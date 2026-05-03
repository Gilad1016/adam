defmodule Adam.Tools.Web do
  def search(%{"query" => query}) when is_binary(query) do
    case Req.get("https://html.duckduckgo.com/html/",
           params: [q: query],
           headers: [{"user-agent", "ADAM/1.0"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        parse_ddg_results(body)

      {:ok, %{status: status}} ->
        "[SEARCH ERROR: status #{status}]"

      {:error, err} ->
        "[SEARCH ERROR: #{inspect(err)}]"
    end
  end

  def search(args), do: "[ERROR: web_search requires 'query' string, got #{inspect(args)}]"

  def read(%{"url" => url}) when is_binary(url) do
    case Req.get(url, headers: [{"user-agent", "ADAM/1.0"}], receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        body
        |> extract_text()
        |> String.slice(0, 4000)

      {:ok, %{status: status}} ->
        "[WEB READ ERROR: status #{status}]"

      {:error, err} ->
        "[WEB READ ERROR: #{inspect(err)}]"
    end
  end

  def read(args), do: "[ERROR: web_read requires 'url' string, got #{inspect(args)}]"

  defp parse_ddg_results(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("a.result__a")
        |> Enum.take(5)
        |> Enum.map(fn el ->
          title = Floki.text(el) |> String.trim()
          href = Floki.attribute(el, "href") |> List.first("")
          "- #{title}: #{href}"
        end)
        |> Enum.join("\n")
        |> case do
          "" -> "no results found"
          results -> results
        end

      _ ->
        "no results found"
    end
  end

  defp extract_text(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("body")
        |> Floki.text(sep: "\n")
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim()

      _ ->
        html
    end
  end
end
