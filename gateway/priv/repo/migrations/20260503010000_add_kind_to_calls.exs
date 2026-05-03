defmodule LlmGateway.Repo.Migrations.AddKindToCalls do
  use Ecto.Migration

  def change do
    alter table(:calls) do
      add :kind, :string, null: false, default: "agent"
    end

    create index(:calls, [:kind])
  end
end
