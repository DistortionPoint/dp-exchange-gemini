defmodule DpExchange.Gemini.Socket do
  @moduledoc """
  The venue's WebSocket connection — internal, and never named above the facade.

  Speaks `wss://ws.gemini.com`, the API Gemini's current documentation describes.
  **This is not the API the host adapter uses**, and the reasoning is in
  `docs/reference/gemini/websocket-api-replacement.md`. In one line: the host's
  `api.gemini.com/v2/marketdata` still answers, but it is absent from the vendor's current
  documentation and from four years of its changelog, so a package published for other
  people to depend on should not be built on it.

  ## Protocol

  Subscription is an RPC-shaped frame naming streams:

      {"method":"subscribe","params":["btcusd@bookTicker","ethusd@bookTicker"],"id":1}

  and the venue acknowledges with `{"id":1,"status":200}`, echoing the client-chosen id
  (`CorrelationId` in the spec). Every request this socket sends carries an id of its own
  (`1` above is only an example), and an answer is matched to its request by that id.

  This socket always carries **`@bookTicker`**. That single stream carries best bid, best
  ask and — where the book has traded — the last trade price, in one message per change.
  It delivers `Core.Types.TopOfBook` on every frame that parses, and a separate
  `Core.Types.Quote` only on the frames that also carry that last trade: the two are
  independent facts and a bid is never dressed up as a price. See `handle_message/2` for
  the substitution that rule exists to stop.

  It also carries **`@trade`** — every executed print, as `Core.Types.Trade` — whenever
  `DpExchange.Gemini.Feed` is configured with `:trades` in its `:channels` option; see
  that module's moduledoc. This socket itself makes no distinction: `subscribe/3` and
  `unsubscribe/3` already took a `channel` argument (defaulting to `:book_ticker`) before
  `:trades` existed as a streamable kind, and `handle_message/2` already decoded a `@trade`
  frame the moment one arrived — the address and the decode were both already correct.
  What changed was `Feed` choosing to ask for `@trade` at all; nothing here.

  ### Which is why there is no order-book machinery here

  The host maintains a 182-line L2 book (`gemini/l2_book.ex`) whose entire purpose is to
  reconstruct a mid price from `l2_updates` deltas, because the endpoint it connects to
  offers no top-of-book message. This endpoint does. The book is not ported, and the
  moduledoc of the file that is not ported records why it existed — a mid computed from a
  single delta rather than the maintained book, which is the incident that created it.

  A caller wanting a depth snapshot calls `get_order_book/2`, a REST snapshot that carries no
  venue time (its per-level `timestamp` is a documented dummy value, rest.yaml:8065) and no
  `u`, so it cannot anchor a `@depth`/`@depthFast` diff stream: the vendor's own sequence
  check (`WsDecode.depth_gap?/2`) compares one `u` against the next frame's `U`, and a REST
  call has neither. The diff streams are available through `subscribe/3` (below); they are
  not carried by default, and `Feed` never subscribes them.

  ## A depth diff stream needs its own anchor

  The vendor's rule (websocket.yaml:1263-1270): with the `snapshot` **connection** parameter
  set, the FIRST `depthUpdate` frame per symbol after (re)subscribing carries absolute levels
  — "there is no separate snapshot message and no lastUpdateId field" — and every frame after
  it is an ordinary diff. The parameter is set once, at the WebSocket upgrade
  (`Environment.websocket_url/2`), so a caller declares its intent to carry
  `:depth`/`:depth_fast` through `start_link/1`'s `:channels` option, before this socket ever
  dials the venue — there is no way to add it after connecting.

  A connection started that way delivers the first post-(re)subscribe `depthUpdate` per
  symbol as `Core.Types.OrderBook` (`WsDecode.to_order_book_from_depth_update/3`) and every
  one after it as `Core.Types.OrderBookDelta` (`WsDecode.to_order_book_delta/2`), tracked per
  symbol in `depth_anchored` and reset on every connect — a reconnected socket carries no
  subscriptions, so the next frame for any symbol is an anchor again, exactly as a fresh
  subscribe would produce one.

  A connection started WITHOUT `:depth`/`:depth_fast` in `:channels` never sets the
  parameter, and every `depthUpdate` on it is delivered as a diff — the behaviour this socket
  had before the parameter existed, and still the right one for a connection the venue was
  never told to anchor. Such a connection cannot REBUILD a book after a gap, which is why a
  gap on it stops the symbol instead of resynchronising it (next section).

  **A symbol is on one diff channel at a time.** `@depth` and `@depth@100ms` frames cannot be
  told apart, so `subscribe/3` refuses `:depth` for a symbol on `:depth_fast` (and the
  reverse) with `{:error, {:conflicting_depth_channel, symbol}}`. Unsubscribe first to switch.

  ## A partial-depth snapshot cannot name its own symbol

  `@depth5`/`@depth10`/`@depth20` (and their `…@100ms` siblings) answer with
  `OrderBookSnapshot` (websocket.yaml:1217-1233): `required: [lastUpdateId, bids, asks]`,
  no `s`, and no combined-stream wrapper names one either — read the whole document and
  nothing attributes one of these frames to a stream. The only attribution this socket can
  make without guessing is "this connection carries exactly one such channel, for exactly one
  symbol", so `subscribe/3` refuses a second, distinct symbol against any of
  `WsChannels.partial_depth/0` on the same connection with `{:error,
  {:partial_depth_symbol_conflict, existing_symbol}}`, and a frame that arrives while none — or
  more than one, which should not be reachable through `subscribe/3` but is not assumed
  impossible — is claimed raises a `:data_quality` notice rather than vanishing.

  ## A depth gap raises one notice, and the consumer must discard that book

  A `depthUpdate` whose `U` skips ahead of the last applied `u` raises a `:data_quality`
  notice (`details.reason: :sequence_gap`, words in `details.message`), as does a sequence
  that goes BACKWARDS by more than one frame's span (`:sequence_restart`: the venue reset
  its counter). An undecodable depth update is `:data_quality` too
  (`:undecodable_depth_update`); `:degraded` is kept for "a slower path is in use". The
  first notice is the instruction to discard that symbol's book. A replay (`u` at or just
  behind the last applied) is dropped without one.

  **On a connection started without the `snapshot` parameter, a gap stops the symbol.** The
  parameter is per connection (websocket.yaml:1264), so a resubscribe there brings diffs
  only and no book can be rebuilt from it. The symbol is marked stopped, announced by a
  `:coverage_change` notice (`details.delivering: false`, reason "depth book cannot be rebuilt
  on a connection without the snapshot parameter"), and every frame for it is dropped until
  the caller subscribes it again and rebuilds its book (`get_order_book/2`, or a connection
  started with `:depth`/`:depth_fast` in `:channels`). Unsubscribing, or a reconnect, also
  clears the mark. A frame fed to a state that records no depth subscription is delivered, as
  before, after the notice.

  On a `snapshot` connection this socket resynchronises the symbol itself, per
  `{symbol, channel}` (`depth_streams`, recorded by `subscribe/3`): unsubscribe, wait for
  that unsubscribe's answer (matched by its own id), subscribe, and take the first
  frame after it as the snapshot. Every frame for the symbol is dropped meanwhile, so the
  consumer receives nothing for it until the snapshot, which is the signal that the book is
  whole again. At most one resync per key per 5s; a gap inside that window waits out the rest
  of it, and a resync that fails (the subscribe refused, or the unsubscribe never answered)
  is announced as a `:coverage_change` notice with `details.delivering: false` and retried
  after a doubling backoff, to 60s. A refused subscribe also takes the symbol out of
  `depth_streams`. Depth is not a `coverage/1` kind, so the notice is the not-delivering
  signal. UNMEASURED: that the venue answers an unsubscribe and writes nothing of the old
  subscription after the answer; if it does not, the retries are the only recovery. An
  undecodable trade frame likewise raises one `:data_quality` notice (`:undecodable_trade`)
  per frame, rather than being dropped in silence.

  ## What is reported when a frame cannot be read, and when the link is down

  A text frame that is not a JSON object raises one `:data_quality` notice
  (`details.reason: :undecodable_frame`, `details.bytes`: its size, never its text), as an
  unreadable trade, book ticker or depth frame does. A depth diff that arrives for a symbol
  with no depth subscription on a `snapshot` connection (in flight when it was unsubscribed)
  is dropped without a notice: left to the anchor rule above it would have been delivered as
  an absolute `OrderBook` holding only the changed levels.

  One `link_down` closes one `link_up`. `websockex` calls `handle_disconnect/2` again for every
  failed reconnect, and only the first call after a connect reports the loss (notice and
  `[:dp_exchange, :link, :down]`); each attempt is still visible as
  `[:dp_exchange, :link, :reconnect_attempt]`.

  ## Event time is nanoseconds

  The `E` field is **nanoseconds** since the epoch, not milliseconds. The difference is a
  factor of a million: read as milliseconds, a 2026 timestamp lands in the year 58,000 and
  every staleness check passes forever. Converted once, in `WsDecode.nanosecond_time/1` —
  every frame handler here reaches that through one of `WsDecode`'s decoders rather than
  parsing `E` a second time.

  ## A dead connection is found by pinging it

  A network path can die without either end being told. TCP notices only when it next
  sends, and this socket sends almost nothing once subscribed, so a half-open connection
  stayed "connected", delivering nothing, for as long as the operating system's own
  timeouts allowed. A quiet market cannot be told from that by silence alone, and this
  venue pushes no heartbeat frame and numbers no stream (no `socket_sequence`; the only
  sequence on the wire is a depth diff's `U`/`u`, below).

  Its AsyncAPI document does list request methods named `ping`, `time` and `conninfo`
  (`docs/reference/gemini/asyncapi/websocket.yaml`, `PingRequest`), but models the request
  envelope only: **the reply to `{"method":"ping"}` is not enumerated**, and nothing here has
  measured one. A liveness check that waited for a reply of unknown shape could neither be
  written nor tested, so this socket does not send it.

  RFC 6455 gives one that needs no venue claim: an endpoint answers a ping with a pong.
  Each connection pings every `@ping_every_ms` (30s), and a frame or a pong counts as being
  heard from. After `@silence_ms` (90s, three pings) with nothing heard, it raises a
  `:degraded` notice (`details.reason: :silent_connection`) and closes. **The silence is
  judged only on a ping tick**, so a connection that fell silent is closed between 90s and
  just under 120s after it was last heard, not at 90s to the second. That takes the
  ordinary `handle_disconnect/2` path: `:link_down`, reconnect, `:reconnected`, resend. The
  check carries this connection's ref and a stale one is not re-armed, so reconnects
  cannot stack check chains. Both clocks are `System.monotonic_time/1`, so a wall-clock step
  neither closes a healthy connection nor keeps a dead one open.

  ## A connection that answers pings but not subscribes is not serving

  The ping check above cannot see a server that is shutting down. Measured 2026-10-02 in
  the host's log: the venue closed this socket with `1012 "Server shutting down"`, the
  reconnect succeeded within a second, the resubscribe went out, and for three minutes 90%
  of the subscribed pairs delivered nothing while the connection kept answering pings. Only
  the host's own watchdog noticed. The venue's outage outlasted that window, so earlier
  detection would not have restored data that night, but the package reported a healthy
  link the whole time, which is the half-dead feed this family ranks worst.

  The venue answers every subscribe request with `{"id":<the request's id>,"status":200}`
  (`GenericSuccessResponse` in `docs/reference/gemini/asyncapi/websocket.yaml`). Measured
  2026-10-02, with every request then sent as `id: 1`, against both `ws.gemini.com` and
  `ws.sandbox.gemini.com`: a first subscribe, the same streams again, and a mix of
  subscribed and new streams were each answered within about 550ms. A repeat is answered too, which matters because `Feed` resubscribes every 60s to
  streams already subscribed. So `subscribe/3` tells this process a request is out, and if
  `@ack_timeout_ms` passes with that request still unanswered, it raises a `:degraded` notice
  (`details.reason: :subscribe_unanswered`) and closes, taking the same reconnect path as a
  silent connection. Silence in the market data alone is never the trigger, because a feed
  watching a few illiquid pairs can be quiet for minutes. An unanswered request has no such
  innocent reading.

  **Each request has its own deadline, armed when it is announced.** One deadline used to
  cover every request outstanding when it was armed, so a request sent 14s after it was armed
  could be closed 1s after it was sent, long before the venue had been given the window the
  first one was. **Requests are matched to answers by id, not by order.** Answers used to
  carry only the request kind (`id: 1`), so they were retired oldest first, and a request
  announced before another but sent after it (a resync's subscribe landing between a caller's
  announce and its frame) retired the wrong one. Every subscribe and unsubscribe now has a
  unique id, the announce names it (`{:awaiting_ack, id}`), the deadline names it, an answer
  retires exactly that request and a request whose frame never went out is withdrawn by its
  id (`{:ack_withdrawn, id}`). `ack_requests` holds `{id, timer}` oldest first;
  `ack_deadline` is the oldest one's id and `unanswered_subscribes` the count. UNMEASURED:
  that the live venue echoes an integer id other than 1 and 2; if it did not, no subscribe
  would be answered and this very deadline would close the connection, loudly.
  """

  alias DpExchange.Core.{Config, Notice, Telemetry}
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Gemini.{Credentials, Environment, SymbolFormat, WsChannels, WsDecode}

  # `use`, `start_link/4` and `send_frame/2` go to this package's vendored fork, never the
  # real `WebSockex`, whose `open_loop/3` has no handshake deadline and whose
  # `websocket_loop/3` crashes on a malformed close frame. See
  # `DpExchange.Gemini.Vendor.WebSockex`. Aliased as `VendoredWebSockex`, never over
  # `WebSockex`, so `WebSockex.Conn` and the rest still name the real dependency's modules.
  alias DpExchange.Gemini.Vendor.WebSockex, as: VendoredWebSockex

  use VendoredWebSockex

  require Logger

  # Chosen against `Feed.@call_timeout` (25s: five 5s frame windows), not inherited from
  # `websockex`'s own general-purpose defaults (6s connect + 5s recv — measured from
  # `deps/websockex/lib/websockex/conn.ex:10-11`, which `start_link/1` used to pass no
  # opts at all and so accepted by accident). `Feed` dials asynchronously now, so a slow
  # connect no longer holds its mailbox, but the CALLER of `subscribe/3` still waits for the
  # connect and then one `send_frame` for the subscribe (`@frame_window_ms`, 5s; two with
  # `:trades` on): 3s + 2s + 5s = 10s (15s with two frames), inside the caller's
  # `@call_timeout`. See `Feed`'s moduledoc.
  @socket_connect_timeout_ms 3_000
  @socket_recv_timeout_ms 2_000

  # See the moduledoc's "A dead connection is found by pinging it".
  @ping_every_ms 30_000
  @silence_ms 90_000

  # See the moduledoc's "A connection that answers pings but not subscribes is not serving".
  # Generous on purpose: the acks this was set against arrive in well under a second, and a
  # false close costs a reconnect.
  @ack_timeout_ms 15_000

  @base_reconnect_delay_ms 1_000
  @max_reconnect_delay_ms 30_000

  @doc """
  How long to wait before the reconnect that `attempt` is about to make.

  **`websockex` reconnects with no delay of its own.** `on_disconnect/5` in
  `deps/websockex/lib/websockex.ex` calls `open_connection/3` and, on failure, calls itself
  with `attempt + 1` — a synchronous loop with nothing between the turns. So a socket the
  venue will not accept back reconnects at full connect speed, forever, and the things that
  cause it are exactly the things that do not fix themselves by being retried sooner:
  credentials the venue has stopped honouring, an IP it has started refusing, a maintenance
  window, a 503. CLAUDE.md's own testing tiers say what a venue does about traffic like
  that — "a venue that sees a package polling it on a timer will rate-limit or block" — and
  a reconnect storm is that, without the timer.

  **Attempt 1 waits nothing.** It is a live session that just dropped, and nothing about an
  ordinary network blip suggests waiting helps. Every attempt after it is a reconnect that
  has already failed at least once, so the wait doubles from #{@base_reconnect_delay_ms}ms,
  capped at #{@max_reconnect_delay_ms}ms.

  The same shape, and the same two constants, as `DpExchange.Schwab.Socket`'s
  `reconnect_delay_ms/1`, which had this venue family's only reconnect backoff until now.
  Its counter is `LOGIN_DENIED`s specifically because that venue can name its own auth
  rejection; here the counter is `websockex`'s consecutive-failure count, which needs no
  venue-specific signal and is already correct for every reason a reconnect can fail.
  """
  # Integer shifting, not `:math.pow/2`, and the exponent is clamped BEFORE the shift.
  #
  # `:math.pow(2, n)` is float arithmetic and raises `ArithmeticError` once `n` passes 1023,
  # because the float range ends at ~1.8e308. Clamping the RESULT — `min(base * pow, max)` —
  # does not help: the raise happens while computing the argument to `min/2`. So the
  # function written to survive a reconnect storm crashed during a long one, at roughly
  # attempt 1025, which at the 30-second cap is about 8.5 hours of continuous failure. That
  # is an ordinary overnight outage or an access token nobody has refreshed yet, and the
  # crash lands inside `handle_disconnect/2` where it reads as this socket's fault rather
  # than the venue's.
  #
  # `Bitwise.bsl/2` has no such ceiling and is exact. The clamp exists only so the
  # intermediate cannot grow without bound — the cap is already reached at exponent 5
  # (`2^5 * @base_reconnect_delay_ms` exceeds `@max_reconnect_delay_ms`), so every clamped
  # value produces the identical answer the unclamped one would have.
  @max_backoff_exponent 30

  @spec reconnect_delay_ms(pos_integer()) :: non_neg_integer()
  def reconnect_delay_ms(attempt) when is_integer(attempt) and attempt <= 1, do: 0

  def reconnect_delay_ms(attempt) when is_integer(attempt) do
    exponent = min(attempt - 2, @max_backoff_exponent)

    min(@base_reconnect_delay_ms * Bitwise.bsl(1, exponent), @max_reconnect_delay_ms)
  end

  @doc """
  `delay_ms` shortened by a random amount of up to a quarter of itself, never lengthened.

  **Every socket the venue drops is dropped together, and they all retried together.** This
  package opens one socket per `Feed` (no sharding, see `Feed`'s moduledoc), and a
  venue-side restart or a network fault closes the socket of every `Feed` a consumer runs,
  and of every node in a consumer's fleet, in the same instant. `reconnect_delay_ms/1` is a
  pure function of the attempt number, so all of them then retried on identical schedules:
  1s, 2s, 4s, 8s... together, a connect burst on every turn of the ladder, at the one time
  a venue is already refusing connections. A random shortening per socket spreads the turns
  apart.

  Only shortened, so `reconnect_delay_ms/1` stays the ceiling it documents (30 seconds).
  `0` stays `0`: attempt 1 is a live session that just dropped and reconnects at once.
  """
  @spec jittered_delay_ms(non_neg_integer()) :: non_neg_integer()
  def jittered_delay_ms(delay_ms) when is_integer(delay_ms) and delay_ms < 4, do: delay_ms

  def jittered_delay_ms(delay_ms) when is_integer(delay_ms),
    do: delay_ms - :rand.uniform(div(delay_ms, 4))

  @doc """
  The `websockex` connection opts `start_link/1` passes to `VendoredWebSockex.start_link/4` —
  `:socket_connect_timeout` and `:socket_recv_timeout`, defaulted to this module's own
  budget (see the moduledoc) and overridable by `opts`.

  Exposed as its own function, rather than inlined, so the budget the moduledoc claims can
  be pinned by a test without opening a connection. (`start_link/1` itself dials for real;
  its own tests stand up a local TCP server for it.) And so a later
  refactor cannot silently drop either the explicit values or the override path back to
  `websockex`'s own accidental defaults.

  **Their sum is also the whole handshake's deadline.** `:socket_recv_timeout` alone
  bounds each `recv` of the upgrade response, not the response, so a peer that trickled it
  held a start or a reconnect open indefinitely. The vendored
  `DpExchange.Gemini.Vendor.WebSockex` ends the handshake at connect plus recv. That is
  pinned against a local TCP server in `socket_vendored_websockex_test.exs`.
  """
  @spec connect_opts(keyword()) :: keyword()
  def connect_opts(opts) do
    # `Credentials.unwrap_ssl/1`: the tree wraps a caller's `:ssl_options` so a supervisor
    # report cannot print a key or password in it (see that module). Here it is used.
    custom = opts |> Config.opt(:ssl_options, nil) |> Credentials.unwrap_ssl()
    timeout_opts(opts) ++ [ssl_options: ssl_options(custom)]
  end

  defp timeout_opts(opts) do
    [
      socket_connect_timeout:
        Config.opt(opts, :socket_connect_timeout, @socket_connect_timeout_ms),
      socket_recv_timeout: Config.opt(opts, :socket_recv_timeout, @socket_recv_timeout_ms)
    ]
  end

  # **An explicit `ssl_options: nil` or `[]` is absence, not "none".** `websockex` reads an
  # empty value as no options and starts from `verify: :verify_none`, so a caller (or a
  # `Config` override) that wrote `ssl_options: []` got a socket that accepted any
  # certificate. Absent, `nil`, `[]` and anything that is not a keyword list take the
  # verified defaults. A non-empty list that does not say `:verify` gets verification added
  # underneath it: the caller's keys win, but verification is not silently dropped by
  # omission. Only an explicit `verify: :verify_none` turns it off, and that is the caller
  # saying so.
  defp ssl_options(custom) when is_list(custom) and custom != [] do
    if Keyword.keyword?(custom) do
      if Keyword.has_key?(custom, :verify),
        do: custom,
        else: Keyword.merge(verified_tls(custom), custom)
    else
      verified_tls([])
    end
  end

  defp ssl_options(_absent_or_unusable), do: verified_tls([])

  # **Certificate verification, which `websockex` does not do unless told to.** Its
  # `WebSockex.Conn` starts with `insecure: true`, which is `verify: :verify_none`
  # (`deps/websockex/lib/websockex/conn.ex:24`). No socket in this family passed TLS options,
  # so every `wss://` connection accepted any certificate from anyone. Measured 2026-09-27:
  # against a local TLS server presenting a certificate from a CA nothing trusts, the TLS
  # handshake completed and the client went on to send its upgrade request. Anyone able to
  # sit on the path could have impersonated the venue and read everything sent after the
  # upgrade, credentials included. HTTP was never affected, because Mint verifies by default.
  #
  # The operating system's trust store (`:public_key.cacerts_get/0`, which OTP caches after
  # the first read) and the HTTPS hostname rules, so a venue's wildcard certificate matches.
  # A caller can still pass its own `:ssl_options`, which replace these entirely.
  defp verified_tls(custom) do
    trust =
      if Keyword.has_key?(custom, :cacerts) or Keyword.has_key?(custom, :cacertfile),
        do: [],
        else: [cacerts: load_cacerts()]

    [
      verify: :verify_peer,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ trust
  end

  # `:public_key.cacerts_get/0` RAISES when the operating system has no trust store to read
  # (a minimal container image without `ca-certificates` is the ordinary way to get there).
  # `start_link/1` runs inside `Feed`'s `handle_call`, so the raise crashed the shared feed
  # and every other consumer's subscription with it, and the restarted feed raised again on
  # the next subscribe. It is `{:error, {:tls_trust_store_unavailable, _}}` from `start_link/1`
  # now, and the connection is NOT made unverified: refusing is the only safe answer to "no
  # CA list". `:cacerts_loader` is the test seam, in the same place `:websocket_url` is.
  defp load_cacerts do
    case Config.get(:dp_exchange_gemini, :cacerts_loader, nil) do
      nil -> :public_key.cacerts_get()
      loader -> loader.()
    end
  end

  # A plain `ws://` URL (the `:websocket_url` proxy seam, or a local test server) never does a
  # TLS handshake, so it has no use for a trust store and must not be refused for lacking one.
  # Only a URL that is clearly `ws` skips the TLS options; anything else, a `wss` URL included,
  # takes them, so the failure is toward verification.
  defp tls_connect_opts(url, opts) do
    if plaintext_url?(url), do: {:ok, timeout_opts(opts)}, else: {:ok, connect_opts(opts)}
  rescue
    error in ErlangError ->
      {:error, {:tls_trust_store_unavailable, inspect(error.original, limit: 20)}}
  end

  defp plaintext_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when is_binary(scheme) -> String.downcase(scheme) == "ws"
      _no_scheme -> false
    end
  end

  defp plaintext_url?(_not_a_string), do: false

  @doc """
  `opts` also accepts `:channels` — the channels this connection is DECLARED to carry, used
  only to decide whether to request the venue's `snapshot` connection parameter (see the
  moduledoc's "A depth diff stream needs its own anchor"). It changes nothing about which
  channels can actually be subscribed later; `subscribe/3` still takes a `channel` argument
  of its own, and this is a one-time hint made before the socket ever connects, because the
  parameter cannot be added after the WebSocket upgrade. Omit it, or leave `:depth` and
  `:depth_fast` out of it, and this socket behaves exactly as it always has.

  **`async: true` returns `{:ok, pid}` at once and dials inside the socket process.** This is
  how `Feed` dials, so that no `Feed` callback waits out a connect. The first successful
  connect is then reported to the subscriber as `{:dp_exchange, :gemini, :connected, pid}`
  (a re-connect is `:reconnected`, as ever), and a first connect that fails ends the process
  with exit reason `{:error, reason}`, which the linked starter sees as an `EXIT`. Without it
  `start_link/1` blocks until connected and answers `{:error, reason}` itself.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    # **A forwarded `url: nil` is no URL, and takes the default.** `Feed` forwards its own
    # `opts` with `Keyword.take/2`, so a consumer's `url: nil` (the shape this family's
    # forwarded opts produce when nothing upstream set it) arrived here present and `nil`.
    # `Keyword.get_lazy/3` only defaults an ABSENT key, so `nil` went on as the URL and
    # `URI.parse/1` raised inside `Feed`'s `handle_call`. `Config.opt/3` reads `nil` as absent.
    url =
      case Config.opt(opts, :url, nil) do
        nil -> default_url(opts)
        explicit -> explicit
      end

    async? = Keyword.get(opts, :async, false) == true

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      # Whether the FIRST connect is reported to the subscriber as `{:dp_exchange, :gemini,
      # :connected, pid}`. Set exactly when this socket dials asynchronously: `Feed` then has
      # no other way to learn the connect finished. See `start_link/1`'s `:async`.
      report_connect?: async?,
      # The process that started this socket (`Feed`, or a test), for `wait_to_reconnect/2`:
      # the link to it is how this socket learns it was stopped, and a backoff has to keep
      # listening for that.
      parent: self(),
      request_id: 0,
      # Whether `handle_connect/2` has run before — so only a RE-connect is reported to
      # `Feed`. See `report_reconnected/1`.
      connected_once?: false,
      # When anything, a frame or a pong, last arrived, and this connection's liveness
      # check. See the moduledoc's "A dead connection is found by pinging it".
      last_heard_at: nil,
      liveness: nil,
      # Whether THIS connection asked the venue for the `snapshot` parameter — decided once,
      # from `opts`, because the parameter is set at the WebSocket upgrade and there is no
      # way to add it once connected. Read via `state[:depth_snapshot?]` elsewhere, so a bare
      # test-built state map that omits this key still reads the same default (falsy) this
      # field starts at.
      depth_snapshot?: depth_snapshot?(opts)
    }

    with {:ok, connect} <- tls_connect_opts(url, opts) do
      connect = if async?, do: Keyword.put(connect, :async, true), else: connect
      VendoredWebSockex.start_link(url, __MODULE__, state, connect)
    end
  end

  @doc """
  The longest a first connect can legitimately take: `:socket_connect_timeout` plus
  `:socket_recv_timeout`, which is the vendored handshake deadline (see `connect_opts/1`).

  `Feed` arms its own timer from this, as a net under an asynchronous dial that never reports.
  """
  @spec dial_budget_ms(keyword()) :: pos_integer()
  def dial_budget_ms(opts) do
    timeouts = timeout_opts(opts)
    connect = Keyword.fetch!(timeouts, :socket_connect_timeout)
    connect + Keyword.fetch!(timeouts, :socket_recv_timeout)
  end

  # The venue's own endpoint, unless the application config names another with
  # `:websocket_url`. The seam exists for tests. A tier-1 run sets it in `config/test.exs` to
  # a closed local port, so a socket that no test aimed elsewhere fails at once instead of
  # dialling the venue. Measured 2026-09-27: this package's suite had been opening live
  # connections to the venue on every run, from tests that never meant to. A consumer can
  # use it for a proxy. `config/` does not ship, so a consumer's default is still the venue.
  defp default_url(opts) do
    Config.get(:dp_exchange_gemini, :websocket_url, nil) ||
      opts |> Environment.resolve() |> Environment.websocket_url(snapshot_url_opts(opts))
  end

  defp depth_snapshot?(opts), do: Enum.any?(Keyword.get(opts, :channels, []), &depth_channel?/1)

  defp depth_channel?(channel), do: channel in [:depth, :depth_fast]

  defp snapshot_url_opts(opts) do
    # `-1`: the full book, not a guessed top-N. The vendor's own words for the alternative —
    # "a positive N for the top N levels" — describe a DIFFERENT, narrower anchor this
    # package has no basis to pick a value for; `-1` is the one option that is not a guess.
    if depth_snapshot?(opts), do: [snapshot: -1], else: []
  end

  # **Request ids.** Every request was `id: 1`, so an `unsubscribe` answer was counted as a
  # subscribe's and could clear the ack deadline while a real subscribe was still unanswered;
  # then ids 1 and 2 told the KINDS apart but not the requests, so answers were matched in
  # announce order, and an announce that raced its frame (a resync subscribe sent between a
  # caller's announce and send) retired the wrong request. Now EVERY subscribe and unsubscribe
  # carries an id of its own (`next_request_id/0`; the spec, websocket.yaml `CorrelationId`:
  # "Client-chosen id, echoed on the matching response") and its answer is matched by that id
  # in `note_answer/2`. UNMEASURED against the live venue: that it echoes an integer id other
  # than 1 and 2. If it did not, no subscribe would ever be answered and `@ack_timeout_ms`
  # would close the connection, loudly, rather than anything being guessed.
  defp next_request_id, do: System.unique_integer([:monotonic, :positive])

  # A depth resync (family rule MD9): at most one per `{symbol, channel}` in this window, and
  # a resync that failed waits twice as long each time, to the cap.
  @resync_min_gap_ms 5_000
  @resync_max_backoff_ms 60_000
  @until_resync "until a resync completes"

  @doc """
  Subscribes the connection to `channel` for each symbol.

  `channel` defaults to `:book_ticker`, which is the only channel this socket delivered
  before the AsyncAPI document was read. **The address is built by `WsChannels`**, not
  concatenated here — the interval is part of the address for the `…Fast` and `…Snapshot`
  channels, and a hand-assembled `"{symbol}@depthFast"` subscribes to nothing and produces
  silence rather than an error.

  A per-account channel takes no symbols: pass `[]`.

  **A non-empty `symbols` against a channel that takes none is refused here**, with
  `{:error, {:channel_takes_no_symbol, channel}}`, rather than reaching `streams/2` and
  silently subscribing to nothing — see `WsChannels.address/2`'s own moduledoc for the
  shape of that failure. **A channel `WsChannels.requires_credential?/1` marks private is
  refused too**, with `{:error, {:credential_required, channel}}`: this socket never
  authenticates its connection, so a private channel can only ever fail at the venue, and
  telling a caller before the round trip is the whole reason that function exists.

  **A symbol is on one diff channel at a time**: `:depth` for a symbol that is on
  `:depth_fast` (or the reverse) is refused with `{:error, {:conflicting_depth_channel,
  symbol}}`, because their frames cannot be told apart. A second distinct symbol on a
  partial-depth channel is refused with `{:error, {:partial_depth_symbol_conflict, symbol}}`
  (see the moduledoc's "A partial-depth snapshot cannot name its own symbol").

  Returns an error rather than exiting when the socket will not accept the frame — a caller
  can retry a batch, but it cannot recover from a linked exit it did not expect. **Which
  error says what to do about it**: `{:error, :send_timeout}` is a socket that did not
  acknowledge in time and is worth retrying, since the frame may well have landed and
  subscribes are idempotent here; `{:error, {:send_exit, reason}}` is a socket that is gone,
  which no number of retries reaches. See `send_rpc/4` for why flattening the two was wrong.
  """
  @spec subscribe(pid(), [String.t()], atom()) :: :ok | {:error, term()}
  def subscribe(socket, symbols, channel \\ :book_ticker) do
    with :ok <- validate_channel(symbols, channel),
         {:ok, fresh_depth} <- claim_depth_channel(socket, symbols, channel),
         {:ok, claimed?} <- claim_partial_depth(socket, symbols, channel) do
      streams = streams(symbols, channel)
      id = next_request_id()
      await_ack(socket, streams, id, symbols)

      case send_rpc(socket, "subscribe", streams, id) do
        :ok ->
          :ok

        # The frame did not go out, so no answer is coming. Left counted, the ack deadline
        # fired 15 s later and closed a healthy connection, and every retry counted again.
        # A claim THIS call took is given back too: left, it refused a different symbol on
        # a channel nothing was subscribed to. A claim that was already held stays.
        error ->
          withdraw_ack(socket, streams, id)
          release_depth_channel(socket, fresh_depth)
          if claimed?, do: release_partial_depth(socket, symbols, channel)
          error
      end
    end
  end

  # **A symbol is on ONE diff channel at a time.** `@depth` and `@depth@100ms` frames carry
  # the same `e`, `s`, `U` and `u` and nothing that says which stream they came from, so with
  # both live the sequence check judges one stream's frames against the other's and a resync
  # cannot tell whose snapshot the first frame is. A second depth channel for a symbol that is
  # on the other is refused, before any frame is sent, with
  # `{:error, {:conflicting_depth_channel, symbol}}`; unsubscribe the first to switch.
  #
  # Which diff channel each symbol is on is also what lets a sequence gap resubscribe the
  # right stream, so it is recorded here, in ONE `:sys.replace_state/3` with the check (two
  # concurrent subscribes on the two channels cannot both pass). Forgotten by `unsubscribe/3`,
  # and by a reconnect. Subscribing a symbol again also lifts its `depth_stopped` mark (see
  # `declare_gap/5`) and forgets its sequence, so the first frame of the new subscription is
  # judged against nothing. Returns the keys THIS call added, for `release_depth_channel/2`.
  defp claim_depth_channel(socket, symbols, channel) when channel in [:depth, :depth_fast] do
    other = if channel == :depth, do: :depth_fast, else: :depth
    canonical = canonical_symbols(symbols)
    caller = self()
    token = make_ref()

    claim = fn state ->
      streams = depth_streams(state)

      case Enum.find(canonical, &MapSet.member?(streams, {&1, other})) do
        nil ->
          fresh =
            for symbol <- canonical,
                not MapSet.member?(streams, {symbol, channel}),
                do: {symbol, channel}

          send(caller, {token, {:ok, fresh}})
          claim_depth_keys(state, streams, canonical, channel)

        symbol ->
          send(caller, {token, {:error, {:conflicting_depth_channel, symbol}}})
          state
      end
    end

    case sys_replace_state_returning(socket, claim) do
      {:ok, _state} ->
        # Deliberately defensive. Any process speaking `:sys` runs `claim` before it replies,
        # and the claim's own message reaches this process before that reply, so a real socket
        # always answers here. A process that acknowledged the replace without running it
        # recorded nothing, so there is nothing of this call's to give back: `{:ok, []}`,
        # never a wait.
        receive do
          {^token, result} -> result
        after
          0 -> {:ok, []}
        end

      # A socket that is gone or does not speak `:sys`: nothing was recorded. `send_rpc/4`
      # reports the dead socket itself.
      :error ->
        {:ok, []}
    end
  end

  defp claim_depth_channel(_socket, _symbols, _channel), do: {:ok, []}

  defp claim_depth_keys(state, streams, canonical, channel) do
    stopped = Map.get(state, :depth_stopped, MapSet.new())
    lifted = Enum.filter(canonical, &MapSet.member?(stopped, &1))

    # A caller's own subscribe supersedes a refused resync's pending retry.
    state =
      Enum.reduce(canonical, state, fn symbol, acc ->
        key = {symbol, channel}

        acc
        |> cancel_depth_timer(:retry, key)
        |> Map.update(:depth_retry, %{}, &Map.delete(&1, key))
      end)

    state
    |> Map.put(:depth_streams, MapSet.union(streams, MapSet.new(canonical, &{&1, channel})))
    |> Map.put(:depth_stopped, MapSet.difference(stopped, MapSet.new(lifted)))
    |> Map.update(:last_depth_update, %{}, &Map.drop(&1, lifted))
    |> Map.update(:depth_anchored, MapSet.new(), &MapSet.difference(&1, MapSet.new(lifted)))
  end

  defp release_depth_channel(_socket, []), do: :ok

  defp release_depth_channel(socket, keys) do
    sys_replace_state(socket, fn state ->
      Map.update(state, :depth_streams, MapSet.new(), &MapSet.difference(&1, MapSet.new(keys)))
    end)
  end

  defp canonical_symbols(symbols),
    do: Enum.map(symbols, &SymbolFormat.to_canonical_symbol(SymbolFormat.to_exchange_symbol(&1)))

  # Only reached when the subscribe frame failed, and `send_rpc/4` never fails an empty
  # address list (it sends nothing and answers `:ok`), so `_streams` is never `[]` here. The
  # `[]` clause that used to sit above this one could not be reached and was removed.
  defp withdraw_ack(socket, _streams, id) do
    case GenServer.whereis(socket) do
      pid when is_pid(pid) -> send(pid, {:ack_withdrawn, id})
      _not_running -> :ok
    end
  end

  # Sent BEFORE the frame, from the same process, so this socket always hears that a request
  # is out before it can hear the answer. An empty address list sends nothing and so expects
  # nothing. A socket that cannot be found is not told: `send/2` to an unregistered name
  # raises, and `send_rpc/4` already turns that same missing socket into a reported error.
  defp await_ack(_socket, [], _id, _symbols), do: :ok

  defp await_ack(socket, _streams, id, symbols) do
    case GenServer.whereis(socket) do
      pid when is_pid(pid) -> send(pid, {:awaiting_ack, id, canonical_symbols(symbols)})
      _not_running -> :ok
    end
  end

  @doc """
  Unsubscribes the connection from `channel` for each symbol.

  Refuses the same two shapes `subscribe/3` does, for the same reasons — see its doc. Also
  releases any `WsChannels.partial_depth/0` claim `subscribe/3` made for these symbols on
  this channel, so a different symbol can be claimed afterward — see the moduledoc's "A
  partial-depth snapshot cannot name its own symbol".
  """
  @spec unsubscribe(pid(), [String.t()], atom()) :: :ok | {:error, term()}
  def unsubscribe(socket, symbols, channel \\ :book_ticker) do
    with :ok <- validate_channel(symbols, channel),
         :ok <- send_rpc(socket, "unsubscribe", streams(symbols, channel), next_request_id()) do
      # Only after the frame went out. Reset first, a send that failed left the stream still
      # flowing while the socket treated its next diff as the absolute anchor, and dropped
      # the partial-depth claim that attributes its frames.
      release_partial_depth(socket, symbols, channel)
      forget_depth(socket, symbols, channel)
      :ok
    end
  end

  # **A depth unsubscribe forgets the book's sequence and anchor.** The vendor's answer to a
  # gap is "discard the book and resubscribe" (websocket.yaml:1264-1270), and a resubscribe
  # on the same connection makes the venue send a fresh absolute snapshot. Left anchored,
  # that snapshot was decoded as a diff, and a consumer applying it kept every stale level.
  # Left with the old `u`, its first frame was judged against a sequence it does not continue.
  @depth_channels [:depth, :depth_fast | WsChannels.partial_depth()]

  defp forget_depth(socket, symbols, channel) when channel in @depth_channels do
    canonical = canonical_symbols(symbols)

    keys = Enum.map(canonical, &{&1, channel})

    sys_replace_state(socket, fn state ->
      state
      |> cancel_depth_timers(keys)
      |> Map.update(:depth_anchored, MapSet.new(), &MapSet.difference(&1, MapSet.new(canonical)))
      |> Map.update(:last_depth_update, %{}, &Map.drop(&1, canonical))
      |> Map.update(:depth_streams, MapSet.new(), &MapSet.difference(&1, MapSet.new(keys)))
      |> Map.update(:depth_stopped, MapSet.new(), &MapSet.difference(&1, MapSet.new(canonical)))
      |> Map.update(:depth_resync, %{}, &Map.drop(&1, keys))
      |> Map.update(:depth_retry, %{}, &Map.drop(&1, keys))
      |> Map.update(:depth_resync_at, %{}, &Map.drop(&1, keys))
      |> Map.update(:depth_resync_failures, %{}, &Map.drop(&1, keys))
    end)
  end

  # **A bookTicker unsubscribe forgets the symbol's last reported trade.** `last_trade_price`
  # was only ever reset on connect, so on a long-lived connection every symbol ever
  # subscribed kept an entry after it was dropped. Forgetting it makes a later resubscribe
  # report the current last trade once, the same thing a reconnect already does.
  defp forget_depth(socket, symbols, :book_ticker) do
    canonical = canonical_symbols(symbols)

    sys_replace_state(socket, fn state ->
      Map.update(state, :last_trade_price, %{}, &Map.drop(&1, canonical))
    end)
  end

  defp forget_depth(_socket, _symbols, _channel), do: :ok

  # `symbols == []` against a per-symbol channel is deliberately **not** refused here: it is
  # how a caller registers as a subscriber without asking for anything yet (`Feed.subscribe/3`
  # with an empty symbol list is exactly this), and `streams/2` already answers it with an
  # empty address list rather than a guess. The two shapes this DOES catch are the ones
  # `WsChannels`'s own moduledoc names as silent failures: a channel given symbols it cannot
  # take, and a private channel this socket can never authenticate for.
  defp validate_channel(symbols, channel) do
    case WsChannels.requires_credential?(channel) do
      true ->
        {:error, {:credential_required, channel}}

      false ->
        validate_symbol_shape(symbols, channel)

      # Unknown channel: `streams/2` already answers this with an empty list rather than a
      # guessed address — see its own "an unknown channel yields no address" test. Refusing
      # it twice over, in two different shapes, would be redundant rather than safer.
      {:error, _reason} ->
        :ok
    end
  end

  defp validate_symbol_shape(symbols, channel) do
    if symbols != [] and channel not in WsChannels.per_symbol() do
      {:error, {:channel_takes_no_symbol, channel}}
    else
      :ok
    end
  end

  # See the moduledoc's "A partial-depth snapshot cannot name its own symbol". A channel
  # outside `WsChannels.partial_depth/0`, or an empty symbol list, needs no claim.
  # `{:ok, claimed?}`: whether THIS call took a claim that was not held before.
  defp claim_partial_depth(_socket, [], _channel), do: {:ok, false}

  defp claim_partial_depth(socket, symbols, channel) do
    if channel in WsChannels.partial_depth() do
      claim_partial_depth_symbol(socket, symbols, channel)
    else
      {:ok, false}
    end
  end

  # A single call naming more than one DISTINCT symbol against a partial-depth channel is
  # unattributable on its own terms — no history to check, and refusing it costs nothing
  # this venue's frame ordering depends on.
  defp claim_partial_depth_symbol(socket, symbols, channel) do
    case Enum.uniq(symbols) do
      [symbol] ->
        do_claim_partial_depth_symbol(socket, symbol, channel)

      _more_than_one ->
        {:error, {:partial_depth_symbol_conflict, symbols}}
    end
  end

  # **Check and claim in ONE `:sys.replace_state/3`**, whose function runs inside the socket
  # process, so two concurrent `subscribe/3` calls cannot both see "no claim yet" and both
  # claim different symbols. A read with `:sys.get_state/2` followed by a separate write was
  # exactly that race. The outcome is read back from the state the function returned: the
  # claim is there if it was allowed, and absent if another symbol already held it.
  defp do_claim_partial_depth_symbol(socket, symbol, channel) do
    caller = self()
    token = make_ref()

    claim = fn state ->
      held = Map.get(state, :partial_depth_claims, MapSet.new())
      send(caller, {token, MapSet.member?(held, {channel, symbol})})

      case partial_depth_symbols(state) do
        # No claim yet, or the same symbol already claimed on a sibling partial-depth
        # channel (e.g. `@depth5` and `@depth10` for the same symbol both attribute
        # cleanly) — both are fine.
        existing when existing == [] or existing == [symbol] ->
          add_partial_depth_claim(state, channel, symbol)

        _other_symbol ->
          state
      end
    end

    case sys_replace_state_returning(socket, claim) do
      {:ok, state} ->
        claims = Map.get(state, :partial_depth_claims, MapSet.new())
        # Always consumed, so a refused claim leaves nothing in the caller's mailbox.
        held? = claim_was_held?(token)

        if MapSet.member?(claims, {channel, symbol}),
          do: {:ok, not held?},
          else: {:error, {:partial_depth_symbol_conflict, hd(partial_depth_symbols(state))}}

      # A socket this package cannot introspect — not a real process, or one that has
      # already exited. `send_rpc/4` still reports a dead socket on its own; this guard is a
      # best-effort refusal of an AMBIGUOUS frame later, not the boundary that decides
      # whether the frame goes out at all.
      :error ->
        {:ok, false}
    end
  end

  # The socket reported, before it changed anything, whether the claim was already held. No
  # report means it is not known, and a claim that may be someone else's is never released.
  defp claim_was_held?(token) do
    receive do
      {^token, held?} -> held?
    after
      0 -> true
    end
  end

  defp sys_replace_state_returning(socket, fun) do
    {:ok, :sys.replace_state(socket, fun, 2_000)}
  catch
    :exit, _reason -> :error
  end

  defp release_partial_depth(socket, symbols, channel) do
    if channel in WsChannels.partial_depth() do
      sys_replace_state(socket, fn state ->
        Enum.reduce(symbols, state, &remove_partial_depth_claim(&2, channel, &1))
      end)
    else
      :ok
    end
  end

  defp partial_depth_symbols(state) do
    state
    |> Map.get(:partial_depth_claims, MapSet.new())
    |> Enum.map(fn {_channel, symbol} -> symbol end)
    |> Enum.uniq()
  end

  defp add_partial_depth_claim(state, channel, symbol) do
    Map.update(
      state,
      :partial_depth_claims,
      MapSet.new([{channel, symbol}]),
      &MapSet.put(&1, {channel, symbol})
    )
  end

  defp remove_partial_depth_claim(state, channel, symbol) do
    Map.update(state, :partial_depth_claims, MapSet.new(), &MapSet.delete(&1, {channel, symbol}))
  end

  # `:sys.get_state/2` and `:sys.replace_state/2` are the generic OTP "peek/poke a special
  # process's own state" primitives — the same mechanism this package's own tests already use
  # on `Feed` (`:sys.replace_state(feed, fn state -> ... end)`, `feed_test.exs`) and that this
  # socket's own vendored loop implements for `:sys.handle_system_msg/6` at every `receive`
  # (see `lib/vendor/websockex.ex`). They work on THIS socket the same way, because the
  # underlying protocol is `:sys`'s, not `GenServer`'s. A bounded timeout, not the 5s default:
  # a caller here is `subscribe/3`, already budgeted against `Feed.@call_timeout`, and this
  # check must not itself become the slow part of that budget.
  defp sys_replace_state(socket, fun) do
    :sys.replace_state(socket, fun, 2_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The subscription addresses for `symbols` on `channel`.

  Exposed because a caller building a batch needs to know what it is about to ask for, and
  because a channel/symbol mismatch is an error worth seeing before the frame goes out
  rather than as silence afterwards.
  """
  @spec streams([String.t()], atom()) :: [String.t()]
  def streams(symbols, channel \\ :book_ticker)

  def streams([], channel) do
    # A per-account channel has no symbols. One address, not none.
    case WsChannels.address(channel) do
      {:ok, address} -> [address]
      {:error, _reason} -> []
    end
  end

  def streams(symbols, channel) do
    for symbol <- symbols,
        {:ok, address} <-
          [WsChannels.address(channel, SymbolFormat.to_exchange_symbol(symbol))],
        do: address
  end

  defp send_rpc(_socket, _method, [], _id), do: :ok

  defp send_rpc(socket, method, params, id) do
    frame = Jason.encode!(%{"method" => method, "params" => params, "id" => id})
    VendoredWebSockex.send_frame(socket, {:text, frame})
  catch
    # BOUNDARY: `WebSockex.send_frame/2` is `:gen.call` with a 5s default, and on timeout it
    # `exit`s rather than returning. Unconverted, that exit kills whatever sent the frame —
    # here, the `Feed` managing this connection. Turning it into a value is the point.
    #
    # The two exits are now told apart, because `Feed` acts on the difference and this
    # clause used to erase it. `:send_timeout` is this package's documented "retry the
    # batch" signal (see `Feed`'s `@call_timeout` comment), and it is the right answer for a
    # timeout: `:gen.call` giving up waiting does not mean the frame was never delivered,
    # and subscribes are idempotent on this venue, so a retry is harmless.
    #
    # It is the wrong answer for `:noproc`. A socket that is gone will never accept this
    # batch however many times it is re-sent, so "slow, try again" sends the caller round a
    # loop whose exit condition can no longer occur — a nearby substitute where the value
    # stays plausible and only the meaning is wrong, which is the failure this family keeps
    # paying for. `{:send_exit, :noproc}` says the thing that actually needs doing: get a
    # new socket.
    #
    # `dp_exchange_coinbase.FrameSender` splits these two for the same reason and says so;
    # `dp_exchange_webull.Socket.disconnect/2` keeps `{kind, reason}` whole. This copy was
    # the only one of the three that flattened them, and the only one that logged nothing —
    # a failed send that leaves no trace is the silent half-dead feed this family ranks
    # worst.
    :exit, {:timeout, _call} ->
      Logger.warning(
        "[Gemini Socket] #{method}: socket did not accept the frame within WebSockex's 5s " <>
          "send window — reporting a failed send rather than letting the exit take the " <>
          "connection down"
      )

      {:error, :send_timeout}

    :exit, exit_reason ->
      reason = without_frame(exit_reason)
      Logger.warning("[Gemini Socket] #{method}: send exited: #{inspect(reason)}")
      {:error, {:send_exit, reason}}
  end

  # `send_frame/3` exits with `{reason, {module, :call, [pid, frame]}}`, and the frame is the
  # message being sent. Kept, it was logged by `inspect/1` above and handed back in
  # `{:send_exit, _}` to whoever reports it next, which the comment above never intended:
  # it names `{:send_exit, :noproc}`. This venue's frames carry no credential today, but in
  # `dp_exchange_coinbase` the same shape put a subscribe frame's signed JWT into the logs.
  # A failure path must not depend on what happens to be in the payload. Only the reason is
  # kept: `:noproc`, `:normal`, and so on.
  defp without_frame({reason, {_module, :call, _args}}), do: reason
  # Deliberately defensive, and unreachable today: the vendored `send_frame/3` catches every
  # exit of its `:gen.call` and re-exits in the shape above. Kept so that a change to that
  # shape is still reported as `{:send_exit, reason}` rather than raising
  # `FunctionClauseError` inside this `catch` and taking `Feed` down with it.
  defp without_frame(reason), do: reason

  # --- callbacks ----------------------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    notify(state, Notice.new(:link_up, :gemini))

    # The metrics channel alongside the notice channel, never instead of it. A `Core.Notice`
    # is a condition a consumer must ACT on; telemetry is aggregate and lossy by design. A
    # consumer that alarmed on a telemetry gauge would be acting on a channel documented as
    # droppable, and one that graphed notices would be graphing something it is meant to
    # handle. Both fire here because this one event is genuinely both.
    Telemetry.link_up(:gemini)
    if state.connected_once?, do: report_reconnected(state), else: report_connected(state)
    # Every timer of the connection that just went away is cancelled, not left to fire and be
    # ref-checked into nothing: the liveness check, the ack deadlines and the depth resync /
    # retry timers.
    state = cancel_connection_timers(state)
    liveness = make_ref()
    liveness_timer = schedule_liveness(liveness)

    # `Map.merge/2`, not `%{state | ...}` — the four keys below are self-initialising
    # (`Map.get(state, :key, default)` everywhere they are read) rather than required at
    # `start_link/1`, the same idiom the original `last_depth_update` already used before
    # this fix. A bare test-built state map that has never seen a frame legitimately lacks
    # them, and `%{state | ...}` raises `KeyError` on a key it does not already have; a
    # reset must not itself require the thing it is resetting to already exist.
    {:ok,
     Map.merge(state, %{
       connected_once?: true,
       last_heard_at: now_ms(),
       liveness: liveness,
       liveness_timer: liveness_timer,
       depth_timers: %{},
       # A reconnected socket carries no subscriptions (`Feed`'s own moduledoc), so
       # everything below describes a subscription state that no longer exists on the
       # connection that just replaced it:
       #
       # * `last_depth_update` — the vendor's gap rule is PER BOOK (websocket.yaml:
       #   1269-1270); this was one node-wide counter until this fix, which meant a gap
       #   on one symbol's book could be masked, or a healthy one falsely flagged, by
       #   whatever OTHER symbol's frame happened to arrive most recently. Per-symbol now,
       #   and cleared here so a symbol's first frame after a reconnect is never treated
       #   as a gap against an update id from a connection the venue has already forgotten.
       # * `depth_anchored` — which symbols have already had their post-(re)subscribe
       #   anchor frame (see the moduledoc's "A depth diff stream needs its own anchor").
       #   The venue owes a fresh one to each symbol on this new connection.
       # * `partial_depth_claims` — which `WsChannels.partial_depth/0` channel/symbol
       #   pairs this connection has claimed (see "A partial-depth snapshot cannot name
       #   its own symbol"). Nothing is actually subscribed yet on the new connection.
       # * `last_trade_price` — the last `c` this connection reported as a `Quote`, per
       #   symbol (see `deliver_last_trade/3`). A fresh connection has reported nothing,
       #   so its first bookTicker frame for a symbol must deliver a `Quote` again even if
       #   `c` is unchanged from what the OLD connection last said.
       last_depth_update: %{},
       depth_anchored: MapSet.new(),
       # * `depth_resync` — a gap resubscribe in flight on the old connection. The new one
       #   starts with no subscriptions and its own fresh snapshots.
       depth_resync: %{},
       # * `depth_streams`, `depth_stopped` — the depth channels this connection carries and
       #   the symbols stopped for want of a rebuildable book. The new connection carries
       #   none, and a stale `depth_streams` would refuse the other channel
       #   (`:conflicting_depth_channel`) on a connection that has nothing subscribed.
       depth_streams: MapSet.new(),
       depth_stopped: MapSet.new(),
       depth_retry: %{},
       depth_resync_at: %{},
       depth_resync_failures: %{},
       partial_depth_claims: MapSet.new(),
       last_trade_price: %{},
       # A request sent on the old connection is not owed an answer on this one.
       unanswered_subscribes: 0,
       ack_deadline: nil,
       ack_requests: [],
       ack_streams: %{},
       # When this session came up. See `handle_disconnect/2`'s short-session backoff.
       connected_at: now_ms(),
       # A `link_up` was just reported, so the next `handle_disconnect/2` owes the one
       # `link_down` that closes it. See `report_link_down/2`.
       link_open?: true
     })}
  end

  # A session shorter than this is counted as a failed connect for backoff, not a healthy
  # session that dropped. Chosen, not measured: long enough to cover an upgrade the venue
  # completes and then closes at once, short against any real session.
  @short_session_ms 5_000

  # See the moduledoc's "A dead connection is found by pinging it". A check whose ref is not
  # this connection's belongs to one that has since dropped, and is not re-armed.
  @impl true
  def handle_info({:liveness, liveness}, %{liveness: liveness} = state) do
    silent_for = now_ms() - state.last_heard_at

    if silent_for >= @silence_ms do
      notify(
        state,
        Notice.new(:degraded, :gemini,
          message:
            "nothing heard, not even a pong, for #{silent_for}ms — closing the connection " <>
              "and reconnecting",
          details: %{reason: :silent_connection, silent_for_ms: silent_for}
        )
      )

      {:close, Map.merge(state, %{liveness: nil, liveness_timer: nil})}
    else
      timer = schedule_liveness(liveness)
      {:reply, :ping, Map.put(state, :liveness_timer, timer)}
    end
  end

  # See the moduledoc's "A connection that answers pings but not subscribes is not serving".
  # Each announced request arms a deadline of its own, so a request is never closed on the
  # strength of a clock that started before it was sent.
  def handle_info({:awaiting_ack, id}, state) do
    {:ok, add_ack_request(state, id)}
  end

  # The same announce, naming the (canonical) symbols the request subscribes. A refusal of the
  # request reports those symbols (`details.symbols`), which the venue's own answer does not name.
  def handle_info({:awaiting_ack, id, symbols}, state) do
    state = add_ack_request(state, id)
    {:ok, Map.put(state, :ack_streams, Map.put(ack_streams(state), id, symbols))}
  end

  # **The depth resync (family rule MD9), one `{symbol, channel}` at a time.** A gap or a
  # sequence restart puts the key in `depth_resync` as `{:pending, ref}` and schedules
  # `{:resync_depth, key, ref}` after the throttle/backoff delay (`schedule_resync/2`). From
  # there the key moves through four states, and EVERY frame for the symbol is dropped until
  # the last one:
  #
  #   1. `{:pending, ref}`         waiting out the delay.
  #   2. `{:unsubscribing, ref, id}`   the unsubscribe (its own unique id) is out; waiting for
  #                                ITS answer.
  #   3. `{:subscribing, ref}`     that answer came, so the old subscription's frames are
  #                                behind us; the subscribe is about to go out.
  #   4. `{:awaiting, ref, id}`    the subscribe (its own unique id, also the key of its ack
  #                                deadline) is out. The FIRST frame for the symbol now
  #                                is the fresh snapshot (the vendor: "the FIRST frame after
  #                                subscribing is the snapshot"), whether it comes before or
  #                                after the subscribe's own answer, so nothing depends on
  #                                that order.
  #
  # What this does depend on, UNMEASURED: that the venue answers an unsubscribe, and writes
  # no frame of the old subscription after that answer. If it never answers, `:resync_timeout`
  # retries with backoff and a notice rather than waiting forever.
  def handle_info({:resync_depth, key, ref}, state) do
    resync = depth_resync(state)

    cond do
      Map.get(resync, key) != {:pending, ref} ->
        {:ok, state}

      not MapSet.member?(depth_streams(state), key) ->
        state = fire_depth_timer(state, :pending, key, ref)
        {:ok, put_resync(state, Map.delete(resync, key))}

      true ->
        {symbol, channel} = key
        id = next_request_id()

        state =
          state
          |> fire_depth_timer(:pending, key, ref)
          |> arm_depth_timer(:timeout, key, ref, {:resync_timeout, key, ref}, @ack_timeout_ms)
          |> put_resync(Map.put(resync, key, {:unsubscribing, ref, id}))
          |> Map.update(:depth_resync_at, %{key => now_ms()}, &Map.put(&1, key, now_ms()))

        frame = rpc_frame("unsubscribe", id, symbol, channel)
        {:reply, {:text, frame}, state}
    end
  end

  # The unsubscribe was never answered. The venue's state is unknown, so start over (the
  # unsubscribe is idempotent), later, and say so.
  def handle_info({:resync_timeout, key, ref}, state) do
    state = fire_depth_timer(state, :timeout, key, ref)

    case Map.get(depth_resync(state), key) do
      {:unsubscribing, ^ref, _id} ->
        {:ok, resync_failed(state, key, :resync_unsubscribe_unanswered)}

      _moved_on ->
        {:ok, state}
    end
  end

  def handle_info({:resubscribe_depth, key, ref}, state) do
    resync = depth_resync(state)

    cond do
      Map.get(resync, key) != {:subscribing, ref} ->
        {:ok, state}

      not MapSet.member?(depth_streams(state), key) ->
        {:ok, put_resync(state, Map.delete(resync, key))}

      true ->
        subscribe_for_resync(state, key, ref)
    end
  end

  # A resubscribe the venue REFUSED was dropped from `depth_streams` (`refused_resync/3`) and
  # is tried again after a backoff. Skipped if the caller subscribed it again meanwhile (the
  # key is back in `depth_streams`, or the symbol is now on the OTHER diff channel, which
  # `subscribe/3` would refuse) or unsubscribed it (`depth_retry` was forgotten).
  def handle_info({:retry_depth, key, ref}, state) do
    retry = Map.get(state, :depth_retry, %{})

    if Map.get(retry, key) == ref,
      do: retry_depth(fire_depth_timer(state, :retry, key, ref), key, ref),
      else: {:ok, state}
  end

  # The announced request's frame never went out: that request, by its id, is no longer owed
  # an answer. One already answered, withdrawn or forgotten by a reconnect is not found.
  def handle_info({:ack_withdrawn, id}, state) do
    case List.keytake(ack_requests(state), id, 0) do
      nil ->
        {:ok, state}

      {{_id, timer}, rest} ->
        Process.cancel_timer(timer)
        state = put_ack_requests(state, rest)
        {:ok, Map.put(state, :ack_streams, Map.delete(ack_streams(state), id))}
    end
  end

  # A deadline whose request was answered, withdrawn or forgotten by a reconnect is no longer
  # in `ack_requests` and does nothing.
  def handle_info({:ack_deadline, deadline}, state) do
    if List.keymember?(ack_requests(state), deadline, 0) do
      unanswered = length(ack_requests(state))

      notify(
        state,
        Notice.new(:degraded, :gemini,
          message:
            "#{unanswered} subscribe request(s) unanswered, the oldest after " <>
              "#{@ack_timeout_ms}ms, while the connection still answers pings — closing the " <>
              "connection and reconnecting",
          details: %{reason: :subscribe_unanswered, unanswered: unanswered}
        )
      )

      cancel_ack_timers(state)
      {:close, state |> put_ack_requests([]) |> Map.put(:ack_streams, %{})}
    else
      {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp retry_depth(state, key, ref) do
    retry = Map.get(state, :depth_retry, %{})

    if MapSet.member?(depth_streams(state), key) or sibling_depth_stream?(state, key) do
      {:ok, Map.put(state, :depth_retry, Map.delete(retry, key))}
    else
      state =
        state
        |> Map.put(:depth_retry, Map.delete(retry, key))
        |> Map.put(:depth_streams, MapSet.put(depth_streams(state), key))
        |> put_resync(Map.put(depth_resync(state), key, {:subscribing, ref}))

      subscribe_for_resync(state, key, ref)
    end
  end

  # **Depth timers are kept and cancelled, not only ref-checked.** Each of the resync's
  # three timers (`:pending` the throttle/backoff wait, `:timeout` the unanswered-unsubscribe
  # deadline, `:retry` the wait after a refused resubscribe) is held in `depth_timers` as
  # `{kind, key} => {ref, timer}` and cancelled the moment its subject moves on: the resync
  # completes, the symbol is unsubscribed or resubscribed, the connection drops, the socket
  # stops. The ref check in each handler stays as defence for a message already in the
  # mailbox when the cancel ran (`Process.cancel_timer/1` cannot recall a delivered one).
  defp depth_timers(state), do: Map.get(state, :depth_timers, %{})

  defp arm_depth_timer(state, kind, key, ref, message, delay) do
    state = cancel_depth_timer(state, kind, key)
    timer = Process.send_after(self(), message, delay)
    Map.put(state, :depth_timers, Map.put(depth_timers(state), {kind, key}, {ref, timer}))
  end

  defp cancel_depth_timer(state, kind, key) do
    {entry, timers} = Map.pop(depth_timers(state), {kind, key})

    case entry do
      {_ref, timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end

    Map.put(state, :depth_timers, timers)
  end

  defp cancel_depth_timers(state, keys) do
    for kind <- [:pending, :timeout, :retry], key <- keys, reduce: state do
      acc -> cancel_depth_timer(acc, kind, key)
    end
  end

  # The timer for `{kind, key}` just fired with `ref`: forget the handle, but only if it is
  # that timer's. A stale message must not drop a newer timer's handle.
  defp fire_depth_timer(state, kind, key, ref) do
    case Map.get(depth_timers(state), {kind, key}) do
      {^ref, _timer} ->
        Map.put(state, :depth_timers, Map.delete(depth_timers(state), {kind, key}))

      _other ->
        state
    end
  end

  defp cancel_connection_timers(state) do
    cancel_ack_timers(state)

    case Map.get(state, :liveness_timer) do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end

    Enum.each(depth_timers(state), fn {_kind_key, {_ref, timer}} ->
      Process.cancel_timer(timer)
    end)

    Map.merge(state, %{depth_timers: %{}, liveness_timer: nil})
  end

  # A stopping socket leaves no live timer behind.
  @impl true
  def terminate(_reason, state) do
    _state = cancel_connection_timers(state)
    :ok
  end

  defp subscribe_for_resync(state, {symbol, channel} = key, ref) do
    id = next_request_id()
    state = add_ack_request(state, id)
    state = put_resync(state, Map.put(depth_resync(state), key, {:awaiting, ref, id}))
    {:reply, {:text, rpc_frame("subscribe", id, symbol, channel)}, state}
  end

  defp depth_resync(state), do: Map.get(state, :depth_resync, %{})
  defp depth_streams(state), do: Map.get(state, :depth_streams, MapSet.new())

  defp sibling_depth_stream?(state, {symbol, channel}) do
    other = if channel == :depth, do: :depth_fast, else: :depth
    MapSet.member?(depth_streams(state), {symbol, other})
  end

  # A resync that did not complete: counted, announced, and started over after a longer wait.
  defp resync_failed(state, key, reason) do
    failures = Map.get(Map.get(state, :depth_resync_failures, %{}), key, 0) + 1

    state
    |> Map.update(:depth_resync_failures, %{key => failures}, &Map.put(&1, key, failures))
    |> notify_not_delivering(key, reason)
    |> schedule_resync(key)
  end

  # Starts (or restarts) the resync of `key` as `{:pending, ref}` and arms its timer. The wait
  # is the longer of what is left of the `@resync_min_gap_ms` window since the last resync of
  # this key began, and the backoff its failures have earned. A gap inside the window is
  # therefore not a second resync: the symbol is simply not delivering until the timer fires.
  defp schedule_resync(state, key) do
    ref = make_ref()
    delay = resync_delay(state, key)
    state = cancel_depth_timers(state, [key])

    state =
      if delay == 0 do
        send(self(), {:resync_depth, key, ref})
        state
      else
        arm_depth_timer(state, :pending, key, ref, {:resync_depth, key, ref}, delay)
      end

    put_resync(state, Map.put(depth_resync(state), key, {:pending, ref}))
  end

  defp resync_delay(state, key) do
    since_last =
      case Map.fetch(Map.get(state, :depth_resync_at, %{}), key) do
        {:ok, at} -> max(@resync_min_gap_ms - (now_ms() - at), 0)
        :error -> 0
      end

    max(since_last, resync_backoff(Map.get(Map.get(state, :depth_resync_failures, %{}), key, 0)))
  end

  defp resync_backoff(0), do: 0

  defp resync_backoff(failures),
    do: min(@resync_min_gap_ms * Bitwise.bsl(1, min(failures - 1, 10)), @resync_max_backoff_ms)

  # `reason` is an atom, and the words for it ride in `details.message` (family decision D4:
  # `details.reason` is never free text).
  @not_delivering_text %{
    resync_unsubscribe_unanswered: "depth resync unsubscribe unanswered",
    resubscribe_refused: "depth resubscribe refused",
    book_not_rebuildable:
      "depth book cannot be rebuilt on a connection without the snapshot parameter"
  }

  defp notify_not_delivering(state, {symbol, channel}, reason, extra \\ %{}) do
    until = Map.get(extra, :until, @until_resync)
    text = Map.fetch!(@not_delivering_text, reason)

    notify(
      state,
      Notice.new(:coverage_change, :gemini,
        severity: :warning,
        message: "#{text} — #{symbol} is not delivering #{until}",
        details:
          Map.merge(extra, %{
            reason: reason,
            message: text,
            symbol: symbol,
            channel: channel,
            delivering: false
          })
      )
    )

    state
  end

  defp ack_requests(state), do: Map.get(state, :ack_requests, [])
  defp ack_streams(state), do: Map.get(state, :ack_streams, %{})

  # A request owed an answer, keyed by the id its frame carries; that id is also what its
  # deadline message names, so the two cannot be confused with another request's.
  defp add_ack_request(state, id) do
    timer = Process.send_after(self(), {:ack_deadline, id}, @ack_timeout_ms)
    put_ack_requests(state, ack_requests(state) ++ [{id, timer}])
  end

  # `ack_deadline` and `unanswered_subscribes` are derived from `ack_requests` on every
  # change, so the three cannot disagree.
  defp put_ack_requests(state, requests) do
    Map.merge(state, %{
      ack_requests: requests,
      ack_deadline: requests |> List.first() |> deadline_ref(),
      unanswered_subscribes: length(requests)
    })
  end

  defp deadline_ref(nil), do: nil
  defp deadline_ref({deadline, _timer}), do: deadline

  defp cancel_ack_timers(state) do
    Enum.each(ack_requests(state), fn {_deadline, timer} -> Process.cancel_timer(timer) end)
  end

  # **An answer is matched to its request by the id it echoes**, never by order. Any answer
  # counts, a refusal included: the question is whether the connection is being served, and a
  # non-200 is already reported on its own by `handle_message/2`. An id that is not
  # outstanding (answered, withdrawn, timed out, forgotten by a reconnect, or a caller's
  # unsubscribe, which is not tracked) changes nothing.
  defp note_answer(%{"id" => id} = message, state) when is_integer(id) do
    case List.keytake(ack_requests(state), id, 0) do
      {{_id, timer}, rest} ->
        Process.cancel_timer(timer)
        {symbols, streams} = Map.pop(ack_streams(state), id, [])

        state
        |> put_ack_requests(rest)
        |> Map.merge(%{ack_streams: streams, answered_symbols: symbols})
        |> resync_subscribe_answered(id, message["status"])

      nil ->
        state |> Map.put(:answered_symbols, []) |> resync_unsubscribe_answered(id)
    end
  end

  defp note_answer(%{"id" => _not_an_integer}, state), do: Map.put(state, :answered_symbols, [])
  defp note_answer(_message, state), do: state

  # The answer to a resync's own unsubscribe: the old subscription is over, so exactly the key
  # that sent THAT id moves on to its subscribe. Any status counts; a refused unsubscribe of a
  # stream that is gone changes nothing the resync needs.
  defp resync_unsubscribe_answered(state, id) do
    waiting = for {key, {:unsubscribing, ref, ^id}} <- depth_resync(state), do: {key, ref}

    case waiting do
      [] ->
        state

      [{key, ref} | _none_other] ->
        send(self(), {:resubscribe_depth, key, ref})

        state
        |> cancel_depth_timer(:timeout, key)
        |> put_resync(Map.put(depth_resync(state), key, {:subscribing, ref}))
    end
  end

  # The venue has answered the subscribe a resync sent. Accepted, there is nothing to do: the
  # key stays `:awaiting` until the first frame, which `take_snapshot/2` takes. REFUSED, the
  # symbol has no depth subscription at all, so it is taken out of `depth_streams` rather than
  # left listed while unsubscribed, announced as not delivering, and retried after a backoff.
  defp resync_subscribe_answered(state, deadline, status) do
    awaiting = for {key, {:awaiting, ref, ^deadline}} <- depth_resync(state), do: {key, ref}

    if status == 200 or awaiting == [] do
      state
    else
      Enum.reduce(awaiting, state, fn {key, _ref}, acc -> refused_resync(acc, key, status) end)
    end
  end

  defp refused_resync(state, key, status) do
    failures = Map.get(Map.get(state, :depth_resync_failures, %{}), key, 0) + 1

    state =
      Map.update(state, :depth_resync_failures, %{key => failures}, &Map.put(&1, key, failures))

    retry_ref = make_ref()
    delay = resync_delay(state, key)

    state
    |> cancel_depth_timers([key])
    |> arm_depth_timer(:retry, key, retry_ref, {:retry_depth, key, retry_ref}, delay)
    |> put_resync(Map.delete(depth_resync(state), key))
    |> Map.put(:depth_streams, MapSet.delete(depth_streams(state), key))
    |> Map.update(:depth_retry, %{key => retry_ref}, &Map.put(&1, key, retry_ref))
    |> notify_not_delivering(key, :resubscribe_refused, %{status: status})
  end

  @impl true
  def handle_pong(_frame, state), do: {:ok, %{state | last_heard_at: now_ms()}}

  # Returns the timer, which the state keeps so a dropped connection cancels it.
  defp schedule_liveness(liveness),
    do: Process.send_after(self(), {:liveness, liveness}, @ping_every_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # WebSockex reconnects inside this process, and a reconnected socket carries no
  # subscriptions. `Feed` resubscribes on a 60s timer regardless, but that left up to a
  # minute of silence after every ordinary reconnect. This tells `Feed` at once, so it can
  # resubscribe now. The timer stays as the net for anything this misses.
  #
  # A private message rather than a `Core.Notice`: it carries this socket's pid, which a
  # consumer has no use for. The FIRST connect is not reported. `Feed` subscribes on that
  # one itself once `start_link/1` returns, and a report would only send the same
  # subscription twice. Lossy by contract, like `notify/2`.
  #
  # Sent to whatever `notify/2` sends to. It used to be guarded `is_pid/1` with a silent
  # `:ok` for anything else, which no caller reached (`Feed` passes `self()`, and
  # `handle_connect/2` has already sent `:link_up` to the same subscriber before this runs);
  # the guard only meant a registered-name subscriber would hear `:link_up` and never this.
  defp report_reconnected(%{subscriber: subscriber}) do
    send(subscriber, {:dp_exchange, :gemini, :reconnected, self()})
    :ok
  end

  # The FIRST connect, reported only by a socket that dialled asynchronously (`start_link/1`'s
  # `:async`): its starter was not waiting on `start_link/1`, so this is how it learns the
  # connect is done and a subscribe frame can go out. A synchronously-dialled socket's starter
  # already knows, and a report would only be a message nobody reads. `Map.get/3`: a bare
  # test-built state has no such key.
  defp report_connected(state) do
    if Map.get(state, :report_connect?, false),
      do: send(state.subscriber, {:dp_exchange, :gemini, :connected, self()})

    :ok
  end

  @impl true
  def handle_disconnect(%{reason: reason} = status, state) do
    state = report_link_down(state, reason)

    # `attempt_number` comes from `websockex` itself. It is a documented key of the
    # `connection_status_map` this function already pattern-matches on
    # (`WebSockex.connection_status_map/0`), and `on_disconnect/5` increments it for each
    # CONSECUTIVE failed reconnect, starting fresh at 1 each time a live session drops.
    #
    # This module used to state that it "keeps no attempt counter", and declined to emit
    # `link_reconnect_attempt` rather than invent one. Refusing to invent was right; the
    # premise was wrong — the real counter was in the argument all along. Both the backoff
    # below and the event now run on the venue's own number rather than a local guess.
    #
    # `Map.get/3` rather than a pattern, so the unit tests that call this callback directly
    # with a bare `%{reason: ...}` keep describing what they mean: one healthy session
    # dropping, which still reconnects at once.
    #
    # **A session that dies straight after connecting counts too.** `attempt_number` starts
    # again at 1 after every successful connect, so a venue that completes the upgrade and
    # closes at once got an unthrottled connect, close, connect loop at 0 ms. Consecutive
    # short sessions are counted here and fed into the same backoff.
    {short_sessions, state} = count_short_session(state)
    attempt = max(Map.get(status, :attempt_number, 1), short_sessions + 1)
    # Jittered per socket — see `jittered_delay_ms/1`. The telemetry event below reports the
    # delay actually waited, not the ladder's rung.
    delay = attempt |> reconnect_delay_ms() |> jittered_delay_ms()

    Telemetry.link_reconnect_attempt(:gemini, attempt, delay)

    # Blocks THIS socket process only, and only while it has no connection to serve anyway —
    # the same trade `dp_exchange_schwab.Socket` already makes. See `wait_to_reconnect/2`: it
    # is a wait, not a bare sleep, so `Feed` stopping this socket still ends it.
    wait_to_reconnect(state, delay)

    {:reconnect, state}
  end

  # **One `link_down` closes one `link_up` (family rule, tick AI).** `websockex` calls
  # `handle_disconnect/2` again for every FAILED reconnect (`on_disconnect/5` calls itself with
  # `attempt + 1`), and this reported the loss each time: a venue refusing connections for ten
  # minutes sent a `:link_down` notice and a `[:dp_exchange, :link, :down]` event per attempt,
  # with no `link_up` between them, so a metrics consumer's link gauge counted a link that had
  # been down once as down thirty times. The loss is reported when the connection that was up
  # goes down, and not again until a `handle_connect/2` has opened another. A state that has
  # never seen a connect (one a test built by hand) still reports, as it always did.
  # The reconnect attempts themselves stay visible: `Telemetry.link_reconnect_attempt/3` below
  # fires for each one.
  defp report_link_down(state, reason) do
    if Map.get(state, :link_open?, true) do
      # Bounded: a refused upgrade carries the venue's response inside the reason, and it went
      # whole into every notice subscriber and every telemetry handler.
      reason_text = inspect(reason, limit: 50, printable_limit: 1_024)

      notify(
        state,
        Notice.new(:link_down, :gemini, details: %{reason: :disconnected, message: reason_text})
      )

      Telemetry.link_down(:gemini, reason_text)
    end

    Map.put(state, :link_open?, false)
  end

  # The backoff wait, which still hears its parent stop it.
  #
  # `WebSockex` traps exits and learns that its parent has gone (or that `Feed` stopped it)
  # from an `{:EXIT, parent, reason}` message that only its own receive loops read. This wait
  # used to be a bare `Process.sleep/1` of up to `@max_reconnect_delay_ms`, during which that
  # message sat unread: a socket told to stop, or orphaned by a `Feed` restart, slept out the
  # whole delay and then dialled the venue once more before it noticed. That is a stray
  # connection from a socket nobody owns.
  #
  # Exiting with the parent's own reason is what `WebSockex` does when it reads the message
  # itself (`terminate/4`). A state with no `:parent` (one a test built by hand) matches no
  # exit and waits the full delay, exactly as the sleep did.
  defp wait_to_reconnect(_state, 0), do: :ok

  defp wait_to_reconnect(state, delay) do
    parent = Map.get(state, :parent)

    receive do
      {:EXIT, ^parent, reason} when is_pid(parent) -> exit(reason)
    after
      delay -> :ok
    end
  end

  # Consecutive sessions that ended within `@short_session_ms` of connecting. Read once per
  # session, so a run of failed reconnects (no connect between them) is not recounted; those
  # are `attempt_number`'s to count. A session that lasted resets it.
  defp count_short_session(state) do
    case Map.get(state, :connected_at) do
      nil ->
        {Map.get(state, :short_sessions, 0), state}

      at ->
        short =
          if now_ms() - at < @short_session_ms,
            do: Map.get(state, :short_sessions, 0) + 1,
            else: 0

        {short, Map.merge(state, %{short_sessions: short, connected_at: nil})}
    end
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    state = %{state | last_heard_at: now_ms()}
    # Emitted BEFORE the decode, and counted whether or not it parses — the question this
    # event answers is "is the venue sending", and a frame this package could not read is
    # still a frame the venue sent. Counting only what parsed would make a decoder bug here
    # look like a silent venue.
    Telemetry.link_event(:gemini, :frame, byte_size(raw))

    case decode_frame(raw) do
      {:ok, message} -> handle_message(message, note_answer(message, state))
      # Not JSON, or JSON that is not an object.
      :error -> {:ok, undecodable_frame(state, raw)}
    end
  end

  def handle_frame(_other, state), do: {:ok, state}

  # **A JSON number is read as a `Decimal`, never as a float.** `Jason.decode/1` turns `0.1` or
  # `65000.12345678901234567` into an Erlang float, which holds 17 significant digits at most, so
  # a price or size the venue sent as a number (REST sends several as numbers, and the AsyncAPI
  # types its prices as strings but a proxy or a venue change can differ) lost its low digits
  # before any decoder saw it. `floats: :decimals` keeps every digit, as `Rest.decoded_body/1`
  # already does for the same venue's REST bodies. A fractional number standing alone at the top
  # level is then a `%Decimal{}`, which is a map: it is not a frame object, and is refused here
  # rather than matched as one.
  defp decode_frame(raw) do
    case Jason.decode(raw, floats: :decimals) do
      {:ok, message} when is_map(message) and not is_struct(message) -> {:ok, message}
      _not_an_object -> :error
    end
  end

  # **A text frame that is not a JSON object is reported, not dropped.** Every frame the venue
  # documents is an object (websocket.yaml), so one that is not JSON, or is JSON of another
  # shape, is a frame this package cannot read: the same condition as the unreadable trade,
  # book and depth frames below, which each raise a `:data_quality` notice. It was discarded in
  # silence, so a venue that began sending something else (a proxy's error page, a framing
  # change) looked like a quiet market. The notice carries the size and none of the text: the
  # bytes are the venue's (or a proxy's) and could be anything. `Feed` throttles the notice per
  # `{kind, reason, symbol}`, so a stream of them is one notice per window.
  defp undecodable_frame(state, raw) do
    notify(
      state,
      Notice.new(:data_quality, :gemini,
        details: %{
          reason: :undecodable_frame,
          message: "undecodable frame",
          bytes: byte_size(raw)
        }
      )
    )

    state
  end

  # A `@trade` frame. **`m` is "whether the buyer is the maker", which is the opposite of
  # the taker's side** — and the opposite of what `/v1/trades` reports under `type`. The
  # inversion lives in `WsDecode.to_trade/2`; doing it here as well would undo it.
  defp handle_message(%{"e" => "trade"} = message, state), do: deliver_trade(message, state)

  defp handle_message(%{"t" => _tid, "p" => _p, "q" => _q} = message, state),
    do: deliver_trade(message, state)

  # A differential depth frame — or, on a connection that asked for the `snapshot`
  # connection parameter, the FIRST such frame per symbol since (re)subscribing, which
  # carries absolute levels instead of a diff. See the moduledoc's "A depth diff stream
  # needs its own anchor" and `WsDecode.to_order_book_from_depth_update/3`.
  #
  # **The ordinary case is not delivered as an OrderBook**: a diff is not a book, and
  # handing a subscriber the changed levels under a type that means "the whole book" is the
  # substitution this family refuses. Delivered as `Core.Types.OrderBookDelta` instead — the
  # contract's own shape for "changed levels, not accumulated" — via `WsDecode`'s decoder,
  # never as the raw frame. This used to send the undecoded JSON message straight through
  # under a bare `{:depth_update, message}` tuple, which is the exact defect this family's
  # "internal wiring" conformance check exists to catch: a decoder built, documented, and
  # never called, while its caller forwarded venue JSON directly instead.
  defp handle_message(%{"e" => "depthUpdate", "U" => _first} = message, state) do
    case symbol_of(message) do
      {:ok, symbol} ->
        deliver_depth_update(message, symbol, state)

      # A diff naming no symbol cannot be applied to any book, so nothing is sent. The
      # sequence bookkeeping this frame would have advanced is per-symbol now (see the
      # moduledoc's "handle_connect/2" reset comment) and there is no symbol to key it
      # under, so nothing there advances either — there is nothing left to make consistent
      # for a symbol this package was never told.
      :error ->
        notify_undecodable_depth(state, noticed(message["s"]))
        {:ok, state}
    end
  end

  # A `depthUpdate` with no `U`. Its sequence range cannot be checked, so it cannot be applied
  # safely, and it is not a bookTicker (the guard on that clause refuses list sides). It used
  # to fall to the catch-all and vanish: the book was then missing a diff with no notice, and
  # the next frame showed no gap against a sequence this frame never advanced. Same outcome as
  # a gap, same notice: discard and resubscribe.
  defp handle_message(%{"e" => "depthUpdate"} = message, state) do
    notify_undecodable_depth(state, noticed(message["s"]))
    {:ok, state}
  end

  # A partial-depth snapshot: absolute levels and a `lastUpdateId`, which is a book — but
  # `OrderBookSnapshot` (websocket.yaml:1217-1233) carries no `s`, so this frame cannot name
  # its own symbol. Attributed only from `partial_depth_claims`, which `subscribe/3` builds:
  # see the moduledoc's "A partial-depth snapshot cannot name its own symbol".
  defp handle_message(%{"lastUpdateId" => _id, "bids" => _b, "asks" => _a} = message, state) do
    case partial_depth_symbols(state) do
      [symbol] ->
        # A snapshot whose side is not a list is not delivered: a book in which nobody
        # bids, built from a side this package could not read, is the substitution
        # `to_order_book/3` now refuses. The next snapshot replaces it whole, so nothing is
        # left to repair.
        case WsDecode.to_order_book(message, symbol, DateTime.utc_now()) do
          {:ok, book} ->
            send(state.subscriber, {:dp_exchange, :gemini, book})

          {:error, _reason} ->
            notify(
              state,
              Notice.new(:data_quality, :gemini,
                details: %{
                  reason: :unreadable_partial_depth_snapshot,
                  message: "unreadable partial-depth snapshot",
                  symbol: symbol
                }
              )
            )
        end

      # Zero claims (nothing this package asked `subscribe/3` for), or more than one (should
      # not be reachable through `subscribe/3`'s own refusal, but is not assumed impossible
      # here) — either way there is no single symbol to attribute this frame to, and a
      # snapshot that cannot be attributed must raise a notice, not vanish silently.
      _zero_or_ambiguous ->
        notify(
          state,
          Notice.new(:data_quality, :gemini,
            details: %{
              reason: :unattributable_partial_depth_snapshot,
              message: "unattributable partial-depth snapshot"
            }
          )
        )
    end

    {:ok, state}
  end

  # A `bookTicker` frame is the top of the book: `s` the symbol, `b`/`a` the best bid and
  # ask, `c` the last trade price where one exists.
  #
  # This used to build a `Core.Types.Quote` with `price: message["c"] || bid` — falling back
  # to the **bid** when the book had not traded — and the comment beside it defended that as
  # better than inventing a value. It is not better; it is the same substitution wearing a
  # different word. A bid is a resting order. A price is an execution. Handing a subscriber
  # a bid in a field called `price` is handing it a plausible number with the wrong meaning,
  # which is the defect this family shipped once already on another venue.
  #
  # A bookTicker frame is top-of-book data, so it now delivers `Core.Types.TopOfBook`, which
  # has no `price` field to misuse. Where the frame also carries a last trade (`c`), that is
  # a separate fact and is delivered as its own `Quote`.
  #
  # The `TopOfBook` itself is built by `WsDecode.to_top_of_book/3` — this used to duplicate
  # that same construction inline, a second implementation of the same decode that could
  # drift from the one `WsChannelsTest` actually exercises directly. One decoder, called
  # once.
  # `b` and `a` are strings on a bookTicker and LISTS on a depth frame. A depthUpdate missing
  # its `U` fell through to here and was published as a book with `nil` sides.
  defp handle_message(%{"s" => native, "b" => bid, "a" => ask} = message, state)
       when is_binary(native) and native != "" and not is_list(bid) and not is_list(ask) do
    symbol = SymbolFormat.to_canonical_symbol(native)

    # No error branch, because there is no longer an error to branch on: a bookTicker frame
    # is a book whether or not the venue dated it — see `WsDecode.to_top_of_book/3`.
    #
    # The clause this replaces read "a quote whose freshness cannot be stated must not reach
    # a consumer ... silence beats stamping it with our own clock", which is true of
    # `venue_time` and was applied to the wrong thing. Nobody was stamping our clock into the
    # venue's field; `observed_at` is a different field that says what it is. What the clause
    # actually did was drop a real bid and ask, and — because `deliver_last_trade/4` sat
    # inside the success branch — the `c` last trade along with them.
    case WsDecode.to_top_of_book(message, symbol, DateTime.utc_now()) do
      {:ok, top} ->
        send(state.subscriber, {:dp_exchange, :gemini, top})

      # A level the venue stated and this package could not read. Not published as `nil`,
      # which would claim there is no resting order; the last trade is still its own fact.
      {:error, _unreadable} ->
        notify(
          state,
          Notice.new(:data_quality, :gemini,
            details: %{
              reason: :unreadable_book_ticker_level,
              message: "unreadable bookTicker level",
              symbol: symbol
            }
          )
        )
    end

    state = deliver_last_trade(message["c"], symbol, state)

    {:ok, state}
  end

  # The subscribe acknowledgement. A non-200 is the venue refusing a subscription, which
  # a consumer needs to hear about — silently continuing is how a feed reports healthy
  # while delivering nothing.
  #
  # `:refusal`, not `:coverage_change`: `Core.Notice`'s own moduledoc defines `:refusal`
  # as "a symbol the venue will not carry", which is exactly this — the venue's own word
  # about a subscription it received and declined, the same shape `dp_exchange_webull`'s
  # `Feed` already reports as `:refusal` for its `INVALID_SYMBOL` case.
  # `:coverage_change` is reserved for the generic, unexplained resubscribe-failure shape
  # this venue does not have. Found by a cross-package audit comparing notice usage
  # across all five venues for the identical condition.
  #
  # `details.symbols` is the symbols of the request this answers, as the caller named them
  # to `subscribe/3` (empty when the request is not one this socket tracked: a resync's own
  # subscribe, or an answer that matches nothing outstanding). `details.reason` is an atom;
  # the venue's text, where there is any, belongs in `details.message`.
  defp handle_message(%{"id" => _id, "status" => status}, state) when status != 200 do
    {symbols, state} = Map.pop(state, :answered_symbols, [])

    # **`status` is whatever the venue sent.** It was interpolated and stored as it came, so a
    # frame carrying `"status": {}` (or any term without a `String.Chars` clause) raised
    # `Protocol.UndefinedError` in this process and took the connection, and `Feed`'s
    # subscription state with a restart, down. The documented status is an integer
    # (`ResponseBase`, websocket.yaml); anything else is shown bounded, as `noticed/1` shows
    # every other venue-supplied value.
    notify(
      state,
      Notice.new(:refusal, :gemini,
        message: "gemini refused a subscription: status #{noticed(status)}",
        details: %{
          reason: :subscribe_refused,
          subscribe_status: if(is_integer(status), do: status, else: noticed(status)),
          symbols: symbols
        }
      )
    )

    {:ok, state}
  end

  # A bookTicker-shaped frame (string `b` and `a`) whose `s` is absent, blank or not text names
  # no symbol to deliver for. Trades and depth frames with the same defect raise one notice;
  # this one was dropped in silence. The symbol is quoted bounded: it is whatever the venue
  # sent, and a map there must not reach `Notice.new/3` as structure.
  defp handle_message(%{"b" => bid, "a" => ask} = message, state)
       when not is_list(bid) and not is_list(ask) do
    notify(
      state,
      Notice.new(:data_quality, :gemini,
        details: %{
          reason: :undecodable_book_ticker,
          message: "undecodable book ticker",
          symbol: noticed(message["s"])
        }
      )
    )

    {:ok, state}
  end

  defp handle_message(_other, state), do: {:ok, state}

  # What the venue sent in `s`, quoted bounded for a notice. A frame names whatever it likes
  # there, and a map or a megabyte string put into `details` whole is delivered to every
  # subscriber and written to every log that prints the notice. Absent stays `nil`; text is cut
  # at 64 characters; anything else is shown as `inspect/2` shows it, bounded.
  defp noticed(nil), do: nil
  #
  # **Copied, not sliced.** `Jason.decode/1` hands back string values as sub-binaries of the
  # frame, and `String.slice/3` of one is another sub-binary of it, so a 64-byte symbol kept
  # the WHOLE frame alive (a depth diff runs to tens of KB, and a frame may reach the 16 MiB
  # cap) for as long as anything held the notice: this feed's `notice_seen` key, or a consumer
  # that keeps its recent notices. `:binary.copy/1` makes it stand alone.
  defp noticed(text) when is_binary(text), do: text |> String.slice(0, 64) |> :binary.copy()
  defp noticed(other), do: inspect(other, limit: 5, printable_limit: 64)

  # A frame ending at or before what was already applied is a replay, not news. Applied, it
  # re-applied old changes and set `last_depth_update` BACK, so the frame after it was
  # judged against the replay instead of the book.
  #
  # **A symbol being resynchronised drops every diff** (`depth_resync`, see the `handle_info`
  # comment on the four states): they continue a book that was already declared wrong, and a
  # second notice per frame would bury the first. The one exception is the first frame after
  # the resubscribe went out, which is the fresh snapshot (`take_snapshot/3`).
  #
  # **A sequence that goes BACKWARDS by more than one frame's span is a restart, not a
  # replay** (`WsDecode.depth_restart?/2`): the venue reset the book's counter, and dropping
  # every frame as stale until it climbed past the old value would be silence for as long as
  # that takes. It is announced and resynchronised like a gap. A replay or a frame only just
  # behind (`u` at or before what was applied, within a span) is still dropped.
  defp deliver_depth_update(message, symbol, state) do
    last_by_symbol = Map.get(state, :last_depth_update, %{})
    applied = Map.get(last_by_symbol, symbol)

    cond do
      MapSet.member?(Map.get(state, :depth_stopped, MapSet.new()), symbol) ->
        {:ok, state}

      unsubscribed_depth?(state, symbol) ->
        {:ok, state}

      symbol_resync(state, symbol) != [] ->
        resyncing_frame(message, symbol, state)

      WsDecode.depth_restart?(message, applied) ->
        declare_gap(message, symbol, state, last_by_symbol, :sequence_restart)

      WsDecode.stale_depth?(message["u"], applied) ->
        {:ok, state}

      is_integer(message["u"]) ->
        apply_depth_update(message, symbol, state, last_by_symbol, applied)

      true ->
        refuse_unsequenced_depth_update(message, symbol, state)
    end
  end

  # **A frame that was in flight when its symbol was unsubscribed is dropped, not taken as the
  # anchor.** `unsubscribe/3` forgets the symbol's anchor flag (so a later resubscribe's
  # snapshot is read as one), and on a `snapshot` connection the first frame after that is
  # decoded as an ABSOLUTE book. The venue keeps writing for a moment after an unsubscribe, so
  # the next in-flight diff was delivered to the consumer as a whole `OrderBook` holding only
  # the levels that diff changed, every price real and the book wrong. A frame for a symbol
  # with no depth subscription is dropped quietly: it is the race, not bad data.
  #
  # Decided from `depth_streams`, which `subscribe/3` records and every connect resets, so it
  # applies only to a state that has one; a state fed a frame without ever recording a
  # subscription (a bare one a test built) is delivered, as before.
  #
  # **Two membership tests, not a scan.** This ran on every depth frame and walked every
  # `{symbol, channel}` in `depth_streams` looking for the symbol, so a connection carrying
  # N symbols paid O(N) per frame (with 346 symbols on both diff channels, about 700 tuple
  # comparisons per frame, at the rate of the busiest stream). `subscribe/3` records only
  # `:depth` and `:depth_fast` keys (`claim_depth_channel/3`), so those are the two keys
  # a streamed symbol can have.
  defp unsubscribed_depth?(%{depth_snapshot?: true, depth_streams: streams}, symbol) do
    on_depth = MapSet.member?(streams, {symbol, :depth})
    on_depth_fast = MapSet.member?(streams, {symbol, :depth_fast})

    not (on_depth or on_depth_fast)
  end

  defp unsubscribed_depth?(_state, _symbol), do: false

  # **A diff whose `u` cannot be read does not advance the sequence, and is not delivered.**
  # `u` was stored as it came, so a frame with no `u` (or a non-integer one) overwrote the
  # symbol's last-applied id with `nil`, and `WsDecode.depth_gap?/2` reads `nil` as "nothing
  # applied yet, never a gap". The frame after it was then judged against nothing, so a real
  # gap behind the unreadable frame was never announced, and a string `u` made the check
  # that followed raise `ArithmeticError` in this process. Found 2026-10-11 reading the
  # sequence bookkeeping. The last good `u` is kept, so the next frame is judged against it
  # and the missing changes surface as the gap they are. The anchor flag still advances
  # (`decode_depth_frame/3`): if this was the anchor, the next frame is a diff, and reading
  # that as the whole book would be worse than the loss.
  defp refuse_unsequenced_depth_update(message, symbol, state) do
    {_discarded, state} = decode_depth_frame(message, symbol, state)
    notify_undecodable_depth(state, symbol)
    {:ok, state}
  end

  # A depth update the book cannot apply is bad data, not a slower path: `:data_quality`,
  # with an atom `reason` and the text in `message` (family decision D4).
  defp notify_undecodable_depth(state, symbol) do
    notify(
      state,
      Notice.new(:data_quality, :gemini,
        details: %{
          reason: :undecodable_depth_update,
          message: "undecodable depth update",
          symbol: symbol
        }
      )
    )
  end

  defp apply_depth_update(message, symbol, state, last_by_symbol, last_applied) do
    if WsDecode.depth_gap?(message, last_applied) do
      # The vendor's rule: discard the book and resubscribe. A consumer that keeps applying
      # after a gap holds a book that is silently wrong from here on, with every price real.
      # Per symbol — websocket.yaml:1269-1270 states the rule per book, and a single
      # node-wide counter (this package's own defect until now) could mask a real gap on
      # one symbol behind unrelated traffic on another, or flag one that never happened.
      declare_gap(message, symbol, state, last_by_symbol, :sequence_gap)
    else
      deliver_depth_frame(message, symbol, state, last_by_symbol)
    end
  end

  # Family rule MD9: on a gap the symbol is resubscribed, on every depth channel it is
  # subscribed on (`depth_streams`, recorded by `subscribe/3`), for a fresh snapshot, and the
  # gapped frame is NOT delivered (it continues a book already declared wrong). The resync
  # itself is `schedule_resync/2`: throttled to one per `{symbol, channel}` per 5s, so a book
  # that keeps gapping is not unsubscribed and resubscribed in a loop. With no channel known
  # (a frame fed to a bare socket state) no resubscribe is possible and the frame is
  # delivered as before, after the notice.
  defp gap_text(:sequence_gap), do: "depth sequence gap"
  defp gap_text(:sequence_restart), do: "depth sequence restart"

  defp declare_gap(message, symbol, state, last_by_symbol, reason) do
    # A sequence gap is bad data, not a slower path: `:data_quality` (family decision D4).
    notify(
      state,
      Notice.new(:data_quality, :gemini,
        details: %{reason: reason, message: gap_text(reason), symbol: symbol}
      )
    )

    case for({^symbol, _channel} = key <- depth_streams(state), do: key) do
      [] ->
        deliver_depth_frame(message, symbol, state, last_by_symbol)

      keys ->
        if Map.get(state, :depth_snapshot?, false),
          do: {:ok, Enum.reduce(keys, state, &schedule_resync(&2, &1))},
          else: {:ok, stop_unrebuildable(state, symbol, keys)}
    end
  end

  # **A connection without the `snapshot` parameter cannot rebuild a book by resubscribing.**
  # The parameter is a CONNECTION parameter, set at the upgrade (websocket.yaml:1264, "With the
  # `snapshot` connection parameter set"); it cannot be asked for per subscribe. Without it a
  # resubscribe brings diffs only, no frame in the stream carries absolute levels, so a resync
  # would end with the symbol "delivering" diffs onto a book nobody holds. Fail closed
  # instead: the symbol is marked `depth_stopped`, announced as not delivering with the
  # reason, and every frame for it is dropped until the caller subscribes it again (which
  # lifts the mark, `claim_depth_channel/3`), when it must rebuild from `get_order_book/2` or
  # from a connection started with `:depth`/`:depth_fast` in `:channels`.
  defp stop_unrebuildable(state, symbol, keys) do
    stopped = Map.get(state, :depth_stopped, MapSet.new())

    keys
    |> Enum.reduce(state, fn key, acc ->
      notify_not_delivering(
        acc,
        key,
        :book_not_rebuildable,
        %{until: "until the caller subscribes it again and rebuilds the book"}
      )
    end)
    |> Map.put(:depth_stopped, MapSet.put(stopped, symbol))
  end

  defp symbol_resync(state, symbol),
    do: for({{^symbol, _channel}, entry} <- depth_resync(state), do: entry)

  # A frame for a symbol whose resync is not finished. Dropped, unless EVERY channel of the
  # symbol is `:awaiting` (its subscribe is out and the old subscription is over): then this
  # is the first frame of the new subscription, the vendor's snapshot, and it is taken. With
  # another channel of the symbol still unsubscribing the frame cannot be attributed, so it
  # is dropped.
  defp resyncing_frame(message, symbol, state) do
    entries = symbol_resync(state, symbol)

    if Enum.all?(entries, &match?({:awaiting, _ref, _deadline}, &1)),
      do: deliver_depth_update(message, symbol, take_snapshot(state, symbol)),
      else: {:ok, state}
  end

  # The resync is over: the sequence and the anchor are forgotten so this frame is judged
  # against nothing and, on a `snapshot` connection, decoded as the absolute book; the
  # failures that earned a backoff are forgiven.
  defp take_snapshot(state, symbol) do
    keys = for {{^symbol, _channel} = key, _entry} <- depth_resync(state), do: key

    state
    |> cancel_depth_timers(keys)
    |> put_resync(Map.drop(depth_resync(state), keys))
    |> Map.update(:depth_resync_failures, %{}, &Map.drop(&1, keys))
    |> Map.update(:last_depth_update, %{}, &Map.delete(&1, symbol))
    |> Map.update(:depth_anchored, MapSet.new(), &MapSet.delete(&1, symbol))
  end

  defp put_resync(state, resync), do: Map.put(state, :depth_resync, resync)

  defp rpc_frame(method, id, symbol, channel) do
    Jason.encode!(%{"method" => method, "params" => streams([symbol], channel), "id" => id})
  end

  defp deliver_depth_frame(message, symbol, state, last_by_symbol) do
    {decoded, state} = decode_depth_frame(message, symbol, state)

    case decoded do
      {:ok, payload} ->
        send(state.subscriber, {:dp_exchange, :gemini, payload})

      # **The book is now missing this frame's changes**, and `last_depth_update` advances
      # past it below, so the next frame shows no gap. It used to be dropped in silence,
      # leaving a subscriber applying later diffs to a book that is wrong from here on with
      # every price real. It is the same outcome as a sequence gap, and it gets the same
      # notice: discard and resubscribe.
      {:error, _reason} ->
        notify_undecodable_depth(state, symbol)
    end

    {:ok, Map.put(state, :last_depth_update, Map.put(last_by_symbol, symbol, message["u"]))}
  end

  # The anchor case: this symbol's snapshot parameter is in force and this is the first
  # frame seen for it since the last (re)subscribe/connect. Marked anchored regardless of
  # whether the decode below succeeds — the FIRST frame is defined by its position in the
  # stream, not by whether this package could read it; treating a later frame as the anchor
  # instead would read a genuine diff's changed levels as if they were the whole book.
  defp decode_depth_frame(message, symbol, %{depth_snapshot?: true} = state) do
    anchored = Map.get(state, :depth_anchored, MapSet.new())

    if MapSet.member?(anchored, symbol) do
      {WsDecode.to_order_book_delta(message, symbol), state}
    else
      state = Map.put(state, :depth_anchored, MapSet.put(anchored, symbol))
      {WsDecode.to_order_book_from_depth_update(message, symbol, DateTime.utc_now()), state}
    end
  end

  # No `snapshot` parameter in force on this connection: every depthUpdate is an ordinary
  # diff, exactly as this socket has always delivered them.
  defp decode_depth_frame(message, symbol, state),
    do: {WsDecode.to_order_book_delta(message, symbol), state}

  # Both undecodable-trade paths raise a `:data_quality` notice. Found 2026-10-10 by reading
  # the clauses: `{:error, _} -> :ok` and `:error -> {:ok, state}` dropped a trade with no
  # word, while depth and bookTicker frames in the same state raise one. A subscriber who
  # sees prints stop cannot tell "quiet market" from "frames this package cannot read". No
  # latch, matching bookTicker's own notice: one notice per unreadable frame.
  defp deliver_trade(message, state) do
    case symbol_of(message) do
      {:ok, symbol} ->
        deliver_trade(message, symbol, state)

      :error ->
        notify(
          state,
          Notice.new(:data_quality, :gemini,
            details: %{
              reason: :undecodable_trade,
              message: "undecodable trade",
              symbol: noticed(message["s"])
            }
          )
        )

        {:ok, state}
    end
  end

  defp deliver_trade(message, symbol, state) do
    case WsDecode.to_trade(message, symbol) do
      {:ok, trade} ->
        send(state.subscriber, {:dp_exchange, :gemini, trade})

      # An undated print cannot be placed on a tape, so it is not delivered; it is not
      # dropped in silence either.
      {:error, _reason} ->
        notify(
          state,
          Notice.new(:data_quality, :gemini,
            details: %{
              reason: :undecodable_trade,
              message: "undecodable trade",
              symbol: symbol
            }
          )
        )
    end

    {:ok, state}
  end

  # The frame's symbol, or `:error`. Three handlers read it as `message["s"] || ""`, which
  # delivered a trade, book or delta for the symbol `""` whenever the venue omitted it: a
  # value every `nil` check passes and that names nothing. And a non-string `s` made
  # `SymbolFormat` raise, taking the connection down. Both found by mutating real frames,
  # 2026-09-26.
  defp symbol_of(%{"s" => native}) when is_binary(native) and native != "",
    do: {:ok, SymbolFormat.to_canonical_symbol(native)}

  defp symbol_of(_message), do: :error

  # No trade price in the frame means the book has quotes and no execution to report. That
  # is a real state and it is silence here, not a `Quote` built from a bid.
  defp deliver_last_trade(nil, _symbol, state), do: state
  defp deliver_last_trade("", _symbol, state), do: state

  # `c` is "Last trade price, present once the book has traded" (websocket.yaml:1254-1256)
  # — the venue documents no trade TIME for it, only that the book has traded. This used to
  # stamp `venue_time` with the FRAME's own `E`, which is `bookTicker`'s own event time — the
  # book UPDATE, not the trade — so a real timestamp ended up attached to the wrong event: a
  # book can tick with no trade at all. `nil` is what the venue actually states about when
  # this traded: nothing. `Core.Types.Quote.venue_time` is explicitly nullable for exactly
  # this shape — "`nil` where the venue publishes none" — and a `nil` here says that, rather
  # than inventing a time this package was never given.
  #
  # And a `bookTicker` frame is not itself trade-triggered: the venue re-sends the SAME `c`
  # on every quote change until the NEXT trade. Delivering a `Quote` on every one of those
  # would report one real execution as a fresh trade each time the bid or ask merely moved —
  # the same "real value, wrong meaning" substitution this family refuses one level up, here
  # applied to time instead of price. So a `Quote` goes out only the first time this
  # connection sees this symbol's `c`, or when it changes — tracked per symbol in
  # `last_trade_price`, reset on connect for the same reason `last_depth_update` is: a
  # reconnected socket has forgotten what it last reported, so its first frame must report
  # again even if the venue's own `c` has not moved since the connection that dropped.
  defp deliver_last_trade(last, symbol, state) do
    # `Quote.price` is required and must be a real traded price — a `Quote` with `price:
    # nil` is the same substitution the family's own `Quote.price` typespec exists to
    # rule out. `"null"` (an unparsable last-trade string) is the same case as `""`
    # above: nothing traded, not a zero and not a missing-but-real price.
    # A last price of zero or less is not a price either (MD6): no `Quote`.
    case WsDecode.traded_price(last) do
      :error ->
        state

      {:ok, price} ->
        last_by_symbol = Map.get(state, :last_trade_price, %{})

        if unchanged_trade?(Map.get(last_by_symbol, symbol), price) do
          state
        else
          deliver(state, %Quote{
            symbol: symbol,
            price: price,
            volume: nil,
            venue_time: nil,
            observed_at: DateTime.utc_now(),
            provider: :gemini
          })

          Map.put(state, :last_trade_price, remember_last_trade(last_by_symbol, symbol, price))
        end
    end
  end

  # **The table of last-reported trade prices is bounded.** One entry per symbol this connection
  # has reported a `Quote` for. `forget_depth/3` drops a symbol's entry on unsubscribe, but a
  # `bookTicker` frame already in flight re-adds it afterwards, and a venue that names a symbol
  # nobody subscribed (or a hostile frame) adds one per frame. At `@max_last_trade_symbols`
  # distinct symbols the table starts again from the symbol in hand. What that costs is one
  # repeated `Quote` per symbol on its next frame, the same repeat a reconnect already causes,
  # and never a lost one: forgetting what was reported can only re-report it.
  @max_last_trade_symbols 4_096

  defp remember_last_trade(tracked, symbol, price) do
    if map_size(tracked) >= @max_last_trade_symbols and not Map.has_key?(tracked, symbol),
      do: %{symbol => price},
      else: Map.put(tracked, symbol, price)
  end

  defp unchanged_trade?(nil, _price), do: false
  defp unchanged_trade?(previous, price), do: Decimal.equal?(previous, price)

  defp deliver(state, payload), do: send(state.subscriber, {:dp_exchange, :gemini, payload})

  defp notify(state, notice), do: send(state.subscriber, {:dp_exchange, :gemini, notice})

  # The price decode (`WsDecode.traded_price/1`) carries the guards this module's own
  # `decimal/1` used to: the whole string must parse (`Decimal.new/1` raised on `""`,
  # reproduced live against `wss://ws.gemini.com` with a 347-symbol subscribe), and NaN,
  # Infinity and exponents that stall a comparison are refused.
end
