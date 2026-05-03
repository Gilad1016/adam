defmodule LlmGateway.Release do
  @moduledoc """
  Runs Ecto migrations on application boot. Idempotent — safe to call repeatedly.
  Keeps the operator-side simple: bring the container up, schema is right.
  """

  @app :llm_gateway

  def migrate do
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp repos do
    Application.load(@app)
    Application.fetch_env!(@app, :ecto_repos)
  end
end
