"""Neraca air FAO-56 v11 dengan DB: ledger, keputusan, dan rantai ke dispatcher.

Nomor mengikuti uji §7 prompt v11. Semua siklus memakai `now` tetap (07:10 WIB)
supaya jendela pagi dan batas jam bisa diperkirakan.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import asyncpg
import pytest

from app import dispatcher, water_balance as wb
from app.actuator import FertigationSettings

from .conftest import INGEST_DSN, NODE1, PLOT

NOW = datetime(2026, 10, 15, 0, 10, tzinfo=timezone.utc)      # 07:10 WIB
END = wb.floor_hour(NOW)                                       # period_end jam penuh terakhir
SETTINGS = wb.WBSettings()


@pytest.fixture
async def ingest():
    conn = await asyncpg.connect(INGEST_DSN)
    try:
        yield conn
    finally:
        await conn.close()


async def readings(admin, start, end, sm=40.0, rain=0.0, temp=True):
    """Satu baris per menit. Suhu harian 20-30 °C supaya Hargreaves punya data."""
    await admin.execute(
        "insert into public.sensor_raw_readings (node_id, plot_id, reading_timestamp, soil_moisture_pct, "
        "air_temperature_c, rainfall_mm, time_status) "
        "select $1, $2, ts, $5, case when $7 then 25 + 5 * sin(extract(epoch from ts) / 86400 * 2 * pi()) end, "
        "$6, 'verified' "
        "from generate_series($3::timestamptz, $4::timestamptz - interval '1 minute', interval '1 minute') ts",
        NODE1, PLOT, start, end, sm, rain, temp,
    )


async def calibrate(admin, coeffs=(5, 1.2)):
    await admin.execute(
        "insert into public.sensor_calibrations (node_id, parameter, coeffs, raw_min, raw_max, source, valid_from) "
        "values ($1, 'soil_moisture', $2, 0, 100, 'uji', '2026-01-01T00:00:00Z')", NODE1, list(coeffs))


async def cycle(ingest, now=NOW):
    out = await wb.run_cycle(ingest, SETTINGS, now=now)
    assert out is not None
    return out


async def ledger(admin):
    return await admin.fetch("select * from public.water_balance_ledger where plot_id = $1 order by period_end", PLOT)


async def predictions(admin):
    return await admin.fetch("select * from public.irrigation_predictions where decision_layer = 'fao56'")


# 4 --------------------------------------------------------------------------
async def test_python_taw_raw_equals_view(admin):
    v = await admin.fetchrow("select * from public.plot_water_params_current where plot_id = $1", PLOT)
    taw, raw, trig = wb.taw_raw(v["theta_fc_pct"], v["theta_pwp_pct"], v["p_frac"], v["zr_mm"])
    assert (taw, raw, trig) == (v["taw_mm"], v["raw_mm"], v["theta_trigger_pct"])  # sama persis
    assert (taw, raw, trig) == pytest.approx((60, 24, 53.5))


# 5 --------------------------------------------------------------------------
async def test_ledger_without_calibration(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    [res] = await cycle(ingest)
    rows = await ledger(admin)
    assert len(rows) == 48 and rows[-1]["period_end"] == END
    assert {r["calibration_status"] for r in rows} == {"uncalibrated"}
    assert not any(r["corrected"] for r in rows)
    assert {r["eto_source"] for r in rows} == {"hargreaves_sht31"}
    assert {r["rain_source"] for r in rows} == {"sensor"}
    assert res.init == "init_fc_assumed" and rows[0]["dr_start_mm"] == 0
    # Model fisika murni: Dr naik sebesar ETc tiap jam
    assert rows[-1]["dr_end_mm"] == pytest.approx(sum(r["etc_mm"] for r in rows))
    assert rows[-1]["taw_mm"] == pytest.approx(60) and rows[-1]["raw_mm"] == pytest.approx(24)

    [p] = await predictions(admin)
    assert p["model_id"] is None and p["ledger_id"] == rows[-1]["id"]
    assert p["reason"].startswith("below_raw: Dr ")
    assert "ETo hargreaves_sht31" in p["reason"] and "sensor belum terkalibrasi" in p["reason"]
    assert "eto_fc_estimated" in p["reason"]  # tidak ada prakiraan ETo
    assert p["dr_value_fao56"] == pytest.approx(rows[-1]["dr_end_mm"])
    assert p["raw_value"] == 40 and p["irrigation_triggered"] is False


# 6 --------------------------------------------------------------------------
async def test_correction_after_calibration_respects_settle(admin, ingest):
    await calibrate(admin)
    await readings(admin, END - timedelta(hours=80), NOW, sm=40)      # 5 + 1,2 x 40 = 53 %
    irrigated = END - timedelta(hours=10)                              # irigasi di jam ini
    await admin.execute(
        "insert into public.irrigation_actions (plot_id, node_id, action_timestamp, triggered_by, valve_action, "
        "duration_sec, estimated_volume_liter, execution_status) "
        "values ($1, $2, $3, 'manual', 'open', 60, 1.2, 'success')", PLOT, NODE1, irrigated + timedelta(minutes=5))
    [res] = await cycle(ingest)
    assert res.init == "observed"

    rows = {r["period_end"]: r for r in await ledger(admin)}
    hit = rows[irrigated + timedelta(hours=1)]
    assert hit["irrigation_mm"] == pytest.approx(1.2 / 0.8)
    assert hit["theta_obs_pct"] == pytest.approx(53) and hit["dr_obs_mm"] == pytest.approx(26)
    assert {r["calibration_status"] for r in rows.values()} == {"calibrated"}
    # Jam irigasi dan WB_SETTLE_H jam sesudahnya tidak dikoreksi
    for h in range(3):
        assert not rows[irrigated + timedelta(hours=1 + h)]["corrected"]
    corrected = sorted(pe for pe, r in rows.items() if r["corrected"])
    assert corrected, "harus ada koreksi"
    assert all(b - a >= timedelta(hours=6) for a, b in zip(corrected, corrected[1:]))
    assert all(rows[pe]["dr_end_mm"] == pytest.approx(26) for pe in corrected)
    # Koreksi pertama sesudah irigasi menunggu settle selesai
    after = [pe for pe in corrected if pe > irrigated + timedelta(hours=1)]
    assert after and after[0] >= irrigated + timedelta(hours=4)


# 7 --------------------------------------------------------------------------
async def test_late_rain_recomputes_without_changing_ids(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    await cycle(ingest)
    before = {r["period_end"]: r for r in await ledger(admin)}

    # Data hujan 20 mm 10 jam lalu baru masuk (kumulatif: nilai naik dan bertahan)
    rain_at = END - timedelta(hours=10) + timedelta(minutes=30)
    await admin.execute("update public.sensor_raw_readings set rainfall_mm = 20 where reading_timestamp >= $1", rain_at)
    await cycle(ingest)
    after = {r["period_end"]: r for r in await ledger(admin)}

    assert {pe: r["id"] for pe, r in before.items()} == {pe: r["id"] for pe, r in after.items()}
    hour = END - timedelta(hours=9)
    assert after[hour]["rain_mm"] == pytest.approx(20) and after[hour]["rain_source"] == "sensor"
    assert after[hour + timedelta(hours=1)]["rain_mm"] == 0                     # tidak dihitung dua kali
    assert after[hour]["dp_mm"] > 0                                             # tanah penuh, sisanya perkolasi
    for pe in before:
        if pe >= hour:
            assert after[pe]["dr_end_mm"] < before[pe]["dr_end_mm"]
        else:
            assert after[pe]["dr_end_mm"] == pytest.approx(before[pe]["dr_end_mm"])
    assert len(await predictions(admin)) == 1  # siklus kedua < 50 menit: tidak menulis prediksi lagi


# 8 --------------------------------------------------------------------------
async def forecast(admin, start, end, eto=0.2, rain=0.0):
    await admin.execute(
        "insert into public.weather_forecasts (plot_id, forecast_issued_at, valid_for_timestamp, "
        "forecast_rainfall_mm, forecast_eto_mm, source) "
        "select $1, $2, ts, $5, $6, 'open_meteo' "
        "from generate_series($3::timestamptz, $4::timestamptz, interval '1 hour') ts",
        PLOT, NOW - timedelta(hours=1), start, end, rain, eto,
    )


async def test_eto_fallback_order(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    await forecast(admin, END - timedelta(hours=60), END + timedelta(hours=24))
    await cycle(ingest)
    rows = await ledger(admin)
    assert {r["eto_source"] for r in rows} == {"open_meteo"}
    assert rows[-1]["eto_mm"] == pytest.approx(0.2) and rows[-1]["etc_mm"] == pytest.approx(0.2)
    [p] = await predictions(admin)
    assert p["etc_forecast_24h_mm"] == pytest.approx(0.2 * 24) and "eto_fc_estimated" not in p["reason"]

    await admin.execute("update public.weather_forecasts set forecast_eto_mm = null")
    await cycle(ingest)
    assert {r["eto_source"] for r in await ledger(admin)} == {"hargreaves_sht31"}

    await admin.execute("update public.sensor_raw_readings set air_temperature_c = null")
    await cycle(ingest)
    rows = await ledger(admin)
    assert {r["eto_source"] for r in rows} == {"none"} and {r["eto_mm"] for r in rows} == {0}


async def test_rain_forecast_skips_irrigation(admin, ingest):
    """Uji 10 lewat DB: Dr di atas RAW tapi prakiraan hujan 12 jam >= 10 mm."""
    await calibrate(admin)
    await readings(admin, END - timedelta(hours=80), NOW, sm=40)
    await forecast(admin, NOW + timedelta(hours=1), NOW + timedelta(hours=12), rain=1.5)  # 12 x 1,5 = 18 mm
    [res] = await cycle(ingest)
    assert (res.decision.code, res.decision.triggered) == ("rain_expected", False)
    [p] = await predictions(admin)
    assert p["rain_forecast_12h_mm"] == pytest.approx(18) and p["recommended_irrigation_mm"] is None


# 13 -------------------------------------------------------------------------
async def test_fao56_prediction_dispatched(admin, ingest):
    """Prediksi FAO-56 (model_id NULL) 2 mm -> dispatcher membuat perintah rule_engine 80 s."""
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    pid = await admin.fetchval(
        "insert into public.irrigation_predictions (plot_id, prediction_timestamp, model_id, decision_layer, "
        "irrigation_triggered, recommended_irrigation_mm, reason) "
        "values ($1, now(), null, 'fao56', true, 2, 'dr_ge_raw: Dr 26,1 mm ≥ RAW 24,0 mm; ETo open_meteo') "
        "returning id", PLOT)
    out = await dispatcher.run_cycle(ingest, FertigationSettings(), now=NOW)
    [d] = out["decisions"]
    assert (d.result, d.water_s, d.ref_id) == ("dispatched", 80, pid)
    c = await admin.fetchrow("select * from public.actuator_commands where id = $1", d.command_id)
    assert (c["trigger"], c["water_s"], c["irrigation_prediction_id"]) == ("rule_engine", 80, pid)


async def test_full_chain_ledger_to_command(admin, ingest):
    """Rantai penuh: θ 53 % (Dr 26 >= RAW 24) -> prediksi dr_ge_raw 26 mm -> perintah (clamped 600 s)."""
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    await calibrate(admin)
    await readings(admin, END - timedelta(hours=80), NOW, sm=40)
    [res] = await cycle(ingest)
    # Dr = 26 di koreksi terakhir + ETc paling lama 6 jam sesudahnya
    assert res.decision.code == "dr_ge_raw" and 26 <= res.decision.recommended_mm < 28
    [p] = await predictions(admin)
    assert p["reason"].startswith("dr_ge_raw: Dr ") and "terkalibrasi" not in p["reason"]

    [d] = (await dispatcher.run_cycle(ingest, FertigationSettings(), now=NOW))["decisions"]
    assert (d.result, d.water_s) == ("clamped", 600)  # 26 mm x 0,8 m2 / 1,2 L/menit = 1040 s


# 14 -------------------------------------------------------------------------
async def test_one_prediction_per_50_minutes(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    [first] = await cycle(ingest)
    [second] = await cycle(ingest, now=NOW + timedelta(minutes=20))
    assert not first.skipped_duplicate and second.skipped_duplicate
    assert len(await predictions(admin)) == 1


async def test_single_runner(admin, ingest):
    other = await asyncpg.connect(INGEST_DSN)
    try:
        assert await other.fetchval("select pg_try_advisory_lock($1)", wb.WB_LOCK_KEY)
        assert await wb.run_cycle(ingest, SETTINGS, now=NOW) is None
    finally:
        await other.close()


async def test_missing_access_degrades(admin, ingest):
    """Tanpa akses plots/nodes meta (kondisi Supabase bila grant tambahan belum ada)."""
    access = {"lat": False, "node_meta": False, "wf_policy": False}
    await readings(admin, END - timedelta(hours=80), NOW)
    res = await wb.compute_plot(ingest, PLOT, SETTINGS, access, NOW)
    assert "lat_default" in res.warnings and len(res.rows) == 48


def test_next_run_minute_five():
    assert wb.next_run(datetime(2026, 10, 15, 0, 4, tzinfo=timezone.utc)) == datetime(2026, 10, 15, 0, 5, tzinfo=timezone.utc)
    assert wb.next_run(datetime(2026, 10, 15, 0, 5, tzinfo=timezone.utc)) == datetime(2026, 10, 15, 1, 5, tzinfo=timezone.utc)
