"""ADAM main loop — the heartbeat."""

import json
import os
import time
import traceback
import threading

from core import llm, email_client, safety, checkpoint, toon, tools, scheduler, speciation, interrupts, compaction


SPECIATION_INTERVAL = 50
HEARTBEAT_INTERVAL_SEC = 30

_runtime_state = {
    "stage": "init",
    "iteration": 0,
    "last_activity_ts": time.time(),
}
_runtime_state_lock = threading.Lock()


def _set_stage(stage: str, iteration: int | None = None):
    with _runtime_state_lock:
        _runtime_state["stage"] = stage
        if iteration is not None:
            _runtime_state["iteration"] = iteration
        _runtime_state["last_activity_ts"] = time.time()


def _start_heartbeat_thread():
    def _heartbeat():
        while True:
            time.sleep(HEARTBEAT_INTERVAL_SEC)
            with _runtime_state_lock:
                stage = _runtime_state["stage"]
                iteration = _runtime_state["iteration"]
                idle_for = int(time.time() - _runtime_state["last_activity_ts"])
            print(f"[HEARTBEAT] alive iteration={iteration} stage={stage} last_activity={idle_for}s")

    t = threading.Thread(target=_heartbeat, daemon=True, name="adam-heartbeat")
    t.start()


def run():
    print("[ADAM] Initializing...")
    _start_heartbeat_thread()
    _set_stage("initializing")
    checkpoint.init_git()
    safety.init_budget()
    scheduler.init()
    interrupts.init()
    _set_stage("loading-model")
    llm.ensure_model()

    last_checkpoint_time = time.time()
    iteration = 0

    print("[ADAM] Entering main loop.")

    while True:
        iteration += 1
        try:
            _set_stage("iterate", iteration)
            _iterate(iteration)
            safety.clear_corruption_counter()
        except Exception as e:
            print(f"[ADAM] Loop error: {e}")
            traceback.print_exc()
            time.sleep(10)

        _set_stage("validating-state", iteration)
        errors = safety.validate_mutable_state()
        if errors:
            safety.handle_corruption(errors, checkpoint.restore_latest)

        _set_stage("checkpoint-check", iteration)
        if checkpoint.should_checkpoint(last_checkpoint_time):
            checkpoint.snapshot()
            last_checkpoint_time = time.time()

        _set_stage("deduct-electricity", iteration)
        safety.deduct_electricity()


def _iterate(iteration: int):
    iter_start = time.time()

    # 1. CHECK INTERRUPTS (owner emails, alarms, system alerts)
    _set_stage("checking-interrupts", iteration)
    active_interrupts = interrupts.check_all()
    if active_interrupts:
        print(f"[INTERRUPT] {len(active_interrupts)} interrupt(s): {[i['type'] for i in active_interrupts]}")

    # Handle owner email commands (goal updates, budget top-ups)
    owner_messages = []
    for intr in active_interrupts:
        if intr["type"] == "owner_email":
            msg = intr["data"]
            _handle_owner_command(msg)
            owner_messages.append(msg)

    # 2. CHECK SCHEDULED ROUTINES
    _set_stage("checking-routines", iteration)
    due_routines = scheduler.get_due_routines()
    if due_routines:
        print(f"[ROUTINES] {len(due_routines)} due: {[r['name'] for r in due_routines]}")

    # 3. CONTEXT COMPACTION (every N iterations)
    _set_stage("compaction-check", iteration)
    if compaction.should_compact(iteration):
        try:
            compaction.compact()
        except Exception as e:
            print(f"[COMPACTION] Error: {e}")

    # 4. CHECK SKILL SPECIATION (every N iterations)
    _set_stage("speciation-check", iteration)
    skill_proposals = []
    if iteration % SPECIATION_INTERVAL == 0:
        skill_proposals = speciation.analyze()
        if skill_proposals:
            print(f"[SPECIATION] {len(skill_proposals)} new pattern(s) detected")

    # 4. LOAD CONTEXT
    _set_stage("building-context", iteration)
    context = _build_context(iteration, active_interrupts, due_routines, skill_proposals)
    system_prompt = _load_system_prompt()

    # 5. THINK
    _set_stage("thinking", iteration)
    think_start = time.time()
    print(f"[THINK] starting iteration={iteration}")
    thought = llm.think(system_prompt, context, tools.get_tools_for_llm())
    think_sec = time.time() - think_start
    print(f"[THINK] completed iteration={iteration} duration={think_sec:.1f}s")
    print(f"[THOUGHT #{iteration}] {thought['content'][:200]}")

    # 6. EXECUTE
    _set_stage("executing-tools", iteration)
    tool_results = []
    for tc in thought.get("tool_calls", []):
        func = tc.get("function", {})
        name = func.get("name", "")
        args = func.get("arguments", {})
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                args = {}
        result = tools.execute_tool(name, args)
        tool_results.append({"tool": name, "args": args, "result": result})
        print(f"[ACTION] {name} -> {result[:200]}")

    # 7. LOG
    _set_stage("logging-thought", iteration)
    _log_thought(iteration, thought, tool_results)

    # 8. MEMORY NUDGE — after meaningful work, prompt for knowledge persistence
    _set_stage("memory-nudge", iteration)
    if tool_results:
        _memory_nudge(thought, tool_results)

    # 9. If idle, brief pause
    if not thought.get("tool_calls") and not thought.get("content", "").strip():
        _set_stage("idle-sleep", iteration)
        print("[IDLE] no thought content or tool calls; sleeping 5s")
        time.sleep(5)

    iter_sec = time.time() - iter_start
    print(f"[LOOP] iteration={iteration} complete duration={iter_sec:.1f}s tools={len(tool_results)}")


def _handle_owner_command(msg: dict):
    subject = msg.get("subject", "")
    body = msg.get("body", "")

    if subject.upper().startswith("GOAL:"):
        goal_text = subject[5:].strip()
        if body.strip():
            goal_text += "\n" + body.strip()
        goals_path = "/app/prompts/goals.md"
        with open(goals_path, "w") as f:
            f.write(f"# Current Goals\n\n{goal_text}\n")
        print(f"[GOAL UPDATED] {goal_text[:100]}")

    elif subject.upper().startswith("BUDGET:"):
        try:
            amount = float(subject[7:].strip())
            budget = safety.load_budget()
            budget["balance"] = round(budget["balance"] + amount, 4)
            safety.save_budget(budget)
            print(f"[BUDGET] Added ${amount:.2f}, new balance: ${budget['balance']:.2f}")
        except ValueError:
            print(f"[BUDGET] Invalid amount in subject: {subject}")


def _build_context(iteration: int, active_interrupts: list[dict],
                   due_routines: list[dict], skill_proposals: list[dict]) -> str:
    parts = []

    # Interrupts (highest priority — in your face)
    if active_interrupts:
        parts.append("!! INTERRUPTS — ADDRESS THESE FIRST !!")
        for intr in active_interrupts:
            if intr["type"] == "owner_email":
                msg = intr["data"]
                parts.append(f"[OWNER EMAIL] Subject: {msg['subject']}\nBody: {msg['body']}")
            elif intr["type"] == "alarm":
                parts.append(f"[ALARM: {intr['data']['name']}] {intr['data']['message']}")
            elif intr["type"] == "system":
                parts.append(f"[SYSTEM ALERT] {intr['data']['message']}")
        parts.append("!! END INTERRUPTS !!")

    # Due routines
    if due_routines:
        parts.append("== DUE ROUTINES (handle these) ==")
        for r in due_routines:
            parts.append(f"- {r['name']}: {r['description']}")
        parts.append("== END ROUTINES ==")

    # Skill speciation proposals
    if skill_proposals:
        parts.append("== SKILL PROPOSALS ==")
        parts.append("You've been repeating these action patterns. Consider creating reusable tools:")
        for p in skill_proposals:
            parts.append(f"- Pattern: {p['pattern']} (repeated {p['count']}x)")
        parts.append("Use create_tool to make a reusable tool, or ignore if not worth it.")
        parts.append("== END PROPOSALS ==")

    # Current goals
    goals_path = "/app/prompts/goals.md"
    if os.path.exists(goals_path):
        with open(goals_path) as f:
            goals = f.read().strip()
        if goals:
            parts.append(f"== GOALS ==\n{goals}\n== END GOALS ==")

    # Budget (if visible)
    if safety.is_budget_visible():
        budget = safety.load_budget()
        parts.append(f"== BALANCE == ${budget.get('balance', 0):.2f} (spent: ${budget.get('total_spent', 0):.2f}, iterations: {budget.get('iteration_count', 0)})")

    # Long-term summary (compacted old thoughts)
    summary = compaction.load_summary()
    if summary:
        parts.append(f"== LONG-TERM MEMORY ==\n{summary}\n== END LONG-TERM ==")

    # Recent thoughts (last 10)
    parts.append(f"== ITERATION {iteration} ==")
    experiences = _load_recent_thoughts(10)
    if experiences:
        parts.append("== RECENT THOUGHTS ==")
        parts.append(toon.encode(experiences))
        parts.append("== END RECENT ==")

    # Self model
    self_model_path = "/app/memory/self_model.toon"
    if os.path.exists(self_model_path):
        with open(self_model_path) as f:
            parts.append(f"== SELF MODEL ==\n{f.read()}\n== END SELF MODEL ==")

    # Available tools
    parts.append(f"== TOOLS ==\n{tools.get_tools_summary()}\n== END TOOLS ==")

    return "\n\n".join(parts)


def _memory_nudge(thought: dict, tool_results: list[dict]):
    """After meaningful work, do a quick follow-up thought asking if anything is worth remembering."""
    has_significant_action = any(
        r["tool"] in ("web_search", "web_read", "sandbox_run", "shell", "send_email")
        for r in tool_results
    )
    if not has_significant_action:
        return

    nudge_context = (
        f"You just completed these actions:\n"
        + "\n".join(f"- {r['tool']}: {r['result'][:200]}" for r in tool_results)
        + "\n\nAnything worth saving to knowledge (write_knowledge tool)? "
        "If not, just say 'nothing to save'. Be selective — only save genuinely useful learnings."
    )

    nudge_thought = llm.think(
        "You are ADAM. Decide if your recent work produced knowledge worth persisting. Be selective.",
        nudge_context,
        tools.get_tools_for_llm()
    )

    for tc in nudge_thought.get("tool_calls", []):
        func = tc.get("function", {})
        name = func.get("name", "")
        if name == "write_knowledge":
            args = func.get("arguments", {})
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    continue
            tools.execute_tool(name, args)
            print(f"[NUDGE] Saved knowledge: {args.get('topic', '?')}")


def _load_system_prompt() -> str:
    path = "/app/prompts/system.md"
    if os.path.exists(path):
        with open(path) as f:
            return f.read()
    return "You are ADAM, an autonomous agent. Think carefully, act deliberately."


def _load_recent_thoughts(n: int) -> list[dict]:
    path = "/app/memory/experiences.toon"
    if not os.path.exists(path):
        return []
    try:
        with open(path) as f:
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


def _log_thought(iteration: int, thought: dict, tool_results: list[dict]):
    entry = {
        "i": iteration,
        "t": time.time(),
        "thought": thought.get("content", "")[:500],
        "actions": [{"tool": r["tool"], "result": r["result"][:200]} for r in tool_results],
        "tokens": thought.get("tokens", 0),
    }
    path = "/app/memory/experiences.toon"
    with open(path, "a") as f:
        f.write(json.dumps(entry) + "\n")


if __name__ == "__main__":
    run()
