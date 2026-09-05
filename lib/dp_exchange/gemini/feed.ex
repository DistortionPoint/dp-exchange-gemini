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

  ## A reconnect that does not resubscribe is a coverage collapse with no error

  WebSockex reconnects a dropped socket on its own — `Socket.handle_disconnect/2` returns
  `{:reconnect, state}` — and a bare reconnect leaves it connected and subscribed to
  **nothing**, silently: a socket that is up and receiving nothing is not itself an error.
  `Socket`'s own state carries no memory of what was subscribed (`%{subscriber:,
  request_id:}`), so there was nothing to resend even if it tried, and this module's
  `wanted` MapSet — written on every `subscribe/3` — was never read by anything. The
  sequence a consumer would actually see is `:link_down` then `:link_up`, which reads as
  "recovered", followed by silence until someone notices a quiet chart. This is the same
  incident class `dp_exchange_coinbase`'s `Feed` moduledoc records under the same heading;
  the fix here is the same idea adapted to one socket instead of a shard set.

  This module now re-issues the current `wanted` set's subscription on a timer,
  unconditionally — not only after a detected reconnect, because a reconnect a consumer's
  process never learns about (a supervisor restart of `Socket` under `Feed`, for instance)
  is indistinguishable from one it does. Re-subscribing a stream the socket already carries
  costs one frame the venue ignores; not re-subscribing one it silently dropped costs this
  package's whole coverage until someone notices.

  ## `ensure_socket/1` connects inside `handle_call` — its timeout budget is chosen, not inherited

  `ensure_socket/1` calls `Socket.start_link/1` synchronously inside `handle_call`, and
  `Feed`/`SandboxFeed` are named, shared processes: the whole blocking window that connect
  can take is borne by every other consumer's `subscribe/3`, `unsubscribe/2` and
  `coverage/1` queued behind it, not only the caller that happened to trigger it — the
  `Feed` process itself is stuck, so the caller's own `@call_timeout` cannot help any of
  them.

  **The connect was never unbounded — that was the wrong diagnosis.** `websockex`'s own
  `WebSockex.Conn` bounds it already: measured from the vendored dependency,
  `@socket_connect_timeout_default` is `6_000`ms and `@socket_recv_timeout_default` is
  `5_000`ms (`deps/websockex/lib/websockex/conn.ex:10-11`), and both are read from the
  `opts` list passed to `WebSockex.start_link/4` (`conn.ex:98-100`). The real defect was
  that `Socket.start_link/1` passed **no opts at all**, so it inherited those defaults by
  accident rather than choosing them — and 6_000 + 5_000 = 11_000ms of connect, plus one
  `send_frame` for the subscribe that follows connecting (up to `@frame_window_ms`,
  5_000ms), is 16_000ms against this module's own 15_000ms `@call_timeout`: already over
  budget before any other overhead in that call is counted.

  `Socket.start_link/1` now sets `:socket_connect_timeout` and `:socket_recv_timeout`
  explicitly, chosen against that same budget rather than left to `websockex`'s general-
  purpose defaults: 3_000ms connect + 2_000ms recv + 5_000ms for the one frame send that
  follows is 10_000ms, leaving 5_000ms — a third of `@call_timeout` — for the GenServer
  call's own overhead. Both remain overridable through the `opts` `Socket.start_link/1`
  already accepts, for a deployment whose real connect time needs more room than this
  package's own budget assumed — `Feed.start_link/1`'s own `opts` forward
  `:socket_connect_timeout` and `:socket_recv_timeout` straight through, alongside `:url`
  and `:environment`.
  """

  use GenServer

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.Socket

  require Logger

  # WebSockex's own send window, which is not configurable. `update_symbols/2` can send an
  # unsubscribe *and* a subscribe, so one call can wait out two windows; the third is
  # headroom, because a `GenServer.call` timing out first would surface a slow socket as a
  # caller-side exit instead of the `{:error, :send_timeout}` that says "retry the batch".
  @frame_window_ms 5_000
  @call_timeout @frame_window_ms * 3

  # Re-issues the current `wanted` set's subscription on this cadence, unconditionally —
  # see the moduledoc on reconnects. Matches the interval `dp_exchange_coinbase` uses for
  # the same purpose; there is no measurement behind the number for either package, and
  # this one has not been tuned against a wide production scope.
  @resubscribe_interval_ms 60_000

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
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    {:ok,
     %{
       socket_opts:
         Keyword.take(opts, [
           :url,
           :environment,
           :socket_connect_timeout,
           :socket_recv_timeout
         ]),
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

  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)
    {:noreply, resubscribe(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Unconditional: sent whether or not a reconnect actually happened, because a socket
  # this process never saw go down (a supervisor restart underneath it, for one) reads
  # identically to a healthy connection from here. `wanted` is what this module already
  # tracks for exactly this purpose; a socket that is not up yet has nothing to resend to
  # and is left for the next tick or the caller that eventually re-subscribes it.
  defp resubscribe(%{socket: socket} = state) when is_pid(socket) do
    if Process.alive?(socket) and MapSet.size(state.wanted) > 0 do
      case Socket.subscribe(socket, MapSet.to_list(state.wanted)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Gemini Feed] periodic resubscribe failed: #{inspect(reason)}")
      end
    end

    state
  end

  defp resubscribe(state), do: state

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
  #
  # A subscriber may be a raw pid or a registered name — `subscribe/2`'s `to:` accepts
  # either, matching ordinary OTP practice (a consumer registering itself by name and
  # handing that name to a producer). `Process.alive?/1` only accepts a pid and raises on
  # anything else, so a registered-name subscriber crashed this whole GenServer on every
  # delivery (same defect, same fix, as `dp-exchange-coinbase`'s `Feed.fan_out/2` —
  # DpCryptoManagement's issue #15). Resolving first, uniformly, fixes both: a dead pid
  # resolves to itself and `Process.alive?/1` filters it; an unregistered name resolves
  # to `nil` and is silently skipped, the same as a dead subscriber already was.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case resolve_subscriber(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  defp resolve_subscriber(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_subscriber(name) when is_atom(name), do: Process.whereis(name)
end
