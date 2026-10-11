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
  by which of `Core.Types.Quote`, `Core.Types.TopOfBook` or `Core.Types.Trade` a message was;
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
  process never learns about (`Socket` reconnecting on its own, under WebSockex's own
  handling of a dropped connection, for instance) is indistinguishable from one it does.
  Re-subscribing a stream the socket already carries costs one frame the venue ignores;
  not re-subscribing one it silently dropped costs this package's whole coverage until
  someone notices.

  ## A reconnect resubscribes at once; the timer is the net

  On the timer alone, an ordinary reconnect meant up to `@resubscribe_interval_ms` (60s)
  of silence: the socket was back, carrying nothing, until the next tick. `Socket` now
  reports each RE-connect to this process (`{:dp_exchange, :gemini, :reconnected, pid}`),
  and this module resubscribes the moment it hears, without re-arming the timer. The timer
  still runs unconditionally, for what no report covers: a venue that quietly stops serving
  a stream on a connection that never dropped.

  ## A socket that is reconnecting is not sent to

  `Socket.handle_disconnect/2` sleeps its backoff (up to 30s) inside the socket process,
  and WebSockex answers no `send_frame/2` while it reconnects. So every send to such a
  socket blocked this process for the full 5s window and came back `:send_timeout`. That
  covered each timer tick (which also raised a "resubscribe failed" notice for a socket
  that was only reconnecting) and each consumer `subscribe/3`, `unsubscribe/2` or
  `update_symbols/2` that landed during the outage. `state.link_down?` is now set by the
  socket's `:link_down` and cleared by its `:reconnected`, and nothing is sent in between.
  Nothing is lost, because `wanted` is kept current regardless and a reconnected socket
  gets all of it at once. Both messages come from the one socket, in order, and a crashed
  socket's replacement starts with the flag cleared.

  ## A crashed socket is `Feed`'s crash too, unless `Feed` catches it — and now it does

  `ensure_socket/1` calls `Socket.start_link/1` from inside `Feed`'s own callback, which
  links the new socket to `Feed` the way `start_link` always does — this is not a
  supervised sibling `Feed` could lose independently, it is a linked child. Before this
  fix `Feed` never called `Process.flag(:trap_exit, true)`, so a socket that exited
  abnormally (an exception inside a WebSockex callback, or anything that killed the
  socket pid directly) sent an untrappable `EXIT` signal along that link and crashed
  `Feed` too — every subscriber, the whole `wanted` set, gone, restarted by
  `DpExchange.Gemini.Supervisor` from the STATIC `opts` it was given at tree-start, which
  never carry a consumer's later `subscribe/3` calls. Proven by linking a real process
  into a running `Feed` the way `ensure_socket/1` does and killing it with
  `Process.exit(pid, :kill)` — `:normal` would not have proven anything, since a
  non-trapping process ignores a peer's normal exit.

  `Feed` now traps exits, and a crashed socket is handled the same way a reconnect it
  never even noticed would be: `state.socket` is cleared, `delivering_by_kind` is reset
  (this venue has one socket carrying every kind `state.channels` asks for — `:quotes`
  and `:top_of_book` always, `:trades` too where opted in — so a crash costs all of them
  at once, not a partial set the way a per-shard venue's would), a `:link_down`
  `Core.Notice` reports it,
  and `resubscribe/1` — the same function the periodic timer already calls — attempts an
  immediate reconnect and resend of `wanted` (for the first crash in a run; a crash within
  30s of the previous one waits, doubling from 1s to 30s, so a socket that dies on connect is
  not redialled in a tight loop) rather than waiting out the next
  `@resubscribe_interval_ms` tick.

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
  follows is 10_000ms, leaving the rest of `@call_timeout` for the GenServer
  call's own overhead. Both remain overridable through the `opts` `Socket.start_link/1`
  already accepts, for a deployment whose real connect time needs more room than this
  package's own budget assumed — `Feed.start_link/1`'s own `opts` forward
  `:socket_connect_timeout` and `:socket_recv_timeout` straight through, alongside `:url`
  and `:environment`.

  ## `channels:` — opt into the trade tape; the default is unchanged

  `start_link/1` (and so `DpExchange.Gemini.Supervisor.start_link/1`, since its `opts`
  pass straight through) takes `:channels`, the family's own convention for this
  (`dp_exchange_coinbase`'s `Feed` established it): a non-empty list drawn from
  `capabilities().streamable`, defaulting to `[:quotes, :top_of_book]` — exactly what
  this feed delivered before `:trades` existed as a kind, so an existing consumer that
  never passes the option sees no change at all.

  Gemini has no separate channel for `:quotes` and `:top_of_book`: both come from the
  same `@bookTicker` frame (see `Socket`'s moduledoc), so this option's only real effect
  is whether `:trades` is in the list. When it is, this module also subscribes
  `{symbol}@trade` for every `wanted` symbol, alongside `@bookTicker` — added and kept
  through every path that builds a subscription (`subscribe/3`, `update_symbols/2`,
  `unsubscribe/2`, the periodic resubscribe, and a reconnect), never only at boot. A
  `Core.Types.Trade` is delivered for every print `@trade` carries; `:quotes` keeps
  meaning "the last-trade price CHANGED", the fix 0.2.85 made — this option adds a
  second, distinct stream rather than altering what the first one means.

  **No per-connection stream limit is enforced or documented for `wss://ws.gemini.com`**
  — see the moduledoc's "Sharding" section above, which already states this package has
  found none for the new endpoint at the scope it has been exercised with. Subscribing
  `:trades` doubles the number of streams this one socket carries per symbol (two
  addresses instead of one), not the number of sockets — this module still shards
  nothing — so there is no shard arithmetic to add here either. If a real limit exists
  on this endpoint, doubling the per-symbol stream count is the change most likely to
  find it, and the fix belongs here, in this package, once it is measured.

  A caller who asks for a kind this venue does not stream (anything outside
  `[:quotes, :top_of_book, :trades]`) gets an `ArgumentError` from `start_link/1` —
  fail closed, per this family's own rule, rather than starting a feed that silently
  never carries what was asked for.

  ## An `{:error, _}` from `subscribe/3` or `update_symbols/2` means nothing was recorded

  Both used to record the subscriber and the symbols first, then try to connect and send, and
  answer `{:error, _}` if that failed while leaving the record in place for the next
  resubscribe tick to dial and send. A caller told "error" reasonably gave up on the symbols
  (fell back to polling, reported the failure) and then received them anyway, from a
  connection it had been told did not exist, on a subscriber it had been told was not
  registered. The intent is now recorded only if the request succeeds. On failure the
  subscriber (unless already registered) and the new symbols are taken back; because a send
  that reported failure may have landed (`Socket.subscribe/3`), the new symbols are queued
  for a wire unsubscribe on the next tick, which skips any symbol wanted again by then. A
  failed `update_symbols/2` restores the previous wanted set and its delivery records stay
  narrowed to the requested one, so coverage under-reports for a moment rather than claiming
  delivery nobody saw. A caller that wants the symbols retries.

  `unsubscribe/2` is deliberately the other way: it narrows `wanted` even when the wire send
  fails, because "stop delivering these" is safe to apply at once, and the unsubscribe is
  retried on the tick.

  ## A subscriber that cannot be sent to is refused in the caller

  `to:` must be a pid or a registered name (an atom other than `nil`, `true` or `false`),
  which is all `Core.Fanout.resolve/1` has a clause for. Anything else used to be stored
  and raised `FunctionClauseError` inside this shared process on the first payload or notice
  sent to it. `subscribe/3` and `subscribe_notices/2` answer
  `{:error, {:invalid_subscriber, term}}` before the call, as bad symbols already answer
  `{:error, {:invalid_symbols, term}}`.

  ## A notice flood is throttled here

  `Socket` raises a notice per unreadable frame, per refused subscribe and per depth gap, and
  they were all forwarded. A field that stays malformed arrives at the stream's rate. For the
  kinds `:data_quality`, `:refusal` and `:degraded`, the first notice per
  `{kind, reason, symbol}` is forwarded at once and the rest within 30 seconds are counted,
  with the next one after the window carrying `details.suppressed`. The symbol is part of the
  key only if it is wanted, and the table is capped, so a venue-supplied string cannot grow
  it. `:link_up`, `:link_down` and `:coverage_change` are bounded by reconnect backoff and
  the resubscribe latch, and pass untouched. The data-path `:degraded` notice for a stalled
  subscriber is sent from `deliver/2`, not here, and already latches.
  """

  use GenServer

  alias DpExchange.Core.{Capabilities, Config, Fanout, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Gemini.{Socket, SymbolFormat}

  require Logger

  # WebSockex's own send window, which is not configurable. `update_symbols/2` can send an
  # unsubscribe *and* a subscribe on each socket channel, and with `:trades` on there are two
  # (`active_socket_channels/1`): four windows. The fifth is headroom, because a
  # `GenServer.call` timing out first would surface a slow socket as a caller-side exit
  # instead of the `{:error, :send_timeout}` that says "retry the batch". It was three, set
  # before `:trades` existed, so a slow socket with trades on exited the caller at 15s of a
  # possible 20s (found 2026-10-10). A first subscribe's connect (3s + 2s, see the moduledoc)
  # plus its two frames is 15s, inside the same bound.
  @frame_window_ms 5_000
  @max_socket_channels 2
  @call_timeout @frame_window_ms * (2 * @max_socket_channels + 1)

  # What `:channels` defaults to when a caller says nothing — exactly this feed's
  # behaviour before `:trades` existed as a kind. See the moduledoc's "`channels:`"
  # section.
  @default_channels [:quotes, :top_of_book]

  # The kinds this feed can be asked to carry. Not read from `DpExchange.Gemini.
  # capabilities().streamable` itself — `dp_exchange_coinbase`'s `Feed` sets the family
  # precedent of a local, literal list here rather than a dependency back onto the
  # facade module, which would need to compile before this one.
  @known_channels [:quotes, :top_of_book, :trades]

  # Re-issues the current `wanted` set's subscription on this cadence, unconditionally —
  # see the moduledoc on reconnects. Matches the interval `dp_exchange_coinbase` uses for
  # the same purpose; there is no measurement behind the number for either package, and
  # this one has not been tuned against a wide production scope.
  @resubscribe_interval_ms 60_000

  # Notices that arrive once per bad FRAME (`:data_quality`, `:refusal`) or per bad condition
  # that can repeat at stream rate (`:degraded`) are forwarded at most once per key per
  # window. See the moduledoc's "A notice flood". Lifecycle notices (`:link_up`,
  # `:link_down`, `:coverage_change`) are bounded by reconnect backoff and pass untouched.
  @throttled_notice_kinds [:data_quality, :refusal, :degraded]
  @notice_window_ms 30_000
  @max_notice_keys 4_096

  @doc """
  Starts the feed. See the moduledoc for the options it forwards to `Socket`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes `symbols` and registers `opts[:to]` (default: the caller) for their data.

  **`:ok` means it was recorded and the request went out; `{:error, _}` means nothing was
  recorded.** A failure to connect or to send used to leave the subscriber and the symbols
  registered anyway, to be dialled and sent on the next resubscribe tick: a caller told
  "error" reasonably gave up on the symbols and then received them. Now the registration is
  undone, and a symbol whose frame may have landed is queued for a wire unsubscribe so the
  venue stops streaming it. A caller that wants the symbols retries.

  Refuses what it cannot hold in the caller, before the shared feed process sees it:
  `{:error, {:invalid_symbols, term}}` (see `canonical_symbols/1`) and
  `{:error, {:invalid_subscriber, term}}` for a `:to` that is neither a pid nor a registered
  name.
  """
  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts) do
    with {:ok, symbols} <- canonical_symbols(symbols),
         {:ok, subscriber} <- valid_subscriber(Config.opt(opts, :to, self())) do
      GenServer.call(feed, {:subscribe, symbols, subscriber}, @call_timeout)
    end
  end

  @doc """
  Stops delivering `symbols` and sends the venue an unsubscribe for them.

  Unlike `subscribe/3`, a failed wire send still narrows what is wanted: the local effect
  (no more delivery, no coverage) is what the caller asked for and is safe to apply, and the
  unsubscribe is retried on the next resubscribe tick. The error reports the wire failure.
  """
  @spec unsubscribe(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(feed, symbols) do
    with {:ok, symbols} <- canonical_symbols(symbols),
         do: GenServer.call(feed, {:unsubscribe, symbols}, @call_timeout)
  end

  @doc """
  Makes `symbols` the whole wanted set.

  Like `subscribe/3`, `{:error, _}` means the wanted set is unchanged. Symbols that were to
  be added are queued for a wire unsubscribe in case their frame landed.
  """
  @spec update_symbols(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def update_symbols(feed, symbols) do
    with {:ok, symbols} <- canonical_symbols(symbols),
         do: GenServer.call(feed, {:update_symbols, symbols}, @call_timeout)
  end

  @doc """
  The subscriber as given if it is a pid or a registered name, or the refusal.

  That is all `Core.Fanout.resolve/1` has a clause for. Anything else (`"consumer"`,
  `{:via, ...}`, a ref) was accepted and raised `FunctionClauseError` inside this shared
  process on the first payload or notice sent to it, taking every other consumer's
  subscription with it. `nil` and booleans are atoms and would resolve to no process: a
  subscriber that silently receives nothing.

  Exposed so `DpExchange.Gemini.Fake` refuses exactly as the real feed does.
  """
  @spec valid_subscriber(term()) ::
          {:ok, pid() | atom()} | {:error, {:invalid_subscriber, term()}}
  def valid_subscriber(pid) when is_pid(pid), do: {:ok, pid}

  def valid_subscriber(name) when is_atom(name) and name not in [nil, true, false],
    do: {:ok, name}

  def valid_subscriber(other), do: {:error, {:invalid_subscriber, other}}

  @doc """
  The canonical, de-duplicated spelling this feed holds `symbols` in, or the refusal for a
  value it cannot hold.

  **Every symbol is held in its canonical spelling.** Frames are matched by the canonical
  symbol they decode to, and `wanted` held whatever the caller wrote. So
  `subscribe(["BTCUSD"])` subscribed `btcusd` on the wire and then dropped every frame for
  it as unwanted, because `"BTC-USD"` was not in the set.

  **Anything that is not a list of non-blank strings is refused here, in the caller.** It
  used to be passed into the `Feed` process, where `MapSet.new/1` raised on `"BTC-USD"` (a
  string where a list was meant) and `Socket.streams/2` raised on `:btc_usd` or `nil`. A
  `Feed` is one shared, named process: the raise crashed it, and its supervisor restarted it
  from the static options it was started with — taking every other consumer's subscription,
  subscriber and delivery record with it, for one caller's typo.

  Exposed so `DpExchange.Gemini.Fake` canonicalises and refuses exactly as the real feed does.
  """
  @spec canonical_symbols(term()) :: {:ok, [String.t()]} | {:error, {:invalid_symbols, term()}}
  def canonical_symbols(symbols) when is_list(symbols) do
    case Enum.reject(symbols, &(is_binary(&1) and String.trim(&1) != "")) do
      [] ->
        {:ok, symbols |> Enum.map(&canonical_symbol/1) |> Enum.uniq()}

      invalid ->
        {:error, {:invalid_symbols, invalid}}
    end
  end

  def canonical_symbols(other), do: {:error, {:invalid_symbols, other}}

  defp canonical_symbol(symbol) do
    symbol |> SymbolFormat.to_exchange_symbol() |> SymbolFormat.to_canonical_symbol()
  end

  # NOTE — reads carry `@call_timeout` explicitly, exactly as the writes above do.
  #
  # They used to take `GenServer.call/2`'s implicit five seconds, and that asymmetry is what
  # turned a bounded delay into a dead caller in dp-exchange-core issue #28: `coverage/1` is
  # the call a consumer's health check makes, so any moment this Feed was busy for longer
  # than five seconds turned a health check into an EXIT — killing the consumer's own
  # process when it read from inside its own `handle_call/3`. Asking whether the venue was
  # healthy was what made it unhealthy.
  #
  # The blocking is fixed at its sources rather than papered over here; this is the second
  # line of defence. A read that has to queue behind something should WAIT for it, never
  # die of it.
  @doc """
  Which symbols have delivered, observed and never intended. See the moduledoc.
  """
  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed), do: GenServer.call(feed, :coverage, @call_timeout)

  @doc """
  `coverage/1` split by data kind, always carrying every kind this venue streams.
  """
  @spec coverage_by_kind(GenServer.server()) :: %{
          Capabilities.data_kind() => %{String.t() => :stream | :internal_poll | :not_covered}
        }
  def coverage_by_kind(feed), do: GenServer.call(feed, :coverage_by_kind, @call_timeout)

  # `@call_timeout`, not `GenServer.call/2`'s five-second default.
  #
  # This was the one public call in this module left on the default, and it is the worst one
  # to leave short. `@call_timeout` is the authors' own statement of how long this feed may
  # legitimately take to answer, and every sibling call — `subscribe/3`, `unsubscribe/2`,
  # `update_symbols/2`, `coverage/1` — is allowed it on the same mailbox. A consumer
  # registers for notices at start-up, which is precisely when that mailbox is deepest: the
  # transport is coming up, symbols are being resolved, and this handler itself may replay a
  # notice to the newly-registered subscriber.
  #
  # A `GenServer.call/3` timeout exits in the CALLER, not in the feed. So the channel a host
  # uses to *hear that something is wrong* was the one call that could kill the host's
  # calling process for asking during exactly the conditions it exists to report.
  @doc """
  Registers `opts[:to]` (default: the caller) for this feed's notices.

  `{:error, {:invalid_subscriber, term}}` for a `:to` that is neither a pid nor a registered
  name, for the reason `subscribe/3` gives.
  """
  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def subscribe_notices(feed, opts) do
    with {:ok, subscriber} <- valid_subscriber(Config.opt(opts, :to, self())),
         do: GenServer.call(feed, {:subscribe_notices, subscriber}, @call_timeout)
  end

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    # `ensure_socket/1` calls `Socket.start_link/1` from inside a `Feed` callback, which
    # links the socket to `Feed` — see the moduledoc's "A crashed socket is Feed's crash
    # too" section. Without this flag an abnormal socket exit crashes `Feed` itself,
    # discarding every subscriber and the whole `wanted` set; `handle_info({:EXIT, _,
    # _}, _)` below is what this flag makes reachable at all.
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    channels = (Keyword.get(opts, :channels) || @default_channels) |> validate_channels!()

    {:ok,
     %{
       socket_opts:
         Keyword.take(opts, [
           :url,
           :environment,
           :socket_connect_timeout,
           :socket_recv_timeout
         ]),
       # See the moduledoc's "`channels:`" section. Read once, here, already validated —
       # every place that decides which `Socket` channels to carry (`active_channels/1`)
       # reads this rather than a module attribute, so a feed always acts on what its own
       # caller asked for.
       channels: channels,
       # An already-established connection. Ordinary use leaves this nil and the feed
       # dials its own on first subscribe; it is set on reconnect, and by tests that need
       # the socket-bearing branches without reaching a venue.
       socket: Keyword.get(opts, :socket),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       # Symbols whose wire unsubscribe failed, retried on the next resubscribe tick. Cleared
       # by any new connection, which carries no subscriptions. See `retry_unsubscribe/2`.
       unsubscribe_pending: MapSet.new(),
       # True between the socket's `:link_down` and its `:reconnected`. Nothing is sent to it
       # meanwhile — see the moduledoc's "A socket that is reconnecting is not sent to".
       link_down?: false,
       # Both of this venue's declared streamable kinds, pre-populated so
       # `coverage_by_kind/1` always answers with both keys — an absent key would read as
       # "unknown" where an empty map honestly reads as "nothing observed yet".
       delivering_by_kind: empty_delivery(),
       # Latches to `:dead` the instant a periodic resubscribe fails, and back to `:ok` on
       # the next one that succeeds — see the moduledoc's "the resubscribe timer's own
       # failure path was silent" section. `resubscribe/1` reads and writes this to fire a
       # `Core.Notice` exactly once per transition, matching `Core.PollingFeed`'s
       # `notice_state` field.
       resubscribe_notice_state: :ok,
       # Monitor references for pid subscribers, so a dead one is dropped rather than
       # walked on every message for the life of this feed — see the `:DOWN` clause and
       # `Core.Fanout.watch/2`. A registered-name subscriber never appears here.
       monitors: %{},
       # `{kind, reason, symbol}` => `{window start, suppressed count}` for the notice kinds in
       # `@throttled_notice_kinds`. Bounded: see `put_notice_seen/4`.
       notice_seen: %{},
       # Back-pressure, per `Core.Venue`'s `subscribe/2` doc and implemented by
       # `Core.Fanout`: `dropping` is the set of subscribers currently over their mailbox
       # bound, carried across calls so a stalled consumer produces one `:degraded` notice
       # when delivery to it stops and one when it resumes — never one per dropped message,
       # which would arrive at the rate of the stream it already cannot keep up with.
       dropping: MapSet.new(),
       max_queue_len: Fanout.max_queue_len!(opts, :gemini)
     }}
  end

  @impl true
  # `{:error, _}` leaves nothing registered — see `subscribe/3`. A failure to connect undoes
  # the registration. A failure to send undoes it too, keeps the socket this call dialled, and
  # queues the new symbols for a wire unsubscribe (`settle_subscribe/5`).
  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    registered = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        monitors: Fanout.watch(subscriber, state.monitors),
        wanted: MapSet.union(state.wanted, MapSet.new(symbols))
    }

    case ensure_socket(registered) do
      {:ok, connected} ->
        sent = when_linked(connected, &subscribe_channels(&1, symbols, connected))
        {:reply, sent, settle_subscribe(sent, connected, state, subscriber, symbols)}

      {:error, reason} ->
        {:reply, {:error, reason}, undo_registration(registered, state, subscriber, symbols)}
    end
  end

  def handle_call({:unsubscribe, symbols}, _from, %{socket: nil} = state) do
    {:reply, :ok, drop(state, symbols)}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    result = when_linked(state, &unsubscribe_channels(&1, symbols, state))
    {:reply, result, state |> drop(symbols) |> unsubscribe_later(result, symbols)}
  end

  # `{:error, _}` leaves the wanted set as it was — see `update_symbols/2`. The delivery
  # records stay narrowed to the new set: a record is only ever evidence that a frame arrived,
  # and dropping one for a symbol still wanted costs a reading until its next frame, where
  # keeping one for a symbol whose stream may have been cut would claim delivery nobody saw.
  def handle_call({:update_symbols, symbols}, _from, state) do
    wanted = MapSet.new(symbols)
    added = state.wanted |> then(&MapSet.difference(wanted, &1)) |> MapSet.to_list()
    removed = wanted |> then(&MapSet.difference(state.wanted, &1)) |> MapSet.to_list()

    updated = %{state | wanted: wanted, delivering_by_kind: narrow_delivery(state, symbols)}

    case apply_delta(updated, added, removed) do
      :ok ->
        {:reply, :ok, updated}

      {:error, _reason} = error ->
        {:reply, error, queue_unsubscribe(%{updated | wanted: state.wanted}, added)}
    end
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
    state = %{
      state
      | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber),
        monitors: Fanout.watch(subscriber, state.monitors)
    }

    {:reply, :ok, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  # A TRANSPORT drop is not a process death, and until this clause existed nothing here
  # noticed the difference. `Socket.handle_disconnect/2` returns `{:reconnect, state}`, so
  # the socket process survives and no `EXIT` ever reaches `isolate_crashed_socket/2` —
  # which meant the delivery records observed on the connection that just died went on
  # answering `:stream` for symbols arriving from nowhere, and a reconnect that restored the
  # socket while silently failing to restore a symbol left that symbol answering `:stream`
  # indefinitely. That is the 325-subscribed/174-delivering shape `coverage/1` was written
  # for, reappearing one level down. See `Core.Venue`'s `coverage/1` doc: observation is
  # scoped to the current transport session.
  #
  # One socket carries every kind this feed is configured for here (see `state.channels`
  # and the moduledoc's "`channels:`" section), so there is no partial loss to compute and
  # the whole map resets — the same shape `init/1` starts with, and the same reset the
  # crash path performs, for the same reason.
  def handle_info({:dp_exchange, :gemini, %Notice{kind: :link_down} = notice}, state) do
    fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
    {:noreply, %{state | delivering_by_kind: empty_delivery(), link_down?: true}}
  end

  # A subscriber that died. Dropped from both sets, and its monitor forgotten.
  #
  # Without this, nothing ever removed a subscriber pid: `Core.Fanout.resolve/1` skips a dead
  # one at send time, so no EVENTS accumulated — which is what the contract asks for and was
  # true — but the pid stayed for the life of this feed. A supervised consumer that restarts
  # leaves one behind on every restart, and `deliver/4` walks the whole set calling
  # `Process.alive?/1` once per message, so the cost is linear in how long the feed has been
  # up. Measured in Core 0.3.3: 0.095 us per fan-out against a clean set, 22.8 us against one
  # carrying a thousand dead pids.
  #
  # Only pids arrive here. A registered-name subscriber is deliberately never monitored — see
  # `Core.Fanout.watch/2` — because a name outlives the process holding it, and pruning on
  # its holder's death would silently unsubscribe a consumer its supervisor is about to
  # restart under the same name.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{
      state
      | subscribers: MapSet.delete(state.subscribers, pid),
        notice_subscribers: MapSet.delete(state.notice_subscribers, pid),
        monitors: Fanout.forget(pid, state.monitors)
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:dp_exchange, :gemini, %Notice{} = notice}, state) do
    case throttle_notice(state, notice) do
      {:forward, notice, state} ->
        fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
        {:noreply, state}

      {:suppress, state} ->
        {:noreply, state}
    end
  end

  # `track_delivery/2` runs whether or not the payload reached anybody. `coverage/1` reports
  # what the VENUE delivered to this package, not what this package forwarded — a symbol
  # whose frames are being dropped for a stalled consumer is still arriving, and reporting it
  # as `:not_covered` would blame the venue for a consumer's backlog.
  # **A payload for a symbol no longer wanted is dropped, not delivered or counted.** A venue
  # keeps sending for a moment after an unsubscribe, and those frames used to reach the
  # subscribers who had just asked to stop. Worse, they re-entered delivery tracking, which
  # `unsubscribe/2` had just pruned, and a streaming route has no staleness window. So one
  # late frame left `coverage/1` answering `:stream` for an unsubscribed symbol
  # indefinitely. Found 2026-09-27 by reading the path, the same shape `Core.PollingFeed`
  # had for an in-flight fetch.
  def handle_info({:dp_exchange, :gemini, payload} = message, state) do
    if unwanted?(payload, state.wanted) do
      {:noreply, state}
    else
      {:noreply, state |> deliver(message) |> track_delivery(payload)}
    end
  end

  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)
    {:noreply, resubscribe(state)}
  end

  # The live socket reconnected, and it carries no subscriptions now — see the moduledoc's
  # "A reconnect resubscribes at once; the timer is the net" section. The same work as a
  # timer tick, but the timer is NOT re-armed here: re-sending `:resubscribe` would start
  # a second timer chain beside the first. A report from a socket that is no longer
  # `state.socket` falls through to the catch-all.
  def handle_info({:dp_exchange, :gemini, :reconnected, socket}, %{socket: socket} = state) do
    {:noreply, resubscribe(%{state | link_down?: false, unsubscribe_pending: MapSet.new()})}
  end

  # The other half of `init/1`'s `Process.flag(:trap_exit, true)` — see the moduledoc's
  # "A crashed socket is Feed's crash too" section. `pid` matching `state.socket` is what
  # tells this apart from an `EXIT` this feed cannot attribute to anything it started; a
  # stale `EXIT` for a socket already replaced (its pid no longer `state.socket`) falls
  # through to the catch-all below and is correctly ignored.
  def handle_info({:EXIT, pid, reason}, %{socket: pid} = state) do
    {:noreply, isolate_crashed_socket(state, reason)}
  end

  # The delayed redial `isolate_crashed_socket/2` schedules once crashes come in a run. A
  # socket some other path already dialled in the meantime makes this a no-op.
  def handle_info(:redial_after_crash, %{socket: nil} = state),
    do: {:noreply, resubscribe(state)}

  def handle_info(_other, state), do: {:noreply, state}

  # Unconditional: sent whether or not a reconnect actually happened, because a socket
  # this process never saw go down reads identically to a healthy connection from here.
  # `wanted` is what this module already tracks for exactly this purpose.
  #
  # A `nil` socket is no longer left for "the next tick or the caller that eventually
  # re-subscribes it" alone — see the clause below this one: if anything is `wanted`,
  # this attempts to dial a fresh socket itself, which is what makes a crashed socket
  # (cleared by `isolate_crashed_socket/2`) actually recover instead of sitting `nil`
  # forever, since a socket this module never dialled has nothing for `Process.alive?/1`
  # to even check.
  defp resubscribe(%{socket: socket} = state) when is_pid(socket) do
    state = retry_unsubscribe(socket, state)

    if Process.alive?(socket) and not state.link_down? and MapSet.size(state.wanted) > 0 do
      case subscribe_channels(socket, MapSet.to_list(state.wanted), state) do
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

  # `state.socket` is `nil` and something is still `wanted` — either nothing has ever
  # subscribed (ordinary boot, `ensure_socket/1` has never run), or a socket crashed and
  # `isolate_crashed_socket/2` cleared it. Only the second case has anything to recover;
  # dialling in the first case costs nothing (the venue gets a connection with no
  # subscription frame, since `Socket.start_link/1` opens without one) but is not the
  # ordinary path — `ensure_socket/1` from `subscribe/3` normally wins the race. Recurses
  # into the `is_pid(socket)` clause above once a socket exists, so the actual `Socket.
  # subscribe/2` call — and the recovery/failure latch — only ever happens in one place.
  defp resubscribe(%{socket: nil} = state) do
    if MapSet.size(state.wanted) > 0 do
      case ensure_socket(state) do
        {:ok, state} ->
          resubscribe(state)

        {:error, reason} ->
          Logger.warning("[Gemini Feed] periodic reconnect failed: #{inspect(reason)}")
          resubscribe_failed(state, reason)
      end
    else
      state
    end
  end

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
  defp apply_delta(%{link_down?: true}, _added, _removed), do: :ok

  defp apply_delta(state, added, removed) do
    with :ok <- unsubscribe_channels(state.socket, removed, state) do
      subscribe_channels(state.socket, added, state)
    end
  end

  # Every `Socket` channel this feed currently carries — `@bookTicker` always, and
  # `@trade` too when `:trades` is in `state.channels`. See the moduledoc's "`channels:`"
  # section: Gemini has no separate channel for `:quotes`/`:top_of_book`, so those two
  # never change which `Socket` channels get used, only `:trades` does.
  # At most `@max_socket_channels`, which `@call_timeout` is sized against.
  defp active_socket_channels(state) do
    if :trades in state.channels, do: [:book_ticker, :trade], else: [:book_ticker]
  end

  # Issues `symbols` against every active `Socket` channel, in order, stopping at the
  # first failure — the same fail-fast shape `apply_delta/3` already used for its own
  # unsubscribe-then-subscribe pair, applied one level down to a call that may now be more
  # than one frame. A caller sees the first error; `wanted` (and, for unsubscribe,
  # `delivering_by_kind`) is already updated regardless, so nothing tracked here is lost —
  # only the wire send may be incomplete, and the next resubscribe tick re-issues
  # everything unconditionally, exactly as it already does for a single-channel miss.
  defp subscribe_channels(socket, symbols, state) do
    send_to_channels(socket, symbols, state, &Socket.subscribe/3)
  end

  defp unsubscribe_channels(socket, symbols, state) do
    send_to_channels(socket, symbols, state, &Socket.unsubscribe/3)
  end

  defp send_to_channels(socket, symbols, state, send) do
    Enum.reduce_while(active_socket_channels(state), :ok, fn channel, :ok ->
      case send.(socket, symbols, channel) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Fail closed, per this family's own rule: a `:channels` value naming a kind this venue
  # does not stream starts no feed at all, rather than one that silently never carries
  # what was asked for. See the moduledoc's "`channels:`" section and
  # `dp_exchange_coinbase.Feed`'s identically-shaped `validate_channels!/1`, the family
  # precedent this copies.
  defp validate_channels!(kinds) when is_list(kinds) and kinds != [] do
    case Enum.reject(kinds, &(&1 in @known_channels)) do
      [] ->
        Enum.uniq(kinds)

      unknown ->
        raise ArgumentError,
              "DpExchange.Gemini.Feed :channels must be drawn from #{inspect(@known_channels)} " <>
                "— the kinds capabilities().streamable declares. Got #{inspect(unknown)}. A " <>
                "kind this venue does not stream cannot be subscribed to by naming it."
    end
  end

  defp validate_channels!(value) do
    raise ArgumentError,
          "DpExchange.Gemini.Feed :channels must be a non-empty list drawn from " <>
            "#{inspect(@known_channels)}. Got #{inspect(value)}."
  end

  # A socket that is reconnecting is asleep in its backoff and answers no `send_frame/2`,
  # so a send would block this process for its whole 5s window. Answered `:ok` because
  # nothing is lost: `wanted` is already updated, and `:reconnected` re-issues all of it.
  defp when_linked(%{link_down?: true}, _send), do: :ok
  defp when_linked(%{socket: socket}, send), do: send.(socket)

  defp ensure_socket(%{socket: socket} = state) when is_pid(socket), do: {:ok, state}

  defp ensure_socket(state) do
    case Socket.start_link(Keyword.put(state.socket_opts, :subscriber, self())) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  # See the moduledoc's "A crashed socket is Feed's crash too" section and `handle_info(
  # {:EXIT, pid, reason}, %{socket: pid} = state)` above. This venue has one socket
  # carrying every kind this feed is configured for — unlike a sharded venue, there is no
  # partial loss to compute, the crash costs everything this feed was delivering, so
  # `delivering_by_kind` resets to the same empty shape `init/1` starts with rather than
  # being narrowed symbol-by-symbol the way `drop/2` narrows it for an ordinary
  # unsubscribe.
  defp isolate_crashed_socket(state, reason) do
    state = %{
      state
      | socket: nil,
        delivering_by_kind: empty_delivery(),
        link_down?: false,
        unsubscribe_pending: MapSet.new()
    }

    notify_socket_crashed(state, reason)

    # `resubscribe/1` — the identical function the periodic timer calls — reconnects and
    # resends `wanted` right away if anything is still wanted, rather than leaving this
    # feed silent until the next `@resubscribe_interval_ms` tick (60s by default).
    #
    # **Right away only for the first crash in a run.** Found 2026-10-10 by reading this
    # function: a socket that crashed on connect (a frame it cannot survive, a venue
    # rejecting the handshake) was redialled at once, crashed, and was redialled again —
    # a connect storm with no delay anywhere in it. A crash within `@crash_run_ms` of the
    # last one now waits, doubling from `@crash_base_delay_ms` to `@crash_max_delay_ms`.
    {run, state} = crash_run(state)

    case crash_redial_delay(run) do
      0 ->
        resubscribe(state)

      delay ->
        Process.send_after(self(), :redial_after_crash, delay)
        state
    end
  end

  @crash_run_ms 30_000
  @crash_base_delay_ms 1_000
  @crash_max_delay_ms 30_000

  # `{length of the current run of crashes, state}`. A crash more than `@crash_run_ms`
  # after the previous one starts a new run of 1. Read with `Map.get/3` so a state built
  # before this field existed (or by a test) starts a run.
  defp crash_run(state) do
    now = System.monotonic_time(:millisecond)

    run =
      case Map.get(state, :crash_run) do
        {count, last_at} when now - last_at < @crash_run_ms -> count + 1
        _none_or_stale -> 1
      end

    {run, Map.put(state, :crash_run, {run, now})}
  end

  @doc false
  @spec crash_redial_delay(pos_integer()) :: non_neg_integer()
  def crash_redial_delay(1), do: 0

  def crash_redial_delay(run),
    do: min(@crash_base_delay_ms * Integer.pow(2, min(run - 2, 5)), @crash_max_delay_ms)

  # The one crash-level event this module could not report before: every other notice
  # this module can send is a reply to a caller's own `subscribe/3`/`unsubscribe/2`
  # failing outright, or the periodic resubscribe's own latch. A socket crash is
  # asynchronous, with no caller waiting on it — without this, it is exactly the
  # "silent half-dead feed" this family's incidents are about,
  # discoverable only by a consumer polling `coverage/1` and noticing symbols it used to
  # see are gone. `:link_down` — see `dp_exchange_core`'s `Core.Notice` moduledoc,
  # "stated without naming the transport" — because this reports the CAUSE (the link
  # went down), distinct from the `:coverage_change` kind `resubscribe_failed/2` uses for
  # a resubscribe attempt that never became delivery.
  defp notify_socket_crashed(state, reason) do
    notice =
      Notice.new(:link_down, :gemini,
        severity: :warning,
        message: "socket crashed (#{inspect(reason)}) — reconnecting now",
        details: %{reason: inspect(reason)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
  end

  # **A wire unsubscribe that failed is retried, not forgotten.** `wanted` was narrowed
  # either way, so nothing reached the consumer, but the venue kept streaming the symbol to
  # this connection until it next reconnected, and nothing ever sent the unsubscribe again.
  # Found 2026-10-10.
  defp unsubscribe_later(state, :ok, _symbols), do: state

  defp unsubscribe_later(state, {:error, _reason}, symbols),
    do: %{
      state
      | unsubscribe_pending: MapSet.union(state.unsubscribe_pending, MapSet.new(symbols))
    }

  # A symbol wanted again since is left subscribed: retrying its old unsubscribe would undo
  # the newer subscribe.
  defp retry_unsubscribe(socket, state) do
    pending = MapSet.difference(state.unsubscribe_pending, state.wanted)

    cond do
      MapSet.size(pending) == 0 or state.link_down? or not Process.alive?(socket) ->
        %{state | unsubscribe_pending: pending}

      unsubscribe_channels(socket, MapSet.to_list(pending), state) == :ok ->
        %{state | unsubscribe_pending: MapSet.new()}

      true ->
        %{state | unsubscribe_pending: pending}
    end
  end

  # **A notice flood.** `Socket` raises one notice per unreadable frame (`data_quality`), per
  # refused subscribe (`refusal`) and per depth gap or undecodable diff (`degraded`), and this
  # clause forwarded every one. A venue field that stays malformed arrives at the rate of the
  # stream, so one bad symbol turned into a notice per frame into every subscriber's mailbox:
  # the same amplification `Core.Fanout` documents for a stalled consumer. Now the first
  # notice for a `{kind, reason, symbol}` goes out at once, the rest inside
  # `@notice_window_ms` are counted, and the next one after the window carries the count in
  # `details.suppressed`. `symbol` is part of the key only when it is a symbol this feed wants,
  # so a venue-supplied string cannot grow the table; the table itself is capped
  # (`put_notice_seen/4`). Other kinds are lifecycle events bounded by reconnect backoff.
  defp throttle_notice(state, %Notice{kind: kind} = notice)
       when kind in @throttled_notice_kinds do
    now = System.monotonic_time(:millisecond)
    key = notice_key(notice, state.wanted)

    case Map.get(state.notice_seen, key) do
      {window_start, suppressed} when now - window_start < @notice_window_ms ->
        {:suppress, put_notice_seen(state, key, {window_start, suppressed + 1}, now)}

      previous ->
        {:forward, with_suppressed(notice, suppressed_count(previous)),
         put_notice_seen(state, key, {now, 0}, now)}
    end
  end

  defp throttle_notice(state, notice), do: {:forward, notice, state}

  defp notice_key(%Notice{kind: kind, details: details}, wanted) when is_map(details) do
    symbol = Map.get(details, :symbol)
    known = if is_binary(symbol) and MapSet.member?(wanted, symbol), do: symbol
    {kind, Map.get(details, :reason), known}
  end

  defp notice_key(%Notice{kind: kind}, _wanted), do: {kind, nil, nil}

  defp suppressed_count({_window_start, suppressed}), do: suppressed
  defp suppressed_count(nil), do: 0

  defp with_suppressed(notice, 0), do: notice

  defp with_suppressed(%Notice{details: details} = notice, suppressed) when is_map(details),
    do: %{notice | details: Map.put(details, :suppressed, suppressed)}

  defp with_suppressed(notice, _suppressed), do: notice

  defp put_notice_seen(state, key, entry, now) do
    %{state | notice_seen: state.notice_seen |> Map.put(key, entry) |> bound_notice_seen(now)}
  end

  # Over the cap, expired windows go; still over, the table starts again. Losing a count is
  # better than holding a table a hostile or broken stream can grow.
  defp bound_notice_seen(seen, now) when map_size(seen) > @max_notice_keys do
    live = Map.reject(seen, fn {_key, {start, _count}} -> now - start >= @notice_window_ms end)
    if map_size(live) > @max_notice_keys, do: %{}, else: live
  end

  defp bound_notice_seen(seen, _now), do: seen

  defp settle_subscribe(:ok, connected, _previous, _subscriber, _symbols), do: connected

  defp settle_subscribe({:error, _reason}, connected, previous, subscriber, symbols) do
    connected
    |> undo_registration(previous, subscriber, symbols)
    |> queue_unsubscribe(newly_wanted(previous, symbols))
  end

  defp newly_wanted(previous, symbols),
    do: Enum.reject(symbols, &MapSet.member?(previous.wanted, &1))

  # Takes back what a failed `subscribe/3` registered, and only that: a symbol or subscriber
  # that was already there before the call stays. A subscriber's monitor is released only when
  # nothing else registered it, since the same pid may also be a notice subscriber.
  defp undo_registration(state, previous, subscriber, symbols) do
    added = MapSet.new(newly_wanted(previous, symbols))
    state = %{state | wanted: MapSet.difference(state.wanted, added)}

    if MapSet.member?(previous.subscribers, subscriber) do
      state
    else
      %{
        state
        | subscribers: MapSet.delete(state.subscribers, subscriber),
          monitors: release_monitor(state, subscriber)
      }
    end
  end

  defp release_monitor(state, subscriber) do
    if MapSet.member?(state.notice_subscribers, subscriber),
      do: state.monitors,
      else: Fanout.forget(subscriber, state.monitors)
  end

  # The frame may have landed even though the send reported failure (`Socket.subscribe/3`:
  # "the frame may well have landed"), so the venue may be streaming symbols nobody wants. The
  # next resubscribe tick unsubscribes them, unless they are wanted again by then.
  defp queue_unsubscribe(state, symbols) do
    %{state | unsubscribe_pending: MapSet.union(state.unsubscribe_pending, MapSet.new(symbols))}
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

  # Every kind `capabilities().streamable` declares, present with empty maps — `:trades`
  # included even for a feed started without it in `:channels`, matching the same
  # always-present-key convention `coverage_by_kind/1`'s own moduledoc documents for
  # `:quotes`/`:top_of_book`: an absent key would read as "this feed does not know about
  # that kind", where an empty map reads as what is actually true — declared, and nothing
  # of it has arrived (whether because none has, or because this feed was never asked to
  # carry it). One function rather than the literal repeated at each of its three call
  # sites — `init/1`, a socket crash and a link drop — because a third streamable kind
  # added to two of the three is a silent, plausible-looking divergence, which is the
  # shape of defect this family keeps writing rules against, and exactly what happened
  # here once already before `:trades` existed to prove the point.
  defp empty_delivery, do: %{quotes: %{}, top_of_book: %{}, trades: %{}}

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

  defp track_delivery(state, %Trade{symbol: symbol}), do: put_delivery(state, :trades, symbol)

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
  # The venue's data stream, bounded — see `Core.Fanout`. Only a subscriber under its
  # mailbox bound is sent to; one past it is skipped and reported once, in a `:degraded`
  # notice, and reported again when it catches up.
  #
  # Notices themselves keep going through `fan_out/2` unbounded, and must: the notice saying
  # a subscriber is being dropped cannot be the first casualty of that same subscriber being
  # dropped. Notices are low-volume by construction here — link transitions, coverage
  # changes, refusals — and have never been produced at a rate that could bury a consumer.
  defp deliver(state, message) do
    {_sent, dropping, transitions} =
      Fanout.deliver(state.subscribers, message, state.dropping,
        max_queue_len: state.max_queue_len
      )

    Enum.each(transitions, fn transition ->
      fan_out(
        state.notice_subscribers,
        {:dp_exchange, :gemini, Fanout.notice_for(transition, :gemini, state.max_queue_len)}
      )
    end)

    %{state | dropping: dropping}
  end

  # The UNBOUNDED path — notices only. See `deliver/2` above for why the data stream does not
  # come through here and why notices deliberately still do.
  #
  # A subscriber may be a raw pid or a registered name — `subscribe/2`'s `to:` accepts
  # either, matching ordinary OTP practice (a consumer registering itself by name and
  # handing that name to a producer). `Process.alive?/1` only accepts a pid and raises on
  # anything else, so a registered-name subscriber crashed this whole GenServer on every
  # delivery (same defect, same fix, as `dp-exchange-coinbase`'s `Feed.fan_out/2` —
  # DpCryptoManagement's issue #15). Resolving first, uniformly, fixes both: a dead pid
  # resolves to itself and `Process.alive?/1` filters it; an unregistered name resolves
  # to `nil` and is silently skipped, the same as a dead subscriber already was.
  #
  # `Core.Fanout.resolve/1` is that resolution, shared: all five venues had written it
  # identically, and `deliver/2` and this function have to agree on what counts as a
  # reachable subscriber or a notice could go to a pid the data stream considers gone.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case Fanout.resolve(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  # See the `{:dp_exchange, :gemini, payload}` clause of `handle_info/2`.
  defp unwanted?(%{symbol: symbol}, wanted) when is_binary(symbol),
    do: not MapSet.member?(wanted, symbol)

  defp unwanted?(_payload, _wanted), do: false
end
