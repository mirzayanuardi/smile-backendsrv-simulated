"""Parsing dan validasi CSV dari node.

Aturan utama: masalah per baris TIDAK menggagalkan request. Fungsi di sini
hanya melempar BadRequest untuk masalah level-request (header CSV salah,
body bukan UTF-8). Masalah per baris dikembalikan sebagai daftar Reject.
"""

from __future__ import annotations

import math
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

READINGS_HEADER = (
    "ts_raw,up,clk,flags,soil_t,soil_m,soil_ec,soil_ph,"
    "soil_n,soil_p,soil_k,air_t,air_h,rain_mm,rain_tips"
)
EVENTS_HEADER = "clk,rtc_before,ref_time,delta_s,start_verified,seg_start,ref_source"
ACTUATIONS_HEADER = "ev_id,cmd_id,command,trigger,clk,ts_start,water_s,dose_s,status,detail"

READINGS_FIELDS = 15
EVENTS_FIELDS = 7
ACTUATIONS_FIELDS = 10

ACT_COMMANDS = ("irrigate", "fertigate", "stop")
ACT_TRIGGERS = ("manual", "rule_engine", "schedule", "local_fallback")
ACT_STATUSES = (
    "executed", "stopped", "interrupted",
    "rejected_limit", "rejected_unsafe", "rejected_invalid", "expired",
)
MAX_DETAIL = 64

INT32_MAX = 2**31 - 1
INT64_MAX = 2**63 - 1
# Batas atas untuk nilai tanpa batas di spesifikasi (rain_mm). Bukan validasi
# ilmiah: hanya penjaga supaya angka absurd tidak membuat INSERT gagal dan
# node mengulang chunk yang sama selamanya.
FLOAT_SANITY_MAX = 1e9

FUTURE_TOLERANCE = timedelta(minutes=10)
MAX_RAW_LINE = 1000

_TS_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"
)
_TS_NO_OFFSET_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?$")
_CLK_RE = re.compile(r"^[0-9a-f]{8}$")
_INT_RE = re.compile(r"^[+-]?\d+$")
_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

# (nama CSV, kolom DB, min, max). max None = tanpa batas atas.
FLOAT_SENSORS: list[tuple[str, str, float, float | None]] = [
    ("soil_t", "soil_temperature_c", -20, 80),
    ("soil_m", "soil_moisture_pct", 0, 100),
    ("soil_ec", "soil_ec_uscm", 0, 20000),
    ("soil_ph", "soil_ph", 0, 14),
    ("soil_n", "soil_n_mgkg", 0, 2000),
    ("soil_p", "soil_p_mgkg", 0, 2000),
    ("soil_k", "soil_k_mgkg", 0, 2000),
    ("air_t", "air_temperature_c", -20, 70),
    ("air_h", "air_humidity_pct", 0, 100),
    ("rain_mm", "rainfall_mm", 0, None),
]

FLAG_NAMES = [(4, "soil_fail"), (8, "sht_fail"), (16, "rain_fail"), (32, "rtc_read_fail")]
FLAG_TIME_UNVERIFIED = 1


class BadRequest(Exception):
    """Masalah level-request -> HTTP 400."""


@dataclass
class Reject:
    line: int
    reason: str
    raw: str


@dataclass
class Reading:
    ts_raw: datetime
    uptime_s: int
    clk: str
    flags: int
    sensors: dict[str, float | None]  # kolom DB -> nilai
    rain_tips: int | None
    quality_flag: str | None


@dataclass
class ClockEvent:
    clk: str
    rtc_before: datetime
    ref_time: datetime
    delta_s: int
    start_verified: bool
    seg_start: datetime | None
    ref_source: str


@dataclass
class Actuation:
    line: int
    raw: str
    ev_id: str
    cmd_id: uuid.UUID | None
    command: str
    trigger: str
    clk: str
    ts_start: datetime
    water_s: int | None
    dose_s: int | None
    status: str
    detail: str | None


@dataclass
class Parsed:
    rows: list = field(default_factory=list)
    rejects: list[Reject] = field(default_factory=list)


class _LineError(Exception):
    pass


def _parse_ts(name: str, value: str) -> datetime:
    if not _TS_RE.match(value):
        if _TS_NO_OFFSET_RE.match(value):
            raise _LineError(f"{name}: missing offset")
        raise _LineError(f"{name}: not ISO 8601")
    try:
        ts = datetime.fromisoformat(value)
    except ValueError:
        raise _LineError(f"{name}: invalid date/time") from None
    if not 2024 <= ts.year <= 2099:
        raise _LineError(f"{name}: year out of range 2024-2099")
    return ts


def _parse_int(name: str, value: str, lo: int, hi: int) -> int:
    if not _INT_RE.match(value):
        raise _LineError(f"{name}: not an integer")
    n = int(value)
    if not lo <= n <= hi:
        raise _LineError(f"{name}: out of range")
    return n


def _parse_clk(value: str) -> str:
    if not _CLK_RE.match(value):
        raise _LineError("clk: must be 8 lowercase hex chars")
    return value


def _split_body(body: bytes, header: str) -> list[tuple[int, str]]:
    """Kembalikan [(nomor_baris, isi)] untuk baris data. Header = baris 1."""
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        raise BadRequest("body is not UTF-8") from None
    lines = text.split("\n")
    first = lines[0].rstrip("\r")
    if first != header:
        raise BadRequest("CSV header mismatch")
    out = []
    for idx, line in enumerate(lines[1:], start=2):
        line = line.rstrip("\r")
        if line.strip() == "":
            continue
        out.append((idx, line))
    return out


def _sensor_value(name: str, raw: str, lo: float, hi: float | None, notes: list[str]) -> float | None:
    if raw == "":
        return None
    try:
        v = float(raw)
    except ValueError:
        notes.append(f"bad:{name}={raw[:20]}")
        return None
    if not math.isfinite(v):
        notes.append(f"bad:{name}={raw[:20]}")
        return None
    upper = hi if hi is not None else FLOAT_SANITY_MAX
    if v < lo or v > upper:
        notes.append(f"oor:{name}={raw[:20]}")
        return None
    return v


def _parse_reading(fields: list[str], now: datetime) -> Reading:
    if len(fields) != READINGS_FIELDS:
        raise _LineError(f"expected {READINGS_FIELDS} fields, got {len(fields)}")
    ts_raw = _parse_ts("ts_raw", fields[0])
    uptime = _parse_int("up", fields[1], 0, INT64_MAX)
    clk = _parse_clk(fields[2])
    flags = _parse_int("flags", fields[3], 0, INT32_MAX)

    if not flags & FLAG_TIME_UNVERIFIED and ts_raw > now + FUTURE_TOLERANCE:
        raise _LineError("ts_raw: more than 10 min in the future")

    notes = [name for bit, name in FLAG_NAMES if flags & bit]
    sensors: dict[str, float | None] = {}
    for i, (name, col, lo, hi) in enumerate(FLOAT_SENSORS, start=4):
        sensors[col] = _sensor_value(name, fields[i], lo, hi, notes)

    tips_raw = fields[14]
    rain_tips: int | None = None
    if tips_raw != "":
        if not _INT_RE.match(tips_raw):
            notes.append(f"bad:rain_tips={tips_raw[:20]}")
        else:
            n = int(tips_raw)
            if 0 <= n <= INT32_MAX:
                rain_tips = n
            else:
                notes.append(f"oor:rain_tips={tips_raw[:20]}")

    return Reading(
        ts_raw=ts_raw,
        uptime_s=uptime,
        clk=clk,
        flags=flags,
        sensors=sensors,
        rain_tips=rain_tips,
        quality_flag=",".join(notes) or None,
    )


def _parse_event(fields: list[str]) -> ClockEvent:
    if len(fields) != EVENTS_FIELDS:
        raise _LineError(f"expected {EVENTS_FIELDS} fields, got {len(fields)}")
    clk = _parse_clk(fields[0])
    rtc_before = _parse_ts("rtc_before", fields[1])
    ref_time = _parse_ts("ref_time", fields[2])
    delta = _parse_int("delta_s", fields[3], -INT32_MAX, INT32_MAX)
    if fields[4] not in ("0", "1"):
        raise _LineError("start_verified: must be 0 or 1")
    seg_start = _parse_ts("seg_start", fields[5]) if fields[5] != "" else None
    if fields[6] not in ("ntp", "server"):
        raise _LineError("ref_source: must be ntp or server")
    return ClockEvent(
        clk=clk,
        rtc_before=rtc_before,
        ref_time=ref_time,
        delta_s=delta,
        start_verified=fields[4] == "1",
        seg_start=seg_start,
        ref_source=fields[6],
    )


def _parse_seconds(name: str, value: str) -> int | None:
    if value == "":
        return None
    return _parse_int(name, value, 0, INT32_MAX)


def _parse_actuation(line_no: int, line: str, fields: list[str]) -> Actuation:
    if len(fields) != ACTUATIONS_FIELDS:
        raise _LineError(f"expected {ACTUATIONS_FIELDS} fields, got {len(fields)}")
    ev_id, cmd_raw, command, trigger, clk, ts, water, dose, status, detail = fields
    if not _CLK_RE.match(ev_id):
        raise _LineError("ev_id: must be 8 lowercase hex chars")
    cmd_id = None
    if cmd_raw != "":
        if not _UUID_RE.match(cmd_raw):
            raise _LineError("cmd_id: not a UUID")
        cmd_id = uuid.UUID(cmd_raw)
    if command not in ACT_COMMANDS:
        raise _LineError("command: must be irrigate, fertigate or stop")
    if trigger not in ACT_TRIGGERS:
        raise _LineError("trigger: must be manual, rule_engine, schedule or local_fallback")
    if trigger == "local_fallback" and cmd_id is not None:
        raise _LineError("cmd_id: must be empty for local_fallback")
    clk = _parse_clk(clk)
    ts_start = _parse_ts("ts_start", ts)
    water_s = _parse_seconds("water_s", water)
    dose_s = _parse_seconds("dose_s", dose)
    if status not in ACT_STATUSES:
        raise _LineError("status: unknown value")
    if len(detail) > MAX_DETAIL:
        raise _LineError(f"detail: longer than {MAX_DETAIL} chars")
    return Actuation(
        line=line_no,
        raw=line[:MAX_RAW_LINE],
        ev_id=ev_id,
        cmd_id=cmd_id,
        command=command,
        trigger=trigger,
        clk=clk,
        ts_start=ts_start,
        water_s=water_s,
        dose_s=dose_s,
        status=status,
        detail=detail or None,
    )


def parse_readings(body: bytes, now: datetime | None = None) -> Parsed:
    now = now or datetime.now(timezone.utc)
    out = Parsed()
    for line_no, line in _split_body(body, READINGS_HEADER):
        try:
            out.rows.append(_parse_reading(line.split(","), now))
        except _LineError as e:
            out.rejects.append(Reject(line_no, str(e), line[:MAX_RAW_LINE]))
    return out


def parse_events(body: bytes) -> Parsed:
    out = Parsed()
    for line_no, line in _split_body(body, EVENTS_HEADER):
        try:
            out.rows.append(_parse_event(line.split(",")))
        except _LineError as e:
            out.rejects.append(Reject(line_no, str(e), line[:MAX_RAW_LINE]))
    return out


def parse_actuations(body: bytes) -> Parsed:
    out = Parsed()
    for line_no, line in _split_body(body, ACTUATIONS_HEADER):
        try:
            out.rows.append(_parse_actuation(line_no, line, line.split(",")))
        except _LineError as e:
            out.rejects.append(Reject(line_no, str(e), line[:MAX_RAW_LINE]))
    return out
