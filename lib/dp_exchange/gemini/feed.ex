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
  `Socket`'s own state carried no memory of what was subscribed (`%{subscriber:,
  request_id:}` then; it still holds no `wanted` set, and a reconnect clears even the depth
  channels it records), so there was nothing to resend even if it tried, and this module's
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

  `start_dial/1` calls `Socket.start_link/1` from inside `Feed`'s own callback, which
  links the new socket to `Feed` the way `start_link` always does — this is not a
  supervised sibling `Feed` could lose independently, it is a linked child. Before this
  fix `Feed` never called `Process.flag(:trap_exit, true)`, so a socket that exited
  abnormally (an exception inside a WebSockex callback, or anything that killed the
  socket pid directly) sent an untrappable `EXIT` signal along that link and crashed
  `Feed` too — every subscriber, the whole `wanted` set, gone, restarted by
  `DpExchange.Gemini.Supervisor` from the STATIC `opts` it was given at tree-start, which
  never carry a consumer's later `subscribe/3` calls. Proven by linking a real process
  into a running `Feed` the way `start_dial/1` does and killing it with
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

  ## A dial never blocks this process — and its timeout budget is chosen, not inherited

  **The dial used to run inside `handle_call`.** `Socket.start_link/1` was called
  synchronously there, and `Feed`/`SandboxFeed` are named, shared processes: the whole
  blocking window that connect could take (up to about 25s in the worst case, with the
  frame sends that followed) was borne by every other consumer's `unsubscribe/2`,
  `coverage/1` and `wanted/1` queued behind it — the `Feed` process itself was stuck, so
  the caller's own `@call_timeout` could not help any of them, and a caller of a read that
  waited past it exited. The same dial ran inside the resubscribe tick and the crash redial.

  **Now the socket dials in its own process** (`Socket.start_link/1` with `async: true`),
  linked to and parented by `Feed` as before, and `Feed` returns to its mailbox at once.
  The socket reports `{:dp_exchange, :gemini, :connected, pid}` when the first connect
  succeeds, or exits `{:error, reason}` when it fails. Meanwhile:

  * `subscribe/3` (non-empty), `unsubscribe/2` and `update_symbols/2` are HELD, with their
    `from`, and replayed in arrival order once the socket is connected (so the caller's
    return is what it always was: `:ok` after the frame went out, `{:error, reason}`
    otherwise). A failed dial answers every held `subscribe/3` `{:error, reason}` — the same
    reason a synchronous dial returned — having registered nothing. At most 1_000 calls are
    held; past that a caller gets `{:error, :dial_backlog_full}`.
  * Everything that touches no wire — `coverage/1`, `coverage_by_kind/1`, `wanted/1`,
    `subscribe_notices/2`, `subscribe([])` — is answered at once.
  * A resubscribe (tick or redial) that finds a dial in progress folds into it: the whole
    `wanted` set is sent when it connects.
  * A first connect that fails is not a socket crash: no `:link_down` notice, no crash-run
    backoff. A dial that resubscribe started reports it as the failed periodic reconnect it
    is (the latched `:coverage_change` notice). The vendored socket exits with a crash
    report for a failed first connect, so a venue that is down logs one report per attempt.
  * `{:dial_timeout, ref}` is the net under a dial that neither connected nor exited (the
    socket's own handshake deadline, connect plus recv, normally ends it first).

  **The connect was never unbounded — that was the wrong diagnosis.** `websockex`'s own
  `WebSockex.Conn` bounds it already: measured from the vendored dependency,
  `@socket_connect_timeout_default` is `6_000`ms and `@socket_recv_timeout_default` is
  `5_000`ms (`deps/websockex/lib/websockex/conn.ex:10-11`), and both are read from the
  `opts` list passed to `WebSockex.start_link/4` (`conn.ex:98-100`). The real defect was
  that `Socket.start_link/1` passed **no opts at all**, so it inherited those defaults by
  accident rather than choosing them — and 6_000 + 5_000 = 11_000ms of connect, plus one
  `send_frame` for the subscribe that follows connecting (up to `@frame_window_ms`,
  5_000ms), is 16_000ms against the 15_000ms `@call_timeout` this module had then: already
  over budget before any other overhead in that call is counted. (`@call_timeout` is 25_000ms
  now, sized for the two frames a `:trades` feed sends; see `@frame_window_ms`. The 3_000 +
  2_000 + one frame below, and the second frame with `:trades` on, are 15_000ms of it.)

  `Socket.start_link/1` now sets `:socket_connect_timeout` and `:socket_recv_timeout`
  explicitly, chosen against that same budget rather than left to `websockex`'s general-
  purpose defaults: 3_000ms connect + 2_000ms recv + 5_000ms for the one frame send that
  follows is 10_000ms, leaving the rest of `@call_timeout` for the GenServer
  call's own overhead. Both remain overridable through the `opts` `Socket.start_link/1`
  already accepts, for a deployment whose real connect time needs more room than this
  package's own budget assumed — `Feed.start_link/1`'s own `opts` forward
  `:socket_connect_timeout` and `:socket_recv_timeout` straight through, alongside `:url`,
  `:environment` and `:ssl_options`. The last replaces the verified-TLS defaults entirely
  (`Socket.connect_opts/1`); `usage-rules.md` told a consumer to pass it, and until it was
  forwarded here there was no way to, since a consumer never calls `Socket.start_link/1`.

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

  ## Stopping the feed stops its socket

  The socket this feed dialled is linked to it and does not trap exits, so a `:normal` stop
  (`GenServer.stop/1`) sent it a signal it ignores, and it stayed connected, reconnecting and
  delivering to nobody. `terminate/2` ends it (`:shutdown`). A socket handed in with `:socket`
  was not dialled here and is left alone.

  ## A restarted feed keeps what it was carrying

  The supervisor restarts a crashed feed from its start options, which never held a consumer's
  later `subscribe/3`, so the wanted symbols and every subscriber were lost without a word.
  When the tree supplies a `:ledger` (`DpExchange.Gemini.Ledger`), the feed records its accepted
  intent after every change (a refused change leaves it as it was, so writes nothing) and a
  restarted one restores it in `handle_continue/2`: it re-monitors the subscribers, resubscribes,
  and, when anything was wanted, sends its notice subscribers `:coverage_change` with
  `details.reason: :feed_restarted`. Data-only subscribers have no notice channel and simply
  receive data again. The feed holds no credential, so there is none to keep.
  """

  use GenServer

  alias DpExchange.Core.{Capabilities, Config, Fanout, Notice, Telemetry}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Gemini.{Credentials, Ledger, Socket, SymbolFormat}

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

  # What a dial may wait on past the socket's own handshake deadline (connect + recv) before
  # `Feed` gives up on it. A net: the handshake deadline is enforced inside the socket and
  # ends the dial first.
  @dial_grace_ms 5_000

  # The most calls held behind one dial. A dial lasts seconds, so reaching this takes a
  # thousand concurrent callers; past it a caller is refused rather than queued without bound.
  @max_dial_waiters 1_000

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
    # Idempotent: credentials, if any were passed, never reach the init argument raw.
    opts = Credentials.wrap_opt(opts)
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

  **A first subscribe waits for the connection, not the feed.** With no socket yet, the socket
  dials in its own process and this call is held until it connects (bounded by the connect and
  receive timeouts), while every other call the feed serves is answered meanwhile. A failed
  dial answers `{:error, reason}` with nothing recorded; more than 1_000 calls held behind one
  dial answer `{:error, :dial_backlog_full}`. See the moduledoc's "A dial never blocks this
  process".

  Refuses what it cannot hold in the caller, before the shared feed process sees it:
  `{:error, {:invalid_symbols, term}}` (see `canonical_symbols/1`) and
  `{:error, {:invalid_subscriber, term}}` for a `:to` that is neither a pid nor a registered
  name.
  """
  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts) do
    with {:ok, symbols} <- canonical_symbols(symbols),
         {:ok, subscriber} <- valid_subscriber(Config.opt(opts, :to, self())),
         :ok <- reject_channels(opts) do
      GenServer.call(feed, {:subscribe, symbols, subscriber}, @call_timeout)
    end
  end

  @doc """
  `:ok`, or `{:error, {:invalid_option, :channels, value}}` when `opts` carries `:channels`.

  **`:channels` configures the one connection this feed holds, at start; it is not a
  `subscribe/3` option.** It used to be ignored here, so a caller who passed it believed they
  had asked for the trade tape per subscribe and got the feed's start-time channels, silently.
  Refused rather than ignored, and `DpExchange.Gemini.Fake` refuses the same way.
  """
  @spec reject_channels(keyword()) :: :ok | {:error, {:invalid_option, :channels, term()}}
  def reject_channels(opts) do
    case Config.opt(opts, :channels, nil) do
      nil -> :ok
      value -> {:error, {:invalid_option, :channels, value}}
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
  def canonical_symbols(symbols) do
    # The error carries the caller's WHOLE argument as given, not only the bad elements, and
    # an improper list (`["BTC-USD" | "tail"]`) is refused rather than raised on.
    if proper_list?(symbols) and Enum.all?(symbols, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, symbols |> Enum.map(&canonical_symbol/1) |> Enum.uniq()}
    else
      {:error, {:invalid_symbols, symbols}}
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

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

  @doc """
  The symbols currently wanted (subscribed and not since removed), sorted: what was asked
  for, not what arrived.
  """
  @spec wanted(GenServer.server()) :: [String.t()]
  def wanted(feed), do: GenServer.call(feed, :wanted, @call_timeout)

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
    {:ok, state} = init_state(opts)

    case state.ledger do
      nil -> {:ok, state}
      _ledger -> {:ok, state, {:continue, :restore_intent}}
    end
  end

  @impl true
  def handle_continue(:restore_intent, state), do: {:noreply, restore_intent(state)}

  defp init_state(opts) do
    # `start_dial/1` calls `Socket.start_link/1` from inside a `Feed` callback, which
    # links the socket to `Feed` — see the moduledoc's "A crashed socket is Feed's crash
    # too" section. Without this flag an abnormal socket exit crashes `Feed` itself,
    # discarding every subscriber and the whole `wanted` set; `handle_info({:EXIT, _,
    # _}, _)` below is what this flag makes reachable at all.
    Process.flag(:trap_exit, true)

    channels = (Keyword.get(opts, :channels) || @default_channels) |> validate_channels!()

    {:ok,
     %{
       socket_opts:
         opts
         |> Keyword.take([
           :url,
           :environment,
           :socket_connect_timeout,
           :socket_recv_timeout,
           :ssl_options
         ])
         |> unwrap_ssl_option(),
       # See the moduledoc's "`channels:`" section. Read once, here, already validated —
       # every place that decides which `Socket` channels to carry (`active_channels/1`)
       # reads this rather than a module attribute, so a feed always acts on what its own
       # caller asked for.
       channels: channels,
       # An already-established connection. Ordinary use leaves this nil and the feed
       # dials its own on first subscribe; it is set on reconnect, and by tests that need
       # the socket-bearing branches without reaching a venue.
       socket: Keyword.get(opts, :socket),
       # The dial in progress, or nil. A first connect is made
       # by the socket process itself and never inside a callback here. See the moduledoc's
       # "A dial never blocks this process" section and `start_dial/1`.
       dial: nil,
       # The one live periodic-resubscribe timer, `{ref, timer}`. A tick whose ref is not this
       # one is stale and does nothing, so a second tick message can never start a second chain.
       resubscribe_timer: schedule_tick(),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       # Symbols whose wire unsubscribe failed, retried on the next resubscribe tick. Cleared
       # by any new connection, which carries no subscriptions. See `retry_unsubscribe/2`.
       unsubscribe_pending: MapSet.new(),
       # The subset of `unsubscribe_pending` queued by a FAILED SUBSCRIBE (`queue_unsubscribe/2`):
       # symbols whose subscribe frame may still land. A `:reconnected` keeps these pending and
       # drops the rest. See `handle_info({:dp_exchange, :gemini, :reconnected, socket}, _)`.
       late_subscribes: MapSet.new(),
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
       max_queue_len: Fanout.max_queue_len!(opts, :gemini),
       # The per-tree `DpExchange.Gemini.Ledger` holding what a restart must not lose, or nil
       # (a feed started on its own). `ledger_snapshot` is what it was last told.
       ledger: Keyword.get(opts, :ledger),
       ledger_snapshot: nil
     }}
  end

  # **What the feed was asked to carry survives the feed.** The supervisor restarts a crashed
  # feed from the options it was started with, which never hold a consumer's later
  # `subscribe/3`: every subscriber, the whole `wanted` set and the notice subscribers were
  # gone, and no consumer was told. `DpExchange.Gemini.Ledger` (started before this process,
  # under `:rest_for_one`) is told the accepted intent after every change; a restarted feed
  # reads it here, in `handle_continue/2`, and not in `init/1`, so the supervisor is not held.
  defp restore_intent(state) do
    case Ledger.fetch(state.ledger) do
      %{wanted: wanted, subscribers: subscribers, notice_subscribers: notice_subscribers} = kept
      when is_struct(wanted, MapSet) and is_struct(subscribers, MapSet) ->
        watched = MapSet.union(subscribers, notice_subscribers)

        restored = %{
          state
          | wanted: wanted,
            subscribers: subscribers,
            notice_subscribers: notice_subscribers,
            monitors: Enum.reduce(watched, state.monitors, &Fanout.watch/2),
            ledger_snapshot: kept
        }

        restored |> announce_restart() |> resubscribe()

      _nothing_kept ->
        state
    end
  end

  # The notice channel is `subscribe_notices/2`'s; a data-only subscriber has none, and gets its
  # data again when the venue resumes. `:coverage_change` is the kind `Core.Notice` defines for
  # "subscribed intent that is not (yet) delivery", so it is sent when something was wanted: a
  # feed that carried nothing lost no coverage and says nothing.
  defp announce_restart(%{wanted: wanted, notice_subscribers: notice_subscribers} = state) do
    if MapSet.size(wanted) > 0 do
      notice =
        Notice.new(:coverage_change, :gemini,
          severity: :warning,
          message: "feed restarted: subscriptions are being re-established",
          details: %{reason: :feed_restarted, delivering: false}
        )

      fan_out(notice_subscribers, {:dp_exchange, :gemini, notice})
    end

    state
  end

  # Tells the ledger the intent when it changed, never when it did not: a refused change leaves
  # `wanted` and the subscribers as they were, so it writes nothing.
  defp sync_ledger(state) do
    case Map.get(state, :ledger) do
      nil ->
        state

      ledger ->
        snapshot = %{
          wanted: state.wanted,
          subscribers: state.subscribers,
          notice_subscribers: state.notice_subscribers
        }

        if snapshot == Map.get(state, :ledger_snapshot) do
          state
        else
          Ledger.put(ledger, snapshot)
          Map.put(state, :ledger_snapshot, snapshot)
        end
    end
  end

  # **A crash report and `:sys.get_status/1` print this process's state, and the state holds
  # the caller's `:ssl_options`.** That is the option `usage-rules.md` tells a consumer to use
  # to replace the verified-TLS defaults, and what it holds is whatever the consumer needs for
  # its own trust: a `:cacerts` list of every CA certificate (hundreds of kilobytes in one log
  # line), and for a private CA or a client certificate a `:key` or a `:password`. The state
  # is shown with that one option replaced; nothing else in it is secret. `:sys.get_state/1`
  # is unchanged, which is what this package's own tests read.
  @impl true
  def format_status(%{state: %{socket_opts: socket_opts} = state} = status)
      when is_list(socket_opts) do
    redacted =
      if Keyword.has_key?(socket_opts, :ssl_options),
        do: Keyword.put(socket_opts, :ssl_options, :redacted),
        else: socket_opts

    %{status | state: %{state | socket_opts: redacted}}
  end

  # Deliberately defensive: the state is always this module's map, but a `format_status/1`
  # that raises loses the crash report it was called to format.
  def format_status(status), do: status

  @impl true
  # **While a dial is in progress, every call that touches the wire waits its turn.** The
  # socket is not connected yet, so a send would fail, and answering `unsubscribe` or
  # `update_symbols` ahead of a queued `subscribe` would reorder the caller's own requests.
  # They are held, with their `from`, and replayed in arrival order by `dial_connected/1` (or
  # answered by `dial_failed/2`). Everything else — `coverage`, `wanted`, `subscribe_notices`,
  # `subscribe([])` — touches no wire and is answered at once. The queue is capped
  # (`@max_dial_waiters`) so a stuck dial cannot grow it.
  def handle_call({:subscribe, [_first | _rest], _subscriber} = call, from, %{dial: %{}} = state),
    do: wait_for_dial(state, from, call)

  def handle_call({:unsubscribe, _symbols} = call, from, %{dial: %{}} = state),
    do: wait_for_dial(state, from, call)

  def handle_call({:update_symbols, _symbols} = call, from, %{dial: %{}} = state),
    do: wait_for_dial(state, from, call)

  # `{:error, _}` leaves nothing registered — see `subscribe/3`. A failure to connect undoes
  # the registration. A failure to send undoes it too, keeps the socket this call dialled, and
  # queues the new symbols for a wire unsubscribe (`settle_subscribe/5`).
  # **`subscribe([])` registers the subscriber and opens nothing.** It used to dial the venue
  # for no symbol, and a consumer that has asked for nothing must not find a socket open.
  # The subscriber still receives whatever a later subscribe delivers.
  def handle_call({:subscribe, [], subscriber}, _from, state) do
    registered = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        monitors: Fanout.watch(subscriber, state.monitors)
    }

    {:reply, :ok, sync_ledger(registered)}
  end

  # No socket: dial one, and hold this call until it is connected. NOTHING is registered yet,
  # so a failed dial has nothing to undo — `dial_failed/2` answers `{:error, reason}` and the
  # state is exactly as the caller found it. The registration happens when the call is
  # replayed against the connected socket (`dial_connected/1`).
  def handle_call({:subscribe, _symbols, _subscriber} = call, from, %{socket: nil} = state) do
    case start_dial(state) do
      {:ok, dialing} -> wait_for_dial(dialing, from, call)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    registered = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        monitors: Fanout.watch(subscriber, state.monitors),
        wanted: MapSet.union(state.wanted, MapSet.new(symbols))
    }

    sent = when_linked(registered, &subscribe_channels(&1, symbols, registered))
    settled = settle_subscribe(sent, registered, state, subscriber, symbols)
    {:reply, sent, sync_ledger(settled)}
  end

  def handle_call({:unsubscribe, symbols}, _from, %{socket: nil} = state) do
    {:reply, :ok, state |> drop(symbols) |> sync_ledger()}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    result = when_linked(state, &unsubscribe_channels(&1, symbols, state))
    dropped = state |> drop(symbols) |> unsubscribe_later(result, symbols)
    {:reply, result, sync_ledger(dropped)}
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
        {:reply, :ok, sync_ledger(updated)}

      # The unsubscribe half went out, so the removed symbols are no longer on the wire: they
      # are not wanted, and a tick must not resend them. Only the subscribe half failed.
      {:error, reason, :subscribe} ->
        kept = MapSet.difference(state.wanted, MapSet.new(removed))
        queued = queue_unsubscribe(%{updated | wanted: kept}, added)
        {:reply, {:error, reason}, sync_ledger(queued)}

      {:error, reason, :unsubscribe} ->
        queued = queue_unsubscribe(%{updated | wanted: state.wanted}, added)
        {:reply, {:error, reason}, sync_ledger(queued)}
    end
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and
    # the facade documents absence as `:not_covered`.
    {:reply, Map.new(all_delivering(state), fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call(:wanted, _from, state) do
    {:reply, state.wanted |> MapSet.to_list() |> Enum.sort(), state}
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

    {:reply, :ok, sync_ledger(state)}
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
  #
  # **The last data subscriber going releases what was wanted.** `wanted` is one set for the
  # whole feed, with no record of who asked for what, so a symbol outlived every consumer that
  # wanted it: the venue kept streaming it to this connection, `resubscribe/1` kept resending
  # it on every tick and after every reconnect, and each frame was fanned out to nobody for
  # the life of the feed. With no data subscriber left (a registered-name one keeps the set
  # alive, as it is never monitored) `wanted` is dropped through the same path an
  # `unsubscribe/2` takes, and the wire unsubscribe is retried on the tick if it fails.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    was_subscriber? = MapSet.member?(state.subscribers, pid)

    state = %{
      state
      | subscribers: MapSet.delete(state.subscribers, pid),
        notice_subscribers: MapSet.delete(state.notice_subscribers, pid),
        monitors: Fanout.forget(pid, state.monitors)
    }

    if was_subscriber? and MapSet.size(state.subscribers) == 0,
      do: {:noreply, state |> release_wanted() |> sync_ledger()},
      else: {:noreply, sync_ledger(state)}
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

  # The periodic tick. Only the tick the state names is honoured, and it re-arms exactly one
  # successor, so the timer chain stays a chain of one however many ticks are sent.
  def handle_info({:resubscribe_tick, ref}, %{resubscribe_timer: {ref, _timer}} = state) do
    state = %{state | resubscribe_timer: schedule_tick()}
    {:noreply, resubscribe(state)}
  end

  def handle_info({:resubscribe_tick, _stale}, state), do: {:noreply, state}

  # A resubscribe asked for by hand (a test, or `send/2` from a host): the work of a tick
  # without the timer. It used to re-arm the timer as well, so each such message started a
  # second chain beside the first.
  def handle_info(:resubscribe, state), do: {:noreply, resubscribe(state)}

  # The socket this feed dialled has finished connecting. See "A dial never blocks this
  # process" in the moduledoc. A report from any other socket falls through to the catch-all.
  def handle_info({:dp_exchange, :gemini, :connected, socket}, %{dial: %{socket: s}} = state)
      when socket == s do
    {:noreply, dial_connected(state)}
  end

  # The safety net under a dial that neither connected nor exited. The vendored handshake
  # deadline normally ends it first, with an `EXIT` below. A ref that is not the dial's is
  # stale — the dial finished first — and does nothing.
  def handle_info({:dial_timeout, ref}, %{dial: %{ref: ref, socket: socket}} = state) do
    Process.exit(socket, :kill)
    {:noreply, dial_failed(state, :dial_timeout)}
  end

  def handle_info({:dial_timeout, _stale}, state), do: {:noreply, state}

  # The socket this feed was dialling exited before it connected: the connect failed. An
  # asynchronous start ends with `{:error, reason}`, the reason a synchronous `start_link/1`
  # used to return, so it is unwrapped to that. This is NOT a socket crash — there was no
  # connection to lose — so no `:link_down` notice and no crash-run backoff: the callers
  # waiting on the dial are told, and the periodic tick tries again.
  def handle_info({:EXIT, pid, reason}, %{dial: %{socket: pid}} = state) do
    {:noreply, dial_failed(state, dial_exit_reason(reason))}
  end

  # The live socket reconnected, and it carries no subscriptions now — see the moduledoc's
  # "A reconnect resubscribes at once; the timer is the net" section. The same work as a
  # timer tick, but the timer is NOT re-armed here: re-sending `:resubscribe` would start
  # a second timer chain beside the first. A report from a socket that is no longer
  # `state.socket` falls through to the catch-all.
  #
  # **A subscribe that failed on the old connection can still land on the new one.** Found by
  # reading the orderings (tick AB). The interleaving, step by step:
  #
  #   1. The socket's connection drops and it sleeps its backoff inside `handle_disconnect/2`,
  #      reading no messages. Its `:link_down` is queued behind whatever this process is doing.
  #   2. A `subscribe/3` for ETH-USD sends its frame (`Socket.subscribe/3`). The socket reads
  #      nothing, so the `send_frame` call times out after 5s: `{:error, :send_timeout}`. The
  #      call's message is still in the socket's mailbox. The registration is undone and
  #      ETH-USD is queued for a wire unsubscribe (`queue_unsubscribe/2`).
  #   3. The socket reconnects. `handle_connect/2` reports `:reconnected` FIRST, then the loop
  #      reads its mailbox and sends the stale subscribe frame on the NEW connection.
  #   4. This clause used to wipe `unsubscribe_pending` ("a new connection carries no
  #      subscriptions"), true of the old connection and false of this frame. The venue then
  #      streamed ETH-USD to a feed that no longer wanted it, for the life of the connection,
  #      and nothing ever unsubscribed it (every payload was dropped as unwanted).
  #
  # So the symbols queued by a failed SUBSCRIBE stay pending, and `resubscribe/1` below sends
  # their unsubscribe (behind the stale frame, which is older in the socket's mailbox). The
  # symbols queued by a failed UNSUBSCRIBE are still dropped: the old connection's
  # subscription died with it, and a stale unsubscribe landing on the new one is harmless.
  def handle_info({:dp_exchange, :gemini, :reconnected, socket}, %{socket: socket} = state) do
    pending = MapSet.intersection(state.unsubscribe_pending, late_subscribes(state))
    state = put_pending(%{state | link_down?: false}, pending)
    {:noreply, resubscribe(state)}
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
  #
  # **Only the redial the LAST crash scheduled is honoured** (`schedule_redial/2`). A consumer's
  # `subscribe/3` can dial a socket while a redial is pending, and if that socket crashes too
  # the run's delay doubles, but the first timer was still live: it fired at the OLD, shorter
  # delay and redialled ahead of the backoff the second crash had earned, once per stacked
  # timer. A timer message whose ref is not the current one is stale and does nothing.
  def handle_info({:redial_after_crash, ref}, %{socket: nil} = state) do
    case Map.get(state, :redial_timer) do
      {^ref, _timer} -> {:noreply, resubscribe(Map.delete(state, :redial_timer))}
      _stale -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # **A feed that stops takes the socket it dialled with it.** The socket is linked to this
  # process, but it does not trap exits (neither does `websockex`), and an exit signal with
  # reason `:normal` is ignored by a process that does not trap: `GenServer.stop/1` on this feed
  # (reason `:normal`) left its socket connected and reconnecting for good, delivering to a
  # subscriber that no longer existed, with nothing left to stop it. Only `:shutdown` and
  # crashes reached it through the link. This process traps exits, so this runs for
  # `GenServer.stop/1`, for a supervisor's shutdown and for a callback that raises.
  #
  # Only the socket THIS process started (`start_dial/1` records it as `:dialled_socket`): a
  # `:socket` handed in through the options is the caller's, and may be the caller itself.
  @impl true
  def terminate(_reason, state) do
    case Map.get(state, :dialled_socket) do
      socket when is_pid(socket) -> Process.exit(socket, :shutdown)
      _none -> true
    end

    :ok
  end

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
  #
  # A dial already in progress has not connected, so there is nothing to resend to yet. The
  # tick is not lost: the dial is told to resubscribe the whole `wanted` set the moment it
  # connects (`dial_connected/1`), or to report the failure if it does not (`dial_failed/2`).
  defp resubscribe(%{dial: %{} = dial} = state), do: %{state | dial: %{dial | resubscribe?: true}}

  defp resubscribe(%{socket: socket} = state) when is_pid(socket) do
    state = retry_unsubscribe(socket, state)

    if Process.alive?(socket) and not state.link_down? and MapSet.size(state.wanted) > 0 do
      case subscribe_channels(socket, MapSet.to_list(state.wanted), state) do
        :ok ->
          resubscribe_recovered(state)

        {:error, reason} ->
          Logger.warning("[Gemini Feed] periodic resubscribe failed: #{reason_text(reason)}")
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
  # subscribed (ordinary boot, `start_dial/1` has never run), or a socket crashed and
  # `isolate_crashed_socket/2` cleared it. Only the second case has anything to recover;
  # dialling in the first case costs nothing (the venue gets a connection with no
  # subscription frame, since `Socket.start_link/1` opens without one) but is not the
  # ordinary path — a `subscribe/3` normally dials first. The dial is asynchronous: this
  # clause only starts it and marks it `resubscribe?`, and `dial_connected/1` then runs the
  # `is_pid(socket)` clause above, so the actual `Socket.subscribe/2` call — and the
  # recovery/failure latch — still only ever happens in one place.
  defp resubscribe(%{socket: nil} = state) do
    if MapSet.size(state.wanted) > 0 do
      case start_dial(state) do
        {:ok, %{dial: dial} = dialing} ->
          %{dialing | dial: %{dial | resubscribe?: true}}

        {:error, reason} ->
          Logger.warning("[Gemini Feed] periodic reconnect failed: #{reason_text(reason)}")
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
        details: %{reason: :resubscribe_failed, message: reason_text(reason)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :gemini, notice})
    %{state | resubscribe_notice_state: :dead}
  end

  defp apply_delta(%{socket: nil}, _added, _removed), do: :ok
  defp apply_delta(%{link_down?: true}, _added, _removed), do: :ok

  defp apply_delta(state, added, removed) do
    case unsubscribe_channels(state.socket, removed, state) do
      :ok -> tag_stage(subscribe_channels(state.socket, added, state), :subscribe)
      error -> tag_stage(error, :unsubscribe)
    end
  end

  defp tag_stage(:ok, _stage), do: :ok
  defp tag_stage({:error, reason}, stage), do: {:error, reason, stage}

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
  @doc """
  The de-duplicated `:channels` list, or `ArgumentError` for an empty list, a non-list or a
  kind outside `capabilities().streamable`. Exposed so `DpExchange.Gemini.Fake` validates the
  channels it is configured with exactly as a real feed does at start.
  """
  @spec validate_channels!(term()) :: [atom()]
  def validate_channels!(kinds) when is_list(kinds) and kinds != [] do
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

  def validate_channels!(value) do
    raise ArgumentError,
          "DpExchange.Gemini.Feed :channels must be a non-empty list drawn from " <>
            "#{inspect(@known_channels)}. Got #{inspect(value)}."
  end

  # A socket that is reconnecting is asleep in its backoff and answers no `send_frame/2`,
  # so a send would block this process for its whole 5s window. Answered `:ok` because
  # nothing is lost: `wanted` is already updated, and `:reconnected` re-issues all of it.
  defp when_linked(%{link_down?: true}, _send), do: :ok
  defp when_linked(%{socket: socket}, send), do: send.(socket)

  # Bounded: a socket crash reason carries the exception and its stacktrace (frame
  # arguments included), and a refused connect carries the venue's response; either went
  # whole into every notice subscriber and every log line.
  defp reason_text(reason), do: inspect(reason, limit: 50, printable_limit: 1_024)

  # `start_link/1` wrapped a caller's `:ssl_options` so the supervisor's child spec cannot print
  # a key or password in it (`DpExchange.Gemini.Credentials`). The state keeps it as given: it
  # is what `Socket` is started with, and `format_status/1` already redacts it for a report.
  defp unwrap_ssl_option(socket_opts) do
    case Keyword.fetch(socket_opts, :ssl_options) do
      {:ok, wrapped} -> Keyword.put(socket_opts, :ssl_options, Credentials.unwrap_ssl(wrapped))
      :error -> socket_opts
    end
  end

  # Starts a socket that dials INSIDE ITS OWN PROCESS (`Socket.start_link/1`'s `:async`) and
  # returns at once, so nothing here waits out a connect. `Feed` is the starter, so the link
  # and the socket's `parent` are `Feed`, exactly as when the dial was synchronous: stopping
  # `Feed` still stops the socket, and a crashed socket is still an `EXIT` here. The socket
  # reports `:connected` (`dial_connected/1`) or exits (`dial_failed/2`); `{:dial_timeout, ref}`
  # is the net under both. Only a synchronous refusal (an unparseable URL, a trust store that
  # cannot be loaded) is an `{:error, _}` from here.
  defp start_dial(state) do
    opts = state.socket_opts |> Keyword.put(:subscriber, self()) |> Keyword.put(:async, true)

    case Socket.start_link(opts) do
      {:ok, socket} ->
        ref = make_ref()
        budget = Socket.dial_budget_ms(opts) + @dial_grace_ms
        timer = Process.send_after(self(), {:dial_timeout, ref}, budget)

        dial = %{
          socket: socket,
          ref: ref,
          timer: timer,
          waiters: [],
          waiting: 0,
          resubscribe?: false
        }

        # A redial still pending is moot: a socket is being dialled now. `:dialled_socket` is
        # what `terminate/2` stops: the socket this process started, never an injected one.
        started = Map.put(state, :dialled_socket, socket)
        {:ok, cancel_redial(%{started | socket: socket, dial: dial})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Holds a call that needs a connected socket until the dial settles. Capped, and past the
  # cap the caller is told so rather than the queue growing: `{:error, :dial_backlog_full}`.
  defp wait_for_dial(%{dial: dial} = state, from, call) do
    if dial.waiting >= @max_dial_waiters do
      {:reply, {:error, :dial_backlog_full}, state}
    else
      waiting = %{dial | waiters: [{from, call} | dial.waiters], waiting: dial.waiting + 1}
      {:noreply, %{state | dial: waiting}}
    end
  end

  # The dial connected. The held calls are replayed, in arrival order, against the now-live
  # socket by the very `handle_call/3` clauses a synchronous caller would have hit, so their
  # registration, their undo-on-failure and their replies are unchanged. A resubscribe that
  # was asked for meanwhile goes first, because it describes what was wanted before them.
  defp dial_connected(%{dial: dial} = state) do
    Process.cancel_timer(dial.timer)
    state = %{state | dial: nil}
    state = if dial.resubscribe?, do: resubscribe(state), else: state

    dial.waiters |> Enum.reverse() |> Enum.reduce(state, &replay_waiter/2)
  end

  defp replay_waiter({from, call}, state) do
    {:reply, reply, state} = handle_call(call, from, state)
    GenServer.reply(from, reply)
    state
  end

  # The dial did not connect. A held `subscribe` is refused with the reason and, because
  # nothing was registered for it, there is nothing to take back. A held `unsubscribe` or
  # `update_symbols` is replayed against the now-socketless state, which is what it would have
  # met had it arrived after the failure. A resubscribe that was waiting on the dial is the
  # failed periodic reconnect it would have been when the dial was synchronous.
  defp dial_failed(%{dial: dial} = state, reason) do
    Process.cancel_timer(dial.timer)
    state = %{state | socket: nil, dial: nil} |> Map.delete(:dialled_socket)

    state =
      if dial.resubscribe? do
        Logger.warning("[Gemini Feed] periodic reconnect failed: #{reason_text(reason)}")
        resubscribe_failed(state, reason)
      else
        state
      end

    dial.waiters |> Enum.reverse() |> Enum.reduce(state, &refuse_waiter(&1, &2, reason))
  end

  defp refuse_waiter({from, {:subscribe, _symbols, _subscriber}}, state, reason) do
    GenServer.reply(from, {:error, reason})
    state
  end

  defp refuse_waiter(waiter, state, _reason), do: replay_waiter(waiter, state)

  defp dial_exit_reason({:error, reason}), do: reason
  defp dial_exit_reason(reason), do: reason

  defp schedule_tick do
    ref = make_ref()
    {ref, Process.send_after(self(), {:resubscribe_tick, ref}, @resubscribe_interval_ms)}
  end

  # See the moduledoc's "A crashed socket is Feed's crash too" section and `handle_info(
  # {:EXIT, pid, reason}, %{socket: pid} = state)` above. This venue has one socket
  # carrying every kind this feed is configured for — unlike a sharded venue, there is no
  # partial loss to compute, the crash costs everything this feed was delivering, so
  # `delivering_by_kind` resets to the same empty shape `init/1` starts with rather than
  # being narrowed symbol-by-symbol the way `drop/2` narrows it for an ordinary
  # unsubscribe.
  defp isolate_crashed_socket(state, reason) do
    report_link_down_metric(state, reason)

    state = %{
      state
      | socket: nil,
        delivering_by_kind: empty_delivery(),
        link_down?: false,
        unsubscribe_pending: MapSet.new()
    }

    # The crashed socket is gone: nothing left for `terminate/2` to stop, and its pid must not
    # be signalled later, when it could name an unrelated process.
    state = Map.delete(state, :dialled_socket)

    # A crashed socket's mailbox died with it: no stale frame can land on its replacement.
    state = Map.put(state, :late_subscribes, MapSet.new())

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
    state = cancel_redial(state)

    case crash_redial_delay(run) do
      0 -> resubscribe(state)
      delay -> schedule_redial(state, delay)
    end
  end

  # **A crashed socket closes the `[:dp_exchange, :link, :up]` the socket opened.** Its
  # `handle_connect/2` emits `link_up`, and its `handle_disconnect/2` emits `link_down`, but a
  # socket that CRASHES (a callback raising, a kill) runs no `handle_disconnect/2`, so a
  # metrics consumer's link gauge stayed "up" for a connection that no longer existed, while
  # the `:link_down` notice (above) did fire. Emitted here, from the one place the crash is
  # seen. Not when the socket already reported its own drop (`link_down?`, set by the
  # `:link_down` notice that precedes the `EXIT`), so one loss is one `link_down`.
  defp report_link_down_metric(state, reason) do
    if Map.get(state, :link_down?, false),
      do: :ok,
      else: Telemetry.link_down(:gemini, reason_text(reason))
  end

  # One redial timer at a time, identified by a ref the message carries. See the
  # `:redial_after_crash` clause of `handle_info/2`.
  defp schedule_redial(state, delay) do
    ref = make_ref()
    timer = Process.send_after(self(), {:redial_after_crash, ref}, delay)
    Map.put(state, :redial_timer, {ref, timer})
  end

  defp cancel_redial(state) do
    case Map.pop(state, :redial_timer) do
      {{_ref, timer}, rest} ->
        Process.cancel_timer(timer)
        rest

      {nil, rest} ->
        rest
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
        message: "socket crashed (#{reason_text(reason)}) — reconnecting now",
        details: %{reason: :socket_crashed, message: reason_text(reason)}
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
        put_pending(state, pending)

      unsubscribe_channels(socket, MapSet.to_list(pending), state) == :ok ->
        state
        |> Map.put(:late_subscribes, MapSet.new())
        |> Map.put(:unsubscribe_pending, MapSet.new())

      true ->
        put_pending(state, pending)
    end
  end

  # **`late_subscribes` only ever describes symbols still in `unsubscribe_pending`.** It was
  # written by `queue_unsubscribe/2` and emptied only by a retry that SUCCEEDED, so a symbol
  # whose failed subscribe was later made good (wanted again, which `retry_unsubscribe/2` takes
  # out of the pending set) stayed in it for the life of the feed. That is a set that grows by
  # one for every symbol that ever failed to subscribe, and it also gave a LATER failed
  # unsubscribe of the same symbol the "may still land" treatment on reconnect that only a
  # failed subscribe earns. Narrowed to the pending set wherever the pending set is narrowed.
  defp put_pending(state, pending) do
    state
    |> Map.put(:unsubscribe_pending, pending)
    |> Map.put(:late_subscribes, MapSet.intersection(late_subscribes(state), pending))
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
    {kind, notice_reason(details), known}
  end

  # Deliberately defensive. `Notice.new/3` refuses non-map `details`, and every notice this
  # package builds goes through it, so only a hand-built struct sent to this named process
  # gets here. Without this clause such a struct would raise `FunctionClauseError` and take
  # down this shared feed, with every other consumer's subscription.
  defp notice_key(%Notice{kind: kind}, _wanted), do: {kind, nil, nil}

  # A `:refusal` from `Socket` states one `:reason` (`:subscribe_refused`, or none when hand
  # built) and the venue's `subscribe_status`. Keyed on the reason alone, a 429 landing inside
  # the window of an earlier 400 was counted away and never reached a consumer, though the
  # two call for different responses. The status is an integer the venue chose, so a stream
  # of distinct values could grow the table, which is why only the closed set of HTTP-style
  # codes (100..599) is keyed and any other value shares one key.
  defp notice_reason(details) do
    case {Map.get(details, :reason), Map.get(details, :subscribe_status)} do
      {reason, status}
      when reason in [nil, :subscribe_refused] and is_integer(status) and status in 100..599 ->
        {:status, status}

      {reason, _status} ->
        reason
    end
  end

  defp suppressed_count({_window_start, suppressed}), do: suppressed
  defp suppressed_count(nil), do: 0

  defp with_suppressed(notice, 0), do: notice

  defp with_suppressed(%Notice{details: details} = notice, suppressed) when is_map(details),
    do: %{notice | details: Map.put(details, :suppressed, suppressed)}

  # Deliberately defensive, for the non-map `details` `notice_key/2` also tolerates: there is
  # nowhere to put the count, so the notice is forwarded as it came.
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
    new = MapSet.new(symbols)

    state
    |> Map.put(:unsubscribe_pending, MapSet.union(state.unsubscribe_pending, new))
    |> Map.put(:late_subscribes, MapSet.union(late_subscribes(state), new))
  end

  # `Map.get/3`: a state built before this field existed (or by a test) has none.
  defp late_subscribes(state), do: Map.get(state, :late_subscribes, MapSet.new())

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

  # Everything wanted, taken back because nobody is left to receive it. A dial still open has
  # no subscriptions to undo, and no socket has none either, so only a connected socket is sent
  # to; a failed send leaves the symbols queued for the tick, as `unsubscribe/2` does.
  defp release_wanted(state) do
    case MapSet.to_list(state.wanted) do
      [] -> state
      symbols -> release_symbols(state, symbols)
    end
  end

  defp release_symbols(%{socket: socket, dial: nil} = state, symbols) when is_pid(socket) do
    result = when_linked(state, &unsubscribe_channels(&1, symbols, state))
    state |> drop(symbols) |> unsubscribe_later(result, symbols)
  end

  defp release_symbols(state, symbols), do: drop(state, symbols)

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
