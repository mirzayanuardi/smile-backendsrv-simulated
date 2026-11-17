"""Kanal aktuator: GET /v1/commands dan POST /v1/ingest/actuations.

Kontrak: docs/INTEGRASI_AKTUATOR_SMILE_v8.md bagian 4. Format baris T/G/C,
kolom CSV, dan pemetaan status di sini TIDAK boleh diubah tanpa mengubah
firmware.
"""

from __future__ import annotations

import logging
import time
import uuid
from dataclasses import dataclass, field
from datetime import timedelta

import asyncpg

from .csvparse import Actuation, Reject
from .db import insert_rejects, node_lock_key, touch_node

log = logging.getLogger("smile.actuator")

MAX_COMMANDS_PER_POLL = 4

# Status akhir: laporan yang datang belakangan tidak boleh menimpanya.
FINAL_STATUSES = ("executed", "stopped", "interrupted", "rejected", "expired", "cancelled")

# §4.3: status ESP -> actuator_commands.status
COMMAND_STATUS = {
    "executed": "executed",
    "stopped": "stopped",
    "interrupted": "interrupted",
    "rejected_limit": "rejected",
    "rejected_unsafe": "rejected",
    "rejected_invalid": "rejected",
    "expired": "expired",
}
# §4.3: status ESP -> execution_status (hanya status yang punya baris riwayat)
EXECUTION_STATUS = {"executed": "success", "stopped": "overridden", "interrupted": "failed"}


# ---------------------------------------------------------------------------
# Skema: nama tipe enum dan labelnya dibaca dari katalog saat pertama dipakai
# ---------------------------------------------------------------------------

@dataclass
class ActuatorSchema:
    trigger_type: str            # irrigation_actions.triggered_by
    valve_action_type: str       # irrigation_actions.valve_action
    irr_exec_type: str           # irrigation_actions.execution_status
    fert_exec_type: str          # fertigation_actions.execution_status
    executed_by_type: str        # fertigation_actions.executed_by
    executed_by_labels: frozenset[str]
    recommendation_labels: frozenset[str]
    # Dispatcher fertigasi mengisi fertigation_recommendations.nutrient_batch_id.
    can_mark_recommendation_batch: bool = False


_SCHEMA_SQL = """
select c.relname as tbl, a.attname as col,
       quote_ident(n.nspname) || '.' || quote_ident(t.typname) as typ,
       array(select e.enumlabel::text from pg_enum e
             where e.enumtypid = t.oid order by e.enumsortorder) as labels
from pg_attribute a
join pg_class c on c.oid = a.attrelid
join pg_type t on t.oid = a.atttypid
join pg_namespace n on n.oid = t.typnamespace
where a.attrelid in ('public.irrigation_actions'::regclass, 'public.fertigation_actions'::regclass,
                     'public.fertigation_recommendations'::regclass)
  and a.attname in ('triggered_by', 'valve_action', 'execution_status', 'executed_by', 'status')
  and not a.attisdropped
"""


_REC_BATCH_PRIVILEGE = """
select coalesce(has_column_privilege('public.fertigation_recommendations', 'nutrient_batch_id', 'UPDATE'),
                false)
"""


async def load_schema(conn: asyncpg.Connection) -> ActuatorSchema:
    cols = {(r["tbl"], r["col"]): r for r in await conn.fetch(_SCHEMA_SQL)}

    def typ(tbl: str, col: str) -> str:
        return cols[(tbl, col)]["typ"]

    def labels(tbl: str, col: str) -> frozenset[str]:
        r = cols.get((tbl, col))
        return frozenset(r["labels"]) if r else frozenset()

    return ActuatorSchema(
        trigger_type=typ("irrigation_actions", "triggered_by"),
        valve_action_type=typ("irrigation_actions", "valve_action"),
        irr_exec_type=typ("irrigation_actions", "execution_status"),
        fert_exec_type=typ("fertigation_actions", "execution_status"),
        executed_by_type=typ("fertigation_actions", "executed_by"),
        executed_by_labels=labels("fertigation_actions", "executed_by"),
        recommendation_labels=labels("fertigation_recommendations", "status"),
        can_mark_recommendation_batch=await conn.fetchval(_REC_BATCH_PRIVILEGE),
    )


@dataclass
class FertigationSettings:
    """Keputusan tim (§9 no. 6). Default kosong: executed_by NULL, fertigasi auto mati."""

    executed_by: dict[str, str] = field(default_factory=dict)  # trigger -> label enum
    auto_statuses: frozenset[str] = frozenset()

    @classmethod
    def from_env(cls, executed_by: str, auto_statuses: str) -> "FertigationSettings":
        mapping = {}
        for part in executed_by.split(","):
            k, sep, v = part.partition("=")
            if sep and k.strip() and v.strip():
                mapping[k.strip()] = v.strip()
        statuses = frozenset(s.strip() for s in auto_statuses.split(",") if s.strip())
        return cls(mapping, statuses)

    def validated(self, schema: ActuatorSchema) -> "FertigationSettings":
        """Buang label yang tidak ada di enum database (jangan menebak)."""
        mapping = {}
        for k, v in self.executed_by.items():
            if v in schema.executed_by_labels:
                mapping[k] = v
            else:
                log.warning("FERTIGATION_EXECUTED_BY: label %r tidak ada di enum %s, diabaikan",
                            v, schema.executed_by_type)
        statuses = frozenset(s for s in self.auto_statuses if s in schema.recommendation_labels)
        for s in self.auto_statuses - statuses:
            log.warning("FERTIGATION_AUTO_STATUSES: status %r tidak ada di enum, diabaikan", s)
        if statuses and not schema.can_mark_recommendation_batch:
            # Tanpa hak ini setiap siklus gagal di UPDATE dan irigasi auto ikut terhenti.
            log.warning("fertigasi auto dimatikan: smile_ingest tidak punya UPDATE "
                        "(nutrient_batch_id) di fertigation_recommendations")
            statuses = frozenset()
        return FertigationSettings(mapping, statuses)


class ActuatorContext:
    """Skema enum + pengaturan fertigasi tervalidasi, dimuat sekali per proses."""

    def __init__(self, fert: FertigationSettings) -> None:
        self._fert_env = fert
        self.schema: ActuatorSchema | None = None
        self.fert: FertigationSettings | None = None

    async def ensure(self, conn: asyncpg.Connection) -> tuple[ActuatorSchema, FertigationSettings]:
        if self.schema is None or self.fert is None:
            schema = await load_schema(conn)
            self.fert = self._fert_env.validated(schema)
            self.schema = schema
            log.info("actuator schema loaded: executed_by=%s labels=%s, fertigation auto statuses=%s",
                     self.fert.executed_by or "NULL", sorted(schema.executed_by_labels),
                     sorted(self.fert.auto_statuses) or "none (disabled)")
        return self.schema, self.fert


# ---------------------------------------------------------------------------
# GET /v1/commands
# ---------------------------------------------------------------------------

@dataclass
class XAct:
    w: bool | None = None
    d: bool | None = None
    cmd: uuid.UUID | None = None
    cfg: int | None = None


def parse_xact(header: str | None) -> XAct:
    """Bagian yang hilang atau rusak diabaikan satu per satu, tidak pernah error."""
    out = XAct()
    if not header:
        return out
    for part in header.split(";"):
        key, _, value = part.strip().partition("=")
        value = value.strip()
        if key in ("w", "d") and value in ("0", "1"):
            setattr(out, key, value == "1")
        elif key == "cmd" and value != "-":
            try:
                out.cmd = uuid.UUID(value)
            except ValueError:
                pass
        elif key == "cfg" and value.isdigit() and len(value) <= 9:
            out.cfg = int(value)
    return out


_UPDATE_VALVE = """
update public.nodes set valve_is_on = $2, valve_updated_at = now()
 where id = $1 and valve_is_on is distinct from $2
"""
_UPDATE_PUMP = """
update public.nodes set pump_is_on = $2, pump_updated_at = now()
 where id = $1 and pump_is_on is distinct from $2
"""
_MARK_RUNNING = """
update public.actuator_commands set status = 'running', started_at = now()
 where id = $2 and node_id = $1 and status = 'sent'
"""
_CONFIG_IF_CHANGED = """
select config_version, max_run_s, max_water_day_s, max_dose_day_s, min_gap_s, prewet_s, flush_s,
       fallback_threshold_raw, fallback_run_s, fallback_offline_h,
       morning_start_hour, morning_end_hour, stop_moisture_raw
  from public.node_actuator_config
 where node_id = $1 and config_version is distinct from $2::integer
"""
_TAKE_PENDING = f"""
with picked as (
  select id from public.actuator_commands
   where node_id = $1 and status = 'pending' and expires_at > now()
   order by created_at
   limit {MAX_COMMANDS_PER_POLL}
   for update skip locked
)
update public.actuator_commands c
   set status = 'sent', sent_at = now()
  from picked
 where c.id = picked.id
returning c.id, c.command, c.trigger, c.water_s, c.dose_s, c.created_at,
          greatest(1, floor(extract(epoch from c.expires_at - now())))::integer as ttl_s
"""


async def poll_commands(
    conn: asyncpg.Connection,
    node_id: uuid.UUID,
    act: XAct,
    touch: bool,
    firmware: str | None,
) -> tuple[asyncpg.Record | None, list[asyncpg.Record]]:
    """Satu transaksi: status pompa, running, ambil perintah. Kembalikan (config, perintah)."""
    async with conn.transaction():
        if touch:
            await touch_node(conn, node_id, firmware)
        if act.w is not None:
            await conn.execute(_UPDATE_VALVE, node_id, act.w)
        if act.d is not None:
            await conn.execute(_UPDATE_PUMP, node_id, act.d)
        if act.cmd is not None:
            await conn.execute(_MARK_RUNNING, node_id, act.cmd)
        config = await conn.fetchrow(_CONFIG_IF_CHANGED, node_id, act.cfg)
        commands = sorted(await conn.fetch(_TAKE_PENDING, node_id), key=lambda r: r["created_at"])
    return config, commands


def _num(v: float) -> str:
    return str(int(v)) if float(v).is_integer() else format(v, "g")


def format_commands(config: asyncpg.Record | None, commands: list[asyncpg.Record]) -> str:
    lines = [f"T {int(time.time())}"]
    if config is not None:
        thr = config["fallback_threshold_raw"]
        stop = config["stop_moisture_raw"]
        lines.append(
            f"G {config['config_version']}"
            f" max_run={config['max_run_s']}"
            f" max_water_day={config['max_water_day_s']}"
            f" max_dose_day={config['max_dose_day_s']}"
            f" min_gap={config['min_gap_s']}"
            f" prewet={config['prewet_s']}"
            f" flush={config['flush_s']}"
            f" fb_thr={-1 if thr is None else _num(thr)}"
            f" fb_run={config['fallback_run_s']}"
            f" fb_off_h={config['fallback_offline_h']}"
            f" m_start={config['morning_start_hour']}"
            f" m_end={config['morning_end_hour']}"
            f" stop_thr={-1 if stop is None else _num(stop)}"  # rem jenuh (v11), mentah
        )
    for c in commands:
        lines.append(
            f"C {c['id']} {c['command']} {c['trigger']} "
            f"{c['water_s'] or 0} {c['dose_s'] or 0} {c['ttl_s']}"
        )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# POST /v1/ingest/actuations
# ---------------------------------------------------------------------------

_CORRECT_TS = """
select u.i, public.smile_corrected_ts(u.ts_raw, e.delta_s, e.start_verified, e.segment_start, e.rtc_before) as ts
from unnest($2::timestamptz[], $3::text[]) with ordinality as u(ts_raw, clk, i)
left join public.clock_events e on e.node_id = $1 and e.clock_segment = u.clk
"""
_NODE_FLOW = """
select water_flow_lpm, dose_flow_ml_per_s from public.node_actuator_config where node_id = $1
"""
_FETCH_COMMANDS = """
select id, command, trigger, irrigation_prediction_id, fertigation_recommendation_id,
       nutrient_batch_id
  from public.actuator_commands
 where node_id = $1 and id = any($2::uuid[])
 for update
"""
_UPDATE_COMMAND = """
update public.actuator_commands
   set status = $2,
       result_detail = $3,
       actual_water_s = $4,
       actual_dose_s = $5,
       started_at = case when $6::timestamptz is null then started_at else coalesce(started_at, $6) end,
       finished_at = $7
 where id = $1 and status <> all($8::text[])
returning 1
"""


def _insert_irrigation_sql(s: ActuatorSchema) -> str:
    return f"""
insert into public.irrigation_actions (
  node_id, plot_id, command_id, device_event_id, action_timestamp, action_timestamp_raw,
  clock_segment, triggered_by, valve_action, duration_sec, estimated_volume_liter,
  execution_status, irrigation_prediction_id, detail
) values (
  $1, $2, $3, $4, $5, $6, $7, $8::text::{s.trigger_type}, 'open'::{s.valve_action_type},
  $9, $10, $11::text::{s.irr_exec_type}, $12, $13
)
on conflict (node_id, device_event_id) where device_event_id is not null do nothing
returning 1
"""


def _insert_fertigation_sql(s: ActuatorSchema) -> str:
    return f"""
insert into public.fertigation_actions (
  node_id, plot_id, command_id, device_event_id, execution_timestamp, execution_timestamp_raw,
  clock_segment, recommendation_id, actual_duration_sec, actual_volume, pump_action,
  execution_status, executed_by, detail, nutrient_batch_id
) values (
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'on',
  $11::text::{s.fert_exec_type}, $12::text::{s.executed_by_type}, $13, $14
)
on conflict (node_id, device_event_id) where device_event_id is not null do nothing
returning 1
"""


def _result_detail(a: Actuation) -> str | None:
    if a.status.startswith("rejected_"):
        return f"{a.status}:{a.detail}" if a.detail else a.status
    return a.detail


async def ingest_actuations(
    conn: asyncpg.Connection,
    node_id: uuid.UUID,
    plot_id,
    rows: list[Actuation],
    rejects: list[Reject],
    endpoint: str,
    schema: ActuatorSchema,
    fert: FertigationSettings,
) -> int:
    """Satu transaksi untuk seluruh chunk. Kembalikan jumlah baris yang menghasilkan
    perubahan baru (riwayat tersisip atau status perintah diperbarui).

    Masalah per baris (cmd_id bukan milik node, command tidak cocok) ditambahkan ke
    `rejects` dan dicatat di ingest_rejects, request tetap sukses."""
    applied = 0
    async with conn.transaction():
        await conn.execute("select pg_advisory_xact_lock($1)", node_lock_key(node_id))
        if rows:
            corrected = {
                r["i"]: r["ts"]
                for r in await conn.fetch(
                    _CORRECT_TS, node_id, [a.ts_start for a in rows], [a.clk for a in rows]
                )
            }
            flow = await conn.fetchrow(_NODE_FLOW, node_id)
            water_lpm = flow["water_flow_lpm"] if flow else None
            dose_mlps = flow["dose_flow_ml_per_s"] if flow else None
            cmd_ids = list({a.cmd_id for a in rows if a.cmd_id is not None})
            commands = (
                {r["id"]: r for r in await conn.fetch(_FETCH_COMMANDS, node_id, cmd_ids)}
                if cmd_ids else {}
            )
            ins_irr = _insert_irrigation_sql(schema)
            ins_fert = _insert_fertigation_sql(schema)

            for i, a in enumerate(rows, start=1):
                cmd = None
                if a.cmd_id is not None:
                    cmd = commands.get(a.cmd_id)
                    if cmd is None:
                        rejects.append(Reject(a.line, "cmd_id: unknown command for this node", a.raw))
                        continue
                    if cmd["command"] != a.command:
                        rejects.append(Reject(a.line, "command: does not match cmd_id", a.raw))
                        continue

                ts = corrected[i]
                triggered_by = cmd["trigger"] if cmd else a.trigger
                changed = False

                exec_status = EXECUTION_STATUS.get(a.status)
                if a.command != "stop" and exec_status is not None:
                    # Fertigasi juga tercatat sebagai irigasi: water_s = basahi + suntik + bilas.
                    volume = (
                        a.water_s / 60 * water_lpm
                        if a.water_s is not None and water_lpm is not None else None
                    )
                    got = await conn.fetchval(
                        ins_irr, node_id, plot_id, a.cmd_id, a.ev_id, ts, a.ts_start, a.clk,
                        triggered_by, a.water_s, volume, exec_status,
                        cmd["irrigation_prediction_id"] if cmd else None,
                        "fertigasi" if a.command == "fertigate" else a.detail,
                    )
                    changed = changed or got is not None
                    if a.command == "fertigate":
                        dose_l = (
                            a.dose_s * dose_mlps / 1000
                            if a.dose_s is not None and dose_mlps is not None else None
                        )
                        got = await conn.fetchval(
                            ins_fert, node_id, plot_id, a.cmd_id, a.ev_id, ts, a.ts_start, a.clk,
                            cmd["fertigation_recommendation_id"] if cmd else None,
                            a.dose_s, dose_l, exec_status,
                            fert.executed_by.get(triggered_by), a.detail,
                            cmd["nutrient_batch_id"] if cmd else None,
                        )
                        changed = changed or got is not None

                if cmd is not None:
                    ran = exec_status is not None
                    duration = max(a.water_s or 0, a.dose_s or 0)
                    got = await conn.fetchval(
                        _UPDATE_COMMAND, cmd["id"], COMMAND_STATUS[a.status], _result_detail(a),
                        a.water_s, a.dose_s, ts if ran else None,
                        ts + timedelta(seconds=duration), list(FINAL_STATUSES),
                    )
                    changed = changed or got is not None

                applied += changed

        await insert_rejects(conn, node_id, endpoint, rejects)
    return applied
