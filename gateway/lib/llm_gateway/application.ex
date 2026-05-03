defmodule LlmGateway.Application do
  use Application

  @impl true
  def start(_type, _args) do
    ensure_data_dir!()

    children = [
      LlmGateway.Repo,
      {Phoenix.PubSub, name: LlmGateway.PubSub},
      LlmGateway.SystemStats,
      LlmGatewayWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LlmGateway.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      LlmGateway.Release.migrate()
      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    LlmGatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp ensure_data_dir! do
    db = Application.get_env(:llm_gateway, LlmGateway.Repo, [])
    case Keyword.get(db, :database) do
      nil -> :ok
      ":memory:" -> :ok
      path when is_binary(path) -> File.mkdir_p!(Path.dirname(path))
      _ -> :ok
    end
  end
end
