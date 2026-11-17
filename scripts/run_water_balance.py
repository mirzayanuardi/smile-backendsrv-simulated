"""Jalankan satu siklus neraca air FAO-56 untuk satu plot dan cetak tabel per jam.

    python scripts/run_water_balance.py --plot <uuid> [--dry-run] [--hours 48] [--force]

Memakai DATABASE_URL dari .env (role smile_ingest). --dry-run hanya membaca:
ledger dan prediksi tidak ditulis. Tanpa --dry-run, hasilnya sama persis dengan
satu siklus job terjadwal (termasuk fetch Open-Meteo, kunci advisory, aturan 50 menit,
dan RF sesuai RF_MODE). --force melewati aturan 50 menit (pemicu manual, sim.sh esp).

Mode backfill untuk ML (hanya membaca, hanya menulis CSV, TIDAK menyentuh ledger):

    python scripts/run_water_balance.py --plot <uuid> --from 2026-10-08 --to 2026-10-12 \
        --no-sensor-correction --export-csv out.csv [--init-dr 0]

Rentang [--from, --to). Waktu tanpa zona dibaca sebagai WIB; CSV dalam UTC.
Kolom `time` = akhir jam (period_end).
"""

from __future__ import annotations

import argparse
import asyncio
import collections
import csv
import os
import sys
import uuid
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import rf_shadow  # noqa: E402
from app import water_balance as wb  # noqa: E402
from app import weather  # noqa: E402
from app.dispatcher import WIB  # noqa: E402


def _dsn() -> str:
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        env = Path(__file__).resolve().parent.parent / ".env"
        for line in env.read_text().splitlines() if env.exists() else []:
            if line.startswith("DATABASE_URL="):
                dsn = line.split("=", 1)[1].strip()
    if not dsn:
        sys.exit("DATABASE_URL belum diisi")
    return dsn


def _f(x, w=6, d=2) -> str:
    return "-".rjust(w) if x is None else f"{x:{w}.{d}f}"


def print_result(res: wb.PlotResult) -> None:
    print(f"plot {res.plot_id}  node {res.node_id}  awal: {res.init or 'lanjut dari ledger'}")
    for w in res.warnings:
        print(f"  peringatan: {w}")
    print()
    print(f"{'jam (WIB)':16} {'ETo':>6} {'sumber':16} {'hujan':>6} {'sumber':10} {'irig':>6} "
          f"{'Dr mdl':>6} {'θ mnth':>6} {'θ %':>6} {'Dr obs':>6} {'Dr ak':>6} kor")
    for r in res.rows:
        print(f"{r.period_start.astimezone(WIB):%Y-%m-%d %H:%M} {_f(r.eto_mm, 6, 3)} {r.eto_source:16} "
              f"{_f(r.rain_mm)} {r.rain_source:10} {_f(r.irrigation_mm)} {_f(r.dr_model_mm)} "
              f"{_f(r.theta_obs_raw, 6, 1)} {_f(r.theta_obs_pct, 6, 1)} {_f(r.dr_obs_mm)} "
              f"{_f(r.dr_end_mm)} {'ya' if r.corrected else ''}")
    d, p = res.decision, res.prediction
    print()
    print(f"keputusan: {d.code}  triggered={d.triggered}  rekomendasi={_f(d.recommended_mm).strip()} mm  "
          f"lapisan={p['decision_layer']}")
    print(f"  TAW {p['taw_mm']:.1f} mm, RAW {p['raw_mm']:.1f} mm, ETc 24 jam {p['etc_forecast_24h_mm']:.2f} mm, "
          f"hujan 12 jam {p['rain_forecast_12h_mm']:.1f} mm, Dr 24 jam {p['dr_forecast_24h_mm']:.1f} mm")
    print(f"  reason: {p['reason']}")


CSV_COLUMNS = ("time", "plot_id", "eto_mm", "etc_mm", "rain_mm", "irrigation_mm", "dr_start_mm",
               "dr_end_mm", "taw_mm", "raw_mm", "eto_source")


def _when(s: str) -> datetime:
    t = datetime.fromisoformat(s)
    return t.replace(tzinfo=WIB) if t.tzinfo is None else t


def write_csv(path: str, traj: wb.Trajectory) -> None:
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(CSV_COLUMNS)
        for r in traj.rows:
            w.writerow([r.time.astimezone(timezone.utc).isoformat(), r.plot_id, *(
                f"{getattr(r, c):.4f}" for c in CSV_COLUMNS[2:-1]), r.eto_source])


async def backfill(conn, args, settings) -> None:
    start, end = _when(args.from_), _when(args.to)
    if end <= start:
        sys.exit("--to harus setelah --from")
    access = await wb.check_access(conn)
    traj = await wb.compute_trajectory(conn, args.plot, settings, access, start, end, args.init_dr)
    if traj is None:
        sys.exit("plot tidak punya parameter tanah atau node irigasi")
    write_csv(args.export_csv, traj)
    rows = traj.rows
    if rows:
        lo, hi = (rows[0].time - wb.HOUR).astimezone(timezone.utc), rows[-1].time.astimezone(timezone.utc)
        print(f"{len(rows)} jam [{lo:%Y-%m-%d %H:%M}Z, {hi:%Y-%m-%d %H:%M}Z) -> {args.export_csv}", file=sys.stderr)
    else:
        print("0 jam", file=sys.stderr)
    print(f"Dr awal: {rows[0].dr_start_mm:.2f} mm ({traj.init})" if rows else "", file=sys.stderr)
    print("sumber ETo: " + ", ".join(f"{k} {v}" for k, v in
                                    collections.Counter(r.eto_source for r in rows).most_common()), file=sys.stderr)
    no_rain = sum(r.rain_source != "sensor" for r in rows)
    if no_rain:
        print(f"{no_rain} jam tanpa data hujan sensor yang cukup: hujan = 0", file=sys.stderr)
    for w in traj.warnings:
        print(f"peringatan: {w}", file=sys.stderr)
    print("(ledger tidak ditulis)", file=sys.stderr)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plot", required=True, type=uuid.UUID)
    ap.add_argument("--dry-run", action="store_true", help="hitung saja, jangan menulis")
    ap.add_argument("--hours", type=int, default=None, help="jendela hitung ulang (default WB_RECOMPUTE_H)")
    ap.add_argument("--force", action="store_true", help="lewati aturan 50 menit (tulis keputusan baru)")
    ml = ap.add_argument_group("mode backfill ML (hanya CSV)")
    ml.add_argument("--from", dest="from_", metavar="ISO", help="awal rentang (tanpa zona = WIB)")
    ml.add_argument("--to", metavar="ISO", help="akhir rentang, eksklusif")
    ml.add_argument("--no-sensor-correction", action="store_true", help="wajib: tanpa koreksi sensor 6-jaman")
    ml.add_argument("--export-csv", metavar="PATH")
    ml.add_argument("--init-dr", type=float, default=None, help="Dr awal (mm); default observasi atau 0")
    args = ap.parse_args()
    backfill_mode = any(x is not None for x in (args.from_, args.to, args.export_csv)) or args.no_sensor_correction
    if backfill_mode:
        if not (args.from_ and args.to and args.export_csv):
            ap.error("mode backfill butuh --from, --to, dan --export-csv")
        if not args.no_sensor_correction:
            ap.error("mode backfill hanya mendukung --no-sensor-correction")

    settings = wb.WBSettings.from_env()
    if args.hours:
        settings = replace(settings, recompute_h=args.hours)
    conn = await asyncpg.connect(_dsn(), statement_cache_size=0)
    try:
        if backfill_mode:
            await backfill(conn, args, settings)
        elif args.dry_run:
            access = await wb.check_access(conn)
            rf = rf_shadow.RFShadow.from_env()
            hint = await rf.infer(conn, args.plot, datetime.now(timezone.utc)) if rf and rf.mode == "active" else None
            res = await wb.compute_plot(conn, args.plot, settings, access, rf_hint=hint)
            if res is None:
                sys.exit("plot tidak punya parameter tanah atau node irigasi")
            print_result(res)
            print("\n(dry-run: tidak ada yang ditulis)")
        else:
            wx = weather.WXSettings.from_env()
            meteo = weather.OpenMeteo(wx) if wx.forecast_enabled else None
            rf = rf_shadow.RFShadow.from_env()
            try:
                out = await wb.run_cycle(conn, settings, plot_ids=[args.plot], meteo=meteo, rf=rf,
                                         force=args.force)
            finally:
                if meteo is not None:
                    await meteo.aclose()
            if out is None:
                sys.exit("proses lain sedang menjalankan siklus neraca air")
            if not out:
                sys.exit("plot tidak diproses (lihat log)")
            print_result(out[0])
            print("\nprediksi tidak ditulis (sudah ada < 50 menit)" if out[0].skipped_duplicate
                  else "\nledger dan prediksi ditulis")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
