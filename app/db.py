"""Pool asyncpg dan semua SQL yang dipakai server.

Rumus koreksi waktu TIDAK ditulis di sini; semuanya memanggil
public.smile_corrected_ts / public.smile_time_status dari migrasi.
"""

from __future__ import annotations

import asyncio
import logging
import uuid

import asyncpg

from .csvparse import FLOAT_SENSORS, ClockEvent, Reading, Reject

log = logging.getLogger("smile.db")

# Error yang berarti "DB bermasalah, coba lagi nanti" -> 503.
DB_ERRORS = (asyncpg.PostgresError, asyncpg.InterfaceError, OSError, TimeoutError)


class Database:
    def __init__(self, dsn: str, statement_cache_size: int = 100):
        self.dsn = dsn
        self.statement_cache_size = statement_cache_size
        self.pool: asyncpg.Pool | None = None
        self._task: asyncio.Task | None = None

    async def start(self) -> None:
        # Pool dibuat di background: server harus tetap hidup (dan /v1/health
        # tetap 200) walaupun DB belum bisa dihubungi saat start.
        self._task = asyncio.create_task(self._connect_loop())

    async def _connect_loop(self) -> None:
        delay = 1.0
        while self.pool is None:
            try:
                self.pool = await asyncpg.create_pool(
                    self.dsn,
                    min_size=1,
                    max_size=5,
                    statement_cache_size=self.statement_cache_size,
                    command_timeout=15,
                    timeout=10,
                )
                log.info("db pool ready")
            except Exception as e:  # noqa: BLE001 - apa pun alasannya, coba lagi
                log.warning("db connect failed: %s: %s", type(e).__name__, e)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)

    async def close(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
        if self.pool is not None:
            await self.pool.close()

    async def ping(self, timeout: float = 1.0) -> bool:
        if self.pool is None:
            return False
        try:
            async with asyncio.timeout(timeout):
                async with self.pool.acquire() as conn:
                    await conn.fetchval("select 1")
            return True
        except Exception:  # noqa: BLE001
            return False


def node_lock_key(node_id: uuid.UUID) -> int:
    """Kunci advisory per node: readings dan clock events untuk node yang sama
    diproses berurutan, sehingga event yang datang bersamaan dengan data
    tidak pernah melewatkan baris yang belum ter-commit."""
    return int.from_bytes(node_id.bytes[:8], "big", signed=True)


async def fetch_node(conn: asyncpg.Connection, node_id: uuid.UUID):
    return await conn.fetchrow(
        "select plot_id, api_token_hash from public.nodes where id = $1", node_id
    )


async def touch_node(conn: asyncpg.Connection, node_id: uuid.UUID, firmware: str | None) -> None:
    # Jangan membaca firmware_version (mis. coalesce): smile_ingest hanya punya
    # hak UPDATE kolom itu, bukan SELECT.
    if firmware:
        await conn.execute(
            "update public.nodes set last_seen_at = now(), firmware_version = $2 where id = $1",
            node_id,
            firmware,
        )
    else:
        await conn.execute("update public.nodes set last_seen_at = now() where id = $1", node_id)


_SENSOR_COLS = [col for _, col, _, _ in FLOAT_SENSORS]

_INSERT_READINGS = f"""
insert into public.sensor_raw_readings (
  node_id, plot_id, reading_timestamp, reading_timestamp_raw, clock_segment,
  uptime_s, device_flags, time_status, quality_flag,
  {", ".join(_SENSOR_COLS)}, rainfall_tip_count
)
select
  $1, $2,
  public.smile_corrected_ts(u.ts_raw, e.delta_s, e.start_verified, e.segment_start, e.rtc_before),
  u.ts_raw, u.clk, u.up, u.flags,
  public.smile_time_status(e.delta_s, e.start_verified, u.flags),
  u.qf,
  {", ".join(f"u.{c}" for c in _SENSOR_COLS)}, u.tips
from unnest(
  $3::timestamptz[], $4::text[], $5::bigint[], $6::integer[], $7::text[],
  {", ".join(f"${i}::float8[]" for i in range(8, 8 + len(_SENSOR_COLS)))},
  ${8 + len(_SENSOR_COLS)}::bigint[]
) as u(ts_raw, clk, up, flags, qf, {", ".join(_SENSOR_COLS)}, tips)
left join public.clock_events e
  on e.node_id = $1 and e.clock_segment = u.clk
on conflict (node_id, clock_segment, reading_timestamp_raw) do nothing
returning 1
"""

_INSERT_REJECTS = """
insert into public.ingest_rejects (node_id, endpoint, line_no, raw_line, reason)
select $1, $2, u.line_no, u.raw_line, u.reason
from unnest($3::integer[], $4::text[], $5::text[]) as u(line_no, raw_line, reason)
"""

_INSERT_EVENTS = """
insert into public.clock_events (
  node_id, clock_segment, rtc_before, ref_time, delta_s,
  start_verified, segment_start, ref_source
)
select $1, u.clk, u.rtc_before, u.ref_time, u.delta_s, u.start_verified, u.seg_start, u.ref_source
from unnest(
  $2::text[], $3::timestamptz[], $4::timestamptz[], $5::integer[],
  $6::boolean[], $7::timestamptz[], $8::text[]
) as u(clk, rtc_before, ref_time, delta_s, start_verified, seg_start, ref_source)
on conflict (node_id, clock_segment) do nothing
returning clock_segment
"""

_RECORRECT_READINGS = """
update public.sensor_raw_readings r
   set reading_timestamp = public.smile_corrected_ts(
         r.reading_timestamp_raw, e.delta_s, e.start_verified, e.segment_start, e.rtc_before),
       time_status = public.smile_time_status(e.delta_s, e.start_verified, r.device_flags)
  from public.clock_events e
 where e.node_id = $1
   and e.clock_segment = any($2::text[])
   and r.node_id = e.node_id
   and r.clock_segment = e.clock_segment
"""

# Riwayat aktuator (v8) memakai rumus koreksi yang sama dengan readings.
_RECORRECT_IRRIGATION = """
update public.irrigation_actions a
   set action_timestamp = public.smile_corrected_ts(
         a.action_timestamp_raw, e.delta_s, e.start_verified, e.segment_start, e.rtc_before)
  from public.clock_events e
 where e.node_id = $1
   and e.clock_segment = any($2::text[])
   and a.node_id = e.node_id
   and a.clock_segment = e.clock_segment
   and a.action_timestamp_raw is not null
"""
_RECORRECT_FERTIGATION = """
update public.fertigation_actions a
   set execution_timestamp = public.smile_corrected_ts(
         a.execution_timestamp_raw, e.delta_s, e.start_verified, e.segment_start, e.rtc_before)
  from public.clock_events e
 where e.node_id = $1
   and e.clock_segment = any($2::text[])
   and a.node_id = e.node_id
   and a.clock_segment = e.clock_segment
   and a.execution_timestamp_raw is not null
"""


async def insert_rejects(conn, node_id, endpoint: str, rejects: list[Reject]) -> None:
    if not rejects:
        return
    await conn.execute(
        _INSERT_REJECTS,
        node_id,
        endpoint,
        [r.line for r in rejects],
        [r.raw for r in rejects],
        [r.reason for r in rejects],
    )


async def ingest_readings(
    conn: asyncpg.Connection,
    node_id: uuid.UUID,
    plot_id,
    rows: list[Reading],
    rejects: list[Reject],
    endpoint: str,
) -> int:
    """Satu transaksi untuk seluruh chunk. Kembalikan jumlah baris tersisip."""
    async with conn.transaction():
        await conn.execute("select pg_advisory_xact_lock($1)", node_lock_key(node_id))
        inserted = 0
        if rows:
            args = [
                node_id,
                plot_id,
                [r.ts_raw for r in rows],
                [r.clk for r in rows],
                [r.uptime_s for r in rows],
                [r.flags for r in rows],
                [r.quality_flag for r in rows],
                *[[r.sensors[c] for r in rows] for c in _SENSOR_COLS],
                [r.rain_tips for r in rows],
            ]
            inserted = len(await conn.fetch(_INSERT_READINGS, *args))
        await insert_rejects(conn, node_id, endpoint, rejects)
    return inserted


async def ingest_events(
    conn: asyncpg.Connection,
    node_id: uuid.UUID,
    rows: list[ClockEvent],
    rejects: list[Reject],
    endpoint: str,
) -> tuple[int, int]:
    """Kembalikan (event tersisip, baris readings + aksi yang dikoreksi ulang)."""
    async with conn.transaction():
        await conn.execute("select pg_advisory_xact_lock($1)", node_lock_key(node_id))
        inserted_segments: list[str] = []
        corrected = 0
        if rows:
            recs = await conn.fetch(
                _INSERT_EVENTS,
                node_id,
                [e.clk for e in rows],
                [e.rtc_before for e in rows],
                [e.ref_time for e in rows],
                [e.delta_s for e in rows],
                [e.start_verified for e in rows],
                [e.seg_start for e in rows],
                [e.ref_source for e in rows],
            )
            inserted_segments = [r["clock_segment"] for r in recs]
        if inserted_segments:
            for sql in (_RECORRECT_READINGS, _RECORRECT_IRRIGATION, _RECORRECT_FERTIGATION):
                status = await conn.execute(sql, node_id, inserted_segments)
                corrected += int(status.split()[-1])
        await insert_rejects(conn, node_id, endpoint, rejects)
    return len(inserted_segments), corrected
