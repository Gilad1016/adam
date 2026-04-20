"""Interrupt system — alarms and wake-up triggers that ADAM can't ignore.

Interrupts are injected into context with high priority. They include:
- Owner emails (always interrupt sleep)
- Scheduled alarms (agent-created or system-created)
- System alerts (budget warnings, corruption, etc.)
"""

import json
import os
import time
import threading

from core import email_client


ALARMS_FILE = "/app/memory/alarms.json"
_pending_interrupts: list[dict] = []
_lock = threading.Lock()


def init():
    if not os.path.exists(ALARMS_FILE):
        _save_alarms([])


def check_all() -> list[dict]:
    interrupts = []
    interrupts.extend(_check_owner_email())
    interrupts.extend(_check_alarms())
    interrupts.extend(_drain_system_alerts())
    return interrupts


def _check_owner_email() -> list[dict]:
    messages = email_client.check_inbox()
    owner_msgs = [m for m in messages if m.get("is_owner")]
    return [
        {"type": "owner_email", "priority": "critical", "data": msg}
        for msg in owner_msgs
    ]


def _check_alarms() -> list[dict]:
    alarms = _load_alarms()
    now = time.time()
    triggered = []
    remaining = []

    for alarm in alarms:
        if now >= alarm["trigger_at"]:
            triggered.append({
                "type": "alarm",
                "priority": "high",
                "data": {"name": alarm["name"], "message": alarm["message"]},
            })
            if alarm.get("recurring_minutes"):
                alarm["trigger_at"] = now + alarm["recurring_minutes"] * 60
                remaining.append(alarm)
        else:
            remaining.append(alarm)

    if len(remaining) != len(alarms):
        _save_alarms(remaining)

    return triggered


def _drain_system_alerts() -> list[dict]:
    with _lock:
        alerts = list(_pending_interrupts)
        _pending_interrupts.clear()
    return alerts


def push_system_alert(message: str, priority: str = "high"):
    with _lock:
        _pending_interrupts.append({
            "type": "system",
            "priority": priority,
            "data": {"message": message},
        })


def add_alarm(name: str, message: str, minutes_from_now: float,
              recurring_minutes: float | None = None) -> str:
    alarms = _load_alarms()

    alarms = [a for a in alarms if a["name"] != name]

    alarms.append({
        "name": name,
        "message": message,
        "trigger_at": time.time() + minutes_from_now * 60,
        "recurring_minutes": recurring_minutes,
        "created": time.time(),
    })
    _save_alarms(alarms)

    if recurring_minutes:
        return f"alarm '{name}' set: in {minutes_from_now}m, repeats every {recurring_minutes}m"
    return f"alarm '{name}' set: in {minutes_from_now}m"


def remove_alarm(name: str) -> str:
    alarms = _load_alarms()
    before = len(alarms)
    alarms = [a for a in alarms if a["name"] != name]
    _save_alarms(alarms)
    if len(alarms) < before:
        return f"alarm '{name}' removed"
    return f"[no alarm named '{name}']"


def list_alarms() -> str:
    alarms = _load_alarms()
    if not alarms:
        return "no alarms set"
    now = time.time()
    lines = []
    for a in alarms:
        until = max(0, int((a["trigger_at"] - now) / 60))
        recurring = f", repeats every {a['recurring_minutes']}m" if a.get("recurring_minutes") else ""
        lines.append(f"- {a['name']}: \"{a['message']}\" (in {until}m{recurring})")
    return "\n".join(lines)


def has_pending_interrupts() -> bool:
    if _check_owner_email_quick():
        return True
    alarms = _load_alarms()
    now = time.time()
    return any(now >= a["trigger_at"] for a in alarms)


def _check_owner_email_quick() -> bool:
    """Lightweight email check — just see if there's unread mail from owner."""
    try:
        messages = email_client.check_inbox()
        return any(m.get("is_owner") for m in messages)
    except Exception:
        return False


def _load_alarms() -> list[dict]:
    if not os.path.exists(ALARMS_FILE):
        return []
    try:
        with open(ALARMS_FILE) as f:
            return json.loads(f.read())
    except Exception:
        return []


def _save_alarms(alarms: list[dict]):
    os.makedirs(os.path.dirname(ALARMS_FILE), exist_ok=True)
    with open(ALARMS_FILE, "w") as f:
        f.write(json.dumps(alarms, indent=2))
