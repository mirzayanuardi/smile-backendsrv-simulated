"""Kanal aktuator v8: uji wajib 1-11 dari prompt, plus beberapa kasus tepi."""

from __future__ import annotations

import time
import uuid
from datetime import datetime, timedelta, timezone

import asyncpg
import pytest

from app import dispatcher
from app.actuator import ActuatorSchema, FertigationSettings, load_schema, parse_xact
from app.csvparse import ACTUATIONS_HEADER, EVENTS_HEADER

from .conftest import INGEST_DSN, NODE1, NODE2, PLOT, TOKEN2, headers

CMD = "/v1/commands"
A = "/v1/ingest/actuations"
E = "/v1/ingest/clock-events"
WIB = timezone(timedelta(hours=7))
MODEL = uuid.UUID("00000000-0000-0000-0000-0000000000c1")
TS = "2026-10-11T07:02:11+07:00"
CLK = "a3f1c2d0"
DEFAULT_G = (
    "G 1 max_run=600 max_water_day=1800 max_dose_day=300 min_gap=1800 prewet=30 flush=30 "
    "fb_thr=-1 fb_run=120 fb_off_h=24 m_start=6 m_end=9 stop_thr=-1"
)
NO_FERT = FertigationSettings()


def act_csv(rows: list[str]) -> str:
    return ACTUATIONS_HEADER + "\n" + "\n".join(rows) + "\n"


def act_row(ev="5e1a90cc", cmd="", command="irrigate", trigger="manual", clk=CLK, ts=TS,
            water="60", dose="0", status="executed", detail="") -> str:
    return ",".join([ev, str(cmd), command, trigger, clk, ts, water, dose, status, detail])


async def new_command(admin, command="irrigate", water_s=60, dose_s=None, trigger="manual", node=NODE1):
    return await admin.fetchval(
        "insert into public.actuator_commands (node_id, plot_id, command, water_s, dose_s, trigger) "
        "values ($1, $2, $3, $4, $5, $6) returning id",
        node, PLOT, command, water_s, dose_s, trigger,
    )


async def new_batch(admin, node=NODE1, grams=200.0, volume_l=10.0):
    """Larutan contoh: NPK 15-15-15, 200 g dalam 10 L -> 0,003 g N/mL dan 0,003 g K2O/mL."""
    product = await admin.fetchval(
        "insert into public.fertilizer_products (name, n_pct, p_pct, k_pct, is_verified) "
        "values ('NPK 15-15-15', 15, 15, 15, true) returning id")
    batch = await admin.fetchval(
        "insert into public.nutrient_batches (node_id, name, solution_volume_l) values ($1, 'uji', $2) "
        "returning id", node, volume_l)
    await admin.execute(
        "insert into public.nutrient_batch_items (batch_id, product_id, amount_g) values ($1, $2, $3)",
        batch, product, grams)
    return batch


async def poll(client, xact: str | None = None, **kw):
    h = headers(**kw)
    if xact is not None:
        h["X-Act"] = xact
    r = await client.get(CMD, headers=h)
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "text/plain; charset=utf-8"
    return r.text.splitlines()


async def report(client, rows: list[str]):
    r = await client.post(A, content=act_csv(rows), headers=headers())
    assert r.status_code == 200, r.text
    return r.json()


async def command_row(admin, cid):
    return await admin.fetchrow("select * from public.actuator_commands where id = $1", cid)


async def irrigation_rows(admin):
    return await admin.fetch("select * from public.irrigation_actions order by created_at")


async def fertigation_rows(admin):
    return await admin.fetch("select * from public.fertigation_actions order by created_at")


@pytest.fixture
async def ingest():
    """Koneksi sebagai smile_ingest, untuk memanggil dispatcher langsung."""
    conn = await asyncpg.connect(INGEST_DSN)
    try:
        yield conn
    finally:
        await conn.close()


def at_wib(hour: int) -> datetime:
    return datetime.now(WIB).replace(hour=hour, minute=0, second=0, microsecond=0)


async def new_prediction(admin, mm=2.0, triggered=True, age_min=0):
    return await admin.fetchval(
        "insert into public.irrigation_predictions (plot_id, model_id, prediction_timestamp, "
        "irrigation_triggered, recommended_irrigation_mm, reason, created_at) "
        "values ($1, $2, now(), $3, $4, 'Dr >= RAW', now() - make_interval(mins => $5)) returning id",
        PLOT, MODEL, triggered, mm, age_min,
    )


# 1 --------------------------------------------------------------------------
async def test_pending_command_is_sent_once(client, admin):
    cid = await new_command(admin)
    lines = await poll(client, "w=0;d=0;cmd=-;left=0;res=1;cfg=1;tw=0;td=0")
    assert lines[0].startswith("T ") and abs(int(lines[0][2:]) - time.time()) < 5
    assert len(lines) == 2
    c, uid, command, trig, water, dose, ttl = lines[1].split(" ")
    assert (c, uid, command, trig, water, dose) == ("C", str(cid), "irrigate", "manual", "60", "0")
    assert 595 <= int(ttl) <= 600

    row = await command_row(admin, cid)
    assert row["status"] == "sent" and row["sent_at"] is not None

    lines = await poll(client, "w=0;d=0;cmd=-;cfg=1")
    assert [line for line in lines if line.startswith("C ")] == []


async def test_poll_limits_to_four_in_created_order(client, admin):
    ids = [await new_command(admin, "stop", None) for _ in range(5)]
    lines = await poll(client, "cfg=1")
    sent = [line.split(" ")[1] for line in lines if line.startswith("C ")]
    assert sent == [str(i) for i in ids[:4]]
    assert lines[1].split(" ")[2:6] == ["stop", "manual", "0", "0"]
    lines = await poll(client, "cfg=1")
    assert [line.split(" ")[1] for line in lines if line.startswith("C ")] == [str(ids[4])]


async def test_expired_pending_not_sent(client, admin):
    cid = await new_command(admin)
    await admin.execute("update public.actuator_commands set expires_at = now() - interval '1 s' where id = $1", cid)
    lines = await poll(client, "cfg=1")
    assert len(lines) == 1
    assert (await command_row(admin, cid))["status"] == "pending"


async def test_other_node_commands_not_visible(client, admin):
    await new_command(admin)
    lines = await poll(client, "cfg=1", node=NODE2, token=TOKEN2)
    assert [line for line in lines if line.startswith("C ")] == []


# 2 --------------------------------------------------------------------------
async def test_xact_running_and_pump_state(client, admin):
    cid = await new_command(admin)
    await poll(client, "cfg=1")
    await poll(client, f"w=1;d=0;cmd={cid};left=55;res=1;cfg=1;tw=5;td=0")

    row = await command_row(admin, cid)
    assert row["status"] == "running" and row["started_at"] is not None
    node = await admin.fetchrow("select * from public.nodes where id = $1", NODE1)
    assert node["valve_is_on"] is True and node["pump_is_on"] is False
    first_change = node["valve_updated_at"]
    assert first_change is not None and node["pump_updated_at"] is None

    # Nilai sama -> *_updated_at tidak berubah
    await poll(client, f"w=1;d=0;cmd={cid};cfg=1")
    node = await admin.fetchrow("select * from public.nodes where id = $1", NODE1)
    assert node["valve_updated_at"] == first_change

    await poll(client, "w=0;d=0;cmd=-;cfg=1")
    node = await admin.fetchrow("select * from public.nodes where id = $1", NODE1)
    assert node["valve_is_on"] is False and node["valve_updated_at"] > first_change
    assert (await command_row(admin, cid))["status"] == "running"


async def test_running_only_from_sent(client, admin):
    cid = await new_command(admin)  # masih pending
    await client.get(CMD, headers={**headers(), "X-Act": f"w=1;cmd={cid};cfg=1"})
    # poll yang sama mengirimnya (sent), tapi baru poll berikutnya yang boleh -> running
    assert (await command_row(admin, cid))["status"] == "sent"


@pytest.mark.parametrize("xact", [None, "", "garbage", "w=banana;d=7;cmd=xyz;cfg=-1;left=;;", "w=1;cmd"])
async def test_bad_xact_never_fails(client, admin, xact):
    lines = await poll(client, xact)
    assert lines[0].startswith("T ")
    node = await admin.fetchrow("select valve_is_on, pump_is_on from public.nodes where id = $1", NODE1)
    assert node["valve_is_on"] is (xact == "w=1;cmd")


def test_parse_xact_partial():
    a = parse_xact("w=1;d=x;cmd=-;cfg=3")
    assert (a.w, a.d, a.cmd, a.cfg) == (True, None, None, 3)


async def test_commands_requires_auth(client):
    r = await client.get(CMD, headers=headers(token="wrong"))
    assert r.status_code == 401


# 3 --------------------------------------------------------------------------
async def test_config_line_only_when_version_differs(client, admin):
    lines = await poll(client, "w=0;d=0;cmd=-;cfg=0")
    assert lines[1] == DEFAULT_G
    lines = await poll(client, "w=0;d=0;cmd=-;cfg=1")
    assert len(lines) == 1
    # Header tanpa cfg -> versi ESP tidak diketahui -> kirim config
    assert (await poll(client, "w=0"))[1] == DEFAULT_G

    await admin.execute(
        "update public.node_actuator_config set fallback_threshold_raw = 35.5, min_gap_s = 2400 where node_id = $1",
        NODE1,
    )
    lines = await poll(client, "cfg=1")
    assert lines[1] == (
        "G 2 max_run=600 max_water_day=1800 max_dose_day=300 min_gap=2400 prewet=30 flush=30 "
        "fb_thr=35.5 fb_run=120 fb_off_h=24 m_start=6 m_end=9 stop_thr=-1"
    )


async def test_stop_threshold_from_calibration(client, admin):
    """v11 uji 15: rem jenuh = bacaan mentah setara theta_FC (59,5 %) lewat kalibrasi [5, 1.2]."""
    assert (await poll(client, "cfg=0"))[1].endswith(" stop_thr=-1")
    await admin.execute(
        "insert into public.sensor_calibrations (node_id, parameter, coeffs, raw_min, raw_max, source) "
        "values ($1, 'soil_moisture', array[5, 1.2], 0, 100, 'uji')", NODE1)
    g = (await poll(client, "cfg=1"))[1]
    assert g.startswith("G 2 ") and g.endswith(" stop_thr=45.4")  # (59,5 - 5) / 1,2
    assert " fb_thr=40.4 " in g                                     # theta pemicu 53,5 %


async def test_no_config_row_no_g(client, admin):
    await admin.execute("delete from public.node_actuator_config where node_id = $1", NODE2)
    lines = await poll(client, "cfg=0", node=NODE2, token=TOKEN2)
    assert len(lines) == 1 and lines[0].startswith("T ")


# 4 --------------------------------------------------------------------------
async def test_executed_report_creates_history_once(client, admin):
    cid = await new_command(admin)
    await poll(client, "cfg=1")
    rows = [act_row(cmd=cid)]
    body = await report(client, rows)
    assert body["inserted"] == 1 and body["duplicates"] == 0 and body["rejected"] == []

    hist = await irrigation_rows(admin)
    assert len(hist) == 1
    h = hist[0]
    assert h["execution_status"] == "success" and h["triggered_by"] == "manual"
    assert h["valve_action"] == "open" and h["duration_sec"] == 60
    assert h["estimated_volume_liter"] == pytest.approx(60 / 60 * 1.2)
    assert h["command_id"] == cid and h["device_event_id"] == "5e1a90cc" and h["plot_id"] == PLOT
    assert h["node_id"] == NODE1 and h["clock_segment"] == CLK
    assert h["action_timestamp"] == h["action_timestamp_raw"] == datetime.fromisoformat(TS)
    assert await fertigation_rows(admin) == []

    c = await command_row(admin, cid)
    assert c["status"] == "executed" and c["actual_water_s"] == 60
    assert c["finished_at"] == datetime.fromisoformat(TS) + timedelta(seconds=60)

    body = await report(client, rows)
    assert body["inserted"] == 0 and body["duplicates"] == 1
    assert len(await irrigation_rows(admin)) == 1


async def test_triggered_by_comes_from_command(client, admin):
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    cid = await new_command(admin, trigger="rule_engine")
    # ESP salah mengisi trigger; server tetap memakai trigger dari actuator_commands
    await report(client, [act_row(cmd=cid, trigger="manual")])
    assert (await irrigation_rows(admin))[0]["triggered_by"] == "rule_engine"


async def test_final_status_not_overwritten(client, admin):
    cid = await new_command(admin)
    await report(client, [act_row(cmd=cid, status="executed")])
    body = await report(client, [act_row(ev="0000beef", cmd=cid, status="interrupted", water="", dose="")])
    assert (await command_row(admin, cid))["status"] == "executed"
    # baris riwayat kedua tetap tercatat (event ESP berbeda)
    assert body["inserted"] == 1 and len(await irrigation_rows(admin)) == 2


# 5 --------------------------------------------------------------------------
async def test_stopped_and_interrupted(client, admin):
    c1 = await new_command(admin)
    await report(client, [act_row(cmd=c1, water="23", status="stopped", detail="stop_command")])
    h = (await irrigation_rows(admin))[0]
    assert h["execution_status"] == "overridden" and h["duration_sec"] == 23
    assert h["detail"] == "stop_command"
    assert (await command_row(admin, c1))["status"] == "stopped"

    c2 = await new_command(admin)
    await report(client, [act_row(ev="c41f0a92", cmd=c2, water="", dose="", status="interrupted",
                                  detail="power_or_reset")])
    h = [r for r in await irrigation_rows(admin) if r["command_id"] == c2][0]
    assert h["duration_sec"] is None and h["estimated_volume_liter"] is None
    assert h["execution_status"] == "failed" and h["detail"] == "power_or_reset"
    c = await command_row(admin, c2)
    assert c["status"] == "interrupted" and c["actual_water_s"] is None


async def test_stop_command_executed_has_no_history(client, admin):
    stop = await new_command(admin, "stop", None)
    body = await report(client, [act_row(cmd=stop, command="stop", water="", dose="", detail="idle")])
    assert body["inserted"] == 1
    assert await irrigation_rows(admin) == []
    assert (await command_row(admin, stop))["status"] == "executed"


# 6 --------------------------------------------------------------------------
async def test_fertigate_writes_both_tables(client, admin):
    batch = await new_batch(admin)
    cid = await new_command(admin, "fertigate", water_s=90, dose_s=30)
    assert (await command_row(admin, cid))["nutrient_batch_id"] == batch  # diisi trigger
    await report(client, [act_row(cmd=cid, command="fertigate", water="90", dose="30", detail="ok")])

    irr = await irrigation_rows(admin)
    fert = await fertigation_rows(admin)
    assert len(irr) == 1 and len(fert) == 1
    i = irr[0]
    # Air total basahi + suntik + bilas, debit air 1,2 L/menit
    assert i["duration_sec"] == 90 and i["estimated_volume_liter"] == pytest.approx(90 / 60 * 1.2)
    assert i["triggered_by"] == "manual" and i["detail"] == "fertigasi"
    assert i["command_id"] == cid and i["device_event_id"] == "5e1a90cc"
    f = fert[0]
    assert f["actual_volume"] == pytest.approx(30 * 1.5 / 1000)  # liter larutan
    assert f["actual_duration_sec"] == 30 and f["pump_action"] == "on"
    assert f["nutrient_batch_id"] == batch and f["detail"] == "ok"
    assert f["execution_status"] == "success" and f["executed_by"] is None
    assert f["command_id"] == cid and f["device_event_id"] == "5e1a90cc" and f["plot_id"] == PLOT
    assert f["execution_timestamp_raw"] == datetime.fromisoformat(TS)
    c = await command_row(admin, cid)
    assert c["status"] == "executed" and (c["actual_water_s"], c["actual_dose_s"]) == (90, 30)

    await report(client, [act_row(cmd=cid, command="fertigate", water="90", dose="30")])
    assert len(await fertigation_rows(admin)) == 1 and len(await irrigation_rows(admin)) == 1


async def test_executed_by_mapping_only_with_valid_labels():
    schema = ActuatorSchema("t", "v", "e", "e", "x", frozenset({"auto", "manual"}),
                            frozenset({"naikkan", "normal", "tunda", "blokir"}), True)
    s = FertigationSettings.from_env("manual=manual, rule_engine=auto ,schedule=robot", "normal,bogus")
    v = s.validated(schema)
    assert v.executed_by == {"manual": "manual", "rule_engine": "auto"}
    assert v.auto_statuses == frozenset({"normal"})
    # Tanpa UPDATE (nutrient_batch_id) di rekomendasi, fertigasi auto dimatikan
    schema.can_mark_recommendation_batch = False
    assert s.validated(schema).auto_statuses == frozenset()


async def test_schema_reports_recommendation_batch_privilege(ingest):
    assert (await load_schema(ingest)).can_mark_recommendation_batch is True


# 7 --------------------------------------------------------------------------
async def test_soil_saturated_stop_is_success(client, admin):
    """v11 uji 16: firmware v8.3 menghentikan irigasi karena rem jenuh -> executed + soil_saturated."""
    cid = await new_command(admin, water_s=120)
    body = await report(client, [act_row(cmd=cid, water="47", detail="soil_saturated")])
    assert body["inserted"] == 1 and body["rejected"] == []
    [h] = await irrigation_rows(admin)
    assert (h["execution_status"], h["duration_sec"], h["detail"]) == ("success", 47, "soil_saturated")
    c = await command_row(admin, cid)
    assert (c["status"], c["actual_water_s"], c["result_detail"]) == ("executed", 47, "soil_saturated")


async def test_rejected_limit_no_history(client, admin):
    cid = await new_command(admin)
    await poll(client, "cfg=1")
    await report(client, [act_row(cmd=cid, water="", dose="", status="rejected_limit", detail="day_water")])
    assert await irrigation_rows(admin) == []
    c = await command_row(admin, cid)
    assert c["status"] == "rejected" and c["result_detail"] == "rejected_limit:day_water"
    assert c["started_at"] is None


async def test_expired_report(client, admin):
    cid = await new_command(admin)
    await report(client, [act_row(cmd=cid, water="", dose="", status="expired")])
    assert await irrigation_rows(admin) == []
    assert (await command_row(admin, cid))["status"] == "expired"


# 8 --------------------------------------------------------------------------
async def test_local_fallback_without_command(client, admin):
    body = await report(client, [act_row(ev="0b77d2e1", trigger="local_fallback", water="120")])
    assert body["inserted"] == 1
    h = (await irrigation_rows(admin))[0]
    assert h["triggered_by"] == "local_fallback" and h["command_id"] is None
    assert h["duration_sec"] == 120 and h["execution_status"] == "success"


async def test_contract_example_rows(client, admin):
    """Tiga baris contoh §4.2 (cmd_id dari baris pertama dibuat dulu)."""
    cid = await new_command(admin)
    body = await report(client, [
        act_row(ev="5e1a90cc", cmd=cid),
        "0b77d2e1,,irrigate,local_fallback,a3f1c2d0,2026-10-12T06:00:40+07:00,120,0,executed,",
        "c41f0a92,,irrigate,rule_engine,a3f1c2d0,2026-10-12T07:15:00+07:00,,,interrupted,power_or_reset",
    ])
    assert body == {**body, "inserted": 3, "duplicates": 0, "rejected": []}
    assert {r["triggered_by"] for r in await irrigation_rows(admin)} == {"manual", "local_fallback", "rule_engine"}


async def test_row_level_rejects(client, admin):
    foreign = uuid.uuid4()
    cid = await new_command(admin)
    body = await report(client, [
        act_row(ev="00000001", cmd=foreign),
        act_row(ev="00000002", cmd=cid, command="fertigate", water="50", dose="10"),
        act_row(ev="00000003", cmd=cid, trigger="local_fallback"),
        act_row(ev="ZZ"),
        act_row(ev="00000005", command="water"),
        act_row(ev="00000006", status="done"),
        act_row(ev="00000007", water="-1"),
        act_row(ev="00000008", ts="2026-10-11T07:02:11"),
        "00000009,,irrigate,manual",
        act_row(ev="0000000a", trigger="local_fallback"),
    ])
    reasons = {r["line"]: r["reason"] for r in body["rejected"]}
    assert reasons == {
        2: "cmd_id: unknown command for this node",
        3: "command: does not match cmd_id",
        4: "cmd_id: must be empty for local_fallback",
        5: "ev_id: must be 8 lowercase hex chars",
        6: "command: must be irrigate, fertigate or stop",
        7: "status: unknown value",
        8: "water_s: out of range",
        9: "ts_start: missing offset",
        10: "expected 10 fields, got 4",
    }
    assert body["inserted"] == 1 and body["duplicates"] == 0
    assert await admin.fetchval(
        "select count(*) from public.ingest_rejects where endpoint = $1", A) == 9


async def test_actuations_request_level_errors(client):
    r = await client.post(A, content="ev_id,cmd_id\n", headers=headers())
    assert r.status_code == 400
    r = await client.post(A, content=act_csv([act_row()]), headers=headers(**{"Content-Type": "text/plain"}))
    assert r.status_code == 415
    r = await client.post(A, content="x" * (64 * 1024 + 1), headers=headers())
    assert r.status_code == 413


# 9 --------------------------------------------------------------------------
async def test_clock_event_after_action_corrects_timestamp(client, admin):
    await new_batch(admin)
    cid = await new_command(admin, "fertigate", water_s=50, dose_s=10)
    await report(client, [act_row(cmd=cid, command="fertigate", water="50", dose="10")])
    event = f"{CLK},2026-10-11T09:00:00+07:00,2026-10-11T09:02:57+07:00,177,0,,ntp"
    r = await client.post(E, content=EVENTS_HEADER + "\n" + event + "\n", headers=headers())
    assert r.status_code == 200, r.text

    raw = datetime.fromisoformat(TS)
    h = (await irrigation_rows(admin))[0]
    assert h["action_timestamp_raw"] == raw
    assert h["action_timestamp"] - raw == timedelta(seconds=177)
    f = (await fertigation_rows(admin))[0]
    assert f["execution_timestamp"] - raw == timedelta(seconds=177)


async def test_clock_event_before_action_corrects_on_insert(client, admin):
    event = f"{CLK},2026-10-11T09:00:00+07:00,2026-10-11T09:02:57+07:00,177,0,,ntp"
    await client.post(E, content=EVENTS_HEADER + "\n" + event + "\n", headers=headers())
    await report(client, [act_row(trigger="local_fallback")])
    h = (await irrigation_rows(admin))[0]
    assert h["action_timestamp"] - h["action_timestamp_raw"] == timedelta(seconds=177)


# 10 -------------------------------------------------------------------------
async def test_dispatcher_converts_mm_to_seconds(admin, ingest):
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    pid = await new_prediction(admin, mm=2.0)
    out = await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7))
    [d] = out["decisions"]
    assert (d.result, d.water_s) == ("dispatched", 80)  # 2 mm x 0,8 m2 / 1,2 L/menit x 60

    c = await command_row(admin, d.command_id)
    assert (c["command"], c["water_s"], c["dose_s"], c["trigger"]) == ("irrigate", 80, None, "rule_engine")
    assert c["irrigation_prediction_id"] == pid and c["reason"] == "Dr >= RAW"
    assert c["status"] == "pending" and c["created_by"] is None
    p = await admin.fetchrow("select * from public.irrigation_predictions where id = $1", pid)
    assert p["dispatched_command_id"] == d.command_id and p["dispatch_note"] is None

    # Siklus berikutnya tidak mengirim ulang prediksi yang sama
    out = await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7))
    assert out["decisions"] == []


async def test_dispatcher_outside_window(admin, ingest):
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    pid = await new_prediction(admin)
    out = await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(12))
    assert [d.result for d in out["decisions"]] == ["outside_window"]
    assert await admin.fetchval("select dispatch_note from public.irrigation_predictions where id = $1", pid) == "outside_window"
    assert await admin.fetchval("select count(*) from public.actuator_commands") == 0


async def test_dispatcher_rejected_by_trigger_when_mode_manual(admin, ingest):
    """Mode berubah ke manual antara pemilihan kandidat dan insert: trigger menolak."""
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    pid = await new_prediction(admin)
    [row] = await ingest.fetch(dispatcher._IRRIGATION_CANDIDATES)
    await admin.execute("update public.nodes set valve_mode = 'manual' where id = $1", NODE1)
    async with ingest.transaction():
        d = await dispatcher._decide(ingest, "irrigation", row, at_wib(7))
    assert d.result == "rejected"
    note = await admin.fetchval("select dispatch_note from public.irrigation_predictions where id = $1", pid)
    assert note == "rejected: irigasi sedang mode MANUAL; perintah otomatis ditolak"
    assert await admin.fetchval("select count(*) from public.actuator_commands") == 0
    # Tidak dicoba lagi walaupun mode kembali auto
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)
    assert (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"] == []


async def test_dispatcher_manual_mode_node_is_not_a_candidate(admin, ingest):
    await new_prediction(admin)  # NODE1 masih manual (fixture)
    assert (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"] == []


async def test_dispatcher_min_gap_busy_small_clamped_stale(client, admin, ingest):
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)

    # too_small: 0,05 mm -> 2 s
    p = await new_prediction(admin, mm=0.05)
    [d] = (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"]
    assert d.result == "too_small"

    # clamped: 20 mm -> 800 s -> 600 s
    p = await new_prediction(admin, mm=20)
    [d] = (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"]
    assert (d.result, d.water_s) == ("clamped", 600)
    assert (await command_row(admin, d.command_id))["reason"] == "Dr >= RAW [clamped water_s 800->600]"

    # busy: perintah tadi masih pending -> dilewati tanpa catatan
    p = await new_prediction(admin)
    [d] = (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"]
    assert d.result == "busy"
    assert await admin.fetchval("select dispatch_note from public.irrigation_predictions where id = $1", p) is None

    # min_gap: perintah tadi dijalankan ESP -> irigasi terakhir baru saja
    await poll(client, "cfg=1")
    [d] = (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"]
    assert d.result == "busy"  # sent masih dihitung tumpuk
    await poll(client, f"w=1;cmd={(await admin.fetchval('select id from public.actuator_commands'))};cfg=1")
    [d] = (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"]
    assert d.result == "min_gap"

    # Prediksi lebih tua dari 30 menit diabaikan
    await admin.execute("truncate public.irrigation_predictions cascade")
    await new_prediction(admin, age_min=31)
    assert (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"] == []


FERT_NORMAL = FertigationSettings(auto_statuses=frozenset({"normal"}))


async def new_recommendation(admin, pump_s=None, n=None, p2o5=None, k2o=None):
    return await admin.fetchval(
        "insert into public.fertigation_recommendations (plot_id, model_id, recommendation_timestamp, "
        "pump_duration_seconds, target_n_g, target_p2o5_g, target_k2o_g, status, reason) "
        "values ($1, $2, now(), $3, $4, $5, $6, 'normal', 'EC rendah') returning id",
        PLOT, MODEL, pump_s, n, p2o5, k2o)


async def recommendation(admin, rid):
    return await admin.fetchrow("select * from public.fertigation_recommendations where id = $1", rid)


async def test_dispatcher_fertigation_disabled_by_default(admin, ingest):
    """Rekomendasi format lama (tanpa target gram): pump_duration_seconds seperti v8."""
    await admin.execute("update public.nodes set pump_mode = 'auto' where id = $1", NODE1)
    batch = await new_batch(admin)
    rid = await new_recommendation(admin, pump_s=12.5)
    assert (await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(7)))["decisions"] == []

    [d] = (await dispatcher.run_cycle(ingest, FERT_NORMAL, now=at_wib(7)))["decisions"]
    assert (d.result, d.dose_s, d.water_s) == ("dispatched", 13, 30 + 13 + 30)  # basahi + suntik + bilas
    c = await command_row(admin, d.command_id)
    assert c["command"] == "fertigate" and c["fertigation_recommendation_id"] == rid
    assert c["nutrient_batch_id"] == batch
    assert (await recommendation(admin, rid))["nutrient_batch_id"] == batch


async def test_dispatcher_fertigation_dose_from_target_grams(admin, ingest):
    await admin.execute("update public.nodes set pump_mode = 'auto' where id = $1", NODE1)
    await admin.execute("update public.node_actuator_config set dose_flow_ml_per_s = 2 where node_id = $1", NODE1)
    batch = await new_batch(admin)
    # pump_duration_seconds diabaikan kalau target gram ada
    rid = await new_recommendation(admin, pump_s=12.5, n=1.0, k2o=1.0)
    expected = await admin.fetchval("select public.smile_dose_seconds($1, 1, null, 1, 2)", batch)
    assert expected == 167  # 1 g / 0,003 g/mL / 2 mL/s = 166,7 -> dibulatkan ke atas

    [d] = (await dispatcher.run_cycle(ingest, FERT_NORMAL, now=at_wib(7)))["decisions"]
    assert (d.result, d.dose_s, d.water_s, d.batch_id) == ("dispatched", expected, 30 + expected + 30, batch)
    c = await command_row(admin, d.command_id)
    assert (c["dose_s"], c["water_s"], c["nutrient_batch_id"]) == (expected, 30 + expected + 30, batch)
    r = await recommendation(admin, rid)
    assert (r["dispatched_command_id"], r["nutrient_batch_id"], r["dispatch_note"]) == (d.command_id, batch, None)


async def test_dispatcher_fertigation_no_active_batch(admin, ingest):
    await admin.execute("update public.nodes set pump_mode = 'auto' where id = $1", NODE1)
    batch = await new_batch(admin)
    await admin.execute("update public.nutrient_batches set is_active = false where id = $1", batch)
    rid = await new_recommendation(admin, n=1.0)
    [d] = (await dispatcher.run_cycle(ingest, FERT_NORMAL, now=at_wib(7)))["decisions"]
    assert d.result == "no_active_batch"
    r = await recommendation(admin, rid)
    assert (r["dispatch_note"], r["nutrient_batch_id"]) == ("no_active_batch", None)
    assert await admin.fetchval("select count(*) from public.actuator_commands") == 0


async def test_dispatcher_fertigation_dose_too_long(admin, ingest):
    await admin.execute("update public.nodes set pump_mode = 'auto' where id = $1", NODE1)
    await admin.execute("update public.node_actuator_config set dose_flow_ml_per_s = 2, max_run_s = 200 "
                        "where node_id = $1", NODE1)
    batch = await new_batch(admin)
    rid = await new_recommendation(admin, n=1.0, k2o=1.0)  # 30 + 167 + 30 = 227 > 200
    [d] = (await dispatcher.run_cycle(ingest, FERT_NORMAL, now=at_wib(7)))["decisions"]
    assert (d.result, d.dose_s, d.water_s) == ("dose_too_long", 167, 227)
    r = await recommendation(admin, rid)
    assert (r["dispatch_note"], r["nutrient_batch_id"], r["dispatched_command_id"]) == ("dose_too_long", batch, None)
    assert await admin.fetchval("select count(*) from public.actuator_commands") == 0


async def test_dispatcher_fertigation_dose_uncomputable(admin, ingest):
    await admin.execute("update public.nodes set pump_mode = 'auto' where id = $1", NODE1)
    await new_batch(admin)
    rid = await new_recommendation(admin, p2o5=0.0)  # target ada tapi nol -> fungsi NULL
    [d] = (await dispatcher.run_cycle(ingest, FERT_NORMAL, now=at_wib(7)))["decisions"]
    assert d.result == "dose_uncomputable"
    assert (await recommendation(admin, rid))["dispatch_note"] == "dose_uncomputable"


async def test_dispatcher_single_runner(admin, ingest):
    other = await asyncpg.connect(INGEST_DSN)
    try:
        async with other.transaction():
            assert await other.fetchval("select pg_try_advisory_xact_lock($1)", dispatcher.DISPATCH_LOCK_KEY)
            assert await dispatcher.run_cycle(ingest, NO_FERT) is None
    finally:
        await other.close()


def test_conversion_helpers():
    assert dispatcher.round_half_up(dispatcher.irrigation_seconds(2, 0.8, 1.2)) == 80
    assert dispatcher.round_half_up(2.5) == 3
    assert dispatcher.in_morning_window(datetime(2026, 10, 11, 23, 30, tzinfo=timezone.utc), 6, 9)  # 06:30 WIB
    assert not dispatcher.in_morning_window(datetime(2026, 10, 11, 2, 0, tzinfo=timezone.utc), 6, 9)  # 09:00 WIB


# 11 -------------------------------------------------------------------------
async def test_dispatcher_expires_stale_pending(admin, ingest):
    cid = await new_command(admin)
    await admin.execute("update public.actuator_commands set expires_at = now() - interval '1 s' where id = $1", cid)
    out = await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(12))
    assert out["expired"] == 1
    c = await command_row(admin, cid)
    assert c["status"] == "expired" and c["result_detail"] == "not_fetched"
