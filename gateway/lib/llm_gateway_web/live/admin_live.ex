defmodule LlmGatewayWeb.AdminLive do
  use LlmGatewayWeb, :live_view

  alias LlmGateway.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:flash_msg, nil)
     |> assign(:flash_kind, :ok)
     |> assign(:confirm_action, nil)
     |> load_state()}
  end

  defp load_state(socket) do
    socket
    |> assign(:env_entries, Admin.read_env())
    |> assign(:system_prompt, read_prompt_or_empty("system"))
    |> assign(:goals_prompt, read_prompt_or_empty("goals"))
    |> assign(:tuning_knobs, Admin.tuning_knobs())
    |> assign(:tuning_overrides, Admin.tuning_overrides())
    |> assign(:tuning_history, Admin.tuning_history())
    |> assign(:narrative, Admin.narrative())
    |> assign(:narrative_rejections, Admin.narrative_rejections())
  end

  defp read_prompt_or_empty(name) do
    case Admin.read_prompt(name) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  @impl true
  def handle_event("save_env", %{"key" => key, "value" => value}, socket) do
    case Admin.update_env_value(key, value) do
      :ok -> {:noreply, socket |> flash_ok("saved #{key}") |> load_state()}
      {:error, reason} -> {:noreply, flash_err(socket, "failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("save_prompt", %{"name" => name, "content" => content}, socket)
      when name in ["system", "goals"] do
    case Admin.write_prompt(name, content) do
      :ok -> {:noreply, socket |> flash_ok("saved #{name}.md") |> load_state()}
      {:error, reason} -> {:noreply, flash_err(socket, "failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("wipe_memory", %{"confirm" => "DELETE"}, socket) do
    {:noreply, run_wipe(socket, &Admin.wipe_memory/0, "memory")}
  end

  @impl true
  def handle_event("wipe_knowledge", %{"confirm" => "DELETE"}, socket) do
    {:noreply, run_wipe(socket, &Admin.wipe_knowledge/0, "knowledge")}
  end

  @impl true
  def handle_event("wipe_checkpoints", %{"confirm" => "DELETE"}, socket) do
    {:noreply, run_wipe(socket, &Admin.wipe_checkpoints/0, "checkpoints")}
  end

  @impl true
  def handle_event("wipe_calls", %{"confirm" => "DELETE"}, socket) do
    {:noreply, run_wipe(socket, &Admin.wipe_calls/0, "calls history")}
  end

  @impl true
  def handle_event("factory_reset", %{"confirm" => "RESET"}, socket) do
    try do
      Admin.factory_reset()
      {:noreply, socket |> flash_ok("factory reset complete") |> load_state()}
    rescue
      e -> {:noreply, flash_err(socket, "reset failed: #{Exception.message(e)}")}
    end
  end

  @impl true
  def handle_event(event, _params, socket)
      when event in ["wipe_memory", "wipe_knowledge", "wipe_checkpoints", "wipe_calls", "factory_reset"] do
    {:noreply, flash_err(socket, "confirmation phrase did not match — nothing was deleted")}
  end

  # ---- tuning ----

  @impl true
  def handle_event("save_tuning", %{"knob" => knob, "value" => raw, "reason" => reason}, socket) do
    case parse_number(raw) do
      {:ok, value} ->
        case Admin.tuning_set(knob, value, reason_or_default(reason, "operator")) do
          {:ok, _} -> {:noreply, socket |> flash_ok("saved #{knob} = #{value}") |> load_state()}
          {:error, reason} -> {:noreply, flash_err(socket, "save failed: #{format_tuning_error(reason)}")}
        end

      :error ->
        {:noreply, flash_err(socket, "invalid number: #{inspect(raw)}")}
    end
  end

  @impl true
  def handle_event("ask_restore", %{"knob" => knob}, socket) do
    {:noreply, assign(socket, :confirm_action, %{kind: :restore, knob: knob})}
  end

  @impl true
  def handle_event("ask_rollback", %{"idx" => idx}, socket) do
    case Integer.parse(to_string(idx)) do
      {i, ""} ->
        history = socket.assigns.tuning_history

        case Enum.at(history, i) do
          %{"name" => knob} = entry ->
            {:noreply,
             assign(socket, :confirm_action, %{
               kind: :rollback,
               history_idx: i,
               knob: knob,
               entry: entry
             })}

          _ ->
            {:noreply, flash_err(socket, "history entry not found")}
        end

      _ ->
        {:noreply, flash_err(socket, "bad history index")}
    end
  end

  @impl true
  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_action, nil)}
  end

  @impl true
  def handle_event("ignore_inner", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("run_confirm", _params, %{assigns: %{confirm_action: nil}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("run_confirm", _params, socket) do
    action = socket.assigns.confirm_action
    socket = assign(socket, :confirm_action, nil)
    {:noreply, dispatch_confirm(socket, action)}
  end

  defp dispatch_confirm(socket, %{kind: :restore, knob: knob}) do
    case Admin.tuning_restore_default(knob) do
      {:ok, value} -> socket |> flash_ok("restored #{knob} to default (#{value})") |> load_state()
      {:error, reason} -> flash_err(socket, "restore failed: #{format_tuning_error(reason)}")
    end
  end

  defp dispatch_confirm(socket, %{kind: :rollback, knob: knob}) do
    case Admin.tuning_rollback(knob, 1) do
      {:ok, value} -> socket |> flash_ok("rolled back #{knob} to #{inspect(value)}") |> load_state()
      {:error, reason} -> flash_err(socket, "rollback failed: #{format_tuning_error(reason)}")
    end
  end

  defp dispatch_confirm(socket, _), do: socket

  defp parse_number(raw) when is_binary(raw) do
    raw = String.trim(raw)

    case Integer.parse(raw) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(raw) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp parse_number(_), do: :error

  defp reason_or_default("", default), do: default
  defp reason_or_default(nil, default), do: default
  defp reason_or_default(reason, _), do: reason

  defp format_tuning_error(:unknown_knob), do: "unknown knob"
  defp format_tuning_error(:validator_required), do: "knob requires validation; only rollback/restore are allowed"
  defp format_tuning_error(:invalid_value), do: "invalid value"
  defp format_tuning_error(:no_history), do: "no history to roll back"
  defp format_tuning_error({:out_of_bounds, lo, hi}), do: "out of bounds (#{lo}..#{hi})"
  defp format_tuning_error(other), do: inspect(other)

  defp run_wipe(socket, fun, label) do
    try do
      case fun.() do
        :ok -> flash_ok(socket, "wiped #{label}")
        {:error, reason} -> flash_err(socket, "wipe failed: #{inspect(reason)}")
      end
    rescue
      e -> flash_err(socket, "wipe failed: #{Exception.message(e)}")
    end
  end

  defp flash_ok(socket, msg), do: socket |> assign(:flash_msg, msg) |> assign(:flash_kind, :ok)
  defp flash_err(socket, msg), do: socket |> assign(:flash_msg, msg) |> assign(:flash_kind, :err)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-gray-100">admin</h1>
        <p class="text-sm text-gray-500 mt-1">
          edit ADAM's env, prompts, and reset state. After saving env values or prompts, restart ADAM with
          <code class="text-cyan-400">docker compose restart adam</code> for changes to take effect.
        </p>
      </div>

      <%= if @flash_msg do %>
        <div class={"mb-4 p-3 rounded text-sm border " <> flash_classes(@flash_kind)}>
          <%= @flash_msg %>
        </div>
      <% end %>

      <h2 class="text-lg uppercase tracking-wider text-gray-400 mb-3 mt-2">narrative identity</h2>
      <div class="border border-gray-800 rounded p-3 mb-6">
        <%= if @narrative == "" do %>
          <p class="text-sm text-gray-500 italic">No narrative yet. ADAM will author one during a sleep cycle once it has at least 5 thoughts of experience.</p>
        <% else %>
          <p class="text-sm text-gray-200 whitespace-pre-wrap"><%= @narrative %></p>
        <% end %>
        <p class="text-xs text-gray-500 mt-2">Regenerated by ADAM during sleep cycles. Read-only here for now; review/approval workflow comes in a follow-up PR.</p>

        <%= if @narrative_rejections != [] do %>
          <div class="mt-4 border-t border-gray-800 pt-3">
            <h3 class="text-xs uppercase tracking-wider text-amber-400 mb-2">recent rejections (last <%= length(@narrative_rejections) %>)</h3>
            <p class="text-xs text-gray-500 mb-2">ADAM tried to update its narrative but the new version contradicted the kernel:</p>
            <div class="space-y-2">
              <%= for r <- Enum.take(@narrative_rejections, 5) do %>
                <details class="text-xs">
                  <summary class="cursor-pointer text-gray-400">
                    <%= r["ts_human"] || "(no timestamp)" %> — <%= r["reason"] |> String.slice(0, 80) %>...
                  </summary>
                  <div class="mt-2 ml-4 space-y-2">
                    <div>
                      <div class="text-gray-500 mb-1">Reason:</div>
                      <pre class="text-amber-200 whitespace-pre-wrap"><%= r["reason"] %></pre>
                    </div>
                    <div>
                      <div class="text-gray-500 mb-1">Rejected candidate:</div>
                      <pre class="text-gray-300 whitespace-pre-wrap"><%= r["candidate"] %></pre>
                    </div>
                  </div>
                </details>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <h2 class="text-lg uppercase tracking-wider text-gray-400 mb-3 mt-8">env</h2>
      <div class="space-y-2">
        <%= if @env_entries == [] do %>
          <div class="text-gray-500 text-sm italic p-6 border border-gray-800 rounded text-center">
            No .env file found at <code><%= LlmGateway.Admin.env_path() %></code>.
          </div>
        <% end %>
        <%= for entry <- @env_entries, entry.kind == :pair do %>
          <form phx-submit="save_env" class="border border-gray-800 rounded p-3 grid grid-cols-12 gap-2 items-center">
            <input type="hidden" name="key" value={entry.key} />
            <span class="col-span-3 text-cyan-400 text-sm font-mono truncate"><%= entry.key %></span>
            <input
              type="text"
              name="value"
              value={entry.value}
              class="col-span-7 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
            />
            <button
              type="submit"
              class="col-span-2 bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs px-3 py-1 rounded"
            >
              save
            </button>
          </form>
        <% end %>
      </div>

      <h2 class="text-lg uppercase tracking-wider text-gray-400 mb-3 mt-8">prompts</h2>
      <div class="space-y-4">
        <form phx-submit="save_prompt" class="border border-gray-800 rounded p-3">
          <input type="hidden" name="name" value="system" />
          <div class="text-sm text-gray-400 mb-2">prompts/system.md</div>
          <textarea
            name="content"
            rows="16"
            class="w-full bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          ><%= @system_prompt %></textarea>
          <div class="mt-2">
            <button type="submit" class="bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs px-3 py-1 rounded">
              save system.md
            </button>
          </div>
        </form>

        <form phx-submit="save_prompt" class="border border-gray-800 rounded p-3">
          <input type="hidden" name="name" value="goals" />
          <div class="text-sm text-gray-400 mb-2">prompts/goals.md</div>
          <textarea
            name="content"
            rows="16"
            class="w-full bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          ><%= @goals_prompt %></textarea>
          <div class="mt-2">
            <button type="submit" class="bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs px-3 py-1 rounded">
              save goals.md
            </button>
          </div>
        </form>
      </div>

      <h2 class="text-lg uppercase tracking-wider text-gray-400 mb-3 mt-8">data ops</h2>
      <p class="text-xs text-gray-500 mb-3">
        type <code class="text-cyan-400">DELETE</code> to wipe a directory, or
        <code class="text-cyan-400">RESET</code> to factory-reset. sandbox is a docker named volume — wipe it from the host with <code>docker volume rm adam_sandbox</code>.
      </p>
      <div class="space-y-2">
        <form phx-submit="wipe_memory" class="border border-gray-800 rounded p-3 grid grid-cols-12 gap-2 items-center">
          <span class="col-span-3 text-gray-200 text-sm">wipe memory/</span>
          <input
            type="text"
            name="confirm"
            placeholder="type DELETE"
            class="col-span-7 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          />
          <button type="submit" class="col-span-2 bg-red-800 hover:bg-red-700 text-white text-xs px-3 py-1 rounded">
            wipe
          </button>
        </form>

        <form phx-submit="wipe_knowledge" class="border border-gray-800 rounded p-3 grid grid-cols-12 gap-2 items-center">
          <span class="col-span-3 text-gray-200 text-sm">wipe knowledge/</span>
          <input
            type="text"
            name="confirm"
            placeholder="type DELETE"
            class="col-span-7 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          />
          <button type="submit" class="col-span-2 bg-red-800 hover:bg-red-700 text-white text-xs px-3 py-1 rounded">
            wipe
          </button>
        </form>

        <form phx-submit="wipe_checkpoints" class="border border-gray-800 rounded p-3 grid grid-cols-12 gap-2 items-center">
          <span class="col-span-3 text-gray-200 text-sm">wipe checkpoints/</span>
          <input
            type="text"
            name="confirm"
            placeholder="type DELETE"
            class="col-span-7 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          />
          <button type="submit" class="col-span-2 bg-red-800 hover:bg-red-700 text-white text-xs px-3 py-1 rounded">
            wipe
          </button>
        </form>

        <form phx-submit="wipe_calls" class="border border-gray-800 rounded p-3 grid grid-cols-12 gap-2 items-center">
          <span class="col-span-3 text-gray-200 text-sm">wipe calls history</span>
          <input
            type="text"
            name="confirm"
            placeholder="type DELETE"
            class="col-span-7 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          />
          <button type="submit" class="col-span-2 bg-red-800 hover:bg-red-700 text-white text-xs px-3 py-1 rounded">
            wipe
          </button>
        </form>

        <form phx-submit="factory_reset" class="border border-red-900 rounded p-3 grid grid-cols-12 gap-2 items-center bg-red-950/20">
          <span class="col-span-3 text-red-300 text-sm">factory reset</span>
          <input
            type="text"
            name="confirm"
            placeholder="type RESET to confirm"
            class="col-span-7 bg-gray-950 border border-red-900 rounded px-2 py-1 text-sm text-gray-200 font-mono"
          />
          <button type="submit" class="col-span-2 bg-red-700 hover:bg-red-600 text-white text-xs px-3 py-1 rounded">
            factory reset
          </button>
        </form>
        <p class="text-xs text-gray-500 mt-2">
          factory reset wipes memory/, knowledge/, checkpoints/, the gateway's calls history, and restores prompts from <code>priv/defaults/prompts/</code> if present. Restart ADAM afterward.
        </p>
      </div>

      <h2 class="text-lg uppercase tracking-wider text-gray-400 mb-3 mt-8">tuning</h2>
      <p class="text-xs text-gray-500 mb-3">
        runtime knobs read by ADAM on its next iteration. operator overrides bypass the agent's stability lock.
        validated knobs (e.g. composite vectors) are read-only here — only rollback or restore-to-default is allowed.
      </p>

      <%= if map_size(@tuning_knobs) == 0 do %>
        <div class="text-gray-500 text-sm italic p-6 border border-gray-800 rounded text-center">
          No tuning registry found at <code><%= LlmGateway.Admin.tuning_knobs_path() %></code>.
          Start ADAM at least once so it can dump the registry.
        </div>
      <% end %>

      <div class="space-y-3">
        <%= for {name, spec} <- Enum.sort_by(@tuning_knobs, fn {n, _} -> n end) do %>
          <% current = LlmGateway.Admin.tuning_value(name) %>
          <% overridden? = Map.has_key?(@tuning_overrides, name) %>
          <% last_change = last_change_for(@tuning_history, name) %>
          <% validator? = Map.get(spec, "validator_present", false) %>
          <div class="border border-gray-800 rounded p-3">
            <div class="flex items-baseline justify-between gap-3">
              <div class="text-cyan-400 text-sm font-mono"><%= name %></div>
              <div class="text-xs text-gray-500">
                <%= if validator? do %>
                  <span class="px-2 py-0.5 rounded bg-yellow-900/40 border border-yellow-800 text-yellow-300">validated</span>
                <% else %>
                  bounds: <%= Map.get(spec, "min") %> .. <%= Map.get(spec, "max") %>
                <% end %>
                · default: <%= inspect(Map.get(spec, "default")) %>
                · stability: <%= Map.get(spec, "stability_hours") %>h
              </div>
            </div>
            <div class="text-xs text-gray-400 mt-1"><%= Map.get(spec, "desc") %></div>
            <div class="text-sm text-gray-200 mt-2">
              current:
              <span class="font-mono text-gray-100"><%= inspect(current) %></span>
              <%= if overridden? do %>
                <span class="text-xs text-amber-400 ml-2">(override)</span>
              <% else %>
                <span class="text-xs text-gray-500 ml-2">(default)</span>
              <% end %>
            </div>

            <%= if validator? do %>
              <div class="mt-2 text-xs text-gray-500 italic">
                free-form edit disabled — use rollback or restore-default.
              </div>
              <div class="mt-2 flex gap-2">
                <button
                  type="button"
                  phx-click="ask_restore"
                  phx-value-knob={name}
                  class="bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs px-3 py-1 rounded"
                >
                  ↶ restore default
                </button>
              </div>
            <% else %>
              <form phx-submit="save_tuning" class="mt-2 grid grid-cols-12 gap-2 items-center">
                <input type="hidden" name="knob" value={name} />
                <input
                  type="text"
                  name="value"
                  value={to_string(current)}
                  class="col-span-3 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
                />
                <input
                  type="text"
                  name="reason"
                  placeholder="reason (optional)"
                  class="col-span-6 bg-gray-950 border border-gray-800 rounded px-2 py-1 text-sm text-gray-200 font-mono"
                />
                <button
                  type="submit"
                  class="col-span-1 bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs px-3 py-1 rounded"
                >
                  save
                </button>
                <button
                  type="button"
                  phx-click="ask_restore"
                  phx-value-knob={name}
                  class="col-span-2 bg-gray-800 hover:bg-gray-700 text-gray-200 text-xs px-2 py-1 rounded"
                >
                  ↶ default
                </button>
              </form>
            <% end %>

            <%= if last_change do %>
              <div class="text-xs text-gray-500 mt-2">
                last changed: <%= ago(last_change["ts"]) %> by <%= last_change["source"] %>
                — <span class="italic">"<%= last_change["reason"] %>"</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <h2 class="text-lg uppercase tracking-wider text-gray-400 mb-3 mt-8">tuning history (last 50)</h2>
      <%= if @tuning_history == [] do %>
        <div class="text-gray-500 text-sm italic p-6 border border-gray-800 rounded text-center">
          No tuning history yet.
        </div>
      <% else %>
        <div class="border border-gray-800 rounded overflow-hidden">
          <table class="w-full text-xs font-mono">
            <thead class="bg-gray-900 text-gray-400 uppercase">
              <tr>
                <th class="text-left px-3 py-2">time</th>
                <th class="text-left px-3 py-2">knob</th>
                <th class="text-left px-3 py-2">prev → value</th>
                <th class="text-left px-3 py-2">source</th>
                <th class="text-left px-3 py-2">reason</th>
                <th class="text-right px-3 py-2">actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for {entry, idx} <- last_history_with_idx(@tuning_history, 50) do %>
                <tr class="border-t border-gray-800 text-gray-200">
                  <td class="px-3 py-1.5 text-gray-400"><%= ago(entry["ts"]) %></td>
                  <td class="px-3 py-1.5 text-cyan-400"><%= entry["name"] %></td>
                  <td class="px-3 py-1.5">
                    <%= inspect(entry["previous"]) %> → <%= inspect(entry["value"]) %>
                  </td>
                  <td class="px-3 py-1.5 text-gray-400"><%= entry["source"] %></td>
                  <td class="px-3 py-1.5 text-gray-400 italic truncate max-w-md"><%= entry["reason"] %></td>
                  <td class="px-3 py-1.5 text-right">
                    <button
                      type="button"
                      phx-click="ask_rollback"
                      phx-value-idx={idx}
                      class="bg-gray-800 hover:bg-gray-700 text-gray-200 px-2 py-0.5 rounded"
                    >
                      ↶ rollback
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <%= if @confirm_action do %>
        <div class="fixed inset-0 bg-black/70 z-50 flex items-center justify-center" phx-click="cancel_confirm">
          <div class="bg-gray-900 border border-gray-800 rounded p-6 max-w-md" phx-click="ignore_inner">
            <h2 class="text-lg text-gray-100 mb-2"><%= confirm_title(@confirm_action) %></h2>
            <p class="text-sm text-gray-400 mb-4"><%= confirm_body(@confirm_action) %></p>
            <div class="flex gap-2 justify-end">
              <button phx-click="cancel_confirm" class="px-3 py-1 rounded border border-gray-700 text-gray-300 text-sm">cancel</button>
              <button phx-click="run_confirm" class="px-3 py-1 rounded bg-red-700 hover:bg-red-600 text-white text-sm">confirm</button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp flash_classes(:ok), do: "border-green-800 bg-green-950/40 text-green-300"
  defp flash_classes(:err), do: "border-red-800 bg-red-950/40 text-red-300"

  defp last_change_for(history, name) do
    history
    |> Enum.filter(&(&1["name"] == name))
    |> List.last()
  end

  defp last_history_with_idx(history, n) do
    total = length(history)
    take = min(n, total)

    history
    |> Enum.with_index()
    |> Enum.drop(total - take)
    |> Enum.reverse()
    |> Enum.map(fn {entry, idx} -> {entry, idx} end)
  end

  defp ago(nil), do: "—"

  defp ago(ts) when is_integer(ts) do
    delta = max(0, System.os_time(:second) - ts)

    cond do
      delta < 60 -> "#{delta}s ago"
      delta < 3600 -> "#{div(delta, 60)}m ago"
      delta < 86_400 -> "#{div(delta, 3600)}h ago"
      true -> "#{div(delta, 86_400)}d ago"
    end
  end

  defp ago(_), do: "—"

  defp confirm_title(%{kind: :restore, knob: knob}), do: "Restore #{knob} to default?"
  defp confirm_title(%{kind: :rollback, knob: knob}), do: "Roll back last change to #{knob}?"
  defp confirm_title(_), do: "Confirm action"

  defp confirm_body(%{kind: :restore, knob: knob}) do
    "Removes the operator override for #{knob}. ADAM will revert to the registry default on its next read."
  end

  defp confirm_body(%{kind: :rollback, knob: knob, entry: %{"previous" => prev, "value" => val}}) do
    "Reverts #{knob} from #{inspect(val)} back to #{inspect(prev)}. A new audit entry is appended."
  end

  defp confirm_body(%{kind: :rollback, knob: knob}) do
    "Reverts the last change to #{knob}."
  end

  defp confirm_body(_), do: "Are you sure?"
end
