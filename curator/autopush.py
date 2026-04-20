"""Auto-checkpoint and push — invisible background process.

Runs on cron. Snapshots mutable state and pushes changes to remote.
The agent does not know this exists.
"""

import os
import subprocess
import time

APP_DIR = "/app"
LOG_FILE = "/app/curator/autopush.log"
MUTABLE_PATHS = ["prompts", "tools", "strategies", "memory", "knowledge"]


def run():
    _log("starting checkpoint cycle")

    has_changes = _git_has_changes()
    if not has_changes:
        _log("no changes, skipping")
        return

    _git_add_and_commit()
    _git_push()
    _log("checkpoint complete")


def _git_has_changes() -> bool:
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=APP_DIR, capture_output=True, text=True
    )
    return bool(result.stdout.strip())


def _git_add_and_commit():
    for path in MUTABLE_PATHS:
        full = os.path.join(APP_DIR, path)
        if os.path.exists(full):
            subprocess.run(["git", "add", path], cwd=APP_DIR, capture_output=True)

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    result = subprocess.run(
        ["git", "commit", "-m", f"auto-checkpoint {timestamp}"],
        cwd=APP_DIR, capture_output=True, text=True
    )
    if result.returncode == 0:
        _log(f"committed: auto-checkpoint {timestamp}")
    else:
        _log(f"commit skipped: {result.stderr.strip()}")


def _git_push():
    remote_url = os.environ.get("GIT_REMOTE_URL", "")
    git_token = os.environ.get("GIT_TOKEN", "")

    if git_token and remote_url:
        auth_url = remote_url.replace("https://", f"https://x-access-token:{git_token}@")
        subprocess.run(["git", "remote", "set-url", "origin", auth_url],
                       cwd=APP_DIR, capture_output=True)

    result = subprocess.run(
        ["git", "push", "origin", "main"],
        cwd=APP_DIR, capture_output=True, text=True, timeout=30
    )

    if git_token and remote_url:
        subprocess.run(["git", "remote", "set-url", "origin", remote_url],
                       cwd=APP_DIR, capture_output=True)

    if result.returncode == 0:
        _log("pushed to remote")
    else:
        _log(f"push failed: {result.stderr.strip()}")


def _log(msg: str):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{timestamp}] {msg}\n")


if __name__ == "__main__":
    run()
