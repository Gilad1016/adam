defmodule LlmGatewayWeb.EventsController do
  @moduledoc """
  Pre-router plug that intercepts `POST /events/tuning` and persists the
  event as a row in the calls table so it shows up in the `/calls`
  dashboard inline with LLM call rows.

  Body is JSON of the form:

      {
        "name": "sleep_threshold",
        "value": 0.75,
        "previous": 0.85,
        "reason": "operator: ...",
        "source": "operator",
        "ts": 1714900000
      }

  Mounted before Plug.Parsers/Plug.Session so we can read the raw body
  ourselves and never crash the gateway because of a malformed event.
  Any other path passes through to the Phoenix router.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(_), do: []

  @impl true
  def call(%Plug.Conn{method: "POST", path_info: ["events", "tuning"]} = conn, _opts) do
    conn
    |> handle_tuning()
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp handle_tuning(conn) do
    with {:ok, body, conn} <- read_full_body(conn, ""),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      insert_tuning_row(decoded)
      send_resp(conn, 200, "{}")
    else
      _ ->
        send_resp(conn, 400, ~s({"error":"bad_request"}))
    end
  rescue
    e ->
      IO.warn("[gateway] tuning event handler crashed: #{inspect(e)}")
      send_resp(conn, 400, ~s({"error":"server_error"}))
  end

  defp insert_tuning_row(event) do
    source = event["source"] || "unknown"

    request_json =
      case Jason.encode(event) do
        {:ok, j} -> j
        _ -> "{}"
      end

    # Note: inserted_at is auto-populated by the schema's timestamps macro.
    # Calls.insert/1 only casts the @cast_fields; the row's `inserted_at`
    # will be DateTime.utc_now() at insert time, which is fine since ADAM
    # POSTs the event right after the change happens.
    attrs = %{
      request_id: Ecto.UUID.generate(),
      model: nil,
      request: request_json,
      response: nil,
      status: 200,
      duration_ms: 0,
      error: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      tool_call_count: nil,
      stream: false,
      kind: "tuning." <> to_string(source)
    }

    case LlmGateway.Calls.insert(attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> IO.warn("[gateway] tuning insert failed: #{inspect(reason)}")
    end
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, _} = err -> err
    end
  end
end
