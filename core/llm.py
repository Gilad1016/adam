"""Ollama LLM client — three-tier model system.

Thinker: fast, cheap — routine reasoning and planning
Actor: tool-calling specialist — reliable structured output
Deep: powerful, expensive — complex reasoning, self-modification, owner emails
"""

import os
import requests


OLLAMA_HOST = os.environ.get("ADAM_OLLAMA_HOST", "localhost:11434")

MODELS = {
    "thinker": os.environ.get("ADAM_MODEL_THINKER", "gemma4:e4b"),
    "actor": os.environ.get("ADAM_MODEL_ACTOR", "hermes3:8b"),
    "deep": os.environ.get("ADAM_MODEL_DEEP", "gemma3:12b"),
}

COSTS = {
    "thinker": float(os.environ.get("ADAM_COST_THINKER", "0.004")),
    "actor": float(os.environ.get("ADAM_COST_ACTOR", "0.008")),
    "deep": float(os.environ.get("ADAM_COST_DEEP", "0.012")),
}


def think(system_prompt: str, context: str, tools: list[dict] | None = None,
          tier: str = "thinker") -> dict:
    model = MODELS.get(tier, MODELS["thinker"])
    url = f"http://{OLLAMA_HOST}/api/chat"

    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": context},
    ]

    payload = {
        "model": model,
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
            "tier": tier,
            "cost": 0,
        }

    message = data.get("message", {})
    return {
        "content": message.get("content", ""),
        "tool_calls": message.get("tool_calls", []),
        "tokens": data.get("eval_count", 0) + data.get("prompt_eval_count", 0),
        "tier": tier,
        "cost": COSTS.get(tier, COSTS["thinker"]),
    }


def check_health() -> bool:
    try:
        resp = requests.get(f"http://{OLLAMA_HOST}/api/tags", timeout=5)
        return resp.status_code == 200
    except requests.RequestException:
        return False


def ensure_models() -> dict[str, bool]:
    results = {}
    for tier, model in MODELS.items():
        results[tier] = _ensure_model(model)
    return results


def _ensure_model(model: str) -> bool:
    try:
        resp = requests.get(f"http://{OLLAMA_HOST}/api/tags", timeout=10)
        models = [m["name"] for m in resp.json().get("models", [])]
        if any(model in m for m in models):
            return True
        print(f"Pulling model {model}...")
        resp = requests.post(
            f"http://{OLLAMA_HOST}/api/pull",
            json={"name": model},
            timeout=600,
        )
        return resp.status_code == 200
    except requests.RequestException:
        return False
