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
     |> load_page(1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_int(params["page"], 1)
    {:noreply, load_page(socket, page)}
  end

  @impl true
  def handle_info({:new_call, call}, socket) do
    if socket.assigns.page == 1 do
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

  defp load_page(socket, page) do
    socket
    |> assign(:page, page)
    |> assign(:calls, Calls.list(page: page, per: @per_page))
    |> assign(:total, Calls.count())
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
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-gray-100">LLM calls</h1>
        <p class="text-sm text-gray-500 mt-1">
          <%= @total %> total · page <%= @page %> · live updating
        </p>
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
              <span class="col-span-2 text-cyan-400 truncate"><%= call.model || "—" %></span>
              <span class={"col-span-1 #{status_color(call.status)}"}><%= call.status %></span>
              <span class="col-span-1 text-gray-400"><%= call.duration_ms %>ms</span>
              <span class="col-span-1 text-gray-400">
                <%= call.prompt_tokens || "·" %>/<%= call.completion_tokens || "·" %>
              </span>
              <span class="col-span-1 text-gray-400">tc:<%= call.tool_call_count || 0 %></span>
              <span class="col-span-4 truncate text-gray-300"><%= preview(call) %></span>
            </button>

            <%= if MapSet.member?(@expanded, call.id) do %>
              <div class="border-t border-gray-800 p-3 space-y-3 bg-gray-950/50">
                <%= if call.error do %>
                  <div>
                    <div class="text-xs text-red-400 mb-1">error</div>
                    <pre class="text-xs whitespace-pre-wrap text-red-300 bg-gray-950 p-2 rounded"><%= call.error %></pre>
                  </div>
                <% end %>
                <div>
                  <div class="text-xs text-gray-500 mb-1">request</div>
                  <pre class="text-xs whitespace-pre-wrap text-gray-200 bg-gray-950 p-2 rounded max-h-96 overflow-auto"><%= pretty(call.request) %></pre>
                </div>
                <%= if call.response do %>
                  <div>
                    <div class="text-xs text-gray-500 mb-1">response</div>
                    <pre class="text-xs whitespace-pre-wrap text-gray-200 bg-gray-950 p-2 rounded max-h-96 overflow-auto"><%= pretty(call.response) %></pre>
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
end
