#!/usr/bin/env python3
"""Simulator node SMILE v7/v8: membuat CSV persis seperti firmware lalu
mengirim clock events kemudian readings, seperti urutan firmware.

Mode --actuator (v8): poll GET /v1/commands dengan header X-Act, menjalankan
perintah secara virtual (pompa air + pompa pupuk, rem dasar firmware), lalu
mengirim laporan CSV ke /v1/ingest/actuations.

Hanya memakai stdlib, jadi bisa dijalankan di laptop mana pun.

Contoh:
  python scripts/sim_node.py --url https://ingest.nirbatas.id \\
      --node <uuid> --token <token> --minutes 150 --delta 177

  # uji dedup: kirim ulang semua chunk yang sama
  python scripts/sim_node.py ... --resend

  # tes lokal tanpa TLS
  python scripts/sim_node.py --url http://127.0.0.1:8000 ...

  # aktuator virtual: poll tiap 15 s selama 10 menit
  python scripts/sim_node.py --url ... --node <uuid> --token <token> --actuator --run-s 600

  # simulasi WiFi putus 15 menit dulu, poll lebih cepat untuk uji di meja
  python scripts/sim_node.py ... --actuator --offline-s 900 --poll-s 5
"""

from __future__ import annotations

import argparse
import json
import random
import secrets
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

READINGS_HEADER = (
    "ts_raw,up,clk,flags,soil_t,soil_m,soil_ec,soil_ph,"
    "soil_n,soil_p,soil_k,air_t,air_h,rain_mm,rain_tips"
)
EVENTS_HEADER = "clk,rtc_before,ref_time,delta_s,start_verified,seg_start,ref_source"
ACTUATIONS_HEADER = "ev_id,cmd_id,command,trigger,clk,ts_start,water_s,dose_s,status,detail"
WIB = timezone(timedelta(hours=7))

F_TIME_UNVERIFIED, F_SOIL_FAIL, F_SHT_FAIL = 1, 4, 8


def iso(t: datetime) -> str:
    return t.astimezone(WIB).replace(microsecond=0).isoformat()


def build_rows(args, clk: str, t0: datetime) -> list[str]:
    rnd = random.Random(args.seed)
    rows = []
    rain_mm, tips = 12.4, 1234
    for i in range(args.minutes):
        t = t0 + timedelta(minutes=i)
        up = args.uptime0 + 60 * i
        flags = 0 if args.start_verified else F_TIME_UNVERIFIED
        soil = [
            f"{24 + rnd.uniform(-1, 1):.1f}", f"{args.soil_m + rnd.uniform(-2, 2):.1f}",
            f"{410 + rnd.randint(-20, 20)}", f"{6.1 + rnd.uniform(-0.2, 0.2):.1f}",
        ]
        npk = ["", "", ""] if args.no_npk else [str(rnd.randint(10, 14)), str(rnd.randint(6, 10)), str(rnd.randint(90, 100))]
        air = [f"{27.4 + rnd.uniform(-1, 1):.2f}", f"{81 + rnd.uniform(-3, 3):.2f}"]
        if rnd.random() < args.fail_rate:  # sensor tanah gagal baca
            flags |= F_SOIL_FAIL
            soil, npk = ["", "", "", ""], ["", "", ""]
        if rnd.random() < args.fail_rate:  # SHT31 gagal
            flags |= F_SHT_FAIL
            air = ["", ""]
        if rnd.random() < args.rain_rate:
            tips += 1
            rain_mm += 0.2
        rows.append(",".join([iso(t), str(up), clk, str(flags), *soil, *npk, *air, f"{rain_mm:.2f}", str(tips)]))
    return rows


def chunks(rows: list[str], max_rows: int = 100, max_bytes: int = 12 * 1024):
    cur, size = [], len(READINGS_HEADER) + 1
    for r in rows:
        if cur and (len(cur) >= max_rows or size + len(r) + 1 > max_bytes):
            yield cur
            cur, size = [], len(READINGS_HEADER) + 1
        cur.append(r)
        size += len(r) + 1
    if cur:
        yield cur


def post(args, path: str, body: str) -> tuple[int, dict | str]:
    req = urllib.request.Request(
        args.url.rstrip("/") + path,
        data=body.encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {args.token}",
            "X-Node-Id": args.node,
            "X-Firmware-Version": "smile-v7.0-sim",
            "X-Schema-Version": "1",
            "Content-Type": "text/csv",
            "User-Agent": "ESP32HTTPClient",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


class VirtualActuator:
    """Meniru perilaku firmware v8 secukupnya untuk uji alur §8 (bukan batas keras asli).

    Fertigasi tiga fase: basahi (w=1;d=0) -> suntik (w=1;d=1) -> bilas (w=1;d=0).
    """

    def __init__(self, args, clk: str):
        self.args = args
        self.clk = clk
        self.cfg = {"version": 0, "max_run": 600, "max_water_day": 1800, "max_dose_day": 300,
                    "prewet": 30, "flush": 30}
        self.run = None          # perintah yang sedang berjalan
        self.phase = None        # fase fertigasi terakhir yang dicetak
        self.seen: set[str] = set()
        self.outbox: list[str] = []
        self.tw = self.td = 0    # total detik hari ini

    def _elapsed(self) -> float:
        return time.monotonic() - self.run["t0"]

    def _dose_on(self) -> bool:
        return self._phase() == "suntik"

    def _phase(self) -> str | None:
        if not self.run or self.run["command"] != "fertigate":
            return None
        e, prewet = self._elapsed(), self.run["prewet"]
        if e < prewet:
            return "basahi"
        return "suntik" if e < prewet + self.run["dose_s"] else "bilas"

    def xact(self) -> str:
        w = 1 if self.run else 0
        left = max(0, int(self.run["water_s"] - self._elapsed())) if self.run else 0
        cmd = self.run["id"] if self.run else "-"
        tw = self.tw + (int(self._elapsed()) if self.run else 0)
        return f"w={w};d={int(self._dose_on())};cmd={cmd};left={left};res=1;cfg={self.cfg['version']};tw={tw};td={self.td}"

    def _event(self, cmd_id, command, trigger, ts, water, dose, status, detail="") -> None:
        row = ",".join([
            secrets.token_hex(4), cmd_id or "", command, trigger, self.clk, iso(ts),
            "" if water is None else str(water), "" if dose is None else str(dose), status, detail,
        ])
        print(f"  event: {row}")
        self.outbox.append(row)

    def _finish(self, status: str, detail: str = "") -> None:
        r = self.run
        water = min(r["water_s"], int(self._elapsed()))
        dose = 0
        if r["command"] == "fertigate":
            dose = max(0, min(r["dose_s"], water - r["prewet"]))
        self.tw += water
        self.td += dose
        self._event(r["id"], r["command"], r["trigger"], r["ts"], water, dose, status, detail)
        self.run = None
        self.phase = None

    def tick(self) -> None:
        phase = self._phase()
        if phase != self.phase and phase is not None:
            print(f"  fase {phase}: w=1;d={int(phase == 'suntik')} (t={self._elapsed():.0f} s)")
        self.phase = phase
        if self.run and self._elapsed() >= self.run["water_s"]:
            self._finish("executed")

    def apply(self, lines: list[str]) -> None:
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "G" and len(parts) >= 2:
                self.cfg["version"] = int(parts[1])
                for kv in parts[2:]:
                    k, _, v = kv.partition("=")
                    if k in self.cfg:
                        self.cfg[k] = int(float(v))
                print(f"  config v{self.cfg['version']}: {' '.join(parts[2:])}")
            elif parts[0] == "C" and len(parts) == 7:
                self._command(parts[1], parts[2], parts[3], int(parts[4]), int(parts[5]))

    def _command(self, cid, command, trigger, water_s, dose_s) -> None:
        if cid in self.seen:  # perintah ganda diabaikan
            return
        self.seen.add(cid)
        now = datetime.now(WIB)
        print(f"  perintah: {command} {trigger} water_s={water_s} dose_s={dose_s} ({cid})")
        if command == "stop":
            if self.run:
                self._finish("stopped", "stop_command")
                self._event(cid, "stop", trigger, now, None, None, "executed", "")
            else:
                self._event(cid, "stop", trigger, now, None, None, "executed", "idle")
            return
        reject = None
        if self.run:
            reject = ("rejected_limit", "busy")
        elif not 1 <= water_s <= self.cfg["max_run"]:
            reject = ("rejected_invalid", "water_s")
        elif self.tw + water_s > self.cfg["max_water_day"]:
            reject = ("rejected_limit", "day_water")
        elif command == "fertigate" and self.td + dose_s > self.cfg["max_dose_day"]:
            reject = ("rejected_limit", "day_dose")
        elif command == "fertigate" and dose_s > water_s - self.cfg["prewet"] - self.cfg["flush"]:
            reject = ("rejected_unsafe", "dose_or_flush")
        if reject:
            self._event(cid, command, trigger, now, None, None, *reject)
            return
        self.run = {"id": cid, "command": command, "trigger": trigger, "water_s": water_s,
                    "dose_s": dose_s, "t0": time.monotonic(), "ts": now,
                    # Sisa air setelah suntik adalah bilas; basahi memakai prewet dari config.
                    "prewet": self.cfg["prewet"]}


def http_get(args, path: str, extra: dict) -> tuple[int, str]:
    req = urllib.request.Request(
        args.url.rstrip("/") + path,
        method="GET",
        headers={
            "Authorization": f"Bearer {args.token}",
            "X-Node-Id": args.node,
            "X-Firmware-Version": "smile-v8.0-sim",
            "X-Schema-Version": "1",
            "User-Agent": "ESP32HTTPClient",
            **extra,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]
    except OSError as e:
        return 0, str(e)


def run_actuator(args) -> None:
    clk = args.clk or secrets.token_hex(4)
    act = VirtualActuator(args, clk)
    print(f"aktuator virtual node={args.node} clk={clk} poll={args.poll_s}s run={args.run_s}s")
    t_start = time.monotonic()
    next_poll = t_start + args.offline_s
    if args.offline_s:
        print(f"offline {args.offline_s} s (tidak poll)")
    while time.monotonic() - t_start < args.run_s:
        act.tick()
        if time.monotonic() >= next_poll:
            xact = act.xact()
            status, body = http_get(args, "/v1/commands", {"X-Act": xact})
            ts = datetime.now(WIB).strftime("%H:%M:%S")
            if status != 200:
                print(f"[{ts}] poll {status}: {body}")
            else:
                lines = body.splitlines()
                extra = [ln for ln in lines if not ln.startswith("T ")]
                print(f"[{ts}] poll X-Act={xact} -> {extra or 'idle'}")
                act.apply(lines)
            next_poll = time.monotonic() + args.poll_s
        if act.outbox:
            body = ACTUATIONS_HEADER + "\n" + "\n".join(act.outbox) + "\n"
            status, resp = post(args, "/v1/ingest/actuations", body)
            print(f"  actuations: {status} {resp}")
            if status == 200:
                act.outbox.clear()
        time.sleep(0.2)
    if act.run:
        print(f"selesai dengan perintah masih berjalan: {act.run['id']}")


def health(args) -> None:
    for attempt in range(3):
        try:
            with urllib.request.urlopen(args.url.rstrip("/") + "/v1/health", timeout=10) as r:
                body = json.loads(r.read())
                drift = body["server_time"] - int(time.time())
                print(f"health: {r.status} {body} (selisih jam lokal {drift:+d} s)")
                return
        except Exception as e:  # noqa: BLE001
            print(f"health percobaan {attempt + 1}: {e}")
            time.sleep(2)
    sys.exit("server tidak terjangkau")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--node", required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--minutes", type=int, default=150, help="jumlah baris (1 per menit)")
    p.add_argument("--delta", type=int, default=177, help="delta_s clock event (0 = tanpa event)")
    p.add_argument("--start-verified", action="store_true", help="segmen dimulai terverifikasi (koreksi linear)")
    p.add_argument("--clk", default=None, help="clock_segment; default acak")
    p.add_argument("--start", default=None, help="ISO waktu baris pertama; default sekarang - minutes")
    p.add_argument("--uptime0", type=int, default=184)
    p.add_argument("--fail-rate", type=float, default=0.05)
    p.add_argument("--soil-m", type=float, default=31.0,
                   help="kelembapan tanah MENTAH yang dikirim (±2); terkalibrasi = 13,279 + 0,5814 x mentah")
    p.add_argument("--rain-rate", type=float, default=0.05, help="peluang 1 tip hujan per menit (0 = kering)")
    p.add_argument("--no-npk", action="store_true")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--resend", action="store_true", help="kirim semua chunk dua kali (uji dedup)")
    p.add_argument("--data-first", action="store_true", help="kirim readings sebelum clock event")
    p.add_argument("--actuator", action="store_true", help="mode aktuator virtual (v8)")
    p.add_argument("--poll-s", type=float, default=15, help="jeda poll /v1/commands (firmware: 15)")
    p.add_argument("--run-s", type=float, default=600, help="lama simulasi aktuator (detik)")
    p.add_argument("--offline-s", type=float, default=0, help="tidak poll selama N detik pertama")
    args = p.parse_args()

    if args.actuator:
        health(args)
        run_actuator(args)
        return

    clk = args.clk or secrets.token_hex(4)
    if args.start:
        t0 = datetime.fromisoformat(args.start)
    else:
        t0 = (datetime.now(WIB) - timedelta(minutes=args.minutes + 2)).replace(second=12, microsecond=0)
    rows = build_rows(args, clk, t0)
    rtc_before = t0 + timedelta(minutes=args.minutes)
    event = ",".join([
        clk, iso(rtc_before), iso(rtc_before + timedelta(seconds=args.delta)), str(args.delta),
        "1" if args.start_verified else "0", iso(t0 - timedelta(seconds=30)), "ntp",
    ])

    print(f"node={args.node} clk={clk} rows={len(rows)} delta={args.delta}")
    health(args)

    def send_event():
        if args.delta:
            print("clock-events:", *post(args, "/v1/ingest/clock-events", EVENTS_HEADER + "\n" + event + "\n"))

    def send_readings():
        tot = {"inserted": 0, "duplicates": 0, "rejected": 0}
        for c in chunks(rows):
            status, body = post(args, "/v1/ingest/readings", READINGS_HEADER + "\n" + "\n".join(c) + "\n")
            if status != 200:
                print("readings:", status, body)
                continue
            tot["inserted"] += body["inserted"]
            tot["duplicates"] += body["duplicates"]
            tot["rejected"] += len(body["rejected"])
        print("readings total:", tot)

    for _ in range(2 if args.resend else 1):
        if args.data_first:
            send_readings()
            send_event()
        else:
            send_event()
            send_readings()


if __name__ == "__main__":
    main()
