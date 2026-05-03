defmodule LlmGatewayWeb.StatsLive do
  use LlmGatewayWeb, :live_view

  import Ecto.Query
  alias LlmGateway.{Calls, Repo}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(LlmGateway.PubSub, "calls")
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info({:new_call, _call}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    socket
    |> assign(:summary, summary())
    |> assign(:charts, %{
      calls_per_min: calls_per_minute_chart(calls_per_minute_buckets()),
      tokens_over_time: tokens_chart(tokens_buckets()),
      status_dist: status_chart(status_distribution()),
      models: models_chart(model_distribution()),
      kinds: kinds_chart(kind_distribution()),
      duration_hist: duration_chart(duration_histogram())
    })
  end

  # ---------- summary ----------

  defp summary do
    total_calls = Calls.count()

    {prompt_sum, completion_sum} =
      from(c in Calls,
        select: {
          coalesce(sum(c.prompt_tokens), 0),
          coalesce(sum(c.completion_tokens), 0)
        }
      )
      |> Repo.one()

    error_count =
      from(c in Calls, where: c.status >= 400, select: count(c.id))
      |> Repo.one()

    error_pct =
      if total_calls > 0, do: Float.round(error_count * 100 / total_calls, 1), else: 0.0

    avg_duration =
      from(c in Calls,
        order_by: [desc: c.id],
        limit: 100,
        select: c.duration_ms
      )
      |> Repo.all()
      |> case do
        [] -> 0
        list -> div(Enum.sum(list), length(list))
      end

    %{
      total_calls: total_calls,
      total_tokens: (prompt_sum || 0) + (completion_sum || 0),
      error_pct: error_pct,
      avg_duration_ms: avg_duration
    }
  end

  # ---------- per-minute buckets ----------

  defp minute_buckets(now) do
    # 30 buckets, oldest first
    base = DateTime.truncate(now, :second)
    base = %{base | second: 0, microsecond: {0, 0}}

    for i <- 29..0//-1 do
      ts = DateTime.add(base, -i * 60, :second)
      key = {ts.year, ts.month, ts.day, ts.hour, ts.minute}
      label = :io_lib.format("~2..0B:~2..0B", [ts.hour, ts.minute]) |> IO.iodata_to_binary()
      %{ts: ts, key: key, label: label, count: 0, prompt: 0, completion: 0}
    end
  end

  defp bucket_key(%DateTime{} = dt), do: {dt.year, dt.month, dt.day, dt.hour, dt.minute}

  defp calls_per_minute_buckets do
    now = DateTime.utc_now()
    from_ts = DateTime.add(now, -30 * 60, :second)
    buckets = minute_buckets(now)

    rows =
      from(c in Calls,
        where: c.inserted_at >= ^from_ts,
        select: c.inserted_at
      )
      |> Repo.all()

    counts =
      Enum.reduce(rows, %{}, fn ts, acc ->
        Map.update(acc, bucket_key(ts), 1, &(&1 + 1))
      end)

    Enum.map(buckets, fn b -> %{b | count: Map.get(counts, b.key, 0)} end)
  end

  defp tokens_buckets do
    now = DateTime.utc_now()
    from_ts = DateTime.add(now, -30 * 60, :second)
    buckets = minute_buckets(now)

    rows =
      from(c in Calls,
        where: c.inserted_at >= ^from_ts,
        select: {c.inserted_at, c.prompt_tokens, c.completion_tokens}
      )
      |> Repo.all()

    sums =
      Enum.reduce(rows, %{}, fn {ts, p, c}, acc ->
        key = bucket_key(ts)

        Map.update(
          acc,
          key,
          %{prompt: p || 0, completion: c || 0},
          fn m -> %{prompt: m.prompt + (p || 0), completion: m.completion + (c || 0)} end
        )
      end)

    Enum.map(buckets, fn b ->
      m = Map.get(sums, b.key, %{prompt: 0, completion: 0})
      %{b | prompt: m.prompt, completion: m.completion}
    end)
  end

  # ---------- status / model / kind / duration ----------

  defp status_distribution do
    rows =
      from(c in Calls,
        group_by: fragment("CASE WHEN ? >= 200 AND ? < 300 THEN '2xx' WHEN ? >= 400 AND ? < 500 THEN '4xx' WHEN ? >= 500 THEN '5xx' ELSE 'other' END", c.status, c.status, c.status, c.status, c.status),
        select: {
          fragment("CASE WHEN ? >= 200 AND ? < 300 THEN '2xx' WHEN ? >= 400 AND ? < 500 THEN '4xx' WHEN ? >= 500 THEN '5xx' ELSE 'other' END", c.status, c.status, c.status, c.status, c.status),
          count(c.id)
        }
      )
      |> Repo.all()

    map = Enum.into(rows, %{})

    [
      %{label: "2xx", count: Map.get(map, "2xx", 0)},
      %{label: "4xx", count: Map.get(map, "4xx", 0)},
      %{label: "5xx", count: Map.get(map, "5xx", 0)},
      %{label: "other", count: Map.get(map, "other", 0)}
    ]
  end

  defp model_distribution do
    from(c in Calls,
      group_by: c.model,
      select: {c.model, count(c.id)},
      order_by: [desc: count(c.id)],
      limit: 6
    )
    |> Repo.all()
    |> Enum.map(fn {m, n} -> %{label: m || "—", count: n} end)
  end

  defp kind_distribution do
    try do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT COALESCE(kind, 'agent') as k, COUNT(*) FROM calls GROUP BY k",
          []
        )

      Enum.map(rows, fn [k, n] -> %{label: k, count: n} end)
    rescue
      _ -> []
    end
  end

  @duration_bins [
    {"0-500", 0, 500},
    {"500-1000", 500, 1_000},
    {"1-2s", 1_000, 2_000},
    {"2-5s", 2_000, 5_000},
    {"5-10s", 5_000, 10_000},
    {"10-30s", 10_000, 30_000},
    {">30s", 30_000, :infinity}
  ]

  defp duration_histogram do
    durations =
      from(c in Calls, select: c.duration_ms)
      |> Repo.all()

    Enum.map(@duration_bins, fn {label, low, high} ->
      count =
        Enum.count(durations, fn
          nil -> false
          d -> d >= low and (high == :infinity or d < high)
        end)

      %{label: label, count: count}
    end)
  end

  # ---------- chart configs ----------

  defp calls_per_minute_chart(buckets) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, & &1.label),
        datasets: [
          %{
            label: "calls",
            data: Enum.map(buckets, & &1.count),
            backgroundColor: "#22d3ee"
          }
        ]
      },
      options: bar_options()
    }
  end

  defp tokens_chart(buckets) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, & &1.label),
        datasets: [
          %{
            label: "prompt",
            data: Enum.map(buckets, & &1.prompt),
            backgroundColor: "#a78bfa",
            stack: "tokens"
          },
          %{
            label: "completion",
            data: Enum.map(buckets, & &1.completion),
            backgroundColor: "#f472b6",
            stack: "tokens"
          }
        ]
      },
      options: %{
        responsive: true,
        maintainAspectRatio: false,
        plugins: %{legend: %{labels: %{color: "#9ca3af"}}},
        scales: %{
          x: %{stacked: true, ticks: %{color: "#9ca3af"}, grid: %{display: false}},
          y: %{
            stacked: true,
            beginAtZero: true,
            ticks: %{color: "#9ca3af"},
            grid: %{color: "#1f2937"}
          }
        }
      }
    }
  end

  defp status_chart(buckets) do
    colors = %{"2xx" => "#34d399", "4xx" => "#fbbf24", "5xx" => "#f87171", "other" => "#6b7280"}

    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, & &1.label),
        datasets: [
          %{
            label: "calls",
            data: Enum.map(buckets, & &1.count),
            backgroundColor: Enum.map(buckets, &Map.get(colors, &1.label, "#6b7280"))
          }
        ]
      },
      options: bar_options()
    }
  end

  defp models_chart(buckets) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, & &1.label),
        datasets: [
          %{
            label: "calls",
            data: Enum.map(buckets, & &1.count),
            backgroundColor: "#fb923c"
          }
        ]
      },
      options: Map.put(bar_options(), :indexAxis, "y")
    }
  end

  defp kinds_chart(buckets) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, & &1.label),
        datasets: [
          %{
            label: "calls",
            data: Enum.map(buckets, & &1.count),
            backgroundColor: "#60a5fa"
          }
        ]
      },
      options: bar_options()
    }
  end

  defp duration_chart(buckets) do
    %{
      type: "bar",
      data: %{
        labels: Enum.map(buckets, & &1.label),
        datasets: [
          %{
            label: "calls",
            data: Enum.map(buckets, & &1.count),
            backgroundColor: "#facc15"
          }
        ]
      },
      options: bar_options()
    }
  end

  defp bar_options do
    %{
      responsive: true,
      maintainAspectRatio: false,
      plugins: %{legend: %{display: false}},
      scales: %{
        y: %{beginAtZero: true, ticks: %{color: "#9ca3af"}, grid: %{color: "#1f2937"}},
        x: %{ticks: %{color: "#9ca3af"}, grid: %{display: false}}
      }
    }
  end

  # ---------- render ----------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-gray-100">Stats</h1>
        <p class="text-sm text-gray-500 mt-1">live updating · last 30 minutes</p>
      </div>

      <div class="grid grid-cols-4 gap-3 mb-6">
        <div class="border border-gray-800 rounded p-3">
          <div class="text-xs uppercase tracking-wider text-gray-500">total calls</div>
          <div class="text-2xl font-semibold text-cyan-400 mt-1"><%= @summary.total_calls %></div>
        </div>
        <div class="border border-gray-800 rounded p-3">
          <div class="text-xs uppercase tracking-wider text-gray-500">total tokens</div>
          <div class="text-2xl font-semibold text-fuchsia-400 mt-1"><%= @summary.total_tokens %></div>
        </div>
        <div class="border border-gray-800 rounded p-3">
          <div class="text-xs uppercase tracking-wider text-gray-500">error %</div>
          <div class="text-2xl font-semibold text-red-400 mt-1"><%= @summary.error_pct %>%</div>
        </div>
        <div class="border border-gray-800 rounded p-3">
          <div class="text-xs uppercase tracking-wider text-gray-500">avg latency (last 100)</div>
          <div class="text-2xl font-semibold text-amber-400 mt-1"><%= @summary.avg_duration_ms %>ms</div>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-3">
        <div class="border border-gray-800 rounded p-3" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">calls / min</div>
          <div
            phx-hook="Chart"
            id="chart-calls-per-min"
            data-chart={Jason.encode!(@charts.calls_per_min)}
            style="height: 195px;"
          >
            <canvas></canvas>
          </div>
        </div>

        <div class="border border-gray-800 rounded p-3" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">tokens / min</div>
          <div
            phx-hook="Chart"
            id="chart-tokens-over-time"
            data-chart={Jason.encode!(@charts.tokens_over_time)}
            style="height: 195px;"
          >
            <canvas></canvas>
          </div>
        </div>

        <div class="border border-gray-800 rounded p-3" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">status mix</div>
          <div
            phx-hook="Chart"
            id="chart-status-dist"
            data-chart={Jason.encode!(@charts.status_dist)}
            style="height: 195px;"
          >
            <canvas></canvas>
          </div>
        </div>

        <div class="border border-gray-800 rounded p-3" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">top models</div>
          <div
            phx-hook="Chart"
            id="chart-models"
            data-chart={Jason.encode!(@charts.models)}
            style="height: 195px;"
          >
            <canvas></canvas>
          </div>
        </div>

        <div class="border border-gray-800 rounded p-3" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">kind</div>
          <%= if @charts.kinds.data.labels == [] do %>
            <div class="text-gray-500 text-xs italic flex items-center justify-center h-full">no data</div>
          <% else %>
            <div
              phx-hook="Chart"
              id="chart-kinds"
              data-chart={Jason.encode!(@charts.kinds)}
              style="height: 195px;"
            >
              <canvas></canvas>
            </div>
          <% end %>
        </div>

        <div class="border border-gray-800 rounded p-3" style="height: 240px;">
          <div class="text-xs uppercase tracking-wider text-gray-500 mb-2">duration histogram</div>
          <div
            phx-hook="Chart"
            id="chart-duration-hist"
            data-chart={Jason.encode!(@charts.duration_hist)}
            style="height: 195px;"
          >
            <canvas></canvas>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
