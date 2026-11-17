"""Klien dan parser Open-Meteo (v12), tanpa DB."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import httpx
import pytest

from app import weather
from app.water_balance import _Series, _sensor_rain

UTC = timezone.utc
H = timedelta(hours=1)


def forecast_json(issued: datetime, eto=0.15, rain=0.4, prob=20.0, past_h=48, future_h=72) -> dict:
    """Bentuk respons forecast API dengan timezone=UTC (stempel tanpa zona)."""
    start = weather.floor_hour(issued) - past_h * H
    n = past_h + future_h + 1
    times = [(start + i * H).strftime("%Y-%m-%dT%H:%M") for i in range(n)]
    return {"latitude": -6.6, "longitude": 106.8, "timezone": "GMT", "hourly": {
        "time": times,
        "temperature_2m": [24.5] * n, "relative_humidity_2m": [85.0] * n,
        "precipitation": [rain] * n, "precipitation_probability": [prob] * n,
        "et0_fao_evapotranspiration": [eto] * n, "wind_speed_10m": [1.5] * n,
        "shortwave_radiation": [300.0] * n,
    }}


def archive_json(start: date, end: date, eto=0.12, rain=0.0) -> dict:
    t0 = datetime(start.year, start.month, start.day, tzinfo=UTC)
    n = ((end - start).days + 1) * 24
    times = [(t0 + i * H).strftime("%Y-%m-%dT%H:%M") for i in range(n)]
    return {"hourly": {
        "time": times, "precipitation": [rain] * n, "temperature_2m": [23.0] * n,
        "relative_humidity_2m": [88.0] * n, "wind_speed_10m": [1.2] * n,
        "shortwave_radiation": [250.0] * n, "et0_fao_evapotranspiration": [eto] * n,
    }}


# --- parser ------------------------------------------------------------------

def test_parse_forecast_snapshot_horizon_and_lead():
    fetched = datetime(2026, 10, 19, 7, 23, 41, tzinfo=UTC)
    p = weather.parse_forecast(forecast_json(fetched), fetched)
    issued = datetime(2026, 10, 19, 7, tzinfo=UTC)

    assert len(p.current) == 48 + 72 + 1                      # semua jam -> weather_forecasts
    assert [s["lead_hours"] for s in p.snapshots] == list(range(1, 49))
    assert p.snapshots[0]["valid_time"] == issued + H
    assert p.snapshots[-1]["valid_time"] == issued + 48 * H
    assert all(s["valid_time"].tzinfo is not None and s["valid_time"].utcoffset() == timedelta(0)
               for s in p.snapshots)
    s = p.snapshots[0]
    assert (s["et0_fao_mm"], s["precipitation_mm"], s["precipitation_probability"]) == (0.15, 0.4, 20.0)
    assert (s["temperature_2m"], s["relative_humidity_2m"], s["wind_speed_10m"], s["shortwave_radiation"]) \
        == (24.5, 85.0, 1.5, 300.0)


def test_parse_forecast_nulls_and_bad_values():
    fetched = datetime(2026, 10, 19, 7, tzinfo=UTC)
    data = forecast_json(fetched)
    h = data["hourly"]
    i = 49                                                     # lead 1
    h["et0_fao_evapotranspiration"][i] = None
    h["precipitation"][i] = None
    h["precipitation_probability"][i] = 140                    # di luar 0..100 -> dipotong
    h["temperature_2m"][i] = "x"                               # bukan angka -> NULL
    h["precipitation"][i + 1] = -0.01                          # negatif kecil -> 0
    del h["shortwave_radiation"]                               # variabel hilang -> NULL semua
    p = weather.parse_forecast(data, fetched)
    s, s2 = p.snapshots[0], p.snapshots[1]
    assert s["et0_fao_mm"] is None and s["precipitation_mm"] is None and s["temperature_2m"] is None
    assert s["precipitation_probability"] == 100 and s2["precipitation_mm"] == 0
    assert all(x["shortwave_radiation"] is None for x in p.snapshots)
    c = p.current[i]
    assert c["eto"] is None and c["rain"] == 0.0               # sama dengan edge function lama


def test_parse_rejects_malformed():
    with pytest.raises(weather.WeatherError):
        weather.parse_forecast({"error": True, "reason": "x"}, datetime.now(UTC))
    data = forecast_json(datetime(2026, 10, 19, tzinfo=UTC))
    data["hourly"]["precipitation"].pop()
    with pytest.raises(weather.WeatherError):
        weather.parse_forecast(data, datetime(2026, 10, 19, tzinfo=UTC))


def test_parse_archive_skips_empty_hours():
    data = archive_json(date(2026, 10, 1), date(2026, 10, 1))
    h = data["hourly"]
    for k in weather.ARCHIVE_VARS:
        h[k][23] = None                                        # jam terakhir belum tersedia
    h["et0_fao_evapotranspiration"][0] = -0.001
    h["temperature_2m"][1] = None
    rows = weather.parse_archive(data)
    assert len(rows) == 23
    assert rows[0]["time"] == datetime(2026, 10, 1, tzinfo=UTC) and rows[0]["et0_fao_mm"] == 0
    assert rows[1]["temperature_2m"] is None and rows[1]["et0_fao_mm"] == 0.12


# --- HTTP: timeout, retry, backoff -----------------------------------------------

def _meteo(handler, attempts=3):
    s = weather.WXSettings(attempts=attempts, backoff_s=0)
    return weather.OpenMeteo(s, httpx.AsyncClient(transport=httpx.MockTransport(handler)))


async def test_retry_then_success_and_request_params():
    calls = []

    def handler(req: httpx.Request):
        calls.append(req)
        if len(calls) == 1:
            return httpx.Response(503, text="busy")
        return httpx.Response(200, json=forecast_json(datetime(2026, 10, 19, tzinfo=UTC)))

    m = _meteo(handler)
    data = await m.forecast(-6.596139, 106.803057)
    assert "hourly" in data and len(calls) == 2
    q = calls[-1].url.params
    assert calls[-1].url.host == "api.open-meteo.com"
    assert (q["timezone"], q["wind_speed_unit"], q["models"], q["latitude"]) == ("UTC", "ms", "best_match", "-6.5961")
    assert set(q["hourly"].split(",")) == set(weather.FORECAST_VARS)
    await m.aclose()


async def test_client_error_not_retried():
    calls = []

    def handler(req):
        calls.append(req)
        return httpx.Response(400, json={"error": True, "reason": "bad"})

    m = _meteo(handler)
    with pytest.raises(weather.WeatherError, match="HTTP 400"):
        await m.forecast(0, 0)
    assert len(calls) == 1


async def test_timeout_retried_then_raises():
    calls = []

    def handler(req):
        calls.append(req)
        raise httpx.ReadTimeout("slow", request=req)

    m = _meteo(handler, attempts=3)
    with pytest.raises(weather.WeatherError, match="3 percobaan"):
        await m.archive(0, 0, date(2026, 10, 1), date(2026, 10, 2))
    assert len(calls) == 3


# --- jadwal --------------------------------------------------------------------

def test_next_observed_run_03_wib():
    wib = timezone(timedelta(hours=7))
    assert weather.next_observed_run(datetime(2026, 10, 19, 2, 59, tzinfo=wib)) == datetime(2026, 10, 18, 20, tzinfo=UTC)
    assert weather.next_observed_run(datetime(2026, 10, 19, 3, 0, tzinfo=wib)) == datetime(2026, 10, 19, 20, tzinfo=UTC)


def test_observed_range_h10_to_h1():
    now = datetime(2026, 10, 18, 20, 0, tzinfo=UTC)            # 2026-10-19 03:00 WIB
    assert weather.observed_range(now, 10) == (date(2026, 10, 9), date(2026, 10, 18))


# --- hujan dari tip x faktor (F) ---------------------------------------------------

def _rows(start, n, tips, rain):
    return [{"ts": start + timedelta(minutes=i), "tips": tips(i), "rain": rain(i), "qf": ""} for i in range(n)]


def test_sensor_rain_uses_tip_factor():
    ps = datetime(2026, 10, 10, 5, tzinfo=UTC)
    prev = _rows(ps - H, 60, lambda i: 100, lambda i: 27.9)
    hour = _rows(ps, 60, lambda i: 100 + (i >= 30) * 10, lambda i: 27.9 + (i >= 30) * 2.8)
    s = _Series(prev + hour)
    assert _sensor_rain(s, ps, ps + H, 0.289) == pytest.approx(10 * 0.289)
    assert _sensor_rain(s, ps, ps + H) == pytest.approx(10 * 0.28)        # default nominal


def test_sensor_rain_without_tips_scales_mm():
    ps = datetime(2026, 10, 10, 5, tzinfo=UTC)
    hour = _rows(ps - H, 120, lambda i: None if i >= 60 else 100, lambda i: 27.9 + (i >= 90) * 2.8)
    s = _Series(hour)
    # Jam itu ada baris tanpa tip -> seluruh jam memakai rainfall_mm x 0,289/0,28
    assert _sensor_rain(s, ps, ps + H, 0.289) == pytest.approx(2.8 * 0.289 / 0.28)
