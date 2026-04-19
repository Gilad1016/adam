"""ADAM main loop — the heartbeat."""

import json
import os
import time
import traceback

from core import llm, email_client, safety, checkpoint, toon, tools


def run():
    print("[ADAM] Initializing...")
    checkpoint.init_git()
    safety.init_budget()
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

    # 2. LOAD CONTEXT
    context = _build_context(iteration, owner_messages)
    system_prompt = _load_system_prompt()

    # 3. THINK
    thought = llm.think(system_prompt, context, tools.get_tools_for_llm())
    print(f"[THOUGHT #{iteration}] {thought['content'][:200]}")

    # 4. EXECUTE
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

    # 5. LOG
    _log_thought(iteration, thought, tool_results)

    # 6. If no tool calls and no meaningful content, brief pause to avoid spinning
    if not thought.get("tool_calls") and not thought.get("content", "").strip():
        time.sleep(5)


def _check_owner_email() -> list[dict]:
    messages = email_client.check_inbox()
    owner_msgs = [m for m in messages if m.get("is_owner")]
    if owner_msgs:
        print(f"[EMAIL] {len(owner_msgs)} message(s) from owner")
    return owner_msgs


def _build_context(iteration: int, owner_messages: list[dict]) -> str:
    parts = []

    # Owner messages (highest priority)
    if owner_messages:
        parts.append("== OWNER MESSAGES (respond to these first) ==")
        for msg in owner_messages:
            parts.append(f"Subject: {msg['subject']}")
            parts.append(f"Body: {msg['body']}")
        parts.append("== END OWNER MESSAGES ==")

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
