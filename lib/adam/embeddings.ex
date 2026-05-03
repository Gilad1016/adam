defmodule Adam.Embeddings do
  @embeddings_file "/app/knowledge/_embeddings.json"
  @embed_model "nomic-embed-text"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate an embedding vector for the given text via Ollama.
  Returns `{:ok, [float]}` or `{:error, reason}`.
  """
  def embed(text) when is_binary(text) do
    url = ollama_url() <> "/api/embed"
    body = %{model: @embed_model, input: text}

    case Req.post(url, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"embeddings" => [vector | _]}}} when is_list(vector) ->
        {:ok, vector}

      {:ok, %{status: status}} ->
        {:error, "embed HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Compute cosine similarity between two equal-length float vectors.
  Returns a float in [-1.0, 1.0]. Returns 0.0 for zero-magnitude vectors.
  """
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  @doc """
  Generate an embedding for `content` and persist it under `entry_id`.
  Silently ignores errors (Ollama unavailable, model not pulled, etc.).
  """
  def embed_and_store(entry_id, content) when is_binary(entry_id) and is_binary(content) do
    case embed(content) do
      {:ok, vector} ->
        store_embedding(entry_id, vector)
      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Rank `index` entries by vector similarity to `query_text`.

  Returns a list of `{score, item}` tuples sorted descending, limited to 5.
  Falls back to `[]` on any embedding error (caller should then use keyword scoring).
  """
  def recall(query_text, index) when is_binary(query_text) and is_list(index) do
    case embed(query_text) do
      {:ok, query_vec} ->
        stored = load_embeddings()
        score_by_vector(query_vec, index, stored)

      {:error, _reason} ->
        {:error, :embedding_unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp score_by_vector(query_vec, index, stored) do
    Enum.map(index, fn item ->
      entry_id = item["id"] || ""

      sim =
        case Map.fetch(stored, entry_id) do
          {:ok, vec} when is_list(vec) -> cosine_similarity(query_vec, vec)
          _ -> 0.0
        end

      {sim, item}
    end)
  end

  defp store_embedding(entry_id, vector) do
    stored = load_embeddings()
    updated = Map.put(stored, entry_id, vector)

    dir = Path.dirname(@embeddings_file)
    File.mkdir_p!(dir)
    File.write!(@embeddings_file, Jason.encode!(updated))

    :ok
  rescue
    _ -> :ok
  end

  defp load_embeddings do
    if File.exists?(@embeddings_file) do
      case File.read(@embeddings_file) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end
    else
      %{}
    end
  end

  defp ollama_url do
    System.get_env("OLLAMA_URL", "http://localhost:11434")
  end
end
