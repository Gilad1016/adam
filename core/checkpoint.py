"""Checkpoint — snapshot and restore mutable state."""

import os
import shutil
import subprocess
import time


CHECKPOINT_DIR = "/app/checkpoints"
MUTABLE_PATHS = ["/app/prompts", "/app/tools", "/app/strategies"]
MAX_CHECKPOINTS = 10


def init_git():
    app_dir = "/app"
    try:
        if not os.path.exists(os.path.join(app_dir, ".git")):
            subprocess.run(["git", "init"], cwd=app_dir, capture_output=True)
            subprocess.run(["git", "config", "user.email", "adam@local"], cwd=app_dir, capture_output=True)
            subprocess.run(["git", "config", "user.name", "ADAM"], cwd=app_dir, capture_output=True)
        remote_url = os.environ.get("GIT_REMOTE_URL")
        if remote_url:
            subprocess.run(["git", "remote", "remove", "origin"], cwd=app_dir,
                            capture_output=True)
            subprocess.run(["git", "remote", "add", "origin", remote_url], cwd=app_dir,
                            capture_output=True)
        _git_commit("initial state")
        # Take an immediate snapshot so there's always a checkpoint to restore from
        snapshot()
        print("[CHECKPOINT] Initial snapshot created")
    except Exception as e:
        print(f"[CHECKPOINT] Git init warning (non-fatal): {e}")


def snapshot() -> str:
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    snap_dir = os.path.join(CHECKPOINT_DIR, timestamp)
    os.makedirs(snap_dir, exist_ok=True)

    for path in MUTABLE_PATHS:
        if os.path.exists(path):
            dirname = os.path.basename(path)
            shutil.copytree(path, os.path.join(snap_dir, dirname), dirs_exist_ok=True)

    _prune_old_checkpoints()
    _git_commit(f"checkpoint {timestamp}")
    return snap_dir


def restore_latest() -> bool:
    checkpoints = _list_checkpoints()
    if not checkpoints:
        return False

    latest = checkpoints[-1]
    snap_dir = os.path.join(CHECKPOINT_DIR, latest)

    for path in MUTABLE_PATHS:
        dirname = os.path.basename(path)
        src = os.path.join(snap_dir, dirname)
        if os.path.exists(src):
            shutil.rmtree(path, ignore_errors=True)
            shutil.copytree(src, path)

    _git_commit(f"restored from {latest}")
    return True


def should_checkpoint(last_checkpoint_time: float) -> bool:
    interval = int(os.environ.get("ADAM_CHECKPOINT_INTERVAL_MINUTES", "60"))
    return (time.time() - last_checkpoint_time) >= interval * 60


def _list_checkpoints() -> list[str]:
    if not os.path.exists(CHECKPOINT_DIR):
        return []
    entries = sorted(os.listdir(CHECKPOINT_DIR))
    return [e for e in entries if os.path.isdir(os.path.join(CHECKPOINT_DIR, e))]


def _prune_old_checkpoints():
    checkpoints = _list_checkpoints()
    while len(checkpoints) > MAX_CHECKPOINTS:
        oldest = checkpoints.pop(0)
        shutil.rmtree(os.path.join(CHECKPOINT_DIR, oldest), ignore_errors=True)


def _git_commit(message: str):
    app_dir = "/app"
    subprocess.run(["git", "add", "-A"], cwd=app_dir, capture_output=True)
    subprocess.run(["git", "commit", "-m", message, "--allow-empty"],
                   cwd=app_dir, capture_output=True)
