"""Backfill cuaca reanalisis Open-Meteo archive ke weather_observed_hourly (satu kali).

    python scripts/backfill_weather_observed.py [--from 2026-10-01] [--to 2026-10-19] [--plot <uuid>]

Tanggal UTC, inklusif; default 2026-10-01 s.d. hari ini (WIB). Memakai klien, upsert
(ON CONFLICT DO UPDATE), dan kunci advisory yang sama dengan job harian 03:00 WIB,
jadi aman diulang dan tidak berjalan bersamaan dengan job itu. Hari-hari terakhir
(ERA5 tertunda ±5 hari) bisa masih kosong; job harian mengisinya kemudian.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import uuid
from datetime import date, datetime, timezone
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import water_balance as wb  # noqa: E402
from app import weather  # noqa: E402
from app.dispatcher import WIB  # noqa: E402
from scripts.run_water_balance import _dsn  # noqa: E402


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="from_", type=date.fromisoformat, default=date(2026, 10, 1))
    ap.add_argument("--to", type=date.fromisoformat, default=None)
    ap.add_argument("--plot", type=uuid.UUID, action="append", help="boleh diulang; default semua plot aktif")
    args = ap.parse_args()
    end = args.to or datetime.now(timezone.utc).astimezone(WIB).date()
    if end < args.from_:
        sys.exit("--to harus >= --from")

    meteo = weather.OpenMeteo(weather.WXSettings.from_env())
    conn = await asyncpg.connect(_dsn(), statement_cache_size=0)
    try:
        access = await wb.check_access(conn)
        stats = await weather.run_observed_cycle(conn, meteo, start=args.from_, end=end,
                                                 plot_ids=args.plot, node_meta=access["node_meta"])
    finally:
        await conn.close()
        await meteo.aclose()
    if stats is None:
        sys.exit("job observasi sedang berjalan di proses lain; coba lagi nanti")
    print(f"{args.from_}..{end}: {stats['plots']} plot, {stats['rows']} baris, {stats['duration_ms']} ms")
    for e in stats["errors"]:
        print(f"  error: {e}")
    if stats["errors"]:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
