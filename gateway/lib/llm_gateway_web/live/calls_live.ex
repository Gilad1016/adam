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

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)

    expanded =
      if MapSet.member?(socket.assigns.expanded, id),
        do: MapSet.delete(socket.assigns.expanded, id),
        else: MapSet.put(socket.assigns.expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("filter_kind", %{"value" => value}, socket) do
    filter = if value == "all", do: nil, else: value

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
          phx-value-value="all"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, nil)}
        >
          all
        </button>
        <button
          phx-click="filter_kind"
          phx-value-value="agent"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, "agent")}
        >
          agent
        </button>
        <button
          phx-click="filter_kind"
          phx-value-value="infra"
          class={"px-3 py-1 rounded border " <> filter_pill_class(@filter_kind, "infra")}
        >
          infra
        </button>
      </div>

      <div class="space-y-1">
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

                <% messages = parsed_messages(call) %>
                <% sys = system_message(messages) %>
                <% usr = user_message(messages) %>
                <% sections = parse_sections(usr && usr["content"]) %>
                <% tools_json = tools_pretty(call) %>

                <%= if sys do %>
                  <div class={"border border-gray-800 rounded " <> section_border("system prompt")}>
                    <div class="text-[10px] uppercase tracking-wider text-cyan-400 px-3 pt-2">system prompt</div>
                    <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= sys["content"] %></pre>
                  </div>
                <% end %>

                <%= for section <- sections do %>
                  <div class="border border-gray-800 rounded">
                    <div class="text-[10px] uppercase tracking-wider text-gray-400 px-3 pt-2"><%= section.label %></div>
                    <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= section.content %></pre>
                  </div>
                <% end %>

                <%= if tools_json do %>
                  <div class={"border border-gray-800 rounded " <> section_border("tools")}>
                    <div class="text-[10px] uppercase tracking-wider text-amber-400 px-3 pt-2">tools</div>
                    <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= tools_json %></pre>
                  </div>
                <% end %>

                <%= if call.response do %>
                  <div class="border border-gray-800 rounded">
                    <div class="text-[10px] uppercase tracking-wider text-gray-500 px-3 pt-2">response</div>
                    <pre class="text-xs whitespace-pre-wrap text-gray-200 p-3 max-h-72 overflow-auto"><%= pretty(call.response) %></pre>
                  </div>
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

  defp status_color(s) when is_integer(s) and s in 200..299, do: "text-green-400"
  defp status_color(s) when is_integer(s) and s in 400..599, do: "text-red-400"
  defp status_color(_), do: "text-gray-400"

  defp kind_color(k) when is_binary(k) do
    cond do
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

  defp system_message(messages) do
    Enum.find(messages, &(&1["role"] == "system"))
  end

  defp user_message(messages) do
    Enum.find(messages, &(&1["role"] == "user"))
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
