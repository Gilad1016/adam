defmodule LlmGatewayWeb.CallsLive do
  use LlmGatewayWeb, :live_view

  alias LlmGateway.Calls

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(LlmGateway.PubSub, "calls")

    {:ok,
     socket
     |> assign(:expanded, MapSet.new())
     |> assign(:per_page, @per_page)
     |> assign(:filter_kind, nil)
     |> load_page(1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_int(params["page"], 1)
    {:noreply, load_page(socket, page)}
  end

  @impl true
  def handle_info({:new_call, call}, socket) do
    if matches_filter?(call, socket.assigns.filter_kind) and socket.assigns.page == 1 do
      calls = [call | socket.assigns.calls] |> Enum.take(@per_page)
      {:noreply, assign(socket, calls: calls, total: socket.assigns.total + 1)}
    else
      {:noreply, assign(socket, total: socket.assigns.total + 1)}
    end
  end

  def handle_info(:calls_wiped, socket) do
    {:noreply, socket |> assign(:expanded, MapSet.new()) |> load_page(1)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)

    expanded =
      if MapSet.member?(socket.assigns.expanded, id),
        do: MapSet.delete(socket.assigns.expanded, id),
        else: MapSet.put(socket.assigns.expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    filter = if kind == "all", do: nil, else: kind

    {:noreply,
     socket
     |> assign(:filter_kind, filter)
     |> load_page(1)}
  end

  defp matches_filter?(_, nil), do: true
  defp matches_filter?(%{kind: k}, prefix) when is_binary(k), do: String.starts_with?(k, prefix)
  defp matches_filter?(_, _), do: false

  defp load_page(socket, page) do
    filter = socket.assigns[:filter_kind]

    socket
    |> assign(:page, page)
    |> assign(:calls, Calls.list(page: page, per: @per_page, kind: filter))
    |> assign(:total, Calls.count(kind: filter))
  end

  defp parse_int(nil, default), do: default

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <div class="mb-4">
        <h1 class="text-2xl font-semibold text-gray-100">LLM calls</h1>
        <p class="text-sm text-gray-500 mt-1">
          <%= @total %> total · page <%= @page %> · live updating
        </p>
      </div>

      <div class="flex gap-2 mb-4 text-xs">
        <button
          phx-click="filter_kind"
          phx-value-kind="all"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, nil)}
        >
          all
        </button>
        <button
          phx-click="filter_kind"
          phx-value-kind="agent"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, "agent")}
        >
          agent
        </button>
        <button
          phx-click="filter_kind"
          phx-value-kind="infra"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, "infra")}
        >
          infra
        </button>
        <button
          phx-click="filter_kind"
          phx-value-kind="tuning"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, "tuning")}
        >
          tuning
        </button>
      </div>

      <div class="space-y-1">
        <div class="grid grid-cols-12 gap-2 text-[10px] uppercase tracking-wider text-gray-500 px-3 py-2 border-b border-gray-800 mb-1">
          <span class="col-span-2">time</span>
          <span class="col-span-1">kind</span>
          <span class="col-span-2">model</span>
          <span class="col-span-1">status</span>
          <span class="col-span-1">duration</span>
          <span class="col-span-1">tokens</span>
          <span class="col-span-1">tools</span>
          <span class="col-span-3">preview</span>
        </div>
        <%= if @calls == [] do %>
          <div class="text-gray-500 text-sm italic p-6 border border-gray-800 rounded text-center">
            No calls logged yet. Once ADAM starts thinking, calls will appear here.
          </div>
        <% end %>
        <%= for call <- @calls do %>
          <div class="border border-gray-800 rounded">
            <button
              phx-click="toggle"
              phx-value-id={call.id}
              class="w-full text-left p-3 grid grid-cols-12 gap-2 text-xs hover:bg-gray-900 transition"
            >
              <span class="col-span-2 text-gray-500"><%= relative_time(call.inserted_at) %></span>
              <span class={"col-span-1 truncate text-[10px] uppercase tracking-wider " <> kind_color(call.kind)}><%= call.kind || "—" %></span>
              <span class="col-span-2 text-cyan-400 truncate"><%= call.model || "—" %></span>
              <span class={"col-span-1 #{status_color(call.status)}"}><%= call.status %></span>
              <span class="col-span-1 text-gray-400"><%= call.duration_ms %>ms</span>
              <span class="col-span-1 text-gray-400">
                <%= call.prompt_tokens || "·" %>/<%= call.completion_tokens || "·" %>
              </span>
              <span class="col-span-1 text-gray-400">tc:<%= call.tool_call_count || 0 %></span>
              <span class="col-span-3 truncate text-gray-300"><%= preview(call) %></span>
            </button>

            <%= if MapSet.member?(@expanded, call.id) do %>
              <div class="border-t border-gray-800 p-3 space-y-3 bg-gray-950/50">
                <%= if call.error do %>
                  <div class="border border-red-800/50 rounded">
                    <div class="text-[10px] uppercase tracking-wider text-red-500 px-3 pt-2">error</div>
                    <pre class="text-xs whitespace-pre-wrap text-red-300 p-3"><%= call.error %></pre>
                  </div>
                <% end %>

                <%= if String.starts_with?(call.kind || "", "tuning.") do %>
                  <% event = tuning_event(call) %>
                  <%= if event do %>
                    <div class="border border-violet-900/40 rounded bg-violet-950/10 p-3 space-y-1 text-xs">
                      <div class="text-[10px] uppercase tracking-wider text-violet-400">tuning event</div>
                      <div><span class="text-gray-500 inline-block w-20">knob:</span> <span class="text-gray-100"><%= event["name"] %></span></div>
                      <div><span class="text-gray-500 inline-block w-20">value:</span> <span class="text-gray-300"><%= format_value(event["previous"]) %> → <%= format_value(event["value"]) %></span></div>
                      <div><span class="text-gray-500 inline-block w-20">source:</span> <span class="text-violet-300"><%= event["source"] %></span></div>
                      <div><span class="text-gray-500 inline-block w-20">reason:</span> <span class="text-gray-300 whitespace-pre-wrap"><%= event["reason"] %></span></div>
                      <div><span class="text-gray-500 inline-block w-20">ts:</span> <span class="text-gray-500"><%= format_ts(event["ts"]) %></span></div>
                    </div>
                  <% end %>
                <% else %>
                  <% messages = parsed_messages(call) %>
                  <% tools_json = tools_pretty(call) %>

                  <%= if tools_json do %>
                    <div class={"border border-gray-800 rounded " <> section_border("tools")}>
                      <div class="text-[10px] uppercase tracking-wider text-amber-400 px-3 pt-2">available tools</div>
                      <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= tools_json %></pre>
                    </div>
                  <% end %>

                  <%= for msg <- messages do %>
                    <%= if msg["role"] == "system" do %>
                      <div class={"border border-gray-800 rounded " <> section_border("system prompt")}>
                        <div class="text-[10px] uppercase tracking-wider text-cyan-400 px-3 pt-2">system</div>
                        <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= msg["content"] %></pre>
                      </div>
                    <% end %>
                    <%= if msg["role"] == "user" do %>
                      <% user_sections = parse_sections(msg["content"]) %>
                      <div class="border border-gray-800 rounded">
                        <div class="text-[10px] uppercase tracking-wider text-gray-500 px-3 pt-2">→ user</div>
                        <%= if user_sections == [] do %>
                          <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= msg["content"] %></pre>
                        <% else %>
                          <div class="p-3 space-y-2">
                            <%= for section <- user_sections do %>
                              <div>
                                <div class="text-[10px] uppercase tracking-wider text-gray-500"><%= section.label %></div>
                                <pre class="text-xs whitespace-pre-wrap text-gray-200 mt-1"><%= section.content %></pre>
                              </div>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if msg["role"] == "assistant" do %>
                      <div class="border border-blue-900/40 rounded bg-blue-950/10">
                        <div class="text-[10px] uppercase tracking-wider text-blue-400 px-3 pt-2">← assistant</div>
                        <%= if msg["content"] not in [nil, ""] do %>
                          <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= msg["content"] %></pre>
                        <% end %>
                        <%= for tc <- List.wrap(msg["tool_calls"]) do %>
                          <div class="px-3 pb-2">
                            <div class="text-[10px] text-amber-400 mt-1">↳ tool call: <%= get_in(tc, ["function", "name"]) || tc["name"] %></div>
                            <pre class="text-xs whitespace-pre-wrap text-amber-200/80 p-2 mt-1 bg-gray-950 rounded"><%= pretty_args(get_in(tc, ["function", "arguments"]) || tc["arguments"]) %></pre>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if msg["role"] == "tool" do %>
                      <div class="border border-amber-900/40 rounded bg-amber-950/10">
                        <div class="text-[10px] uppercase tracking-wider text-amber-400 px-3 pt-2">→ tool result<%= if msg["name"], do: ": " <> msg["name"] %></div>
                        <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= msg["content"] %></pre>
                      </div>
                    <% end %>
                  <% end %>

                  <%= if call.response do %>
                    <div class="border border-green-900/40 rounded bg-green-950/10">
                      <div class="text-[10px] uppercase tracking-wider text-green-400 px-3 pt-2">↩ response (this call)</div>
                      <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= pretty(call.response) %></pre>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="mt-6 flex gap-4 text-xs">
        <%= if @page > 1 do %>
          <.link patch={"/?page=" <> Integer.to_string(@page - 1)} class="text-cyan-400 hover:text-cyan-300">
            ← newer
          </.link>
        <% end %>
        <%= if @page * @per_page < @total do %>
          <.link patch={"/?page=" <> Integer.to_string(@page + 1)} class="text-cyan-400 hover:text-cyan-300">
            older →
          </.link>
        <% end %>
      </div>
    </div>
    """
  end

  defp pretty(json) when is_binary(json) and byte_size(json) > 0 do
    case Jason.decode(json) do
      {:ok, m} -> Jason.encode!(m, pretty: true)
      _ -> json
    end
  end

  defp pretty(_), do: ""

  defp pretty_args(nil), do: ""
  defp pretty_args(args) when is_map(args) or is_list(args), do: Jason.encode!(args, pretty: true)
  defp pretty_args(args) when is_binary(args), do: args
  defp pretty_args(args), do: inspect(args)

  defp preview(%{kind: "tuning." <> _, request: req}) when is_binary(req) do
    case Jason.decode(req) do
      {:ok, %{"name" => n, "value" => v, "source" => s}} ->
        "#{s} set #{n} = #{format_value(v)}"

      _ ->
        "tuning event"
    end
  end

  defp preview(%{request: req}) when is_binary(req) do
    case Jason.decode(req) do
      {:ok, %{"messages" => msgs}} when is_list(msgs) ->
        case List.last(msgs) do
          %{"content" => c} when is_binary(c) ->
            c |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  defp preview(_), do: ""

  # Compact rendering of a tuning event value. Maps render as `<map:N keys>`
  # so a personality-vector swap doesn't dump the whole vector inline.
  defp format_value(v) when is_map(v), do: "<map:#{map_size(v)} keys>"
  defp format_value(v) when is_number(v), do: to_string(v)
  defp format_value(v) when is_binary(v), do: inspect(v)
  defp format_value(nil), do: "—"
  defp format_value(v), do: inspect(v)

  defp tuning_event(%{request: req}) when is_binary(req) do
    case Jason.decode(req) do
      {:ok, m} when is_map(m) -> m
      _ -> nil
    end
  end

  defp tuning_event(_), do: nil

  defp format_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> to_string(ts)
    end
  end

  defp format_ts(ts), do: inspect(ts)

  defp status_color(s) when is_integer(s) and s in 200..299, do: "text-green-400"
  defp status_color(s) when is_integer(s) and s in 400..599, do: "text-red-400"
  defp status_color(_), do: "text-gray-400"

  defp kind_color(k) when is_binary(k) do
    cond do
      String.starts_with?(k, "tuning.") -> "text-violet-400"
      String.starts_with?(k, "agent") -> "text-cyan-400"
      String.starts_with?(k, "infra") -> "text-amber-400"
      true -> "text-gray-500"
    end
  end

  defp kind_color(_), do: "text-gray-500"

  defp filter_pill_class(current, value) do
    cond do
      current == value and value == nil ->
        "border-cyan-400 text-cyan-400 bg-cyan-400/10"

      current == value and value == "agent" ->
        "border-cyan-400 text-cyan-400 bg-cyan-400/10"

      current == value and value == "infra" ->
        "border-amber-400 text-amber-400 bg-amber-400/10"

      current == value and value == "tuning" ->
        "border-violet-400 text-violet-400 bg-violet-400/10"

      true ->
        "border-gray-700 text-gray-400 hover:text-gray-200"
    end
  end

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp relative_time(_), do: "—"

  defp parsed_messages(call) do
    case Jason.decode(call.request || "") do
      {:ok, %{"messages" => msgs}} when is_list(msgs) -> msgs
      _ -> []
    end
  end

  defp parse_sections(nil), do: []

  defp parse_sections(content) when is_binary(content) do
    lines = String.split(content, "\n")
    do_parse_sections(lines, :outside, nil, [], [], [])
  end

  defp do_parse_sections([], :outside, _label, _acc, pre, sections) do
    pre_section =
      case Enum.reverse(pre) |> Enum.join("\n") |> String.trim() do
        "" -> []
        text -> [%{label: "memory", content: text}]
      end

    Enum.reverse(sections) ++ pre_section
  end

  defp do_parse_sections([], :inside, label, acc, _pre, sections) do
    text = Enum.reverse(acc) |> Enum.join("\n")
    Enum.reverse([%{label: label, content: text} | sections])
  end

  defp do_parse_sections([line | rest], :outside, _label, _acc, pre, sections) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(~r/^== ([A-Z][A-Z _]+) ==$/, trimmed) and
          not String.starts_with?(trimmed, "== END") ->
        [_, name] = Regex.run(~r/^== ([A-Z][A-Z _]+) ==$/, trimmed)

        pre_section =
          case Enum.reverse(pre) |> Enum.join("\n") |> String.trim() do
            "" -> []
            text -> [%{label: "memory", content: text}]
          end

        do_parse_sections(rest, :inside, String.downcase(name), [], [], pre_section ++ sections)

      true ->
        do_parse_sections(rest, :outside, nil, [], [line | pre], sections)
    end
  end

  defp do_parse_sections([line | rest], :inside, label, acc, pre, sections) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(~r/^== END/, trimmed) ->
        content = Enum.reverse(acc) |> Enum.join("\n") |> String.trim()
        do_parse_sections(rest, :outside, nil, [], pre, [%{label: label, content: content} | sections])

      true ->
        do_parse_sections(rest, :inside, label, [line | acc], pre, sections)
    end
  end

  defp section_border("system prompt"), do: "border-l-2 border-cyan-500/50"
  defp section_border("tools"), do: "border-l-2 border-amber-500/50"
  defp section_border(_), do: ""

  defp tools_pretty(call) do
    case Jason.decode(call.request || "") do
      {:ok, %{"tools" => tools}} when is_list(tools) and tools != [] ->
        Jason.encode!(tools, pretty: true)

      _ ->
        nil
    end
  end
end
