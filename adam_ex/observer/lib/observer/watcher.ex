defmodule Observer.Watcher do
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    interval = Application.get_env(:observer, :poll_interval_ms, 500)

    case remote_url() do
      nil ->
        path = Application.get_env(:observer, :events_file, "/app/observer/events.jsonl")

        {events, pos} =
          if File.exists?(path) do
            read_from(path, 0)
          else
            Logger.info("[Observer.Watcher] Waiting for events file at #{path}")
            {[], 0}
          end

        Enum.each(events, &store_and_broadcast/1)
        send(self(), :poll)
        {:ok, %{mode: :local, path: path, position: pos, interval: interval}}

      url ->
        :inets.start()
        :ssl.start()
        send(self(), :poll)
        {:ok, %{mode: :remote, url: url, cursor: 0, interval: interval}}
    end
  end

  @impl true
  def handle_info(:poll, %{mode: :local, path: path, position: pos, interval: interval} = state) do
    {events, new_pos} = read_from(path, pos)
    Enum.each(events, &store_and_broadcast/1)
    Process.send_after(self(), :poll, interval)
    {:noreply, %{state | position: new_pos}}
  end

  def handle_info(:poll, %{mode: :remote, url: url, cursor: cursor, interval: interval} = state) do
    new_cursor = poll_remote(url, cursor)
    Process.send_after(self(), :poll, interval)
    {:noreply, %{state | cursor: new_cursor}}
  end

  defp remote_url do
    case System.get_env("OBSERVER_REMOTE_URL") do
      nil -> Application.get_env(:observer, :remote_url)
      url -> url
    end
  end

  defp poll_remote(url, cursor) do
    request_url = String.to_charlist("#{url}?since=#{cursor}")

    case :httpc.request(:get, {request_url, []}, [], []) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        body_str = if is_list(body), do: List.to_string(body), else: body

        case Jason.decode(body_str) do
          {:ok, %{"events" => events, "next" => next}} ->
            Enum.each(events, &store_and_broadcast/1)
            next

          {:ok, _} ->
            Logger.warning("[Observer.Watcher] Unexpected remote response shape")
            cursor

          {:error, reason} ->
            Logger.warning("[Observer.Watcher] Failed to decode remote response: #{inspect(reason)}")
            cursor
        end

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        Logger.warning("[Observer.Watcher] Remote returned HTTP #{status}")
        cursor

      {:error, reason} ->
        Logger.warning("[Observer.Watcher] Remote HTTP error: #{inspect(reason)}")
        cursor
    end
  end

  defp read_from(path, pos) do
    cond do
      not File.exists?(path) ->
        {[], pos}

      true ->
        do_read(path, pos)
    end
  end

  defp do_read(path, pos) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        :file.position(file, pos)
        raw = IO.binread(file, :eof)
        File.close(file)

        content = if is_binary(raw), do: raw, else: ""
        new_pos = pos + byte_size(content)

        events =
          content
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, event} -> [event]
              _            -> []
            end
          end)

        {events, new_pos}

      {:error, reason} ->
        Logger.debug("[Observer.Watcher] Cannot open #{path}: #{inspect(reason)}")
        {[], pos}
    end
  end

  defp store_and_broadcast(event) do
    Observer.Store.push(event)
    Phoenix.PubSub.broadcast(Observer.PubSub, "events", {:new_event, event})
  end
end
