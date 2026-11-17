"""Dispatcher mode auto (docs/INTEGRASI_AKTUATOR_SMILE_v8.md §5), tiap 60 detik.

Hanya satu proses yang menjalankan satu siklus pada satu waktu
(pg_try_advisory_xact_lock), jadi aman dengan beberapa worker uvicorn.
Semua perintah masuk lewat trigger smile_guard_actuator_command: kalau
trigger menolak, alasannya dicatat di dispatch_note dan tidak dicoba lagi.
Batas angka (durasi, bilas, kedaluwarsa) tetap milik CHECK/trigger database.
"""

from __future__ import annotations

import asyncio
import logging
import math
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import asyncpg

from .actuator import ActuatorContext, FertigationSettings
from .jsonlog import log_json

log = logging.getLogger("smile.dispatcher")

WIB = timezone(timedelta(hours=7))
DISPATCH_LOCK_KEY = int.from_bytes(b"smiledsp", "big", signed=True)
MIN_RUN_S = 5          # §5: di bawah 5 s -> too_small
MAX_DOSE_S = 300       # §5: dose_s maks 300 (format lama, pump_duration_seconds)

_EXPIRE = """
update public.actuator_commands
   set status = 'expired', finished_at = now(), result_detail = 'not_fetched'
 where status = 'pending' and expires_at <= now()
returning id, node_id
"""

_IRRIGATION_CANDIDATES = """
select n.id as node_id, n.plot_id, c.water_flow_lpm, c.wetted_area_m2, c.max_run_s, c.min_gap_s,
       c.morning_start_hour, c.morning_end_hour,
       p.id as ref_id, p.recommended_irrigation_mm, p.reason
from public.nodes n
join public.node_actuator_config c on c.node_id = n.id
join lateral (
  select p.id, p.recommended_irrigation_mm, p.reason
    from public.irrigation_predictions p
   where p.plot_id = n.plot_id
     and p.irrigation_triggered
     and p.recommended_irrigation_mm > 0
     and p.dispatched_command_id is null
     and p.dispatch_note is null
     and p.created_at > now() - interval '30 minutes'
   order by p.created_at desc
   limit 1
) p on true
where n.valve_mode = 'auto'
  and c.has_irrigation
  and c.water_flow_lpm is not null
  and c.wetted_area_m2 is not null
order by n.id
"""

_FERTIGATION_CANDIDATES = """
select n.id as node_id, n.plot_id, c.max_run_s, c.prewet_s, c.flush_s, c.dose_flow_ml_per_s,
       r.id as ref_id, r.pump_duration_seconds, r.target_n_g, r.target_p2o5_g, r.target_k2o_g, r.reason
from public.nodes n
join public.node_actuator_config c on c.node_id = n.id
join lateral (
  select r.id, r.pump_duration_seconds, r.target_n_g, r.target_p2o5_g, r.target_k2o_g, r.reason
    from public.fertigation_recommendations r
   where r.plot_id = n.plot_id
     and r.status::text = any($1::text[])
     and r.dispatched_command_id is null
     and r.dispatch_note is null
     and r.created_at > now() - interval '30 minutes'
   order by r.created_at desc
   limit 1
) r on true
where n.pump_mode = 'auto'
  and c.has_fertigation
order by n.id
"""

# Sama dengan anti tumpuk di trigger: perintah aksi pending/sent yang belum kedaluwarsa.
_BUSY = """
select exists (
  select 1 from public.actuator_commands
   where node_id = $1 and command <> 'stop'
     and status in ('pending', 'sent') and expires_at > now())
"""

# Irigasi terakhir: riwayat dari ESP, atau perintah yang sudah mulai tapi belum dilaporkan.
_WITHIN_MIN_GAP = """
select greatest(
         (select max(action_timestamp) from public.irrigation_actions where node_id = $1),
         (select max(started_at) from public.actuator_commands
           where node_id = $1 and command <> 'stop' and started_at is not null)
       ) > now() - make_interval(secs => $2)
"""

# Paling banyak satu larutan aktif per node (uq_nutrient_batches_one_active).
_ACTIVE_BATCH = """
select id from public.nutrient_batches where node_id = $1 and is_active
"""

_DOSE_SECONDS = "select public.smile_dose_seconds($1, $2, $3, $4, $5)"

# created_by diisi NULL eksplisit: default auth.uid() tidak bisa dievaluasi oleh
# smile_ingest (tidak punya USAGE di schema auth).
_INSERT_COMMAND = """
insert into public.actuator_commands (
  node_id, plot_id, command, water_s, dose_s, trigger,
  irrigation_prediction_id, fertigation_recommendation_id, reason, nutrient_batch_id, created_by
) values ($1, $2, $3, $4, $5, 'rule_engine', $6, $7, $8, $9, null)
returning id
"""

# $3 = larutan yang dipakai menghitung dosis (hanya fertigasi).
_MARK = {
    "irrigation": (
        "update public.irrigation_predictions set dispatched_command_id = $2 where id = $1",
        "update public.irrigation_predictions set dispatch_note = $2 where id = $1",
    ),
    "fertigation": (
        "update public.fertigation_recommendations"
        " set dispatched_command_id = $2, nutrient_batch_id = coalesce($3, nutrient_batch_id) where id = $1",
        "update public.fertigation_recommendations"
        " set dispatch_note = $2, nutrient_batch_id = coalesce($3, nutrient_batch_id) where id = $1",
    ),
}


def round_half_up(x: float) -> int:
    return int(math.floor(x + 0.5))


def irrigation_seconds(mm: float, area_m2: float, flow_lpm: float) -> float:
    """§5: t = I x A / Q x 60 (1 mm x 1 m2 = 1 L)."""
    return mm * area_m2 / flow_lpm * 60


def in_morning_window(now: datetime, start_hour: int, end_hour: int) -> bool:
    return start_hour <= now.astimezone(WIB).hour < end_hour


@dataclass
class Decision:
    channel: str
    node_id: uuid.UUID
    ref_id: uuid.UUID
    result: str                    # dispatched/clamped/outside_window/min_gap/too_small/busy/rejected,
                                   # fertigasi: no_active_batch/dose_uncomputable/dose_too_long
    command_id: uuid.UUID | None = None
    water_s: int | None = None
    dose_s: int | None = None
    note: str | None = None
    batch_id: uuid.UUID | None = None


@dataclass
class Plan:
    water_s: int | None = None
    dose_s: int | None = None
    clamped_from: int | None = None
    too_small: bool = False
    too_long: bool = False


def plan_irrigation(row) -> Plan:
    t = round_half_up(irrigation_seconds(row["recommended_irrigation_mm"], row["wetted_area_m2"],
                                         row["water_flow_lpm"]))
    if t < MIN_RUN_S:
        return Plan(too_small=True)
    if t > row["max_run_s"]:
        return Plan(water_s=row["max_run_s"], clamped_from=t)
    return Plan(water_s=t)


def has_targets(row) -> bool:
    """Rekomendasi format baru membawa target gram; format lama hanya pump_duration_seconds."""
    return any(row[k] is not None for k in ("target_n_g", "target_p2o5_g", "target_k2o_g"))


def plan_fertigation(row, dose_s: int | None) -> Plan:
    """dose_s dari smile_dose_seconds (format baru); None = pakai pump_duration_seconds.

    Air total = basahi + suntik + bilas. Kalau tidak muat di max_run_s, dosis tidak
    dipotong (pupuk jadi kurang tanpa ketahuan): perintah tidak dikirim."""
    clamped_from = None
    if dose_s is None:
        if row["pump_duration_seconds"] is None:
            return Plan(too_small=True)
        asked = round_half_up(row["pump_duration_seconds"])
        dose_s = min(asked, MAX_DOSE_S)
        clamped_from = asked if dose_s < asked else None
    if dose_s < 1:
        return Plan(too_small=True)
    water = row["prewet_s"] + dose_s + row["flush_s"]
    if water > row["max_run_s"]:
        return Plan(water_s=water, dose_s=dose_s, too_long=True)
    return Plan(water_s=water, dose_s=dose_s, clamped_from=clamped_from)


async def _decide(conn: asyncpg.Connection, channel: str, row, now: datetime) -> Decision:
    d = Decision(channel, row["node_id"], row["ref_id"], "")
    set_cmd, set_note = _MARK[channel]

    def mark_args() -> tuple:
        return (d.batch_id,) if channel == "fertigation" else ()

    async def note(result: str, text: str | None = None) -> Decision:
        d.result, d.note = result, text or result
        await conn.execute(set_note, row["ref_id"], d.note, *mark_args())
        return d

    if channel == "irrigation":
        if not in_morning_window(now, row["morning_start_hour"], row["morning_end_hour"]):
            return await note("outside_window")
        if await conn.fetchval(_WITHIN_MIN_GAP, row["node_id"], float(row["min_gap_s"])):
            return await note("min_gap")
    if await conn.fetchval(_BUSY, row["node_id"]):
        d.result = "busy"  # coba lagi siklus berikutnya, tidak dicatat
        return d

    if channel == "irrigation":
        plan = plan_irrigation(row)
    else:
        d.batch_id = await conn.fetchval(_ACTIVE_BATCH, row["node_id"])
        if d.batch_id is None:
            return await note("no_active_batch")
        dose_s = None
        if has_targets(row):
            dose_s = await conn.fetchval(
                _DOSE_SECONDS, d.batch_id, row["target_n_g"], row["target_p2o5_g"],
                row["target_k2o_g"], row["dose_flow_ml_per_s"],
            )
            if dose_s is None:
                return await note("dose_uncomputable")
        plan = plan_fertigation(row, dose_s)
    if plan.too_small:
        return await note("too_small")
    d.water_s, d.dose_s = plan.water_s, plan.dose_s
    if plan.too_long:
        return await note("dose_too_long")

    reason = row["reason"]
    if plan.clamped_from is not None:
        unit = "water_s" if channel == "irrigation" else "dose_s"
        got = plan.water_s if channel == "irrigation" else plan.dose_s
        reason = f"{reason or ''} [clamped {unit} {plan.clamped_from}->{got}]".strip()

    try:
        async with conn.transaction():  # savepoint: penolakan trigger tidak membatalkan siklus
            d.command_id = await conn.fetchval(
                _INSERT_COMMAND, row["node_id"], row["plot_id"],
                "irrigate" if channel == "irrigation" else "fertigate",
                plan.water_s, plan.dose_s,
                row["ref_id"] if channel == "irrigation" else None,
                row["ref_id"] if channel == "fertigation" else None,
                reason, d.batch_id,
            )
    except (asyncpg.RaiseError, asyncpg.IntegrityConstraintViolationError) as e:
        return await note("rejected", f"rejected: {e}"[:300])

    await conn.execute(set_cmd, row["ref_id"], d.command_id, *mark_args())
    d.result = "clamped" if plan.clamped_from is not None else "dispatched"
    return d


async def run_cycle(
    conn: asyncpg.Connection,
    fert: FertigationSettings,
    now: datetime | None = None,
) -> dict | None:
    """Satu siklus dalam satu transaksi. None kalau proses lain sedang memegang kunci."""
    now = now or datetime.now(timezone.utc)
    decisions: list[Decision] = []
    async with conn.transaction():
        if not await conn.fetchval("select pg_try_advisory_xact_lock($1)", DISPATCH_LOCK_KEY):
            return None
        expired = await conn.fetch(_EXPIRE)
        for r in expired:
            log_json(event="dispatch_expire", node=r["node_id"], command=r["id"])

        for row in await conn.fetch(_IRRIGATION_CANDIDATES):
            decisions.append(await _decide(conn, "irrigation", row, now))
        if fert.auto_statuses:
            for row in await conn.fetch(_FERTIGATION_CANDIDATES, sorted(fert.auto_statuses)):
                decisions.append(await _decide(conn, "fertigation", row, now))

    for d in decisions:
        log_json(event="dispatch", channel=d.channel, node=d.node_id, ref=d.ref_id, result=d.result,
                 command=d.command_id, water_s=d.water_s, dose_s=d.dose_s, batch=d.batch_id,
                 note=d.note)
    return {"expired": len(expired), "decisions": decisions}


async def run_forever(database, ctx: ActuatorContext, interval_s: float) -> None:
    while True:
        if database.pool is not None:
            try:
                async with database.pool.acquire() as conn:
                    _, fert = await ctx.ensure(conn)
                    await run_cycle(conn, fert)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 - siklus berikutnya mencoba lagi
                log.warning("dispatcher cycle failed: %s: %s", type(e).__name__, e)
        await asyncio.sleep(interval_s)
