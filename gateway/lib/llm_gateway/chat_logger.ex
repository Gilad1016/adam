defmodule LlmGateway.ChatLogger do
  @moduledoc """
  Plug that schedules a DB insert *after* the proxy has sent the response.
  The insert runs in a Task so the request never blocks on the database.
  All errors are swallowed — logging must never affect the proxy contract.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      Task.start(fn -> persist(conn) end)
      conn
    end)
  end

  defp persist(conn) do
    case conn.assigns[:proxy] do
      nil -> :ok
      proxy -> insert_call(proxy)
    end
  rescue
    e -> IO.warn("[gateway] logger crashed: #{inspect(e)}")
  end

  defp insert_call(proxy) do
    parsed_req = safe_decode(proxy.request_body)
    parsed_resp = safe_decode(proxy.response_body)

    attrs = %{
      request_id: Ecto.UUID.generate(),
      model: get_string(parsed_req, "model"),
      request: proxy.request_body,
      response: proxy.response_body,
      status: proxy.status,
      duration_ms: proxy.duration_ms,
      error: proxy.error,
      stream: parsed_req["stream"] == true,
      prompt_tokens: get_int(parsed_resp, "prompt_eval_count"),
      completion_tokens: get_int(parsed_resp, "eval_count"),
      tool_call_count: count_tool_calls(parsed_resp)
    }

    case LlmGateway.Calls.insert(attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> IO.warn("[gateway] insert failed: #{inspect(reason)}")
    end
  end

  defp safe_decode(nil), do: %{}

  defp safe_decode(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp safe_decode(_), do: %{}

  defp get_string(map, key) do
    case map[key] do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp get_int(map, key) do
    case map[key] do
      v when is_integer(v) -> v
      _ -> nil
    end
  end

  defp count_tool_calls(%{"message" => %{"tool_calls" => calls}}) when is_list(calls),
    do: length(calls)

  defp count_tool_calls(_), do: 0
end
