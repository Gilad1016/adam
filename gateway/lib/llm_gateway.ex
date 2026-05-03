defmodule LlmGateway do
  @moduledoc """
  Transparent reverse proxy in front of Ollama. Logs every /api/chat call
  to SQLite and serves a debug UI listing the calls.

  ADAM has no awareness of this service — it simply points OLLAMA_URL at it.
  """
end
