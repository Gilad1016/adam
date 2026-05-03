# LLM Gateway — design

**Date:** 2026-05-03
**Status:** approved
**Replaces:** the current `observer/` Phoenix app and the `Adam.Observer` JSONL event emitter

## Goal

A small, independent Phoenix service that sits between ADAM and Ollama as a transparent reverse proxy. It logs every chat-completion call (request + response) to SQLite and serves a debug UI listing those calls. ADAM has no awareness of it — failure modes are identical to "Ollama is unreachable".

The current observer (granular event stream tailed from a shared JSONL file, parsed and rendered piecemeal) is removed entirely. We start lean: one row per LLM call, one list view.

## Non-goals (for v1)

- Tags, annotations, evaluations, training-data export
- Full-text search
- Replay / re-run
- Streaming response logging (pass-through only)
- Postgres, retention policies, rollups
- Cost / tier / valence inference (we keep raw JSON; derive later)

## Architecture

```
ADAM ── POST /api/chat ──► gateway ── POST /api/chat ──► Ollama
                              │
                              ├── writes 1 row to SQLite (async, after response sent)
                              └── serves LiveView /  (list of calls)
```

- **One service** named `gateway`, app `:llm_gateway`, lives in `gateway/` (the existing `observer/` directory is removed).
- ADAM's only change is the `OLLAMA_URL` env var, which now points at the gateway. No Elixir code changes inside ADAM beyond deleting `lib/adam/observer.ex` and its callsites.
- Gateway is a transparent reverse proxy for **any** Ollama path/method. It logs **only** `POST /api/chat`; everything else (e.g. `/api/pull`, `/api/tags`) passes through unlogged.
- Failure semantics:
  - Ollama errors → returned to ADAM verbatim and logged with the error status.
  - Gateway down → ADAM gets a connect error. Identical UX to Ollama being down. No fallback. Docker `restart: unless-stopped` covers flaps.
  - SQLite write fails → logged to stderr; the proxy response is unaffected.

## Components

Inside `gateway/lib/`:

- `LlmGateway.Application` — supervises Repo + Endpoint.
- `LlmGateway.Repo` — Ecto repo over SQLite (`ecto_sqlite3`).
- `LlmGateway.Calls` — schema + context (`list/1`, `get/1`, `insert_async/1`).
- `LlmGateway.Proxy` — Plug that forwards request to Ollama using `Req` and writes status/headers/body back. ~40 lines.
- `LlmGateway.ChatLogger` — Plug pipeline-stage that wraps Proxy on `POST /api/chat`: buffers request body, calls Proxy, buffers response body, then `Task.start`s the DB insert. Errors in the logger never block the response.
- `LlmGatewayWeb.Endpoint`, `Router`, `Layouts`.
- `LlmGatewayWeb.CallsLive` — LiveView at `/`. Newest-first list of calls (50/page). Each row collapses; clicking expands to show pretty-printed request and response JSON.
- `LlmGatewayWeb.ApiPipeline` — router scope with raw-body reader (no JSON parser) so the proxy gets the unmodified request body.

**Deps:** `phoenix ~> 1.7`, `phoenix_live_view ~> 1.0`, `phoenix_html ~> 4.0`, `ecto_sqlite3 ~> 0.17`, `req ~> 0.5`, `jason ~> 1.4`, `bandit ~> 1.5`. (No esbuild/tailwind toolchain — minimal inline CSS.)

## Data flow (POST /api/chat)

1. ADAM sends `POST http://gateway:4000/api/chat` with body `{model, messages, tools?, stream: false}`.
2. Router routes to `ChatLogger`. Raw body is read via `Plug.Conn.read_body/2` (no parser in the pipeline) and stored on `conn.assigns`.
3. `t0 = monotonic_time(:millisecond)`. Gateway issues `Req.post(ollama_url <> "/api/chat", body: <raw>, headers: <forwarded>, receive_timeout: 120_000)`.
4. On response: `t1`, capture status + headers + body.
5. Send response to ADAM (status, body verbatim; strip hop-by-hop headers).
6. After `send_resp`: `Task.start(fn -> Calls.insert(...) end)` — request never blocks on the DB.

If `stream: true` is detected in the request body, log a single row marking `stream: true` with empty `response` (response body not buffered) and pass through. ADAM doesn't use this today; it's a safety net.

## Schema

Migration `20260503000000_create_calls.exs`:

| column            | type                       | notes                                              |
|-------------------|----------------------------|----------------------------------------------------|
| `id`              | integer pk                 | autoincrement                                      |
| `request_id`      | text not null unique       | UUIDv4 generated at insert                         |
| `inserted_at`     | utc_datetime_usec not null | when the request was received                      |
| `model`           | text                       | parsed from request body, null if unparseable     |
| `request`         | text not null              | full request body as received                      |
| `response`        | text                       | full response body, null if upstream errored hard |
| `status`          | integer not null           | HTTP status returned to ADAM                       |
| `duration_ms`     | integer not null           | t1 − t0 (upstream call only)                       |
| `error`           | text                       | transport error message if proxying failed         |
| `prompt_tokens`   | integer                    | from `prompt_eval_count`, null if absent           |
| `completion_tokens` | integer                  | from `eval_count`, null if absent                  |
| `tool_call_count` | integer                    | length of `message.tool_calls`                     |
| `stream`          | boolean not null default 0 | request had `stream: true`                         |

Indexes: `inserted_at desc`, `request_id` unique.

Volume: `gateway_data:/app/data`. SQLite file at `/app/data/calls.db`.

## UI

`GET /` — LiveView.

- Auto-refreshes via `Phoenix.PubSub` broadcast from `Calls.insert/1`. New rows appear at the top live.
- Columns: time (relative), model, status, duration, prompt+completion tokens, tool count, first ~80 chars of last user message.
- Click a row → expands inline to show pretty-printed JSON of `request` and `response`, plus `error` if present.
- Pagination: simple `?page=N`, 50 rows per page.

No auth. Bound to localhost via Docker port mapping.

## docker-compose changes

- Replace `observer:` service with `gateway:` (build context `./gateway`, port `4000:4000`, volume `gateway_data:/app/data`).
- Remove `observer_data` volume.
- ADAM service env: change `OLLAMA_URL` from `http://ollama:11434` to `http://gateway:4000`. Remove `ADAM_OBSERVER_MODE` and `OBSERVER_EVENTS_FILE` env. Remove `observer_data` mount.
- Gateway service env: `OLLAMA_URL=http://ollama:11434`, `DATABASE_PATH=/app/data/calls.db`, `PORT=4000`, `MIX_ENV=dev` (local-only service; matches the original observer's pattern and avoids the prod-mode `SECRET_KEY_BASE` requirement).
- Gateway depends on `ollama` (healthy). ADAM depends on `gateway` (started). The chain: `ollama → ollama-init → gateway → adam`.

## ADAM-side changes

- Delete `lib/adam/observer.ex`.
- Delete all `Adam.Observer.*` calls from `lib/adam/loop.ex` (lines 65, 67, 79, 94, 102, 193).
- No changes to `lib/adam/llm.ex` — it already reads `OLLAMA_URL` from env.
- `.env.example`: drop `ADAM_OBSERVER_MODE`.

## Extensibility

The base table is intentionally small but stores the raw `request` and `response` blobs unmodified. Future additions (tags, evaluations, replays, training-data exports) are pure additions:

- New tables join on `calls.request_id`.
- New derived columns are added via `alter table` migrations and backfilled from the JSON.
- SQLite's `json_extract` covers ad-hoc analytics without a schema change.

Ecto migrations are used from commit one so schema evolution stays clean.

## Testing strategy

Manual end-to-end: `docker compose up`, send ADAM an email goal, watch `http://localhost:4000/` populate. No automated test suite in v1 (matches the rest of the project). A future iteration can add `Calls` context tests once the schema starts being relied on by other features.

## Out-of-band

The existing `Adam.Observer` was reading section names like `INTERRUPTS`, `GOALS`, `AVAILABLE TOOLS` out of the rendered context string. That parsing logic dies with the module. If we want section-aware analytics later, we derive it from the stored `request` JSON in the gateway, not by re-parsing strings inside ADAM.
