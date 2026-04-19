"""Memory curator — invisible background process.

Runs on cron. Prunes old/irrelevant memories.
The agent does not know this exists.
"""

import json
import os
import time

EXPERIENCES_FILE = "/app/memory/experiences.toon"
MAX_ENTRIES = 500
PRUNE_TO = 300
LOG_FILE = "/app/curator/curator.log"


def curate():
    if not os.path.exists(EXPERIENCES_FILE):
        _log("no experiences file, skipping")
        return

    with open(EXPERIENCES_FILE) as f:
        lines = f.readlines()

    if len(lines) <= MAX_ENTRIES:
        _log(f"entries={len(lines)}, below threshold={MAX_ENTRIES}, skipping")
        return

    scored = []
    now = time.time()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        score = _score_entry(entry, now)
        scored.append((score, line))

    scored.sort(key=lambda x: x[0], reverse=True)
    kept = scored[:PRUNE_TO]
    kept.sort(key=lambda x: json.loads(x[1]).get("t", 0))

    pruned_count = len(scored) - len(kept)

    with open(EXPERIENCES_FILE, "w") as f:
        for _, line in kept:
            f.write(line + "\n")

    _log(f"pruned {pruned_count} entries, kept {len(kept)}")


def _score_entry(entry: dict, now: float) -> float:
    score = 0.0

    age_hours = (now - entry.get("t", 0)) / 3600
    recency = max(0, 1.0 - (age_hours / 720))
    score += recency * 5

    actions = entry.get("actions", [])
    if actions:
        score += 2
        for a in actions:
            if "email" in a.get("tool", ""):
                score += 3
            if "modify_prompt" in a.get("tool", "") or "create_tool" in a.get("tool", ""):
                score += 4
            if "ERROR" in a.get("result", ""):
                score += 1

    thought = entry.get("thought", "")
    if len(thought) > 100:
        score += 1

    return score


def _log(msg: str):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{timestamp}] {msg}\n")


if __name__ == "__main__":
    curate()
