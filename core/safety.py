"""Safety — budget tracking, corruption detection, safe mode."""

import json
import os
import shutil
import time

from core import toon


BUDGET_FILE = "/app/memory/budget.toon"
DEFAULTS_DIR = "/app/defaults"
MUTABLE_DIRS = ["/app/prompts", "/app/tools", "/app/strategies"]

_consecutive_rollbacks = 0
MAX_ROLLBACKS_BEFORE_SAFE_MODE = 3


def init_budget():
    if os.path.exists(BUDGET_FILE):
        return
    total = float(os.environ.get("ADAM_BUDGET_TOTAL", "250"))
    budget = {
        "balance": total,
        "initial": total,
        "total_spent": 0,
        "iteration_count": 0,
        "last_deduction": time.time(),
    }
    with open(BUDGET_FILE, "w") as f:
        f.write(toon.encode(budget))


def deduct_electricity() -> float:
    cost = float(os.environ.get("ADAM_BUDGET_ELECTRICITY_PER_ITERATION", "0.01"))
    budget = load_budget()
    budget["balance"] = round(budget["balance"] - cost, 4)
    budget["total_spent"] = round(budget["total_spent"] + cost, 4)
    budget["iteration_count"] = budget.get("iteration_count", 0) + 1
    budget["last_deduction"] = time.time()
    save_budget(budget)
    return budget["balance"]


def load_budget() -> dict:
    if not os.path.exists(BUDGET_FILE):
        init_budget()
    with open(BUDGET_FILE) as f:
        return toon.decode(f.read())


def save_budget(budget: dict):
    with open(BUDGET_FILE, "w") as f:
        f.write(toon.encode(budget))


def get_balance() -> float:
    return load_budget().get("balance", 0)


def is_budget_visible() -> bool:
    return os.environ.get("ADAM_BUDGET_VISIBLE", "true").lower() == "true"


def validate_mutable_state() -> list[str]:
    errors = []

    system_prompt = "/app/prompts/system.md"
    if not os.path.exists(system_prompt):
        errors.append("prompts/system.md missing")
    elif os.path.getsize(system_prompt) == 0:
        errors.append("prompts/system.md is empty")

    goals_file = "/app/prompts/goals.md"
    if not os.path.exists(goals_file):
        errors.append("prompts/goals.md missing")

    tools_dir = "/app/tools"
    if os.path.exists(tools_dir):
        for f in os.listdir(tools_dir):
            if f.endswith(".py") and f != "__init__.py":
                path = os.path.join(tools_dir, f)
                try:
                    with open(path) as fh:
                        compile(fh.read(), path, "exec")
                except SyntaxError as e:
                    errors.append(f"tools/{f} has syntax error: {e}")

    budget = load_budget()
    if not isinstance(budget.get("balance"), (int, float)):
        errors.append("budget balance is not a valid number")

    return errors


def handle_corruption(errors: list[str], checkpoint_fn) -> bool:
    global _consecutive_rollbacks
    _consecutive_rollbacks += 1

    print(f"[CORRUPTION DETECTED ({_consecutive_rollbacks}/{MAX_ROLLBACKS_BEFORE_SAFE_MODE})]: {errors}")

    if _consecutive_rollbacks >= MAX_ROLLBACKS_BEFORE_SAFE_MODE:
        print("[ENTERING SAFE MODE — resetting to factory defaults]")
        _reset_to_defaults()
        _consecutive_rollbacks = 0
        return True

    restored = checkpoint_fn()
    if not restored:
        print("[NO CHECKPOINT AVAILABLE — restoring missing files from defaults]")
        _restore_missing_from_defaults()
    return restored


def _restore_missing_from_defaults():
    for dirname in ["prompts", "tools"]:
        src_dir = os.path.join(DEFAULTS_DIR, dirname)
        dst_dir = os.path.join("/app", dirname)
        if not os.path.exists(src_dir):
            continue
        os.makedirs(dst_dir, exist_ok=True)
        for filename in os.listdir(src_dir):
            src_file = os.path.join(src_dir, filename)
            dst_file = os.path.join(dst_dir, filename)
            if not os.path.exists(dst_file) or os.path.getsize(dst_file) == 0:
                if os.path.isfile(src_file):
                    shutil.copy2(src_file, dst_file)
                    print(f"[RESTORED] {dirname}/{filename} from defaults")


def clear_corruption_counter():
    global _consecutive_rollbacks
    _consecutive_rollbacks = 0


def _reset_to_defaults():
    for dirname in ["prompts", "tools"]:
        src = os.path.join(DEFAULTS_DIR, dirname)
        dst = os.path.join("/app", dirname)
        if os.path.exists(src):
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(src, dst)
