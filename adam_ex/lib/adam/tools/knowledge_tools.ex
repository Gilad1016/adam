defmodule Adam.Tools.KnowledgeTools do
  def write(%{"topic" => topic, "content" => content} = args) do
    tags = Map.get(args, "tags", [])
    tags = if is_binary(tags), do: String.split(tags, ",") |> Enum.map(&String.trim/1), else: tags
    Adam.Knowledge.write(topic, content, tags)
  end

  def read(%{"id" => id}) do
    case Adam.Knowledge.read(id) do
      nil -> "[ERROR: knowledge '#{id}' not found]"
      entry -> "#{entry["topic"]}\n\n#{entry["content"]}"
    end
  end

  def search(%{"query" => query}) do
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

  def list do
    case Adam.Knowledge.list() do
      "" -> "knowledge base is empty"
      listing -> listing
    end
  end

  def update(%{"id" => id, "content" => content}) do
    Adam.Knowledge.update(id, content)
  end
end
