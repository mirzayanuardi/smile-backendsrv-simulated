"""Open-Meteo: satu-satunya klien HTTP cuaca di server ini (migrasi v12).

- Prakiraan (forecast API) dipanggil SEKALI per plot (semua plot) di awal siklus neraca air
  tiap jam. Satu respons mengisi dua tabel:
    weather_forecasts            nilai terbaru per jam (dibaca ledger dan app), upsert
    weather_forecast_snapshots   arsip apa adanya untuk ML, ON CONFLICT DO NOTHING
  Gagal fetch atau gagal menulis TIDAK menggagalkan siklus neraca air.
- Observasi (archive API) dijalankan job harian 03:00 WIB untuk H-10 s.d. H-1,
  ON CONFLICT DO UPDATE karena reanalisis hari-hari terakhir direvisi.

Stempel jam Open-Meteo (timezone=UTC): nilai akumulasi (hujan, ET0) dan rata-rata
(radiasi) berlaku untuk satu jam SEBELUM stempel, sama dengan period_end ledger.
"""

from __future__ import annotations

import asyncio
import logging
import math
import os
import time
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

import asyncpg
import httpx

from .dispatcher import WIB
from .jsonlog import log_json

log = logging.getLogger("smile.weather")

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
MODEL = "best_match"           # model yang diminta; API tidak mengembalikan model yang dipakai
HORIZON_H = 48
FORECAST_VARS = ("temperature_2m", "relative_humidity_2m", "precipitation", "precipitation_probability",
                 "et0_fao_evapotranspiration", "wind_speed_10m", "shortwave_radiation")
ARCHIVE_VARS = ("precipitation", "temperature_2m", "relative_humidity_2m", "wind_speed_10m",
                "shortwave_radiation", "et0_fao_evapotranspiration")
RETRY_STATUS = {429, 500, 502, 503, 504}
ARCHIVE_CHUNK_DAYS = 31
OBS_LOCK_KEY = int.from_bytes(b"smilewxo", "big", signed=True)   # beda dengan dispatcher/neraca air
OBS_RUN_HOUR_WIB = 3
HOUR = timedelta(hours=1)


class WeatherError(Exception):
    pass


@dataclass
class WXSettings:
    forecast_enabled: bool = True
    observed_enabled: bool = True
    observed_days: int = 10
    timeout_s: float = 15.0
    attempts: int = 3
    backoff_s: float = 1.0          # jeda 1, 2, 4 ... detik antar percobaan
    default_lat: float = -6.595
    default_lng: float = 106.8166

    @classmethod
    def from_env(cls) -> "WXSettings":
        e = os.environ.get
        return cls(
            forecast_enabled=e("WX_FORECAST_ENABLED", "1") != "0",
            observed_enabled=e("WX_OBSERVED_ENABLED", "1") != "0",
            observed_days=max(1, int(e("WX_OBSERVED_DAYS", "10"))),
            timeout_s=float(e("WX_HTTP_TIMEOUT_S", "15")),
            attempts=max(1, int(e("WX_HTTP_ATTEMPTS", "3"))),
            backoff_s=float(e("WX_HTTP_BACKOFF_S", "1")),
            default_lat=float(e("WB_DEFAULT_LAT", "-6.595")),
            default_lng=float(e("WB_DEFAULT_LNG", "106.8166")),
        )


class OpenMeteo:
    """Klien Open-Meteo dengan timeout dan retry + backoff eksponensial."""

    def __init__(self, settings: WXSettings, client: httpx.AsyncClient | None = None):
        self.settings = settings
        self._client = client or httpx.AsyncClient(
            timeout=settings.timeout_s, headers={"User-Agent": "smile-backendsrv/1.0"})

    async def aclose(self) -> None:
        await self._client.aclose()

    async def get_json(self, url: str, params: dict) -> dict:
        s = self.settings
        err = "no attempt"
        for attempt in range(s.attempts):
            try:
                r = await self._client.get(url, params=params, timeout=s.timeout_s)
            except (httpx.TimeoutException, httpx.TransportError) as e:
                err = f"{type(e).__name__}: {e}"
            else:
                if r.status_code == 200:
                    try:
                        return r.json()
                    except ValueError as e:
                        raise WeatherError(f"bukan JSON: {e}") from e
                err = f"HTTP {r.status_code}: {r.text[:200]}"
                if r.status_code not in RETRY_STATUS:
                    raise WeatherError(err)       # 4xx: parameter salah, mengulang tidak membantu
            if attempt + 1 < s.attempts:
                await asyncio.sleep(s.backoff_s * 2 ** attempt)
        raise WeatherError(f"{err} (setelah {s.attempts} percobaan)")

    async def forecast(self, lat: float, lng: float) -> dict:
        return await self.get_json(FORECAST_URL, {
            "latitude": f"{lat:.4f}", "longitude": f"{lng:.4f}",
            "hourly": ",".join(FORECAST_VARS), "models": MODEL,
            "timezone": "UTC", "wind_speed_unit": "ms",
            # past_days=2 seperti edge function lama: jam yang sudah lewat tetap punya ETo/hujan.
            "past_days": 2, "forecast_days": 3,
        })

    async def archive(self, lat: float, lng: float, start: date, end: date) -> dict:
        return await self.get_json(ARCHIVE_URL, {
            "latitude": f"{lat:.4f}", "longitude": f"{lng:.4f}",
            "hourly": ",".join(ARCHIVE_VARS), "timezone": "UTC", "wind_speed_unit": "ms",
            "start_date": start.isoformat(), "end_date": end.isoformat(),
        })


# ---------------------------------------------------------------------------
# Parser (murni)
# ---------------------------------------------------------------------------

def floor_hour(t: datetime) -> datetime:
    return t.replace(minute=0, second=0, microsecond=0)


def _utc(s: str) -> datetime:
    t = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return t.replace(tzinfo=timezone.utc) if t.tzinfo is None else t.astimezone(timezone.utc)


def _num(v) -> float | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        return None
    return float(v)


def _nonneg(v) -> float | None:
    v = _num(v)
    return None if v is None else max(v, 0.0)   # reanalisis kadang memberi -0,0001


def _hourly(data: dict, names: tuple[str, ...]) -> list[dict]:
    """Respons hourly -> daftar {"time": datetime UTC, <var>: float|None}.
    Variabel yang tidak ada di respons menjadi None; panjang array harus sama."""
    if not isinstance(data, dict) or not isinstance(data.get("hourly"), dict):
        raise WeatherError("respons tanpa 'hourly'")
    h = data["hourly"]
    times = h.get("time")
    if not isinstance(times, list):
        raise WeatherError("hourly.time bukan array")
    cols = {}
    for n in names:
        col = h.get(n)
        if col is None:
            col = [None] * len(times)
        elif not isinstance(col, list) or len(col) != len(times):
            raise WeatherError(f"hourly.{n} panjangnya tidak sama dengan time")
        cols[n] = col
    return [{"time": _utc(t), **{n: cols[n][i] for n in names}} for i, t in enumerate(times)]


@dataclass
class ForecastParse:
    current: list[dict]       # semua jam respons -> weather_forecasts
    snapshots: list[dict]     # lead 1..48 jam -> weather_forecast_snapshots


def parse_forecast(data: dict, issued_at: datetime) -> ForecastParse:
    issued_at = floor_hour(issued_at.astimezone(timezone.utc))
    current, snaps = [], []
    for r in _hourly(data, FORECAST_VARS):
        vt = r["time"]
        eto = _nonneg(r["et0_fao_evapotranspiration"])
        rain = _nonneg(r["precipitation"])
        current.append({
            "valid_time": vt,
            # Sama dengan edge function lama: hujan kosong = 0, ETo kosong tetap NULL
            # (0 akan terbaca "tidak ada evaporasi" di neraca air).
            "rain": 0.0 if rain is None else rain,
            "temp": _num(r["temperature_2m"]), "rh": _num(r["relative_humidity_2m"]), "eto": eto,
        })
        lead = (vt - issued_at) / HOUR
        if lead != int(lead) or not 1 <= lead <= HORIZON_H:
            continue
        pp = _num(r["precipitation_probability"])
        snaps.append({
            "valid_time": vt, "lead_hours": int(lead), "precipitation_mm": rain,
            "precipitation_probability": None if pp is None else min(max(pp, 0.0), 100.0),
            "et0_fao_mm": eto, "temperature_2m": _num(r["temperature_2m"]),
            "relative_humidity_2m": _num(r["relative_humidity_2m"]),
            "wind_speed_10m": _num(r["wind_speed_10m"]), "shortwave_radiation": _num(r["shortwave_radiation"]),
        })
    return ForecastParse(current, snaps)


_OBS_FIELDS = (("precipitation_mm", "precipitation", _nonneg), ("temperature_2m", "temperature_2m", _num),
               ("relative_humidity_2m", "relative_humidity_2m", _num),
               ("wind_speed_10m", "wind_speed_10m", _num),
               ("shortwave_radiation", "shortwave_radiation", _num),
               ("et0_fao_mm", "et0_fao_evapotranspiration", _nonneg))


def parse_archive(data: dict) -> list[dict]:
    """Jam yang semua variabelnya kosong (ERA5 belum tersedia) dilewati, supaya
    cakupan jam di tabel = jam yang benar-benar punya data."""
    out = []
    for r in _hourly(data, ARCHIVE_VARS):
        row = {"time": r["time"], **{col: conv(r[src]) for col, src, conv in _OBS_FIELDS}}
        if any(row[col] is not None for col, _, _ in _OBS_FIELDS):
            out.append(row)
    return out


# ---------------------------------------------------------------------------
# SQL
# ---------------------------------------------------------------------------

# Prakiraan untuk SEMUA plot, termasuk yang tanpa node atau node-nya maintenance:
# app menampilkan cuaca per plot, dan edge function lama juga mengisi semua plot.
_ALL_PLOTS = """
select p.id, p.location_lat, p.location_lng
  from public.plots p
 where ($1::uuid[] is null or p.id = any($1::uuid[]))
 order by p.id
"""


def _active_plots_sql(node_meta: bool) -> str:
    active = "and coalesce(n.status::text, 'active') = 'active'" if node_meta else ""
    return f"""
select p.id, p.location_lat, p.location_lng
  from public.plots p
 where exists (select 1 from public.nodes n where n.plot_id = p.id {active})
   and ($1::uuid[] is null or p.id = any($1::uuid[]))
 order by p.id
"""


_WF_UPSERT = """
insert into public.weather_forecasts (plot_id, forecast_issued_at, valid_for_timestamp, forecast_rainfall_mm,
                                      forecast_temperature_c, forecast_humidity_pct, forecast_eto_mm, source)
select $1, $2, u.vt, u.rain, u.t, u.rh, u.eto, 'open_meteo'::public.source_type
  from unnest($3::timestamptz[], $4::float8[], $5::float8[], $6::float8[], $7::float8[]) as u(vt, rain, t, rh, eto)
on conflict (plot_id, valid_for_timestamp, source) do update set
  forecast_issued_at = excluded.forecast_issued_at, forecast_rainfall_mm = excluded.forecast_rainfall_mm,
  forecast_temperature_c = excluded.forecast_temperature_c, forecast_humidity_pct = excluded.forecast_humidity_pct,
  forecast_eto_mm = excluded.forecast_eto_mm
"""

_SNAP_INSERT = """
insert into public.weather_forecast_snapshots (
  plot_id, source, model, issued_at, valid_time, lead_hours, precipitation_mm, precipitation_probability,
  et0_fao_mm, temperature_2m, relative_humidity_2m, wind_speed_10m, shortwave_radiation, fetched_at)
select $1, 'open_meteo', $2, $3, u.vt, u.lead, u.p, u.pp, u.e, u.t, u.rh, u.ws, u.sw, $4
  from unnest($5::timestamptz[], $6::int[], $7::float8[], $8::float8[], $9::float8[], $10::float8[],
              $11::float8[], $12::float8[], $13::float8[]) as u(vt, lead, p, pp, e, t, rh, ws, sw)
on conflict (plot_id, source, issued_at, valid_time) do nothing
"""

# NULL baru tidak menimpa nilai lama (archive kadang mengosongkan jam terbaru).
_OBS_UPSERT = """
insert into public.weather_observed_hourly as w (
  plot_id, source, time, precipitation_mm, temperature_2m, relative_humidity_2m, wind_speed_10m,
  shortwave_radiation, et0_fao_mm, updated_at)
select $1, 'open_meteo_archive', u.ts, u.p, u.t, u.rh, u.ws, u.sw, u.e, now()
  from unnest($2::timestamptz[], $3::float8[], $4::float8[], $5::float8[], $6::float8[], $7::float8[],
              $8::float8[]) as u(ts, p, t, rh, ws, sw, e)
on conflict (plot_id, source, time) do update set
  precipitation_mm     = coalesce(excluded.precipitation_mm, w.precipitation_mm),
  temperature_2m       = coalesce(excluded.temperature_2m, w.temperature_2m),
  relative_humidity_2m = coalesce(excluded.relative_humidity_2m, w.relative_humidity_2m),
  wind_speed_10m       = coalesce(excluded.wind_speed_10m, w.wind_speed_10m),
  shortwave_radiation  = coalesce(excluded.shortwave_radiation, w.shortwave_radiation),
  et0_fao_mm           = coalesce(excluded.et0_fao_mm, w.et0_fao_mm),
  updated_at           = now()
"""

_LAST_TIMES = """
select (select max(fetched_at) from public.weather_forecast_snapshots) as forecast,
       (select max(updated_at) from public.weather_observed_hourly) as observed
"""


def _count(status: str) -> int:
    """'INSERT 0 37' -> 37."""
    return int(status.rsplit(" ", 1)[-1])


def coords(row, settings: WXSettings) -> tuple[float, float, bool]:
    """(lat, lng, pakai_default). Sama dengan edge function lama: koordinat kosong -> default."""
    try:
        lat, lng = float(row["location_lat"]), float(row["location_lng"])
        if math.isfinite(lat) and math.isfinite(lng):
            return lat, lng, False
    except (TypeError, ValueError):
        pass
    return settings.default_lat, settings.default_lng, True


async def write_forecast(conn: asyncpg.Connection, plot_id: uuid.UUID, parsed: ForecastParse,
                         issued_at: datetime, fetched_at: datetime) -> tuple[int, int, list[str]]:
    """Dua tulisan terpisah: gagal satu tidak membatalkan yang lain. Kembalikan
    (baris weather_forecasts, baris snapshot baru, error)."""
    errors = []
    wf = snap = 0
    c = parsed.current
    try:
        wf = _count(await conn.execute(
            _WF_UPSERT, plot_id, fetched_at, [r["valid_time"] for r in c], [r["rain"] for r in c],
            [r["temp"] for r in c], [r["rh"] for r in c], [r["eto"] for r in c]))
    except asyncpg.PostgresError as e:
        errors.append(f"weather_forecasts: {type(e).__name__}: {e}"[:300])
    s = parsed.snapshots
    try:
        snap = _count(await conn.execute(
            _SNAP_INSERT, plot_id, MODEL, floor_hour(issued_at), fetched_at,
            [r["valid_time"] for r in s], [r["lead_hours"] for r in s], [r["precipitation_mm"] for r in s],
            [r["precipitation_probability"] for r in s], [r["et0_fao_mm"] for r in s],
            [r["temperature_2m"] for r in s], [r["relative_humidity_2m"] for r in s],
            [r["wind_speed_10m"] for r in s], [r["shortwave_radiation"] for r in s]))
    except asyncpg.PostgresError as e:
        errors.append(f"snapshot: {type(e).__name__}: {e}"[:300])
    return wf, snap, errors


async def sync_forecasts(conn: asyncpg.Connection, meteo: OpenMeteo, now: datetime | None = None,
                         plot_ids: list[uuid.UUID] | None = None) -> dict:
    """Satu fetch per plot (semua plot). TIDAK PERNAH melempar error (kecuali dibatalkan):
    dipanggil di awal siklus neraca air dan kegagalannya cukup dicatat di log."""
    started = time.perf_counter()
    now = now or datetime.now(timezone.utc)
    stats = {"plots": 0, "rows_forecast": 0, "rows_snapshot": 0, "errors": []}
    try:
        plots = await conn.fetch(_ALL_PLOTS, plot_ids)
    except asyncpg.PostgresError as e:
        plots = []
        stats["errors"].append(f"plots: {type(e).__name__}: {e}"[:300])
    for p in plots:
        lat, lng, defaulted = coords(p, meteo.settings)
        try:
            data = await meteo.forecast(lat, lng)
            parsed = parse_forecast(data, now)
            wf, snap, errs = await write_forecast(conn, p["id"], parsed, now, now)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 - neraca air tetap jalan
            stats["errors"].append(f"{p['id']}: {type(e).__name__}: {e}"[:300])
            continue
        stats["plots"] += 1
        stats["rows_forecast"] += wf
        stats["rows_snapshot"] += snap
        stats["errors"] += [f"{p['id']}: {x}" for x in errs]
        if defaulted:
            stats["errors"].append(f"{p['id']}: koordinat kosong, dipakai WB_DEFAULT_LAT/LNG")
    stats["duration_ms"] = round((time.perf_counter() - started) * 1000, 1)
    log_json(event="forecast_snapshot", issued_at=floor_hour(now), plots=stats["plots"],
             rows_forecast=stats["rows_forecast"], rows_snapshot=stats["rows_snapshot"],
             duration_ms=stats["duration_ms"], errors=stats["errors"] or None)
    return stats


def observed_range(now: datetime, days: int) -> tuple[date, date]:
    """H-days s.d. H-1 dari tanggal WIB hari ini."""
    today = now.astimezone(WIB).date()
    return today - timedelta(days=days), today - timedelta(days=1)


async def run_observed_cycle(conn: asyncpg.Connection, meteo: OpenMeteo, now: datetime | None = None,
                             start: date | None = None, end: date | None = None,
                             plot_ids: list[uuid.UUID] | None = None, node_meta: bool = True) -> dict | None:
    """Ambil archive untuk [start, end] (tanggal UTC, inklusif). None kalau proses lain memegang kunci."""
    now = now or datetime.now(timezone.utc)
    if start is None or end is None:
        start, end = observed_range(now, meteo.settings.observed_days)
    if not await conn.fetchval("select pg_try_advisory_lock($1)", OBS_LOCK_KEY):
        return None
    started = time.perf_counter()
    stats = {"plots": 0, "rows": 0, "errors": []}
    try:
        for p in await conn.fetch(_active_plots_sql(node_meta), plot_ids):
            lat, lng, defaulted = coords(p, meteo.settings)
            if defaulted:
                stats["errors"].append(f"{p['id']}: koordinat kosong, dipakai WB_DEFAULT_LAT/LNG")
            ok = True
            d = start
            while d <= end:
                d2 = min(d + timedelta(days=ARCHIVE_CHUNK_DAYS - 1), end)
                try:
                    rows = parse_archive(await meteo.archive(lat, lng, d, d2))
                    if rows:
                        stats["rows"] += _count(await conn.execute(
                            _OBS_UPSERT, p["id"], [r["time"] for r in rows],
                            *[[r[col] for r in rows] for col in
                              ("precipitation_mm", "temperature_2m", "relative_humidity_2m",
                               "wind_speed_10m", "shortwave_radiation", "et0_fao_mm")]))
                except (WeatherError, asyncpg.PostgresError, ValueError) as e:
                    ok = False
                    stats["errors"].append(f"{p['id']} {d}..{d2}: {type(e).__name__}: {e}"[:300])
                d = d2 + timedelta(days=1)
            stats["plots"] += ok
    finally:
        await conn.execute("select pg_advisory_unlock($1)", OBS_LOCK_KEY)
        stats["duration_ms"] = round((time.perf_counter() - started) * 1000, 1)
        log_json(event="weather_observed", start=start, end=end, plots=stats["plots"], rows=stats["rows"],
                 duration_ms=stats["duration_ms"], errors=stats["errors"] or None)
    return stats


def next_observed_run(now: datetime) -> datetime:
    t = now.astimezone(WIB).replace(hour=OBS_RUN_HOUR_WIB, minute=0, second=0, microsecond=0)
    if t <= now:
        t += timedelta(days=1)
    return t.astimezone(timezone.utc)


async def run_observed_forever(database, settings: WXSettings, meteo: OpenMeteo | None = None) -> None:
    """Tiap hari 03:00 WIB. Tidak dijalankan saat startup: jendela H-10 menutup hari yang terlewat."""
    meteo = meteo or OpenMeteo(settings)
    try:
        while True:
            now = datetime.now(timezone.utc)
            await asyncio.sleep((next_observed_run(now) - now).total_seconds())
            while database.pool is None:
                await asyncio.sleep(1)
            try:
                async with database.pool.acquire() as conn:
                    await run_observed_cycle(conn, meteo)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001 - besok dicoba lagi
                log.warning("weather observed cycle failed: %s: %s", type(e).__name__, e)
    finally:
        await meteo.aclose()


async def last_times(database, timeout: float = 1.0) -> tuple[datetime | None, datetime | None]:
    """Untuk /v1/health. (None, None) kalau DB atau tabel v12 belum siap."""
    if database.pool is None:
        return None, None
    try:
        async with asyncio.timeout(timeout):
            async with database.pool.acquire() as conn:
                r = await conn.fetchrow(_LAST_TIMES)
        return r["forecast"], r["observed"]
    except Exception:  # noqa: BLE001
        return None, None
