"""Skill speciation — auto-detect repeated patterns and propose tools.

Runs periodically (triggered by the loop). Analyzes recent experiences
to find repeated tool-call sequences and proposes creating reusable tools.
"""

import json
import os
import time
from collections import Counter


EXPERIENCES_FILE = "/app/memory/experiences.toon"
SPECIATION_FILE = "/app/memory/speciation.json"
MIN_REPETITIONS = 3


def analyze() -> list[dict]:
    entries = _load_recent_entries(100)
    if len(entries) < 10:
        return []

    sequences = _extract_sequences(entries)
    repeated = _find_repeated(sequences)

    proposals = []
    existing = _load_existing_proposals()
    existing_names = {p["pattern"] for p in existing}

    for pattern, count in repeated:
        if pattern not in existing_names:
            proposals.append({
                "pattern": pattern,
                "count": count,
                "proposed_at": time.time(),
            })

    if proposals:
        existing.extend(proposals)
        _save_proposals(existing)

    return proposals


def get_pending_proposals() -> list[dict]:
    proposals = _load_existing_proposals()
    return [p for p in proposals if not p.get("resolved")]


def resolve_proposal(pattern: str, action: str):
    proposals = _load_existing_proposals()
    for p in proposals:
        if p["pattern"] == pattern:
            p["resolved"] = True
            p["action"] = action
            p["resolved_at"] = time.time()
    _save_proposals(proposals)


def _extract_sequences(entries: list[dict]) -> list[str]:
    sequences = []
    for i in range(len(entries) - 1):
        actions_a = [a["tool"] for a in entries[i].get("actions", [])]
        actions_b = [a["tool"] for a in entries[i + 1].get("actions", [])]
        if actions_a and actions_b:
            seq = " -> ".join(actions_a + actions_b)
            sequences.append(seq)

    for i in range(len(entries) - 2):
        actions = []
        for j in range(3):
            actions.extend([a["tool"] for a in entries[i + j].get("actions", [])])
        if actions:
            sequences.append(" -> ".join(actions))

    return sequences


def _find_repeated(sequences: list[str]) -> list[tuple[str, int]]:
    counter = Counter(sequences)
    return [(pattern, count) for pattern, count in counter.most_common(10)
            if count >= MIN_REPETITIONS]


def _load_recent_entries(n: int) -> list[dict]:
    if not os.path.exists(EXPERIENCES_FILE):
        return []
    try:
        with open(EXPERIENCES_FILE) as f:
            lines = f.readlines()
        entries = []
        for line in lines[-n:]:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return entries
    except Exception:
        return []


def _load_existing_proposals() -> list[dict]:
    if not os.path.exists(SPECIATION_FILE):
        return []
    try:
        with open(SPECIATION_FILE) as f:
            return json.loads(f.read())
    except Exception:
        return []


def _save_proposals(proposals: list[dict]):
    with open(SPECIATION_FILE, "w") as f:
        f.write(json.dumps(proposals, indent=2))
