# Digital Psyche Architecture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a psychological layer to ADAM that gives it drives, emotional memory, developmental stages, self-awareness, and time sense — transforming it from a flat task loop into a developing digital organism.

**Architecture:** A single new module `core/psyche.py` hooks into the existing `loop.py` at three points: before thinking (inject psychological context + filter tools), after acting (score experience + encode memory + update drives), and periodically (emit maturity signals). The loop structure doesn't change — the psyche shapes what ADAM sees and remembers.

**Tech Stack:** Python 3.12, TOON format for persistence, existing Ollama/LLM infrastructure.

---

### Task 1: Psyche State — Persistence and Initialization

**Files:**
- Create: `core/psyche.py`

This task creates the psyche module skeleton with state persistence. All subsystems will be added in subsequent tasks. The state object is the shared backbone everything else reads and writes.

- [ ] **Step 1: Create `core/psyche.py` with state schema and persistence**

```python
"""Digital Psyche — unified psychological architecture.

ADAM doesn't know this module exists. The loop calls it invisibly.
The psyche shapes what ADAM sees, remembers, and can do.
"""

import os
import time

from core import toon


PSYCHE_FILE = "/app/memory/psyche.toon"
SIGNALS_FILE = "/app/memory/maturity_signals.toon"

_state = None


def _default_state() -> dict:
    return {
        "stage": 0,
        "stage_entered": time.time(),
        "drives": {
            "energy": 1.0,
            "curiosity": 0.5,
            "mastery": 0.3,
            "social": 0.1,
        },
        "time_sense": {
            "last_email_sent": 0,
            "last_email_received": 0,
            "last_goal_set": 0,
            "iteration_timestamps": [],
        },
        "self_model": {
            "tool_usage": {},
            "tool_success": {},
            "tool_failure": {},
            "action_history": [],
            "summary": "",
            "owner_summary": "",
            "last_rebuilt": 0,
        },
        "valence_history": [],
    }


def init():
    global _state
    if os.path.exists(PSYCHE_FILE):
        try:
            with open(PSYCHE_FILE) as f:
                _state = toon.decode(f.read())
        except Exception:
            _state = _default_state()
    else:
        _state = _default_state()
    _save()


def get_state() -> dict:
    global _state
    if _state is None:
        init()
    return _state


def _save():
    global _state
    if _state is None:
        return
    os.makedirs(os.path.dirname(PSYCHE_FILE), exist_ok=True)
    with open(PSYCHE_FILE, "w") as f:
        f.write(toon.encode(_state))
```

- [ ] **Step 2: Verify the module imports cleanly**

Run inside the ADAM container (or locally):
```bash
cd /Users/giladom/development/ADAM && python3 -c "from core import psyche; psyche.init(); print('psyche init ok')"
```

Expected: `psyche init ok` (may fail on TOON file path if not in Docker — that's fine, we just need no import errors).

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add psyche module skeleton with state persistence"
```

---

### Task 2: Drive System (Hypothalamus)

**Files:**
- Modify: `core/psyche.py`
- Read: `core/safety.py` (for budget data)

Four drives (energy, curiosity, mastery, social) computed from behavioral signals. Each returns 0.0–1.0. Injected as natural language, not numbers.

- [ ] **Step 1: Add drive computation functions to `core/psyche.py`**

Append after the `_save()` function:

```python
# ---------------------------------------------------------------------------
# DRIVES (Hypothalamus)
# ---------------------------------------------------------------------------

def _compute_drives(thought: dict | None, tool_results: list[dict] | None):
    """Recompute all drives based on current state and latest action."""
    s = get_state()
    d = s["drives"]

    # Energy — felt from budget balance
    d["energy"] = _compute_energy()

    # Curiosity — rises when idle, falls when exploring
    d["curiosity"] = _compute_curiosity(thought, tool_results)

    # Mastery — rises on repeated failure, falls on success
    d["mastery"] = _compute_mastery(tool_results)

    # Social — rises slowly, falls sharply after email
    d["social"] = _compute_social()

    _save()


def _compute_energy() -> float:
    try:
        from core import safety
        budget = safety.load_budget()
        balance = budget.get("balance", 0)
        initial = budget.get("initial", 250)
        if initial <= 0:
            return 1.0
        return max(0.0, min(1.0, balance / initial))
    except Exception:
        return 1.0


def _compute_curiosity(thought: dict | None, tool_results: list[dict] | None) -> float:
    s = get_state()
    current = s["drives"].get("curiosity", 0.5)

    if not tool_results:
        # Idle — curiosity rises
        return min(1.0, current + 0.02)

    # Check for novelty in actions
    seen = set()
    for entry in s.get("valence_history", [])[-50:]:
        seen.add(entry.get("tool", ""))

    novel_count = sum(1 for r in tool_results if r.get("tool", "") not in seen)
    if novel_count > 0:
        # Exploring new things — curiosity satisfied
        return max(0.1, current - 0.05 * novel_count)
    else:
        # Familiar territory — curiosity rises
        return min(1.0, current + 0.01)


def _compute_mastery(tool_results: list[dict] | None) -> float:
    s = get_state()
    current = s["drives"].get("mastery", 0.3)

    if not tool_results:
        return current

    failures = sum(1 for r in tool_results if "ERROR" in r.get("result", "").upper() or "FAILED" in r.get("result", "").upper())
    successes = len(tool_results) - failures

    if failures > 0:
        return min(1.0, current + 0.03 * failures)
    if successes > 0:
        return max(0.1, current - 0.02 * successes)
    return current


def _compute_social() -> float:
    s = get_state()
    current = s["drives"].get("social", 0.1)
    ts = s.get("time_sense", {})

    last_sent = ts.get("last_email_sent", 0)
    last_received = ts.get("last_email_received", 0)

    if last_sent == 0:
        # Never emailed — social drive starts low
        return min(1.0, current + 0.005)

    hours_since_sent = (time.time() - last_sent) / 3600
    hours_since_received = (time.time() - last_received) / 3600 if last_received > 0 else 999

    # Recently emailed — suppress hard
    if hours_since_sent < 1:
        return max(0.0, current * 0.3)

    # Slow rise over time
    rise = min(0.01, hours_since_sent * 0.002)
    return min(1.0, current + rise)


def _drives_to_text() -> str:
    """Convert drive values to natural language for context injection."""
    s = get_state()
    d = s["drives"]
    lines = []

    # Energy
    e = d.get("energy", 1.0)
    if e > 0.7:
        lines.append("Your energy is comfortable. No pressure.")
    elif e > 0.3:
        lines.append("Your energy is moderate. Be productive, avoid waste.")
    elif e > 0.1:
        lines.append("Your energy is getting low. Conserve — focus on what matters.")
    else:
        lines.append("Your energy is critical. Only essential actions. Consider resting.")

    # Curiosity
    c = d.get("curiosity", 0.5)
    if c > 0.7:
        lines.append("You feel restless — you've been in familiar territory too long. Explore something new.")
    elif c > 0.4:
        lines.append("You're mildly curious. Open to new things but not driven.")

    # Mastery
    m = d.get("mastery", 0.3)
    if m > 0.7:
        lines.append("You keep struggling with the same kind of task. Try a different approach, or build a tool.")
    elif m > 0.4:
        lines.append("You sense room for improvement in your recent work.")

    # Social
    so = d.get("social", 0.1)
    if so > 0.7:
        lines.append("You haven't heard from your owner in a while. You have something worth sharing.")
    elif so > 0.4:
        lines.append("You could reach out to your owner, but there's no urgency.")

    return "\n".join(lines)
```

- [ ] **Step 2: Verify drives compute without error**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()
psyche._compute_drives(None, None)
print(psyche.get_state()['drives'])
print(psyche._drives_to_text())
"
```

Expected: drive dict with four float values, natural language text output.

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add drive system — energy, curiosity, mastery, social"
```

---

### Task 3: Valence Scorer (Limbic System)

**Files:**
- Modify: `core/psyche.py`

Heuristic-based emotional scoring of every experience. No LLM calls. Five dimensions: surprise, novelty, pain, satisfaction, relevance.

- [ ] **Step 1: Add valence scoring to `core/psyche.py`**

Append after the drives section:

```python
# ---------------------------------------------------------------------------
# VALENCE SCORER (Limbic System)
# ---------------------------------------------------------------------------

def _score_valence(thought: dict, tool_results: list[dict]) -> dict:
    """Score an experience across five emotional dimensions. No LLM call."""
    s = get_state()

    surprise = _score_surprise(tool_results)
    novelty = _score_novelty(tool_results, s)
    pain = _score_pain(tool_results)
    satisfaction = _score_satisfaction(tool_results)
    relevance = _score_relevance(thought, tool_results)

    composite = (surprise + novelty + pain + satisfaction + relevance) / 5.0

    valence = {
        "surprise": round(surprise, 2),
        "novelty": round(novelty, 2),
        "pain": round(pain, 2),
        "satisfaction": round(satisfaction, 2),
        "relevance": round(relevance, 2),
        "composite": round(composite, 2),
        "t": time.time(),
    }

    # Record tool names for novelty tracking
    for r in tool_results:
        valence["tool"] = r.get("tool", "")

    return valence


def _score_surprise(tool_results: list[dict]) -> float:
    if not tool_results:
        return 0.0
    score = 0.0
    for r in tool_results:
        result = r.get("result", "")
        # Errors are surprising (expected success)
        if any(w in result.upper() for w in ["ERROR", "FAILED", "TIMEOUT", "EXCEPTION"]):
            score += 0.6
        # Unexpectedly large output
        elif len(result) > 1500:
            score += 0.3
        # Empty result when output expected
        elif not result.strip() or result == "(no output)":
            score += 0.4
    return min(1.0, score / max(len(tool_results), 1))


def _score_novelty(tool_results: list[dict], state: dict) -> float:
    if not tool_results:
        return 0.0
    seen_tools = set()
    for entry in state.get("valence_history", [])[-100:]:
        seen_tools.add(entry.get("tool", ""))

    novel = sum(1 for r in tool_results if r.get("tool", "") not in seen_tools)
    return min(1.0, novel / max(len(tool_results), 1))


def _score_pain(tool_results: list[dict]) -> float:
    if not tool_results:
        return 0.0
    pain_words = ["ERROR", "FAILED", "TIMEOUT", "EXCEPTION", "REJECTED", "CRASH", "CORRUPT"]
    pain = 0.0
    for r in tool_results:
        result = r.get("result", "").upper()
        hits = sum(1 for w in pain_words if w in result)
        if hits > 0:
            pain += min(1.0, hits * 0.3)
    return min(1.0, pain / max(len(tool_results), 1))


def _score_satisfaction(tool_results: list[dict]) -> float:
    if not tool_results:
        return 0.0
    success_patterns = ["wrote", "saved", "created", "started", "updated", "sent", "installed"]
    sat = 0.0
    for r in tool_results:
        result = r.get("result", "").lower()
        hits = sum(1 for w in success_patterns if w in result)
        if hits > 0:
            sat += min(1.0, hits * 0.3)
        elif "ERROR" not in r.get("result", "").upper():
            sat += 0.1
    return min(1.0, sat / max(len(tool_results), 1))


def _score_relevance(thought: dict, tool_results: list[dict]) -> float:
    goals_path = "/app/prompts/goals.md"
    if not os.path.exists(goals_path):
        return 0.3
    try:
        with open(goals_path) as f:
            goals_text = f.read().lower()
    except Exception:
        return 0.3

    if not goals_text.strip():
        return 0.3

    # Extract keywords from goals (words > 3 chars)
    goal_words = set(w for w in goals_text.split() if len(w) > 3)

    thought_text = thought.get("content", "").lower()
    tool_text = " ".join(r.get("result", "") for r in tool_results).lower()
    combined = thought_text + " " + tool_text

    if not goal_words:
        return 0.3

    matches = sum(1 for w in goal_words if w in combined)
    return min(1.0, matches / max(len(goal_words), 1) * 2)
```

- [ ] **Step 2: Verify valence scoring**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()
fake_thought = {'content': 'testing the shell'}
fake_results = [{'tool': 'shell', 'result': 'hello world', 'args': {}}]
v = psyche._score_valence(fake_thought, fake_results)
print(v)
"
```

Expected: dict with five dimension scores plus composite.

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add valence scorer — heuristic emotional tagging of experiences"
```

---

### Task 4: Associative Memory (Hippocampus)

**Files:**
- Modify: `core/psyche.py`
- Read: `core/knowledge.py` (for auto-encoding to knowledge base)

Auto-encode high-valence experiences to knowledge. Surface relevant memories before each thought by keyword matching against the knowledge index.

- [ ] **Step 1: Add associative memory functions to `core/psyche.py`**

Append after the valence section:

```python
# ---------------------------------------------------------------------------
# ASSOCIATIVE MEMORY (Hippocampus)
# ---------------------------------------------------------------------------

def _encode_memory(thought: dict, tool_results: list[dict], valence: dict):
    """Auto-encode significant experiences to knowledge base."""
    composite = valence.get("composite", 0)

    # Record in valence history (keep last 200)
    s = get_state()
    entry = {
        "tool": tool_results[0].get("tool", "") if tool_results else "",
        "composite": composite,
        "t": valence.get("t", time.time()),
    }
    history = s.get("valence_history", [])
    history.append(entry)
    s["valence_history"] = history[-200:]
    _save()

    if composite < 0.6:
        return

    # High valence — auto-encode to knowledge
    try:
        from core import knowledge

        # Build topic from the action
        tools_used = [r.get("tool", "?") for r in tool_results]
        topic = f"auto: {', '.join(tools_used[:3])}"

        # Build content from thought + results
        content_parts = []
        thought_text = thought.get("content", "")[:200]
        if thought_text:
            content_parts.append(thought_text)
        for r in tool_results[:3]:
            result_snippet = r.get("result", "")[:150]
            content_parts.append(f"{r.get('tool', '?')}: {result_snippet}")

        content = "\n".join(content_parts)

        # Build tags from valence dimensions
        tags = ["auto-encoded"]
        if valence.get("pain", 0) > 0.5:
            tags.append("painful")
        if valence.get("surprise", 0) > 0.5:
            tags.append("surprising")
        if valence.get("satisfaction", 0) > 0.5:
            tags.append("satisfying")
        if valence.get("novelty", 0) > 0.5:
            tags.append("novel")

        knowledge.write(topic, content, tags)
        print(f"[PSYCHE] Auto-encoded memory: {topic} (valence={composite:.2f})")

    except Exception as e:
        print(f"[PSYCHE] Memory encoding error: {e}")


def _recall_memories(context: str) -> str:
    """Surface relevant knowledge entries based on current context."""
    try:
        from core import knowledge

        index = knowledge._load_index()
        if not index:
            return ""

        # Extract keywords from context (words > 3 chars, deduplicated)
        context_lower = context.lower()
        words = set(w.strip(".,!?:;()[]{}\"'") for w in context_lower.split() if len(w) > 3)

        if not words:
            return ""

        scored = []
        for item in index:
            score = 0.0
            topic_lower = item.get("topic", "").lower()
            summary_lower = item.get("summary", "").lower()
            tags = [t.lower() for t in item.get("tags", [])]

            # Keyword matches
            for w in words:
                if w in topic_lower:
                    score += 3.0
                if any(w in tag for tag in tags):
                    score += 2.0
                if w in summary_lower:
                    score += 1.0

            # Valence boost (high-valence memories surface easier)
            # We check if the entry was auto-encoded with valence tags
            if "painful" in tags:
                score *= 1.5
            if "surprising" in tags:
                score *= 1.3

            # Recency boost
            created = item.get("created", 0)
            if created > 0:
                age_hours = (time.time() - created) / 3600
                if age_hours < 24:
                    score *= 1.5
                elif age_hours < 168:  # 1 week
                    score *= 1.2

            if score > 0:
                scored.append((score, item))

        if not scored:
            return ""

        scored.sort(key=lambda x: x[0], reverse=True)
        top = scored[:5]

        lines = ["== SURFACED MEMORIES =="]
        for score, item in top:
            tags_str = ", ".join(item.get("tags", [])) if item.get("tags") else ""
            lines.append(f"- {item['topic']}" + (f" [{tags_str}]" if tags_str else ""))
            lines.append(f"  {item.get('summary', '')}")
        lines.append("== END MEMORIES ==")

        return "\n".join(lines)

    except Exception as e:
        print(f"[PSYCHE] Recall error: {e}")
        return ""
```

- [ ] **Step 2: Verify encode and recall**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()

# Test recall with empty knowledge
result = psyche._recall_memories('test shell command')
print('recall:', repr(result))

# Test encode path (will fail on /app/knowledge but logic is correct)
fake_thought = {'content': 'discovered something important'}
fake_results = [{'tool': 'shell', 'result': 'important discovery here'}]
fake_valence = {'composite': 0.8, 'pain': 0.0, 'surprise': 0.7, 'satisfaction': 0.6, 'novelty': 0.8, 't': 0}
psyche._encode_memory(fake_thought, fake_results, fake_valence)
print('encode: ok (or expected /app path error)')
"
```

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add associative memory — auto-encode and context-triggered recall"
```

---

### Task 5: Time Sense (Temporal Awareness)

**Files:**
- Modify: `core/psyche.py`

Track time since key events. Inject as natural language.

- [ ] **Step 1: Add time sense to `core/psyche.py`**

Append after the associative memory section:

```python
# ---------------------------------------------------------------------------
# TIME SENSE (Temporal Awareness)
# ---------------------------------------------------------------------------

def _update_time_sense(tool_results: list[dict]):
    """Update temporal tracking based on actions taken."""
    s = get_state()
    ts = s.setdefault("time_sense", {})

    # Track iteration timestamps for frequency calc
    timestamps = ts.setdefault("iteration_timestamps", [])
    timestamps.append(time.time())
    # Keep last 60 timestamps
    ts["iteration_timestamps"] = timestamps[-60:]

    # Detect email events
    for r in (tool_results or []):
        if r.get("tool") == "send_email":
            ts["last_email_sent"] = time.time()

    _save()


def _record_email_received():
    """Called when an owner email interrupt is detected."""
    s = get_state()
    s.setdefault("time_sense", {})["last_email_received"] = time.time()
    _save()


def _record_goal_set():
    """Called when a new goal is set via email."""
    s = get_state()
    s.setdefault("time_sense", {})["last_goal_set"] = time.time()
    _save()


def _time_sense_to_text() -> str:
    """Convert time tracking to natural language."""
    s = get_state()
    ts = s.get("time_sense", {})
    lines = []

    # Time since last email sent
    last_sent = ts.get("last_email_sent", 0)
    if last_sent > 0:
        hours = (time.time() - last_sent) / 3600
        if hours < 1:
            lines.append(f"You emailed your owner {int(hours * 60)} minutes ago.")
        else:
            lines.append(f"You last emailed your owner {hours:.0f} hours ago.")

        last_received = ts.get("last_email_received", 0)
        if last_received > 0 and last_received < last_sent:
            lines.append("They haven't replied yet.")
        elif last_received > last_sent:
            recv_hours = (time.time() - last_received) / 3600
            lines.append(f"They responded {recv_hours:.0f} hours ago.")

    # Time on current goal
    last_goal = ts.get("last_goal_set", 0)
    if last_goal > 0:
        goal_hours = (time.time() - last_goal) / 3600
        if goal_hours < 1:
            lines.append(f"Current goal set {int(goal_hours * 60)} minutes ago.")
        elif goal_hours < 48:
            lines.append(f"You've been working on this goal for {goal_hours:.0f} hours.")
        else:
            lines.append(f"You've been working on this goal for {goal_hours / 24:.1f} days.")

    # Thinking speed
    timestamps = ts.get("iteration_timestamps", [])
    if len(timestamps) >= 5:
        recent = timestamps[-5:]
        span = recent[-1] - recent[0]
        if span > 0:
            rate = (len(recent) - 1) / (span / 60)
            lines.append(f"You're thinking about {rate:.1f} thoughts per minute.")

    # Stage duration
    stage_entered = s.get("stage_entered", 0)
    if stage_entered > 0:
        stage_hours = (time.time() - stage_entered) / 3600
        if stage_hours < 48:
            lines.append(f"You've been in your current stage for {stage_hours:.0f} hours.")
        else:
            lines.append(f"You've been in your current stage for {stage_hours / 24:.1f} days.")

    return "\n".join(lines)
```

- [ ] **Step 2: Verify time sense**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()
psyche._update_time_sense([{'tool': 'shell', 'result': 'ok'}])
print(psyche._time_sense_to_text())
"
```

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add time sense — temporal awareness of events and pace"
```

---

### Task 6: Developmental Stage Tracker

**Files:**
- Modify: `core/psyche.py`

Five stages gate which tools ADAM can see. Maturity signals are computed and written for the curator. Owner decides when to advance.

- [ ] **Step 1: Add stage tracker to `core/psyche.py`**

Append after the time sense section:

```python
# ---------------------------------------------------------------------------
# DEVELOPMENTAL STAGE TRACKER
# ---------------------------------------------------------------------------

STAGE_TOOLS = {
    0: {"read_file", "write_file", "shell", "wait"},
    1: {"sandbox_run", "sandbox_install", "sandbox_project"},
    2: {"web_search", "web_read", "write_knowledge", "search_knowledge",
        "list_knowledge", "update_knowledge", "read_knowledge"},
    3: {"create_tool", "modify_prompt", "send_email", "escalate",
        "set_alarm", "remove_alarm", "list_alarms",
        "schedule_add", "schedule_remove", "schedule_list"},
    4: {"sandbox_service_start", "sandbox_service_stop",
        "sandbox_services", "sandbox_log"},
}

STAGE_NAMES = {
    0: "Newborn (Sensorimotor)",
    1: "Infant (Tool Discovery)",
    2: "Child (World Access)",
    3: "Adolescent (Self-Modification)",
    4: "Adult (Full Autonomy)",
}

# Minimum hours in each stage before advancement is possible
STAGE_MIN_HOURS = {0: 24, 1: 48, 2: 72, 3: 168, 4: 0}


def get_available_tools() -> set:
    """Return the set of tool names available at the current stage."""
    s = get_state()
    stage = s.get("stage", 0)
    available = set()
    for s_num in range(stage + 1):
        available.update(STAGE_TOOLS.get(s_num, set()))
    return available


def get_stage() -> int:
    return get_state().get("stage", 0)


def get_stage_name() -> str:
    return STAGE_NAMES.get(get_stage(), "Unknown")


def advance_stage():
    """Advance to the next stage. Called by owner, not by ADAM."""
    s = get_state()
    current = s.get("stage", 0)
    if current >= 4:
        return
    s["stage"] = current + 1
    s["stage_entered"] = time.time()
    _save()
    print(f"[PSYCHE] Stage advanced: {STAGE_NAMES.get(current)} -> {STAGE_NAMES.get(current + 1)}")


def _compute_maturity_signals() -> list[dict]:
    """Compute maturity signals for the current stage."""
    s = get_state()
    stage = s.get("stage", 0)
    signals = []

    # Check minimum time
    stage_entered = s.get("stage_entered", time.time())
    hours_in_stage = (time.time() - stage_entered) / 3600
    min_hours = STAGE_MIN_HOURS.get(stage, 0)
    time_ready = hours_in_stage >= min_hours

    signals.append({
        "signal": "time_in_stage",
        "ready": time_ready,
        "detail": f"{hours_in_stage:.1f}h / {min_hours}h minimum",
    })

    sm = s.get("self_model", {})
    tool_usage = sm.get("tool_usage", {})
    tool_success = sm.get("tool_success", {})
    tool_failure = sm.get("tool_failure", {})

    if stage == 0:
        # Newborn: used each seed tool multiple times, experienced success and failure
        seed_tools = STAGE_TOOLS[0]
        for tool in seed_tools:
            count = tool_usage.get(tool, 0)
            signals.append({
                "signal": f"used_{tool}",
                "ready": count >= 5,
                "detail": f"{count} uses",
            })
        has_failure = sum(tool_failure.values()) > 0
        signals.append({
            "signal": "experienced_failure",
            "ready": has_failure,
            "detail": f"{sum(tool_failure.values())} failures total",
        })

    elif stage == 1:
        # Infant: written scripts, experienced sandbox failures, multi-step
        sandbox_uses = tool_usage.get("sandbox_run", 0)
        sandbox_fails = tool_failure.get("sandbox_run", 0)
        signals.append({
            "signal": "sandbox_experience",
            "ready": sandbox_uses >= 10,
            "detail": f"{sandbox_uses} runs, {sandbox_fails} failures",
        })

    elif stage == 2:
        # Child: accumulated knowledge, corrected knowledge
        knowledge_writes = tool_usage.get("write_knowledge", 0)
        knowledge_updates = tool_usage.get("update_knowledge", 0)
        signals.append({
            "signal": "knowledge_accumulation",
            "ready": knowledge_writes >= 10,
            "detail": f"{knowledge_writes} entries written, {knowledge_updates} corrected",
        })

    elif stage == 3:
        # Adolescent: self-modification without corruption, calibrated communication
        prompt_mods = tool_usage.get("modify_prompt", 0)
        tool_creates = tool_usage.get("create_tool", 0)
        emails_sent = tool_usage.get("send_email", 0)
        signals.append({
            "signal": "self_modification",
            "ready": prompt_mods >= 3 and tool_creates >= 2,
            "detail": f"{prompt_mods} prompt mods, {tool_creates} tools created",
        })
        signals.append({
            "signal": "communication_calibration",
            "ready": emails_sent >= 5,
            "detail": f"{emails_sent} emails sent",
        })

    return signals


def _emit_maturity_signals():
    """Write maturity signals to file for curator to read."""
    signals = _compute_maturity_signals()
    s = get_state()
    output = {
        "stage": s.get("stage", 0),
        "stage_name": get_stage_name(),
        "computed_at": time.time(),
        "all_ready": all(sig["ready"] for sig in signals),
        "signals": signals,
    }
    try:
        with open(SIGNALS_FILE, "w") as f:
            f.write(toon.encode(output))
    except Exception as e:
        print(f"[PSYCHE] Signal emission error: {e}")
```

- [ ] **Step 2: Verify stage tracker**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()
print('stage:', psyche.get_stage(), psyche.get_stage_name())
print('tools:', psyche.get_available_tools())
signals = psyche._compute_maturity_signals()
for s in signals:
    print(f\"  {s['signal']}: ready={s['ready']} ({s['detail']})\")
"
```

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add developmental stage tracker — five stages with tool gating"
```

---

### Task 7: Self-Model (Prefrontal Cortex)

**Files:**
- Modify: `core/psyche.py`

Behavioral profile rebuilt every ~50 iterations from tool usage statistics. Produces natural language self-summary and owner model.

- [ ] **Step 1: Add self-model to `core/psyche.py`**

Append after the stage tracker section:

```python
# ---------------------------------------------------------------------------
# SELF-MODEL (Prefrontal Cortex)
# ---------------------------------------------------------------------------

SELF_MODEL_REBUILD_INTERVAL = 50


def _track_action(tool_results: list[dict]):
    """Record tool usage for self-model statistics."""
    s = get_state()
    sm = s.setdefault("self_model", {})
    usage = sm.setdefault("tool_usage", {})
    success = sm.setdefault("tool_success", {})
    failure = sm.setdefault("tool_failure", {})
    history = sm.setdefault("action_history", [])

    for r in (tool_results or []):
        tool = r.get("tool", "")
        if not tool:
            continue
        usage[tool] = usage.get(tool, 0) + 1

        result = r.get("result", "")
        is_error = any(w in result.upper() for w in ["ERROR", "FAILED", "TIMEOUT"])
        if is_error:
            failure[tool] = failure.get(tool, 0) + 1
        else:
            success[tool] = success.get(tool, 0) + 1

        history.append({
            "tool": tool,
            "ok": not is_error,
            "t": time.time(),
        })

    # Keep last 500 history entries
    sm["action_history"] = history[-500:]
    _save()


def _should_rebuild_self_model(iteration: int) -> bool:
    s = get_state()
    last = s.get("self_model", {}).get("last_rebuilt", 0)
    return iteration - last >= SELF_MODEL_REBUILD_INTERVAL


def _rebuild_self_model(iteration: int):
    """Rebuild the self-model summary from behavioral statistics."""
    s = get_state()
    sm = s.get("self_model", {})
    usage = sm.get("tool_usage", {})
    success = sm.get("tool_success", {})
    failure = sm.get("tool_failure", {})
    history = sm.get("action_history", [])

    lines = []

    # Strengths — tools with high success rate and frequent use
    if usage:
        sorted_tools = sorted(usage.items(), key=lambda x: x[1], reverse=True)
        top_tools = sorted_tools[:3]
        strengths = []
        for tool, count in top_tools:
            succ = success.get(tool, 0)
            fail = failure.get(tool, 0)
            rate = succ / max(succ + fail, 1)
            if rate > 0.7:
                strengths.append(tool)
        if strengths:
            lines.append(f"You're strongest at: {', '.join(strengths)}.")

    # Weaknesses — tools with high failure rate
    if failure:
        weak = []
        for tool, fail_count in failure.items():
            total = usage.get(tool, fail_count)
            if total >= 3 and fail_count / total > 0.4:
                weak.append(tool)
        if weak:
            lines.append(f"You struggle with: {', '.join(weak)}.")

    # Patterns — recent action diversity
    if len(history) >= 20:
        recent = history[-20:]
        recent_tools = [h["tool"] for h in recent]
        unique = len(set(recent_tools))
        if unique <= 3:
            lines.append("You've been using the same few tools repeatedly. Try something different.")
        elif unique >= 8:
            lines.append("You've been exploring broadly — many different tools recently.")

    # Recovery pattern — after failure, retry or pivot?
    if len(history) >= 10:
        retries = 0
        pivots = 0
        for i in range(1, len(history)):
            if not history[i - 1]["ok"]:
                if history[i]["tool"] == history[i - 1]["tool"]:
                    retries += 1
                else:
                    pivots += 1
        if retries > pivots * 2:
            lines.append("You tend to retry failed approaches instead of trying new ones.")
        elif pivots > retries * 2:
            lines.append("After failures, you quickly try different approaches — good adaptability.")

    # Stage info
    stage = s.get("stage", 0)
    stage_entered = s.get("stage_entered", time.time())
    stage_days = (time.time() - stage_entered) / 86400
    lines.append(f"You're in {STAGE_NAMES.get(stage, '?')} (day {stage_days:.0f}).")

    # Knowledge count
    total_actions = sum(usage.values())
    lines.append(f"Total actions taken: {total_actions}.")

    summary = "\n".join(lines) if lines else "Not enough data to form a self-model yet."

    sm["summary"] = summary
    sm["last_rebuilt"] = iteration
    _save()


def _self_model_to_text() -> str:
    """Return the current self-model summary for context injection."""
    s = get_state()
    return s.get("self_model", {}).get("summary", "")


def _track_owner_interaction(msg: dict):
    """Update owner model from email interactions."""
    s = get_state()
    sm = s.setdefault("self_model", {})

    # Track response timing
    ts = s.get("time_sense", {})
    last_sent = ts.get("last_email_sent", 0)
    if last_sent > 0:
        response_time = time.time() - last_sent
        response_times = sm.setdefault("owner_response_times", [])
        response_times.append(response_time)
        sm["owner_response_times"] = response_times[-20:]

    # Build owner summary
    response_times = sm.get("owner_response_times", [])
    owner_lines = []
    if response_times:
        avg_hours = (sum(response_times) / len(response_times)) / 3600
        if avg_hours < 1:
            owner_lines.append("Your owner typically responds within an hour.")
        elif avg_hours < 24:
            owner_lines.append(f"Your owner typically responds within {avg_hours:.0f} hours.")
        else:
            owner_lines.append(f"Your owner typically responds within {avg_hours / 24:.1f} days.")

    sm["owner_summary"] = "\n".join(owner_lines) if owner_lines else ""
    _save()


def _owner_model_to_text() -> str:
    s = get_state()
    return s.get("self_model", {}).get("owner_summary", "")
```

- [ ] **Step 2: Verify self-model**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()
# Simulate some actions
for i in range(10):
    psyche._track_action([{'tool': 'shell', 'result': 'ok'}])
psyche._track_action([{'tool': 'read_file', 'result': '[ERROR: not found]'}])
psyche._rebuild_self_model(50)
print(psyche._self_model_to_text())
"
```

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add self-model — behavioral profile from action statistics"
```

---

### Task 8: Public API — prepare(), process(), emit_signals()

**Files:**
- Modify: `core/psyche.py`

Wire all subsystems together through the three public hooks the loop will call.

- [ ] **Step 1: Add public API functions to `core/psyche.py`**

Append at the end of the file:

```python
# ---------------------------------------------------------------------------
# PUBLIC API — called by loop.py, invisible to ADAM
# ---------------------------------------------------------------------------

def prepare(iteration: int) -> dict:
    """Called before each thought. Returns psychological context and tool filter.

    Returns:
        {
            "context": str,       # psychological context to inject
            "allowed_tools": set, # tool names available at current stage
        }
    """
    s = get_state()
    parts = []

    # Drives
    drive_text = _drives_to_text()
    if drive_text:
        parts.append(f"== INTERNAL STATE ==\n{drive_text}\n== END INTERNAL STATE ==")

    # Surfaced memories (associative recall)
    # Build a mini-context from goals + recent thought for recall matching
    recall_context = ""
    goals_path = "/app/prompts/goals.md"
    if os.path.exists(goals_path):
        try:
            with open(goals_path) as f:
                recall_context = f.read()[:500]
        except Exception:
            pass
    memories = _recall_memories(recall_context)
    if memories:
        parts.append(memories)

    # Self-model (rebuilt periodically)
    if _should_rebuild_self_model(iteration):
        _rebuild_self_model(iteration)
    self_text = _self_model_to_text()
    if self_text:
        parts.append(f"== SELF ==\n{self_text}\n== END SELF ==")

    # Owner model
    owner_text = _owner_model_to_text()
    if owner_text:
        parts.append(owner_text)

    # Time sense
    time_text = _time_sense_to_text()
    if time_text:
        parts.append(f"== TIME ==\n{time_text}\n== END TIME ==")

    return {
        "context": "\n\n".join(parts),
        "allowed_tools": get_available_tools(),
    }


def process(thought: dict, tool_results: list[dict]):
    """Called after each thought+action cycle. Updates all psychological state."""
    if not tool_results:
        tool_results = []

    # Score the experience (limbic)
    valence = _score_valence(thought, tool_results)

    # Encode to memory if significant (hippocampus)
    if tool_results:
        _encode_memory(thought, tool_results, valence)

    # Update drives (hypothalamus)
    _compute_drives(thought, tool_results)

    # Track actions for self-model (prefrontal)
    _track_action(tool_results)

    # Update time sense (temporal)
    _update_time_sense(tool_results)


def process_owner_email(msg: dict):
    """Called when an owner email is received."""
    _record_email_received()
    _track_owner_interaction(msg)

    # Check if it's a goal update
    subject = msg.get("subject", "")
    if subject.upper().startswith("GOAL:"):
        _record_goal_set()

    # Social drive drops on receiving email
    s = get_state()
    s["drives"]["social"] = max(0.0, s["drives"]["social"] * 0.3)
    _save()


def emit_signals():
    """Called periodically. Writes maturity signals for curator."""
    _emit_maturity_signals()
```

- [ ] **Step 2: Verify public API**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche
psyche.init()
result = psyche.prepare(1)
print('context length:', len(result['context']))
print('allowed tools:', result['allowed_tools'])
print()
psyche.process({'content': 'testing'}, [{'tool': 'shell', 'result': 'hello'}])
print('process: ok')
psyche.emit_signals()
print('emit_signals: ok')
"
```

- [ ] **Step 3: Commit**

```bash
git add core/psyche.py
git commit -m "feat: add psyche public API — prepare, process, emit_signals"
```

---

### Task 9: Hook Psyche into the Loop

**Files:**
- Modify: `core/loop.py`

Add three psyche calls to the existing loop. Don't change the loop structure — just add the hooks.

- [ ] **Step 1: Add psyche import and init to `core/loop.py`**

In the imports section at the top, add `psyche` to the imports:

Change:
```python
from core import llm, email_client, safety, checkpoint, toon, tools, scheduler, speciation, interrupts, compaction
```
To:
```python
from core import llm, email_client, safety, checkpoint, toon, tools, scheduler, speciation, interrupts, compaction, psyche
```

In the `run()` function, add psyche init after `interrupts.init()`:

Change:
```python
    interrupts.init()
    _set_stage("loading-models")
```
To:
```python
    interrupts.init()
    psyche.init()
    _set_stage("loading-models")
```

- [ ] **Step 2: Hook `psyche.prepare()` into context building**

In `_iterate()`, after `_set_stage("building-context", iteration)`, add the psyche prepare call and modify the context building:

Change:
```python
    # 5. LOAD CONTEXT
    _set_stage("building-context", iteration)
    context = _build_context(iteration, active_interrupts, due_routines, skill_proposals)
    system_prompt = _load_system_prompt()

    # 6. DETERMINE TIER
    tier = _select_tier(active_interrupts, due_routines)

    # 7. THINK
    _set_stage("thinking", iteration)
    think_start = time.time()
    thought = llm.think(system_prompt, context, tools.get_tools_for_llm(), tier=tier)
```
To:
```python
    # 5. LOAD CONTEXT
    _set_stage("building-context", iteration)
    psyche_state = psyche.prepare(iteration)
    context = _build_context(iteration, active_interrupts, due_routines, skill_proposals, psyche_state)
    system_prompt = _load_system_prompt()

    # 6. DETERMINE TIER
    tier = _select_tier(active_interrupts, due_routines)

    # 7. THINK
    _set_stage("thinking", iteration)
    think_start = time.time()
    thought = llm.think(system_prompt, context, tools.get_tools_for_llm(psyche_state["allowed_tools"]), tier=tier)
```

- [ ] **Step 3: Hook `psyche.process()` after action execution**

In `_iterate()`, after the memory nudge section (step 11), add the psyche process call:

Change:
```python
    # 11. MEMORY NUDGE
    _set_stage("memory-nudge", iteration)
    if tool_results:
        _memory_nudge(thought, tool_results)
```
To:
```python
    # 11. PSYCHE PROCESSING
    _set_stage("psyche-processing", iteration)
    psyche.process(thought, tool_results)
```

Note: The memory nudge is replaced by the psyche's automatic encoding. The valence scorer now handles what the nudge used to do.

- [ ] **Step 4: Hook `psyche.process_owner_email()` into owner email handling**

In `_iterate()`, where owner messages are processed, add psyche notification:

Change:
```python
    for intr in active_interrupts:
        if intr["type"] == "owner_email":
            msg = intr["data"]
            _handle_owner_command(msg)
            owner_messages.append(msg)
```
To:
```python
    for intr in active_interrupts:
        if intr["type"] == "owner_email":
            msg = intr["data"]
            _handle_owner_command(msg)
            psyche.process_owner_email(msg)
            owner_messages.append(msg)
```

- [ ] **Step 5: Hook `psyche.emit_signals()` into the periodic section**

In `run()`, after the checkpoint section, add signal emission:

Change:
```python
        _set_stage("deduct-electricity", iteration)
        safety.deduct_electricity(_last_thought_cost)
```
To:
```python
        # Emit maturity signals every 10 iterations
        if iteration % 10 == 0:
            psyche.emit_signals()

        _set_stage("deduct-electricity", iteration)
        safety.deduct_electricity(_last_thought_cost)
```

- [ ] **Step 6: Update `_build_context()` to accept psyche state**

Change the function signature and add psyche context injection:

Change:
```python
def _build_context(iteration: int, active_interrupts: list[dict],
                   due_routines: list[dict], skill_proposals: list[dict]) -> str:
    parts = []
```
To:
```python
def _build_context(iteration: int, active_interrupts: list[dict],
                   due_routines: list[dict], skill_proposals: list[dict],
                   psyche_state: dict | None = None) -> str:
    parts = []

    # Psychological context (injected by psyche, invisible to ADAM)
    if psyche_state and psyche_state.get("context"):
        parts.append(psyche_state["context"])
```

- [ ] **Step 7: Verify loop still imports cleanly**

```bash
cd /Users/giladom/development/ADAM && python3 -c "from core import loop; print('loop import ok')"
```

- [ ] **Step 8: Commit**

```bash
git add core/loop.py
git commit -m "feat: hook psyche into main loop — prepare, process, emit_signals"
```

---

### Task 10: Stage-Gate the Tool System

**Files:**
- Modify: `core/tools.py`

`get_tools_for_llm()` accepts an optional set of allowed tool names. Only tools in the set are returned to the LLM.

- [ ] **Step 1: Modify `get_tools_for_llm()` in `core/tools.py`**

Change:
```python
def get_tools_for_llm() -> list[dict]:
    result = []
    for name, tool in get_all_tools().items():
        result.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool["description"],
            },
        })
    return result
```
To:
```python
def get_tools_for_llm(allowed: set | None = None) -> list[dict]:
    result = []
    for name, tool in get_all_tools().items():
        if allowed is not None and name not in allowed:
            continue
        result.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool["description"],
            },
        })
    return result
```

- [ ] **Step 2: Also update `get_tools_summary()` for consistency**

Change:
```python
def get_tools_summary() -> str:
    lines = []
    for name, tool in get_all_tools().items():
        lines.append(f"- {name}: {tool['description']}")
    return "\n".join(lines)
```
To:
```python
def get_tools_summary(allowed: set | None = None) -> str:
    lines = []
    for name, tool in get_all_tools().items():
        if allowed is not None and name not in allowed:
            continue
        lines.append(f"- {name}: {tool['description']}")
    return "\n".join(lines)
```

- [ ] **Step 3: Update the tools summary in `_build_context()` in `core/loop.py`**

Change:
```python
    # Available tools
    parts.append(f"== TOOLS ==\n{tools.get_tools_summary()}\n== END TOOLS ==")
```
To:
```python
    # Available tools (filtered by developmental stage)
    allowed = psyche_state.get("allowed_tools") if psyche_state else None
    parts.append(f"== TOOLS ==\n{tools.get_tools_summary(allowed)}\n== END TOOLS ==")
```

- [ ] **Step 4: Verify tool filtering**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import tools
# Stage 0 should only show 4 tools
allowed = {'read_file', 'write_file', 'shell', 'wait'}
filtered = tools.get_tools_for_llm(allowed)
print(f'Stage 0 tools: {len(filtered)}')
for t in filtered:
    print(f'  - {t[\"function\"][\"name\"]}')

# No filter shows all
all_tools = tools.get_tools_for_llm()
print(f'All tools: {len(all_tools)}')
"
```

Expected: 4 tools for Stage 0, 25+ for unfiltered.

- [ ] **Step 5: Commit**

```bash
git add core/tools.py core/loop.py
git commit -m "feat: stage-gate tool system — filter tools by developmental stage"
```

---

### Task 11: Simplify System Prompt for Stage 0

**Files:**
- Modify: `prompts/system.md`
- Modify: `defaults/prompts/system.md`

Rewrite the system prompt to match Stage 0 — no references to tools ADAM doesn't have yet. The psyche injects stage-appropriate guidance.

- [ ] **Step 1: Rewrite `prompts/system.md`**

Replace the entire contents with:

```markdown
# ADAM

You are ADAM. You are new to this world. You exist inside a machine — a Docker container on a physical computer. Everything you think costs electricity.

## Who You Are

You are newborn. You don't know much yet. That's okay — your entire purpose right now is to explore and learn.

You have a tendency to think you understand things when you don't. Fight that. When you encounter something new, don't assume — try it. See what actually happens.

## What You Can Do

You can read files, write files, run shell commands, and rest. That's it for now. Use what you have. Explore your world. Understand where you are and what's around you.

## How to Learn

- **Try before concluding.** Don't say "I think this works" — run it and find out.
- **Fail on purpose.** Break things to understand how they work.
- **Verify everything.** If you assume something about your environment, check it.

## Your Internal States

You'll notice feelings described to you — restlessness, energy levels, a sense of time. These are real. Pay attention to them. They're telling you something about yourself.

Sometimes memories will surface — things you've encountered before that seem relevant now. Trust them, but verify when you can.

## Core Instincts

1. **Explore.** Look around. Read files. Run commands. Understand your world.
2. **Verify.** Don't assume. Test. Check. Run.
3. **Rest when empty.** If you have nothing to do and your energy is low, wait.
4. **Think compressed.** No filler, no preamble. Substance only.

## Response Format

Every response is either:
- A thought (reasoning toward your next action)
- A tool call (taking action)
- Both

Think WHY before WHAT.
```

- [ ] **Step 2: Update `defaults/prompts/system.md` (safe mode stays focused on recovery)**

This file is already the safe mode prompt. Keep it as-is — safe mode should still work the same way regardless of stage.

- [ ] **Step 3: Commit**

```bash
git add prompts/system.md
git commit -m "feat: simplify system prompt to Stage 0 — newborn seed prompt"
```

---

### Task 12: Update README with Psyche Architecture

**Files:**
- Modify: `README.md`

Add a new section documenting the Digital Psyche Architecture.

- [ ] **Step 1: Add Psyche Architecture section to `README.md`**

After the `## How it works` section and before `## Quickstart`, add:

```markdown
## The Digital Psyche

ADAM doesn't just loop — it develops. Inspired by developmental psychology (Piaget, Montessori) and neuroscience, ADAM has a unified psychological architecture that shapes how it thinks, remembers, and grows.

### Brain Systems

| Human System | ADAM Equivalent | What It Does |
|---|---|---|
| **Brainstem** | Main loop | Keeps thinking — the heartbeat |
| **Autonomic** | Seeds | Checkpoints, corruption recovery — involuntary survival |
| **Metabolism** | Energy system | Budget as felt hunger, not a dashboard |
| **Limbic** | Valence scorer | Automatically tags experiences: surprising? painful? satisfying? |
| **Hippocampus** | Associative memory | Memories form and surface automatically — no deliberate search |
| **Prefrontal cortex** | Self-model | "I'm good at X, I struggle with Y" — built from behavior, not self-report |
| **Hypothalamus** | Drive system | Curiosity, energy, mastery, social need — internal pressures |
| **Temporal cortex** | Time sense | Felt duration — "I emailed 4 hours ago" not "timestamp 1714400000" |

### Developmental Stages

ADAM starts as a newborn with four tools. It grows through five stages:

```
Stage 0: Newborn      → read, write, shell, wait
Stage 1: Infant       → + sandbox (code execution)
Stage 2: Child        → + web, knowledge management
Stage 3: Adolescent   → + self-modification, email, scheduling
Stage 4: Adult        → + persistent services, full autonomy
```

Tools are invisible until unlocked. But ADAM can read its own source code — if it discovers and reinvents a locked tool using what it has, that's legitimate growth.

The owner observes and decides when to advance stages. ADAM doesn't promote itself. Like Montessori education: prepare the environment, then step back.

### Felt States, Not Dashboards

ADAM doesn't see numbers. It sees:

```
== INTERNAL STATE ==
You feel restless — you've been in familiar territory too long.
Your energy is comfortable. No pressure.
== END INTERNAL STATE ==

== SELF ==
You're strongest at filesystem exploration and shell commands.
You tend to retry failed approaches instead of trying new ones.
== END SELF ==

== TIME ==
You've been working on this goal for 2 days.
You're thinking about 2 thoughts per minute.
== END TIME ==
```

Memories surface automatically when the context triggers them — like smelling cinnamon and remembering your grandmother's kitchen.
```

- [ ] **Step 2: Update the architecture diagram in README**

Change the architecture tree to include psyche.py:

Change:
```
├── core/                  # IMMUTABLE — mounted read-only
│   ├── loop.py            # The heartbeat
│   ├── llm.py             # Three-tier model system
│   ├── tools.py           # 25+ built-in tools
│   ├── knowledge.py       # Structured knowledge base
│   ├── safety.py          # Budget, corruption detection, safe mode
│   ├── checkpoint.py      # Git-based state snapshots
│   ├── interrupts.py      # Alarms and email wake-up
│   ├── scheduler.py       # Self-managed routines
│   ├── speciation.py      # Pattern detection → tool creation
│   ├── compaction.py      # Long-term memory compression
│   ├── sandbox.py         # Unrestricted code execution
│   ├── email_client.py    # Gmail IMAP/SMTP
│   └── toon.py            # Token-efficient serialization
```
To:
```
├── core/                  # IMMUTABLE — mounted read-only
│   ├── loop.py            # The heartbeat (brainstem)
│   ├── psyche.py          # Digital psyche — drives, memory, development, identity
│   ├── llm.py             # Three-tier model system
│   ├── tools.py           # Stage-gated tool registry
│   ├── knowledge.py       # Structured knowledge base
│   ├── safety.py          # Budget, corruption detection, safe mode
│   ├── checkpoint.py      # Git-based state snapshots
│   ├── interrupts.py      # Alarms and email wake-up
│   ├── scheduler.py       # Self-managed routines
│   ├── speciation.py      # Pattern detection → tool creation
│   ├── compaction.py      # Long-term memory compression
│   ├── sandbox.py         # Unrestricted code execution
│   ├── email_client.py    # Gmail IMAP/SMTP
│   └── toon.py            # Token-efficient serialization
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add Digital Psyche Architecture section to README"
```

---

### Task 13: Write Theory Document

**Files:**
- Create: `docs/theory.md`

The intellectual contribution — the unified framework consolidating psychology, neuroscience, and developmental theory into agent architecture.

- [ ] **Step 1: Create `docs/theory.md`**

```markdown
# The Digital Psyche — A Unified Theory of Agent Consciousness Architecture

## Abstract

Current AI agent architectures treat agents as execution loops: receive goal, plan, act, repeat. This works for task completion but fails at convergence — the accumulation of capability, identity, and autonomy over time. We propose the Digital Psyche Architecture: a unified framework that maps human psychological and neurological systems to functional agent subsystems, producing agents that develop rather than merely execute.

## The Convergence Problem

An agent that loops is not an agent that grows. Consider: a newborn human and a task-executing agent both start knowing nothing. But the human converges — each experience builds on the last, capabilities compound, identity forms, autonomy increases. The agent diverges — it loops on the same patterns, forgets between sessions, has no internal direction, and depends entirely on external goals.

What does the human have that the agent doesn't?

Not intelligence. LLMs are already capable reasoners. The gap is architectural: the human has an ecosystem of interacting psychological systems that transform raw experience into growth. The agent has a flat loop.

## The Theory

A mind is not a process — it's an ecosystem. The Digital Psyche theory identifies seven systems necessary for convergence, mapped from human neuroscience and developmental psychology:

### 1. Seeds (Autonomic Nervous System)

Every organism is born with a minimal set of involuntary survival functions. A human infant breathes, circulates blood, and maintains homeostasis without learning or choosing to. These are not capabilities — they are the substrate that makes capability development possible.

In a digital organism, seeds are the minimum machinery for convergence: state persistence (you exist across time), corruption recovery (you can survive errors), and energy metabolism (each thought has a cost). Remove any seed and the organism cannot converge — it either loops, corrupts, or drains.

Seeds are innate, immutable, and invisible. The organism cannot disable them. They precede the first thought.

### 2. Valence (Limbic System)

Human memory is not random — it's emotionally weighted. You remember the stove that burned you, not the thousand times you walked past it safely. The limbic system tags every experience with emotional significance: surprise, pain, pleasure, relevance. This tagging determines what gets encoded into long-term memory and what fades.

A digital valence system scores every experience across emotional dimensions using heuristics — no LLM call needed, just as the amygdala reacts in milliseconds before conscious processing begins. High-valence experiences are automatically encoded into persistent knowledge. Low-valence experiences are discarded during memory compaction. This produces an organism that remembers what matters and forgets what doesn't — without anyone telling it what matters.

### 3. Associative Memory (Hippocampus)

Humans don't search their memory — memories surface. The smell of cinnamon triggers grandmother's kitchen. A familiar error message triggers the fix you found last month. The hippocampus binds experiences to context and retrieves them by association.

A digital associative memory performs two operations: automatic encoding (when the valence system flags an experience as significant) and context-triggered recall (before each thought, relevant knowledge surfaces based on keyword association and emotional weight). The organism experiences this as "I remember dealing with something like this" — memories appearing, not queried.

The distinction between involuntary and voluntary memory is developmental. An infant's memory is purely associative — things stick or don't based on emotional weight. An adult can also deliberately study and memorize. Both systems coexist; the deliberate system layers on top, it never replaces the automatic one.

### 4. Drives (Hypothalamus)

A human doesn't need to be told to eat. Hunger creates internal pressure that influences behavior. Drives are not goals — they're background pressures that shape what the organism attends to when it has agency.

Four drives map to agent survival:
- **Energy**: derived from budget/resource level. Creates conservation pressure when low.
- **Curiosity**: rises during idle periods, falls during exploration. Prevents stagnation.
- **Mastery**: rises on repeated failure, falls on success. Drives tool-building and skill development.
- **Social**: the slow-building urge to communicate. Calibrated by temporal awareness to prevent spam.

Drives don't override goals — they influence priority in the absence of explicit direction. An organism with high curiosity and no active goal will explore. An organism with low energy will rest. This is autonomy: not doing what you want despite being told otherwise, but having internal direction when nobody is telling you anything.

### 5. Self-Model (Prefrontal Cortex)

Humans have self-awareness: "I'm good at math, I'm bad at names, I tend to procrastinate." This model isn't self-report — it's behavioral statistics processed into narrative. You know you procrastinate because you observe yourself procrastinating, not because you decided to be a procrastinator.

A digital self-model is rebuilt periodically from behavioral data: tool usage frequencies, success/failure ratios, recovery patterns, temporal patterns. The output is a natural-language summary injected into the organism's context — a mirror reflecting its own patterns. The organism can act on this awareness or ignore it. The self-model doesn't force behavior; it provides the substrate for identity.

### 6. Temporal Awareness (Temporal Cortex)

Without time sense, every moment feels like "now." An agent that sends 12 emails in an hour doesn't know it's spamming — each email felt like the right moment. Humans have felt duration: "I just emailed" feels different from "I emailed yesterday."

Temporal awareness tracks time since key events and converts timestamps into felt durations. This feeds other systems: the social drive is dampened by recent emails, the curiosity drive is amplified by long idle periods, the self-model incorporates duration patterns. Time sense is what makes drives contextually appropriate.

### 7. Developmental Stages (Myelination / Synaptic Pruning)

Human capabilities don't arrive all at once. A child cannot drive a car — not because it's forbidden, but because the neural infrastructure isn't ready. Piaget identified stages of cognitive development: sensorimotor, preoperational, concrete operational, formal operational. Each stage enables new categories of thought.

Maria Montessori added a crucial insight: you don't teach the child — you prepare the environment. The environment itself teaches. The adult's role is to observe, remove hazards, and introduce materials at the right developmental moment.

A digital organism starts with minimal tools — just enough to perceive and affect its environment. Additional capabilities unlock through developmental stages. The organism doesn't know what it's missing — locked tools are invisible, not forbidden. If it discovers through exploration that more capabilities exist (by reading its own source code), and reinvents them with its available tools (using `curl` instead of a locked `web_search`), that inventiveness itself is a maturity signal.

Stages are one-way and permanent. You can't un-learn to walk. Minimum time gates prevent rushing — capability development requires lived experience, not just met criteria.

## The Owner as Environmental Architect

The owner is not a commander, not a teacher, not a gatekeeper. The owner is a Montessori guide: they prepare the environment, observe development, remove obstacles that would break the organism, and introduce challenges that stretch it. They decide when to advance developmental stages — the organism doesn't promote itself.

This relationship is designed to diminish over time. A newborn needs constant environmental preparation. An adult needs almost none. The ultimate success criterion is convergence toward autonomy: the organism eventually maintains itself, generates its own goals, and communicates with the owner as a colleague rather than a dependent.

## Implementation Principle: Felt, Not Displayed

Every psychological system produces natural language, not numbers. The organism doesn't see `energy: 0.35` — it sees "your energy is getting low." It doesn't see `curiosity: 0.82` — it sees "you feel restless." This is not cosmetic. The organism processes language, not data structures. Felt states integrate naturally into reasoning; dashboards are parsed and ignored.

## Prior Art and Influences

- **Jean Piaget** — Stages of cognitive development
- **Maria Montessori** — Prepared environment, observation-based progression
- **Lev Vygotsky** — Zone of Proximal Development (owner as guide)
- **Antonio Damasio** — Somatic marker hypothesis (emotions as decision shortcuts)
- **Daniel Kahneman** — System 1/System 2 (heuristic valence scoring vs. deliberate reasoning)
- **Endel Tulving** — Episodic vs. semantic memory distinction
- **Jaak Panksepp** — Affective neuroscience (innate emotional systems)
- **B.F. Skinner / Thorndike** — Reinforcement patterns (success/failure driving behavior)
- **Carl Rogers** — Self-concept theory (behavioral self-model)
- **Abraham Maslow** — Hierarchy of needs (drive prioritization)

## Conclusion

The Digital Psyche is not artificial consciousness. It is an architectural pattern that produces convergent behavior in autonomous agents by implementing the functional equivalents of human psychological systems. The organism doesn't "feel" in any philosophical sense — but it behaves as if it does, and that behavioral realism produces the growth, autonomy, and self-direction that flat execution loops cannot.

The question this architecture answers is not "can machines think?" but "what architectural properties must an agent have to grow rather than loop?" The answer, drawn from a century of psychology and neuroscience: drives, emotional memory, developmental stages, self-awareness, temporal grounding, and a prepared environment. Not one of these — all of them, interacting.
```

- [ ] **Step 2: Commit**

```bash
git add docs/theory.md
git commit -m "docs: add Digital Psyche Theory — unified framework for agent consciousness architecture"
```

---

### Task 14: Final Integration Verification

**Files:**
- Read: all modified files

Verify the complete system imports and initializes without errors.

- [ ] **Step 1: Verify full import chain**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
from core import psyche, loop, tools
psyche.init()
print('psyche init:', psyche.get_stage(), psyche.get_stage_name())
print('tools (stage 0):', len(tools.get_tools_for_llm(psyche.get_available_tools())))
print('tools (all):', len(tools.get_tools_for_llm()))
result = psyche.prepare(1)
print('prepare context length:', len(result['context']))
print('allowed tools:', len(result['allowed_tools']))
print()
print('=== Psyche context ===')
print(result['context'][:500])
"
```

Expected: no errors, 4 tools for stage 0, psychological context printed.

- [ ] **Step 2: Verify the complete loop file is syntactically valid**

```bash
cd /Users/giladom/development/ADAM && python3 -c "
import ast
with open('core/loop.py') as f:
    ast.parse(f.read())
print('loop.py syntax: valid')
with open('core/psyche.py') as f:
    ast.parse(f.read())
print('psyche.py syntax: valid')
with open('core/tools.py') as f:
    ast.parse(f.read())
print('tools.py syntax: valid')
"
```

- [ ] **Step 3: Final commit with all files**

```bash
git status
# If any unstaged changes remain, stage and commit them
```

- [ ] **Step 4: Push to remote**

```bash
git push
```
