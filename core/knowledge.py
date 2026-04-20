"""Knowledge management — structured, queryable, indexed.

Knowledge is organized as entries with topics and tags.
An index file tracks all entries for quick lookup.
ADAM can write, read, search, and list knowledge.
"""

import json
import os
import time


KNOWLEDGE_DIR = "/app/knowledge"
INDEX_FILE = "/app/knowledge/_index.json"


def init():
    os.makedirs(KNOWLEDGE_DIR, exist_ok=True)
    if not os.path.exists(INDEX_FILE):
        _save_index([])


def write(topic: str, content: str, tags: list[str] | None = None) -> str:
    init()
    entry_id = f"{int(time.time())}_{_slugify(topic)}"
    entry = {
        "id": entry_id,
        "topic": topic,
        "tags": tags or [],
        "content": content,
        "created": time.time(),
        "updated": time.time(),
    }

    path = os.path.join(KNOWLEDGE_DIR, f"{entry_id}.json")
    with open(path, "w") as f:
        json.dump(entry, f, indent=2)

    index = _load_index()
    index.append({
        "id": entry_id,
        "topic": topic,
        "tags": tags or [],
        "summary": content[:100],
        "created": entry["created"],
    })
    _save_index(index)

    return f"knowledge saved: '{topic}' (id={entry_id})"


def read(entry_id: str) -> str:
    path = os.path.join(KNOWLEDGE_DIR, f"{entry_id}.json")
    if not os.path.exists(path):
        return f"[no entry with id '{entry_id}']"
    with open(path) as f:
        entry = json.load(f)
    return f"## {entry['topic']}\nTags: {', '.join(entry.get('tags', []))}\n\n{entry['content']}"


def search(query: str) -> str:
    index = _load_index()
    query_lower = query.lower()
    matches = []

    for item in index:
        score = 0
        if query_lower in item["topic"].lower():
            score += 3
        if any(query_lower in tag.lower() for tag in item.get("tags", [])):
            score += 2
        if query_lower in item.get("summary", "").lower():
            score += 1
        if score > 0:
            matches.append((score, item))

    if not matches:
        return f"no knowledge found for '{query}'"

    matches.sort(key=lambda x: x[0], reverse=True)
    lines = []
    for score, item in matches[:10]:
        tags = ", ".join(item.get("tags", [])) if item.get("tags") else "none"
        lines.append(f"- [{item['id']}] {item['topic']} (tags: {tags})\n  {item['summary']}")
    return "\n".join(lines)


def list_topics() -> str:
    index = _load_index()
    if not index:
        return "knowledge base is empty"

    by_tag: dict[str, list[str]] = {}
    untagged = []
    for item in index:
        tags = item.get("tags", [])
        if not tags:
            untagged.append(item["topic"])
        for tag in tags:
            by_tag.setdefault(tag, []).append(item["topic"])

    lines = []
    for tag in sorted(by_tag):
        lines.append(f"[{tag}]")
        for topic in by_tag[tag]:
            lines.append(f"  - {topic}")
    if untagged:
        lines.append("[untagged]")
        for topic in untagged:
            lines.append(f"  - {topic}")
    lines.append(f"\nTotal: {len(index)} entries")
    return "\n".join(lines)


def update(entry_id: str, content: str) -> str:
    path = os.path.join(KNOWLEDGE_DIR, f"{entry_id}.json")
    if not os.path.exists(path):
        return f"[no entry with id '{entry_id}']"
    with open(path) as f:
        entry = json.load(f)
    entry["content"] = content
    entry["updated"] = time.time()
    with open(path, "w") as f:
        json.dump(entry, f, indent=2)

    index = _load_index()
    for item in index:
        if item["id"] == entry_id:
            item["summary"] = content[:100]
    _save_index(index)

    return f"knowledge updated: '{entry['topic']}'"


def _slugify(text: str) -> str:
    return "".join(c if c.isalnum() else "_" for c in text.lower())[:40]


def _load_index() -> list[dict]:
    if not os.path.exists(INDEX_FILE):
        return []
    try:
        with open(INDEX_FILE) as f:
            return json.loads(f.read())
    except Exception:
        return []


def _save_index(index: list[dict]):
    with open(INDEX_FILE, "w") as f:
        f.write(json.dumps(index, indent=2))
