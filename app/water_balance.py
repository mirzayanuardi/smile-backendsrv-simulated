"""Neraca air FAO-56 (Layer 1, tanpa ML): buku besar per jam + rule engine irigasi.

Istilah (FAO-56):
- Dr  : defisit air zona akar (mm). 0 = kapasitas lapang (FC), TAW = titik layu (PWP).
- ETo : evapotranspirasi acuan (mm). ETc = Kc x ETo.
- DP  : perkolasi dalam, air yang lolos ke bawah zona akar ketika tanah sudah penuh.
- TAW = (theta_FC - theta_PWP)/100 x Zr ; RAW = p x TAW.

Pembagian tugas: modul ini memutuskan irrigation_triggered dan recommended_irrigation_mm.
Jendela pagi, min_gap, konversi mm -> detik, too_small, dan clamped tetap di dispatcher.
"""

from __future__ import annotations

import asyncio
import bisect
import logging
import math
import os
import statistics
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

import asyncpg

from . import weather
from .dispatcher import WIB, in_morning_window
from .jsonlog import log_json

GSC = 0.0820  # konstanta surya, MJ m-2 menit-1


# ---------------------------------------------------------------------------
# Fungsi murni
# ---------------------------------------------------------------------------

def extraterrestrial_radiation_mj(lat_deg: float, doy: int) -> float:
    """Ra harian (MJ m-2 hari-1), FAO-56 persamaan 21-25."""
    phi = math.radians(lat_deg)
    dr = 1 + 0.033 * math.cos(2 * math.pi * doy / 365)                 # pers. 23
    delta = 0.409 * math.sin(2 * math.pi * doy / 365 - 1.39)          # pers. 24
    ws = math.acos(max(-1.0, min(1.0, -math.tan(phi) * math.tan(delta))))  # pers. 25
    return (24 * 60 / math.pi) * GSC * dr * (                         # pers. 21
        ws * math.sin(phi) * math.sin(delta) + math.cos(phi) * math.cos(delta) * math.sin(ws)
    )


def eto_hargreaves_mm_day(tmin_c: float, tmax_c: float, ra_mj: float) -> float:
    """ETo Hargreaves (mm/hari); 0,408 mengubah MJ m-2 ke mm air. Tidak pernah negatif."""
    if tmax_c < tmin_c:
        tmin_c, tmax_c = tmax_c, tmin_c
    tmean = (tmin_c + tmax_c) / 2
    return max(0.0, 0.0023 * (tmean + 17.8) * math.sqrt(tmax_c - tmin_c) * 0.408 * ra_mj)


def balance_step(dr_start: float, etc: float, rain: float, irrigation: float,
                 taw: float) -> tuple[float, float]:
    """Satu langkah neraca. Kembalikan (dr_model, dp)."""
    x = dr_start - rain - irrigation + etc
    dp = 0.0
    if x < 0:
        dp, x = -x, 0.0
    return min(x, taw), dp


def dr_from_theta(theta_pct: float, theta_fc_pct: float, zr_mm: float, taw: float) -> float:
    """Dr dari kadar air terkalibrasi (% vol): clamp((theta_FC - theta)/100 x Zr, 0, TAW)."""
    return min(max((theta_fc_pct - theta_pct) / 100 * zr_mm, 0.0), taw)


def taw_raw(theta_fc_pct: float, theta_pwp_pct: float, p_frac: float,
            zr_mm: float) -> tuple[float, float, float]:
    """(TAW, RAW, theta pemicu %vol), urutan operasi sama dengan view
    plot_water_params_current supaya hasilnya identik sampai bit terakhir."""
    taw = (theta_fc_pct - theta_pwp_pct) / 100.0 * zr_mm
    raw = p_frac * (theta_fc_pct - theta_pwp_pct) / 100.0 * zr_mm
    return taw, raw, theta_fc_pct - p_frac * (theta_fc_pct - theta_pwp_pct)


def rain_increments(values: list[float | None], prev: float | None = None) -> list[float]:
    """Hujan per baris dari rainfall_mm KUMULATIF sejak boot (firmware rain24hLocked()).

    `prev` = nilai baris terakhir sebelum daftar ini (jam sebelumnya). Aturan firmware:
    kalau nilai turun, sensor ter-reset (listrik putus) dan selisihnya = nilai baru.
    Baris pertama tanpa `prev` tidak punya pembanding, jadi 0. NULL dilewati."""
    out: list[float] = []
    for v in values:
        if v is None:
            continue
        if prev is None:
            out.append(0.0)
        elif v < prev:
            out.append(v)
        else:
            out.append(v - prev)
        prev = v
    return out


# ---------------------------------------------------------------------------
# Keputusan (§4)
# ---------------------------------------------------------------------------

@dataclass
class DecisionInput:
    dr_now: float
    taw: float
    raw: float
    theta_fc_pct: float
    theta_obs_pct: float | None       # terkalibrasi, NULL kalau belum
    theta_obs_age_h: float | None     # umur bacaan theta_obs_pct
    rain_forecast_12h_mm: float
    dr_forecast_24h_mm: float
    in_morning_window: bool
    rain_skip_mm: float = 10.0


@dataclass
class Decision:
    triggered: bool
    recommended_mm: float | None
    code: str                         # soil_at_fc / rain_expected / dr_ge_raw / anticipatory_24h / below_raw
    detail: str                       # kalimat untuk kolom reason


def _mm(x: float) -> str:
    return f"{x:.1f}".replace(".", ",")


def decide(d: DecisionInput) -> Decision:
    """Aturan R1-R5 berurutan; berhenti di yang pertama cocok."""
    dr, raw = d.dr_now, d.raw
    if (d.theta_obs_pct is not None and d.theta_obs_age_h is not None
            and d.theta_obs_age_h <= 2 and d.theta_obs_pct >= d.theta_fc_pct):
        return Decision(False, None, "soil_at_fc",
                        f"θ {_mm(d.theta_obs_pct)} % ≥ θ_FC {_mm(d.theta_fc_pct)} %")
    if d.rain_forecast_12h_mm >= d.rain_skip_mm:
        return Decision(False, None, "rain_expected",
                        f"hujan 12 jam {_mm(d.rain_forecast_12h_mm)} mm ≥ {_mm(d.rain_skip_mm)} mm; "
                        f"Dr {_mm(dr)} mm")
    if dr >= raw:
        return Decision(True, min(dr, d.taw), "dr_ge_raw", f"Dr {_mm(dr)} mm ≥ RAW {_mm(raw)} mm")
    if d.in_morning_window and d.dr_forecast_24h_mm >= raw:
        return Decision(True, min(dr, d.taw), "anticipatory_24h",
                        f"Dr 24 jam {_mm(d.dr_forecast_24h_mm)} mm ≥ RAW {_mm(raw)} mm; Dr {_mm(dr)} mm")
    return Decision(False, None, "below_raw", f"Dr {_mm(dr)} mm < RAW {_mm(raw)} mm")


# ---------------------------------------------------------------------------
# Job terjadwal: buku besar per jam + satu keputusan per plot per siklus
# ---------------------------------------------------------------------------

log = logging.getLogger("smile.water_balance")

HOUR = timedelta(hours=1)
WB_LOCK_KEY = int.from_bytes(b"smilewbl", "big", signed=True)  # beda dengan dispatcher
MAX_BACKFILL_H = 14 * 24        # celah ledger lebih tua dari ini -> mulai ulang (init)
RUN_MINUTE = 5                  # menit ke-5 tiap jam (WIB = UTC+7, menitnya sama)
SETTLE_RAIN_MM = 0.2
MIN_RAIN_ROWS = 30
MIN_THETA_ROWS = 5
MIN_TEMP_HOURS = 18
THETA_WINDOW = timedelta(minutes=15)
THETA_FRESH_H = 2
IRRIGATION_COUNTED = ("success", "overridden")   # irrigation_actions.execution_status
NOMINAL_MM_PER_TIP = 0.28       # konstanta firmware: rainfall_mm = tip x 0,28
# Baris yang jamnya tidak bisa dipercaya jatuh di jam yang benar.
UNTRUSTED_TIME = ("unverified", "legacy")


@dataclass
class WBSettings:
    enabled: bool = True
    recompute_h: int = 48
    correct_every_h: float = 6
    settle_h: int = 2
    rain_skip_mm: float = 10.0
    default_lat: float = -6.595
    default_lng: float = 106.8166

    @classmethod
    def from_env(cls) -> "WBSettings":
        e = os.environ.get
        return cls(
            enabled=e("WB_ENABLED", "1") != "0",
            recompute_h=max(1, int(e("WB_RECOMPUTE_H", "48"))),
            correct_every_h=float(e("WB_CORRECT_EVERY_H", "6")),
            settle_h=max(0, int(e("WB_SETTLE_H", "2"))),
            rain_skip_mm=float(e("WB_RAIN_SKIP_MM", "10")),
            default_lat=float(e("WB_DEFAULT_LAT", "-6.595")),
            default_lng=float(e("WB_DEFAULT_LNG", "106.8166")),
        )


@dataclass
class Params:
    id: uuid.UUID
    theta_fc_pct: float
    theta_pwp_pct: float
    p_frac: float
    zr_mm: float
    kc: float
    valid_from: datetime

    @property
    def taw_raw(self) -> tuple[float, float, float]:
        return taw_raw(self.theta_fc_pct, self.theta_pwp_pct, self.p_frac, self.zr_mm)


@dataclass
class LedgerRow:
    period_start: datetime
    period_end: datetime
    params_id: uuid.UUID
    eto_mm: float
    eto_source: str
    kc: float
    etc_mm: float
    rain_mm: float
    rain_source: str
    irrigation_mm: float
    dp_mm: float
    dr_start_mm: float
    dr_model_mm: float
    theta_obs_raw: float | None
    theta_obs_pct: float | None
    dr_obs_mm: float | None
    dr_end_mm: float
    corrected: bool
    taw_mm: float
    raw_mm: float
    calibration_status: str


@dataclass
class PlotResult:
    plot_id: uuid.UUID
    node_id: uuid.UUID
    rows: list[LedgerRow]
    init: str | None                   # None / 'ledger' / 'observed' / 'init_fc_assumed'
    decision: Decision | None = None
    prediction: dict | None = None     # kolom irrigation_predictions yang akan ditulis
    skipped_duplicate: bool = False
    warnings: list[str] = field(default_factory=list)


# --- SQL ---------------------------------------------------------------------

_ACCESS = """
select has_column_privilege('public.plots', 'location_lat', 'SELECT') as lat,
       has_column_privilege('public.nodes', 'status', 'SELECT')
         and has_column_privilege('public.nodes', 'created_at', 'SELECT') as node_meta,
       exists (select 1 from pg_policies
                where schemaname = 'public' and tablename = 'weather_forecasts'
                  and cmd in ('SELECT', 'ALL')
                  and ('smile_ingest'::name = any(roles) or 'public'::name = any(roles))) as wf_policy,
       coalesce(has_table_privilege(to_regclass('public.weather_forecast_snapshots'), 'SELECT'), false)
         and coalesce(has_table_privilege(to_regclass('public.weather_observed_hourly'), 'SELECT'), false) as wx,
       case when exists (select 1 from pg_attribute
                          where attrelid = 'public.nodes'::regclass and attname = 'rain_mm_per_tip'
                            and not attisdropped)
            then has_column_privilege('public.nodes', 'rain_mm_per_tip', 'SELECT') else false end as rain_factor
"""

_PLOTS = """
select w.plot_id, w.params_id, w.theta_fc_pct, w.theta_pwp_pct, w.p_frac, w.zr_mm, w.kc,
       w.taw_mm, w.raw_mm, w.theta_trigger_pct
  from public.plot_water_params_current w
 where exists (select 1 from public.nodes n
                 join public.node_actuator_config c on c.node_id = n.id
                where n.plot_id = w.plot_id and c.has_irrigation)
 order by w.plot_id
"""

_PLOT_PARAMS_CURRENT = """
select plot_id, params_id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc, taw_mm, raw_mm, theta_trigger_pct
  from public.plot_water_params_current where plot_id = $1
"""


def _nodes_sql(node_meta: bool, rain_factor: bool = False) -> str:
    active = "and coalesce(n.status::text, 'active') = 'active'" if node_meta else ""
    order = "n.created_at, n.id" if node_meta else "n.id"
    factor = "n.rain_mm_per_tip" if rain_factor else "null::float8 as rain_mm_per_tip"
    return f"""
select n.id, c.wetted_area_m2, c.morning_start_hour, c.morning_end_hour, {factor}
  from public.nodes n
  join public.node_actuator_config c on c.node_id = n.id
 where n.plot_id = $1 and c.has_irrigation {active}
 order by {order}
"""


_PARAM_VERSIONS = """
select id, theta_fc_pct, theta_pwp_pct, p_frac, zr_mm, kc, valid_from
  from public.plot_soil_water_params where plot_id = $1 order by valid_from
"""
_LAT = "select location_lat from public.plots where id = $1"

_READINGS = f"""
select reading_timestamp as ts, soil_moisture_pct as sm, air_temperature_c as t,
       rainfall_mm as rain, rainfall_tip_count as tips, coalesce(quality_flag, '') as qf
  from public.sensor_raw_readings
 where node_id = $1 and reading_timestamp >= $2 and reading_timestamp < $3
   and coalesce(time_status, 'verified') not in {UNTRUSTED_TIME}
 order by reading_timestamp
"""

# Nilai jam Open-Meteo = jumlah satu jam SEBELUM stempelnya -> dicocokkan ke period_end.
_FORECASTS = """
select distinct on (valid_for_timestamp)
       valid_for_timestamp as ts, forecast_eto_mm as eto, forecast_rainfall_mm as rain
  from public.weather_forecasts
 where plot_id = $1 and source::text = 'open_meteo'
   and valid_for_timestamp > $2 and valid_for_timestamp <= $3
 order by valid_for_timestamp, forecast_issued_at desc nulls last
"""

# Fallback ETo (v12): snapshot terbaru untuk jam itu, lalu reanalisis archive.
_CACHED_ETO = """
select distinct on (valid_time) valid_time as ts, et0_fao_mm as eto
  from public.weather_forecast_snapshots
 where plot_id = $1 and source = 'open_meteo' and et0_fao_mm is not null
   and valid_time > $2 and valid_time <= $3
 order by valid_time, issued_at desc
"""
_ARCHIVE_ETO = """
select time as ts, et0_fao_mm as eto
  from public.weather_observed_hourly
 where plot_id = $1 and source = 'open_meteo_archive' and et0_fao_mm is not null
   and time > $2 and time <= $3
"""

_IRRIGATIONS = """
select action_timestamp as ts, estimated_volume_liter as vol
  from public.irrigation_actions
 where plot_id = $1 and (node_id = $2 or node_id is null)
   and action_timestamp >= $3 and action_timestamp < $4
   and execution_status::text = any($5::text[])
   and estimated_volume_liter is not null
"""

_LEDGER_BEFORE = """
select period_end, dr_end_mm from public.water_balance_ledger
 where plot_id = $1 and period_end <= $2 order by period_end desc limit 1
"""
_LAST_CORRECTION = """
select max(period_end) from public.water_balance_ledger
 where plot_id = $1 and corrected and period_end <= $2
"""
_ETC_HISTORY = """
select etc_mm from public.water_balance_ledger
 where plot_id = $1 and period_end > $2 and period_end <= $3
"""
_CALIBRATE = """
select u.i, public.smile_calibrate($1, 'soil_moisture', u.raw, u.at) as pct
  from unnest($2::float8[], $3::timestamptz[]) with ordinality as u(raw, at, i)
"""

_UPSERT = """
insert into public.water_balance_ledger (
  plot_id, node_id, period_start, period_end, params_id, eto_mm, eto_source, kc, etc_mm,
  rain_mm, rain_source, irrigation_mm, dp_mm, dr_start_mm, dr_model_mm, theta_obs_raw,
  theta_obs_pct, dr_obs_mm, dr_end_mm, corrected, taw_mm, raw_mm, calibration_status, computed_at
) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19,
          $20, $21, $22, $23, now())
on conflict (plot_id, period_end) do update set
  node_id = excluded.node_id, period_start = excluded.period_start, params_id = excluded.params_id,
  eto_mm = excluded.eto_mm, eto_source = excluded.eto_source, kc = excluded.kc,
  etc_mm = excluded.etc_mm, rain_mm = excluded.rain_mm, rain_source = excluded.rain_source,
  irrigation_mm = excluded.irrigation_mm, dp_mm = excluded.dp_mm,
  dr_start_mm = excluded.dr_start_mm, dr_model_mm = excluded.dr_model_mm,
  theta_obs_raw = excluded.theta_obs_raw, theta_obs_pct = excluded.theta_obs_pct,
  dr_obs_mm = excluded.dr_obs_mm, dr_end_mm = excluded.dr_end_mm, corrected = excluded.corrected,
  taw_mm = excluded.taw_mm, raw_mm = excluded.raw_mm,
  calibration_status = excluded.calibration_status, computed_at = now()
"""
_LEDGER_ID = "select id from public.water_balance_ledger where plot_id = $1 and period_end = $2"

_RECENT_FAO56 = """
select exists (select 1 from public.irrigation_predictions
                where plot_id = $1 and decision_layer = 'fao56'
                  and created_at > now() - interval '50 minutes')
"""
_INSERT_PREDICTION = """
insert into public.irrigation_predictions (
  plot_id, prediction_timestamp, model_id, decision_layer, status_model,
  dr_value_fao56, prediction_dr_value, predicted_soil_moisture, raw_value,
  taw_mm, raw_mm, etc_forecast_24h_mm, rain_forecast_12h_mm, dr_forecast_24h_mm,
  irrigation_triggered, recommended_irrigation_mm, ledger_id, reason
) values ($1, $2, null, 'fao56', null, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
returning id
"""


# --- perhitungan per plot -------------------------------------------------------

def floor_hour(t: datetime) -> datetime:
    return t.replace(minute=0, second=0, microsecond=0)


def _flags(qf: str) -> set[str]:
    return set(qf.split(",")) if qf else set()


def _param_for(versions: list[Params], at: datetime) -> Params:
    """Versi terbaru dengan valid_from <= at; kalau tidak ada, yang paling awal."""
    chosen = versions[0]
    for v in versions:
        if v.valid_from <= at:
            chosen = v
    return chosen


class _Series:
    """Bacaan sensor terurut waktu, dengan pencarian rentang cepat."""

    def __init__(self, rows):
        self.rows = rows
        self.ts = [r["ts"] for r in rows]

    def between(self, start: datetime, end: datetime, inclusive_end: bool = False):
        lo = bisect.bisect_left(self.ts, start)
        hi = bisect.bisect_right(self.ts, end) if inclusive_end else bisect.bisect_left(self.ts, end)
        return self.rows[lo:hi]

    def last_before(self, t: datetime, pred) -> object | None:
        for r in reversed(self.rows[:bisect.bisect_left(self.ts, t)]):
            if pred(r):
                return r
        return None


def _sensor_rain(series: _Series, ps: datetime, pe: datetime,
                 mm_per_tip: float = NOMINAL_MM_PER_TIP) -> float | None:
    """Hujan jam itu dari tipping bucket, dengan faktor mm/tip node (v12).

    Utama: selisih rainfall_tip_count x mm_per_tip. Kalau ada baris tanpa tip_count
    (firmware lama), seluruh jam memakai rainfall_mm x mm_per_tip / 0,28. Dua
    representasi tidak dicampur dalam satu deret karena rainfall_mm firmware tidak
    selalu tepat tip x 0,28; mencampurnya membuat lonjakan hujan palsu."""
    def ok(r):
        return "rain_fail" not in _flags(r["qf"]) and (r["tips"] is not None or r["rain"] is not None)

    rows = [r for r in series.between(ps, pe) if ok(r)]
    if len(rows) < MIN_RAIN_ROWS:
        return None
    if all(r["tips"] is not None for r in rows):
        prev = series.last_before(ps, lambda r: ok(r) and r["tips"] is not None)
        tips = sum(rain_increments([r["tips"] for r in rows], prev["tips"] if prev else None))
        return tips * mm_per_tip
    rows = [r for r in rows if r["rain"] is not None]
    prev = series.last_before(ps, lambda r: ok(r) and r["rain"] is not None)
    mm = sum(rain_increments([r["rain"] for r in rows], prev["rain"] if prev else None))
    return mm * (mm_per_tip / NOMINAL_MM_PER_TIP)


# CATATAN: SHT31 saat ini terpasang di bawah naungan plastik dan bias ±+5 °C di
# siang hari (malam ±0 °C). Tmax terlalu tinggi -> (Tmax - Tmin) dan Tmean terlalu
# besar, sehingga ETo Hargreaves cenderung TERLALU TINGGI. Karena itu Hargreaves
# hanya dipakai kalau semua sumber Open-Meteo (live, cached, archive) kosong.
def _hargreaves(series: _Series, pe: datetime, lat: float) -> float | None:
    rows = [r for r in series.between(pe - timedelta(hours=24), pe, inclusive_end=True)
            if r["ts"] > pe - timedelta(hours=24) and r["t"] is not None
            and "sht_fail" not in _flags(r["qf"])]
    if len({floor_hour(r["ts"]) for r in rows}) < MIN_TEMP_HOURS:
        return None
    temps = [r["t"] for r in rows]
    doy = pe.astimezone(WIB).timetuple().tm_yday
    return eto_hargreaves_mm_day(min(temps), max(temps), extraterrestrial_radiation_mj(lat, doy)) / 24


def _theta_raw(series: _Series, pe: datetime) -> float | None:
    vals = [r["sm"] for r in series.between(pe - THETA_WINDOW, pe)
            if r["sm"] is not None and "soil_fail" not in _flags(r["qf"])]
    return statistics.median(vals) if len(vals) >= MIN_THETA_ROWS else None


@dataclass
class _PlotContext:
    node: asyncpg.Record
    versions: list[Params]
    current: asyncpg.Record
    lat: float
    mm_per_tip: float
    warnings: list[str]


async def _plot_context(conn, plot_id: uuid.UUID, settings: WBSettings, access) -> _PlotContext | None:
    warnings: list[str] = []
    nodes = await conn.fetch(_nodes_sql(access["node_meta"], access.get("rain_factor", False)), plot_id)
    if not nodes:
        return None
    node = nodes[0]
    if len(nodes) > 1:
        warnings.append(f"multiple_nodes: dipakai {node['id']} dari {len(nodes)} node")

    versions = [Params(**dict(r)) for r in await conn.fetch(_PARAM_VERSIONS, plot_id)]
    current = await conn.fetchrow(_PLOT_PARAMS_CURRENT, plot_id)
    if not versions or current is None:
        return None

    lat = settings.default_lat
    if access["lat"]:
        raw_lat = await conn.fetchval(_LAT, plot_id)
        try:
            lat = float(raw_lat)
        except (TypeError, ValueError):
            warnings.append("lat_default")
    else:
        warnings.append("lat_default")
    mm_per_tip = node["rain_mm_per_tip"] or NOMINAL_MM_PER_TIP
    return _PlotContext(node, versions, current, lat, mm_per_tip, warnings)


@dataclass
class _Inputs:
    series: _Series
    fc_rows: dict            # weather_forecasts, issue terbaru per jam
    cached_eto: dict         # weather_forecast_snapshots, issue terbaru per jam
    archive_eto: dict        # weather_observed_hourly
    irr_rows: list


async def _load_inputs(conn, plot_id: uuid.UUID, node_id: uuid.UUID, access, first_flux: datetime,
                       end: datetime, fc_until: datetime) -> _Inputs:
    series = _Series(await conn.fetch(_READINGS, node_id, first_flux - timedelta(hours=24), end))
    fc_rows = {r["ts"]: r for r in await conn.fetch(_FORECASTS, plot_id, first_flux, fc_until)}
    cached, archive = {}, {}
    if access.get("wx", False):
        cached = {r["ts"]: r["eto"] for r in await conn.fetch(_CACHED_ETO, plot_id, first_flux, end)}
        archive = {r["ts"]: r["eto"] for r in await conn.fetch(_ARCHIVE_ETO, plot_id, first_flux, end)}
    irr_rows = await conn.fetch(_IRRIGATIONS, plot_id, node_id, first_flux, end, list(IRRIGATION_COUNTED))
    return _Inputs(series, fc_rows, cached, archive, irr_rows)


def _eto(inp: _Inputs, pe: datetime, lat: float) -> tuple[float, str]:
    """Urutan sumber ETo (v12): live -> cached -> archive -> Hargreaves SHT31 -> none."""
    fc = inp.fc_rows.get(pe)
    if fc is not None and fc["eto"] is not None:
        return fc["eto"], "open_meteo"
    if pe in inp.cached_eto:
        return inp.cached_eto[pe], "open_meteo_cached"
    if pe in inp.archive_eto:
        return inp.archive_eto[pe], "open_meteo_archive"
    h = _hargreaves(inp.series, pe, lat)               # bias tinggi, lihat catatan _hargreaves
    return (h, "hargreaves_sht31") if h is not None else (0.0, "none")


def _hour_flux(inp: _Inputs, ps: datetime, ctx: _PlotContext,
               rain_fallback: bool = True) -> tuple[float, str, float, str, float]:
    """(eto, eto_source, hujan, rain_source, irigasi mm) untuk jam [ps, ps+1h)."""
    pe = ps + HOUR
    eto, eto_src = _eto(inp, pe, ctx.lat)
    rain = _sensor_rain(inp.series, ps, pe, ctx.mm_per_tip)
    fc = inp.fc_rows.get(pe)
    if rain is not None:
        rain_src = "sensor"
    elif rain_fallback and fc is not None and fc["rain"] is not None:
        rain, rain_src = fc["rain"], "open_meteo"
    else:
        rain, rain_src = 0.0, "none"
    area = ctx.node["wetted_area_m2"]
    vol = sum(r["vol"] for r in inp.irr_rows if ps <= r["ts"] < pe)
    irr = vol / area if area else 0.0
    return eto, eto_src, max(rain, 0.0), rain_src, irr


async def compute_plot(
    conn: asyncpg.Connection,
    plot_id: uuid.UUID,
    settings: WBSettings,
    access: asyncpg.Record,
    now: datetime | None = None,
) -> PlotResult | None:
    """Hitung ledger jendela + keputusan tanpa menulis apa pun (dipakai juga --dry-run)."""
    now = now or datetime.now(timezone.utc)
    ctx = await _plot_context(conn, plot_id, settings, access)
    if ctx is None:
        return None
    node, versions, current, warnings = ctx.node, ctx.versions, ctx.current, ctx.warnings
    node_id = node["id"]

    end = floor_hour(now)                                   # period_end jam penuh terakhir
    window_start = end - timedelta(hours=settings.recompute_h)
    init = "ledger"
    prev = await conn.fetchrow(_LEDGER_BEFORE, plot_id, window_start)
    if prev is not None and prev["period_end"] < window_start:
        if prev["period_end"] >= end - timedelta(hours=MAX_BACKFILL_H):
            window_start = prev["period_end"]               # tutup celah, jangan lompat
        else:
            prev = None
    first_flux = window_start - timedelta(hours=settings.settle_h)

    inp = await _load_inputs(conn, plot_id, node_id, access, first_flux, end, now + timedelta(hours=24))
    series, fc_rows = inp.series, inp.fc_rows
    if node["wetted_area_m2"] is None and inp.irr_rows:
        warnings.append("wetted_area_null: irigasi dihitung 0 mm")

    # Fluks per jam (termasuk settle_h jam sebelum jendela untuk syarat koreksi)
    hours = []
    t = first_flux
    while t < end:
        hours.append(t)
        t += HOUR
    flux = {ps: _hour_flux(inp, ps, ctx) for ps in hours}

    # Observasi sensor (kalibrasi lewat fungsi SQL, bukan polinomial di Python)
    obs_at = [ps + HOUR for ps in hours if ps >= window_start]
    if prev is None:
        obs_at = [window_start] + obs_at                    # untuk Dr awal dari observasi
    obs_raw = {pe: _theta_raw(series, pe) for pe in obs_at}
    have = [pe for pe in obs_at if obs_raw[pe] is not None]
    obs_pct: dict[datetime, float | None] = dict.fromkeys(obs_at)
    if have:
        for r in await conn.fetch(_CALIBRATE, node_id, [obs_raw[pe] for pe in have], have):
            obs_pct[have[r["i"] - 1]] = r["pct"]

    # Dr awal jendela
    if prev is not None:
        dr = prev["dr_end_mm"]
    else:
        p0 = _param_for(versions, window_start - HOUR)
        taw0 = p0.taw_raw[0]
        if obs_pct.get(window_start) is not None:
            dr, init = dr_from_theta(obs_pct[window_start], p0.theta_fc_pct, p0.zr_mm, taw0), "observed"
        else:
            dr, init = 0.0, "init_fc_assumed"
            log_json(event="water_balance_init", plot=plot_id, note="init_fc_assumed")

    last_corr = await conn.fetchval(_LAST_CORRECTION, plot_id, window_start)
    rows: list[LedgerRow] = []
    for ps in hours:
        if ps < window_start:
            continue
        pe = ps + HOUR
        p = _param_for(versions, ps)
        taw, raw, _ = p.taw_raw
        eto, eto_src, rain, rain_src, irr = flux[ps]
        etc = p.kc * eto
        dr_model, dp = balance_step(dr, etc, rain, irr, taw)

        theta_raw = obs_raw.get(pe)
        theta_pct = obs_pct.get(pe)
        calibrated = theta_pct is not None
        dr_obs = dr_from_theta(theta_pct, p.theta_fc_pct, p.zr_mm, taw) if calibrated else None

        settle = [flux[h] for h in hours if ps - timedelta(hours=settings.settle_h) <= h <= ps]
        wet = sum(f[2] for f in settle) > SETTLE_RAIN_MM or any(f[4] > 0 for f in settle)
        due = last_corr is None or pe - last_corr >= timedelta(hours=settings.correct_every_h)
        corrected = dr_obs is not None and due and not wet
        dr_end = dr_obs if corrected else dr_model
        if corrected:
            last_corr = pe

        rows.append(LedgerRow(
            period_start=ps, period_end=pe, params_id=p.id, eto_mm=eto, eto_source=eto_src, kc=p.kc,
            etc_mm=etc, rain_mm=rain, rain_source=rain_src, irrigation_mm=irr, dp_mm=dp,
            dr_start_mm=dr, dr_model_mm=dr_model, theta_obs_raw=theta_raw, theta_obs_pct=theta_pct,
            dr_obs_mm=dr_obs, dr_end_mm=dr_end, corrected=corrected, taw_mm=taw, raw_mm=raw,
            calibration_status="calibrated" if calibrated else "uncalibrated",
        ))
        dr = dr_end

    result = PlotResult(plot_id, node_id, rows, None if init == "ledger" else init, warnings=warnings)
    await _decide(conn, result, current, node, fc_rows, settings, now)
    return result


async def _decide(conn, result: PlotResult, cur, node, fc_rows, settings: WBSettings, now: datetime) -> None:
    latest = result.rows[-1]
    dr_now = latest.dr_end_mm
    taw, raw = cur["taw_mm"], cur["raw_mm"]

    ahead = [r for ts, r in fc_rows.items() if now < ts <= now + timedelta(hours=24)]
    notes = []
    etos = [r["eto"] for r in ahead if r["eto"] is not None]
    if etos:
        etc24 = cur["kc"] * sum(etos)
    else:
        since = now - timedelta(hours=72)
        hist = [r.etc_mm for r in result.rows if r.period_end > since]
        oldest = result.rows[0].period_start
        hist += [r["etc_mm"] for r in await conn.fetch(_ETC_HISTORY, result.plot_id, since, oldest)]
        etc24 = (sum(hist) / len(hist) * 24) if hist else 0.0
        notes.append("eto_fc_estimated")
    rain12 = sum(r["rain"] or 0 for r in ahead if r["ts"] <= now + timedelta(hours=12))
    rain24 = sum(r["rain"] or 0 for r in ahead)
    dr24 = min(max(dr_now + etc24 - rain24, 0.0), taw)

    theta_row = next((r for r in reversed(result.rows) if r.theta_obs_pct is not None), None)
    raw_row = next((r for r in reversed(result.rows) if r.theta_obs_raw is not None), None)
    d = decide(DecisionInput(
        dr_now=dr_now, taw=taw, raw=raw, theta_fc_pct=cur["theta_fc_pct"],
        theta_obs_pct=theta_row.theta_obs_pct if theta_row else None,
        theta_obs_age_h=(now - theta_row.period_end).total_seconds() / 3600 if theta_row else None,
        rain_forecast_12h_mm=rain12, dr_forecast_24h_mm=dr24,
        in_morning_window=in_morning_window(now, node["morning_start_hour"], node["morning_end_hour"]),
        rain_skip_mm=settings.rain_skip_mm,
    ))
    reason = f"{d.code}: {d.detail}; ETo {latest.eto_source}"
    if notes:
        reason += "; " + "; ".join(notes)
    if latest.calibration_status != "calibrated":
        reason += "; sensor belum terkalibrasi"
    result.decision = d
    result.prediction = dict(
        dr_value_fao56=dr_now, prediction_dr_value=dr24,
        predicted_soil_moisture=cur["theta_fc_pct"] - dr24 / cur["zr_mm"] * 100,
        raw_value=raw_row.theta_obs_raw if raw_row else None,
        taw_mm=taw, raw_mm=raw, etc_forecast_24h_mm=etc24, rain_forecast_12h_mm=rain12,
        dr_forecast_24h_mm=dr24, irrigation_triggered=d.triggered,
        recommended_irrigation_mm=d.recommended_mm, reason=reason,
    )


# --- lintasan FAO-56 murni untuk ML (scripts/run_water_balance.py --from/--to) -----

@dataclass
class TrajectoryRow:
    time: datetime            # period_end (UTC); nilai berlaku untuk jam [time-1h, time)
    plot_id: uuid.UUID
    eto_mm: float
    etc_mm: float
    rain_mm: float
    irrigation_mm: float
    dr_start_mm: float
    dr_end_mm: float
    taw_mm: float
    raw_mm: float
    eto_source: str
    rain_source: str          # tidak masuk CSV; untuk ringkasan


@dataclass
class Trajectory:
    rows: list[TrajectoryRow]
    init: str                 # 'given' / 'observed' / 'init_fc_assumed'
    warnings: list[str]


async def compute_trajectory(
    conn: asyncpg.Connection,
    plot_id: uuid.UUID,
    settings: WBSettings,
    access,
    start: datetime,
    end: datetime,
    init_dr: float | None = None,
) -> Trajectory | None:
    """Lintasan FAO-56 per jam [start, end) TANPA koreksi sensor. Hanya membaca.

    Parameter tanah per jam = versi yang berlaku saat itu; ETo dengan urutan yang
    sama dengan ledger; hujan HANYA dari sensor (jam tanpa data cukup = 0);
    irigasi dari irrigation_actions. Dr awal: init_dr, atau observasi terkalibrasi
    di `start`, atau 0 (kapasitas lapang)."""
    start, end = floor_hour(start), floor_hour(end)
    ctx = await _plot_context(conn, plot_id, settings, access)
    if ctx is None:
        return None
    warnings = list(ctx.warnings)
    inp = await _load_inputs(conn, plot_id, ctx.node["id"], access, start, end, end)

    if init_dr is not None:
        dr, init = init_dr, "given"
    else:
        dr, init = 0.0, "init_fc_assumed"
        theta = _theta_raw(inp.series, start)
        if theta is not None:
            pct = await conn.fetchval("select public.smile_calibrate($1, 'soil_moisture', $2, $3)",
                                      ctx.node["id"], theta, start)
            if pct is not None:
                p0 = _param_for(ctx.versions, start - HOUR)
                dr, init = dr_from_theta(pct, p0.theta_fc_pct, p0.zr_mm, p0.taw_raw[0]), "observed"

    rows: list[TrajectoryRow] = []
    before_first = 0
    ps = start
    while ps < end:
        p = _param_for(ctx.versions, ps)
        if p.valid_from > ps:
            before_first += 1
        taw, raw, _ = p.taw_raw
        eto, eto_src, rain, rain_src, irr = _hour_flux(inp, ps, ctx, rain_fallback=False)
        etc = p.kc * eto
        dr_end, _dp = balance_step(dr, etc, rain, irr, taw)
        rows.append(TrajectoryRow(ps + HOUR, plot_id, eto, etc, rain, irr, dr, dr_end, taw, raw,
                                  eto_src, rain_src))
        dr = dr_end
        ps += HOUR
    if before_first:
        warnings.append(f"{before_first} jam sebelum versi parameter tanah pertama: dipakai versi paling awal")
    return Trajectory(rows, init, warnings)


async def write_plot(conn: asyncpg.Connection, result: PlotResult, now: datetime) -> uuid.UUID | None:
    """Satu transaksi per plot: upsert ledger (id baris tetap), lalu satu prediksi."""
    async with conn.transaction():
        await conn.executemany(_UPSERT, [
            (result.plot_id, result.node_id, r.period_start, r.period_end, r.params_id, r.eto_mm,
             r.eto_source, r.kc, r.etc_mm, r.rain_mm, r.rain_source, r.irrigation_mm, r.dp_mm,
             r.dr_start_mm, r.dr_model_mm, r.theta_obs_raw, r.theta_obs_pct, r.dr_obs_mm, r.dr_end_mm,
             r.corrected, r.taw_mm, r.raw_mm, r.calibration_status)
            for r in result.rows
        ])
        if await conn.fetchval(_RECENT_FAO56, result.plot_id):
            result.skipped_duplicate = True
            return None
        ledger_id = await conn.fetchval(_LEDGER_ID, result.plot_id, result.rows[-1].period_end)
        p = result.prediction
        return await conn.fetchval(
            _INSERT_PREDICTION, result.plot_id, now, p["dr_value_fao56"], p["prediction_dr_value"],
            p["predicted_soil_moisture"], p["raw_value"], p["taw_mm"], p["raw_mm"],
            p["etc_forecast_24h_mm"], p["rain_forecast_12h_mm"], p["dr_forecast_24h_mm"],
            p["irrigation_triggered"], p["recommended_irrigation_mm"], ledger_id, p["reason"],
        )


_warned_access: set[str] = set()


async def check_access(conn: asyncpg.Connection) -> asyncpg.Record:
    access = await conn.fetchrow(_ACCESS)
    for key, msg in (
        ("lat", "smile_ingest tidak bisa membaca plots.location_lat; dipakai WB_DEFAULT_LAT"),
        ("node_meta", "smile_ingest tidak bisa membaca nodes.status/created_at; node dipilih by id"),
        ("wf_policy", "weather_forecasts tidak punya policy RLS untuk smile_ingest; prakiraan terbaca KOSONG"),
        ("wx", "tabel cuaca v12 tidak terbaca; fallback ETo open_meteo_cached/open_meteo_archive mati"),
        ("rain_factor", "nodes.rain_mm_per_tip tidak terbaca (v12 belum diterapkan?); dipakai 0,28 mm/tip"),
    ):
        if not access[key] and key not in _warned_access:
            _warned_access.add(key)
            log.warning("water balance: %s", msg)
    return access


async def run_cycle(
    conn: asyncpg.Connection,
    settings: WBSettings,
    now: datetime | None = None,
    plot_ids: list[uuid.UUID] | None = None,
    meteo: weather.OpenMeteo | None = None,
) -> list[PlotResult] | None:
    """Satu siklus semua plot. None kalau proses lain memegang kunci.

    Dengan `meteo`, prakiraan Open-Meteo diambil dulu (satu panggilan per plot)
    dan disimpan ke weather_forecasts + snapshot. Kegagalannya hanya dicatat di log."""
    now = now or datetime.now(timezone.utc)
    if not await conn.fetchval("select pg_try_advisory_lock($1)", WB_LOCK_KEY):
        return None
    results: list[PlotResult] = []
    try:
        access = await check_access(conn)
        if meteo is not None:
            await weather.sync_forecasts(conn, meteo, now, plot_ids)
        plots = plot_ids or [r["plot_id"] for r in await conn.fetch(_PLOTS)]
        for plot_id in plots:
            try:
                res = await compute_plot(conn, plot_id, settings, access, now)
                if res is None:
                    continue
                pred_id = await write_plot(conn, res, now)
            except (asyncpg.PostgresError, ArithmeticError, ValueError) as e:
                log.warning("water balance plot %s gagal: %s: %s", plot_id, type(e).__name__, e)
                continue
            results.append(res)
            latest = res.rows[-1]
            log_json(
                event="water_balance", plot=plot_id, node=res.node_id, hours=len(res.rows),
                corrected=sum(r.corrected for r in res.rows), init=res.init,
                dr_end_mm=round(latest.dr_end_mm, 2), eto_source=latest.eto_source,
                rain_source=latest.rain_source, calibration=latest.calibration_status,
                decision=res.decision.code if res.decision else None,
                triggered=res.decision.triggered if res.decision else None,
                recommended_mm=res.decision.recommended_mm if res.decision else None,
                prediction=pred_id, duplicate=res.skipped_duplicate,
                warnings=res.warnings or None,
            )
    finally:
        await conn.execute("select pg_advisory_unlock($1)", WB_LOCK_KEY)
    return results


def next_run(now: datetime) -> datetime:
    t = now.replace(minute=RUN_MINUTE, second=0, microsecond=0)
    return t if t > now else t + HOUR


async def run_forever(database, settings: WBSettings, meteo: weather.OpenMeteo | None = None) -> None:
    """Sekali saat startup (setelah pool siap), lalu tiap jam menit ke-5 WIB."""
    try:
        while database.pool is None:
            await asyncio.sleep(1)
        while True:
            try:
                async with database.pool.acquire() as conn:
                    await run_cycle(conn, settings, meteo=meteo)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 - siklus berikutnya mencoba lagi
                log.warning("water balance cycle failed: %s: %s", type(e).__name__, e)
            now = datetime.now(timezone.utc)
            await asyncio.sleep((next_run(now) - now).total_seconds())
    finally:
        if meteo is not None:
            await meteo.aclose()
