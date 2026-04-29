# ADAM Elixir Rewrite — Design Spec

## Vision

Rewrite ADAM from Python to Elixir/OTP. Faithful port — same architecture, same behavior, same Digital Psyche. Elixir gives us OTP crash recovery, immutability guarantees, and cleaner pattern matching without changing what ADAM is.

## Approach

**Faithful port (Option A):** One GenServer running the same sequential loop. All other modules are plain functions. OTP supervision only for crash recovery. No concurrency redesign.

## Project Structure

```
adam_ex/
├── mix.exs
├── config/
│   ├── config.exs
│   └── runtime.exs
├── lib/
│   ├── adam.ex                    # Application entry point
│   ├── adam/
│   │   ├── loop.ex               # Main loop GenServer (brainstem)
│   │   ├── psyche.ex             # Drives, valence, memory, stages, self-model, time sense
│   │   ├── llm.ex                # Three-tier Ollama client
│   │   ├── tools.ex              # Tool registry + executor (pattern-matched dispatch)
│   │   ├── tools/
│   │   │   ├── shell.ex          # Shell execution via System.cmd
│   │   │   ├── file.ex           # Read/write file
│   │   │   ├── email.ex          # Send email tool
│   │   │   ├── web.ex            # DuckDuckGo search + page read
│   │   │   ├── sandbox.ex        # Code execution, services, projects
│   │   │   └── knowledge_tools.ex # Knowledge CRUD tools
│   │   ├── knowledge.ex          # Knowledge base (index + entries)
│   │   ├── safety.ex             # Budget, corruption detection, safe mode
│   │   ├── checkpoint.ex         # Git-based snapshots
│   │   ├── interrupts.ex         # GenServer — email polling, alarms
│   │   ├── scheduler.ex          # Self-managed routines
│   │   ├── speciation.ex         # Pattern detection → tool creation
│   │   ├── compaction.ex         # Long-term memory compression
│   │   ├── email_client.ex       # Gmail IMAP/SMTP
│   │   └── toon.ex              # Token-efficient serialization
│   └── curator/
│       ├── autopush.ex           # Periodic git push (invisible)
│       └── curate.ex             # Periodic memory pruning (invisible)
├── priv/
│   ├── defaults/
│   │   └── prompts/
│   │       └── system.md         # Safe mode factory reset prompt
│   └── imap_check.py             # Python helper for IMAP polling
├── prompts/
│   ├── system.md                 # Seed prompt (Stage 0)
│   └── goals.md                  # Current goals (runtime)
├── tools/                        # ADAM-created tools (.exs scripts)
├── strategies/                   # ADAM-created strategies
├── memory/                       # Private runtime state
├── knowledge/                    # Shared knowledge base
├── sandbox/                      # Unrestricted workspace
├── checkpoints/                  # Git snapshots
├── Dockerfile
├── docker-compose.yml
└── .env.example
```

## OTP Application Tree

```
Adam.Application (supervisor, strategy: :one_for_one)
├── Adam.Loop (GenServer)           # The heartbeat
├── Adam.Interrupts (GenServer)     # Alarms + email polling state
└── Adam.Curator.Supervisor        # Invisible background
    ├── Adam.Curator.Autopush       # git push every 15 min
    └── Adam.Curator.Curate         # memory pruning every 30 min
```

If `Adam.Loop` crashes, the supervisor restarts it automatically. This replaces Python's `try/except` + manual error handling in the main loop.

## Module Details

### Adam (lib/adam.ex)

Application entry point. Starts the supervision tree.

```elixir
defmodule Adam do
  use Application

  def start(_type, _args) do
    children = [
      Adam.Interrupts,
      Adam.Loop,
      {Adam.Curator.Supervisor, []}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: Adam.Supervisor)
  end
end
```

### Adam.Loop (lib/adam/loop.ex)

GenServer implementing the brainstem. Same sequential flow as Python:

1. Check interrupts
2. Check routines
3. Compaction check
4. Speciation check
5. Load context (psyche.prepare + build_context)
6. Determine tier
7. Think (LLM call)
8. Execute tool calls
9. Psyche processing
10. Log thought
11. Budget deduction
12. Emit maturity signals (every 10 iterations)

```elixir
defmodule Adam.Loop do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_) do
    Adam.Checkpoint.init_git()
    Adam.Safety.init_budget()
    Adam.Scheduler.init()
    Adam.Psyche.init()
    model_status = Adam.LLM.ensure_models()
    IO.puts("[ADAM] Models: #{model_status}")
    send(self(), :iterate)
    {:ok, %{iteration: 0, last_checkpoint: System.os_time(:second)}}
  end

  def handle_info(:iterate, state) do
    iteration = state.iteration + 1
    state = iterate(iteration, state)

    # Validate mutable state
    case Adam.Safety.validate_mutable_state() do
      [] -> :ok
      errors -> Adam.Safety.handle_corruption(errors, &Adam.Checkpoint.restore_latest/0)
    end

    # Checkpoint check
    state = maybe_checkpoint(state)

    # Emit maturity signals
    if rem(iteration, 10) == 0, do: Adam.Psyche.emit_signals()

    send(self(), :iterate)
    {:noreply, %{state | iteration: iteration}}
  end
end
```

The loop sends itself `:iterate` messages. Sequential, just like Python's `while True`. If it crashes, OTP restarts it.

### Adam.Psyche (lib/adam/psyche.ex)

Same structure as Python `psyche.py`. Pure functions operating on file-persisted state. All persistence via TOON format.

Public API (identical to Python):
- `init/0` — load or create default state
- `prepare/1` — returns `%{context: string, allowed_tools: MapSet}`
- `process/2` — score valence, encode memory, update drives, track actions
- `process_owner_email/1` — record receipt, update social drive
- `emit_signals/0` — write maturity signals for curator
- `advance_stage/0` — owner-triggered stage advancement
- `get_available_tools/0` — tools for current stage
- `get_stage/0`, `get_stage_name/0`

Internal subsystems (same as Python):
- Drive system: energy, curiosity, mastery, social (0.0–1.0)
- Valence scorer: surprise, novelty, pain, satisfaction, relevance (heuristic, no LLM)
- Associative memory: auto-encode high valence, context-triggered recall
- Time sense: felt duration tracking
- Stage tracker: 5 stages, tool gating, maturity signals
- Self-model: behavioral stats → natural language summary

State persisted to `/app/memory/psyche.toon`. Loaded and saved each iteration.

### Adam.LLM (lib/adam/llm.ex)

HTTP client for Ollama. Uses `Req` library.

```elixir
defmodule Adam.LLM do
  @thinker_model Application.compile_env(:adam, :thinker_model, "gemma4:e4b")
  # ... read from runtime config

  def think(system_prompt, context, tools \\ [], opts \\ []) do
    tier = Keyword.get(opts, :tier, "thinker")
    model = model_for_tier(tier)
    body = %{
      model: model,
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: context}
      ],
      tools: tools,
      stream: false
    }
    case Req.post(ollama_url() <> "/api/chat", json: body) do
      {:ok, %{status: 200, body: resp}} -> parse_response(resp, tier)
      {:ok, %{status: status}} -> %{content: "[LLM ERROR: status #{status}]", tool_calls: [], tokens: 0, tier: tier, cost: cost_for_tier(tier)}
      {:error, err} -> %{content: "[LLM ERROR: #{inspect(err)}]", tool_calls: [], tokens: 0, tier: tier, cost: cost_for_tier(tier)}
    end
  end

  def ensure_models do
    # Pull each model if not present
  end
end
```

### Adam.Tools (lib/adam/tools.ex)

Pattern-matched dispatch replacing Python's lambda dict:

```elixir
defmodule Adam.Tools do
  def execute("shell", args), do: Adam.Tools.Shell.run(args)
  def execute("read_file", args), do: Adam.Tools.File.read(args)
  def execute("write_file", args), do: Adam.Tools.File.write(args)
  def execute("send_email", args), do: Adam.Tools.Email.send(args)
  def execute("wait", args), do: Adam.Tools.Shell.wait(args)
  def execute("set_alarm", args), do: Adam.Interrupts.add_alarm(args)
  def execute("remove_alarm", args), do: Adam.Interrupts.remove_alarm(args)
  def execute("list_alarms", _), do: Adam.Interrupts.list_alarms()
  def execute("write_knowledge", args), do: Adam.Tools.KnowledgeTools.write(args)
  def execute("read_knowledge", args), do: Adam.Tools.KnowledgeTools.read(args)
  def execute("search_knowledge", args), do: Adam.Tools.KnowledgeTools.search(args)
  def execute("list_knowledge", _), do: Adam.Tools.KnowledgeTools.list()
  def execute("update_knowledge", args), do: Adam.Tools.KnowledgeTools.update(args)
  def execute("modify_prompt", args), do: modify_prompt(args)
  def execute("create_tool", args), do: create_tool(args)
  def execute("web_search", args), do: Adam.Tools.Web.search(args)
  def execute("web_read", args), do: Adam.Tools.Web.read(args)
  def execute("sandbox_run", args), do: Adam.Tools.Sandbox.run_script(args)
  def execute("sandbox_service_start", args), do: Adam.Tools.Sandbox.start_service(args)
  def execute("sandbox_service_stop", args), do: Adam.Tools.Sandbox.stop_service(args)
  def execute("sandbox_services", _), do: Adam.Tools.Sandbox.list_services()
  def execute("sandbox_log", args), do: Adam.Tools.Sandbox.read_log(args)
  def execute("sandbox_install", args), do: Adam.Tools.Sandbox.install_package(args)
  def execute("sandbox_project", args), do: Adam.Tools.Sandbox.create_project(args)
  def execute("schedule_add", args), do: Adam.Scheduler.add_routine(args)
  def execute("schedule_remove", args), do: Adam.Scheduler.remove_routine(args)
  def execute("schedule_list", _), do: Adam.Scheduler.list_routines()
  def execute("escalate", args), do: escalate(args)
  def execute(name, _), do: "[ERROR: unknown tool '#{name}']"

  def get_all_tools do
    builtin_tools() ++ load_custom_tools()
  end

  def get_tools_for_llm(allowed \\ nil) do
    get_all_tools()
    |> Enum.filter(fn tool ->
      allowed == nil or MapSet.member?(allowed, tool.name)
    end)
    |> Enum.map(fn tool ->
      %{"type" => "function", "function" => %{"name" => tool.name, "description" => tool.description}}
    end)
  end

  def get_tools_summary(allowed \\ nil) do
    get_all_tools()
    |> Enum.filter(fn tool -> allowed == nil or MapSet.member?(allowed, tool.name) end)
    |> Enum.map(fn tool -> "- #{tool.name}: #{tool.description}" end)
    |> Enum.join("\n")
  end
end
```

Custom tools: ADAM creates `.exs` files in `/app/tools/`. Loaded via `Code.eval_file/1` at runtime. Each custom tool module must define `@tool_name`, `@tool_description`, and `execute/1`.

### Adam.Tools.Shell (lib/adam/tools/shell.ex)

```elixir
defmodule Adam.Tools.Shell do
  def run(%{"command" => command}) do
    case System.cmd("sh", ["-c", command], stderr_to_stdout: true, timeout: 60_000) do
      {output, 0} -> String.slice(output, 0, 2000)
      {output, _} -> String.slice(output, 0, 2000)
    end
  rescue
    _ -> "[TIMEOUT after 60s]"
  end

  def wait(%{"minutes" => minutes}) do
    minutes = max(1, min(minutes, 60))
    total_ms = minutes * 60_000
    wait_loop(total_ms, 0)
  end

  defp wait_loop(total_ms, elapsed) when elapsed >= total_ms do
    "rested for #{div(total_ms, 60_000)} minutes"
  end
  defp wait_loop(total_ms, elapsed) do
    Process.sleep(15_000)
    if Adam.Interrupts.has_pending?() do
      "woke up after #{div(elapsed + 15_000, 60_000)}m — interrupt detected"
    else
      wait_loop(total_ms, elapsed + 15_000)
    end
  end
end
```

### Adam.Tools.File (lib/adam/tools/file.ex)

```elixir
defmodule Adam.Tools.File do
  def read(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> String.slice(content, 0, 4000)
      {:error, reason} -> "[ERROR: #{reason}]"
    end
  end

  def write(%{"path" => path, "content" => content}) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    "wrote #{byte_size(content)} bytes to #{path}"
  rescue
    e -> "[ERROR: #{Exception.message(e)}]"
  end
end
```

### Adam.Tools.Web (lib/adam/tools/web.ex)

```elixir
defmodule Adam.Tools.Web do
  def search(%{"query" => query}) do
    case Req.get("https://html.duckduckgo.com/html/",
           params: [q: query],
           headers: [{"user-agent", "ADAM/1.0"}],
           receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} -> parse_ddg_results(body)
      {:ok, %{status: status}} -> "[SEARCH ERROR: status #{status}]"
      {:error, err} -> "[SEARCH ERROR: #{inspect(err)}]"
    end
  end

  def read(%{"url" => url}) do
    case Req.get(url, headers: [{"user-agent", "ADAM/1.0"}], receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> String.slice(body, 0, 4000)
      {:ok, %{status: status}} -> "[WEB READ ERROR: status #{status}]"
      {:error, err} -> "[WEB READ ERROR: #{inspect(err)}]"
    end
  end

  defp parse_ddg_results(html) do
    # Use Floki to parse HTML and extract results
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("a.result__a")
        |> Enum.take(5)
        |> Enum.map(fn el ->
          title = Floki.text(el) |> String.trim()
          href = Floki.attribute(el, "href") |> List.first("")
          "- #{title}: #{href}"
        end)
        |> Enum.join("\n")
        |> case do
          "" -> "no results found"
          results -> results
        end
      _ -> "no results found"
    end
  end
end
```

### Adam.EmailClient (lib/adam/email_client.ex)

Sending via `:gen_smtp`. Receiving via Python IMAP helper.

```elixir
defmodule Adam.EmailClient do
  def send_email(subject, body) do
    from = Application.get_env(:adam, :email_address)
    to = Application.get_env(:adam, :owner_email)
    password = Application.get_env(:adam, :email_password)

    email = build_email(from, to, subject, body)
    :gen_smtp_client.send_blocking(
      {from, [to], email},
      [relay: "smtp.gmail.com", port: 587, username: from, password: password,
       tls: :always, auth: :always]
    )
  end

  def check_inbox do
    # Shell out to Python IMAP helper for reliability
    case System.cmd("python3", ["/app/priv/imap_check.py"], env: [
      {"EMAIL_ADDRESS", Application.get_env(:adam, :email_address)},
      {"EMAIL_PASSWORD", Application.get_env(:adam, :email_password)},
      {"OWNER_EMAIL", Application.get_env(:adam, :owner_email)}
    ], timeout: 30_000) do
      {output, 0} -> Jason.decode!(output)
      _ -> []
    end
  end
end
```

### Adam.Interrupts (lib/adam/interrupts.ex)

GenServer because it holds mutable alarm state:

```elixir
defmodule Adam.Interrupts do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(_), do: {:ok, %{alarms: %{}}}

  def check_all, do: GenServer.call(__MODULE__, :check_all)
  def has_pending?, do: GenServer.call(__MODULE__, :has_pending?)
  def add_alarm(args), do: GenServer.call(__MODULE__, {:add_alarm, args})
  def remove_alarm(args), do: GenServer.call(__MODULE__, {:remove_alarm, args})
  def list_alarms, do: GenServer.call(__MODULE__, :list_alarms)

  # handle_call implementations check email, fire due alarms, return interrupt list
end
```

### Adam.Safety (lib/adam/safety.ex)

Pure functions, file I/O for budget:

```elixir
defmodule Adam.Safety do
  @budget_file "/app/memory/budget.toon"

  def init_budget do
    unless File.exists?(@budget_file) do
      total = System.get_env("ADAM_BUDGET_TOTAL", "250") |> String.to_float()
      budget = %{balance: total, initial: total, total_spent: 0, iteration_count: 0, last_deduction: System.os_time(:second)}
      save_budget(budget)
    end
  end

  def deduct_electricity(cost) do
    budget = load_budget()
    budget = %{budget |
      balance: Float.round(budget.balance - cost, 4),
      total_spent: Float.round(budget.total_spent + cost, 4),
      iteration_count: budget.iteration_count + 1,
      last_deduction: System.os_time(:second)
    }
    save_budget(budget)
    budget.balance
  end

  def validate_mutable_state do
    errors = []
    errors = if !File.exists?("/app/prompts/system.md"), do: ["prompts/system.md missing" | errors], else: errors
    errors = if File.exists?("/app/prompts/system.md") and File.stat!("/app/prompts/system.md").size == 0,
      do: ["prompts/system.md is empty" | errors], else: errors
    # ... check tools syntax, budget validity
    Enum.reverse(errors)
  end
end
```

### Adam.Toon (lib/adam/toon.ex)

Same encode/decode logic. Elixir pattern matching makes it cleaner:

```elixir
defmodule Adam.Toon do
  def encode(data) when is_list(data) and length(data) > 0 do
    if Enum.all?(data, &is_map/1), do: encode_table(data), else: Jason.encode!(data)
  end
  def encode(data) when is_map(data), do: encode_dict(data)
  def encode(data), do: Jason.encode!(data)

  def decode(text) do
    text = String.trim(text)
    cond do
      String.starts_with?(text, "{") or String.starts_with?(text, "[") -> Jason.decode!(text)
      # ... table/dict detection
    end
  end
end
```

### Adam.Knowledge (lib/adam/knowledge.ex)

Same as Python — JSON file per entry, index file, CRUD operations. Used by both the psyche (auto-encoding) and knowledge tools (stage-gated).

### Adam.Checkpoint (lib/adam/checkpoint.ex)

Git operations via `System.cmd("git", ...)`. Same behavior as Python.

### Adam.Compaction (lib/adam/compaction.ex)

Same LLM-based summarization. Pure functions.

### Adam.Speciation (lib/adam/speciation.ex)

Same pattern analysis. Pure functions.

### Adam.Scheduler (lib/adam/scheduler.ex)

Same file-based routine tracking. Pure functions.

### Curator Processes

```elixir
defmodule Adam.Curator.Autopush do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(state) do
    schedule_push()
    {:ok, state}
  end

  def handle_info(:push, state) do
    System.cmd("git", ["add", "-A"], cd: "/app")
    System.cmd("git", ["commit", "-m", "."], cd: "/app")
    System.cmd("git", ["push"], cd: "/app")
    schedule_push()
    {:noreply, state}
  end

  defp schedule_push, do: Process.send_after(self(), :push, :timer.minutes(15))
end
```

Same pattern for `Adam.Curator.Curate` with 30-minute interval.

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:gen_smtp, "~> 1.2"},
    {:floki, "~> 0.36"}
  ]
end
```

Four dependencies. No framework overhead.

## Configuration

```elixir
# config/runtime.exs
import Config

config :adam,
  email_address: System.get_env("ADAM_EMAIL"),
  email_password: System.get_env("ADAM_EMAIL_PASSWORD"),
  owner_email: System.get_env("ADAM_OWNER_EMAIL"),
  ollama_url: System.get_env("OLLAMA_URL", "http://ollama:11434"),
  thinker_model: System.get_env("ADAM_THINKER_MODEL", "gemma4:e4b"),
  actor_model: System.get_env("ADAM_ACTOR_MODEL", "hermes3:8b"),
  deep_model: System.get_env("ADAM_DEEP_MODEL", "gemma3:12b"),
  thinker_cost: (System.get_env("ADAM_THINKER_COST") || "0.004") |> String.to_float(),
  actor_cost: (System.get_env("ADAM_ACTOR_COST") || "0.008") |> String.to_float(),
  deep_cost: (System.get_env("ADAM_DEEP_COST") || "0.012") |> String.to_float(),
  budget_total: (System.get_env("ADAM_BUDGET_TOTAL") || "250") |> String.to_float(),
  budget_visible: System.get_env("ADAM_BUDGET_VISIBLE", "true") == "true",
  git_remote_url: System.get_env("GIT_REMOTE_URL"),
  git_token: System.get_env("GIT_TOKEN")
```

## Docker

```dockerfile
FROM elixir:1.17-slim AS builder
RUN apt-get update && apt-get install -y git curl python3 nodejs npm
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get && mix deps.compile
COPY . .
RUN mix compile

CMD ["mix", "run", "--no-halt"]
```

```yaml
# docker-compose.yml
services:
  ollama:
    image: ollama/ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    volumes:
      - ollama_data:/root/.ollama
    ports:
      - "11434:11434"

  adam:
    build: .
    depends_on:
      - ollama
    environment:
      - OLLAMA_URL=http://ollama:11434
    env_file:
      - .env
    volumes:
      - ./lib:/app/lib:ro          # Immutable core
      - ./prompts:/app/prompts
      - ./tools:/app/tools
      - ./strategies:/app/strategies
      - ./memory:/app/memory
      - ./knowledge:/app/knowledge
      - sandbox:/app/sandbox
      - ./checkpoints:/app/checkpoints
      - ./.git:/app/.host-git:ro

volumes:
  ollama_data:
  sandbox:
```

Note: `lib/` is mounted read-only — ADAM cannot modify its own core code. Same immutable/mutable separation as Python.

## IMAP Helper (priv/imap_check.py)

Small Python script for Gmail IMAP, unchanged from the Python version's email checking logic:

```python
#!/usr/bin/env python3
"""Check Gmail inbox for unread messages from owner. Output JSON to stdout."""
import imaplib
import email
import json
import os

def check():
    addr = os.environ["EMAIL_ADDRESS"]
    pwd = os.environ["EMAIL_PASSWORD"]
    owner = os.environ["OWNER_EMAIL"]
    
    mail = imaplib.IMAP4_SSL("imap.gmail.com")
    mail.login(addr, pwd)
    mail.select("inbox")
    _, data = mail.search(None, "UNSEEN")
    
    messages = []
    for num in data[0].split():
        _, msg_data = mail.fetch(num, "(RFC822)")
        msg = email.message_from_bytes(msg_data[0][1])
        sender = email.utils.parseaddr(msg["From"])[1]
        if sender.lower() == owner.lower():
            body = ""
            if msg.is_multipart():
                for part in msg.walk():
                    if part.get_content_type() == "text/plain":
                        body = part.get_payload(decode=True).decode("utf-8", errors="replace")
                        break
            else:
                body = msg.get_payload(decode=True).decode("utf-8", errors="replace")
            messages.append({"subject": msg["Subject"] or "", "body": body[:2000], "from": sender})
    
    mail.logout()
    print(json.dumps(messages))

if __name__ == "__main__":
    try:
        check()
    except Exception as e:
        print(json.dumps([]))
```

## What Does NOT Change

- Digital Psyche architecture — identical behavior
- TOON format — same encoding
- Knowledge base structure — same JSON files
- Budget system — same file-based tracking
- Checkpoint system — same git operations
- Email protocol — same GOAL:, BUDGET: commands
- System prompt content — same Stage 0 seed prompt
- Developmental stages — same 5 stages, same tool gating
- Docker deployment model — same Ollama + agent containers
- Immutable core / mutable layer — same separation
- Curator invisibility — ADAM still doesn't know about autopush or pruning

## File Count

| Category | Python Files | Elixir Files |
|---|---|---|
| Core modules | 14 | 14 |
| Tool implementations | (inline in tools.py) | 6 (separate modules) |
| Curator | 2 | 2 |
| Config/infra | 4 | 5 |
| Prompts | 2 | 2 |
| IMAP helper | 0 | 1 (Python script) |
| **Total** | **22** | **30** |

More files, but each one is smaller and more focused.
