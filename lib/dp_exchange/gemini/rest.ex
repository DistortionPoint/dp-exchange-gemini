defmodule DpExchange.Gemini.Rest do
  @moduledoc """
  Gemini's REST surface — internal. The facade's market-data callbacks are served here.

  Every endpoint below was measured against the live venue on 2026-08-28. Where the
  measurement disagreed with Gemini's documentation, the measurement won and the
  divergence is recorded in `docs/reference/gemini/`.

  ## The candle window is fixed and every parameter is ignored

  `/v2/candles/{symbol}/{time_frame}` takes no bounds. `limit`, `start` and `end` are
  accepted and discarded — three requests differing only in those returned byte-identical
  responses. Each width serves a fixed window:

  | Width sent | Bars | ≈ span |
  |---|---|---|
  | `1m` | 1440 | 1 day |
  | `5m` | 2015 | 7 days |
  | `15m` | 1343 | 14 days |
  | `30m` | 1439 | 30 days |
  | `1hr` | 1463 | 61 days |
  | `6hr` | 367 | 92 days |
  | `1day` | 364 | 1 year |
  | `1w` | ~240 | ~4.6 years |
  | `1mo` | ~115 | ~9.6 years |

  So a range is honoured by **filtering here**, and a range the window cannot cover is an
  **error** rather than a short answer for the five widths above whose window this package
  can compute — see the next section for why `1w` and `1mo` are the two exceptions.
  Handing back 364 daily bars to a caller who asked for five years is the family's named
  failure mode in its quietest form: every value real, only the meaning wrong.

  ## `1w` and `1mo` — real widths the venue added, that this package cannot window-check

  **Found 2026-09-08, live.** The venue's own 400 body used to name seven accepted widths;
  it now names nine: `[1m, 5m, 15m, 30m, 1hr, 6hr, 1day, 1w, 1mo]`. `/v2/candles/BTCUSD/1w`
  and `/v2/candles/BTCUSD/1mo` both answer `200` with real bars — 240 weekly and 115 monthly,
  measured the same day — not the `400` a genuinely unserved width returns. This is the same
  failure mode `negative-claims.md` exists to catch, pointed at a positive claim this file
  made instead of a negative one: "the accepted set is `[…]`" was true on 2026-08-28 and
  stopped being true some time before 2026-09-08.

  Both widths are in `DpExchange.Core.Timeframe.nameable/0` (`1w`, and `1M` for calendar
  months) but neither is in `known/0` — `Timeframe.seconds/1` returns `:error` for both,
  deliberately: a week's boundary depends on which weekday a venue starts it, and a month is
  not a fixed number of seconds. `range_within_window/2` needs that width to compute how far
  back the fixed window reaches, so it cannot be computed for these two the way it is for the
  other seven. Rather than approximate a month as a fixed number of seconds — which is
  exactly the kind of guess this family refuses — `1w` and `1M` are simply not in
  `@window_bars`, and `range_within_window/2`'s existing fallback for an unmapped width
  applies: no pre-flight refusal, and the real rows returned are still filtered against
  `range` client-side by `within?/2` on their own real `opened_at`, same as every width. A
  `:start` older than the venue's actual window on one of these two returns an empty list
  rather than `{:error, {:range_unavailable, …}}` — a real gap from the other seven widths,
  disclosed here rather than hidden behind a fabricated window size.

  ## Neither ticker carries a quote time, so `:venue_time` comes from the `Date` header

  `/v1/pubticker` returns a `timestamp`, but it is **inside the `volume` object** — it
  stamps the 24-hour volume window, updates about once a minute, and is not when the bid
  and ask were true. `/v2/ticker` carries no timestamp at all. Using either as the quote
  time would be a substitution of exactly the kind this family exists to stop, and the
  host adapter does something worse: `parse_timestamp(nil)` returns `DateTime.utc_now()`,
  so a quote with no venue time gets the *client's* clock and looks perfectly fresh.

  This package uses the HTTP `Date` **response header** — the venue's own statement of
  when it served the answer, which bounds the quote's age and is not our clock. When that
  header is absent or unreadable, `venue_time` is `nil`: the traded price is still real, and
  `observed_at` states freshness. Nothing is ever substituted into `venue_time`.

  **`Quote.venue_time` can be `nil` here.** This moduledoc said "never `nil`" until it was
  checked against `header_time_or_nil/1` on 2026-10-10. That stopped being true in 0.2.30,
  when `get_price/2` stopped discarding a real traded price over a missing `Date` header. A
  consumer needs a `nil` branch for this venue's quotes.
  """

  alias DpExchange.Core.{Config, HttpClient, Timeframe}

  alias DpExchange.Core.Types.{
    Candle,
    ContractStats,
    Funding,
    OrderBook,
    Quote,
    StakingRate,
    TopOfBook,
    Trade
  }

  alias DpExchange.Gemini.{Environment, SymbolFormat}

  # The venue's refusal vocabulary, written down at compile time so that decoding one can
  # never mint an atom from venue-supplied text. See `refusal_reason/1` for why that
  # matters more than it looks.
  #
  # These are the reasons this package RECOGNISES, not the venue's complete list — Gemini
  # publishes more and adds to them without notice. That is exactly why an unrecognised
  # reason keeps its own string rather than being guessed at or collapsed: an incomplete
  # list must degrade legibly, not silently. Each key is the venue's own spelling; each
  # value is the atom this package's callers already match on, unchanged from when these
  # were built by `String.to_atom(Macro.underscore(reason))`.
  #
  # Every entry here is either in Gemini's own documented error-code table
  # (`docs/reference/gemini/rate-limits-and-auth.md` — the seven `Missing*`/`Invalid*`/
  # `AmbiguousAuthentication` codes) or measured live and recorded elsewhere in this
  # module's own docs (`MissingSecurityHeaders`, the documented divergence from
  # `MissingApikeyHeader`; `InvalidSymbol` and `InvalidParameterValue`, named in
  # `request_opts/1`'s comment and exercised by this module's own tests). Nothing is
  # guessed: an entry that is not backed by the vendor's table or a live measurement does
  # not belong here, because a wrong entry in this map is silently, permanently wrong for
  # whatever real reason happens to collide with it.
  @refusal_reasons %{
    "MissingApikeyHeader" => :missing_apikey_header,
    "MissingPayloadHeader" => :missing_payload_header,
    "MissingSignatureHeader" => :missing_signature_header,
    "InvalidNonce" => :invalid_nonce,
    "InvalidSignature" => :invalid_signature,
    "AmbiguousAuthentication" => :ambiguous_authentication,
    "InvalidApiKey" => :invalid_api_key,
    "MissingSecurityHeaders" => :missing_security_headers,
    "InvalidSymbol" => :invalid_symbol,
    "InvalidParameterValue" => :invalid_parameter_value
  }

  # Canonical width => the literal Gemini accepts. Measured 2026-08-28: the venue names
  # its own accepted set in the 400 body — `[1m, 5m, 15m, 30m, 1hr, 6hr, 1day]` — while
  # its documentation lists `1h`, `6h` and `1d`, none of which work. Three of the seven
  # documented values are rejected by the venue that documents them.
  #
  # Re-measured 2026-09-08: the venue's accepted set grew to nine — `1w` and `1mo` joined
  # without notice, both serving real bars, not a 400. See the moduledoc's "`1w` and `1mo`"
  # section for why `1mo` maps from Core's `1M` rather than `1mo` itself.
  @time_frames %{
    "1m" => "1m",
    "5m" => "5m",
    "15m" => "15m",
    "30m" => "30m",
    "1h" => "1hr",
    "6h" => "6hr",
    "1d" => "1day",
    "1w" => "1w",
    "1M" => "1mo"
  }

  # Bars served per width, measured 2026-08-28 and identical to the host's independent
  # 2026-08-06 measurement on all seven. Used to refuse a range the window cannot cover.
  #
  # Deliberately missing `1w` and `1M`, added to `@time_frames` 2026-09-08: `Timeframe.
  # seconds/1` returns `:error` for both (see `DpExchange.Core.Timeframe`'s moduledoc —
  # a week's start-of-week is venue-defined and a month is not a fixed second count), so
  # `range_within_window/2` cannot turn a bar count into an "earliest reachable" instant
  # for them the way it can for the other seven, and approximating one would substitute a
  # guess for the thing this map exists to avoid guessing about. See the moduledoc.
  @window_bars %{
    "1m" => 1_440,
    "5m" => 2_015,
    "15m" => 1_343,
    "30m" => 1_439,
    "1h" => 1_463,
    "6h" => 367,
    "1d" => 364
  }

  @doc "Canonical timeframes this venue serves, shortest first."
  @spec timeframes() :: [String.t()]
  def timeframes, do: @time_frames |> Map.keys() |> Enum.sort_by(&width!/1)

  @doc "Base URL, overridable per process for tests through `Core.Config`."
  @spec base_url(keyword()) :: String.t()
  def base_url(opts \\ []) do
    Keyword.get_lazy(opts, :base_url, fn ->
      opts |> Environment.resolve() |> Environment.rest_url()
    end)
  end

  # --- quotes -------------------------------------------------------------

  @doc """
  Best bid, best ask and last trade for one symbol.

  Timestamped from the venue's `Date` response header — see the module doc for why not
  from the payload.
  """
  @spec get_price(String.t(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, body, headers} <- get_with_headers("/v1/pubticker/#{segment(native)}", opts),
         {:ok, last} <- quoted_price(body),
         {:ok, price} <- required_decimal(last, :price) do
      # The ticker's `volume` is "the 24 hour volume on the exchange", measured up to its
      # own `timestamp` (`Ticker` in docs/reference/gemini/openapi/rest.yaml), so a rolling
      # 24-hour total. No interval's volume can be derived from it — dp-exchange-core issue
      # #42. Per-interval volume comes from the `:trades` stream.
      volume = base_volume(body, native)

      {:ok,
       %Quote{
         symbol: reported_symbol(symbol, native),
         price: price,
         volume: volume,
         volume_window: volume && :rolling_24h,
         # Read, not required, through the same `header_time_or_nil/1` that
         # `get_top_of_book/2` has always used on this identical payload.
         # `Core.Types.Quote` enforces `[:symbol, :price, :observed_at, :provider]`, so an
         # absent or unreadable `Date` header was discarding a real guarded traded price
         # over an optional field — and the two calls reading the SAME `/v1/pubticker`
         # response disagreed about whether it was usable.
         #
         # The thing that must not happen is unchanged: an unstated venue time is `nil`
         # here, never this package's clock, and `volume.timestamp` — which stamps the
         # 24-hour window, not the quote — is still never reached for.
         venue_time: header_time_or_nil(headers),
         observed_at: DateTime.utc_now(),
         provider: :gemini
       }}
    end
  end

  @doc """
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Same `/v1/pubticker/{symbol}` payload as `get_price/2`: the venue returns the last trade
  and the top of the book together, and this splits them into the two types that say which
  is which. `bid` and `ask` used to ride along on the `Quote`, which `Core.Types.Quote` no
  longer has fields for.

  The payload carries no sizes, so `bid_size` and `ask_size` stay `nil` — not published,
  and not zero. `venue_time` comes from the `Date` header for the same reason
  `get_price/2`'s timestamp does; `observed_at` is when this package read it.
  """
  @spec get_top_of_book(String.t(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, body, headers} <- get_with_headers("/v1/pubticker/#{segment(native)}", opts),
         {:ok, body} <- object(body),
         # A side the venue stated and this package cannot read is refused, not `nil`:
         # `TopOfBook` reads `nil` as "no resting order". An absent side stays `nil`.
         {:ok, bid} <- stated_price(body["bid"]),
         {:ok, ask} <- stated_price(body["ask"]) do
      {:ok,
       %TopOfBook{
         symbol: reported_symbol(symbol, native),
         bid: bid,
         ask: ask,
         bid_size: nil,
         ask_size: nil,
         venue_time: header_time_or_nil(headers),
         observed_at: DateTime.utc_now(),
         provider: :gemini
       }}
    end
  end

  defp stated_price(empty) when empty in [nil, ""], do: {:ok, nil}

  defp stated_price(value) do
    case decimal(value) do
      nil -> {:error, :unexpected_response_shape}
      price -> {:ok, price}
    end
  end

  defp header_time_or_nil(headers) do
    case venue_time(headers) do
      {:ok, timestamp} -> timestamp
      _no_usable_header -> nil
    end
  end

  # A 200 whose body is not a ticker is not a quote with missing fields — it is a
  # response nobody understood. Building a `Quote` with `nil` prices out of it would hand
  # a caller a struct that passes every type check and means nothing, which is the whole
  # family's failure mode arriving through the parser instead of the venue.
  defp quoted_price(%{"last" => nil}), do: {:error, :unexpected_response_shape}
  defp quoted_price(%{"last" => last}), do: {:ok, last}
  defp quoted_price(_body), do: {:error, :unexpected_response_shape}

  # --- candles ------------------------------------------------------------

  @doc """
  Candles for a symbol and canonical timeframe, filtered to `range`.

  `range` accepts `:start` and `:end` as `DateTime`s. Both are optional; with neither, the
  venue's whole fixed window is returned.

  Refuses rather than truncating:

    * an unknown width → `{:error, {:unsupported_timeframe, width}}`
    * a `:start` older than the window can reach → `{:error, {:range_unavailable, …}}`
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    # Found 2026-10-10 by reading the call sites: this echoed the caller's symbol string and
    # interpolated `native` raw, where `get_order_book/2` and `get_price/2` return the
    # canonical symbol and `segment/1` the path. Two spellings of one pair in one family.
    canonical = reported_symbol(symbol, native)

    with {:ok, path, time_frame} <- candles_path(native, timeframe),
         :ok <- range_within_window(timeframe, range),
         {:ok, body} <- get_body("#{path}/#{segment(native)}/#{time_frame}", opts),
         {:ok, rows} <- list(body) do
      with {:ok, candles} <- rows_to_candles(rows, canonical, timeframe) do
        {:ok,
         candles
         |> Enum.filter(&within?(&1, range))
         |> Enum.sort_by(& &1.opened_at, DateTime)}
      end
    end
  end

  # **Perpetuals have their own candles endpoint, and it serves 1m only.**
  #
  #     spot         /v2/candles/{symbol}/{width}              the full width vocabulary
  #     perpetual    /v2/derivatives/candles/{symbol}/1m       one width, and only one
  #
  # The vendor states both: the derivatives path is "available only for perpetual pairs" and
  # its `time_frame` enum contains `1m` and nothing else.
  #
  # **Sending a perpetual to the spot path is the failure worth preventing.** It does not
  # error — the symbol is well-formed and the endpoint answers — so a caller asking for
  # 5m bars on `BTCGUSDPERP` would get something back and have no way to tell it was not
  # the instrument it asked about. The routing is on `SymbolFormat.perpetual?/1`, which is
  # measured against the venue's own catalogue rather than guessed from the name.
  defp candles_path(native, timeframe) do
    if SymbolFormat.perpetual?(native) do
      perpetual_candles(timeframe)
    else
      with {:ok, time_frame} <- time_frame(timeframe), do: {:ok, "/v2/candles", time_frame}
    end
  end

  defp perpetual_candles("1m"), do: {:ok, "/v2/derivatives/candles", "1m"}

  # A width the derivatives endpoint does not serve. Falling back to the spot path would
  # answer a question about a different instrument; falling back to 1m would relabel
  # someone else's bars.
  defp perpetual_candles(timeframe), do: {:error, {:unsupported_timeframe, timeframe}}

  # --- catalogue ----------------------------------------------------------

  @doc """
  Every spot symbol the venue lists, canonical.

  Perpetuals are excluded. They are real instruments and the venue lists them alongside
  spot pairs, but this package declares `supported_instrument_types: [:spot]`, and a
  perpetual has no canonical `BASE-QUOTE` form — emitting one would invent a spot pair
  that does not exist.

  **Closed symbols are included**: `/v1/symbols` keeps them, and nothing here says which
  pairs trade (issue #4). For status, use `list_instruments/1`.
  """
  @spec get_symbols(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_symbols(opts) do
    with {:ok, body} <- get_body("/v1/symbols", opts),
         {:ok, symbols} <- list(body) do
      {:ok,
       symbols
       |> Enum.filter(&is_binary/1)
       |> Enum.reject(&SymbolFormat.perpetual?/1)
       |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
       |> Enum.sort()}
    end
  end

  @doc """
  Every pair with its last price and 24-hour change, in one call.

  `/v1/pricefeed` is the only endpoint here that describes the whole catalogue at once,
  which is what makes an overview affordable — the alternative is one request per symbol
  across 346 symbols, which is not an overview, it is a rate-limit incident.
  """
  @spec get_market_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def get_market_overview(opts) do
    with {:ok, body} <- get_body("/v1/pricefeed", opts),
         {:ok, rows} <- list(body) do
      {:ok,
       rows
       |> Enum.filter(&priced_pair?/1)
       |> Map.new(fn row ->
         {SymbolFormat.to_canonical_symbol(row["pair"]),
          %{price: decimal(row["price"]), change_24h: decimal(row["percentChange24h"])}}
       end)}
    end
  end

  # A row that names no pair is skipped. `is_map/1` used to be the whole filter, so a row
  # with no string `pair` reached `SymbolFormat.to_canonical_symbol/1` and raised, taking
  # the whole overview with it (REST fuzz, 2026-09-27). A price for no named pair belongs
  # to nothing a caller can ask about.
  defp priced_pair?(%{"pair" => pair}) when is_binary(pair), do: true
  defp priced_pair?(_unnamed), do: false

  @doc """
  The increments and minimum the venue will actually accept for a symbol.

  From `/v1/symbols/details/{symbol}`, which is also the source behind the venue's own
  published minimums table — that page states it fetches this endpoint live.

  `tick_size` is the **base-asset** increment and `quote_increment` the **price**
  increment. They are not interchangeable and the names do not say so: for `btcusd`,
  `tick_size` is `1.0e-8` BTC while `quote_increment` is `0.01` USD.
  """
  @spec quantization(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def quantization(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, raw} <- get_body("/v1/symbols/details/#{segment(native)}", opts),
         {:ok, body} <- object(raw) do
      {:ok,
       %{
         price_increment: decimal(body["quote_increment"]),
         quantity_increment: decimal(body["tick_size"]),
         min_quantity: decimal(body["min_order_size"]),
         status: body["status"]
       }}
    end
  end

  @doc """
  Each symbol's base, quote, instrument type and **trading status**, from
  `/v1/symbols/details/{symbol}`.

  `get_symbols/1` reads `/v1/symbols`, which keeps **closed** symbols (issue #4). Measured
  2026-10-07/08: `efilfil` is in `/v1/symbols` and in `/v1/pricefeed` (all 347 symbols are),
  and only its details say `"status":"closed"`. A consumer building a catalogue from
  `get_symbols/1` carried EFIL-FIL as a live pair for two months.

  **One request per symbol: the venue has no bulk details endpoint.** Pass `symbols:` to
  detail only the pairs you are deciding about. That is the cheap call, and the right one for
  a review queue. Without it this details every non-perpetual symbol `/v1/symbols` lists,
  about 347 requests. Each waits for its slot in the rate limiter
  (`rate_limit_blocking: true` unless you say otherwise), so the venue's ceiling is never
  exceeded, but the full listing spends minutes of the public budget. Call it rarely: the
  catalogue changes slowly.

  Status: `open` → `:tradable`; `closed` → `:delisted`; `post_only`/`limit_only` →
  `:tradable` (it trades, with restrictions); `cancel_only` and anything unrecognised →
  `:unknown`. A symbol whose details cannot be read fails the whole call. A catalogue with a
  silent hole in it is the outcome this family refuses.
  """
  @spec list_instruments(keyword()) ::
          {:ok, [DpExchange.Core.Instrument.t()]} | {:error, term()} | {:refused, term()}
  def list_instruments(opts) do
    opts = Keyword.put_new(opts, :rate_limit_blocking, true)

    with {:ok, symbols} <- instrument_symbols(opts) do
      Enum.reduce_while(symbols, {:ok, []}, fn symbol, {:ok, acc} ->
        case instrument(symbol, opts) do
          {:ok, instrument} -> {:cont, {:ok, [instrument | acc]}}
          failure -> {:halt, {:error, {:instrument_detail_failed, symbol, failure}}}
        end
      end)
      |> case do
        {:ok, instruments} -> {:ok, Enum.reverse(instruments)}
        error -> error
      end
    end
  end

  defp instrument_symbols(opts) do
    # Anything else was a `CaseClauseError` in the caller: `symbols: "BTC-USD"` reads as one
    # symbol to a person and is neither a list nor absent here.
    case Keyword.get(opts, :symbols) do
      nil -> get_symbols(opts)
      symbols when is_list(symbols) -> {:ok, Enum.uniq(symbols)}
      other -> {:error, {:invalid_option, :symbols, other}}
    end
  end

  defp instrument(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, raw} <- get_body("/v1/symbols/details/#{segment(native)}", opts),
         {:ok, body} <- object(raw) do
      {:ok,
       DpExchange.Core.Instrument.new(
         symbol: SymbolFormat.to_canonical_symbol(native),
         base: body["base_currency"],
         quote: body["quote_currency"],
         instrument: DpExchange.Core.Instrument.instrument_from(body["product_type"]),
         status: book_status(body["status"])
       )}
    end
  end

  # The venue's book statuses (`rest.yaml`: "`open`, `closed`, `cancel_only`, `post_only`,
  # `limit_only`").
  defp book_status("open"), do: :tradable
  defp book_status("post_only"), do: :tradable
  defp book_status("limit_only"), do: :tradable
  defp book_status("closed"), do: :delisted
  defp book_status(_cancel_only_or_unrecognised), do: :unknown

  # --- order book ---------------------------------------------------------

  @doc """
  A price-level snapshot for one symbol.

  **`venue_time` is always `nil`.** Each level carries a `timestamp` field, and this used
  to read the newest one as the book's own time — but `OrderBookEntry.timestamp`'s own
  schema (`rest.yaml:8065`) says **"DO NOT USE — this field is included for compatibility
  reasons only and is just populated with a dummy value."** There is no real time in it to
  derive, readable or not, and `/v1/book` publishes no time of its own elsewhere in the
  response. A body whose levels carry no readable timestamp used to refuse the whole book
  for that reason (`:missing_venue_timestamp`) — refusing a real book over a field the
  vendor states is meaningless was itself the bug; `venue_time: nil` is the honest answer
  regardless of what the field holds.

  `opts[:depth]` defaults to the venue's own documented default — see
  `docs/reference/gemini/order-book.md`, which quotes `limit_bids`/`limit_asks`'s "Default
  is 50" verbatim — rather than to a plausible-looking guess.
  """
  @spec get_order_book(String.t(), keyword()) ::
          {:ok, OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    # 50 is the venue's own documented default for both limit_bids and limit_asks — see
    # this function's own @doc and docs/reference/gemini/order-book.md.
    depth = Config.opt(opts, :depth, 50)
    params = [limit_bids: depth, limit_asks: depth]

    with {:ok, body} <-
           get_body("/v1/book/#{segment(native)}", Keyword.put(opts, :params, params)),
         :ok <- book_shape(body),
         :ok <- readable_book_side(body["bids"]),
         :ok <- readable_book_side(body["asks"]) do
      {:ok,
       %OrderBook{
         symbol: reported_symbol(symbol, native),
         bids: levels(body["bids"], :desc),
         asks: levels(body["asks"], :asc),
         venue_time: nil,
         observed_at: DateTime.utc_now(),
         provider: :gemini
       }}
    end
  end

  @doc """
  Recent public trades for `symbol` — `/v1/trades/{symbol}`.

  **This is the tape, not `get_trade_history/2`.** That returns the credential's own fills;
  this returns everyone's executions.

  ## `type` is the taker's side, and it is the opposite of the resting order's

  The venue is explicit: *"`buy` means that an ask was removed from the book by an incoming
  buy order"*. So `:buy` here says a buyer lifted the offer. A package that read it as the
  maker's side would invert every entry on the tape while every number stayed real.

  ## Broken trades are excluded unless asked for

  The venue publishes `broken` on each print and hides them by default itself. This does
  the same and `opts[:include_broken]` opts in: **a busted trade did not stand**, and its
  price in a series becomes a phantom high or low in every range and volatility figure
  built on it.

  `opts[:since]` narrows the window — the venue takes it as `timestamp`, with `since_tid`
  as the alternative and **`since_tid` wins where both are given**, which is the venue's own
  precedence rather than one chosen here. `opts[:limit]` is the venue's `limit_trades`.

  **This endpoint reaches seven calendar days**, and 90 days with a timestamp; the venue
  states both. A caller asking for more gets what the venue serves, which is why the window
  is worth knowing rather than discovering from a short list.
  """
  @spec get_trades(String.t(), keyword()) ::
          {:ok, [Trade.t()]} | {:error, term()} | {:refused, term()}
  def get_trades(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    # Canonical, not the caller's spelling — see `get_historical_prices/4` (2026-10-10).
    canonical = reported_symbol(symbol, native)

    params =
      []
      |> put_param(:timestamp, timestamp_ms(Keyword.get(opts, :since)))
      |> put_param(:since_tid, Keyword.get(opts, :since_tid))
      |> put_param(:limit_trades, Keyword.get(opts, :limit))
      |> put_param(:include_breaks, include_breaks(opts))

    # `List.wrap/1` used to stand where `list/1` does now: `List.wrap(nil)` answered `{:ok, []}`
    # for an unreadable body, no different from the venue truthfully reporting no trades, and
    # `List.wrap(%{...})` turned an object this package could not parse into a one-row list
    # holding that object whole. The vendor's OpenAPI gives this 200 as a bare array, never
    # either.
    with {:ok, rows} <-
           get_body("/v1/trades/#{segment(native)}", Keyword.put(opts, :params, params)),
         {:ok, rows} <- list(rows) do
      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case to_trade(row, canonical) do
          {:ok, trade} -> {:cont, {:ok, [trade | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        # Oldest first, by the venue's own time — see `Core.Venue`'s callback doc.
        {:ok, trades} ->
          {:ok,
           trades
           |> Enum.reverse()
           |> Enum.sort_by(& &1.timestamp, DateTime)
           |> reject_broken(opts)}

        error ->
          error
      end
    end
  end

  # Asked for only when the caller wants them. The venue hides broken trades by default and
  # this does not second-guess that.
  defp include_breaks(opts), do: if(Keyword.get(opts, :include_broken, false), do: true)

  # Belt and braces: the venue's own filter is asked for above, and anything that arrives
  # marked broken anyway is dropped here unless the caller said otherwise.
  defp reject_broken(trades, opts) do
    if Keyword.get(opts, :include_broken, false),
      do: trades,
      else: Enum.reject(trades, & &1.broken)
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Keyword.put(params, key, value)

  defp timestamp_ms(nil), do: nil
  defp timestamp_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp timestamp_ms(other), do: other

  # `to_string_or_nil/1` on the id, never `to_string/1`.
  #
  # `to_string(nil)` is `""`, so a row with no `tid` produced `id: ""` — a value that passes
  # every `nil` check a consumer might write while identifying no print at all. An empty
  # string is not a weaker id; it is a different kind of wrong, because `nil` is at least
  # detectable. `Private.to_fill/2` carried the identical substitution and was fixed first;
  # this is the same mistake in the sibling decoder, which is why it is worth saying twice.
  #
  # `WsDecode.to_trade/2` — the socket arm of the same type — already used the nil-preserving
  # form. It was the one that did not guard `price` and `quantity`, which this function did.
  # Each file held the fix the other needed.
  defp to_trade(row, _symbol) when not is_map(row), do: {:error, :unexpected_response_shape}

  defp to_trade(row, symbol) do
    with {:ok, timestamp} <- trade_time(row),
         {:ok, price} <- required_decimal(Map.get(row, "price"), :price),
         {:ok, quantity} <- required_decimal(Map.get(row, "amount"), :quantity) do
      {:ok,
       %Trade{
         id: row |> Map.get("tid") |> to_string_or_nil(),
         symbol: symbol,
         # The taker's side. See the note on get_trades/2.
         side: trade_side(Map.get(row, "type")),
         price: price,
         quantity: quantity,
         timestamp: timestamp,
         broken: Map.get(row, "broken", false) == true,
         provider: :gemini
       }}
    end
  end

  # Milliseconds where the venue sends them, seconds otherwise — the venue publishes both
  # fields and `timestampms` is the precise one.
  defp trade_time(%{"timestampms" => ms}) when is_integer(ms),
    do: from_unix_or_undated(ms, :millisecond)

  defp trade_time(%{"timestamp" => seconds}) when is_integer(seconds),
    do: from_unix_or_undated(seconds, :second)

  # An undated print cannot be placed on a tape, and the local clock would place it wrongly
  # while looking right.
  defp trade_time(_row), do: {:error, :missing_venue_timestamp}

  # `DateTime.from_unix/2`, not `from_unix!/2`, and non-positive is refused.
  #
  # Two ways a number that reached here is still not a print time, and the bang version
  # handled neither. **Out of range RAISES**: the seconds clause above takes whatever the
  # venue put in `timestamp`, so milliseconds landing there — this venue publishes both
  # fields, so the two are one typo apart — is `invalid Unix time`, thrown out of the read
  # rather than returned by it. **Zero and negative do NOT raise**: they become 1970 and
  # earlier, which this package has already ruled out in as many words — see
  # `defensive_branches_test.exs`, "an unreadable level timestamp does not become the epoch".
  defp from_unix_or_undated(value, unit) when value > 0 do
    case DateTime.from_unix(value, unit) do
      {:ok, at} -> {:ok, at}
      {:error, _out_of_range} -> {:error, :missing_venue_timestamp}
    end
  end

  defp from_unix_or_undated(_non_positive, _unit), do: {:error, :missing_venue_timestamp}

  # `nil` stays `nil`. `to_string/1` would make it `""`, which reads as an id a consumer can
  # compare and log while identifying nothing — see `to_trade/2`.
  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)

  # A map or a list is not an id, and `to_string/1` raised on it (REST fuzz, 2026-09-27).
  # `nil`, for the reason above: it is the detectable answer.
  defp to_string_or_nil(_not_an_id), do: nil

  defp trade_side("buy"), do: :buy
  defp trade_side("sell"), do: :sell
  defp trade_side(_other), do: nil

  # `GET /v2/fxrate/{symbol}/{timestamp}` — a foreign-exchange reference rate — used to live
  # here, documented "Public". It is not: measured against the vendor's own OpenAPI
  # (`rest.yaml:7836-7851`), this route's `security` lists `apiKeyAuth`, `signatureAuth`
  # and `payloadAuth`, the same full private scheme as any signed POST, and states the key
  # must carry the Auditor role. `Rest` never sends credentials — that is this module's
  # whole design, see the moduledoc — so this function could never succeed no matter what a
  # caller passed it, the same defect `/v2/network/{token}` had directly above. It now lives
  # in `DpExchange.Gemini.Private.get_fx_rate/3`, signed like every other authenticated call.

  # `GET /v2/network/{token}` — the blockchain networks an asset moves over — used to live
  # here, documented "Public". It is not: measured live 2026-09-05, an unauthenticated
  # `GET /v2/network/BTC` returns `401 MissingSecurityHeaders`, and the vendor's own
  # OpenAPI requires apiKeyAuth, signatureAuth and payloadAuth on this route. `Rest` never
  # sends credentials — that is this module's whole design, see the moduledoc — so this
  # function could never succeed no matter what a caller passed it. It now lives in
  # `DpExchange.Gemini.Private.list_networks/2`, signed like every other authenticated
  # call, alongside the network→assets direction it already answered.

  @doc """
  Symbols currently carrying a promotional fee — `GET /v1/feepromos`.

  **Not `get_fees/2`.** That is the schedule applying to this credential; this is the public
  list of symbols where the venue is charging something other than its published schedule.
  A caller computing cost from the schedule alone is wrong for exactly these symbols.

  An empty list means the venue is running no promotions, which is a real state and not an
  error.

  > #### This path is gone from the vendor's specification {: .warning}
  >
  > `GET /v1/feepromos` was in Gemini's OpenAPI document when this was written and is not in
  > it as of **2026-09-21**, found by `script/check_endpoint_inventory.sh`. On this venue
  > absence IS the announcement — it removes things with no changelog entry.
  >
  > The capability moved rather than disappeared: the same specification now gives the
  > authenticated `/v1/notionalvolume` an optional `symbol`, "The symbol to get fee
  > promotions or specific fee schedule rates for". `DpExchange.Gemini.Private.get_fees/2`
  > takes `opts[:symbol]` for exactly that, and is the route to prefer.
  >
  > **This function is left in place and still declared `:experimental`.** A path removed
  > from a document is not a refusal the venue made, and `Core.Capabilities` is explicit that
  > `:unsupported` "would claim a refusal the venue never made" — this repository cannot
  > probe the live endpoint to find out which it is (tier 2 is never run on a schedule), so
  > it does not guess in either direction. What is known is written here.
  """
  @spec list_fee_promos(keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_fee_promos(opts) do
    with {:ok, body} <- get_body("/v1/feepromos", opts) do
      promo_rows(body)
    end
  end

  defp promo_rows(%{"symbols" => symbols}) when is_list(symbols),
    do: {:ok, Enum.map(symbols, &%{"symbol" => &1})}

  # **The wrapper is never a row.** When `"symbols"` is present it decides the shape whatever
  # it holds; only a response with no `"symbols"` key at all is treated as one bare object.
  # The catch-all used to take the wrapper too: `{"symbols": null}` came back as
  # `{:ok, [%{"symbols" => nil}]}`. The same defect
  # `dp_exchange_webull`'s `rows/1` had, found the same day.
  #
  # `null` is no promotions. Any other non-list, or a body that is neither an object nor a
  # list, is unreadable rather than empty: it used to answer `{:ok, []}`, "no promotions",
  # from a response that said nothing about them.
  defp promo_rows(%{"symbols" => nil}), do: {:ok, []}
  defp promo_rows(%{"symbols" => _unreadable}), do: {:error, :unexpected_response_shape}
  defp promo_rows(rows) when is_list(rows), do: {:ok, rows}
  defp promo_rows(%{} = row), do: {:ok, [row]}
  defp promo_rows(_other), do: {:error, :unexpected_response_shape}

  @doc """
  What each provider pays for staking each asset — `GET /v1/staking/rates`.

  Public: the schedule is the same for everyone, so no credential is involved.

  ## The nesting was read backwards, and the fixture agreed with the bug

  Measured live 2026-09-05: the response is `{"<provider-uuid>": {"ETH": {...}, "SOL":
  {...}}}` — the **outer key is a provider UUID** and each provider holds a map keyed by
  **asset symbol**. This package had it inverted: `asset` was read from the outer key and
  `provider_id` from the inner one, so every `StakingRate` it built carried an upcased UUID
  as its asset and a real asset symbol as its provider. Gemini's own OpenAPI names the
  nesting exactly this way too — `StakingRateResponse`'s "Provider UUID Keys" hold a
  `StakingRateProvider`'s "Currency Symbol Keys" — so the mistake was checkable without a
  live call, and it wasn't checked: the test fixture was written keyed the same wrong way,
  which is exactly why a swapped pair of fields survived. The fix is keyed the other way
  and the fixture now uses the shape captured from the live response.

  Each row also names its own field for the notional cap — `depositUsdLimit` — which this
  package read as `depositLimitUsd`, a field the venue does not send. Every row's
  `:deposit_limit_usd` was silently `nil`. The same live payload proved both bugs at once,
  so both are fixed together.

  **Three numbers, and only two of them survive.** Gemini publishes `rate` in *basis
  points*, `ratePct` as a percentage and `apyPct` as an annualised percentage — the first
  two differ by a factor of a hundred and the third by compounding as well. `StakingRate`
  carries percentages only, both named for what they are, because a contract carrying "the
  rate" invites a caller to be wrong by 100× and be plausible either way.

  A row publishing only `rate` is converted (basis points ÷ 100). A row publishing neither
  percentage leaves `:rate_pct` nil rather than deriving one, and `:apy_pct` is never
  derived from `:rate_pct` at all — that needs a compounding frequency the venue did not
  state, and assuming one is inventing a number.

  Both levels are walked so a provider is addressable; `Types.StakingBalance` carries the
  matching breakdown, and redeeming from the wrong provider redeems at the wrong rate.
  """
  @spec get_staking_rates(keyword()) ::
          {:ok, [StakingRate.t()]} | {:error, term()} | {:refused, term()}
  def get_staking_rates(opts) do
    with {:ok, body} <- get_body("/v1/staking/rates", opts) do
      staking_rates(body)
    end
  end

  # **Every level must be an object, or the reply is refused.** A body, a provider's entry or
  # an asset's row that was not one used to be skipped or filled: the body read as no rates,
  # a provider as offering nothing, and a row as a `StakingRate` with every number `nil`,
  # asserting the provider stakes that asset. A caller choosing where to stake then chose
  # among what this package could read, believing it was everything the venue offered.
  defp staking_rates(%{} = body) do
    body
    |> Enum.reduce_while({:ok, []}, fn {provider_id, assets}, {:ok, acc} ->
      case rates_for_provider(provider_id, assets) do
        {:ok, rates} -> {:cont, {:ok, [rates | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp staking_rates(_other), do: {:error, :unexpected_response_shape}

  defp rates_for_provider(provider_id, %{} = assets) do
    if Enum.all?(assets, fn {_asset, row} -> is_map(row) end),
      do: {:ok, Enum.map(assets, fn {asset, row} -> staking_rate(asset, provider_id, row) end)},
      else: {:error, :unexpected_response_shape}
  end

  defp rates_for_provider(_provider_id, _other), do: {:error, :unexpected_response_shape}

  defp staking_rate(asset, provider_id, row) do
    %StakingRate{
      asset: String.upcase(asset),
      provider_id: provider_id,
      rate_pct: rate_pct(row),
      apy_pct: decimal(row["apyPct"]),
      deposit_limit_usd: decimal(row["depositUsdLimit"]),
      venue_time: nil,
      provider: :gemini
    }
  end

  # `ratePct` where the venue publishes it; otherwise `rate`, which is basis points, divided
  # by a hundred. Never `apyPct`, which is a different number for the same position.
  defp rate_pct(%{"ratePct" => pct}) when is_binary(pct) or is_number(pct), do: decimal(pct)

  defp rate_pct(%{"rate" => bps}) when is_binary(bps) or is_number(bps) do
    case decimal(bps) do
      nil -> nil
      value -> Decimal.div(value, Decimal.new(100))
    end
  end

  defp rate_pct(_row), do: nil

  @doc """
  Funding for a perpetual — `GET /v1/fundingamount/{symbol}`.

  Public: funding is a property of the contract, not of an account.

  **Settled and estimated are different facts and stay in different fields.** `amount` is
  funding that has happened at a funding time that has passed; `estimatedFundingAmount` is
  the venue's projection for the next one and moves continuously until it settles. A real
  response carries `-1.50991` beside `-2.10595` — 40% apart — which is how wrong a caller
  reading "the funding" would be.

  **The sign is the venue's and is carried through unchanged.** It means direction between
  longs and shorts, and normalising it here would assert a convention Gemini did not state.

  Both timestamps travel: `fundingTimestampMilliSecs` is when this one settled and
  `nextFundingTimestamp` is when the next one lands. A caller holding across that instant
  pays or receives at it.

  **The vendor's own spec contradicts itself on the settled amount's field name.**
  `FundingAmountResponse`'s schema (`rest.yaml:9420`) names it `amount`; the very same
  endpoint's own example response two sections up (`:562`) gives `fundingAmount` instead —
  both are the vendor's own names for the field, in the same document, for the same
  endpoint. `amount` is read first, and `fundingAmount` where it is absent, rather than
  picking one and reading the other's real value as "not reported".
  """
  @spec get_funding(String.t(), keyword()) ::
          {:ok, Funding.t()} | {:error, term()} | {:refused, term()}
  def get_funding(symbol, opts) do
    with {:ok, raw} <- get_body("/v1/fundingamount/#{segment(symbol)}", opts),
         {:ok, body} <- object(raw) do
      {:ok,
       %Funding{
         symbol: body["symbol"] || symbol,
         amount: decimal(body["amount"] || body["fundingAmount"]),
         estimated_amount: decimal(body["estimatedFundingAmount"]),
         funded_at: epoch_ms(body["fundingTimestampMilliSecs"]),
         next_funding_at: epoch_ms(body["nextFundingTimestamp"]),
         provider: :gemini
       }}
    end
  end

  @doc """
  When the next funding calculation lands — `GET /v1/nextfundingtimestamp/{symbol}`.

  Public, and **the venue answers with a bare integer**, not an object: milliseconds since
  the epoch and nothing around it. `get_funding/2` carries the same value alongside the
  amounts; this exists because a caller that only needs the schedule should not have to read
  a funding amount to get it.

  A body that is not an integer is `{:error, :unexpected_response_shape}` rather than a nil
  timestamp — "the venue said something else" and "there is no next funding" are different
  answers, and the second would be remarkable on a perpetual.
  """
  @spec next_funding_timestamp(String.t(), keyword()) ::
          {:ok, DateTime.t()} | {:error, term()} | {:refused, term()}
  def next_funding_timestamp(symbol, opts) do
    with {:ok, body} <- get_body("/v1/nextfundingtimestamp/#{segment(symbol)}", opts) do
      case epoch_ms(body) do
        nil -> {:error, :unexpected_response_shape}
        at -> {:ok, at}
      end
    end
  end

  @doc """
  Risk statistics for a perpetual — `GET /v1/riskstats/{symbol}`.

  Public. **Three prices, and none of them is the other.** `mark_price` is what Gemini marks
  positions and computes liquidations against; `index_price` is the external reference it is
  derived from; and neither is what the contract last traded at, which is `get_price/2`. A
  position can be liquidated at a mark the market never printed, and that is why the two are
  separate fields rather than one.

  Open interest arrives twice — in contracts and in notional — and neither substitutes for
  the other across instruments with different contract sizes.

  `venue_time` is `nil`: this endpoint publishes no timestamp of its own, and stamping the
  local clock would make a stale response indistinguishable from a current one.
  """
  @spec get_contract_stats(String.t(), keyword()) ::
          {:ok, ContractStats.t()} | {:error, term()} | {:refused, term()}
  def get_contract_stats(symbol, opts) do
    with {:ok, raw} <- get_body("/v1/riskstats/#{segment(symbol)}", opts),
         {:ok, body} <- object(raw) do
      {:ok,
       %ContractStats{
         symbol: body["symbol"] || symbol,
         product_type: body["product_type"],
         mark_price: decimal(body["mark_price"]),
         index_price: decimal(body["index_price"]),
         open_interest: decimal(body["open_interest"]),
         open_interest_notional: decimal(body["open_interest_notional"]),
         venue_time: nil,
         provider: :gemini
       }}
    end
  end

  defp epoch_ms(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, at} -> at
      {:error, _reason} -> nil
    end
  end

  defp epoch_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {millis, ""} -> epoch_ms(millis)
      _other -> nil
    end
  end

  defp epoch_ms(_other), do: nil
  # --- internals ----------------------------------------------------------

  # **A response of the wrong JSON shape is a refusal, never a raise.** These decoders read
  # `body["field"]`, and `Access` on a LIST raises `ArgumentError`; they iterate rows, and
  # iterating `null` raises `Protocol.UndefinedError` while iterating an object walks its
  # key/value pairs into a function expecting a row. Found by feeding every active facade
  # call a set of plausible-but-wrong bodies — `[]`, `null`, `{}`, an object whose lists are
  # all `null` — and seven raised in the CALLER's process: `get_top_of_book/2`,
  # `get_funding/2` and `get_contract_stats/2` on `[]`; `get_symbols/1`,
  # `get_market_overview/1` and `get_historical_prices/4` on `null` or an object;
  # `Private.get_deposit_address/4` on `[]`. `Core.Venue`'s error discipline is that a facade
  # answers, and never raises. `:unexpected_response_shape` is the refusal this module
  # already uses for the same condition in `quoted_price/1` and `to_fx_rate/3`.
  @doc false
  @spec object(term()) :: {:ok, map()} | {:error, :unexpected_response_shape}
  def object(%{} = body), do: {:ok, body}
  def object(_other), do: {:error, :unexpected_response_shape}

  @doc false
  @spec list(term()) :: {:ok, list()} | {:error, :unexpected_response_shape}
  def list(body) when is_list(body), do: {:ok, body}
  def list(_other), do: {:error, :unexpected_response_shape}

  defp get_body(path, opts) do
    with {:ok, body, _headers} <- get_with_headers(path, opts), do: {:ok, body}
  end

  # Everything goes through `request/5` rather than `get/3`, for two reasons that both
  # come down to what `get/3` throws away: it drops the response headers, which is where
  # this venue's only usable quote timestamp lives, and it maps a 4xx to a message string,
  # which is where this venue states its refusal reason.
  #
  # ## A 404 on these endpoints is the venue speaking, not the endpoint missing
  #
  # Measured live 2026-09-06: `GET /v1/pubticker/nonexistentsymbolxyz` returns **404**,
  # plain text, `'nonexistentsymbolxyz' does not have available data yet` — the venue
  # naming exactly the condition `Core.PollingFeed`'s typedoc means by a venue *statement*
  # that it does not carry the symbol, not a routing failure. `GET
  # /v1/fundingamount/nonexistentsymbolxyz` also 404s, with an empty body. Before this, a
  # 404 fell through to the generic `{:error, {:exchange_error, …}}` clause below — the
  # one shape the family reserves for a possibly-transient failure — so a permanently
  # unlisted symbol looked retryable forever. Every symbol-scoped GET in this module
  # shares this clause, so the fix is here rather than at each call site.
  defp get_with_headers(path, opts) do
    url = base_url(opts) <> path <> query(opts)

    case HttpClient.request(:get, url, [], nil, request_opts(opts)) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        with {:ok, decoded} <- decoded_body(body), do: {:ok, decoded, headers}

      {:ok, %{status: status, body: body}} when status in [400, 404] ->
        {:refused, refusal(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exchange_error, :gemini, "HTTP #{status}: #{inspect(body)}"}}

      # Rate limiting arrives as an ordinary two-element error carrying the retry interval
      # in its message — both the venue's 429 and our own limiter's refusal, which Core
      # words differently on purpose. A clause here matched a three-element
      # `{:error, :rate_limited, retry_after: n}` because Core's spec advertised one;
      # dialyzer proved that shape is never returned, and Core's spec was corrected rather
      # than this dead clause kept.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(opts) do
    case Config.opt(opts, :params, []) do
      [] -> ""
      params -> "?" <> URI.encode_query(params)
    end
  end

  # `:plug` and `:req_adapter` go through so tier-1 tests can exercise this pipeline
  # without reaching a network — the same seam a consumer would use.
  #
  # `raw_status: true` is what makes a refusal possible. Gemini names its own reason in a
  # 4xx body — `InvalidSymbol`, `InvalidParameterValue` — and without this Core flattens
  # status and body into a message string, leaving a venue to recover the distinction by
  # matching substrings. Added to Core for this package.
  #
  # `:rate_limit_blocking` is forwarded from here too — a family-wide gap
  # (DpCryptoManagement's issue #23's investigation, alongside `dp_exchange_webull`'s own
  # issue #23 and `dp_exchange_robinhood`'s issue #16): `Core.HttpClient.check_rate_limits/1`
  # reads it to choose `acquire/3` over fail-fast `check/3`, and no caller of this module
  # could ever set it. Not defaulted — this venue's periodic resubscribe
  # (`DpExchange.Gemini.Feed`'s unconditional 60s re-issue) sends WebSocket frames, not
  # HTTP, so there is no rate-limited background replay here that would justify choosing
  # a default on a caller's behalf.
  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :limiter,
      :timeout,
      :retry_attempts,
      :log_requests,
      :plug,
      :req_adapter,
      :rate_limit_blocking
    ])
    |> Keyword.merge(provider: :gemini, raw_status: true)
  end

  # A 2xx body this package cannot decode is NOT an empty object.
  #
  # This used to collapse any unparseable body to `%{}` and hand it on as success. Nothing
  # downstream could tell that apart from a real but sparse response: `%{}` flows through
  # every `to_*` reader in this module and comes out as a well-formed struct with each
  # field `nil`, returned as `{:ok, value}`. The realistic way to get there is not malformed
  # JSON from the venue but a `200` that is not the venue at all — an interstitial, a
  # captive portal, or a CDN maintenance page, all of which answer `200 text/html`. A
  # caller polling through one of those was told, truthfully-looking, that the book was
  # empty.
  #
  # Refuse instead. Refusal bodies do NOT come through here — see `refusal/1` below, which
  # reads the venue's own text and has its own reason to stay lenient.
  defp decoded_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:undecodable_response, :gemini}}
    end
  end

  defp decoded_body(body), do: {:ok, body}

  # A 400 or 404 from Gemini names its own reason, and the ones below are permanent for
  # the request as sent — no retry can make an unknown symbol known. That is a refusal,
  # not an error, and the distinction is the whole point of having two shapes.
  #
  # `body` is passed RAW, not through the shared decoder: that decoder's fallback used to
  # collapse unparseable JSON to `%{}`, which would discard the venue's own text before
  # `refusal_reason/1` ever saw it. Measured live 2026-09-06:
  # `/v2/candles/{symbol}/{width}`'s 400 body is plain text (`"Supplied value 'X' is not a
  # valid symbol"`), not JSON, so routing it through that decoder used to turn it into
  # `{:refused, :refused}` — the venue's only stated reason, discarded. `refusal_reason/1`
  # now does its own decode and keeps the text when there is nothing else to keep.
  #
  # The `%{}` collapse is gone from the 2xx path too — `decoded_body/1` above refuses there
  # rather than inventing an empty success — but this clause would still be wrong to route
  # through it. A plain-text refusal body is not an undecodable *response*; it is the
  # venue's answer in the form the venue chose, and refusing it would swap a specific
  # `{:refused, reason}` for a generic error.
  defp refusal(body), do: refusal_reason(body)

  @doc false
  # Shared with `DpExchange.Gemini.Private`, which refuses on the same venue vocabulary.
  # One implementation rather than two copies that can drift apart on a security fix.
  #
  # ## This must never call `String.to_atom/1` on the venue's reason
  #
  # It used to. `reason` arrives from the venue's own JSON error body, and atoms are
  # **never garbage collected** — the VM's atom table is finite (default ~1,048,576) and
  # exhausting it kills the entire BEAM, not just this package. Since these packages run
  # *inside* a consumer's application, an unbounded stream of distinct reasons would take
  # that consumer's whole node down, driven by input this package does not control. Found
  # by `mix sobelow` (`DOS.StringToAtom`) during the 2026-09-05 defect sweep, where it had
  # been waved through twice as a "pre-existing low-confidence warning".
  #
  # `Core.FakeInjection` already designed around this same class deliberately — see its
  # moduledoc. The rule is the same here: an atom may only ever come from a fixed set
  # written down at compile time.
  #
  # A reason NOT in that set keeps the venue's own words as data rather than being
  # flattened to a bare `:refused`, because the venue's wording is the only thing that
  # says what actually happened, and Gemini adds reasons without telling anyone.
  #
  # ## Some refusals arrive as plain text, not JSON
  #
  # `HttpClient`/Req only decodes a body it recognises as JSON; a plain-text 4xx (measured
  # live on `/v2/candles`) reaches this function as a raw `String.t()`, not a map. This
  # clause decodes it here rather than upstream, so a body that turns out not to be JSON
  # at all still keeps its own words — via `{:unknown_reason, text}` — instead of losing
  # them to the same `%{}`-shaped fallback a 2xx body uses. An empty body (Gemini's 404 on
  # `/v1/fundingamount/{symbol}`, measured the same day) names nothing to keep, so it stays
  # a bare `:refused` rather than `{:unknown_reason, ""}`.
  #
  # ## A KNOWN reason must never be less informative than an unknown one
  #
  # This function used to answer a known reason with a bare atom and throw the venue's
  # `message` away, while an unknown one kept the venue's words. That asymmetry contradicted
  # the paragraph directly above it, and it broke a consumer (dp-exchange-gemini issue #1).
  #
  # Gemini's nonce rejection is the case that proves it:
  #
  #     {"result": "error", "reason": "InvalidNonce",
  #      "message": "Nonce '1757...' has not increased since your last call ..."}
  #
  # `:invalid_nonce` names the category. The **message** is the entire diagnosis, because
  # the two situations it distinguishes have opposite remedies: a stored high-water nonce
  # above what we send (bump the scale — a key poisoned to ~1.4e19 needed nonces above
  # 2^64), or a key whose mark has climbed past anything we can emit (rotate it, which only
  # a human can do). Without the sentence a caller cannot tell those apart, and 164
  # occurrences of `"gemini refused: :invalid_nonce"` in one log span told its reader
  # nothing at all.
  #
  # So a known reason carries the venue's sentence when there is one:
  #
  #   * `{reason, message}` — the venue named a category AND said more.
  #   * `reason` alone — the venue named a category and nothing else.
  #   * `{:unknown_reason, word}` — unchanged; the venue's own word IS the diagnosis when
  #     nothing here recognises it.
  #
  # Two shapes for a known reason is deliberate, and it is not "sometimes a tuple". The
  # tuple means *the venue said more*, which is a different fact from *the venue named a
  # category*, and flattening them would either invent a `nil` message for refusals that
  # never had one or throw away the sentence that made this issue worth filing. It also
  # keeps every message-less refusal matching exactly as it did — including the `Fake`'s,
  # which builds refusals literally and must stay shape-identical to the real venue
  # (assertion 9). The only callers that change are the ones that were being under-informed.
  @spec refusal_reason(term()) ::
          :refused | atom() | {atom(), String.t()} | {:unknown_reason, String.t()}
  def refusal_reason(%{"reason" => reason} = body) when is_binary(reason) do
    classify(reason, message_from(body))
  end

  def refusal_reason(body) when is_binary(body) do
    case String.trim(body) do
      "" ->
        :refused

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{"reason" => reason} = decoded} when is_binary(reason) ->
            classify(reason, message_from(decoded))

          {:ok, _other} ->
            :refused

          {:error, _reason} ->
            {:unknown_reason, trimmed}
        end
    end
  end

  def refusal_reason(_other), do: :refused

  # An unknown reason keeps the venue's own word as the payload, exactly as before — that
  # word IS the diagnosis when nothing here recognises it, and the message (if any) rarely
  # adds to a reason nobody has seen. A known one carries the message instead, since the
  # atom already says what the word would have.
  defp classify(reason, message) do
    case Map.fetch(@refusal_reasons, reason) do
      {:ok, known} when is_binary(message) -> {known, message}
      {:ok, known} -> known
      :error -> {:unknown_reason, reason}
    end
  end

  # Only a non-empty binary counts. An absent, null or blank `message` becomes `nil`, so a
  # caller can test one thing — "did the venue say more?" — instead of also guarding "" .
  defp message_from(%{"message" => message}) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp message_from(_no_message), do: nil

  # The venue's own clock, from the response it served. Absent, and the request fails —
  # a quote whose freshness cannot be stated must not be returned.
  # Req hands headers back as a map of lowercase name to a LIST of values; a raw client
  # hands back a list of two-tuples with the venue's own casing. Both shapes appear here,
  # and reading only one of them is how a header goes silently missing.
  defp venue_time(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "date", do: value
    end)
    |> first_value()
    |> parse_http_date()
  end

  defp first_value([value | _rest]), do: value
  defp first_value(value), do: value

  # RFC 1123, which is what an HTTP `Date` header is: "Fri, 28 Aug 2026 17:00:01 GMT".
  # Parsed here rather than taking a date dependency for one fixed format — and parsed
  # strictly: anything that does not match returns `:missing_venue_timestamp`, because a
  # header we cannot read is indistinguishable from one that was not sent.
  defp parse_http_date(value) when is_binary(value) do
    # The zone is required to be the literal `GMT`, as RFC 7231's IMF-fixdate requires. It
    # used to be matched and discarded, so a header in any other zone was read as UTC and
    # could be hours off: a plausible time with the wrong meaning.
    with [_day, d, mon, y, time, "GMT"] <- String.split(value, [" ", ", "], trim: true),
         {day, ""} <- Integer.parse(d),
         {year, ""} <- Integer.parse(y),
         {:ok, month} <- month_number(mon),
         [h, m, s] <- String.split(time, ":"),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(m),
         {second, ""} <- Integer.parse(s),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _other -> {:error, :missing_venue_timestamp}
    end
  end

  defp parse_http_date(_other), do: {:error, :missing_venue_timestamp}

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp month_number(name) do
    case Enum.find_index(@months, &(&1 == name)) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  # This used to derive the book's own time from the newest level's `timestamp` — see this
  # function's callers' @doc for why that was reading a field the vendor's own schema marks
  # a meaningless dummy value. What is left of that function is the shape check it also
  # did: `List.wrap/1` on each side rather than `bids ++ asks`, because a venue that sends
  # `"asks": null` for an empty side crashed this with a FunctionClauseError from deep
  # inside `Enum.map`, reaching a caller as a crash rather than an answer — an absent side
  # is a book with no asks, not a malformed response, and `levels/2` already answers `[]`
  # for `nil`. A side that is PRESENT but not a list is not an empty side, though; that
  # used to raise out of `Map.get/2` too (REST fuzz, 2026-09-27), and `levels/2` has no
  # clause for a value that is neither a list nor `nil` — this is what keeps it from
  # reaching one.
  defp book_shape(%{"bids" => bids, "asks" => asks})
       when (is_list(bids) or is_nil(bids)) and (is_list(asks) or is_nil(asks)),
       do: :ok

  defp book_shape(%{"bids" => _bids, "asks" => _asks}), do: {:error, :unexpected_response_shape}
  defp book_shape(_other), do: {:error, :unexpected_response_shape}

  # All-or-error. Found 2026-10-10: `levels/2` dropped a row with an unreadable price and kept
  # one with an unreadable amount as `{price, nil}`, so a damaged reply became a complete-
  # looking book. The websocket arm refuses the same way (`WsDecode.to_order_book/3`).
  defp readable_book_side(nil), do: :ok

  defp readable_book_side(rows) when is_list(rows) do
    if Enum.all?(rows, &readable_book_row?/1),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  defp readable_book_row?(%{"price" => price, "amount" => amount}),
    do: decimal(price) != nil and decimal(amount) != nil

  defp readable_book_row?(_row), do: false

  defp levels(nil, _direction), do: []

  # Sorted, and levels with an unreadable price dropped — the REST arm of the fix
  # `WsDecode.to_order_book/3` got the same day. `Core.Types.OrderBook` makes the ordering
  # part of the contract, and `@type level :: {Decimal.t(), Decimal.t()}` has no nil in it,
  # so `hd(bids)` must be able to answer "the best bid" with a real number.
  #
  # `{direction, Decimal}` rather than term order, because `Decimal` structs do not compare
  # correctly as plain terms. A nil AMOUNT is kept: a level stating a price but no size is a
  # real shape rather than an unreadable one.
  defp levels(rows, direction) when is_list(rows) do
    rows
    |> Enum.flat_map(fn
      row when not is_map(row) ->
        []

      row ->
        case decimal(row["price"]) do
          nil -> []
          price -> [{price, decimal(row["amount"])}]
        end
    end)
    |> Enum.sort_by(fn {price, _amount} -> price end, {direction, Decimal})
  end

  defp time_frame(canonical) do
    case Map.fetch(@time_frames, canonical) do
      {:ok, native} -> {:ok, native}
      :error -> {:error, {:unsupported_timeframe, canonical}}
    end
  end

  # The window is fixed, so a start older than it can reach is unanswerable. Returning
  # what the window happens to hold would look like a complete answer for a period the
  # venue simply does not serve.
  #
  # `1w` and `1M` fall through to the `:ok` branch below every time: neither is in
  # `@window_bars`, because neither has a `Timeframe.seconds/1` width to multiply a bar
  # count by. That is a real, disclosed gap — see the moduledoc's "`1w` and `1mo`" section
  # — not an oversight; `get_historical_prices/4` still filters their real rows against
  # `range` afterward, so a caller reaching before the actual window gets an empty list
  # rather than wrong data, just without this pre-flight refusal naming the boundary.
  # A `:start` or `:end` that is not a `DateTime` is refused here. It reached
  # `DateTime.compare/2` in the row filter and raised in the caller's process.
  defp range_within_window(timeframe, range) do
    case Enum.find([:start, :end], &(not range_bound?(Keyword.get(range, &1)))) do
      nil -> window_check(timeframe, range)
      bad -> {:error, {:invalid_range, bad, Keyword.get(range, bad)}}
    end
  end

  defp range_bound?(nil), do: true
  defp range_bound?(%DateTime{}), do: true
  defp range_bound?(_other), do: false

  # The oldest bar the venue still serves opened at the start of the current bar minus
  # `bars - 1` widths. `now - bars * width` ignored the bar in progress, so a `:start` up to
  # one bar past the real edge passed this check and came back short, which is the silent
  # truncation this check exists to refuse.
  defp window_check(timeframe, range) do
    with %DateTime{} = start <- Keyword.get(range, :start),
         {:ok, bars} <- Map.fetch(@window_bars, timeframe),
         {:ok, width} <- Timeframe.seconds(timeframe) do
      now = DateTime.to_unix(DateTime.utc_now())
      earliest = DateTime.from_unix!(div(now, width) * width - (bars - 1) * width)

      if DateTime.compare(start, earliest) == :lt do
        {:error, {:range_unavailable, timeframe, earliest: earliest, requested: start}}
      else
        :ok
      end
    else
      _no_start_or_unknown_width -> :ok
    end
  end

  # Refuses a candle row this package cannot read, rather than building one out of whatever
  # survived.
  #
  # `Core.Types.Candle` enforces `:open`, `:high`, `:low`, `:close` and `:opened_at`, and its
  # `new/1` refuses a `nil` in any of them. Nothing here called `new/1` — this built the
  # struct literally — so the check never ran, and the four prices went through bare
  # `decimal/1`, which answers `nil` for an absent, empty, unparseable, NaN or Infinity
  # value. `Types.Validate`'s moduledoc uses this exact type as its worked example of the
  # gap: "`struct!(Candle, open: nil, ...)` builds without complaint, even though `Candle`'s
  # own typespec declares `open: Decimal.t()`". `dp_exchange_coinbase` and
  # `dp_exchange_webull` both guard all four with `required_decimal/2`; this module already
  # had that helper and this decoder was the one place not using it.
  #
  # **`opened_at` was worse than unguarded — it was substituted.** `to_integer/1` answered
  # `0` for a string `Integer.parse/1` could not read, so a malformed timestamp became
  # `DateTime.from_unix!(0)`: a candle opened on 1 January 1970, sorted to the front of the
  # series, every price in it real. That is the family's named failure exactly — a plausible
  # value carrying the wrong meaning — and it is why `candle_time/1` below returns an error
  # rather than a number. The same function also raised on a `nil` or a map (no clause) and
  # on an integer outside `DateTime`'s range (`from_unix!`), so the honest answers and the
  # crashes are now one refusal.
  #
  # `volume` stays unguarded on purpose: it is not an enforced key, and a venue that did not
  # state a volume has not stated one.
  defp row_to_candle([time_ms, open, high, low, close, volume], symbol, timeframe) do
    with {:ok, opened_at} <- candle_time(time_ms),
         {:ok, open} <- required_decimal(open, :open),
         {:ok, high} <- required_decimal(high, :high),
         {:ok, low} <- required_decimal(low, :low),
         {:ok, close} <- required_decimal(close, :close) do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: opened_at,
         open: open,
         high: high,
         low: low,
         close: close,
         volume: decimal(volume),
         provider: :gemini
       }}
    end
  end

  # A row that is not six elements. This used to have no such clause, so the venue sending a
  # seventh field — or one fewer — raised `FunctionClauseError` out of a `GenServer`'s own
  # fetch rather than returning an error the caller could act on.
  defp row_to_candle(_row, _symbol, _timeframe), do: {:error, :unexpected_response_shape}

  # One unreadable row refuses the whole series rather than leaving a gap in it. A candle
  # list with a bar silently missing reads as "the venue published nothing for that minute",
  # which a consumer will treat as a real gap in the market rather than as a decode failure.
  defp rows_to_candles(rows, symbol, timeframe) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case row_to_candle(row, symbol, timeframe) do
        {:ok, candle} -> {:cont, {:ok, [candle | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, candles} -> {:ok, Enum.reverse(candles)}
      error -> error
    end
  end

  defp candle_time(value) when is_integer(value), do: from_unix_ms(value)
  defp candle_time(value) when is_float(value), do: from_unix_ms(trunc(value))

  defp candle_time(value) when is_binary(value) do
    # The WHOLE string, not `Integer.parse/1`'s leading run. `{integer, _rest}` accepted
    # `"1757000000000-ish"` as a timestamp and threw the rest away — the same
    # partial-parse hazard `decimal/1` above is written against.
    case Integer.parse(value) do
      {milliseconds, ""} -> from_unix_ms(milliseconds)
      _unparsable -> {:error, {:unparseable_venue_timestamp, value}}
    end
  end

  defp candle_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  defp from_unix_ms(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, at} -> {:ok, at}
      {:error, _reason} -> {:error, {:unparseable_venue_timestamp, milliseconds}}
    end
  end

  defp within?(candle, range) do
    after_start?(candle, Keyword.get(range, :start)) and
      before_end?(candle, Keyword.get(range, :end))
  end

  defp after_start?(_candle, nil), do: true
  defp after_start?(candle, start), do: DateTime.compare(candle.opened_at, start) != :lt

  defp before_end?(_candle, nil), do: true
  defp before_end?(candle, finish), do: DateTime.compare(candle.opened_at, finish) != :gt

  # `/v1/pubticker` reports volume keyed by currency code, so the base asset's key has to
  # be recovered from the symbol rather than assumed to be first.
  defp base_volume(%{"volume" => volume}, native) when is_map(volume) do
    base =
      native
      |> SymbolFormat.to_canonical_symbol()
      |> String.split("-")
      |> List.first()

    decimal(Map.get(volume, base))
  end

  defp base_volume(_body, _native), do: nil

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.new/1` raises on a string the venue did not actually send a number in —
  # measured live at production scale against `wss://ws.gemini.com` for the socket's own
  # copy of this helper, which is where this was found. `Decimal.parse/1`, requiring the
  # whole string be consumed (`{d, ""}`), is what this package already does in
  # `ws_decode.ex`; every copy of this helper now matches it.
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

  # A garbage or missing value in a field this contract requires must not become a `nil`
  # carried into `@enforce_keys` — a struct's own field list does not check that a value
  # is non-nil, only that the key was given, so `decimal/1`'s lenient `nil` would sail
  # straight through and out to a subscriber as a `Quote` or `Trade` with no price. Refuse
  # the record instead; `field` names which value failed, for the caller reading the error.
  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end

  # Sort key only — never used to bucket or window-check a real candle, so an
  # approximation here is not the family's forbidden kind. `1w` and `1M` have no
  # `Timeframe.seconds/1` width; this places them after `1d` and in their own
  # calendar order without claiming either is a fixed number of seconds anywhere else.
  @approx_sort_seconds %{"1w" => 604_800, "1M" => 2_629_800}

  defp width!(timeframe) do
    case Timeframe.seconds(timeframe) do
      {:ok, seconds} -> seconds
      :error -> Map.fetch!(@approx_sort_seconds, timeframe)
    end
  end

  # One path segment, percent-encoded. Symbols, networks and tickers were interpolated raw,
  # so a value carrying `/` or `?` changed the path or started a query, and on a signed
  # request the venue was asked for a resource the caller never named. Every value the venue
  # documents is unreserved already, so for them this changes nothing.
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  # The symbol a returned struct names. A spot pair reports its canonical `BASE-QUOTE`. A
  # perpetual reports the caller's symbol, uppercased, because `SymbolFormat` deliberately
  # gives a perpetual no canonical form (see its moduledoc): `to_canonical_symbol/1` of
  # `"btcgusd-perp"` is `"BTCGUSD-PERP"`, a symbol that maps back to `"btcgusdperp"`, not the
  # one asked. Found 2026-10-10 when canonicalising candles broke the vendor's own perpetual
  # example, and the same mangling was already on `get_price/2`, `get_top_of_book/2` and
  # `get_order_book/2` for a perpetual.
  defp reported_symbol(symbol, native) do
    if SymbolFormat.perpetual?(native),
      do: String.upcase(symbol),
      else: SymbolFormat.to_canonical_symbol(native)
  end
end
