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

  and the venue acknowledges with `{"id":1,"status":200}`.

  This package subscribes to **`@bookTicker`** and nothing else. That single stream carries
  best bid, best ask and — where the book has traded — the last trade price, in one message
  per change. It delivers `Core.Types.TopOfBook` on every frame that parses, and a separate
  `Core.Types.Quote` only on the frames that also carry that last trade: the two are
  independent facts and a bid is never dressed up as a price. See `handle_message/2` for
  the substitution that rule exists to stop.

  ### Which is why there is no order-book machinery here

  The host maintains a 182-line L2 book (`gemini/l2_book.ex`) whose entire purpose is to
  reconstruct a mid price from `l2_updates` deltas, because the endpoint it connects to
  offers no top-of-book message. This endpoint does. The book is not ported, and the
  moduledoc of the file that is not ported records why it existed — a mid computed from a
  single delta rather than the maintained book, which is the incident that created it.

  A caller wanting depth calls `get_order_book/2`, a REST snapshot that carries no venue time
  (its per-level `timestamp` is a documented dummy value, rest.yaml:8065) and no `u`, so it cannot anchor a
  `@depth`/`@depthFast` diff stream: the vendor's own sequence check (`WsDecode.depth_gap?/2`)
  compares one `u` against the next frame's `U`, and a REST call has neither.

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
  never told to anchor.

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
  impossible — is claimed raises a `:degraded` notice rather than vanishing.

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
  venue documents no heartbeat of its own.

  RFC 6455 gives one that needs no venue claim: an endpoint answers a ping with a pong.
  Each connection pings every `@ping_every_ms` (30s), and a frame or a pong counts as being
  heard from. After `@silence_ms` (90s, three pings) with nothing heard, it raises a
  `:degraded` notice (`details.reason: :silent_connection`) and closes. That takes the
  ordinary `handle_disconnect/2` path: `:link_down`, reconnect, `:reconnected`, resend. The
  check carries this connection's ref and a stale one is not re-armed, so reconnects
  cannot stack check chains.
  """

  alias DpExchange.Core.{Config, Notice, Telemetry}
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Gemini.{Environment, SymbolFormat, WsChannels, WsDecode}

  # `use`, `start_link/4` and `send_frame/2` go to this package's vendored fork, never the
  # real `WebSockex`, whose `open_loop/3` has no handshake deadline and whose
  # `websocket_loop/3` crashes on a malformed close frame. See
  # `DpExchange.Gemini.Vendor.WebSockex`. Aliased as `VendoredWebSockex`, never over
  # `WebSockex`, so `WebSockex.Conn` and the rest still name the real dependency's modules.
  alias DpExchange.Gemini.Vendor.WebSockex, as: VendoredWebSockex

  use VendoredWebSockex

  require Logger

  # Chosen against `Feed.@call_timeout` (15s), not inherited from `websockex`'s own
  # general-purpose defaults (6s connect + 5s recv — measured from
  # `deps/websockex/lib/websockex/conn.ex:10-11`, which `start_link/1` used to pass no
  # opts at all and so accepted by accident). `ensure_socket/1` connects synchronously
  # inside a `Feed`/`SandboxFeed` `handle_call`, and one `send_frame` for the subscribe
  # that follows (`@frame_window_ms`, 5s) rides the same call: 3s + 2s + 5s = 10s, leaving
  # 5s of `@call_timeout` for everything else in that call. See `Feed`'s moduledoc.
  @socket_connect_timeout_ms 3_000
  @socket_recv_timeout_ms 2_000

  # See the moduledoc's "A dead connection is found by pinging it".
  @ping_every_ms 30_000
  @silence_ms 90_000

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
    [
      socket_connect_timeout:
        Config.opt(opts, :socket_connect_timeout, @socket_connect_timeout_ms),
      socket_recv_timeout: Config.opt(opts, :socket_recv_timeout, @socket_recv_timeout_ms),
      ssl_options: Config.opt(opts, :ssl_options, nil) || verified_tls()
    ]
  end

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
  defp verified_tls do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @doc """
  `opts` also accepts `:channels` — the channels this connection is DECLARED to carry, used
  only to decide whether to request the venue's `snapshot` connection parameter (see the
  moduledoc's "A depth diff stream needs its own anchor"). It changes nothing about which
  channels can actually be subscribed later; `subscribe/3` still takes a `channel` argument
  of its own, and this is a one-time hint made before the socket ever connects, because the
  parameter cannot be added after the WebSocket upgrade. Omit it, or leave `:depth` and
  `:depth_fast` out of it, and this socket behaves exactly as it always has.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    url =
      Keyword.get_lazy(opts, :url, fn -> default_url(opts) end)

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
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

    VendoredWebSockex.start_link(url, __MODULE__, state, connect_opts(opts))
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

  Returns an error rather than exiting when the socket will not accept the frame — a caller
  can retry a batch, but it cannot recover from a linked exit it did not expect. **Which
  error says what to do about it**: `{:error, :send_timeout}` is a socket that did not
  acknowledge in time and is worth retrying, since the frame may well have landed and
  subscribes are idempotent here; `{:error, {:send_exit, reason}}` is a socket that is gone,
  which no number of retries reaches. See `send_rpc/3` for why flattening the two was wrong.
  """
  @spec subscribe(pid(), [String.t()], atom()) :: :ok | {:error, term()}
  def subscribe(socket, symbols, channel \\ :book_ticker) do
    with :ok <- validate_channel(symbols, channel),
         :ok <- claim_partial_depth(socket, symbols, channel) do
      send_rpc(socket, "subscribe", streams(symbols, channel))
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
    with :ok <- validate_channel(symbols, channel) do
      release_partial_depth(socket, symbols, channel)
      send_rpc(socket, "unsubscribe", streams(symbols, channel))
    end
  end

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
  defp claim_partial_depth(_socket, [], _channel), do: :ok

  defp claim_partial_depth(socket, symbols, channel) do
    if channel in WsChannels.partial_depth() do
      claim_partial_depth_symbol(socket, symbols, channel)
    else
      :ok
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
    claim = fn state ->
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

        if MapSet.member?(claims, {channel, symbol}),
          do: :ok,
          else: {:error, {:partial_depth_symbol_conflict, hd(partial_depth_symbols(state))}}

      # A socket this package cannot introspect — not a real process, or one that has
      # already exited. `send_rpc/3` still reports a dead socket on its own; this guard is a
      # best-effort refusal of an AMBIGUOUS frame later, not the boundary that decides
      # whether the frame goes out at all.
      :error ->
        :ok
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

  defp send_rpc(_socket, _method, []), do: :ok

  defp send_rpc(socket, method, params) do
    frame = Jason.encode!(%{"method" => method, "params" => params, "id" => 1})
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
    if state.connected_once?, do: report_reconnected(state)
    liveness = make_ref()
    schedule_liveness(liveness)

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
       partial_depth_claims: MapSet.new(),
       last_trade_price: %{}
     })}
  end

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

      {:close, %{state | liveness: nil}}
    else
      schedule_liveness(liveness)
      {:reply, :ping, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_pong(_frame, state), do: {:ok, %{state | last_heard_at: now_ms()}}

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
  defp report_reconnected(%{subscriber: subscriber}) when is_pid(subscriber) do
    send(subscriber, {:dp_exchange, :gemini, :reconnected, self()})
    :ok
  end

  defp report_reconnected(_state), do: :ok

  @impl true
  def handle_disconnect(%{reason: reason} = status, state) do
    notify(state, Notice.new(:link_down, :gemini, details: %{reason: inspect(reason)}))
    Telemetry.link_down(:gemini, inspect(reason))

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
    attempt = Map.get(status, :attempt_number, 1)
    delay = reconnect_delay_ms(attempt)

    Telemetry.link_reconnect_attempt(:gemini, attempt, delay)

    # Blocks THIS socket process only, and only while it has no connection to serve anyway —
    # the same trade `dp_exchange_schwab.Socket` already makes.
    if delay > 0, do: Process.sleep(delay)

    {:reconnect, state}
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    state = %{state | last_heard_at: now_ms()}
    # Emitted BEFORE the decode, and counted whether or not it parses — the question this
    # event answers is "is the venue sending", and a frame this package could not read is
    # still a frame the venue sent. Counting only what parsed would make a decoder bug here
    # look like a silent venue.
    Telemetry.link_event(:gemini, :frame, byte_size(raw))

    case Jason.decode(raw) do
      {:ok, message} -> handle_message(message, state)
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_frame(_other, state), do: {:ok, state}

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
        notify(
          state,
          Notice.new(:degraded, :gemini,
            details: %{reason: "undecodable depth update", symbol: message["s"]}
          )
        )

        {:ok, state}
    end
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
              Notice.new(:degraded, :gemini,
                details: %{reason: "unreadable partial-depth snapshot", symbol: symbol}
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
          Notice.new(:degraded, :gemini,
            details: %{reason: "unattributable partial-depth snapshot"}
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
  defp handle_message(%{"s" => native, "b" => _bid, "a" => _ask} = message, state)
       when is_binary(native) and native != "" do
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
    {:ok, top} = WsDecode.to_top_of_book(message, symbol, DateTime.utc_now())

    send(state.subscriber, {:dp_exchange, :gemini, top})
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
  defp handle_message(%{"id" => _id, "status" => status}, state) when status != 200 do
    notify(
      state,
      Notice.new(:refusal, :gemini,
        message: "gemini refused a subscription: status #{status}",
        details: %{subscribe_status: status}
      )
    )

    {:ok, state}
  end

  defp handle_message(_other, state), do: {:ok, state}

  defp deliver_depth_update(message, symbol, state) do
    last_by_symbol = Map.get(state, :last_depth_update, %{})
    last_applied = Map.get(last_by_symbol, symbol)

    if WsDecode.depth_gap?(message, last_applied) do
      # The vendor's rule: discard the book and resubscribe. A consumer that keeps applying
      # after a gap holds a book that is silently wrong from here on, with every price real.
      # Per symbol — websocket.yaml:1269-1270 states the rule per book, and a single
      # node-wide counter (this package's own defect until now) could mask a real gap on
      # one symbol behind unrelated traffic on another, or flag one that never happened.
      notify(
        state,
        Notice.new(:degraded, :gemini, details: %{reason: "depth sequence gap", symbol: symbol})
      )
    end

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
        notify(
          state,
          Notice.new(:degraded, :gemini,
            details: %{reason: "undecodable depth update", symbol: symbol}
          )
        )
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

  defp deliver_trade(message, state) do
    case symbol_of(message) do
      {:ok, symbol} -> deliver_trade(message, symbol, state)
      :error -> {:ok, state}
    end
  end

  defp deliver_trade(message, symbol, state) do
    case WsDecode.to_trade(message, symbol) do
      {:ok, trade} -> send(state.subscriber, {:dp_exchange, :gemini, trade})
      # An undated print cannot be placed on a tape. Silence beats a trade at the wrong
      # moment.
      {:error, _reason} -> :ok
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
    case decimal(last) do
      nil ->
        state

      price ->
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

          Map.put(state, :last_trade_price, Map.put(last_by_symbol, symbol, price))
        end
    end
  end

  defp unchanged_trade?(nil, _price), do: false
  defp unchanged_trade?(previous, price), do: Decimal.equal?(previous, price)

  defp deliver(state, payload), do: send(state.subscriber, {:dp_exchange, :gemini, payload})

  defp notify(state, notice), do: send(state.subscriber, {:dp_exchange, :gemini, notice})

  defp decimal(nil), do: nil

  # `Decimal.new/1` raises on a string that is not a number. **Reproduced live**: a
  # 347-symbol subscribe against production `wss://ws.gemini.com` crashed this socket
  # within seconds on a `bookTicker` frame carrying `""` for a bid/ask field — a single
  # symbol's test, which is what shipped before, never sends enough traffic to hit it.
  # `Decimal.parse/1`, requiring the whole string be consumed, is what `ws_decode.ex`
  # already does for the same shape of field.
  # `Decimal.parse/1` requiring the whole string be consumed is NOT a sufficient guard on
  # its own, which is the half this copy was missing. "NaN", "Inf" and "-Inf" all parse
  # fully and case-insensitively — `"-nan"` and `"inf"` too — so each arrived here as a
  # perfectly well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than the raise this parse replaced, and it fails a long way from the
  # cause. Measured: `Decimal.add(nan, 1)` is NaN, so it poisons a consumer's arithmetic
  # silently; `Decimal.compare(nan, _)` RAISES `invalid_operation: operation on NaN`, in
  # the consumer's own process, with a message naming Decimal rather than the venue that
  # sent it. An Infinity is quieter still — it compares greater than everything and never
  # raises at all.
  #
  # `dp_exchange_webull` found this and guarded both of its own copies; the other four
  # venues guarded none of their nine. Fixed where it was found, not where it applied —
  # which is why this comment is in each of them now rather than one of them.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil
end
