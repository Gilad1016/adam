"""Ollama LLM client — each call is a thought."""

import json
import os
import requests


OLLAMA_HOST = os.environ.get("ADAM_OLLAMA_HOST", "localhost:11434")
OLLAMA_MODEL = os.environ.get("ADAM_OLLAMA_MODEL", "gemma3:12b")


def think(system_prompt: str, context: str, tools: list[dict] | None = None) -> dict:
    url = f"http://{OLLAMA_HOST}/api/chat"

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": context},
    ]

    payload = {
        "model": OLLAMA_MODEL,
        "messages": messages,
        "stream": False,
        "options": {
            "temperature": 0.7,
            "num_ctx": 8192,
        },
    }

    if tools:
        payload["tools"] = tools

    try:
        resp = requests.post(url, json=payload, timeout=300)
        resp.raise_for_status()
        data = resp.json()
    except requests.RequestException as e:
        return {
            "content": f"[THOUGHT FAILED: {e}]",
            "tool_calls": [],
            "tokens": 0,
        }

    message = data.get("message", {})
    return {
        "content": message.get("content", ""),
        "tool_calls": message.get("tool_calls", []),
        "tokens": data.get("eval_count", 0) + data.get("prompt_eval_count", 0),
    }


def check_health() -> bool:
    try:
        resp = requests.get(f"http://{OLLAMA_HOST}/api/tags", timeout=5)
        return resp.status_code == 200
    except requests.RequestException:
        return False


def ensure_model() -> bool:
    try:
        resp = requests.get(f"http://{OLLAMA_HOST}/api/tags", timeout=10)
        models = [m["name"] for m in resp.json().get("models", [])]
        if any(OLLAMA_MODEL in m for m in models):
            return True
        print(f"Pulling model {OLLAMA_MODEL}...")
        resp = requests.post(
            f"http://{OLLAMA_HOST}/api/pull",
            json={"name": OLLAMA_MODEL},
            timeout=600,
        )
        return resp.status_code == 200
    except requests.RequestException:
        return False
