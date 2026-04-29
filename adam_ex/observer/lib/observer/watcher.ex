defmodule Observer.Watcher do
  @moduledoc """
  GenServer that tail-reads events.jsonl and broadcasts new events via PubSub.
  Polls every poll_interval_ms milliseconds. Tracks byte position so only
  new lines are processed on each poll.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    path = Application.get_env(:observer, :events_file, "/app/observer/events.jsonl")
    interval = Application.get_env(:observer, :poll_interval_ms, 500)

    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")

    # Load any events that already exist on startup
    {events, pos} = read_from(path, 0)
    Enum.each(events, &store_and_broadcast/1)

    send(self(), :poll)
    {:ok, %{path: path, position: pos, interval: interval}}
  end

  @impl true
  def handle_info(:poll, %{path: path, position: pos, interval: interval} = state) do
    {events, new_pos} = read_from(path, pos)
    Enum.each(events, &store_and_broadcast/1)
    Process.send_after(self(), :poll, interval)
    {:noreply, %{state | position: new_pos}}
  end

  # Read new content starting at byte offset `pos`.
  # Returns {[decoded_events], new_byte_position}.
  defp read_from(path, pos) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        :file.position(file, pos)
        content = IO.binread(file, :eof)
        File.close(file)

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
