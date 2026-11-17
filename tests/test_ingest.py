"""Skenario uji wajib 1-10 dari spesifikasi, plus beberapa kasus tepi."""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from app.csvparse import EVENTS_HEADER, READINGS_HEADER

from .conftest import NODE1, NODE2, PLOT, TOKEN2, headers

R = "/v1/ingest/readings"
E = "/v1/ingest/clock-events"
WIB = timezone(timedelta(hours=7))


def readings_csv(rows: list[str]) -> str:
    return READINGS_HEADER + "\n" + "\n".join(rows) + "\n"


def events_csv(rows: list[str]) -> str:
    return EVENTS_HEADER + "\n" + "\n".join(rows) + "\n"


def make_rows(n: int, start="2026-10-07T10:00:00+07:00", clk="a3f1c2d0", flags=1) -> list[str]:
    t0 = datetime.fromisoformat(start)
    return [
        f"{(t0 + timedelta(minutes=i)).isoformat()},{60 * (i + 1)},{clk},{flags},"
        f"24.3,31.2,410,6.1,12,8,95,27.40,81.00,0.00,1234"
        for i in range(n)
    ]


async def fetch_rows(admin, node=NODE1):
    return await admin.fetch(
        "select * from public.sensor_raw_readings where node_id = $1 order by reading_timestamp_raw",
        node,
    )


# 1 --------------------------------------------------------------------------
async def test_valid_chunk_all_inserted(client, admin):
    rows = make_rows(5)
    r = await client.post(R, content=readings_csv(rows), headers=headers())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["inserted"] == 5 and body["duplicates"] == 0 and body["rejected"] == []
    assert isinstance(body["server_time"], int)

    db_rows = await fetch_rows(admin)
    assert len(db_rows) == 5
    for row in db_rows:
        assert row["reading_timestamp"] == row["reading_timestamp_raw"]
        assert row["time_status"] == "unverified"  # flags=1, belum ada event
        assert row["plot_id"] == PLOT
        assert row["clock_segment"] == "a3f1c2d0"
        assert row["soil_ph"] == pytest.approx(6.1) and row["rainfall_tip_count"] == 1234
        assert row["rainfall_mm"] == 0.0  # 0.00 tetap 0, bukan NULL
        assert row["quality_flag"] is None
    assert db_rows[0]["uptime_s"] == 60 and db_rows[0]["device_flags"] == 1

    node = await admin.fetchrow("select last_seen_at, firmware_version from public.nodes where id = $1", NODE1)
    assert node["last_seen_at"] is not None and node["firmware_version"] == "smile-v7.0"


async def test_verified_flags_status_verified(client, admin):
    r = await client.post(R, content=readings_csv(make_rows(1, flags=0)), headers=headers())
    assert r.status_code == 200
    assert (await fetch_rows(admin))[0]["time_status"] == "verified"


# 2 --------------------------------------------------------------------------
async def test_same_chunk_twice_is_deduplicated(client, admin):
    body = readings_csv(make_rows(10))
    first = (await client.post(R, content=body, headers=headers())).json()
    second = (await client.post(R, content=body, headers=headers())).json()
    assert first["inserted"] == 10 and first["duplicates"] == 0
    assert second["inserted"] == 0 and second["duplicates"] == 10
    assert len(await fetch_rows(admin)) == 10


async def test_duplicate_lines_within_one_chunk(client, admin):
    rows = make_rows(3)
    r = await client.post(R, content=readings_csv(rows + [rows[1]]), headers=headers())
    assert r.json()["inserted"] == 3 and r.json()["duplicates"] == 1


# 3 --------------------------------------------------------------------------
async def test_one_bad_line_does_not_fail_chunk(client, admin):
    rows = make_rows(5)
    rows[2] = "2026-10-07T10:02:00,180,a3f1c2d0,1,24.3,31.2,410,6.1,12,8,95,27.40,81.00,0.00,1234"
    r = await client.post(R, content=readings_csv(rows), headers=headers())
    assert r.status_code == 200
    body = r.json()
    assert body["inserted"] == 4
    # header = baris 1, jadi baris data ke-3 = baris 4 (sama dengan contoh di spesifikasi)
    assert body["rejected"] == [{"line": 4, "reason": "ts_raw: missing offset"}]

    rej = await admin.fetch("select * from public.ingest_rejects")
    assert len(rej) == 1
    assert rej[0]["node_id"] == NODE1 and rej[0]["endpoint"] == R
    assert rej[0]["line_no"] == 4 and rej[0]["raw_line"] == rows[2]


@pytest.mark.parametrize(
    "line,reason",
    [
        ("2026-10-07T10:00:00+07:00,60,a3f1c2d0,1,1,2", "expected 15 fields, got 6"),
        ("2023-10-07T10:00:00+07:00,60,a3f1c2d0,1,,,,,,,,,,,", "ts_raw: year out of range 2024-2099"),
        ("2026-10-07T10:00:00+07:00,60,A3F1C2D0,1,,,,,,,,,,,", "clk: must be 8 lowercase hex chars"),
        ("2026-10-07T10:00:00+07:00,6.5,a3f1c2d0,1,,,,,,,,,,,", "up: not an integer"),
        ("2026-10-07T10:00:00+07:00,60,a3f1c2d0,x,,,,,,,,,,,", "flags: not an integer"),
        ("07/10/2026 10:00,60,a3f1c2d0,1,,,,,,,,,,,", "ts_raw: not ISO 8601"),
    ],
)
async def test_structural_rejects(client, admin, line, reason):
    r = await client.post(R, content=readings_csv([line]), headers=headers())
    assert r.status_code == 200
    assert r.json()["rejected"] == [{"line": 2, "reason": reason}]


async def test_future_timestamp_rejected_only_when_verified(client, admin):
    future = (datetime.now(WIB) + timedelta(minutes=30)).replace(microsecond=0).isoformat()
    verified = f"{future},60,a3f1c2d0,0,,,,,,,,,,,"
    unverified = f"{future},60,b3f1c2d0,1,,,,,,,,,,,"
    r = await client.post(R, content=readings_csv([verified, unverified]), headers=headers())
    body = r.json()
    assert body["inserted"] == 1
    assert body["rejected"] == [{"line": 2, "reason": "ts_raw: more than 10 min in the future"}]


# 4 --------------------------------------------------------------------------
async def test_wrong_csv_header_400(client):
    body = "ts,up,clk\n2026-10-07T10:00:00+07:00,60,a3f1c2d0\n"
    assert (await client.post(R, content=body, headers=headers())).status_code == 400
    assert (await client.post(E, content=readings_csv([]), headers=headers())).status_code == 400


async def test_wrong_token_401(client):
    r = await client.post(R, content=readings_csv(make_rows(1)), headers=headers(token="nope"))
    assert r.status_code == 401


async def test_other_nodes_token_401(client, admin):
    r = await client.post(R, content=readings_csv(make_rows(1)), headers=headers(node=NODE1, token=TOKEN2))
    assert r.status_code == 401
    assert await fetch_rows(admin) == []


async def test_missing_auth_401(client):
    h = headers()
    del h["Authorization"]
    assert (await client.post(R, content=readings_csv(make_rows(1)), headers=h)).status_code == 401
    h = headers(**{"X-Node-Id": "not-a-uuid"})
    assert (await client.post(R, content=readings_csv(make_rows(1)), headers=h)).status_code == 401


async def test_unknown_node_401(client):
    h = headers(node="33333333-3333-3333-3333-333333333333")
    assert (await client.post(R, content=readings_csv(make_rows(1)), headers=h)).status_code == 401


async def test_body_too_large_413(client, admin):
    rows = make_rows(1) * 800  # ~70 KB
    r = await client.post(R, content=readings_csv(rows), headers=headers())
    assert r.status_code == 413
    assert await fetch_rows(admin) == []


async def test_schema_version_and_content_type(client):
    body = readings_csv(make_rows(1))
    assert (await client.post(R, content=body, headers=headers(**{"X-Schema-Version": "2"}))).status_code == 422
    assert (await client.post(R, content=body, headers=headers(**{"Content-Type": "application/json"}))).status_code == 415
    ok = headers(**{"Content-Type": "text/csv; charset=utf-8"})
    assert (await client.post(R, content=body, headers=ok)).status_code == 200


async def test_new_token_works_immediately_despite_cache(client, admin):
    body = readings_csv(make_rows(1))
    assert (await client.post(R, content=body, headers=headers())).status_code == 200  # isi cache
    from app.auth import hash_token
    await admin.execute("update public.nodes set api_token_hash = $2 where id = $1", NODE1, hash_token("rotated"))
    assert (await client.post(R, content=body, headers=headers(token="rotated"))).status_code == 200


# 5, 6 -----------------------------------------------------------------------
EVENT_CONST = "a3f1c2d0,2026-10-07T13:00:00+07:00,2026-10-07T13:02:57+07:00,177,0,2026-10-07T09:58:00+07:00,ntp"


async def _final_state(admin):
    return [
        (r["reading_timestamp_raw"], r["reading_timestamp"], r["time_status"])
        for r in await fetch_rows(admin)
    ]


async def test_event_before_data_corrects_constant(client, admin):
    r = await client.post(E, content=events_csv([EVENT_CONST]), headers=headers())
    assert r.status_code == 200 and r.json()["inserted"] == 1
    r = await client.post(R, content=readings_csv(make_rows(5)), headers=headers())
    assert r.json()["inserted"] == 5

    for raw, corrected, status in await _final_state(admin):
        assert corrected - raw == timedelta(seconds=177)
        assert status == "corrected_constant"

    ev = await admin.fetchrow("select * from public.clock_events")
    assert ev["delta_s"] == 177 and ev["start_verified"] is False and ev["ref_source"] == "ntp"
    assert ev["segment_start"] == datetime.fromisoformat("2026-10-07T09:58:00+07:00")


async def test_data_before_event_gives_identical_result(client, admin):
    await client.post(E, content=events_csv([EVENT_CONST]), headers=headers())
    await client.post(R, content=readings_csv(make_rows(5)), headers=headers())
    expected = await _final_state(admin)

    await admin.execute("truncate public.sensor_raw_readings, public.clock_events")
    r = await client.post(R, content=readings_csv(make_rows(5)), headers=headers())
    assert r.json()["inserted"] == 5
    assert all(s == "unverified" for _, _, s in await _final_state(admin))
    r = await client.post(E, content=events_csv([EVENT_CONST]), headers=headers())
    assert r.json()["inserted"] == 1

    assert await _final_state(admin) == expected


async def test_duplicate_event_is_ignored(client, admin):
    await client.post(E, content=events_csv([EVENT_CONST]), headers=headers())
    other = EVENT_CONST.replace(",177,", ",999,")
    r = await client.post(E, content=events_csv([other]), headers=headers())
    assert r.json()["inserted"] == 0 and r.json()["duplicates"] == 1
    assert await admin.fetchval("select delta_s from public.clock_events") == 177


async def test_event_does_not_touch_other_node(client, admin):
    await client.post(R, content=readings_csv(make_rows(2)), headers=headers(node=NODE2, token=TOKEN2))
    await client.post(E, content=events_csv([EVENT_CONST]), headers=headers())
    rows = await fetch_rows(admin, NODE2)
    assert len(rows) == 2
    assert all(r["time_status"] == "unverified" for r in rows)
    assert all(r["reading_timestamp"] == r["reading_timestamp_raw"] for r in rows)


# 7 --------------------------------------------------------------------------
async def test_start_verified_linear_correction(client, admin):
    # Segmen 10:00 -> 11:00 (RTC), delta +60 s. Baris 10:30 = tengah segmen.
    event = "c0ffee00,2026-10-07T11:00:00+07:00,2026-10-07T11:01:00+07:00,60,1,2026-10-07T10:00:00+07:00,server"
    rows = [
        f"2026-10-07T10:{m:02d}:00+07:00,{m * 60},c0ffee00,0,,,,,,,,27.40,81.00,0.00,1"
        for m in (0, 30, 59)
    ]
    for order in ("event-first", "data-first"):
        await admin.execute("truncate public.sensor_raw_readings, public.clock_events")
        if order == "event-first":
            await client.post(E, content=events_csv([event]), headers=headers())
        await client.post(R, content=readings_csv(rows), headers=headers())
        if order == "data-first":
            await client.post(E, content=events_csv([event]), headers=headers())

        state = await _final_state(admin)
        shifts = [(c - r).total_seconds() for r, c, _ in state]
        assert shifts == [0.0, 30.0, 59.0], (order, shifts)
        assert {s for _, _, s in state} == {"corrected_linear"}


async def test_event_line_validation(client, admin):
    bad = [
        "a3f1c2d0,2026-10-07T13:00:00+07:00,2026-10-07T13:02:57+07:00,1.5,0,,ntp",
        "a3f1c2d0,2026-10-07T13:00:00+07:00,2026-10-07T13:02:57+07:00,177,2,,ntp",
        "a3f1c2d0,2026-10-07T13:00:00+07:00,2026-10-07T13:02:57+07:00,177,0,,gps",
        "a3f1c2d0,2026-10-07T13:00:00,2026-10-07T13:02:57+07:00,177,0,,ntp",
        "a3f1c2d0,2026-10-07T13:00:00+07:00",
    ]
    good = "b3f1c2d0,2026-10-07T13:00:00+07:00,2026-10-07T12:59:58+07:00,-2,0,,server"
    r = await client.post(E, content=events_csv(bad + [good]), headers=headers())
    body = r.json()
    assert r.status_code == 200 and body["inserted"] == 1
    assert [x["line"] for x in body["rejected"]] == [2, 3, 4, 5, 6]
    assert body["rejected"][3]["reason"] == "rtc_before: missing offset"
    assert await admin.fetchval("select count(*) from public.ingest_rejects where endpoint = $1", E) == 5
    assert await admin.fetchval("select segment_start from public.clock_events") is None


# 8 --------------------------------------------------------------------------
async def test_empty_fields_null_and_out_of_range(client, admin):
    rows = [
        "2026-10-07T10:04:12+07:00,244,a3f1c2d0,5,,,,,,,,27.50,80.80,0.00,1234",
        "2026-10-07T10:05:12+07:00,304,a3f1c2d0,1,24.3,31.2,410,15.2,12,8,95,27.40,81.00,0.00,1234",
        "2026-10-07T10:06:12+07:00,364,a3f1c2d0,25,24.3,131,410,6.1,,,,,,abc,",
    ]
    r = await client.post(R, content=readings_csv(rows), headers=headers())
    assert r.json()["inserted"] == 3 and r.json()["rejected"] == []
    a, b, c = await fetch_rows(admin)

    for col in ("soil_temperature_c", "soil_moisture_pct", "soil_ec_uscm", "soil_ph",
                "soil_n_mgkg", "soil_p_mgkg", "soil_k_mgkg"):
        assert a[col] is None
    assert a["air_temperature_c"] == 27.5 and a["rainfall_mm"] == 0.0
    assert a["quality_flag"] == "soil_fail"

    assert b["soil_ph"] is None and b["soil_temperature_c"] == 24.3
    assert b["quality_flag"] == "oor:soil_ph=15.2"

    assert c["soil_moisture_pct"] is None and c["rainfall_mm"] is None and c["rainfall_tip_count"] is None
    assert c["quality_flag"] == "sht_fail,rain_fail,oor:soil_m=131,bad:rain_mm=abc"


# 9 --------------------------------------------------------------------------
async def test_db_dies_mid_request_rolls_back(client, admin):
    """Koneksi DB putus di tengah transaksi: readings sudah di-INSERT tetapi
    belum commit (transaksi tertahan di insert ingest_rejects). Server harus
    membalas 5xx dan tidak boleh ada baris yang tersimpan."""
    rows = make_rows(5)
    rows[1] = "garbage"
    body = readings_csv(rows)

    blocker = admin
    tx = blocker.transaction()
    await tx.start()
    await blocker.execute("lock table public.ingest_rejects in access exclusive mode")

    task = asyncio.create_task(client.post(R, content=body, headers=headers()))
    pid = None
    for _ in range(100):
        pid = await client_pid_waiting(admin_conn := await _new_admin())
        await admin_conn.close()
        if pid:
            break
        await asyncio.sleep(0.05)
    assert pid, "request tidak pernah tertahan di lock"

    killer = await _new_admin()
    await killer.execute("select pg_terminate_backend($1)", pid)
    await killer.close()

    r = await task
    await tx.rollback()
    assert r.status_code == 503
    assert await fetch_rows(admin) == []
    assert await admin.fetchval("select count(*) from public.ingest_rejects") == 0

    # Pool pulih sendiri; kiriman ulang dari node masuk normal.
    r = await client.post(R, content=body, headers=headers())
    assert r.status_code == 200 and r.json()["inserted"] == 4


async def _new_admin():
    import asyncpg
    from .conftest import ADMIN_TEST_DSN
    return await asyncpg.connect(ADMIN_TEST_DSN)


async def client_pid_waiting(conn):
    return await conn.fetchval(
        "select pid from pg_stat_activity where usename = 'smile_ingest' "
        "and wait_event_type = 'Lock' limit 1"
    )


async def test_db_unreachable_returns_503(client_db_down):
    r = await client_db_down.post(R, content=readings_csv(make_rows(1)), headers=headers())
    assert r.status_code == 503
    r = await client_db_down.post(E, content=events_csv([EVENT_CONST]), headers=headers())
    assert r.status_code == 503


# 10 -------------------------------------------------------------------------
async def test_health_ok(client):
    r = await client.get("/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok" and body["db"] == "ok"
    assert type(body["server_time"]) is int
    assert abs(body["server_time"] - datetime.now(timezone.utc).timestamp()) < 5


async def test_health_when_db_down(client_db_down):
    loop = asyncio.get_running_loop()
    t0 = loop.time()
    r = await client_db_down.get("/v1/health")
    assert loop.time() - t0 < 1.5
    assert r.status_code == 200
    body = r.json()
    assert body["db"] == "down" and type(body["server_time"]) is int
