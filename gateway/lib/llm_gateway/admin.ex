defmodule LlmGateway.Admin do
  @env_path "/app/host/.env"
  @prompts_dir "/app/host/prompts"
  @memory_dir "/app/host/memory"
  @knowledge_dir "/app/host/knowledge"
  @checkpoints_dir "/app/host/checkpoints"
  @defaults_dir "/app/host/priv/defaults/prompts"

  def env_path, do: System.get_env("ADAM_ENV_FILE", @env_path)
  def prompts_dir, do: System.get_env("ADAM_PROMPTS_DIR", @prompts_dir)
  def memory_dir, do: System.get_env("ADAM_MEMORY_DIR", @memory_dir)
  def knowledge_dir, do: System.get_env("ADAM_KNOWLEDGE_DIR", @knowledge_dir)
  def checkpoints_dir, do: System.get_env("ADAM_CHECKPOINTS_DIR", @checkpoints_dir)
  def defaults_dir, do: System.get_env("ADAM_DEFAULTS_DIR", @defaults_dir)

  def read_env do
    case File.read(env_path()) do
      {:ok, content} -> parse_env(content)
      {:error, _} -> []
    end
  end

  defp parse_env(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      cond do
        String.starts_with?(line, "#") or line == "" ->
          %{kind: :raw, idx: idx, raw: line}

        true ->
          case String.split(line, "=", parts: 2) do
            [k, v] -> %{kind: :pair, idx: idx, key: String.trim(k), value: v, raw: line}
            _ -> %{kind: :raw, idx: idx, raw: line}
          end
      end
    end)
  end

  def update_env_value(key, new_value) when is_binary(key) and is_binary(new_value) do
    entries = read_env()

    new_entries =
      Enum.map(entries, fn
        %{kind: :pair, key: ^key} = e -> %{e | value: new_value, raw: key <> "=" <> new_value}
        e -> e
      end)

    write_env(new_entries)
  end

  defp write_env(entries) do
    body = entries |> Enum.map(& &1.raw) |> Enum.join("\n")
    File.write(env_path(), body <> "\n")
  end

  def read_prompt(name) when name in ["system", "goals"] do
    File.read(Path.join(prompts_dir(), name <> ".md"))
  end

  def write_prompt(name, content) when name in ["system", "goals"] and is_binary(content) do
    File.write(Path.join(prompts_dir(), name <> ".md"), content)
  end

  @doc "Read ADAM's current narrative identity. Empty string if none yet."
  def narrative do
    path = Path.join(memory_dir(), "narrative.md")

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      _ -> ""
    end
  end

  def wipe_memory, do: wipe_dir(memory_dir())
  def wipe_knowledge, do: wipe_dir(knowledge_dir())
  def wipe_checkpoints, do: wipe_dir(checkpoints_dir())

  def wipe_calls do
    LlmGateway.Repo.delete_all(LlmGateway.Calls)
    Phoenix.PubSub.broadcast(LlmGateway.PubSub, "calls", :calls_wiped)
    :ok
  end

  def wipe_dir(dir) when is_binary(dir) do
    abs = ensure_safe!(dir)

    cond do
      not File.exists?(abs) ->
        :ok

      not File.dir?(abs) ->
        {:error, :not_a_dir}

      true ->
        for entry <- File.ls!(abs) do
          path = Path.join(abs, entry)
          File.rm_rf!(path)
        end

        :ok
    end
  end

  def factory_reset do
    wipe_memory()
    wipe_knowledge()
    wipe_checkpoints()
    wipe_calls()
    restore_defaults()
    :ok
  end

  defp restore_defaults do
    for name <- ["system.md", "goals.md"] do
      src = Path.join(defaults_dir(), name)
      dst = Path.join(prompts_dir(), name)
      if File.exists?(src), do: File.cp!(src, dst)
    end
  end

  defp ensure_safe!(path) do
    abs = Path.expand(path)
    unless String.starts_with?(abs, "/app/host/"), do: raise("refuse to wipe unsafe path: #{abs}")
    abs
  end

  # ---- tuning ----
  #
  # The gateway can't call into Adam.Tuning directly (separate container, no
  # Erlang distribution) so it reads/writes the same files Adam.Tuning uses,
  # via the host bind-mount at /app/host/memory/. Adam.Tuning picks up the
  # new override on its next get/2 call.

  def tuning_knobs_path, do: Path.join(memory_dir(), "tuning_knobs.toon")
  def tuning_overrides_path, do: Path.join(memory_dir(), "tuning.toon")
  def tuning_history_path, do: Path.join(memory_dir(), "tuning_history.toon")

  @doc "Knob registry mirrored from Adam.Tuning.dump_registry/0."
  def tuning_knobs do
    case read_toon(tuning_knobs_path()) do
      %{"knobs" => knobs} when is_map(knobs) -> knobs
      _ -> %{}
    end
  end

  @doc "Current operator overrides — map of knob_name (string) to value."
  def tuning_overrides do
    case read_toon(tuning_overrides_path()) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  @doc "Audit log entries (list of maps), oldest first."
  def tuning_history do
    case read_toon(tuning_history_path()) do
      %{"entries" => entries} when is_list(entries) -> entries
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Effective value for a knob: override-or-default. Mirrors Adam.Tuning.get/1."
  def tuning_value(name) when is_binary(name) do
    overrides = tuning_overrides()

    case Map.fetch(overrides, name) do
      {:ok, v} ->
        v

      :error ->
        case Map.fetch(tuning_knobs(), name) do
          {:ok, %{"default" => d}} -> d
          _ -> nil
        end
    end
  end

  @doc """
  Operator override. Validates against the dumped registry's min/max bounds.
  Refuses knobs marked `validator_present: true` because we can't run Adam's
  validator from here.
  """
  def tuning_set(name, value, reason) when is_binary(name) and is_binary(reason) do
    knobs = tuning_knobs()

    with {:ok, spec} <- fetch_knob(knobs, name),
         :ok <- check_validator(spec),
         :ok <- check_bounds(spec, value) do
      previous = tuning_value(name)
      overrides = Map.put(tuning_overrides(), name, value)

      with :ok <- write_toon(tuning_overrides_path(), overrides),
           :ok <- append_tuning_history(name, value, previous, reason, "operator") do
        {:ok, value}
      end
    end
  end

  @doc "Restore a knob to its registry default and record an audit entry."
  def tuning_restore_default(name, reason \\ "operator: restore to default")
      when is_binary(name) do
    knobs = tuning_knobs()

    with {:ok, spec} <- fetch_knob(knobs, name) do
      default = Map.get(spec, "default")
      previous = tuning_value(name)
      overrides = Map.delete(tuning_overrides(), name)

      with :ok <- write_toon(tuning_overrides_path(), overrides),
           :ok <- append_tuning_history(name, default, previous, reason, "operator") do
        {:ok, default}
      end
    end
  end

  @doc """
  Roll back the last `n` changes for a knob (file-based mirror of
  Adam.Tuning.rollback/2). Sets the value to the `previous` of the oldest
  reverted entry.
  """
  def tuning_rollback(name, n \\ 1) when is_binary(name) and is_integer(n) and n >= 1 do
    knob_entries =
      tuning_history()
      |> Enum.filter(&(&1["name"] == name))

    last_n =
      knob_entries
      |> Enum.reverse()
      |> Enum.take(n)

    case last_n do
      [] ->
        {:error, :no_history}

      _ ->
        target = List.last(last_n)["previous"]
        knobs = tuning_knobs()

        case fetch_knob(knobs, name) do
          {:ok, spec} ->
            previous = tuning_value(name)

            overrides =
              if is_nil(target) or target == Map.get(spec, "default") do
                Map.delete(tuning_overrides(), name)
              else
                Map.put(tuning_overrides(), name, target)
              end

            reason = "rollback (#{length(last_n)} steps)"

            with :ok <- write_toon(tuning_overrides_path(), overrides),
                 :ok <- append_tuning_history(name, target, previous, reason, "operator") do
              {:ok, target}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp fetch_knob(knobs, name) do
    case Map.fetch(knobs, name) do
      {:ok, spec} when is_map(spec) -> {:ok, spec}
      _ -> {:error, :unknown_knob}
    end
  end

  defp check_validator(%{"validator_present" => true}), do: {:error, :validator_required}
  defp check_validator(_), do: :ok

  defp check_bounds(%{"min" => lo, "max" => hi}, v)
       when is_number(v) and is_number(lo) and is_number(hi) do
    if v >= lo and v <= hi, do: :ok, else: {:error, {:out_of_bounds, lo, hi}}
  end

  defp check_bounds(_, _), do: {:error, :invalid_value}

  defp append_tuning_history(name, value, previous, reason, source) do
    entry = %{
      "name" => name,
      "value" => value,
      "previous" => previous,
      "reason" => reason,
      "source" => source,
      "ts" => System.os_time(:second)
    }

    entries = tuning_history() ++ [entry]
    entries = Enum.take(entries, -1000)
    write_toon(tuning_history_path(), %{"entries" => entries})
  end

  defp read_toon(path) do
    with {:ok, content} <- File.read(path),
         trimmed <- String.trim(content),
         true <- trimmed != "",
         {:ok, decoded} <- Jason.decode(trimmed) do
      decoded
    else
      _ -> nil
    end
  end

  defp write_toon(path, data) do
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(data) do
      {:ok, body} -> File.write(path, body)
      {:error, reason} -> {:error, reason}
    end
  end
end
