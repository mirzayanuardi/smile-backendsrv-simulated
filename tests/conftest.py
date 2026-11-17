"""Fixture pengujian: PostgreSQL lokal di Docker + migrasi v7, v8, v10, v11, dan v12 asli,
lalu grant yang belum ada di migrasi (tests/schema_pending.sql).

Default DSN admin: postgresql://postgres:testpw@127.0.0.1:55432/postgres
(lihat README bagian Pengujian). Aplikasi diuji memakai role smile_ingest,
sehingga hak akses dan RLS dari migrasi ikut teruji.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import httpx
import pytest

from app.auth import hash_token
from app.main import create_app

ROOT = Path(__file__).resolve().parent.parent
ADMIN_DSN = os.environ.get("TEST_ADMIN_DSN", "postgresql://postgres:testpw@127.0.0.1:55432/postgres")
TEST_DB = "smile_test"
# Password role dari smile_migration_v7.sql (hanya berlaku di DB uji lokal).
INGEST_PASSWORD = "4lw4y55m1l3"

NODE1 = uuid.UUID("11111111-1111-1111-1111-111111111111")
NODE2 = uuid.UUID("22222222-2222-2222-2222-222222222222")
PLOT = uuid.UUID("00000000-0000-0000-0000-0000000000b1")
TOKEN1 = "test-token-node-1"
TOKEN2 = "test-token-node-2"


def _dsn(user: str, password: str, db: str) -> str:
    u = urlsplit(ADMIN_DSN)
    netloc = f"{user}:{password}@{u.hostname}:{u.port or 5432}"
    return urlunsplit((u.scheme, netloc, f"/{db}", "", ""))


ADMIN_TEST_DSN = _dsn(urlsplit(ADMIN_DSN).username, urlsplit(ADMIN_DSN).password, TEST_DB)
INGEST_DSN = _dsn("smile_ingest", INGEST_PASSWORD, TEST_DB)


async def _setup_database() -> None:
    conn = await asyncpg.connect(ADMIN_DSN)
    try:
        await conn.execute(f"drop database if exists {TEST_DB} with (force)")
        await conn.execute("drop role if exists smile_ingest")
        await conn.execute(f"create database {TEST_DB}")
    finally:
        await conn.close()

    conn = await asyncpg.connect(ADMIN_TEST_DSN)
    try:
        await conn.execute((ROOT / "tests" / "schema_stub.sql").read_text())
        await conn.execute((ROOT / "smile_migration_v7.sql").read_text())
        # Migrasi harus menandai baris lama sebagai legacy.
        status = await conn.fetchval("select time_status from public.sensor_raw_readings")
        assert status == "legacy", status
        await conn.execute((ROOT / "docs" / "smile_migration_v8.sql").read_text())
        await conn.execute((ROOT / "docs" / "smile_migration_v10.sql").read_text())
        await conn.execute((ROOT / "docs" / "migration_v11_neraca_air.sql").read_text())
        await conn.execute((ROOT / "docs" / "migration_v12_arsip_cuaca.sql").read_text())
        # Idempoten: dijalankan dua kali tidak boleh gagal.
        await conn.execute((ROOT / "docs" / "migration_v12_arsip_cuaca.sql").read_text())
        await conn.execute((ROOT / "tests" / "schema_pending.sql").read_text())
    finally:
        await conn.close()


@pytest.fixture(scope="session", autouse=True)
def database():
    asyncio.run(_setup_database())


@pytest.fixture
async def admin():
    conn = await asyncpg.connect(ADMIN_TEST_DSN)
    await conn.execute(
        "truncate public.sensor_raw_readings, public.clock_events, public.ingest_rejects restart identity"
    )
    await conn.execute(
        "truncate public.irrigation_actions, public.fertigation_actions, public.actuator_commands, "
        "public.irrigation_predictions, public.fertigation_recommendations, "
        "public.nutrient_batch_items, public.nutrient_batches, public.fertilizer_products, "
        "public.water_balance_ledger, public.sensor_calibrations, public.weather_forecasts, "
        "public.plot_soil_water_params, public.weather_forecast_snapshots, public.weather_observed_hourly cascade"
    )
    # Parameter awal v11 (Latosol Darmaga) seperti hasil seed migrasi.
    await conn.execute(
        "insert into public.plot_soil_water_params (plot_id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc, "
        "source, valid_from) values ($1, 59.5, 44.5, 0.40, 400, 1.0, 'literatur_latosol_darmaga', "
        "'2026-01-01T00:00:00Z')",
        PLOT,
    )
    await conn.execute("update public.plots set location_lat = '-6.595', location_lng = '106.8166'")
    await conn.execute(
        "update public.nodes set api_token_hash = case id when $1 then $3 when $2 then $4 end, "
        "last_seen_at = null, firmware_version = null, valve_mode = 'manual', pump_mode = 'manual', "
        "valve_is_on = false, pump_is_on = false, valve_updated_at = null, pump_updated_at = null, "
        "rain_mm_per_tip = null",
        NODE1, NODE2, hash_token(TOKEN1), hash_token(TOKEN2),
    )
    # Hanya NODE1 yang punya aktuator; NODE2 node sensor saja.
    await conn.execute("delete from public.node_actuator_config")
    await conn.execute(
        "insert into public.node_actuator_config (node_id, has_irrigation, has_fertigation, "
        "water_flow_lpm, wetted_area_m2, dose_flow_ml_per_s) values ($1, true, true, 1.2, 0.8, 1.5), "
        "($2, false, false, null, null, null)",
        NODE1, NODE2,
    )
    try:
        yield conn
    finally:
        await conn.close()


async def _wait_pool(app, timeout: float = 10.0) -> None:
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while app.state.db.pool is None:
        if loop.time() > deadline:
            raise RuntimeError("pool tidak siap")
        await asyncio.sleep(0.05)


@pytest.fixture
async def client(admin):
    app = create_app(INGEST_DSN, dispatcher_enabled=False, water_balance_enabled=False,
                     weather_observed_enabled=False)
    async with app.router.lifespan_context(app):
        await _wait_pool(app)
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
            c.app = app
            yield c


@pytest.fixture
async def client_db_down():
    """Aplikasi yang DB-nya tidak bisa dihubungi sama sekali."""
    app = create_app("postgresql://smile_ingest:x@127.0.0.1:1/none", dispatcher_enabled=False,
                     water_balance_enabled=False, weather_observed_enabled=False)
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
            yield c


def headers(node=NODE1, token=TOKEN1, **extra):
    h = {
        "Authorization": f"Bearer {token}",
        "X-Node-Id": str(node),
        "X-Firmware-Version": "smile-v7.0",
        "X-Schema-Version": "1",
        "Content-Type": "text/csv",
    }
    h.update(extra)
    return h
