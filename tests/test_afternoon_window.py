"""Jendela sore (AFTERNOON_WINDOW): dispatcher menyiram sore hanya kalau pagi itu belum ada air."""

from __future__ import annotations

from datetime import timedelta

import pytest

from app import dispatcher

from .conftest import NODE1, PLOT
from .test_actuator import NO_FERT, at_wib, ingest, new_command, new_prediction  # noqa: F401 - fixture ingest

AFTERNOON = (15, 18)


async def auto(admin):
    await admin.execute("update public.nodes set valve_mode = 'auto' where id = $1", NODE1)


async def irrigated_at(admin, ts, status="success", trigger="rule_engine"):
    await admin.execute(
        "insert into public.irrigation_actions (plot_id, node_id, action_timestamp, triggered_by, valve_action, "
        "duration_sec, estimated_volume_liter, execution_status) "
        "values ($1, $2, $3, $4::text::trigger_type, 'open', 120, 2.4, $5::text::execution_status)",
        PLOT, NODE1, ts, trigger, status,
    )


async def run(ingest, hour, afternoon=AFTERNOON):
    out = await dispatcher.run_cycle(ingest, NO_FERT, now=at_wib(hour), afternoon=afternoon)
    [d] = out["decisions"]
    return d


async def test_afternoon_off_by_default(admin, ingest):
    await auto(admin)
    await new_prediction(admin)
    assert (await run(ingest, 16, afternoon=None)).result == "outside_window"


async def test_afternoon_dispatches_when_morning_dry(admin, ingest):
    await auto(admin)
    await irrigated_at(admin, at_wib(7) - timedelta(days=1))      # kemarin pagi tidak dihitung
    await new_prediction(admin, mm=2.0)
    d = await run(ingest, 16)
    assert (d.result, d.water_s) == ("dispatched", 80)          # 2 mm x 0,8 m2 / 1,2 L/menit x 60


@pytest.mark.parametrize("trigger", ["rule_engine", "manual", "local_fallback"])
async def test_morning_irrigation_blocks_afternoon(admin, ingest, trigger):
    await auto(admin)
    await irrigated_at(admin, at_wib(7), trigger=trigger)
    pid = await new_prediction(admin)
    assert (await run(ingest, 16)).result == "morning_irrigated"
    p = await admin.fetchrow("select dispatch_note, dispatched_command_id from public.irrigation_predictions "
                             "where id = $1", pid)
    assert p["dispatch_note"] == "morning_irrigated" and p["dispatched_command_id"] is None


async def test_started_command_without_report_blocks_afternoon(admin, ingest):
    cid = await new_command(admin, trigger="manual")              # node masih manual saat dibuat
    await admin.execute("update public.actuator_commands set status = 'executed', started_at = $2 where id = $1",
                        cid, at_wib(8))
    await auto(admin)
    await new_prediction(admin)
    assert (await run(ingest, 16)).result == "morning_irrigated"


async def test_outside_both_windows(admin, ingest):
    await auto(admin)
    await new_prediction(admin)
    assert (await run(ingest, 12)).result == "outside_window"
    await new_prediction(admin)
    assert (await run(ingest, 18)).result == "outside_window"   # akhir jendela eksklusif


@pytest.mark.parametrize("raw, expected", [("15-18", (15, 18)), ("", None), ("18-15", None),
                                           ("15", None), ("abc", None), ("0-24", (0, 24))])
def test_parse_env(monkeypatch, raw, expected):
    monkeypatch.setenv("AFTERNOON_WINDOW", raw)
    assert dispatcher.afternoon_window_from_env() == expected


def test_window_bounds():
    s, e = dispatcher.window_bounds(at_wib(16), 6, 9)
    assert (s.hour, e.hour, s.date() == e.date()) == (6, 9, True)
    assert dispatcher.window_bounds(at_wib(16), 15, 24)[1] - dispatcher.window_bounds(at_wib(16), 15, 24)[0] \
        == timedelta(hours=9)
