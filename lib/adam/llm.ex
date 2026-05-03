defmodule Adam.LLM do
  def think(system_prompt, context, tools \\ [], opts \\ []) do
    tier = Keyword.get(opts, :tier, "thinker")
    model = model_for_tier(tier)
    kind = Keyword.get(opts, :kind, "agent.think")

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: context}
    ]

    body =
      %{model: model, messages: messages, stream: false}
      |> maybe_add_tools(tools)

    # Local Ollama can take several minutes on cold model load or large
    # seed-prefixed contexts (consolidation, self-critique). Keep generous.
    case Req.post(ollama_url() <> "/api/chat",
           json: body,
           headers: [{"x-adam-kind", kind}],
           receive_timeout: 600_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        parse_response(resp, tier)

      {:ok, %{status: status}} ->
        %{content: "[LLM ERROR: status #{status}]", tool_calls: [], tokens: 0, tier: tier, cost: cost_for_tier(tier)}

      {:error, err} ->
        %{content: "[LLM ERROR: #{inspect(err)}]", tool_calls: [], tokens: 0, tier: tier, cost: cost_for_tier(tier)}
    end
  end

  def ensure_models do
    models = [
      Application.get_env(:adam, :thinker_model),
      Application.get_env(:adam, :actor_model)
    ]

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

  defp parse_response(resp, tier) do
    message = resp["message"] || %{}
    tool_calls = parse_tool_calls(message["tool_calls"])
    tokens = (resp["eval_count"] || 0) + (resp["prompt_eval_count"] || 0)

    %{
      content: message["content"] || "",
      tool_calls: tool_calls,
      tokens: tokens,
      tier: tier,
      cost: cost_for_tier(tier)
    }
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      func = call["function"] || %{}
      %{name: func["name"], arguments: func["arguments"] || %{}}
    end)
  end

  defp maybe_add_tools(body, []), do: body
  defp maybe_add_tools(body, tools), do: Map.put(body, :tools, tools)

  defp model_for_tier("actor"), do: Application.get_env(:adam, :actor_model)
  defp model_for_tier(_), do: Application.get_env(:adam, :thinker_model)

  defp cost_for_tier("actor"), do: Application.get_env(:adam, :actor_cost)
  defp cost_for_tier(_), do: Application.get_env(:adam, :thinker_cost)

  defp ollama_url, do: Application.get_env(:adam, :ollama_url)
end
