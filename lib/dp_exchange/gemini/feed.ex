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

  ## Coverage by kind is tracked from the struct that arrived, never from the channel

  `delivering_by_kind` buckets the same observed-arrival fact `coverage/1` reports, split
  by which of `Core.Types.Quote` or `Core.Types.TopOfBook` a message actually was;
  `coverage/1`'s own map is now derived from it, so the two cannot drift apart. The kind
  comes from a pattern match on the struct itself — never from the `wanted` set, a
  channel address, or anything this module ever asked for — because intent standing in
  for evidence is the exact failure `coverage_by_kind/1` exists to close. See
  `DpExchange.Gemini.coverage_by_kind/1` for the incident this closes and why it applies
  to a venue with one physical stream underneath two data kinds.

  A payload of a struct type this module does not recognise is still fanned out to
  subscribers — this module is not the place to decide a struct is uninteresting — but
  it is not counted toward `delivering_by_kind`, and so not toward `coverage/1` either.
  Counting an unrecognised kind as generic "something arrived" would be the same collapse
  one level removed: a symbol would read as covered without this module being able to say
  what for.

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

  ## The resubscribe timer's own failure path was silent — until now

  The section above fixed a silent coverage collapse by making this module re-issue its
  subscription unconditionally. Its own failure path repeated the exact shape it was built
  to close: before this fix, `grep -n "Notice.new(" lib/dp_exchange/gemini/feed.ex` matched
  nothing in this file at all — a resubscribe that kept failing every 60 seconds only ever
  reached a `Logger.warning`, and this is a file whose own moduledoc, one section up, exists
  because a log line is not something a consumer can subscribe to.

  `DpExchange.Core.PollingFeed`'s moduledoc records the sibling discovery for the poll-feed
  case — DpCryptoManagement's issue #21, where a feed answered nothing for hours while its
  own "delivered NOTHING" log line sat ungrepped — and its fix is the shape this module now
  borrows: a `notice_state: :ok | :dead` latch (`record_success/2` and
  `notify_delivering_nothing/3`), firing a `Core.Notice` on the transition INTO failure and
  a recovery notice on the transition back OUT, never once per tick for as long as an
  outage lasts. `dp_exchange_coinbase`'s `Feed` established the sibling case for THIS
  family — a channel subscribe that exhausted its retries without ever becoming delivery —
  using Core's `:coverage_change` kind for exactly that shape of fact: subscribed intent
  that did not become delivery. A periodic resubscribe that keeps failing is the same shape
  one level up: the intent is "keep what was already subscribed, subscribed", and it is not
  becoming delivery either.

  Coinbase's own notice there is one-shot — it fires once when retries are exhausted and
  carries no recovery counterpart, because that retry chain either succeeds silently or
  exhausts and is left for the next unconditional cycle to revisit. This module's
  resubscribe runs forever on a fixed timer rather than a bounded retry chain, so the
  stricter, `PollingFeed`-shaped latch applies here instead: `resubscribe_notice_state`
  tracks whether the last resubscribe attempt succeeded, a `:warning` notice fires exactly
  once on the first failure after a success (or after boot), and an `:info` recovery notice
  fires exactly once on the first success after a failure. The `Logger.warning` above is
  unchanged and still fires on every failing tick — that remains the correct "loud while it
  lasts" log behaviour; only a consumer-visible `Notice` is new, and it is deliberately
  quieter than the log beside it.

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

  alias DpExchange.Core.{Capabilities, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook}
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

  @spec coverage_by_kind(GenServer.server()) :: %{
          Capabilities.data_kind() => %{String.t() => :stream | :internal_poll | :not_covered}
        }
  def coverage_by_kind(feed), do: GenServer.call(feed, :coverage_by_kind)

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
       # Both of this venue's declared streamable kinds, pre-populated so
       # `coverage_by_kind/1` always answers with both keys — an absent key would read as
       # "unknown" where an empty map honestly reads as "nothing observed yet".
       delivering_by_kind: %{quotes: %{}, top_of_book: %{}},
       # Latches to `:dead` the instant a periodic resubscribe fails, and back to `:ok` on
       # the next one that succeeds — see the moduledoc's "the resubscribe timer's own
       # failure path was silent" section. `resubscribe/1` reads and writes this to fire a
       # `Core.Notice` exactly once per transition, matching `Core.PollingFeed`'s
       # `notice_state` field.
       resubscribe_notice_state: :ok
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

    state = %{state | wanted: wanted, delivering_by_kind: narrow_delivery(state, symbols)}

    {:reply, apply_delta(state, added, removed), state}
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and
    # the facade documents absence as `:not_covered`.
    {:reply, Map.new(all_delivering(state), fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call(:coverage_by_kind, _from, state) do
    by_kind =
      Map.new(state.delivering_by_kind, fn {kind, symbols} ->
        {kind, Map.new(symbols, fn {symbol, _at} -> {symbol, :stream} end)}
      end)

    {:reply, by_kind, state}
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

  def handle_info({:dp_exchange, :gemini, payload} = message, state) do
    fan_out(state.subscribers, message)
    {:noreply, track_delivery(state, payload)}
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
          resubscribe_recovered(state)

        {:error, reason} ->
          Logger.warning("[Gemini Feed] periodic resubscribe failed: #{inspect(reason)}")
          resubscribe_failed(state, reason)
      end
    else
      # Nothing was attempted — a dead socket or an empty `wanted` set is not a fact about
      # whether resubscribing works, so the latch is left exactly as it was. Only an actual
      # `Socket.subscribe/2` result may set or clear it.
      state
    end
  end

  defp resubscribe(state), do: state

  # Fires the recovery notice exactly once, on the transition back OUT of a latched
  # failure — see the moduledoc and `Core.PollingFeed.record_success/2`. An ordinary
  # successful resubscribe when nothing was ever latched fires nothing: a notice on every
  # succeeding tick would be as much of a storm as one on every failing tick.
  defp resubscribe_recovered(%{resubscribe_notice_state: :dead} = state) do
    notice =
      Notice.new(:coverage_change, :gemini,
        severity: :info,
        message: "periodic resubscribe has resumed succeeding"
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
    %{state | resubscribe_notice_state: :ok}
  end

  defp resubscribe_recovered(state), do: state

  # Fires the failure notice exactly once, on the transition INTO failure — see the
  # moduledoc and `Core.PollingFeed.notify_delivering_nothing/3`. The `Logger.warning`
  # above still fires on every failing tick; only this `Notice` latches, so a consumer
  # hears about the outage once rather than once a minute for as long as it lasts.
  defp resubscribe_failed(%{resubscribe_notice_state: :dead} = state, _reason), do: state

  defp resubscribe_failed(state, reason) do
    notice =
      Notice.new(:coverage_change, :gemini,
        severity: :warning,
        message: "periodic resubscribe failed",
        details: %{reason: inspect(reason)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
    %{state | resubscribe_notice_state: :dead}
  end

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
        delivering_by_kind:
          Map.new(state.delivering_by_kind, fn {kind, by_symbol} ->
            {kind, Map.drop(by_symbol, symbols)}
          end)
    }
  end

  defp narrow_delivery(state, symbols) do
    Map.new(state.delivering_by_kind, fn {kind, by_symbol} ->
      {kind, Map.take(by_symbol, symbols)}
    end)
  end

  # The union of every kind's delivery map — what `coverage/1` reports before the
  # `:stream` atom is stamped on. Deriving this from `delivering_by_kind` rather than
  # tracking it separately is what makes the union invariant hold by construction: there
  # is no second copy of "what arrived" that could drift from the by-kind breakdown.
  defp all_delivering(state) do
    Enum.reduce(state.delivering_by_kind, %{}, fn {_kind, by_symbol}, acc ->
      Map.merge(acc, by_symbol)
    end)
  end

  # Kind is derived strictly from the delivered struct's own type — never from a channel
  # name or subscription intent. See the moduledoc: intent standing in for evidence is
  # the exact failure `coverage_by_kind/1` exists to close, and deriving kind from
  # anything but the payload itself would reintroduce it one level down.
  defp track_delivery(state, %Quote{symbol: symbol}), do: put_delivery(state, :quotes, symbol)

  defp track_delivery(state, %TopOfBook{symbol: symbol}),
    do: put_delivery(state, :top_of_book, symbol)

  defp track_delivery(state, _other), do: state

  defp put_delivery(state, kind, symbol) do
    timestamp = :os.system_time(:millisecond)

    %{
      state
      | delivering_by_kind:
          Map.update!(state.delivering_by_kind, kind, &Map.put(&1, symbol, timestamp))
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
