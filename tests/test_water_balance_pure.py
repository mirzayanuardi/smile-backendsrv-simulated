"""Neraca air FAO-56: fungsi murni (tanpa DB). Nomor mengikuti uji §7 prompt v11."""

from __future__ import annotations

import pytest

from app.water_balance import (
    DecisionInput,
    balance_step,
    decide,
    dr_from_theta,
    eto_hargreaves_mm_day,
    extraterrestrial_radiation_mj,
    rain_increments,
    taw_raw,
)


# 1
def test_extraterrestrial_radiation_fao56_example_8():
    assert extraterrestrial_radiation_mj(-20, 246) == pytest.approx(32.2, rel=0.01)


def test_hargreaves_never_negative():
    assert eto_hargreaves_mm_day(22, 31, 37.0) > 0
    assert eto_hargreaves_mm_day(25, 25, 37.0) == 0
    assert eto_hargreaves_mm_day(31, 22, 37.0) == eto_hargreaves_mm_day(22, 31, 37.0)


# 2
def test_balance_step():
    dr, dp = balance_step(10, 0.2, 15, 0, 60)
    assert dr == 0 and dp == pytest.approx(4.8)
    assert balance_step(58, 5, 0, 0, 60) == (60, 0)


# 3
def test_dr_from_theta():
    assert dr_from_theta(53.5, 59.5, 400, 60) == pytest.approx(24.0)
    assert dr_from_theta(70, 59.5, 400, 60) == 0
    assert dr_from_theta(10, 59.5, 400, 60) == 60


# 4 (bagian Python; perbandingan dengan view ada di uji DB)
def test_taw_raw_seed():
    taw, raw, trig = taw_raw(59.5, 44.5, 0.40, 400)
    assert (taw, raw, trig) == pytest.approx((60, 24, 53.5))


def test_rain_increments_cumulative_and_reset():
    # naik bertahap, datar, lalu reset (listrik putus) dan naik lagi
    assert rain_increments([0.28, 0.56, 0.56, 0.84], prev=0.0) == pytest.approx([0.28, 0.28, 0, 0.28])
    assert rain_increments([33.81, 0.0, 0.28], prev=33.53) == pytest.approx([0.28, 0, 0.28])
    # reset ke nilai > 0 (tip sudah terhitung setelah boot): selisih = nilai baru
    assert rain_increments([1.12, 0.56], prev=None) == pytest.approx([0, 0.56])
    assert rain_increments([None, 0.28, None, 0.56], prev=0.0) == pytest.approx([0.28, 0.28])
    assert rain_increments([]) == []


def _inp(**kw):
    base = dict(dr_now=26, taw=60, raw=24, theta_fc_pct=59.5, theta_obs_pct=None, theta_obs_age_h=None,
                rain_forecast_12h_mm=0, dr_forecast_24h_mm=26, in_morning_window=False)
    base.update(kw)
    return DecisionInput(**base)


# 9
def test_decide_dr_ge_raw():
    d = decide(_inp())
    assert (d.triggered, d.code, d.recommended_mm) == (True, "dr_ge_raw", 26)
    assert d.detail == "Dr 26,0 mm ≥ RAW 24,0 mm"


# 10
def test_decide_rain_expected():
    d = decide(_inp(rain_forecast_12h_mm=15))
    assert (d.triggered, d.code, d.recommended_mm) == (False, "rain_expected", None)


# 11
def test_decide_anticipatory_only_in_window():
    d = decide(_inp(dr_now=18, dr_forecast_24h_mm=18 + 7, in_morning_window=True))
    assert (d.triggered, d.code, d.recommended_mm) == (True, "anticipatory_24h", 18)
    d = decide(_inp(dr_now=18, dr_forecast_24h_mm=18 + 7, in_morning_window=False))
    assert (d.triggered, d.code) == (False, "below_raw")


# 12
def test_decide_soil_at_fc_needs_fresh_calibrated_reading():
    assert decide(_inp(theta_obs_pct=60, theta_obs_age_h=1)).code == "soil_at_fc"
    assert decide(_inp(theta_obs_pct=60, theta_obs_age_h=3)).code == "dr_ge_raw"


def test_recommended_capped_at_taw():
    assert decide(_inp(dr_now=70, taw=60)).recommended_mm == 60
