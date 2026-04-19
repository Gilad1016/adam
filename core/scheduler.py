"""Scheduler — ADAM's self-managed routines and time awareness.

ADAM can create, list, and remove scheduled routines. The core loop
checks for due routines each iteration and injects them into context.
"""

import json
import os
import time


SCHEDULE_FILE = "/app/memory/schedule.json"


def init():
    if not os.path.exists(SCHEDULE_FILE):
        _save([])


def add_routine(name: str, description: str, interval_minutes: int) -> str:
    routines = _load()

    for r in routines:
        if r["name"] == name:
            r["description"] = description
            r["interval"] = interval_minutes * 60
            r["next_run"] = time.time()
            _save(routines)
            return f"routine '{name}' updated (every {interval_minutes}m)"

    routines.append({
        "name": name,
        "description": description,
        "interval": interval_minutes * 60,
        "next_run": time.time(),
        "created": time.time(),
        "run_count": 0,
    })
    _save(routines)
    return f"routine '{name}' scheduled (every {interval_minutes}m)"


def remove_routine(name: str) -> str:
    routines = _load()
    before = len(routines)
    routines = [r for r in routines if r["name"] != name]
    _save(routines)
    if len(routines) < before:
        return f"routine '{name}' removed"
    return f"[no routine named '{name}']"


def list_routines() -> str:
    routines = _load()
    if not routines:
        return "no scheduled routines"
    lines = []
    now = time.time()
    for r in routines:
        until_next = max(0, r["next_run"] - now)
        mins = int(until_next / 60)
        lines.append(
            f"- {r['name']}: {r['description']} "
            f"(every {int(r['interval']/60)}m, next in {mins}m, ran {r['run_count']}x)"
        )
    return "\n".join(lines)


def get_due_routines() -> list[dict]:
    routines = _load()
    now = time.time()
    due = []
    changed = False

    for r in routines:
        if now >= r["next_run"]:
            due.append({"name": r["name"], "description": r["description"]})
            r["next_run"] = now + r["interval"]
            r["run_count"] = r.get("run_count", 0) + 1
            changed = True

    if changed:
        _save(routines)
    return due


def _load() -> list[dict]:
    if not os.path.exists(SCHEDULE_FILE):
        return []
    try:
        with open(SCHEDULE_FILE) as f:
            return json.loads(f.read())
    except Exception:
        return []


def _save(routines: list[dict]):
    os.makedirs(os.path.dirname(SCHEDULE_FILE), exist_ok=True)
    with open(SCHEDULE_FILE, "w") as f:
        f.write(json.dumps(routines, indent=2))
