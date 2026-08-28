defmodule DpExchange.Gemini.Feed do
  @moduledoc """
  This venue's subscription lifecycle — internal. The facade's `subscribe/2`,
  `unsubscribe/2`, `update_symbols/2`, `coverage/1` and `subscribe_notices/1` are served
  from here.

  ## Coverage is observed, never intended

  A symbol enters the coverage map when **a payload for it arrives**, never when it is
  subscribed. That exists because a venue once reported 325 symbols subscribed and
  confirmed while 174 were delivering; reporting the subscription would have said 325.

  A subscribed symbol that has delivered nothing is simply absent, which the facade
  documents as `:not_covered`.

  ## Sharding: the host shards this venue nine ways, and this package does not

  `gemini/feed.ex` in the host opens **nine sockets**, ten pairs each, because the endpoint
  it uses stopped accepting subscriptions past roughly that count. That is a real measured
  property — of the *old* endpoint.

  This package speaks `wss://ws.gemini.com`, where subscription is a single `subscribe`
  frame carrying a list of streams, and there is no documented per-connection limit. So
  there is **no shard arithmetic here**, and that is a claim with a hole in it worth
  naming: it has been exercised with a handful of symbols, not with 346. If a limit exists
  on the new endpoint it will be found by the first consumer to subscribe broadly, and the
  fix belongs here, in this package, where the measurement will live.

  Carrying the host's nine-way split across on the assumption that the new endpoint shares
  the old one's limit would be worse — nine connections where one may do, justified by a
  measurement of a different API.
  """

  use GenServer

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.Socket

  # WebSockex's own send window, which is not configurable. `update_symbols/2` can send an
  # unsubscribe *and* a subscribe, so one call can wait out two windows; the third is
  # headroom, because a `GenServer.call` timing out first would surface a slow socket as a
  # caller-side exit instead of the `{:error, :send_timeout}` that says "retry the batch".
  @frame_window_ms 5_000
  @call_timeout @frame_window_ms * 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts) do
    GenServer.call(feed, {:subscribe, symbols, Keyword.get(opts, :to, self())}, @call_timeout)
  end

  @spec unsubscribe(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(feed, symbols),
    do: GenServer.call(feed, {:unsubscribe, symbols}, @call_timeout)

  @spec update_symbols(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def update_symbols(feed, symbols),
    do: GenServer.call(feed, {:update_symbols, symbols}, @call_timeout)

  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed), do: GenServer.call(feed, :coverage)

  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed, opts),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       socket_opts: Keyword.take(opts, [:url, :environment]),
       # An already-established connection. Ordinary use leaves this nil and the feed
       # dials its own on first subscribe; it is set on reconnect, and by tests that need
       # the socket-bearing branches without reaching a venue.
       socket: Keyword.get(opts, :socket),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       delivering: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    state = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        wanted: MapSet.union(state.wanted, MapSet.new(symbols))
    }

    case ensure_socket(state) do
      {:ok, state} -> {:reply, Socket.subscribe(state.socket, symbols), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, symbols}, _from, %{socket: nil} = state) do
    {:reply, :ok, drop(state, symbols)}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    {:reply, Socket.unsubscribe(state.socket, symbols), drop(state, symbols)}
  end

  def handle_call({:update_symbols, symbols}, _from, state) do
    wanted = MapSet.new(symbols)
    added = state.wanted |> then(&MapSet.difference(wanted, &1)) |> MapSet.to_list()
    removed = wanted |> then(&MapSet.difference(state.wanted, &1)) |> MapSet.to_list()

    state = %{state | wanted: wanted, delivering: Map.take(state.delivering, symbols)}

    {:reply, apply_delta(state, added, removed), state}
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and
    # the facade documents absence as `:not_covered`.
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:dp_exchange, :gemini, %Notice{} = notice}, state) do
    fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :gemini, quote_struct} = message, state) do
    fan_out(state.subscribers, message)

    {:noreply,
     %{
       state
       | delivering: Map.put(state.delivering, quote_struct.symbol, :os.system_time(:millisecond))
     }}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp apply_delta(%{socket: nil}, _added, _removed), do: :ok

  defp apply_delta(state, added, removed) do
    with :ok <- Socket.unsubscribe(state.socket, removed) do
      Socket.subscribe(state.socket, added)
    end
  end

  defp ensure_socket(%{socket: socket} = state) when is_pid(socket), do: {:ok, state}

  defp ensure_socket(state) do
    case Socket.start_link(Keyword.put(state.socket_opts, :subscriber, self())) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop(state, symbols) do
    %{
      state
      | wanted: MapSet.difference(state.wanted, MapSet.new(symbols)),
        delivering: Map.drop(state.delivering, symbols)
    }
  end

  # A dead subscriber stops delivery. The venue must not accumulate events for a process
  # that no longer exists.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn pid -> if Process.alive?(pid), do: send(pid, message) end)
  end
end
