defmodule LlmGateway.Repo.Migrations.CreateCalls do
  use Ecto.Migration

  def change do
    create table(:calls) do
      add :request_id, :string, null: false
      add :model, :string
      add :request, :text, null: false
      add :response, :text
      add :status, :integer, null: false
      add :duration_ms, :integer, null: false
      add :error, :text
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :tool_call_count, :integer
      add :stream, :boolean, default: false, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:calls, [:request_id])
    create index(:calls, [:inserted_at])
  end
end
