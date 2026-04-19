"""TOON encoder/decoder — compact token-efficient serialization."""

import json
from typing import Any


def encode(data: Any) -> str:
    if isinstance(data, list) and len(data) > 0 and all(isinstance(item, dict) for item in data):
        return _encode_table(data)
    if isinstance(data, dict):
        return _encode_dict(data)
    return json.dumps(data)


def decode(text: str) -> Any:
    text = text.strip()
    if not text:
        return None
    if text.startswith("{") or text.startswith("["):
        return json.loads(text)
    lines = text.split("\n")
    if len(lines) >= 2 and "," in lines[0]:
        return _decode_table(lines)
    return _decode_dict(lines)


def _encode_table(items: list[dict]) -> str:
    keys = list(items[0].keys())
    header = ", ".join(keys)
    rows = []
    for item in items:
        vals = []
        for k in keys:
            v = item.get(k, "")
            vals.append(_serialize_val(v))
        rows.append(", ".join(vals))
    return header + "\n" + "\n".join(rows)


def _encode_dict(d: dict, indent: int = 0) -> str:
    lines = []
    prefix = "  " * indent
    for k, v in d.items():
        if isinstance(v, dict):
            lines.append(f"{prefix}{k}:")
            lines.append(_encode_dict(v, indent + 1))
        elif isinstance(v, list) and len(v) > 0 and all(isinstance(i, dict) for i in v):
            lines.append(f"{prefix}{k}:")
            lines.append(_indent(_encode_table(v), indent + 1))
        else:
            lines.append(f"{prefix}{k}: {_serialize_val(v)}")
    return "\n".join(lines)


def _decode_table(lines: list[str]) -> list[dict]:
    keys = [k.strip() for k in lines[0].split(",")]
    items = []
    for line in lines[1:]:
        if not line.strip():
            continue
        vals = [v.strip() for v in line.split(",")]
        item = {}
        for i, k in enumerate(keys):
            item[k] = _deserialize_val(vals[i]) if i < len(vals) else ""
        items.append(item)
    return items


def _decode_dict(lines: list[str]) -> dict:
    result = {}
    for line in lines:
        if not line.strip():
            continue
        if ": " in line:
            k, v = line.split(": ", 1)
            result[k.strip()] = _deserialize_val(v.strip())
        elif line.endswith(":"):
            result[line[:-1].strip()] = {}
    return result


def _serialize_val(v: Any) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return str(v).lower()
    if isinstance(v, (int, float)):
        return str(v)
    return str(v)


def _deserialize_val(v: str) -> Any:
    if v == "null":
        return None
    if v == "true":
        return True
    if v == "false":
        return False
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v


def _indent(text: str, level: int) -> str:
    prefix = "  " * level
    return "\n".join(prefix + line for line in text.split("\n"))
