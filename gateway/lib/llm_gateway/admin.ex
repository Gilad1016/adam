defmodule LlmGateway.Admin do
  @env_path "/app/host/.env"
  @prompts_dir "/app/host/prompts"
  @memory_dir "/app/host/memory"
  @knowledge_dir "/app/host/knowledge"
  @checkpoints_dir "/app/host/checkpoints"
  @defaults_dir "/app/host/priv/defaults"

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

  def wipe_memory, do: wipe_dir(memory_dir())
  def wipe_knowledge, do: wipe_dir(knowledge_dir())
  def wipe_checkpoints, do: wipe_dir(checkpoints_dir())

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
end
