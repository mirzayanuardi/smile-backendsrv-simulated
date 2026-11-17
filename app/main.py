"""SMILE Ingest Server.

Kode status adalah kontrak dengan firmware (lihat README):
  2xx          -> node memajukan cursor (walau sebagian baris ditolak)
  401          -> node berhenti 15 menit, data tidak dibuang
  400/413/415/422 -> node coba 3x lalu karantina chunk
  5xx          -> node backoff lalu kirim ulang
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

from . import actuator, db, dispatcher, water_balance, weather
from .auth import AuthError, NodeAuth
from .csvparse import BadRequest, parse_actuations, parse_events, parse_readings
from .jsonlog import log_json as _log_json

MAX_BODY_BYTES = 64 * 1024
SUPPORTED_SCHEMA_VERSIONS = {"1"}

log = logging.getLogger("smile")


def _setup_logging() -> None:
    root = logging.getLogger()
    if not root.handlers:
        h = logging.StreamHandler(sys.stdout)
        h.setFormatter(logging.Formatter("%(message)s"))
        root.addHandler(h)
    root.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def _error(status: int, message: str) -> JSONResponse:
    return JSONResponse({"error": message}, status_code=status)


class _BodyTooLarge(Exception):
    pass


async def _read_body(request: Request, limit: int) -> bytes:
    cl = request.headers.get("content-length")
    if cl and cl.isdigit() and int(cl) > limit:
        raise _BodyTooLarge
    buf = bytearray()
    async for chunk in request.stream():
        buf += chunk
        if len(buf) > limit:
            raise _BodyTooLarge
    return bytes(buf)


def create_app(
    database_url: str | None = None,
    statement_cache_size: int | None = None,
    dispatcher_enabled: bool | None = None,
    water_balance_enabled: bool | None = None,
    weather_observed_enabled: bool | None = None,
) -> FastAPI:
    _setup_logging()
    auth = NodeAuth()
    act_ctx = actuator.ActuatorContext(
        actuator.FertigationSettings.from_env(
            os.environ.get("FERTIGATION_EXECUTED_BY", ""),
            os.environ.get("FERTIGATION_AUTO_STATUSES", ""),
        )
    )
    if dispatcher_enabled is None:
        dispatcher_enabled = os.environ.get("DISPATCHER_ENABLED", "1") != "0"
    dispatch_interval = float(os.environ.get("DISPATCH_INTERVAL_S", "60"))
    wb_settings = water_balance.WBSettings.from_env()
    if water_balance_enabled is None:
        water_balance_enabled = wb_settings.enabled
    wx_settings = weather.WXSettings.from_env()
    if weather_observed_enabled is None:
        weather_observed_enabled = wx_settings.observed_enabled

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        dsn = database_url or os.environ.get("DATABASE_URL")
        if not dsn:
            raise RuntimeError("DATABASE_URL belum diisi")
        cache = statement_cache_size
        if cache is None:
            cache = int(os.environ.get("DB_STATEMENT_CACHE_SIZE", "100"))
        app.state.db = db.Database(dsn, cache)
        await app.state.db.start()
        tasks = []
        if dispatcher_enabled:
            tasks.append(asyncio.create_task(dispatcher.run_forever(app.state.db, act_ctx, dispatch_interval)))
        if water_balance_enabled:
            # Prakiraan Open-Meteo diambil di siklus neraca air (satu panggilan per plot per jam).
            meteo = weather.OpenMeteo(wx_settings) if wx_settings.forecast_enabled else None
            tasks.append(asyncio.create_task(water_balance.run_forever(app.state.db, wb_settings, meteo)))
        if weather_observed_enabled:
            tasks.append(asyncio.create_task(weather.run_observed_forever(app.state.db, wx_settings)))
        yield
        for task in tasks:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        await app.state.db.close()

    app = FastAPI(title="SMILE Ingest", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.auth = auth
    app.state.actuator = act_ctx

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        start = time.perf_counter()
        request.state.log = {}
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        finally:
            if request.url.path != "/v1/health" or status != 200:
                _log_json(
                    method=request.method,
                    endpoint=request.url.path,
                    status=status,
                    duration_ms=round((time.perf_counter() - start) * 1000, 1),
                    client=request.client.host if request.client else None,
                    **request.state.log,
                )

    @app.get("/v1/health")
    async def health(request: Request):
        database = request.app.state.db
        db_ok = await database.ping(timeout=1.0)
        fc_at, obs_at = await weather.last_times(database, timeout=1.0) if db_ok else (None, None)
        return {
            "status": "ok", "server_time": int(time.time()), "db": "ok" if db_ok else "down",
            "last_forecast_snapshot_at": fc_at.isoformat() if fc_at else None,
            "last_observed_weather_at": obs_at.isoformat() if obs_at else None,
        }

    async def _ingest(request: Request, kind: str):
        endpoint = request.url.path
        st = request.state.log
        database: db.Database = request.app.state.db

        try:
            node_id, token = NodeAuth.parse_headers(
                request.headers.get("authorization"), request.headers.get("x-node-id")
            )
        except AuthError as e:
            st["auth_error"] = str(e)
            return _error(401, "unauthorized")
        st["node_id"] = str(node_id)

        if database.pool is None:
            return _error(503, "database unavailable")

        try:
            async with database.pool.acquire() as conn:
                try:
                    node = await auth.authenticate(conn, node_id, token)
                except AuthError as e:
                    st["auth_error"] = str(e)
                    return _error(401, "unauthorized")

                if auth.should_touch(node_id):
                    fw = (request.headers.get("x-firmware-version") or "").strip()[:64] or None
                    try:
                        await db.touch_node(conn, node_id, fw)
                    except db.DB_ERRORS as e:
                        log.warning("touch_node failed: %s", e)
                        if conn.is_closed():
                            raise

                if request.headers.get("x-schema-version", "").strip() not in SUPPORTED_SCHEMA_VERSIONS:
                    return _error(422, "unsupported X-Schema-Version")
                ctype = request.headers.get("content-type", "").split(";")[0].strip().lower()
                if ctype != "text/csv":
                    return _error(415, "Content-Type must be text/csv")
                try:
                    body = await _read_body(request, MAX_BODY_BYTES)
                except _BodyTooLarge:
                    return _error(413, f"body larger than {MAX_BODY_BYTES} bytes")
                st["bytes"] = len(body)

                parser = {"readings": parse_readings, "events": parse_events,
                          "actuations": parse_actuations}[kind]
                try:
                    parsed = parser(body)
                except BadRequest as e:
                    st["bad_request"] = str(e)
                    return _error(400, str(e))

                parse_rejects = len(parsed.rejects)
                if kind == "readings":
                    inserted = await db.ingest_readings(
                        conn, node_id, node.plot_id, parsed.rows, parsed.rejects, endpoint
                    )
                elif kind == "actuations":
                    schema, fert = await act_ctx.ensure(conn)
                    inserted = await actuator.ingest_actuations(
                        conn, node_id, node.plot_id, parsed.rows, parsed.rejects, endpoint, schema, fert
                    )
                else:
                    inserted, corrected = await db.ingest_events(
                        conn, node_id, parsed.rows, parsed.rejects, endpoint
                    )
                    st["corrected"] = corrected
        except db.DB_ERRORS as e:
            st["db_error"] = f"{type(e).__name__}: {e}"[:300]
            return _error(503, "database error, retry later")

        # Baris yang lolos parser tapi ditolak saat dicocokkan ke DB (cmd_id) bukan duplikat.
        duplicates = len(parsed.rows) - (len(parsed.rejects) - parse_rejects) - inserted
        st.update(inserted=inserted, duplicates=duplicates, rejected=len(parsed.rejects))
        return {
            "inserted": inserted,
            "duplicates": duplicates,
            "rejected": [{"line": r.line, "reason": r.reason} for r in parsed.rejects],
            "server_time": int(time.time()),
        }

    @app.post("/v1/ingest/readings")
    async def ingest_readings(request: Request):
        return await _ingest(request, "readings")

    @app.post("/v1/ingest/clock-events")
    async def ingest_clock_events(request: Request):
        return await _ingest(request, "events")

    @app.post("/v1/ingest/actuations")
    async def ingest_actuations(request: Request):
        return await _ingest(request, "actuations")

    @app.get("/v1/commands")
    async def commands(request: Request):
        st = request.state.log
        database: db.Database = request.app.state.db
        try:
            node_id, token = NodeAuth.parse_headers(
                request.headers.get("authorization"), request.headers.get("x-node-id")
            )
        except AuthError as e:
            st["auth_error"] = str(e)
            return _error(401, "unauthorized")
        st["node_id"] = str(node_id)
        if database.pool is None:
            return _error(503, "database unavailable")

        raw_act = request.headers.get("x-act")
        act = actuator.parse_xact(raw_act)
        if raw_act:
            st["x_act"] = raw_act[:200]
        try:
            async with database.pool.acquire() as conn:
                try:
                    await auth.authenticate(conn, node_id, token)
                except AuthError as e:
                    st["auth_error"] = str(e)
                    return _error(401, "unauthorized")
                fw = (request.headers.get("x-firmware-version") or "").strip()[:64] or None
                config, cmds = await actuator.poll_commands(
                    conn, node_id, act, auth.should_touch(node_id), fw
                )
        except db.DB_ERRORS as e:
            st["db_error"] = f"{type(e).__name__}: {e}"[:300]
            return _error(503, "database error, retry later")

        if cmds:
            st["sent"] = [str(c["id"]) for c in cmds]
        if config is not None:
            st["config_version"] = config["config_version"]
        return PlainTextResponse(
            actuator.format_commands(config, cmds), media_type="text/plain; charset=utf-8"
        )

    return app


app = create_app()
