defmodule Adam.Interrupts do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(_), do: {:ok, %{alarms: %{}, last_email_check: 0}}

  def check_all, do: GenServer.call(__MODULE__, :check_all, 60_000)
  def has_pending?, do: GenServer.call(__MODULE__, :has_pending?)
  def add_alarm(args), do: GenServer.call(__MODULE__, {:add_alarm, args})
  def remove_alarm(args), do: GenServer.call(__MODULE__, {:remove_alarm, args})
  def list_alarms, do: GenServer.call(__MODULE__, :list_alarms)

  def handle_call(:check_all, _from, state) do
    now = System.os_time(:second)
    interrupts = []

    {fired, remaining} =
      Enum.split_with(state.alarms, fn {_name, alarm} -> alarm.fire_at <= now end)

    interrupts =
      interrupts ++
        Enum.map(fired, fn {name, alarm} ->
          "[ALARM] #{name}: #{alarm.message}"
        end)

    {emails, state} =
      if now - state.last_email_check > 120 do
        msgs = Adam.EmailClient.check_inbox()
        {msgs, %{state | last_email_check: now}}
      else
        {[], state}
      end

    email_interrupts =
      Enum.map(emails, fn msg ->
        "[EMAIL from #{msg["from"]}] #{msg["subject"]}: #{msg["body"]}"
      end)

    state = %{state | alarms: Map.new(remaining)}

    {:reply, %{interrupts: interrupts ++ email_interrupts, emails: emails}, state}
  end

  def handle_call(:has_pending?, _from, state) do
    now = System.os_time(:second)
    has_alarms = Enum.any?(state.alarms, fn {_name, alarm} -> alarm.fire_at <= now end)
    {:reply, has_alarms, state}
  end

  def handle_call({:add_alarm, %{"name" => name, "minutes" => minutes} = args}, _from, state)
      when is_binary(name) and is_integer(minutes) do
    message = Map.get(args, "message", "alarm fired") |> to_string()
    fire_at = System.os_time(:second) + minutes * 60
    alarm = %{fire_at: fire_at, message: message}
    state = %{state | alarms: Map.put(state.alarms, name, alarm)}
    {:reply, "alarm '#{name}' set for #{minutes} minutes", state}
  end

  def handle_call({:add_alarm, args}, _from, state) do
    {:reply, "[ERROR: set_alarm requires 'name' string and 'minutes' integer, got #{inspect(args)}]", state}
  end

  def handle_call({:remove_alarm, %{"name" => name}}, _from, state) when is_binary(name) do
    if Map.has_key?(state.alarms, name) do
      state = %{state | alarms: Map.delete(state.alarms, name)}
      {:reply, "removed alarm '#{name}'", state}
    else
      {:reply, "[ERROR: alarm '#{name}' not found]", state}
    end
  end

  def handle_call({:remove_alarm, args}, _from, state) do
    {:reply, "[ERROR: remove_alarm requires 'name' string, got #{inspect(args)}]", state}
  end

  def handle_call(:list_alarms, _from, state) do
    now = System.os_time(:second)

    result =
      state.alarms
      |> Enum.map(fn {name, alarm} ->
        remaining = max(0, alarm.fire_at - now)
        "#{name}: #{alarm.message} (in #{div(remaining, 60)}m)"
      end)
      |> case do
        [] -> "no active alarms"
        alarms -> Enum.join(alarms, "\n")
      end

    {:reply, result, state}
  end
end
