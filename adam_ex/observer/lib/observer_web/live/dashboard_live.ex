defmodule ObserverWeb.DashboardLive do
  use ObserverWeb, :live_view

  # Left-border accent color per event type
  @border_colors %{
    "tool_call"      => "border-l-blue-500",
    "memory_update"  => "border-l-yellow-500",
    "memory_compact" => "border-l-orange-500",
    "thought"        => "border-l-purple-500",
    "context"        => "border-l-gray-500",
    "goal_update"    => "border-l-emerald-500",
  }

  # Badge styles per event type
  @type_badges %{
    "tool_call"      => "bg-blue-950 text-blue-300 border-blue-800",
    "memory_update"  => "bg-yellow-950 text-yellow-300 border-yellow-800",
    "memory_compact" => "bg-orange-950 text-orange-300 border-orange-800",
    "thought"        => "bg-purple-950 text-purple-300 border-purple-800",
    "context"        => "bg-gray-800 text-gray-300 border-gray-600",
    "goal_update"    => "bg-emerald-950 text-emerald-300 border-emerald-800",
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Observer.PubSub, "events")
    end

    mode = Application.get_env(:observer, :mode, "partial")

    {:ok,
     assign(socket,
       events: Observer.Store.all(),
       filter: "all",
       expanded: MapSet.new(),
       mode: mode,
       paused: false
     )}
  end

  @impl true
  def handle_info({:new_event, _event}, %{assigns: %{paused: true}} = socket) do
    # When paused, still store but don't update the visible list
    {:noreply, socket}
  end

  def handle_info({:new_event, event}, socket) do
    events = [event | socket.assigns.events] |> Enum.take(1000)
    {:noreply, assign(socket, events: events)}
  end

  @impl true
  def handle_event("set_filter", %{"type" => type}, socket) do
    {:noreply, assign(socket, filter: type)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, events: [], expanded: MapSet.new())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 flex flex-col">

      <%!-- ── Header ─────────────────────────────────────────────────── --%>
      <header class="sticky top-0 z-20 bg-gray-950/95 backdrop-blur border-b border-gray-800 px-5 py-3 flex items-center gap-3">
        <div class="flex items-center gap-2 shrink-0">
          <span class="text-emerald-400 font-bold text-base tracking-tight">ADAM</span>
          <span class="text-gray-600 text-base">observer</span>
        </div>

        <%!-- Mode badge --%>
        <span class={"px-2 py-0.5 text-xs rounded border font-bold shrink-0 " <> mode_badge(@mode)}>
          <%= String.upcase(@mode) %>
        </span>

        <%!-- Live indicator --%>
        <div class="flex items-center gap-1.5 shrink-0">
          <%= if @paused do %>
            <span class="h-2 w-2 rounded-full bg-gray-500"></span>
            <span class="text-gray-500 text-xs">paused</span>
          <% else %>
            <span class="relative flex h-2 w-2">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
            </span>
            <span class="text-emerald-500 text-xs">live</span>
          <% end %>
        </div>

        <span class="text-gray-600 text-xs ml-1">
          <%= length(@events) %> events
        </span>

        <div class="ml-auto flex gap-2">
          <button phx-click="toggle_pause"
                  class="px-3 py-1 text-xs rounded border border-gray-700 text-gray-400 hover:border-gray-500 hover:text-gray-200 transition-colors">
            <%= if @paused, do: "▶ resume", else: "⏸ pause" %>
          </button>
          <button phx-click="clear"
                  class="px-3 py-1 text-xs rounded border border-gray-700 text-gray-500 hover:border-red-800 hover:text-red-400 transition-colors">
            clear
          </button>
        </div>
      </header>

      <%!-- ── Filter bar ──────────────────────────────────────────────── --%>
      <div class="px-5 py-2 border-b border-gray-800 flex flex-wrap gap-1.5 bg-gray-950/80">
        <button phx-click="set_filter" phx-value-type="all"
                class={"px-3 py-1 text-xs rounded border transition-colors " <> filter_class("all", @filter)}>
          all
        </button>
        <%= for type <- ~w(tool_call memory_update memory_compact thought context goal_update) do %>
          <button phx-click="set_filter" phx-value-type={type}
                  class={"px-3 py-1 text-xs rounded border transition-colors " <> filter_class(type, @filter)}>
            <%= String.replace(type, "_", " ") %>
          </button>
        <% end %>
      </div>

      <%!-- ── Event timeline ─────────────────────────────────────────── --%>
      <div class="flex-1 px-4 py-3 space-y-1 max-w-5xl w-full mx-auto">
        <%= for event <- visible_events(@events, @filter) do %>
          <% id = event_id(event) %>
          <div class={"border-l-2 border border-gray-800 rounded-r bg-gray-900/40 overflow-hidden hover:bg-gray-900/70 transition-colors " <> border_color(event["type"])}>

            <%!-- Row --%>
            <button
              phx-click="toggle_expand"
              phx-value-id={id}
              class="w-full flex items-center gap-2.5 px-3 py-2 text-left"
            >
              <%!-- Timestamp --%>
              <span class="text-gray-600 text-xs shrink-0 w-16 tabular-nums">
                <%= format_ts(event["ts"]) %>
              </span>

              <%!-- Type badge --%>
              <span class={"px-1.5 py-0.5 text-xs rounded border font-mono shrink-0 " <> type_badge(event["type"])}>
                <%= event["type"] %>
              </span>

              <%!-- Iteration --%>
              <span class="text-gray-600 text-xs shrink-0 w-10 tabular-nums">
                #<%= event["iteration"] %>
              </span>

              <%!-- Tier badge (when relevant) --%>
              <%= if tier = get_in(event, ["data", "tier"]) do %>
                <span class={"px-1.5 py-0.5 text-xs rounded shrink-0 " <> tier_badge(tier)}>
                  <%= tier %>
                </span>
              <% end %>

              <%!-- Summary --%>
              <span class="text-gray-300 text-xs flex-1 truncate">
                <%= event_summary(event) %>
              </span>

              <%!-- Expand toggle --%>
              <span class="text-gray-700 text-xs shrink-0 pl-2">
                <%= if MapSet.member?(@expanded, id), do: "▲", else: "▼" %>
              </span>
            </button>

            <%!-- Expanded detail --%>
            <%= if MapSet.member?(@expanded, id) do %>
              <div class="border-t border-gray-800 px-4 py-3 bg-gray-950">
                <pre class="text-xs text-gray-300 overflow-auto max-h-96 whitespace-pre-wrap leading-relaxed"><%= Jason.encode!(event["data"], pretty: true) %></pre>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if visible_events(@events, @filter) == [] do %>
          <div class="text-center py-24 text-gray-700 text-sm">
            <div class="text-3xl mb-3">◎</div>
            <div>No events yet.</div>
            <div class="text-xs mt-1 text-gray-800">
              Is ADAM running with ADAM_OBSERVER_MODE=partial or full?
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp visible_events(events, "all"), do: events
  defp visible_events(events, filter), do: Enum.filter(events, &(&1["type"] == filter))

  defp event_id(event), do: "#{event["ts"]}_#{event["iteration"]}_#{event["type"]}"

  defp format_ts(ts) when is_number(ts) do
    ts |> trunc() |> DateTime.from_unix!() |> Calendar.strftime("%H:%M:%S")
  end
  defp format_ts(_), do: "--:--:--"

  defp event_summary(%{"type" => "tool_call", "data" => d}) do
    name = d["name"] || "?"
    ms = d["duration_ms"] || 0
    result = String.slice(to_string(d["result"]), 0, 80)
    "#{name}()  #{ms}ms  →  #{result}"
  end

  defp event_summary(%{"type" => "memory_update", "data" => d}) do
    file = Path.basename(to_string(d["file"]))
    delta = d["delta"] || 0
    sign = if delta >= 0, do: "+", else: ""
    "#{file}  #{sign}#{delta}B  (#{d["old_size"]} → #{d["new_size"]})"
  end

  defp event_summary(%{"type" => "memory_compact", "data" => d}) do
    pct = d["reduction_pct"] || 0
    "−#{pct}% reduction  (#{d["before_size"]} → #{d["after_size"]} bytes)"
  end

  defp event_summary(%{"type" => "thought", "data" => d}) do
    tokens = d["tokens"] || 0
    String.slice(to_string(d["content"]), 0, 90) <> "  [#{tokens} tok]"
  end

  defp event_summary(%{"type" => "context", "data" => d}) do
    len = d["context_len"] || 0
    tools = length(d["allowed_tools"] || [])
    tier = d["tier"] || "?"
    "#{len}B context · #{tools} tools · #{tier}"
  end

  defp event_summary(%{"type" => "goal_update", "data" => d}) do
    String.slice(to_string(d["goal"]), 0, 100)
  end

  defp event_summary(_), do: ""

  defp border_color(type), do: Map.get(@border_colors, type, "border-l-gray-700")
  defp type_badge(type),   do: Map.get(@type_badges, type, "bg-gray-800 text-gray-400 border-gray-700")

  defp tier_badge("deep"),    do: "bg-red-950 text-red-300 border border-red-900"
  defp tier_badge("actor"),   do: "bg-indigo-950 text-indigo-300 border border-indigo-900"
  defp tier_badge("thinker"), do: "bg-gray-800 text-gray-500 border border-gray-700"
  defp tier_badge(_),         do: "bg-gray-800 text-gray-500 border border-gray-700"

  defp mode_badge("full"),    do: "bg-purple-950 text-purple-300 border-purple-800"
  defp mode_badge("partial"), do: "bg-blue-950 text-blue-300 border-blue-800"
  defp mode_badge(_),         do: "bg-gray-800 text-gray-500 border-gray-700"

  defp filter_class(type, type), do: "bg-gray-700 text-white border-gray-500"
  defp filter_class(_, _),       do: "bg-transparent text-gray-500 border-gray-800 hover:border-gray-600 hover:text-gray-300"
end
