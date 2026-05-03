defmodule LlmGatewayWeb.ApiDispatcher do
  @moduledoc """
  Pre-router plug that intercepts `/api/*` requests, runs them through the
  proxy (with the chat-logger before-send hook for `/api/chat` only), and
  halts the pipeline. Any other path passes through to the Phoenix router.

  Mounted before Plug.Parsers and Plug.Session so the proxy can read the
  raw request body without it being consumed.
  """

  @behaviour Plug

  alias LlmGateway.{ChatLogger, Proxy}

  @impl true
  def init(_), do: []

  @impl true
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    conn
    |> maybe_log()
    |> Proxy.call([])
    |> Plug.Conn.halt()
  end

  def call(conn, _opts), do: conn

  defp maybe_log(%Plug.Conn{path_info: ["api", "chat"]} = conn), do: ChatLogger.call(conn, [])
  defp maybe_log(conn), do: conn
end
