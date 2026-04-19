"""Tool registry and executor."""

import importlib.util
import os
import subprocess

from core import toon, email_client, checkpoint


TOOLS_DIR = "/app/tools"

BUILTIN_TOOLS = {
    "shell": {
        "description": "Execute a shell command. Args: {command: string}",
        "execute": lambda args: _run_shell(args["command"]),
    },
    "read_file": {
        "description": "Read a file. Args: {path: string}",
        "execute": lambda args: _read_file(args["path"]),
    },
    "write_file": {
        "description": "Write content to a file. Args: {path: string, content: string}",
        "execute": lambda args: _write_file(args["path"], args["content"]),
    },
    "send_email": {
        "description": "Send email to owner. Args: {subject: string, body: string}",
        "execute": lambda args: str(email_client.send_email(args["subject"], args["body"])),
    },
    "wait": {
        "description": "Rest for N minutes to conserve electricity. Args: {minutes: number}",
        "execute": lambda args: _wait(args["minutes"]),
    },
    "write_knowledge": {
        "description": "Save knowledge to shared knowledge base. Args: {topic: string, content: string}",
        "execute": lambda args: _write_knowledge(args["topic"], args["content"]),
    },
    "modify_prompt": {
        "description": "Modify your own system prompt. Triggers checkpoint first. Args: {content: string}",
        "execute": lambda args: _modify_prompt(args["content"]),
    },
    "create_tool": {
        "description": "Create a new tool. Triggers checkpoint first. Args: {name: string, code: string}",
        "execute": lambda args: _create_tool(args["name"], args["code"]),
    },
    "web_search": {
        "description": "Search the web via DuckDuckGo. Args: {query: string}",
        "execute": lambda args: _web_search(args["query"]),
    },
    "web_read": {
        "description": "Fetch and read a web page as text. Args: {url: string}",
        "execute": lambda args: _web_read(args["url"]),
    },
}


def get_all_tools() -> dict:
    tools = dict(BUILTIN_TOOLS)
    tools.update(_load_custom_tools())
    return tools


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


def get_tools_summary() -> str:
    lines = []
    for name, tool in get_all_tools().items():
        lines.append(f"- {name}: {tool['description']}")
    return "\n".join(lines)


def execute_tool(name: str, args: dict) -> str:
    tools = get_all_tools()
    if name not in tools:
        return f"[ERROR: unknown tool '{name}']"
    try:
        return str(tools[name]["execute"](args))
    except Exception as e:
        return f"[TOOL ERROR: {e}]"


def _load_custom_tools() -> dict:
    custom = {}
    if not os.path.exists(TOOLS_DIR):
        return custom
    for f in os.listdir(TOOLS_DIR):
        if f.endswith(".py") and f != "__init__.py":
            path = os.path.join(TOOLS_DIR, f)
            try:
                spec = importlib.util.spec_from_file_location(f[:-3], path)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                custom[mod.TOOL_NAME] = {
                    "description": mod.TOOL_DESCRIPTION,
                    "execute": mod.execute,
                }
            except Exception:
                continue
    return custom


def _run_shell(command: str) -> str:
    try:
        result = subprocess.run(
            command, shell=True, capture_output=True, text=True, timeout=60
        )
        output = result.stdout + result.stderr
        return output[:2000] if output else "(no output)"
    except subprocess.TimeoutExpired:
        return "[TIMEOUT after 60s]"


def _read_file(path: str) -> str:
    try:
        with open(path) as f:
            content = f.read()
        return content[:4000] if content else "(empty file)"
    except Exception as e:
        return f"[ERROR: {e}]"


def _write_file(path: str, content: str) -> str:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        return f"wrote {len(content)} bytes to {path}"
    except Exception as e:
        return f"[ERROR: {e}]"


def _wait(minutes: int) -> str:
    import time
    minutes = max(1, min(minutes, 60))
    time.sleep(minutes * 60)
    return f"rested for {minutes} minutes"


def _write_knowledge(topic: str, content: str) -> str:
    path = f"/app/knowledge/{topic}.toon"
    existing = ""
    if os.path.exists(path):
        with open(path) as f:
            existing = f.read() + "\n"
    with open(path, "w") as f:
        f.write(existing + content)
    return f"knowledge saved to {topic}"


def _modify_prompt(content: str) -> str:
    checkpoint.snapshot()
    with open("/app/prompts/system.md", "w") as f:
        f.write(content)
    return "system prompt updated (checkpoint created)"


def _create_tool(name: str, code: str) -> str:
    try:
        compile(code, f"{name}.py", "exec")
    except SyntaxError as e:
        return f"[SYNTAX ERROR: {e}] — tool not created"
    checkpoint.snapshot()
    path = os.path.join(TOOLS_DIR, f"{name}.py")
    with open(path, "w") as f:
        f.write(code)
    return f"tool '{name}' created (checkpoint created)"


def _web_search(query: str) -> str:
    try:
        import requests
        resp = requests.get(
            "https://html.duckduckgo.com/html/",
            params={"q": query},
            headers={"User-Agent": "ADAM/1.0"},
            timeout=15,
        )
        from html.parser import HTMLParser

        results = []

        class DDGParser(HTMLParser):
            in_result = False
            current = {}

            def handle_starttag(self, tag, attrs):
                attrs_dict = dict(attrs)
                if tag == "a" and "result__a" in attrs_dict.get("class", ""):
                    self.in_result = True
                    self.current = {"url": attrs_dict.get("href", ""), "title": ""}

            def handle_data(self, data):
                if self.in_result:
                    self.current["title"] += data

            def handle_endtag(self, tag):
                if tag == "a" and self.in_result:
                    self.in_result = False
                    if self.current.get("title"):
                        results.append(self.current)

        parser = DDGParser()
        parser.feed(resp.text)
        lines = [f"- {r['title'].strip()}: {r['url']}" for r in results[:5]]
        return "\n".join(lines) if lines else "no results found"
    except Exception as e:
        return f"[SEARCH ERROR: {e}]"


def _web_read(url: str) -> str:
    try:
        import requests
        resp = requests.get(url, headers={"User-Agent": "ADAM/1.0"}, timeout=15)
        text = resp.text[:4000]
        return text
    except Exception as e:
        return f"[WEB READ ERROR: {e}]"
