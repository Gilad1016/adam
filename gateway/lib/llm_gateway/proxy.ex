defmodule LlmGateway.Proxy do
  @moduledoc """
  Transparent reverse proxy plug. Forwards request body to upstream Ollama,
  returns response verbatim.

  Stashes the raw request body, response body, status, duration, and any
  transport error on `conn.assigns[:proxy]` so a downstream plug
  (LlmGateway.ChatLogger) can persist the call.
  """

  import Plug.Conn

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization
                 te trailers transfer-encoding upgrade)
  @drop_response_headers @hop_by_hop ++ ~w(content-length)

  def init(opts), do: opts

  def call(conn, _opts) do
    case read_full_body(conn, "") do
      {:ok, body, conn} ->
        upstream = upstream_url(conn)
        headers = forwardable_request_headers(conn.req_headers)
        method = method_atom(conn.method)

        t0 = System.monotonic_time(:millisecond)

        result =
          Req.request(
            method: method,
            url: upstream,
            headers: headers,
            body: body,
            # Local Ollama calls with seed-prefixed context can take several minutes
            # on cold model load or deep consolidation; must be >= ADAM's own timeout.
            receive_timeout: 600_000,
            decode_body: false,
            retry: false
          )

        duration_ms = System.monotonic_time(:millisecond) - t0
        finalize(conn, body, result, duration_ms)

      {:error, reason} ->
        send_resp(conn, 400, "could not read request body: #{inspect(reason)}")
    end
  end

  defp finalize(conn, req_body, {:ok, %Req.Response{} = resp}, duration_ms) do
    body = to_string(resp.body)

    conn
    |> assign(:proxy, %{
      request_body: req_body,
      response_body: body,
      status: resp.status,
      duration_ms: duration_ms,
      error: nil,
      path: conn.request_path,
      req_headers: conn.req_headers
    })
    |> put_response_headers(resp.headers)
    |> send_resp(resp.status, body)
  end

  defp finalize(conn, req_body, {:error, err}, duration_ms) do
    msg = "upstream error: #{inspect(err)}"

    conn
    |> assign(:proxy, %{
      request_body: req_body,
      response_body: nil,
      status: 502,
      duration_ms: duration_ms,
      error: msg,
      path: conn.request_path,
      req_headers: conn.req_headers
    })
    |> put_resp_content_type("text/plain")
    |> send_resp(502, msg)
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, _} = err -> err
    end
  end

  defp upstream_url(conn) do
    base = Application.get_env(:llm_gateway, :ollama_url, "http://ollama:11434")
    qs = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    base <> conn.request_path <> qs
  end

  defp forwardable_request_headers(headers) do
    Enum.reject(headers, fn {k, _} ->
      kdown = String.downcase(k)
      kdown in @hop_by_hop or kdown == "host"
    end)
  end

  defp put_response_headers(conn, headers) when is_map(headers) do
    Enum.reduce(headers, conn, fn {k, vs}, acc ->
      kdown = k |> to_string() |> String.downcase()

      if kdown in @drop_response_headers do
        acc
      else
        Enum.reduce(List.wrap(vs), acc, fn v, c ->
          put_resp_header(c, kdown, to_string(v))
        end)
      end
    end)
  end

  defp put_response_headers(conn, headers) when is_list(headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc ->
      kdown = k |> to_string() |> String.downcase()
      if kdown in @drop_response_headers, do: acc, else: put_resp_header(acc, kdown, to_string(v))
    end)
  end

  defp put_response_headers(conn, _), do: conn

  defp method_atom(m), do: m |> String.downcase() |> String.to_atom()
end
