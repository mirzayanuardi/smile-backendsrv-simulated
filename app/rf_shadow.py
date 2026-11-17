"""Random Forest irigasi: RF_MODE = off | shadow | active.

shadow: RF hanya mencatat prediksi Dr 24 jam ke irrigation_predictions dengan
decision_layer = 'rf' dan irrigation_triggered = false. Keputusan siram tetap
milik rule engine FAO-56 (water_balance.decide); dispatcher juga mengabaikan
baris 'rf' (pengaman kedua).

active (fase 2): RF dihitung sebelum FAO-56 memutuskan. Kalau reliable, aturan
R4 (antisipasi pagi) memakai Dr 24 jam RF dan barisnya decision_layer = 'fao56+rf'.
Kalau tidak reliable / fitur tidak lengkap, keputusan FAO-56 murni.

Fitur harus sama persis dengan training
(ML/TrainingAgain/skenario_4_data_gabungan_forecast/smile_irigasi_gabungan_forecast.py,
bagian 2, build_features, build_forecast_features, tree_stats). Aturan pembersihan
yang khusus sesi training (ketukan manual 7 Nov, 15 menit pertama setelah sensor
ditancap, baris anomali 14 Nov, selisih tip per segmen asli/sintetis) tidak
dibawa ke sini karena tidak bisa diketahui server.
"""

from __future__ import annotations

import logging
import os
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import asyncpg
import joblib
import numpy as np
import pandas as pd

from .jsonlog import log_json

log = logging.getLogger("smile.rf_shadow")

TZ = "Asia/Jakarta"
WIB = timezone(timedelta(hours=7))
STEP = pd.Timedelta("5min")
SPH = 12                               # blok 5 menit per jam
AIR_THETA, AIR_EC = 13.279, 0.0        # sensor di udara
SOIL_OFF_EC = 20.0
MM_PER_TIP = 0.2891                    # konstanta training (bukan nodes.rain_mm_per_tip)
MAX_TIPS_PER_MIN = 10
HORIZON = "24h"
WINDOW_BLOCKS = 24 * SPH               # rainfall_acc_24h: 288 blok termasuk blok t
LOOKBACK = timedelta(hours=25)         # jendela 24 jam + margin untuk selisih tip pertama
RECENT_MIN = 50                        # sama dengan anti dobel FAO-56 (_RECENT_FAO56)

IRR_FEATURES = ["soil_moisture_lag_1h", "soil_moisture_lag_3h", "soil_moisture_lag_6h",
                "delta_moisture_1h", "delta_moisture_3h", "delta_moisture_6h",
                "rainfall_acc_1h", "rainfall_acc_6h", "rainfall_acc_24h",
                "hour_sin", "hour_cos", "day_of_year_sin", "day_of_year_cos"]
FC_FEATURES = ["fc_rain_next_1h", "fc_rain_next_6h", "fc_rain_next_24h", "fc_rain_prob_max_24h",
               "fc_et0_next_24h", "fc_temp_mean_24h", "fc_rh_mean_24h"]
FEATURES = IRR_FEATURES + FC_FEATURES
READING_COLS = ["id", "ts", "soil_moisture_pct", "soil_ec_uscm", "rainfall_tip_count"]
FC_COLS = ["issued_at", "fetched_at", "valid_time", "precipitation_mm", "precipitation_probability",
           "et0_fao_mm", "temperature_2m", "relative_humidity_2m"]


# --- fitur (fungsi murni, index = waktu WIB tanpa zona, label = awal blok) -------

def _wib_naive(s: pd.Series) -> pd.Series:
    return pd.to_datetime(s, utc=True, format="mixed").dt.tz_convert(TZ).dt.tz_localize(None)


def preprocess(readings: pd.DataFrame) -> pd.DataFrame:
    """Baris calibrated_sensor_raw_readings (kolom READING_COLS, ts UTC) -> theta & rain_mm per menit."""
    d = readings.copy()
    d["ts"] = _wib_naive(d.ts)
    d = d[d.ts.dt.year >= 2020].sort_values(["ts", "id"])
    d = d.drop_duplicates("ts", keep="first").set_index("ts")
    air = np.isclose(d.soil_moisture_pct, AIR_THETA, atol=1e-3) & (d.soil_ec_uscm == AIR_EC)
    d = d[~air]
    d = d[~(d.soil_ec_uscm < SOIL_OFF_EC)]
    tips = d.rainfall_tip_count.diff().fillna(0.0).clip(lower=0)      # reset penghitung = 0
    rain = tips.where(tips <= MAX_TIPS_PER_MIN, 0.0) * MM_PER_TIP       # > 10 tip/menit = tip palsu
    return pd.DataFrame({"theta": d.soil_moisture_pct, "rain_mm": rain})


def to_grid(minutes: pd.DataFrame) -> pd.DataFrame:
    """Resample 5 menit: theta rata-rata, hujan jumlah; blok tanpa data NaN."""
    r = minutes.resample(STEP)
    return pd.DataFrame({"theta": r.theta.mean(), "rain_mm": r.rain_mm.sum(min_count=1)})


def build_features(g: pd.DataFrame) -> pd.DataFrame:
    """Sama dengan build_features training: 13 kolom irrigation_features dari grid 5 menit."""
    th, f = g.theta, pd.DataFrame(index=g.index)
    for h in (1, 3, 6):
        f[f"soil_moisture_lag_{h}h"] = th.shift(h * SPH)
        f[f"delta_moisture_{h}h"] = th - th.shift(h * SPH)
    for h in (1, 6, 24):
        f[f"rainfall_acc_{h}h"] = g.rain_mm.rolling(h * SPH, min_periods=h * SPH).sum()
    hour = g.index.hour + g.index.minute / 60
    doy = g.index.dayofyear
    f["hour_sin"], f["hour_cos"] = np.sin(2 * np.pi * hour / 24), np.cos(2 * np.pi * hour / 24)
    f["day_of_year_sin"], f["day_of_year_cos"] = np.sin(2 * np.pi * doy / 365.25), np.cos(2 * np.pi * doy / 365.25)
    return f[IRR_FEATURES]


def prepare_forecasts(fc: pd.DataFrame) -> pd.DataFrame:
    """Baris weather_forecast_snapshots (kolom FC_COLS, waktu UTC) -> WIB, dedup seperti training."""
    fc = fc.copy()
    for c in ("issued_at", "valid_time", "fetched_at"):
        fc[c] = _wib_naive(fc[c])
    return fc.sort_values("fetched_at").drop_duplicates(["issued_at", "valid_time"], keep="last")


def build_forecast_features(grid: pd.DatetimeIndex, fc: pd.DataFrame) -> pd.DataFrame:
    """Sama dengan build_forecast_features training: snapshot terbaru dengan fetched_at <= t."""
    out = pd.DataFrame(np.nan, index=grid, columns=FC_FEATURES)
    if fc.empty:
        return out
    issues = (fc.groupby("issued_at").fetched_at.max().rename("tersedia").reset_index().sort_values("tersedia"))
    m = pd.merge_asof(pd.DataFrame({"t": grid}), issues, left_on="t", right_on="tersedia")
    for iss, grp in m.dropna(subset=["issued_at"]).groupby("issued_at"):
        f = fc[fc.issued_at == iss].sort_values("valid_time")
        T, V = grp.t.to_numpy()[:, None], f.valid_time.to_numpy()[None, :]
        # shortcut (dari training): jam valid dihitung utuh walau t di tengah jam; tepat untuk t = HH:00
        w = {k: (V > T) & (V <= T + np.timedelta64(k, "h")) for k in (1, 6, 24)}
        rain = f.precipitation_mm.to_numpy(float)
        with np.errstate(invalid="ignore", divide="ignore"):
            vals = np.column_stack([w[1] @ rain, w[6] @ rain, w[24] @ rain,
                                    np.where(w[24], f.precipitation_probability.to_numpy(float), -np.inf).max(1),
                                    w[24] @ f.et0_fao_mm.to_numpy(float),
                                    (w[24] @ f.temperature_2m.to_numpy(float)) / w[24].sum(1),
                                    (w[24] @ f.relative_humidity_2m.to_numpy(float)) / w[24].sum(1)])
        vals[f.valid_time.max() < grp.t.to_numpy() + np.timedelta64(24, "h")] = np.nan   # tidak menjangkau 24 jam
        out.loc[grp.t.to_numpy()] = vals
    return out


def features_at(readings: pd.DataFrame, fc: pd.DataFrame, t: pd.Timestamp) -> pd.Series:
    """20 fitur untuk titik t (WIB tanpa zona, awal blok). NaN = tidak lengkap."""
    idx = pd.date_range(t - (WINDOW_BLOCKS - 1) * STEP, t, freq=STEP)
    minutes = preprocess(readings)
    g = to_grid(minutes).reindex(idx) if len(minutes) else pd.DataFrame(np.nan, index=idx, columns=["theta", "rain_mm"])
    row = build_features(g).iloc[-1]
    return pd.concat([row, build_forecast_features(pd.DatetimeIndex([t]), fc).iloc[0]])[FEATURES]


def latest_complete_block(now: datetime) -> datetime:
    """Awal blok 5 menit terakhir yang sudah lengkap (UTC)."""
    now = now.astimezone(timezone.utc)
    floor = now.replace(minute=now.minute - now.minute % 5, second=0, microsecond=0)
    return floor - timedelta(minutes=5)


# --- SQL ------------------------------------------------------------------------

# Training memakai tabel ini (export CSV): kalibrasi sama, termasuk rumus cadangan trigger.
_READINGS = """
select id, reading_timestamp as ts, soil_moisture_pct, soil_ec_uscm, rainfall_tip_count
  from public.calibrated_sensor_raw_readings
 where plot_id = $1 and reading_timestamp >= $2 and reading_timestamp < $3
"""

# Issue dengan max(fetched_at) <= t terbaru (= merge_asof training). Issue terbit lebih
# dari 2 hari sebelum t tidak mungkin menjangkau t+24 jam (lead maks 48 jam), jadi boleh dilewati.
_SNAPSHOT = """
with issue as (
  select issued_at from public.weather_forecast_snapshots
   where plot_id = $1 and source = 'open_meteo' and issued_at > $2::timestamptz - interval '2 days'
   group by issued_at having max(fetched_at) <= $2::timestamptz
   order by max(fetched_at) desc limit 1)
select s.issued_at, s.fetched_at, s.valid_time, s.precipitation_mm, s.precipitation_probability,
       s.et0_fao_mm, s.temperature_2m, s.relative_humidity_2m
  from public.weather_forecast_snapshots s join issue using (issued_at)
 where s.plot_id = $1 and s.source = 'open_meteo'
"""

_RECENT_RF = f"""
select exists (select 1 from public.irrigation_predictions
                where plot_id = $1 and decision_layer = 'rf'
                  and created_at > now() - interval '{RECENT_MIN} minutes')
"""

_INSERT = """
insert into public.irrigation_predictions (
  plot_id, prediction_timestamp, model_id, decision_layer, status_model,
  prediction_dr_value, prediction_error_margin, predicted_soil_moisture, taw_mm, raw_mm,
  irrigation_triggered, recommended_irrigation_mm, reason
) values ($1, $2, $3, 'rf', $4, $5, $6, $7, $8, $9, false, null, $10)
returning id
"""


def _frame(rows, cols: list[str], time_cols: tuple[str, ...]) -> pd.DataFrame:
    df = pd.DataFrame([tuple(r) for r in rows], columns=cols)
    for c in cols:
        if c not in time_cols:
            df[c] = df[c].astype(float)
    return df


# --- model ----------------------------------------------------------------------

MODES = ("off", "shadow", "active")


@dataclass
class RFResult:
    t: datetime                  # titik fitur (UTC, awal blok)
    dr_mm: float                 # prediksi Dr t+24 jam
    std_mm: float                # std antar pohon
    uncertainty_pct: float
    status: str                  # reliable / uncertain
    theta_pct: float             # θ_FC - Dr/Zr x 100
    model_id: uuid.UUID
    model_version: str | None

    @property
    def reliable(self) -> bool:
        return self.status == "reliable"


class RFShadow:
    def __init__(self, bundle: dict, model_id: uuid.UUID, error_threshold_pct: float, mode: str = "shadow"):
        self.bundle = bundle
        self.model = bundle["models"][HORIZON]
        self.model_id = model_id
        self.threshold = error_threshold_pct
        self.mode = mode
        self.plot_id = uuid.UUID(bundle["plot_id"])
        self.soil = bundle["soil"]

    @classmethod
    def from_env(cls) -> "RFShadow | None":
        """Muat model sekali. None (dengan satu baris log) kalau dimatikan atau tidak lengkap."""
        e = os.environ.get
        mode = e("RF_MODE", "off").strip().lower()
        if mode not in MODES:
            log.warning("rf: RF_MODE=%r tidak dikenal (off/shadow/active), RF dimatikan", mode)
            return None
        if mode == "off":
            log.info("rf: mati (RF_MODE=off)")
            return None
        path, model_id = e("RF_MODEL_PATH", ""), e("RF_MODEL_ID", "")
        if not path or not model_id:
            log.warning("rf shadow: RF_MODEL_PATH atau RF_MODEL_ID kosong, RF dilewati")
            return None
        try:
            mid = uuid.UUID(model_id)
            threshold = float(e("RF_ERROR_THRESHOLD_PCT", "25"))
            bundle = joblib.load(path)
            if bundle["features"] != FEATURES or HORIZON not in bundle["models"]:
                raise ValueError("fitur/horizon bundle tidak sama dengan kode backend")
        except Exception as err:  # noqa: BLE001 - model rusak/beda versi: RF dilewati, FAO-56 tetap jalan
            log.warning("rf shadow: model tidak bisa dimuat, RF dilewati: %s: %s", type(err).__name__, err)
            return None
        log_json(event="rf_loaded", mode=mode, model_version=bundle.get("model_version"), plot=bundle["plot_id"],
                 sklearn=bundle.get("sklearn_version"), threshold_pct=threshold)
        return cls(bundle, mid, threshold, mode)

    def predict(self, x: pd.Series) -> tuple[float, float]:
        """Rata-rata dan std prediksi antar pohon (mm), seperti tree_stats training."""
        X = x.to_numpy(float).reshape(1, -1)
        allp = np.stack([tree.predict(X) for tree in self.model.estimators_])
        return float(allp.mean()), float(allp.std())

    async def infer(self, conn: asyncpg.Connection, plot_id: uuid.UUID, now: datetime) -> RFResult | None:
        """Fitur + prediksi untuk titik t. None kalau plot bukan milik model atau fitur tidak lengkap."""
        if plot_id != self.plot_id:
            return None
        t = latest_complete_block(now)
        t_wib = pd.Timestamp(t.astimezone(WIB).replace(tzinfo=None))
        readings = _frame(await conn.fetch(_READINGS, plot_id, t - LOOKBACK, t + timedelta(minutes=5)),
                          READING_COLS, ("ts",))
        fc = _frame(await conn.fetch(_SNAPSHOT, plot_id, t), FC_COLS, ("issued_at", "fetched_at", "valid_time"))
        x = features_at(readings, prepare_forecasts(fc), t_wib)
        missing = [k for k, v in x.items() if pd.isna(v)]
        if missing:
            log_json(event="rf", mode=self.mode, plot=plot_id, t=t, skipped="fitur_tidak_lengkap",
                     missing=missing, readings=len(readings), forecast_rows=len(fc))
            return None
        dr, sd = self.predict(x)
        uncertainty = 100 * sd / self.soil["raw_mm"]
        res = RFResult(t, dr, sd, uncertainty, "reliable" if uncertainty <= self.threshold else "uncertain",
                       self.soil["theta_fc"] - dr / self.soil["zr_mm"] * 100,
                       self.model_id, self.bundle.get("model_version"))
        log_json(event="rf", mode=self.mode, plot=plot_id, t=t, dr_mm=round(dr, 2), std_mm=round(sd, 2),
                 uncertainty_pct=round(uncertainty, 1), status=res.status)
        return res

    async def run(self, conn: asyncpg.Connection, plot_id: uuid.UUID, now: datetime,
                  force: bool = False) -> uuid.UUID | None:
        """Shadow: catat satu baris decision_layer='rf' (paling banyak satu per 50 menit kecuali force)."""
        if plot_id != self.plot_id:
            return None
        if not force and await conn.fetchval(_RECENT_RF, plot_id):
            log_json(event="rf", mode=self.mode, plot=plot_id, skipped="duplicate")
            return None
        r = await self.infer(conn, plot_id, now)
        if r is None:
            return None
        t_wib = r.t.astimezone(WIB)
        reason = (f"rf_shadow: t={t_wib:%Y-%m-%d %H:%M} WIB, horizon {HORIZON}, Dr {r.dr_mm:.2f} mm, "
                  f"uncertainty {r.uncertainty_pct:.1f}% ({r.status}), {r.model_version}")
        return await conn.fetchval(_INSERT, plot_id, now, self.model_id, r.status, r.dr_mm, r.std_mm,
                                   r.theta_pct, self.soil["taw_mm"], self.soil["raw_mm"], reason)
