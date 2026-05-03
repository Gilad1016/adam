defmodule Adam.Knowledge do
  @knowledge_dir "/app/knowledge"
  @index_file "/app/knowledge/index.toon"

  def init do
    File.mkdir_p!(@knowledge_dir)
    unless File.exists?(@index_file), do: save_index([])
  end

  def write(topic, content, tags \\ []) do
    index = load_index()
    id = generate_id()
    now = System.os_time(:second)

    entry = %{
      "id" => id,
      "topic" => topic,
      "content" => content,
      "tags" => tags,
      "created" => now,
      "updated" => now
    }

    entry_path = Path.join(@knowledge_dir, "#{id}.toon")
    File.write!(entry_path, Adam.Toon.encode(entry))

    index_entry = %{"id" => id, "topic" => topic, "tags" => Enum.join(tags, ";"), "updated" => now}
    save_index([index_entry | index])

    # Generate and persist a vector embedding for this entry (best-effort).
    embed_text = "#{topic} #{content}"
    Task.start(fn -> Adam.Embeddings.embed_and_store(id, embed_text) end)

    "stored knowledge '#{topic}' (id: #{id})"
  end

  def read(id) do
    path = Path.join(@knowledge_dir, "#{id}.toon")

    if File.exists?(path) do
      path |> File.read!() |> Adam.Toon.decode()
    else
      nil
    end
  end

  def search(query) do
    query_lower = String.downcase(query)
    terms = String.split(query_lower)

    load_index()
    |> Enum.filter(fn entry ->
      text = String.downcase("#{entry["topic"]} #{entry["tags"]}")
      Enum.any?(terms, &String.contains?(text, &1))
    end)
    |> Enum.take(10)
  end

  def list do
    load_index()
    |> Enum.take(20)
    |> Enum.map(fn e -> "#{e["id"]}: #{e["topic"]}" end)
    |> Enum.join("\n")
  end

  def update(id, content) do
    path = Path.join(@knowledge_dir, "#{id}.toon")

    if File.exists?(path) do
      entry = path |> File.read!() |> Adam.Toon.decode()
      entry = Map.merge(entry, %{"content" => content, "updated" => System.os_time(:second)})
      File.write!(path, Adam.Toon.encode(entry))

      index =
        load_index()
        |> Enum.map(fn e ->
          if e["id"] == id, do: Map.put(e, "updated", entry["updated"]), else: e
        end)

      save_index(index)
      "updated knowledge #{id}"
    else
      "[ERROR: knowledge #{id} not found]"
    end
  end

  def delete(id) do
    path = Path.join(@knowledge_dir, "#{id}.toon")
    File.rm(path)
    index = load_index() |> Enum.reject(&(&1["id"] == id))
    save_index(index)
    "deleted knowledge #{id}"
  end

  def count, do: length(load_index())

  def load_index do
    if File.exists?(@index_file) do
      content = File.read!(@index_file)
      if String.trim(content) == "" do
        []
      else
        case Adam.Toon.decode(content) do
          list when is_list(list) -> list
          _ -> []
        end
      end
    else
      []
    end
  end

  defp save_index(index) do
    File.write!(@index_file, Adam.Toon.encode(index))
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false) |> String.slice(0, 8)
  end
end
