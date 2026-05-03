defmodule LlmGatewayWeb.AdminLive do
  use LlmGatewayWeb, :live_view

  alias LlmGateway.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:flash_msg, nil)
     |> assign(:flash_kind, :ok)
     |> load_state()}
  end

  defp load_state(socket) do
    socket
    |> assign(:env_entries, Admin.read_env())
    |> assign(:system_prompt, read_prompt_or_empty("system"))
    |> assign(:goals_prompt, read_prompt_or_empty("goals"))
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
      when event in ["wipe_memory", "wipe_knowledge", "wipe_checkpoints", "factory_reset"] do
    {:noreply, flash_err(socket, "confirmation phrase did not match — nothing was deleted")}
  end

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
          factory reset wipes memory/, knowledge/, checkpoints/ and restores prompts from <code>priv/defaults/</code> if present. Restart ADAM afterward.
        </p>
      </div>
    </div>
    """
  end

  defp flash_classes(:ok), do: "border-green-800 bg-green-950/40 text-green-300"
  defp flash_classes(:err), do: "border-red-800 bg-red-950/40 text-red-300"
end
