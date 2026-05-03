defmodule Adam.LLM do
  def think(system_prompt, context, tools \\ [], opts \\ []) when is_binary(context) do
    think_messages(system_prompt, [%{role: "user", content: context}], tools, opts)
  end

  def think_messages(system_prompt, messages, tools \\ [], opts \\ []) when is_list(messages) do
    model = model()
    kind = Keyword.get(opts, :kind, "agent.think")

    full = [%{role: "system", content: system_prompt} | messages]

    body =
      %{model: model, messages: full, stream: false}
      |> maybe_add_tools(tools)

    # Local Ollama can take several minutes on cold model load or large
    # seed-prefixed contexts (consolidation, self-critique). Keep generous.
    case Req.post(ollama_url() <> "/api/chat",
           json: body,
           headers: [{"x-adam-kind", kind}],
           receive_timeout: 600_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        parse_response(resp)

      {:ok, %{status: status}} ->
        %{content: "[LLM ERROR: status #{status}]", tool_calls: [], tokens: 0, cost: cost()}

      {:error, err} ->
        %{content: "[LLM ERROR: #{inspect(err)}]", tool_calls: [], tokens: 0, cost: cost()}
    end
  end

  def ensure_models do
    models = [Application.get_env(:adam, :model)]

    results =
      Enum.map(models, fn model ->
        IO.puts("[ADAM] Pulling model #{model} (this can take a while on first run)...")
        t0 = System.monotonic_time(:second)

        result =
          case Req.post(ollama_url() <> "/api/pull",
                 json: %{name: model, stream: false},
                 receive_timeout: 1_800_000
               ) do
            {:ok, %{status: 200}} -> "#{model} ready"
            {:ok, %{status: status}} -> "#{model} FAILED (status #{status})"
            {:error, err} -> "#{model} FAILED (#{inspect(err)})"
          end

        IO.puts("[ADAM] #{result} (#{System.monotonic_time(:second) - t0}s)")
        result
      end)

    Enum.join(results, ", ")
  end

  defp parse_response(resp) do
    message = resp["message"] || %{}
    content = message["content"] || ""
    tool_calls =
      message["tool_calls"]
      |> parse_tool_calls()
      |> maybe_parse_inline_tool_calls(content)
    tokens = (resp["eval_count"] || 0) + (resp["prompt_eval_count"] || 0)

    %{
      content: content,
      tool_calls: tool_calls,
      tokens: tokens,
      cost: cost()
    }
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      func = call["function"] || %{}
      %{name: func["name"], arguments: func["arguments"] || %{}}
    end)
  end

  # Fallback for small models that emit tool calls inside `content` as JSON
  # rather than via the structured `tool_calls` field. Conservative: only
  # fires when the structured field is empty and content matches a known shape.
  defp maybe_parse_inline_tool_calls(tool_calls, _content) when tool_calls != [], do: tool_calls

  defp maybe_parse_inline_tool_calls([], content) when is_binary(content) do
    case extract_json_object(content) do
      {:ok, %{"name" => name, "arguments" => args}} when is_binary(name) ->
        [%{name: name, arguments: args || %{}}]

      {:ok, %{"function" => %{"name" => name, "arguments" => args}}} when is_binary(name) ->
        [%{name: name, arguments: args || %{}}]

      {:ok, %{"tool" => name, "arguments" => args}} when is_binary(name) ->
        [%{name: name, arguments: args || %{}}]

      _ ->
        []
    end
  end

  defp maybe_parse_inline_tool_calls([], _), do: []

  defp extract_json_object(content) do
    case :binary.match(content, "{") do
      :nomatch ->
        :error

      {start, _} ->
        rest = binary_part(content, start, byte_size(content) - start)
        try_decode_balanced(rest)
    end
  end

  defp try_decode_balanced(str) do
    # Try progressively shorter prefixes ending at a `}` until one parses.
    indices =
      for {?\}, i} <- Enum.with_index(:binary.bin_to_list(str)), do: i

    Enum.reduce_while(Enum.reverse(indices), :error, fn i, _acc ->
      candidate = binary_part(str, 0, i + 1)

      case Jason.decode(candidate) do
        {:ok, %{} = obj} -> {:halt, {:ok, obj}}
        _ -> {:cont, :error}
      end
    end)
  end

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp model, do: Application.get_env(:adam, :model)

  defp cost, do: Application.get_env(:adam, :cost)

  defp ollama_url, do: Application.get_env(:adam, :ollama_url)
end
