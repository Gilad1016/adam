defmodule Adam.Tools.KnowledgeTools do
  def write(%{"topic" => topic, "content" => content} = args) when is_binary(topic) and is_binary(content) do
    tags = Map.get(args, "tags", [])
    tags =
      cond do
        is_binary(tags) -> String.split(tags, ",") |> Enum.map(&String.trim/1)
        is_list(tags) -> tags
        true -> []
      end
    Adam.Knowledge.write(topic, content, tags)
  end

  def write(args), do: "[ERROR: write_knowledge requires 'topic' and 'content', got #{inspect(args)}]"

  def read(%{"id" => id}) when is_binary(id) do
    case Adam.Knowledge.read(id) do
      nil -> "[ERROR: knowledge '#{id}' not found]"
      entry -> "#{entry["topic"]}\n\n#{entry["content"]}"
    end
  end

  def read(args), do: "[ERROR: read_knowledge requires 'id' string, got #{inspect(args)}]"

  def search(%{"query" => query}) when is_binary(query) do
    results = Adam.Knowledge.search(query)

    case results do
      [] ->
        "no knowledge found for '#{query}'"

      entries ->
        entries
        |> Enum.map(fn e -> "#{e["id"]}: #{e["topic"]}" end)
        |> Enum.join("\n")
    end
  end

  def search(args), do: "[ERROR: search_knowledge requires 'query' string, got #{inspect(args)}]"

  def list do
    case Adam.Knowledge.list() do
      "" -> "knowledge base is empty"
      listing -> listing
    end
  end

  def update(%{"id" => id, "content" => content}) when is_binary(id) and is_binary(content) do
    Adam.Knowledge.update(id, content)
  end

  def update(args), do: "[ERROR: update_knowledge requires 'id' and 'content', got #{inspect(args)}]"
end
