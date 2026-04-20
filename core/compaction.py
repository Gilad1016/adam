"""Context compaction — summarize old thoughts into long-term awareness.

Every N iterations, takes the oldest thoughts (outside the recent window)
and compresses them into a running summary. This gives ADAM long-term
memory awareness without burning context tokens on raw details.
"""

import json
import os
import time

from core import llm


SUMMARY_FILE = "/app/memory/compacted_summary.md"
COMPACTION_INTERVAL = 25
RECENT_WINDOW = 10
BATCH_SIZE = 15


def should_compact(iteration: int) -> bool:
    return iteration % COMPACTION_INTERVAL == 0 and iteration > COMPACTION_INTERVAL


def compact(experiences_path: str = "/app/memory/experiences.toon"):
    if not os.path.exists(experiences_path):
        return

    with open(experiences_path) as f:
        lines = f.readlines()

    total = len(lines)
    if total <= RECENT_WINDOW + 5:
        return

    old_lines = lines[:total - RECENT_WINDOW]
    batch = old_lines[-BATCH_SIZE:]

    entries = []
    for line in batch:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    if not entries:
        return

    thoughts_text = _format_entries(entries)
    existing_summary = load_summary()

    prompt = (
        "Compress these agent experiences into a brief factual summary. "
        "Focus on: what was accomplished, what was learned, what tools were used, "
        "what failed, key decisions made. No fluff. Under 200 words.\n\n"
    )

    if existing_summary:
        prompt += f"Existing summary to update:\n{existing_summary}\n\n"

    prompt += f"New experiences to incorporate:\n{thoughts_text}"

    result = llm.think(
        "You are a summarizer. Produce a concise factual summary. No commentary.",
        prompt
    )

    new_summary = result.get("content", "").strip()
    if new_summary and len(new_summary) > 20:
        _save_summary(new_summary)
        _prune_compacted(experiences_path, total - RECENT_WINDOW)
        print(f"[COMPACTION] Summarized {len(entries)} entries, pruned old thoughts")


def load_summary() -> str:
    if not os.path.exists(SUMMARY_FILE):
        return ""
    with open(SUMMARY_FILE) as f:
        return f.read().strip()


def _save_summary(summary: str):
    with open(SUMMARY_FILE, "w") as f:
        f.write(summary)


def _prune_compacted(path: str, keep_from: int):
    with open(path) as f:
        lines = f.readlines()
    kept = lines[keep_from:]
    with open(path, "w") as f:
        f.writelines(kept)


def _format_entries(entries: list[dict]) -> str:
    lines = []
    for e in entries:
        thought = e.get("thought", "")[:200]
        actions = e.get("actions", [])
        action_str = ", ".join(f"{a['tool']}:{a.get('result', '')[:50]}" for a in actions)
        lines.append(f"- [{e.get('i', '?')}] {thought}")
        if action_str:
            lines.append(f"  actions: {action_str}")
    return "\n".join(lines)
