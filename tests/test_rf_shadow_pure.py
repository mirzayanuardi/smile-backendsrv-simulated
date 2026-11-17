"""RF shadow tanpa DB: kesamaan fitur dengan training (uji a) dan titik t.

Uji kesamaan butuh folder ML (CSV export + fitur_model_lengkap.csv), misalnya
RF_TEST_ML_DIR="D:/The Kuliah Files/SMILE/ML/TrainingAgain". Tanpa env itu di-skip.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from app import rf_shadow as rs

ML_DIR = os.environ.get("RF_TEST_ML_DIR")
PLOT = "e4ecc640-f805-4840-a192-225250f37b91"
# Ketukan manual 7 Nov 16:11-16:13 WIB dibuang training (aturan khusus sesi, tidak dibawa ke server):
# hanya fitur hujan di titik yang jendela 24 jamnya mencakup ketukan itu boleh berbeda.
MANUAL_TAP = (pd.Timestamp("2026-11-07 16:10"), pd.Timestamp("2026-11-08 16:05"))
RAIN_FEATURES = {"rainfall_acc_1h", "rainfall_acc_6h", "rainfall_acc_24h"}


def test_latest_complete_block():
    now = datetime(2026, 11, 17, 3, 5, 41, tzinfo=timezone.utc)       # 10:05:41 WIB, siklus menit ke-5
    assert rs.latest_complete_block(now) == datetime(2026, 11, 17, 3, 0, tzinfo=timezone.utc)
    now = datetime(2026, 11, 17, 3, 0, 0, tzinfo=timezone.utc)
    assert rs.latest_complete_block(now) == datetime(2026, 11, 17, 2, 55, tzinfo=timezone.utc)


def test_incomplete_window_gives_nan():
    t = pd.Timestamp("2026-11-10 07:00")
    ts = pd.date_range(t - pd.Timedelta("2h"), t, freq="1min").tz_localize(rs.TZ).tz_convert("UTC")
    readings = pd.DataFrame({"id": range(len(ts)), "ts": ts, "soil_moisture_pct": 60.0,
                             "soil_ec_uscm": 500.0, "rainfall_tip_count": 0.0})
    x = rs.features_at(readings, pd.DataFrame(columns=rs.FC_COLS), t)
    assert x[["soil_moisture_lag_1h", "delta_moisture_1h"]].notna().all()
    assert x[["soil_moisture_lag_6h", "rainfall_acc_24h", "fc_rain_next_24h"]].isna().all()


@pytest.fixture(scope="module")
def ml():
    if not ML_DIR:
        pytest.skip("RF_TEST_ML_DIR tidak di-set")
    d = Path(ML_DIR)
    raw = pd.read_csv(d / "data" / "calibrated_sensor_raw_readings.csv", low_memory=False)
    raw = raw[raw.plot_id == PLOT].rename(columns={"reading_timestamp": "ts"})[rs.READING_COLS]
    fc = pd.read_csv(d / "data" / "weather_forecast_snapshots_rows.csv")
    fc = fc[(fc.plot_id == PLOT) & (fc.source == "open_meteo")][rs.FC_COLS]
    ref = pd.read_csv(d / "skenario_4_data_gabungan_forecast" / "hasil" / "fitur_model_lengkap.csv",
                      index_col="waktu_wib", parse_dates=True)
    return raw, rs.prepare_forecasts(fc), ref


def test_features_match_training(ml):
    raw, fc, ref = ml
    assert list(ref.columns) == rs.FEATURES
    feat = rs.build_features(rs.to_grid(rs.preprocess(raw)))
    got = feat.join(rs.build_forecast_features(feat.index, fc))[rs.FEATURES]

    close = pd.DataFrame(np.isclose(got.reindex(ref.index).to_numpy(float), ref.to_numpy(float),
                                    rtol=1e-9, atol=1e-9), index=ref.index, columns=rs.FEATURES)
    tap = (ref.index >= MANUAL_TAP[0]) & (ref.index <= MANUAL_TAP[1])
    assert close[~tap].all().all(), close[~tap].sum().to_dict()
    assert set(close.columns[~close[tap].all()]) <= RAIN_FEATURES
    # Backend tidak menghasilkan titik lengkap yang tidak ada di acuan.
    assert got.dropna().index.difference(ref.index).empty


def test_window_path_equals_full_series(ml):
    """features_at (jendela 25 jam seperti query server) = perhitungan atas seluruh data."""
    raw, fc, ref = ml
    ts = pd.to_datetime(raw.ts, utc=True, format="mixed")
    for t in ref.index[::137]:
        t_utc = t.tz_localize(rs.TZ).tz_convert("UTC")
        win = raw[(ts >= t_utc - rs.LOOKBACK) & (ts < t_utc + rs.STEP)]
        x = rs.features_at(win, fc, t)
        assert np.allclose(x.to_numpy(float), ref.loc[t].to_numpy(float), rtol=1e-9, atol=1e-9) \
            or (MANUAL_TAP[0] <= t <= MANUAL_TAP[1]), t
