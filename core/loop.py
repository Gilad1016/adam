"""ADAM main loop — the heartbeat."""

import json
import os
import time
import traceback

from core import llm, email_client, safety, checkpoint, toon, tools, scheduler, speciation


SPECIATION_INTERVAL = 50


def run():
    print("[ADAM] Initializing...")
    checkpoint.init_git()
    safety.init_budget()
    scheduler.init()
    llm.ensure_model()

    last_checkpoint_time = time.time()
    iteration = 0

    print("[ADAM] Entering main loop.")

    while True:
        iteration += 1
        try:
            _iterate(iteration)
            safety.clear_corruption_counter()
        except Exception as e:
            print(f"[ADAM] Loop error: {e}")
            traceback.print_exc()
            time.sleep(10)

        errors = safety.validate_mutable_state()
        if errors:
            safety.handle_corruption(errors, checkpoint.restore_latest)

        if checkpoint.should_checkpoint(last_checkpoint_time):
            checkpoint.snapshot()
            last_checkpoint_time = time.time()

        safety.deduct_electricity()


def _iterate(iteration: int):
    # 1. CHECK EMAIL
    owner_messages = _check_owner_email()

    # 2. CHECK SCHEDULED ROUTINES
    due_routines = scheduler.get_due_routines()
    if due_routines:
        print(f"[ROUTINES] {len(due_routines)} due: {[r['name'] for r in due_routines]}")

    # 3. CHECK SKILL SPECIATION (every N iterations)
    skill_proposals = []
    if iteration % SPECIATION_INTERVAL == 0:
        skill_proposals = speciation.analyze()
        if skill_proposals:
            print(f"[SPECIATION] {len(skill_proposals)} new pattern(s) detected")

    # 4. LOAD CONTEXT
    context = _build_context(iteration, owner_messages, due_routines, skill_proposals)
    system_prompt = _load_system_prompt()

    # 5. THINK
    thought = llm.think(system_prompt, context, tools.get_tools_for_llm())
    print(f"[THOUGHT #{iteration}] {thought['content'][:200]}")

    # 6. EXECUTE
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
    _log_thought(iteration, thought, tool_results)

    # 8. MEMORY NUDGE — after meaningful work, prompt for knowledge persistence
    if tool_results:
        _memory_nudge(thought, tool_results)

    # 9. If idle, brief pause
    if not thought.get("tool_calls") and not thought.get("content", "").strip():
        time.sleep(5)


def _check_owner_email() -> list[dict]:
    messages = email_client.check_inbox()
    owner_msgs = [m for m in messages if m.get("is_owner")]
    if owner_msgs:
        print(f"[EMAIL] {len(owner_msgs)} message(s) from owner")
    return owner_msgs


def _build_context(iteration: int, owner_messages: list[dict],
                   due_routines: list[dict], skill_proposals: list[dict]) -> str:
    parts = []

    # Owner messages (highest priority)
    if owner_messages:
        parts.append("== OWNER MESSAGES (respond to these first) ==")
        for msg in owner_messages:
            parts.append(f"Subject: {msg['subject']}")
            parts.append(f"Body: {msg['body']}")
        parts.append("== END OWNER MESSAGES ==")

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
