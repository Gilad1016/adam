defmodule LlmGateway.SystemStats do
  @moduledoc """
  Polls host CPU/memory (via bind-mounted /proc) and GPU (via nvidia-smi) every
  2 seconds and broadcasts a snapshot on the "system_stats" PubSub topic.

  CPU % is computed as a delta between consecutive readings — the previous raw
  /proc/stat snapshot is kept in process state.
  """

  use GenServer

  @poll_interval_ms 2000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def latest, do: GenServer.call(__MODULE__, :latest)

  @impl true
  def init(_) do
    state = %{prev_cpu: nil, latest: %{}}
    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {cpu, prev_cpu} = read_cpu(state.prev_cpu)
    mem = read_memory()
    gpus = read_gpus()

    snap = %{
      ts: DateTime.utc_now(),
      cpu: cpu,
      memory: mem,
      gpus: gpus
    }

    Phoenix.PubSub.broadcast(LlmGateway.PubSub, "system_stats", {:system_stats, snap})
    schedule_tick()
    {:noreply, %{state | prev_cpu: prev_cpu, latest: snap}}
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}

  defp schedule_tick, do: Process.send_after(self(), :tick, @poll_interval_ms)

  defp proc_path(p), do: Path.join(System.get_env("HOST_PROC", "/host/proc"), p)

  # CPU: parse /proc/stat first line (aggregate) and per-cpu lines.
  # Returns {%{percent: float, per_core: [float]}, raw_for_next}
  defp read_cpu(prev) do
    case File.read(proc_path("stat")) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        agg =
          Enum.find(lines, fn l -> String.starts_with?(l, "cpu ") end)
          |> parse_cpu_line()

        cores =
          lines
          |> Enum.filter(&Regex.match?(~r/^cpu\d+ /, &1))
          |> Enum.map(&parse_cpu_line/1)

        new_raw = %{agg: agg, cores: cores}

        case prev do
          nil ->
            {%{percent: 0.0, per_core: List.duplicate(0.0, length(cores))}, new_raw}

          %{agg: prev_agg, cores: prev_cores} ->
            pct = cpu_delta_pct(agg, prev_agg)

            per_core =
              Enum.zip(cores, prev_cores)
              |> Enum.map(fn {now, before} -> cpu_delta_pct(now, before) end)

            {%{percent: pct, per_core: per_core}, new_raw}
        end

      _ ->
        {%{percent: 0.0, per_core: []}, prev}
    end
  end

  # parse "cpu 1234 56 789 ..." -> %{user, nice, system, idle, iowait, irq, softirq, steal}
  defp parse_cpu_line(nil), do: nil

  defp parse_cpu_line(line) do
    [_label | rest] = String.split(line, ~r/\s+/, trim: true)
    nums = Enum.map(rest, fn s -> String.to_integer(s) end)
    [user, nice, system, idle, iowait, irq, softirq, steal | _] = nums ++ List.duplicate(0, 8)

    %{
      user: user,
      nice: nice,
      system: system,
      idle: idle,
      iowait: iowait,
      irq: irq,
      softirq: softirq,
      steal: steal
    }
  end

  defp cpu_delta_pct(nil, _), do: 0.0
  defp cpu_delta_pct(_, nil), do: 0.0

  defp cpu_delta_pct(now, before) do
    busy = now.user + now.nice + now.system + now.irq + now.softirq + now.steal
    busy_prev = before.user + before.nice + before.system + before.irq + before.softirq + before.steal
    total = busy + now.idle + now.iowait
    total_prev = busy_prev + before.idle + before.iowait
    d_total = total - total_prev
    d_busy = busy - busy_prev
    if d_total <= 0, do: 0.0, else: Float.round(d_busy * 100 / d_total, 1)
  end

  # Memory from /proc/meminfo: MemTotal, MemAvailable
  defp read_memory do
    case File.read(proc_path("meminfo")) do
      {:ok, content} ->
        kv =
          content
          |> String.split("\n")
          |> Enum.into(%{}, fn line ->
            case String.split(line, ":", parts: 2) do
              [k, v] -> {String.trim(k), String.trim(v)}
              _ -> {"", ""}
            end
          end)

        total_kb = parse_kb(kv["MemTotal"])
        avail_kb = parse_kb(kv["MemAvailable"])
        used_kb = total_kb - avail_kb

        %{
          total_mb: round(total_kb / 1024),
          used_mb: round(used_kb / 1024),
          percent: if(total_kb > 0, do: Float.round(used_kb * 100 / total_kb, 1), else: 0.0)
        }

      _ ->
        %{total_mb: 0, used_mb: 0, percent: 0.0}
    end
  end

  defp parse_kb(nil), do: 0

  defp parse_kb(s) do
    case String.split(s, " ", trim: true) do
      [n | _] ->
        case Integer.parse(n) do
          {v, _} -> v
          _ -> 0
        end

      _ ->
        0
    end
  end

  # GPUs via nvidia-smi
  defp read_gpus do
    cmd =
      "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,name --format=csv,noheader,nounits"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_gpu_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_gpu_line(line) do
    case String.split(line, ",") |> Enum.map(&String.trim/1) do
      [util, mem_used, mem_total, temp, power, name] ->
        %{
          util_pct: parse_float(util),
          vram_used_mb: parse_int(mem_used),
          vram_total_mb: parse_int(mem_total),
          temp_c: parse_int(temp),
          power_w: parse_float(power),
          name: name
        }

      _ ->
        nil
    end
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {v, _} -> v
      _ -> 0.0
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {v, _} -> v
      _ -> 0
    end
  end
end
