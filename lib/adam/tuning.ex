defmodule Adam.Tuning do
  @moduledoc """
  Runtime-mutable knobs with bounds, stability locks, and audit history.

  Each knob has:
    - default: baked-in safe value
    - min, max: hard bounds; out-of-range writes rejected
    - stability_hours: minimum interval between successive `tune/3` calls
      for the same knob (operator `set/3` bypasses)

  Storage:
    - /app/memory/tuning.toon         current overrides (knob_name => value)
    - /app/memory/tuning_history.toon  append-only log of every change

  Read path: Adam.Tuning.get(:knob_name) returns override-or-default.
  """

  @knobs %{
    sleep_threshold: %{
      default: 0.85, min: 0.6, max: 0.99, stability_hours: 6,
      desc: "Tiredness above this triggers a sleep cycle."
    },
    consolidation_min_iterations: %{
      default: 20, min: 5, max: 200, stability_hours: 4,
      desc: "Minimum iterations between deep consolidations."
    },
    summarize_min_chars: %{
      default: 200, min: 50, max: 2000, stability_hours: 4,
      desc: "Minimum content length before infra LLM calls fire; below this they skip."
    },
    sleep_regression_window_seconds: %{
      default: 86_400, min: 3_600, max: 604_800, stability_hours: 24,
      desc: "How far back to consider agent tunings for sleep regression check (seconds)."
    },
    sleep_regression_threshold_pct: %{
      default: 0.15, min: 0.05, max: 0.50, stability_hours: 24,
      desc: "Valence drop fraction (0..1) that triggers automatic rollback."
    },
    sleep_valence_sample_size: %{
      default: 20, min: 5, max: 200, stability_hours: 24,
      desc: "How many recent valence samples to mean for sleep pre/post comparison."
    }
  }

  @tuning_file "/app/memory/tuning.toon"
  @history_file "/app/memory/tuning_history.toon"
  @registry_file "/app/memory/tuning_knobs.toon"

  def knobs, do: @knobs

  @doc """
  Dump the knob registry to disk so external services (e.g. the gateway admin
  page) that can't import this module can still see defaults, bounds, and
  descriptions. Called from `Adam.start/2` on boot.

  Each knob entry includes a `validator_present` flag — true for knobs whose
  acceptance depends on a runtime validator (e.g. drive-weight vectors).
  External writers must treat `validator_present: true` knobs as read-only
  beyond rollback/restore-default.
  """
  def dump_registry do
    payload = %{
      "knobs" =>
        for {name, spec} <- @knobs, into: %{} do
          {Atom.to_string(name),
           %{
             "default" => spec.default,
             "min" => Map.get(spec, :min),
             "max" => Map.get(spec, :max),
             "stability_hours" => spec.stability_hours,
             "desc" => spec.desc,
             "validator_present" => Map.get(spec, :validator, false) != false
           }}
        end
    }

    File.mkdir_p!(Path.dirname(@registry_file))
    File.write!(@registry_file, Adam.Toon.encode(payload))
    :ok
  rescue
    _ -> :error
  end

  @doc "Read the current value for a knob — override or default."
  def get(name, fallback \\ nil) do
    cond do
      Map.has_key?(@knobs, name) ->
        case Map.fetch(load_overrides(), Atom.to_string(name)) do
          {:ok, v} -> v
          :error -> @knobs[name].default
        end

      fallback != nil ->
        fallback

      true ->
        raise ArgumentError, "Unknown tuning knob: #{inspect(name)}"
    end
  end

  @doc "Operator override — bypasses stability lock."
  def set(name, value, reason \\ "operator") do
    do_change(name, value, reason, :operator)
  end

  @doc "Agent path — enforces stability lock; requires a reason."
  def tune(name, value, reason) when is_binary(reason) and byte_size(reason) > 0 do
    spec = Map.get(@knobs, name)

    cond do
      is_nil(spec) ->
        {:error, :unknown_knob}

      not within_bounds?(value, spec) ->
        {:error, {:out_of_bounds, spec.min, spec.max}}

      time_since_last_change(name) < spec.stability_hours * 3600 ->
        {:error, :stability_lock}

      true ->
        do_change(name, value, reason, :agent)
    end
  end

  def tune(_, _, _), do: {:error, :reason_required}

  @doc "Replay history; useful for tests and rollback."
  def history, do: load_history()

  @doc "Roll back the last `n` changes for a knob."
  def rollback(name, n \\ 1) do
    entries =
      load_history()
      |> Enum.filter(&(&1["name"] == Atom.to_string(name)))
      |> Enum.reverse()
      |> Enum.take(n)

    case entries do
      [] ->
        {:error, :no_history}

      _ ->
        target = List.last(entries)["previous"]
        do_change(name, target, "rollback (#{length(entries)} steps)", :rollback)
    end
  end

  # ---- internals ----

  defp do_change(name, value, reason, source) do
    spec = Map.get(@knobs, name)

    cond do
      is_nil(spec) ->
        {:error, :unknown_knob}

      not within_bounds?(value, spec) ->
        {:error, {:out_of_bounds, spec.min, spec.max}}

      true ->
        previous = get(name)
        overrides = Map.put(load_overrides(), Atom.to_string(name), value)
        save_overrides(overrides)
        append_history(%{
          "name" => Atom.to_string(name),
          "value" => value,
          "previous" => previous,
          "reason" => reason,
          "source" => Atom.to_string(source),
          "ts" => System.os_time(:second)
        })
        {:ok, value}
    end
  end

  defp within_bounds?(v, %{min: lo, max: hi}) when is_number(v),
    do: v >= lo and v <= hi
  defp within_bounds?(_, _), do: false

  defp time_since_last_change(name) do
    last =
      load_history()
      |> Enum.filter(&(&1["name"] == Atom.to_string(name)))
      |> List.last()

    case last do
      %{"ts" => ts} -> System.os_time(:second) - ts
      _ -> :infinity
    end
  end

  defp load_overrides do
    case File.read(@tuning_file) do
      {:ok, content} ->
        try do
          case Adam.Toon.decode(content) do
            m when is_map(m) -> m
            _ -> %{}
          end
        rescue
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_overrides(map) do
    File.mkdir_p!(Path.dirname(@tuning_file))
    File.write!(@tuning_file, Adam.Toon.encode(map))
  end

  defp load_history do
    case File.read(@history_file) do
      {:ok, content} ->
        try do
          case Adam.Toon.decode(content) do
            l when is_list(l) -> l
            %{"entries" => entries} when is_list(entries) -> entries
            _ -> []
          end
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end

  defp append_history(entry) do
    File.mkdir_p!(Path.dirname(@history_file))
    entries = load_history() ++ [entry]
    # Cap history at 1000 entries to keep file bounded
    entries = Enum.take(entries, -1000)
    File.write!(@history_file, Adam.Toon.encode(%{"entries" => entries}))
  end
end
