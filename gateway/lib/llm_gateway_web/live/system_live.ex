defmodule LlmGatewayWeb.SystemLive do
  use LlmGatewayWeb, :live_view

  alias LlmGateway.SystemStats

  @history 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(LlmGateway.PubSub, "system_stats")
    snap = SystemStats.latest()

    {:ok,
     socket
     |> assign(:snap, snap)
     |> assign(:history, [])
     |> assign(:chart, history_chart([]))}
  end

  @impl true
  def handle_info({:system_stats, snap}, socket) do
    history = (socket.assigns.history ++ [snap]) |> Enum.take(-@history)

    {:noreply,
     socket
     |> assign(:snap, snap)
     |> assign(:history, history)
     |> assign(:chart, history_chart(history))}
  end

  defp history_chart(history) do
    labels = Enum.map(history, fn s -> Calendar.strftime(s.ts, "%H:%M:%S") end)
    cpu = Enum.map(history, fn s -> s.cpu[:percent] || 0.0 end)

    gpu =
      Enum.map(history, fn s ->
        Enum.map(s.gpus || [], & &1.util_pct) |> Enum.max(fn -> 0.0 end)
      end)

    %{
      type: "line",
      data: %{
        labels: labels,
        datasets: [
          %{
            label: "cpu %",
            data: cpu,
            borderColor: "#22d3ee",
            backgroundColor: "rgba(34,211,238,0.1)",
            tension: 0.3,
            fill: true
          },
          %{
            label: "gpu %",
            data: gpu,
            borderColor: "#f59e0b",
            backgroundColor: "rgba(245,158,11,0.1)",
            tension: 0.3,
            fill: true
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: %{legend: %{labels: %{color: "#9ca3af"}}},
        scales: %{
          y: %{min: 0, max: 100, ticks: %{color: "#9ca3af"}, grid: %{color: "#1f2937"}},
          x: %{ticks: %{color: "#9ca3af", maxTicksLimit: 6}, grid: %{display: false}}
        }
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-gray-100">system</h1>
        <p class="text-sm text-gray-500 mt-1">live host machine usage · refresh every 2s</p>
      </div>

      <%= if @snap == nil or @snap == %{} do %>
        <div class="text-gray-500 text-sm italic p-6 border border-gray-800 rounded text-center">
          waiting for first reading…
        </div>
      <% else %>
        <div class="grid grid-cols-4 gap-3 mb-6">
          <div class="border border-gray-800 rounded p-3">
            <div class="text-xs uppercase tracking-wider text-gray-500">cpu</div>
            <div class="text-2xl font-semibold text-cyan-400 mt-1">
              <%= Float.round(@snap.cpu[:percent] || 0.0, 1) %>%
            </div>
          </div>
          <div class="border border-gray-800 rounded p-3">
            <div class="text-xs uppercase tracking-wider text-gray-500">ram</div>
            <div class="text-2xl font-semibold text-cyan-400 mt-1"><%= @snap.memory[:percent] %>%</div>
            <div class="text-xs text-gray-500 mt-1">
              <%= @snap.memory[:used_mb] %> / <%= @snap.memory[:total_mb] %> mb
            </div>
          </div>
          <%= for gpu <- @snap.gpus do %>
            <div class="border border-gray-800 rounded p-3">
              <div class="text-xs uppercase tracking-wider text-gray-500"><%= gpu.name %> · gpu</div>
              <div class="text-2xl font-semibold text-amber-400 mt-1"><%= gpu.util_pct %>%</div>
              <div class="text-xs text-gray-500 mt-1">
                <%= gpu.temp_c %>°C · <%= gpu.power_w %>W
              </div>
            </div>
            <div class="border border-gray-800 rounded p-3">
              <div class="text-xs uppercase tracking-wider text-gray-500">vram</div>
              <div class="text-2xl font-semibold text-amber-400 mt-1">
                <%= Float.round(gpu.vram_used_mb * 100 / max(gpu.vram_total_mb, 1), 1) %>%
              </div>
              <div class="text-xs text-gray-500 mt-1">
                <%= gpu.vram_used_mb %> / <%= gpu.vram_total_mb %> mb
              </div>
            </div>
          <% end %>
        </div>

        <div class="border border-gray-800 rounded p-3 mb-6" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">cpu / gpu over time</div>
          <div
            phx-hook="Chart"
            id="chart-system-history"
            data-chart={Jason.encode!(@chart)}
            style="height: 200px;"
          >
            <canvas></canvas>
          </div>
        </div>

        <div class="border border-gray-800 rounded p-3">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">cpu cores</div>
          <div class="space-y-1">
            <%= for {pct, idx} <- Enum.with_index(@snap.cpu[:per_core] || []) do %>
              <div class="flex items-center gap-2 text-xs">
                <span class="w-12 text-gray-500">cpu<%= idx %></span>
                <div class="flex-1 h-3 bg-gray-900 rounded overflow-hidden">
                  <div class="h-full bg-cyan-500" style={"width: #{pct}%"}></div>
                </div>
                <span class="w-12 text-right text-gray-400"><%= pct %>%</span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
