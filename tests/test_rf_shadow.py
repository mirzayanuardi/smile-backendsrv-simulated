"""RF dengan DB: shadow (insert, fitur tidak lengkap, dispatcher, isolasi FAO-56) dan active (R4).

Model diganti pohon palsu (prediksi tetap), jadi tes ini tidak butuh file joblib.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import numpy as np
import pytest

from app import dispatcher, rf_shadow as rs, water_balance as wb
from app.actuator import FertigationSettings

from .conftest import NODE1, PLOT
from .test_actuator import MODEL, at_wib
from .test_water_balance import END, NOW, SETTINGS, ingest, readings  # noqa: F401 - fixture ingest

T = rs.latest_complete_block(NOW)            # 00:05 UTC = 07:05 WIB


class _Tree:
    def __init__(self, value: float):
        self.value = value

    def predict(self, X):
        return np.full(len(X), self.value)


def fake_rf(trees=(10.0, 14.0), mode="shadow") -> rs.RFShadow:
    bundle = {"plot_id": str(PLOT), "features": rs.FEATURES, "model_version": "uji",
              "models": {"24h": SimpleNamespace(estimators_=[_Tree(v) for v in trees])},
              "soil": {"theta_fc": 59.5, "zr_mm": 400.0, "taw_mm": 60.0, "raw_mm": 24.0}}
    return rs.RFShadow(bundle, MODEL, 25.0, mode)


async def calibrated(admin, start, end, theta=55.0):
    await admin.execute(
        "insert into public.calibrated_sensor_raw_readings (node_id, plot_id, reading_timestamp, "
        "soil_moisture_pct, soil_ec_uscm, rainfall_tip_count) "
        "select $1, $2, ts, $5, 500, 0 "
        "from generate_series($3::timestamptz, $4::timestamptz - interval '1 minute', interval '1 minute') ts",
        NODE1, PLOT, start, end, theta,
    )


async def snapshot(admin, issued):
    await admin.execute(
        "insert into public.weather_forecast_snapshots (plot_id, issued_at, valid_time, lead_hours, "
        "precipitation_mm, precipitation_probability, et0_fao_mm, temperature_2m, relative_humidity_2m, fetched_at) "
        "select $1, $2::timestamptz, $2::timestamptz + make_interval(hours => h), h, 0.1, 40, 0.15, 26, 85, "
        "$2::timestamptz + interval '5 minutes' "
        "from generate_series(1, 48) h",
        PLOT, issued,
    )


async def rf_rows(admin):
    return await admin.fetch("select * from public.irrigation_predictions where decision_layer = 'rf'")


async def test_complete_features_insert_shadow_row(admin, ingest):
    await calibrated(admin, T - rs.LOOKBACK, T + timedelta(minutes=5))
    await snapshot(admin, T - timedelta(hours=1, minutes=5))
    pid = await fake_rf().run(ingest, PLOT, NOW)
    [p] = await rf_rows(admin)
    assert p["id"] == pid and p["model_id"] == MODEL and p["status_model"] == "reliable"   # 2/24 = 8,3 %
    assert p["prediction_dr_value"] == pytest.approx(12) and p["prediction_error_margin"] == pytest.approx(2)
    assert p["predicted_soil_moisture"] == pytest.approx(59.5 - 12 / 400 * 100)
    assert (p["raw_mm"], p["taw_mm"]) == (24, 60)
    assert p["irrigation_triggered"] is False and p["recommended_irrigation_mm"] is None
    assert p["reason"].startswith("rf_shadow: t=2026-10-15 07:05 WIB")

    # Siklus kedua dalam 50 menit tidak menulis dobel.
    assert await fake_rf().run(ingest, PLOT, NOW) is None
    assert len(await rf_rows(admin)) == 1


async def test_uncertain_status(admin, ingest):
    await calibrated(admin, T - rs.LOOKBACK, T + timedelta(minutes=5))
    await snapshot(admin, T - timedelta(hours=1, minutes=5))
    await fake_rf(trees=(0.0, 14.0)).run(ingest, PLOT, NOW)     # std 7 mm = 29 % > 25 %
    [p] = await rf_rows(admin)
    assert p["status_model"] == "uncertain"


@pytest.mark.parametrize("gap", ["no_forecast", "short_history", "missing_block"])
async def test_incomplete_features_no_insert(admin, ingest, gap):
    if gap == "short_history":
        await calibrated(admin, T - timedelta(hours=2), T + timedelta(minutes=5))
    elif gap == "missing_block":
        await calibrated(admin, T - rs.LOOKBACK, T - timedelta(hours=3))
        await calibrated(admin, T - timedelta(hours=3) + timedelta(minutes=10), T + timedelta(minutes=5))
    else:
        await calibrated(admin, T - rs.LOOKBACK, T + timedelta(minutes=5))
    if gap != "no_forecast":
        await snapshot(admin, T - timedelta(hours=1, minutes=5))
    assert await fake_rf().run(ingest, PLOT, NOW) is None
    assert await rf_rows(admin) == []


async def test_snapshot_fetched_after_t_not_used(admin, ingest):
    await calibrated(admin, T - rs.LOOKBACK, T + timedelta(minutes=5))
    await snapshot(admin, T)                    # fetched_at = t + 5 menit > t
    assert await fake_rf().run(ingest, PLOT, NOW) is None


async def test_dispatcher_ignores_rf_rows(admin, ingest):
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    # Dipaksa seolah-olah siram, supaya hanya filter decision_layer yang menahannya.
    await admin.execute(
        "insert into public.irrigation_predictions (plot_id, model_id, prediction_timestamp, decision_layer, "
        "irrigation_triggered, recommended_irrigation_mm, reason) values ($1, $2, now(), 'rf', true, 2.0, 'rf_shadow: uji')",
        PLOT, MODEL,
    )
    out = await dispatcher.run_cycle(ingest, FertigationSettings(), now=at_wib(7))
    assert out["decisions"] == []
    [p] = await rf_rows(admin)
    assert p["dispatched_command_id"] is None and p["dispatch_note"] is None


async def test_rf_failure_does_not_break_fao56(admin, ingest):
    class Boom:
        def __init__(self, mode):
            self.mode = mode

        async def run(self, conn, plot_id, now, force=False):
            raise RuntimeError("model rusak")

        async def infer(self, conn, plot_id, now):
            raise RuntimeError("model rusak")

    await readings(admin, END - timedelta(hours=80), NOW)
    for mode in ("shadow", "active"):
        out = await wb.run_cycle(ingest, SETTINGS, now=NOW, rf=Boom(mode), force=True)
        assert out and out[0].prediction is not None
    rows = await admin.fetch("select decision_layer from public.irrigation_predictions")
    assert [r["decision_layer"] for r in rows] == ["fao56", "fao56"]


async def test_disabled_by_default(monkeypatch):
    monkeypatch.delenv("RF_MODE", raising=False)
    assert rs.RFShadow.from_env() is None
    monkeypatch.setenv("RF_MODE", "aktif")                  # salah ketik -> mati, bukan crash
    assert rs.RFShadow.from_env() is None
    monkeypatch.setenv("RF_MODE", "shadow")
    monkeypatch.delenv("RF_MODEL_PATH", raising=False)
    assert rs.RFShadow.from_env() is None
    monkeypatch.setenv("RF_MODEL_PATH", "/tidak/ada.joblib")
    monkeypatch.setenv("RF_MODEL_ID", str(MODEL))
    assert rs.RFShadow.from_env() is None


# --- RF_MODE=active (fase 2): RF dipakai di R4 kalau reliable -----------------------

async def rf_inputs(admin):
    """FAO-56: Dr ~ ETc 48 jam (< RAW, tanpa kalibrasi). RF: fitur lengkap di t."""
    await readings(admin, END - timedelta(hours=80), NOW)
    await calibrated(admin, T - rs.LOOKBACK, T + timedelta(minutes=5))
    await snapshot(admin, T - timedelta(hours=1, minutes=5))


async def decisions(admin):
    return await admin.fetch("select * from public.irrigation_predictions order by created_at")


async def test_active_reliable_rf_triggers_r4_and_dispatch(admin, ingest):
    await rf_inputs(admin)
    [res] = await wb.run_cycle(ingest, SETTINGS, now=NOW, rf=fake_rf(trees=(30.0, 30.0), mode="active"))
    assert res.decision.code == "anticipatory_24h" and res.decision.triggered
    [p] = await decisions(admin)                       # active: tidak ada baris 'rf' terpisah
    assert p["decision_layer"] == "fao56+rf" and p["model_id"] == MODEL and p["status_model"] == "reliable"
    assert p["prediction_dr_value"] == pytest.approx(30) and p["prediction_error_margin"] == 0
    assert p["dr_forecast_24h_mm"] < 24                # FAO-56 sendiri tidak memicu R4
    assert "R4 memakai RF" in p["reason"]

    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    out = await dispatcher.run_cycle(ingest, FertigationSettings(), now=at_wib(7))
    [d] = out["decisions"]
    assert d.result == "dispatched" and d.ref_id == p["id"]

    # Aturan 50 menit menghitung 'fao56+rf': siklus biasa berikutnya tidak menulis dobel.
    [again] = await wb.run_cycle(ingest, SETTINGS, now=NOW, rf=fake_rf(trees=(30.0, 30.0), mode="active"))
    assert again.skipped_duplicate and len(await decisions(admin)) == 1


async def test_active_uncertain_rf_falls_back_to_fao56(admin, ingest):
    await rf_inputs(admin)
    [res] = await wb.run_cycle(ingest, SETTINGS, now=NOW, rf=fake_rf(trees=(0.0, 60.0), mode="active"))
    assert res.decision.code == "below_raw" and not res.decision.triggered
    [p] = await decisions(admin)
    assert p["decision_layer"] == "fao56" and p["model_id"] is None and p["status_model"] is None
    assert "R4 memakai FAO-56" in p["reason"]


async def test_active_incomplete_features_is_plain_fao56(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)           # tanpa bacaan terkalibrasi
    [res] = await wb.run_cycle(ingest, SETTINGS, now=NOW, rf=fake_rf(trees=(30.0, 30.0), mode="active"))
    [p] = await decisions(admin)
    assert p["decision_layer"] == "fao56" and "RF" not in p["reason"]


async def test_force_skips_fifty_minute_rule(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    await wb.run_cycle(ingest, SETTINGS, now=NOW)
    [dup] = await wb.run_cycle(ingest, SETTINGS, now=NOW)
    assert dup.skipped_duplicate
    [forced] = await wb.run_cycle(ingest, SETTINGS, now=NOW, force=True)
    assert not forced.skipped_duplicate and len(await decisions(admin)) == 2
