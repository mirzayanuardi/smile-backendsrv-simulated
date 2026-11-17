"""Arsip cuaca v12 dengan DB: snapshot, observasi, fallback ETo, faktor tip, mode backfill ML."""

from __future__ import annotations

import csv
import uuid
from datetime import date, datetime, timedelta, timezone

import asyncpg
import httpx
import pytest

from app import water_balance as wb
from app import weather
from scripts.run_water_balance import CSV_COLUMNS, write_csv

from .conftest import INGEST_DSN, NODE1, PLOT
from .test_water_balance import END, NOW, SETTINGS, ledger, readings
from .test_weather_pure import archive_json, forecast_json

H = timedelta(hours=1)


@pytest.fixture
async def ingest():
    conn = await asyncpg.connect(INGEST_DSN)
    try:
        yield conn
    finally:
        await conn.close()


class FakeOpenMeteo:
    """MockTransport: forecast relatif ke `issued`, archive sesuai start/end permintaan."""

    def __init__(self, issued=NOW, eto=0.15, rain=0.4, archive_eto=0.12, fail=False):
        self.issued, self.eto, self.rain, self.archive_eto, self.fail = issued, eto, rain, archive_eto, fail
        self.calls: list[httpx.Request] = []

    def handler(self, req: httpx.Request):
        self.calls.append(req)
        if self.fail:
            return httpx.Response(500, text="down")
        if req.url.host == "archive-api.open-meteo.com":
            q = req.url.params
            return httpx.Response(200, json=archive_json(
                date.fromisoformat(q["start_date"]), date.fromisoformat(q["end_date"]), eto=self.archive_eto))
        return httpx.Response(200, json=forecast_json(self.issued, eto=self.eto, rain=self.rain))

    def client(self) -> weather.OpenMeteo:
        return weather.OpenMeteo(weather.WXSettings(backoff_s=0),
                                 httpx.AsyncClient(transport=httpx.MockTransport(self.handler)))


async def snapshots(admin):
    return await admin.fetch("select * from public.weather_forecast_snapshots order by issued_at, valid_time")


# --- A: snapshot forecast ------------------------------------------------------------

async def test_sync_writes_forecast_and_snapshot_in_one_call(admin, ingest):
    fake = FakeOpenMeteo()
    stats = await weather.sync_forecasts(ingest, fake.client(), NOW)
    assert len(fake.calls) == 1                                    # satu plot aktif, satu panggilan
    assert (stats["rows_snapshot"], stats["errors"]) == (48, [])
    snaps = await snapshots(admin)
    issued = wb.floor_hour(NOW)
    assert len(snaps) == 48 and {s["issued_at"] for s in snaps} == {issued}
    assert [s["lead_hours"] for s in snaps] == list(range(1, 49))
    assert all(s["valid_time"] - s["issued_at"] == s["lead_hours"] * H for s in snaps)
    assert {(s["source"], s["model"]) for s in snaps} == {("open_meteo", "best_match")}
    assert snaps[0]["fetched_at"] == NOW
    wf = await admin.fetch("select * from public.weather_forecasts where plot_id = $1", PLOT)
    assert len(wf) == 48 + 72 + 1 and {r["forecast_eto_mm"] for r in wf} == {0.15}


async def test_forecast_covers_plots_without_active_node(admin, ingest):
    # Plot tanpa node dan plot dengan node maintenance tetap dapat prakiraan (dulu dari
    # edge function); job observasi tetap hanya untuk plot dengan node aktif.
    no_node = uuid.UUID("00000000-0000-0000-0000-0000000000b2")
    maint = uuid.UUID("00000000-0000-0000-0000-0000000000b3")
    maint_node = uuid.UUID("33333333-3333-3333-3333-333333333333")
    owner = await admin.fetchval("select user_id from public.plots where id = $1", PLOT)
    await admin.execute("insert into public.plots (id, user_id, plot_name) values ($1, $3, 'B'), ($2, $3, 'C')",
                        no_node, maint, owner)
    await admin.execute("insert into public.nodes (id, user_id, plot_id, status) values ($1, $2, $3, 'maintenance')",
                        maint_node, owner, maint)
    try:
        fake = FakeOpenMeteo()
        stats = await weather.sync_forecasts(ingest, fake.client(), NOW)
        assert stats["plots"] == 3 and len(fake.calls) == 3
        got = {r["plot_id"] for r in await admin.fetch("select distinct plot_id from public.weather_forecasts")}
        assert got == {PLOT, no_node, maint}

        obs = await weather.run_observed_cycle(ingest, FakeOpenMeteo().client(),
                                               start=date(2026, 10, 1), end=date(2026, 10, 1))
        assert obs["plots"] == 1
    finally:
        for t in ("weather_forecast_snapshots", "weather_forecasts", "weather_observed_hourly"):
            await admin.execute(f"delete from public.{t} where plot_id = any($1::uuid[])", [no_node, maint])
        await admin.execute("delete from public.nodes where id = $1", maint_node)
        await admin.execute("delete from public.plots where id = any($1::uuid[])", [no_node, maint])


async def test_snapshot_upsert_idempotent(admin, ingest):
    await weather.sync_forecasts(ingest, FakeOpenMeteo(eto=0.15).client(), NOW)
    # Fetch ulang di jam yang sama dengan nilai berbeda: snapshot TIDAK berubah,
    # weather_forecasts (nilai terbaru) ikut berubah.
    stats = await weather.sync_forecasts(ingest, FakeOpenMeteo(eto=0.30).client(), NOW + timedelta(minutes=20))
    assert stats["rows_snapshot"] == 0
    snaps = await snapshots(admin)
    assert len(snaps) == 48 and {s["et0_fao_mm"] for s in snaps} == {0.15}
    assert {r["forecast_eto_mm"] for r in await admin.fetch("select forecast_eto_mm from public.weather_forecasts")} == {0.30}

    # Jam berikutnya = issue baru
    later = NOW + H
    await weather.sync_forecasts(ingest, FakeOpenMeteo(issued=later, eto=0.2).client(), later)
    snaps = await snapshots(admin)
    assert len(snaps) == 96 and len({s["issued_at"] for s in snaps}) == 2


async def test_forecast_failure_does_not_fail_water_balance(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    fake = FakeOpenMeteo(fail=True)
    out = await wb.run_cycle(ingest, SETTINGS, now=NOW, meteo=fake.client())
    assert out and len(fake.calls) == 3                            # retry 3x lalu menyerah
    assert len(await ledger(admin)) == 48 and await snapshots(admin) == []


async def test_snapshot_write_failure_does_not_fail_water_balance(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    await admin.execute("revoke insert on public.weather_forecast_snapshots from smile_ingest")
    try:
        out = await wb.run_cycle(ingest, SETTINGS, now=NOW, meteo=FakeOpenMeteo().client())
    finally:
        await admin.execute("grant insert on public.weather_forecast_snapshots to smile_ingest")
    assert out
    rows = await ledger(admin)
    assert len(rows) == 48 and await snapshots(admin) == []
    # weather_forecasts tetap ditulis dan langsung dipakai ledger jam ini
    assert {r["eto_source"] for r in rows} == {"open_meteo"}


# --- B: observasi -----------------------------------------------------------------

async def test_observed_upsert_revises_and_keeps_old_on_null(admin, ingest):
    start, end = date(2026, 10, 1), date(2026, 10, 2)
    stats = await weather.run_observed_cycle(ingest, FakeOpenMeteo(archive_eto=0.12).client(),
                                             start=start, end=end)
    assert stats["rows"] == 48 and stats["errors"] == []
    first = await admin.fetchval("select max(updated_at) from public.weather_observed_hourly")

    # Revisi reanalisis: nilai baru menimpa, NULL tidak menghapus nilai lama
    fake = FakeOpenMeteo(archive_eto=0.2)
    orig = fake.handler

    def handler(req):
        r = orig(req)
        data = r.json()
        data["hourly"]["temperature_2m"] = [None] * len(data["hourly"]["time"])
        return httpx.Response(200, json=data)

    fake.handler = handler
    stats = await weather.run_observed_cycle(ingest, fake.client(), start=start, end=end)
    rows = await admin.fetch("select * from public.weather_observed_hourly order by time")
    assert len(rows) == 48 and stats["rows"] == 48
    assert {r["et0_fao_mm"] for r in rows} == {0.2} and {r["temperature_2m"] for r in rows} == {23.0}
    assert rows[0]["time"] == datetime(2026, 10, 1, tzinfo=timezone.utc)
    assert rows[0]["updated_at"] > first and {r["source"] for r in rows} == {"open_meteo_archive"}


async def test_observed_single_runner(admin, ingest):
    other = await asyncpg.connect(INGEST_DSN)
    try:
        assert await other.fetchval("select pg_try_advisory_lock($1)", weather.OBS_LOCK_KEY)
        assert await weather.run_observed_cycle(ingest, FakeOpenMeteo().client(), now=NOW) is None
    finally:
        await other.close()


# --- D: urutan ETo ------------------------------------------------------------------

async def test_eto_order_live_cached_archive_hargreaves(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    cached_until, archive_until = END - 30 * H, END - 10 * H
    # Snapshot dua issue untuk jam awal: yang terbaru menang
    for lead, eto in ((2, 0.1), (1, 0.3)):
        await admin.execute(
            "insert into public.weather_forecast_snapshots (plot_id, issued_at, valid_time, lead_hours, et0_fao_mm) "
            "select $1, ts - make_interval(hours => $4), ts, $4, $5 "
            "from generate_series($2::timestamptz, $3::timestamptz, interval '1 hour') ts",
            PLOT, END - 60 * H, cached_until, lead, eto)
    await admin.execute(
        "insert into public.weather_observed_hourly (plot_id, time, et0_fao_mm) "
        "select $1, ts, 0.25 from generate_series($2::timestamptz, $3::timestamptz, interval '1 hour') ts",
        PLOT, END - 60 * H, archive_until)
    # Live untuk 5 jam terakhir saja; jam di antaranya jatuh ke Hargreaves
    await admin.execute(
        "insert into public.weather_forecasts (plot_id, forecast_issued_at, valid_for_timestamp, forecast_eto_mm, source) "
        "select $1, $2, ts, 0.2, 'open_meteo' from generate_series($3::timestamptz, $4::timestamptz, interval '1 hour') ts",
        PLOT, NOW, END - 4 * H, END + 24 * H)
    await wb.run_cycle(ingest, SETTINGS, now=NOW)
    by = {r["period_end"]: r for r in await ledger(admin)}
    assert (by[cached_until]["eto_source"], by[cached_until]["eto_mm"]) == ("open_meteo_cached", 0.3)
    assert (by[archive_until]["eto_source"], by[archive_until]["eto_mm"]) == ("open_meteo_archive", 0.25)
    assert by[END - 5 * H]["eto_source"] == "hargreaves_sht31"
    assert (by[END]["eto_source"], by[END]["eto_mm"]) == ("open_meteo", 0.2)


# --- F: faktor tip ----------------------------------------------------------------

async def test_rain_from_tips_with_node_factor(admin, ingest):
    await readings(admin, END - timedelta(hours=80), NOW)
    rain_at = END - 10 * H + timedelta(minutes=30)
    await admin.execute("update public.sensor_raw_readings set rainfall_tip_count = "
                        "case when reading_timestamp >= $1 then 120 else 100 end, "
                        "rainfall_mm = case when reading_timestamp >= $1 then 33.6 else 28 end", rain_at)
    await admin.execute("update public.nodes set rain_mm_per_tip = 0.289 where id = $1", NODE1)
    await wb.run_cycle(ingest, SETTINGS, now=NOW)
    by = {r["period_end"]: r for r in await ledger(admin)}
    assert by[END - 9 * H]["rain_mm"] == pytest.approx(20 * 0.289)
    raw = await admin.fetchval("select max(rainfall_tip_count) from public.sensor_raw_readings")
    assert raw == 120                                              # data mentah tidak diubah


# --- E: lintasan untuk ML ---------------------------------------------------------

async def test_trajectory_pure_fao56_no_ledger_write(admin, ingest, tmp_path):
    await admin.execute(
        "insert into public.sensor_calibrations (node_id, parameter, coeffs, raw_min, raw_max, source, valid_from) "
        "values ($1, 'soil_moisture', '{5,1.2}', 0, 100, 'uji', '2026-01-01T00:00:00Z')", NODE1)
    await readings(admin, END - timedelta(hours=80), NOW, sm=40)   # θ 53 % -> Dr obs 26 mm
    start, end = END - 24 * H, END
    # Versi parameter baru di tengah rentang: TAW berubah tepat di jam itu
    await admin.execute(
        "insert into public.plot_soil_water_params (plot_id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc, "
        "source, valid_from) values ($1, 59.5, 44.5, 0.40, 600, 1.0, 'uji', $2)", PLOT, start + 12 * H)

    access = await wb.check_access(ingest)
    traj = await wb.compute_trajectory(ingest, PLOT, SETTINGS, access, start, end)
    rows = traj.rows
    assert len(rows) == 24 and rows[0].time == start + H and rows[-1].time == end
    assert traj.init == "observed" and rows[0].dr_start_mm == pytest.approx(26)
    # Tanpa koreksi sensor: Dr naik murni sebesar ETc (tanpa hujan/irigasi)
    for a, b in zip(rows, rows[1:]):
        assert b.dr_start_mm == a.dr_end_mm
    assert rows[-1].dr_end_mm == pytest.approx(26 + sum(r.etc_mm for r in rows))
    assert [r.taw_mm for r in rows] == pytest.approx([60] * 12 + [90] * 12)
    assert await ledger(admin) == []                               # TIDAK menulis ledger

    path = tmp_path / "out.csv"
    write_csv(str(path), traj)
    with open(path) as f:
        data = list(csv.reader(f))
    assert tuple(data[0]) == CSV_COLUMNS and len(data) == 25
    assert data[1][0] == (start + H).isoformat() and data[1][-1] == "hargreaves_sht31"


# --- RLS / hak akses ----------------------------------------------------------------

@pytest.mark.parametrize("role", ["anon", "authenticated"])
async def test_new_tables_not_writable_by_client_roles(admin, role):
    async with admin.transaction():
        await admin.execute(f"set local role {role}")
        for sql in (
            "insert into public.weather_forecast_snapshots (plot_id, issued_at, valid_time, lead_hours) "
            "values ($1, '2026-10-19T00:00Z', '2026-10-19T01:00Z', 1)",
            "insert into public.weather_observed_hourly (plot_id, time) values ($1, '2026-10-19T00:00Z')",
        ):
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                async with admin.transaction():          # savepoint: rollback setelah error
                    await admin.execute(sql, PLOT)
        if role == "anon":
            for t in ("weather_forecast_snapshots", "weather_observed_hourly"):
                with pytest.raises(asyncpg.InsufficientPrivilegeError):
                    async with admin.transaction():
                        await admin.fetch(f"select 1 from public.{t}")


async def test_ingest_cannot_rewrite_snapshots(admin, ingest):
    await weather.sync_forecasts(ingest, FakeOpenMeteo().client(), NOW)
    with pytest.raises(asyncpg.InsufficientPrivilegeError):
        await ingest.execute("update public.weather_forecast_snapshots set et0_fao_mm = 9")


# --- health -------------------------------------------------------------------

async def test_health_weather_fields(client, admin):
    body = (await client.get("/v1/health")).json()
    assert body["last_forecast_snapshot_at"] is None and body["last_observed_weather_at"] is None
    await admin.execute(
        "insert into public.weather_forecast_snapshots (plot_id, issued_at, valid_time, lead_hours, fetched_at) "
        "values ($1, '2026-10-19T00:00Z', '2026-10-19T01:00Z', 1, '2026-10-19T00:05Z')", PLOT)
    await admin.execute("insert into public.weather_observed_hourly (plot_id, time, updated_at) "
                        "values ($1, '2026-10-18T00:00Z', '2026-10-18T20:00Z')", PLOT)
    body = (await client.get("/v1/health")).json()
    assert datetime.fromisoformat(body["last_forecast_snapshot_at"]) == datetime(2026, 10, 19, 0, 5, tzinfo=timezone.utc)
    assert datetime.fromisoformat(body["last_observed_weather_at"]) == datetime(2026, 10, 18, 20, tzinfo=timezone.utc)
