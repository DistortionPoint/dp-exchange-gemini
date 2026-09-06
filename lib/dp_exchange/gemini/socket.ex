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

  A caller wanting depth calls `get_order_book/2`, which is a REST snapshot with the
  venue's own per-level timestamps. Where a differential depth frame arrives instead — a
  future `@depth`/`@depthFast` subscription, not one this socket requests today — it is
  decoded into `Core.Types.OrderBookDelta` by `WsDecode.to_order_book_delta/2` and forwarded
  once, per frame. Never accumulated into a book here: see `OrderBookDelta`'s own moduledoc
  for why a distinct, non-snapshot-shaped type is what keeps that from happening by
  construction rather than by discipline.

  ## Event time is nanoseconds

  The `E` field is **nanoseconds** since the epoch, not milliseconds. The difference is a
  factor of a million: read as milliseconds, a 2026 timestamp lands in the year 58,000 and
  every staleness check passes forever. Converted once, in `WsDecode.nanosecond_time/1` —
  every frame handler here reaches that through one of `WsDecode`'s decoders rather than
  parsing `E` a second time.
  """

  use WebSockex

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Gemini.{Environment, SymbolFormat, WsChannels, WsDecode}

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

  @doc """
  The `websockex` connection opts `start_link/1` passes to `WebSockex.start_link/4` —
  `:socket_connect_timeout` and `:socket_recv_timeout`, defaulted to this module's own
  budget (see the moduledoc) and overridable by `opts`.

  Exposed as its own function, rather than inlined, so the budget the moduledoc claims can
  be pinned by a test without opening a real connection — `start_link/1` itself cannot be
  exercised against a fake transport, since `websockex` dials for real — and so a later
  refactor cannot silently drop either the explicit values or the override path back to
  `websockex`'s own accidental defaults.
  """
  @spec connect_opts(keyword()) :: keyword()
  def connect_opts(opts) do
    [
      socket_connect_timeout:
        Keyword.get(opts, :socket_connect_timeout, @socket_connect_timeout_ms),
      socket_recv_timeout: Keyword.get(opts, :socket_recv_timeout, @socket_recv_timeout_ms)
    ]
  end

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    url =
      Keyword.get_lazy(opts, :url, fn ->
        opts |> Environment.resolve() |> Environment.websocket_url()
      end)

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      request_id: 0
    }

    WebSockex.start_link(url, __MODULE__, state, connect_opts(opts))
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

  Returns `{:error, :send_timeout}` rather than exiting when the socket will not accept the
  frame — a caller can retry a batch, but it cannot recover from a linked exit it did not
  expect.
  """
  @spec subscribe(pid(), [String.t()], atom()) :: :ok | {:error, term()}
  def subscribe(socket, symbols, channel \\ :book_ticker) do
    with :ok <- validate_channel(symbols, channel) do
      send_rpc(socket, "subscribe", streams(symbols, channel))
    end
  end

  @doc """
  Unsubscribes the connection from `channel` for each symbol.

  Refuses the same two shapes `subscribe/3` does, for the same reasons — see its doc.
  """
  @spec unsubscribe(pid(), [String.t()], atom()) :: :ok | {:error, term()}
  def unsubscribe(socket, symbols, channel \\ :book_ticker) do
    with :ok <- validate_channel(symbols, channel) do
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
    WebSockex.send_frame(socket, {:text, frame})
  catch
    :exit, _reason -> {:error, :send_timeout}
  end

  # --- callbacks ----------------------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    notify(state, Notice.new(:link_up, :gemini))
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify(state, Notice.new(:link_down, :gemini, details: %{reason: inspect(reason)}))
    {:reconnect, state}
  end

  @impl true
  def handle_frame({:text, raw}, state) do
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

  # A differential depth frame. **Not delivered as an OrderBook**: a diff is not a book, and
  # handing a subscriber the changed levels under a type that means "the whole book" is the
  # substitution this family refuses. Delivered as `Core.Types.OrderBookDelta` instead — the
  # contract's own shape for "changed levels, not accumulated" — via `WsDecode`'s decoder,
  # never as the raw frame. This used to send the undecoded JSON message straight through
  # under a bare `{:depth_update, message}` tuple, which is the exact defect this family's
  # "internal wiring" conformance check exists to catch: a decoder built, documented, and
  # never called, while its caller forwarded venue JSON directly instead.
  defp handle_message(%{"e" => "depthUpdate", "U" => _first} = message, state) do
    if WsDecode.depth_gap?(message, state[:last_depth_update]) do
      # The vendor's rule: discard the book and resubscribe. A consumer that keeps applying
      # after a gap holds a book that is silently wrong from here on, with every price real.
      notify(
        state,
        Notice.new(:degraded, :gemini,
          details: %{reason: "depth sequence gap", symbol: message["s"]}
        )
      )
    end

    symbol = SymbolFormat.to_canonical_symbol(message["s"] || "")

    case WsDecode.to_order_book_delta(message, symbol) do
      {:ok, delta} -> send(state.subscriber, {:dp_exchange, :gemini, delta})
      # An undated diff cannot be ordered against anything. Silence beats a delta whose
      # place in the sequence cannot be stated.
      {:error, _reason} -> :ok
    end

    {:ok, Map.put(state, :last_depth_update, message["u"])}
  end

  # A partial-depth snapshot: absolute levels and a `lastUpdateId`, which is a book.
  defp handle_message(%{"lastUpdateId" => _id, "bids" => _b, "asks" => _a} = message, state) do
    symbol = SymbolFormat.to_canonical_symbol(message["s"] || "")

    {:ok, book} = WsDecode.to_order_book(message, symbol, DateTime.utc_now())
    send(state.subscriber, {:dp_exchange, :gemini, book})
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
  defp handle_message(%{"s" => native, "b" => _bid, "a" => _ask} = message, state) do
    symbol = SymbolFormat.to_canonical_symbol(native)

    case WsDecode.to_top_of_book(message, symbol, DateTime.utc_now()) do
      {:ok, top} ->
        send(state.subscriber, {:dp_exchange, :gemini, top})
        deliver_last_trade(message["c"], symbol, top.venue_time, state)

      # A quote whose freshness cannot be stated must not reach a consumer — see
      # `WsDecode.nanosecond_time/1`. Silence beats stamping it with our own clock.
      {:error, _reason} ->
        :ok
    end

    {:ok, state}
  end

  # The subscribe acknowledgement. A non-200 is the venue refusing a subscription, which
  # a consumer needs to hear about — silently continuing is how a feed reports healthy
  # while delivering nothing.
  defp handle_message(%{"id" => _id, "status" => status}, state) when status != 200 do
    notify(state, Notice.new(:coverage_change, :gemini, details: %{subscribe_status: status}))
    {:ok, state}
  end

  defp handle_message(_other, state), do: {:ok, state}

  defp deliver_trade(message, state) do
    symbol = SymbolFormat.to_canonical_symbol(message["s"] || "")

    case WsDecode.to_trade(message, symbol) do
      {:ok, trade} -> send(state.subscriber, {:dp_exchange, :gemini, trade})
      # An undated print cannot be placed on a tape. Silence beats a trade at the wrong
      # moment.
      {:error, _reason} -> :ok
    end

    {:ok, state}
  end

  # No trade price in the frame means the book has quotes and no execution to report. That
  # is a real state and it is silence here, not a `Quote` built from a bid.
  defp deliver_last_trade(nil, _symbol, _timestamp, _state), do: :ok
  defp deliver_last_trade("", _symbol, _timestamp, _state), do: :ok

  defp deliver_last_trade(last, symbol, timestamp, state) do
    # `Quote.price` is required and must be a real traded price — a `Quote` with `price:
    # nil` is the same substitution the family's own `Quote.price` typespec exists to
    # rule out. `"null"` (an unparsable last-trade string) is the same case as `""`
    # above: nothing traded, not a zero and not a missing-but-real price.
    case decimal(last) do
      nil ->
        :ok

      price ->
        deliver(state, %Quote{
          symbol: symbol,
          price: price,
          volume: nil,
          timestamp: timestamp,
          provider: :gemini
        })
    end
  end

  defp deliver(state, payload), do: send(state.subscriber, {:dp_exchange, :gemini, payload})

  defp notify(state, notice), do: send(state.subscriber, {:dp_exchange, :gemini, notice})

  defp decimal(nil), do: nil

  # `Decimal.new/1` raises on a string that is not a number. **Reproduced live**: a
  # 347-symbol subscribe against production `wss://ws.gemini.com` crashed this socket
  # within seconds on a `bookTicker` frame carrying `""` for a bid/ask field — a single
  # symbol's test, which is what shipped before, never sends enough traffic to hit it.
  # `Decimal.parse/1`, requiring the whole string be consumed, is what `ws_decode.ex`
  # already does for the same shape of field.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> parsed
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil
end
