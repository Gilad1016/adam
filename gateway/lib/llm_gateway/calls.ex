defmodule LlmGateway.Calls do
  @moduledoc """
  One row per LLM call. Append-only.

  Stores the raw request and response JSON so any future analytic can be
  derived without re-running the call. A few obvious fields are denormalized
  at insert time (model, tokens, tool count) to keep the list view fast and
  give future analytics free indexes.
  """

  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias LlmGateway.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "calls" do
    field :request_id, :string
    field :model, :string
    field :request, :string
    field :response, :string
    field :status, :integer
    field :duration_ms, :integer
    field :error, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :tool_call_count, :integer
    field :stream, :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast_fields ~w(request_id model request response status duration_ms error
                  prompt_tokens completion_tokens tool_call_count stream)a
  @required_fields ~w(request_id request status duration_ms)a

  def insert(attrs) do
    %__MODULE__{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> Repo.insert()
    |> case do
      {:ok, call} = ok ->
        Phoenix.PubSub.broadcast(LlmGateway.PubSub, "calls", {:new_call, call})
        ok

      err ->
        err
    end
  end

  def list(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per = Keyword.get(opts, :per, 50)
    offset = (page - 1) * per

    from(c in __MODULE__, order_by: [desc: c.id], limit: ^per, offset: ^offset)
    |> Repo.all()
  end

  def count, do: Repo.aggregate(__MODULE__, :count, :id)

  def get(id), do: Repo.get(__MODULE__, id)
end
