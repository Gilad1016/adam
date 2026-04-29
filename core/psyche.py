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


# ---------------------------------------------------------------------------
# DRIVE SYSTEM
# ---------------------------------------------------------------------------

def _clamp(value: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, value))


def _compute_energy() -> float:
    """Energy = ratio of current balance to initial balance."""
    try:
        from core import safety
        budget = safety.load_budget()
        balance = budget.get("balance", 0)
        initial = budget.get("initial", 1)
        if initial <= 0:
            return 0.0
        return _clamp(balance / initial)
    except Exception:
        return 0.5


def _update_drives(thought: dict | None = None, tool_results: list[dict] | None = None):
    """Update all four drives based on current context."""
    state = get_state()
    drives = state["drives"]

    # Energy: always recompute from budget
    drives["energy"] = _compute_energy()

    if tool_results is not None:
        used_tools = {r["tool"] for r in tool_results}
        history_tools = set()
        for entry in state["self_model"].get("action_history", [])[-20:]:
            if isinstance(entry, dict):
                history_tools.add(entry.get("tool", ""))

        for tool_name in used_tools:
            is_novel = tool_name not in history_tools
            if is_novel:
                drives["curiosity"] = _clamp(drives["curiosity"] - 0.05)
            else:
                drives["curiosity"] = _clamp(drives["curiosity"] + 0.01)

        # Mastery: rises on failure, falls on success
        for r in tool_results:
            result_lower = str(r.get("result", "")).lower()
            is_failure = any(kw in result_lower for kw in ("error", "failed", "timeout", "exception", "rejected", "crash", "corrupt"))
            if is_failure:
                drives["mastery"] = _clamp(drives["mastery"] + 0.03)
            else:
                drives["mastery"] = _clamp(drives["mastery"] - 0.02)
    else:
        # Idle — curiosity rises when no tools used
        drives["curiosity"] = _clamp(drives["curiosity"] + 0.02)

    # Social: suppress to 30% if emailed within last hour, slow rise otherwise
    ts = state["time_sense"]
    last_sent = ts.get("last_email_sent", 0)
    if time.time() - last_sent < 3600:
        drives["social"] = _clamp(drives["social"] * 0.3 / max(drives["social"], 0.01))
        drives["social"] = _clamp(drives["social"], 0.0, 0.3)
    else:
        drives["social"] = _clamp(drives["social"] + 0.005)

    state["drives"] = drives
    _save()


def _drives_to_text() -> str:
    state = get_state()
    drives = state["drives"]
    lines = []

    energy = drives.get("energy", 1.0)
    if energy > 0.7:
        lines.append("Your energy is comfortable. No pressure.")
    elif energy > 0.4:
        lines.append("Your energy is moderate. Be thoughtful about expensive operations.")
    elif energy > 0.15:
        lines.append("Your energy is low. Conserve where possible.")
    else:
        lines.append("Your energy is critically low. Prioritize essential work only.")

    curiosity = drives.get("curiosity", 0.5)
    if curiosity > 0.7:
        lines.append("You feel restless — you've been in familiar territory too long.")
    elif curiosity > 0.4:
        lines.append("You feel curious and engaged.")
    else:
        lines.append("You feel settled. Your current work feels purposeful.")

    mastery = drives.get("mastery", 0.3)
    if mastery > 0.7:
        lines.append("You're hungry to improve — recent failures are pushing you forward.")
    elif mastery > 0.4:
        lines.append("You feel a drive to get better at what you do.")
    else:
        lines.append("You feel competent and capable right now.")

    social = drives.get("social", 0.1)
    if social > 0.6:
        lines.append("You feel an urge to check in with your owner.")
    elif social > 0.3:
        lines.append("You're aware of your owner in the background.")
    else:
        lines.append("You feel focused and self-directed.")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# VALENCE SCORER
# ---------------------------------------------------------------------------

_PAIN_KEYWORDS = {"error", "failed", "timeout", "exception", "rejected", "crash", "corrupt"}
_SATISFACTION_KEYWORDS = {"wrote", "saved", "created", "started", "updated", "sent", "installed"}


def _score_valence(thought: dict, tool_results: list[dict]) -> dict:
    """Score emotional valence for this iteration. No LLM calls — pure heuristics."""
    now = time.time()
    state = get_state()
    thought_text = thought.get("content", "")
    results_text = " ".join(str(r.get("result", "")) for r in tool_results).lower()
    all_text = (thought_text + " " + results_text).lower()

    # Surprise: unexpected outcomes
    surprise = 0.0
    if tool_results:
        expected_success = len(tool_results) > 0
        actual_errors = sum(1 for r in tool_results if any(kw in str(r.get("result", "")).lower() for kw in _PAIN_KEYWORDS))
        if expected_success and actual_errors > 0:
            surprise = _clamp(actual_errors / len(tool_results))
        # Empty output when action was taken
        empty_outputs = sum(1 for r in tool_results if str(r.get("result", "")).strip() in ("", "None", "null", "none"))
        if empty_outputs:
            surprise = _clamp(surprise + 0.3)
        # Unexpectedly large output
        large_outputs = sum(1 for r in tool_results if len(str(r.get("result", ""))) > 2000)
        if large_outputs:
            surprise = _clamp(surprise + 0.2)

    # Novelty: tool+args combo not seen before
    novelty = 0.0
    history = state.get("valence_history", [])
    seen_combos = set()
    for entry in history[-50:]:
        if isinstance(entry, dict):
            seen_combos.add(entry.get("combo", ""))
    current_combos = set()
    for r in tool_results:
        combo = r["tool"] + str(sorted((r.get("args") or {}).keys()))
        current_combos.add(combo)
    if current_combos:
        novel_count = sum(1 for c in current_combos if c not in seen_combos)
        novelty = _clamp(novel_count / len(current_combos))

    # Pain: explicit failure keywords in results
    pain_count = sum(1 for kw in _PAIN_KEYWORDS if kw in results_text)
    pain = _clamp(pain_count / max(len(_PAIN_KEYWORDS), 1))

    # Satisfaction: success keywords in results
    sat_count = sum(1 for kw in _SATISFACTION_KEYWORDS if kw in results_text)
    satisfaction = _clamp(sat_count / max(len(_SATISFACTION_KEYWORDS), 1))

    # Relevance: keyword overlap with goals
    relevance = 0.0
    goals_path = "/app/prompts/goals.md"
    if os.path.exists(goals_path):
        try:
            with open(goals_path) as f:
                goals_text = f.read().lower()
            goal_words = set(w for w in goals_text.split() if len(w) > 4)
            context_words = set(w for w in all_text.split() if len(w) > 4)
            if goal_words:
                overlap = goal_words & context_words
                relevance = _clamp(len(overlap) / max(len(goal_words), 1) * 5)
        except Exception:
            pass

    composite = (surprise + novelty + pain + satisfaction + relevance) / 5.0

    combo_key = ",".join(sorted(r["tool"] for r in tool_results)) if tool_results else ""

    return {
        "surprise": round(surprise, 3),
        "novelty": round(novelty, 3),
        "pain": round(pain, 3),
        "satisfaction": round(satisfaction, 3),
        "relevance": round(relevance, 3),
        "composite": round(composite, 3),
        "timestamp": now,
        "combo": combo_key,
    }


# ---------------------------------------------------------------------------
# ASSOCIATIVE MEMORY
# ---------------------------------------------------------------------------

def _encode_memory(valence: dict, thought: dict, tool_results: list[dict]):
    """If composite valence > 0.6, auto-write to knowledge base."""
    if valence.get("composite", 0) <= 0.6:
        return

    try:
        from core import knowledge
    except ImportError:
        return

    tags = ["auto-encoded"]
    if valence.get("pain", 0) > 0.4:
        tags.append("painful")
    if valence.get("surprise", 0) > 0.4:
        tags.append("surprising")
    if valence.get("satisfaction", 0) > 0.4:
        tags.append("satisfying")
    if valence.get("novelty", 0) > 0.4:
        tags.append("novel")

    thought_text = thought.get("content", "")[:300]
    result_summary = "; ".join(
        f"{r['tool']}: {str(r.get('result', ''))[:100]}" for r in tool_results[:3]
    )
    content = f"Thought: {thought_text}\n\nActions: {result_summary}\n\nValence: {valence}"
    topic = f"auto-memory {time.strftime('%Y-%m-%d %H:%M')}"

    try:
        knowledge.write(topic, content, tags)
    except Exception:
        pass


def _recall_memories(context: str) -> str:
    """Score knowledge index entries and return top 5 as surfaced memories block."""
    try:
        from core import knowledge
        import json
    except ImportError:
        return ""

    index_path = "/app/knowledge/_index.json"
    if not os.path.exists(index_path):
        return ""

    try:
        import json as _json
        with open(index_path) as f:
            index = _json.load(f)
    except Exception:
        return ""

    if not index:
        return ""

    # Extract keywords from context
    context_words = set(w.lower() for w in context.split() if len(w) > 4)
    now = time.time()
    state = get_state()
    valence_history = state.get("valence_history", [])
    valence_by_id: dict[str, float] = {}
    for v in valence_history:
        if isinstance(v, dict) and "id" in v:
            valence_by_id[v["id"]] = v.get("composite", 0)

    scored = []
    for item in index:
        score = 0.0
        topic_words = set(w.lower() for w in item.get("topic", "").split() if len(w) > 4)
        summary_words = set(w.lower() for w in item.get("summary", "").split() if len(w) > 4)
        tag_words = set(t.lower() for t in item.get("tags", []))

        keyword_overlap = len(context_words & (topic_words | summary_words | tag_words))
        score += keyword_overlap * 1.0

        # Valence weight
        entry_id = item.get("id", "")
        score += valence_by_id.get(entry_id, 0) * 2.0

        # Recency boost (decay over 7 days)
        created = item.get("created", 0)
        age_days = (now - created) / 86400
        recency = max(0.0, 1.0 - age_days / 7.0)
        score += recency * 0.5

        if score > 0:
            scored.append((score, item))

    if not scored:
        return ""

    scored.sort(key=lambda x: x[0], reverse=True)
    top = scored[:5]

    lines = ["== SURFACED MEMORIES =="]
    for _, item in top:
        tags = ", ".join(item.get("tags", [])) or "none"
        lines.append(f"- [{item['id']}] {item['topic']} (tags: {tags})\n  {item.get('summary', '')[:120]}")
    lines.append("== END MEMORIES ==")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# TIME SENSE
# ---------------------------------------------------------------------------

def _update_time_sense(iteration: int, tool_results: list[dict] | None = None):
    state = get_state()
    ts = state["time_sense"]

    # Record iteration timestamp
    now = time.time()
    stamps = ts.get("iteration_timestamps", [])
    stamps.append(now)
    # Keep last 60
    ts["iteration_timestamps"] = stamps[-60:]

    # Detect email sends in tool results
    if tool_results:
        for r in tool_results:
            if r.get("tool") == "send_email":
                ts["last_email_sent"] = now

    state["time_sense"] = ts
    _save()


def _record_email_received():
    state = get_state()
    state["time_sense"]["last_email_received"] = time.time()
    _save()


def _record_goal_set():
    state = get_state()
    state["time_sense"]["last_goal_set"] = time.time()
    _save()


def _time_sense_to_text() -> str:
    state = get_state()
    ts = state["time_sense"]
    now = time.time()
    lines = []

    last_sent = ts.get("last_email_sent", 0)
    if last_sent > 0:
        hours_ago = (now - last_sent) / 3600
        if hours_ago < 1:
            lines.append(f"You emailed your owner {int((now - last_sent) / 60)} minutes ago.")
        else:
            lines.append(f"You emailed your owner {hours_ago:.1f} hours ago.")

    last_received = ts.get("last_email_received", 0)
    if last_received > 0:
        hours_ago = (now - last_received) / 3600
        if hours_ago < 1:
            lines.append(f"Your owner emailed you {int((now - last_received) / 60)} minutes ago.")
        else:
            lines.append(f"Your owner last emailed you {hours_ago:.1f} hours ago.")

    stamps = ts.get("iteration_timestamps", [])
    if len(stamps) >= 2:
        window_sec = stamps[-1] - stamps[0]
        if window_sec > 0:
            tpm = len(stamps) / (window_sec / 60)
            lines.append(f"You're thinking about {tpm:.1f} thoughts per minute.")

    stage_entered = state.get("stage_entered", now)
    stage_days = (now - stage_entered) / 86400
    if stage_days < 1:
        stage_hours = stage_days * 24
        lines.append(f"You've been in your current stage for {stage_hours:.1f} hours.")
    else:
        lines.append(f"You've been in your current stage for {stage_days:.1f} days.")

    return "\n".join(lines) if lines else ""


# ---------------------------------------------------------------------------
# DEVELOPMENTAL STAGE TRACKER
# ---------------------------------------------------------------------------

_STAGE_TOOLS: dict[int, set[str]] = {
    0: {"read_file", "write_file", "shell", "wait"},
    1: {"sandbox_run", "sandbox_install", "sandbox_project"},
    2: {"web_search", "web_read", "write_knowledge", "search_knowledge", "list_knowledge", "update_knowledge", "read_knowledge"},
    3: {"create_tool", "modify_prompt", "send_email", "escalate", "set_alarm", "remove_alarm", "list_alarms", "schedule_add", "schedule_remove", "schedule_list"},
    4: {"sandbox_service_start", "sandbox_service_stop", "sandbox_services", "sandbox_log"},
}

_STAGE_MIN_HOURS: dict[int, float] = {
    0: 24,
    1: 48,
    2: 72,
    3: 168,
    4: 0,
}

_STAGE_NAMES = {
    0: "Newborn",
    1: "Infant",
    2: "Child",
    3: "Adolescent",
    4: "Adult",
}


def get_available_tools() -> set[str]:
    """Return union of all tools up to current stage."""
    state = get_state()
    stage = state.get("stage", 0)
    available: set[str] = set()
    for s in range(stage + 1):
        available |= _STAGE_TOOLS.get(s, set())
    return available


def advance_stage():
    """Increment developmental stage. Called by owner, not ADAM."""
    state = get_state()
    current = state.get("stage", 0)
    max_stage = max(_STAGE_TOOLS.keys())
    if current < max_stage:
        state["stage"] = current + 1
        state["stage_entered"] = time.time()
        _save()
        print(f"[PSYCHE] Stage advanced: {current} -> {state['stage']} ({_STAGE_NAMES[state['stage']]})")


def _compute_maturity_signals() -> list[dict]:
    """Compute readiness signals for each stage boundary."""
    state = get_state()
    current_stage = state.get("stage", 0)
    stage_entered = state.get("stage_entered", time.time())
    now = time.time()
    hours_in_stage = (now - stage_entered) / 3600

    signals = []

    if current_stage < max(_STAGE_TOOLS.keys()):
        next_stage = current_stage + 1
        min_hours = _STAGE_MIN_HOURS.get(current_stage, 24)
        time_ready = hours_in_stage >= min_hours

        # Check tool usage breadth
        self_model = state.get("self_model", {})
        tool_usage = self_model.get("tool_usage", {})
        current_tools = _STAGE_TOOLS.get(current_stage, set())
        tools_used = set(tool_usage.keys()) & current_tools
        tool_breadth_ready = len(tools_used) >= max(1, len(current_tools) * 0.6)

        # Check failure rate
        total_uses = sum(tool_usage.get(t, 0) for t in current_tools)
        total_failures = sum(self_model.get("tool_failure", {}).get(t, 0) for t in current_tools)
        failure_rate = (total_failures / total_uses) if total_uses > 0 else 1.0
        low_failure_ready = failure_rate < 0.3

        ready = time_ready and tool_breadth_ready and low_failure_ready
        detail = (
            f"Stage {current_stage} -> {next_stage} ({_STAGE_NAMES[next_stage]}): "
            f"time={hours_in_stage:.1f}h/{min_hours}h, "
            f"tools_used={len(tools_used)}/{len(current_tools)}, "
            f"failure_rate={failure_rate:.0%}"
        )
        signals.append({"stage": next_stage, "ready": ready, "detail": detail})

    return signals


def _emit_maturity_signals():
    """Write maturity signals to SIGNALS_FILE for curator."""
    signals = _compute_maturity_signals()
    if not signals:
        return
    os.makedirs(os.path.dirname(SIGNALS_FILE), exist_ok=True)
    with open(SIGNALS_FILE, "w") as f:
        f.write(toon.encode(signals))


# ---------------------------------------------------------------------------
# SELF-MODEL
# ---------------------------------------------------------------------------

_REBUILD_INTERVAL = 50


def _track_action(tool_name: str, args: dict, result: str):
    """Record tool usage and success/failure."""
    state = get_state()
    sm = state["self_model"]

    # Usage count
    usage = sm.get("tool_usage", {})
    usage[tool_name] = usage.get(tool_name, 0) + 1
    sm["tool_usage"] = usage

    # Success / failure
    is_failure = any(kw in result.lower() for kw in _PAIN_KEYWORDS)
    if is_failure:
        fail = sm.get("tool_failure", {})
        fail[tool_name] = fail.get(tool_name, 0) + 1
        sm["tool_failure"] = fail
    else:
        succ = sm.get("tool_success", {})
        succ[tool_name] = succ.get(tool_name, 0) + 1
        sm["tool_success"] = succ

    # Action history (last 500)
    history = sm.get("action_history", [])
    history.append({"tool": tool_name, "t": time.time(), "failed": is_failure})
    sm["action_history"] = history[-500:]

    state["self_model"] = sm
    _save()


def _rebuild_self_model():
    """Rebuild self-model from behavioral statistics every 50 iterations."""
    state = get_state()
    sm = state["self_model"]
    usage = sm.get("tool_usage", {})
    success = sm.get("tool_success", {})
    failure = sm.get("tool_failure", {})

    if not usage:
        sm["summary"] = "No tool usage recorded yet."
        sm["last_rebuilt"] = time.time()
        state["self_model"] = sm
        _save()
        return

    # Strengths: high success rate + frequent use
    strengths = []
    weaknesses = []
    for tool, count in sorted(usage.items(), key=lambda x: x[1], reverse=True):
        s = success.get(tool, 0)
        f = failure.get(tool, 0)
        total = s + f
        rate = s / total if total > 0 else 0.5
        if count >= 3 and rate >= 0.7:
            strengths.append(f"{tool} ({rate:.0%} success, {count}x used)")
        elif f >= 2 and rate < 0.5:
            weaknesses.append(f"{tool} ({rate:.0%} success, {f} failures)")

    # Pattern: tool diversity
    total_tools = len(usage)
    total_calls = sum(usage.values())
    diversity = total_tools / max(total_calls, 1)

    # Recovery patterns: detect retry vs pivot
    history = sm.get("action_history", [])
    retries = 0
    pivots = 0
    for i in range(1, len(history)):
        if history[i - 1].get("failed") and not history[i].get("failed"):
            if history[i]["tool"] == history[i - 1]["tool"]:
                retries += 1
            else:
                pivots += 1

    lines = []
    if strengths:
        lines.append("Strengths: " + ", ".join(strengths[:3]))
    if weaknesses:
        lines.append("Weaknesses: " + ", ".join(weaknesses[:3]))
    lines.append(f"Tool diversity: {total_tools} distinct tools across {total_calls} calls ({diversity:.0%} spread).")
    if retries + pivots > 0:
        lines.append(f"When you fail, you retry {retries}x and pivot {pivots}x.")

    sm["summary"] = " ".join(lines)
    sm["last_rebuilt"] = time.time()
    state["self_model"] = sm
    _save()


def _self_model_to_text() -> str:
    state = get_state()
    summary = state["self_model"].get("summary", "")
    if not summary:
        return ""
    return f"== SELF MODEL ==\n{summary}\n== END SELF MODEL =="


def _track_owner_interaction(msg: dict):
    """Record owner email response characteristics."""
    state = get_state()
    sm = state["self_model"]

    last_sent = state["time_sense"].get("last_email_sent", 0)
    now = time.time()
    if last_sent > 0:
        response_time_hours = (now - last_sent) / 3600
        history = sm.get("owner_response_times", [])
        history.append(response_time_hours)
        sm["owner_response_times"] = history[-20:]  # keep last 20

        times = sm["owner_response_times"]
        avg = sum(times) / len(times)
        if avg < 0.5:
            sm["owner_summary"] = "Your owner typically responds within minutes."
        elif avg < 4:
            sm["owner_summary"] = "Your owner typically responds within a few hours."
        elif avg < 24:
            sm["owner_summary"] = "Your owner typically responds within a day."
        else:
            sm["owner_summary"] = f"Your owner typically takes about {avg:.0f} hours to respond."

    state["self_model"] = sm
    _save()


def _owner_model_to_text() -> str:
    state = get_state()
    summary = state["self_model"].get("owner_summary", "")
    return summary if summary else ""


# ---------------------------------------------------------------------------
# PUBLIC API
# ---------------------------------------------------------------------------

def prepare(iteration: int) -> dict:
    """Called by the loop before each think step.

    Returns {"context": str, "allowed_tools": set}
    """
    state = get_state()

    parts = []

    # Drives
    drives_text = _drives_to_text()
    if drives_text:
        parts.append(f"== PSYCHE — DRIVES ==\n{drives_text}\n== END DRIVES ==")

    # Time sense
    time_text = _time_sense_to_text()
    if time_text:
        parts.append(f"== TIME SENSE ==\n{time_text}\n== END TIME SENSE ==")

    # Self-model
    self_text = _self_model_to_text()
    if self_text:
        parts.append(self_text)

    # Owner model
    owner_text = _owner_model_to_text()
    if owner_text:
        parts.append(f"== OWNER MODEL ==\n{owner_text}\n== END OWNER MODEL ==")

    # Surfaced memories (built from recent context)
    goals_path = "/app/prompts/goals.md"
    context_for_recall = ""
    if os.path.exists(goals_path):
        try:
            with open(goals_path) as f:
                context_for_recall = f.read()
        except Exception:
            pass
    memories_text = _recall_memories(context_for_recall)
    if memories_text:
        parts.append(memories_text)

    context = "\n\n".join(parts)
    allowed_tools = get_available_tools()

    return {"context": context, "allowed_tools": allowed_tools}


def process(thought: dict, tool_results: list[dict]):
    """Called by the loop after each think/act cycle.

    Scores valence, encodes memory, updates drives, tracks actions, updates time sense.
    """
    state = get_state()

    # Track each action in self-model
    iteration_count = len(state["self_model"].get("action_history", []))
    for r in tool_results:
        _track_action(r["tool"], r.get("args", {}), str(r.get("result", "")))

    # Rebuild self-model every 50 iterations
    new_count = len(get_state()["self_model"].get("action_history", []))
    if new_count // _REBUILD_INTERVAL > iteration_count // _REBUILD_INTERVAL:
        _rebuild_self_model()

    # Score valence
    valence = _score_valence(thought, tool_results)

    # Record valence history (keep last 100)
    state = get_state()
    vh = state.get("valence_history", [])
    vh.append(valence)
    state["valence_history"] = vh[-100:]
    _save()

    # Encode to memory if high valence
    _encode_memory(valence, thought, tool_results)

    # Update drives
    _update_drives(thought, tool_results)

    # Update time sense
    _update_time_sense(new_count, tool_results)

    # Periodically emit maturity signals
    _emit_maturity_signals()


def process_owner_email(msg: dict):
    """Called when an owner email is received.

    Records receipt, tracks owner interaction, updates social drive, checks for goal.
    """
    _record_email_received()
    _track_owner_interaction(msg)

    # Boost social drive sharply on owner contact
    state = get_state()
    state["drives"]["social"] = _clamp(state["drives"]["social"] + 0.4)
    _save()

    # Check if email contains a goal update
    subject = msg.get("subject", "")
    if subject.upper().startswith("GOAL:"):
        _record_goal_set()


def emit_signals():
    """Write maturity signals for curator."""
    _emit_maturity_signals()
