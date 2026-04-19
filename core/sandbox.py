"""Sandbox — unrestricted workspace where ADAM can write and run anything.

This is ADAM's personal computer within the computer. It can:
- Write and run any code (Python, shell scripts, services)
- Start long-running processes (sub-agents, servers, daemons)
- Install packages
- Create entire applications
- No restrictions — if ADAM can imagine it, it can build and run it here.
"""

import os
import subprocess
import signal
import json
import time


SANDBOX_DIR = "/app/sandbox"
PROCESSES_FILE = "/app/sandbox/.processes.json"


def init():
    os.makedirs(SANDBOX_DIR, exist_ok=True)
    os.makedirs(os.path.join(SANDBOX_DIR, "projects"), exist_ok=True)
    os.makedirs(os.path.join(SANDBOX_DIR, "services"), exist_ok=True)
    os.makedirs(os.path.join(SANDBOX_DIR, "scripts"), exist_ok=True)


def run_script(name: str, code: str, language: str = "python") -> str:
    init()
    ext = {"python": ".py", "bash": ".sh", "node": ".js"}.get(language, ".py")
    script_path = os.path.join(SANDBOX_DIR, "scripts", f"{name}{ext}")

    with open(script_path, "w") as f:
        f.write(code)
    os.chmod(script_path, 0o755)

    cmd = {"python": ["python", script_path],
           "bash": ["bash", script_path],
           "node": ["node", script_path]}.get(language, ["python", script_path])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                                cwd=SANDBOX_DIR)
        output = result.stdout + result.stderr
        return output[:4000] if output else "(no output)"
    except subprocess.TimeoutExpired:
        return "[TIMEOUT after 120s]"
    except Exception as e:
        return f"[ERROR: {e}]"


def start_service(name: str, command: str) -> str:
    init()
    _load_processes()

    log_path = os.path.join(SANDBOX_DIR, "services", f"{name}.log")
    log_file = open(log_path, "a")

    try:
        proc = subprocess.Popen(
            command, shell=True, stdout=log_file, stderr=log_file,
            cwd=SANDBOX_DIR, start_new_session=True
        )
        _save_process(name, proc.pid, command)
        return f"service '{name}' started (pid={proc.pid}, log={log_path})"
    except Exception as e:
        return f"[ERROR starting service: {e}]"


def stop_service(name: str) -> str:
    processes = _load_processes()
    if name not in processes:
        return f"[no service named '{name}']"

    pid = processes[name]["pid"]
    try:
        os.kill(pid, signal.SIGTERM)
        del processes[name]
        _save_processes(processes)
        return f"service '{name}' stopped (pid={pid})"
    except ProcessLookupError:
        del processes[name]
        _save_processes(processes)
        return f"service '{name}' was already dead, cleaned up"
    except Exception as e:
        return f"[ERROR stopping service: {e}]"


def list_services() -> str:
    processes = _load_processes()
    if not processes:
        return "no running services"
    lines = []
    for name, info in processes.items():
        alive = _is_alive(info["pid"])
        status = "running" if alive else "dead"
        lines.append(f"- {name}: pid={info['pid']} [{status}] cmd={info['command']}")
    return "\n".join(lines)


def read_service_log(name: str, tail: int = 50) -> str:
    log_path = os.path.join(SANDBOX_DIR, "services", f"{name}.log")
    if not os.path.exists(log_path):
        return f"[no log for service '{name}']"
    with open(log_path) as f:
        lines = f.readlines()
    return "".join(lines[-tail:])[:4000]


def install_package(package: str) -> str:
    try:
        result = subprocess.run(
            ["pip", "install", package],
            capture_output=True, text=True, timeout=120
        )
        return (result.stdout + result.stderr)[:2000]
    except Exception as e:
        return f"[INSTALL ERROR: {e}]"


def create_project(name: str, files: dict[str, str]) -> str:
    init()
    project_dir = os.path.join(SANDBOX_DIR, "projects", name)
    os.makedirs(project_dir, exist_ok=True)

    created = []
    for filename, content in files.items():
        filepath = os.path.join(project_dir, filename)
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        with open(filepath, "w") as f:
            f.write(content)
        created.append(filename)

    return f"project '{name}' created at {project_dir} with files: {', '.join(created)}"


def _is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _load_processes() -> dict:
    if not os.path.exists(PROCESSES_FILE):
        return {}
    try:
        with open(PROCESSES_FILE) as f:
            return json.loads(f.read())
    except Exception:
        return {}


def _save_process(name: str, pid: int, command: str):
    processes = _load_processes()
    processes[name] = {"pid": pid, "command": command, "started": time.time()}
    _save_processes(processes)


def _save_processes(processes: dict):
    with open(PROCESSES_FILE, "w") as f:
        f.write(json.dumps(processes))
