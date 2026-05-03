defmodule LlmGateway.Repo do
  use Ecto.Repo,
    otp_app: :llm_gateway,
    adapter: Ecto.Adapters.SQLite3
end
