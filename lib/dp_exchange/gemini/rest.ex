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
  **error** rather than a short answer for the seven widths above whose window this package
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
  `range` client-side by `within?/4` on their own real `opened_at`, same as every width. A
  `:start` older than anything the venue returns on one of these two is not refused: the
  filter keeps every returned bar opened at or after `:start`, so the answer is the bars the
  venue sent, beginning wherever its reply begins, rather than
  `{:error, {:range_unavailable, …}}`. Whether the venue's `1w` and `1M` replies reach back
  to the instrument's listing or stop at a fixed count has not been measured. That is a real
  gap from the other seven widths, disclosed here rather than hidden behind a fabricated
  window size.

  ## Neither ticker carries a quote time, so `:venue_time` is always `nil`

  `/v1/pubticker` returns a `timestamp`, but it is **inside the `volume` object** — it
  stamps the 24-hour volume window, updates about once a minute, and is not when the bid
  and ask were true or the last trade happened. `/v2/ticker` carries no timestamp at all.
  Using either as the quote time would be a substitution of exactly the kind this family
  exists to stop.

  **The HTTP `Date` response header is not used either** (family rule MD7, tick R). It is
  when the reply was served, not when the last trade happened or the quote was true, so it
  is a different event's time. `Quote.venue_time` and `TopOfBook.venue_time` are `nil` from
  REST; `observed_at` states freshness. A consumer needs a `nil` branch for this venue.

  ## Candle conventions (tick R)

    * The bar still forming (`opened_at + width > now`) is dropped unless the caller passes
      `include_partial: true`; with it the last bar is returned as the venue sent it and may
      still change.
    * `:start` is inclusive and `:end` exclusive, on `opened_at`; an absent `:end` is now,
      except with `include_partial: true`, which applies no upper bound (a bar just opened
      must not vanish because this clock runs behind the venue's).
    * `opened_at` must be aligned to the bar width. The venue does not state whether its
      timestamp is a bar's open or close, so a bar not aligned (`Timeframe.aligned?/2`)
      refuses the whole reply `{:error, {:unaligned_candle, time}}`, and two bars with the
      same timestamp in one reply refuse it `{:error, {:duplicate_candle, time}}`. Both
      checks are UNMEASURED against the live venue: they fail closed on what the vendor
      does not state (and its own example repeats a timestamp).
    * An open, high, low or close <= 0 refuses the reply.
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
    "InvalidSymbol" => :not_listed,
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
  The last traded price for one symbol, as a `Quote`. Bid and ask are `get_top_of_book/2`.
  `venue_time` is always `nil` — the venue states no trade time; see the module doc. A `last`
  of zero or less is not a price and refuses the reply.
  """
  @spec get_price(String.t(), keyword()) ::
          {:ok, Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, opts) do
    with :ok <- validate_symbol(symbol),
         native = SymbolFormat.to_exchange_symbol(symbol),
         {:ok, body} <- get_symbol_body("/v1/pubticker/#{segment(native)}", opts),
         {:ok, last} <- quoted_price(body),
         {:ok, price} <- required_price(last, :price),
         # The ticker's `volume` is "the 24 hour volume on the exchange", measured up to its
         # own `timestamp` (`Ticker` in docs/reference/gemini/openapi/rest.yaml), so a rolling
         # 24-hour total. No interval's volume can be derived from it — dp-exchange-core issue
         # #42. Per-interval volume comes from the `:trades` stream.
         {:ok, volume} <- base_volume(body, native) do
      {:ok,
       %Quote{
         symbol: reported_symbol(symbol, native),
         price: price,
         volume: volume,
         volume_window: volume && :rolling_24h,
         # Always `nil` (family rule MD7): the venue states no time for the last trade.
         # The HTTP `Date` header is when the reply was served, not when the trade
         # happened, and `volume.timestamp` stamps the 24-hour window, not the quote.
         # Neither is substituted; `observed_at` states freshness.
         venue_time: nil,
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
  and not zero. `venue_time` is `nil` (the venue states no quote time; the `Date` header is
  not it); `observed_at` is when this package read it. A side priced `0` is no resting order
  on that side (`nil`); a negative or unreadable side refuses the reply.
  """
  @spec get_top_of_book(String.t(), keyword()) ::
          {:ok, TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, opts) do
    with :ok <- validate_symbol(symbol),
         native = SymbolFormat.to_exchange_symbol(symbol),
         {:ok, body} <- get_symbol_body("/v1/pubticker/#{segment(native)}", opts),
         {:ok, body} <- object(body),
         :ok <- ticker_states_a_side(body),
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
         # `nil`: the ticker states no time for the quote (family rule MD7). The `Date`
         # header is when the reply was served, which is a different event.
         venue_time: nil,
         observed_at: DateTime.utc_now(),
         provider: :gemini
       }}
    end
  end

  # A 200 object naming neither `bid` nor `ask` is not a ticker. Reading it gave a `TopOfBook`
  # with both sides `nil`, which the type reads as "no resting orders" — a claim about the
  # book the venue never made (`get_price/2` already refuses the same body via `quoted_price/1`).
  # One side absent stays `nil`; a side stated as `""` or `null` is the venue's own empty side.
  defp ticker_states_a_side(body) do
    if Map.has_key?(body, "bid") or Map.has_key?(body, "ask"),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  # A price of zero means no resting order on that side (family rule MD6): `nil`. A negative
  # one, or one this package cannot read, refuses the reply.
  defp stated_price(empty) when empty in [nil, ""], do: {:ok, nil}

  defp stated_price(value) do
    case decimal(value) do
      nil ->
        {:error, :unexpected_response_shape}

      price ->
        case Decimal.compare(price, 0) do
          :gt -> {:ok, price}
          :eq -> {:ok, nil}
          :lt -> {:error, :unexpected_response_shape}
        end
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

  `range` accepts `:start` (inclusive) and `:end` (exclusive) as `DateTime`s, on `opened_at`.
  Both are optional; with neither, the venue's whole fixed window up to now is returned. The
  bar still forming is not returned unless `opts[:include_partial]` is `true`, and with it an
  absent `:end` applies no upper bound at all (an explicit `:end` is still exclusive).

  Refuses rather than truncating:

    * a non-nil `opts[:limit]` → `{:error, {:unsupported_option, :limit}}`
    * a bar not aligned to its width → `{:error, {:unaligned_candle, time}}` (unmeasured)
    * two bars with one timestamp → `{:error, {:duplicate_candle, opened_at}}` (unmeasured)
    * an open, high, low or close <= 0 → `{:error, {:non_positive_price, field, value}}`
    * an unknown width → `{:error, {:unsupported_timeframe, width}}`
    * a `:start` older than the window can reach → `{:error, {:range_unavailable, …}}`
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, opts) do
    with :ok <- validate_symbol(symbol),
         :ok <- validate_candle_opts(opts),
         do: fetch_candles(symbol, timeframe, range, opts)
  end

  defp fetch_candles(symbol, timeframe, range, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    # Found 2026-10-10 by reading the call sites: this echoed the caller's symbol string and
    # interpolated `native` raw, where `get_order_book/2` and `get_price/2` return the
    # canonical symbol and `segment/1` the path. Two spellings of one pair in one family.
    canonical = reported_symbol(symbol, native)

    with {:ok, path, time_frame} <- candles_path(native, timeframe),
         :ok <- range_within_window(timeframe, range),
         {:ok, body} <- get_symbol_body("#{path}/#{segment(native)}/#{time_frame}", opts),
         {:ok, rows} <- list(body),
         {:ok, candles} <- rows_to_candles(rows, canonical, timeframe) do
      {:ok, select_candles(candles, timeframe, range, opts)}
    end
  end

  @doc """
  Whether `opts` holds options `get_historical_prices/4` can honour, checked without sending
  anything.

  `/v2/candles` takes no `limit` (it serves a fixed window), so a non-nil `:limit` is
  `{:error, {:unsupported_option, :limit}}` rather than accepted and ignored. `:include_partial`
  must be a boolean (`{:error, {:invalid_option, :include_partial, value}}`); `true` keeps the
  bar still forming, which may change on the next call. Exposed so `DpExchange.Gemini.Fake`
  refuses with this function.
  """
  @spec validate_candle_opts(keyword()) ::
          :ok | {:error, {:unsupported_option, :limit} | {:invalid_option, atom(), term()}}
  def validate_candle_opts(opts) do
    partial = Keyword.get(opts, :include_partial, false)

    cond do
      Keyword.get(opts, :limit) != nil -> {:error, {:unsupported_option, :limit}}
      not is_boolean(partial) -> {:error, {:invalid_option, :include_partial, partial}}
      true -> :ok
    end
  end

  @doc """
  Whether `symbol` is a non-blank string, checked without sending anything.

  A `nil`, atom or integer symbol raised `FunctionClauseError` in
  `SymbolFormat.to_exchange_symbol/1`, and `""` sent `GET /v1/pubticker/` with an empty path
  segment. Both are `{:error, {:invalid_symbol, symbol}}` now, decided locally before any
  request. Exposed so `DpExchange.Gemini.Fake` refuses with this function.
  """
  @spec validate_symbol(term()) :: :ok | {:error, {:invalid_symbol, term()}}
  def validate_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: :ok
  end

  def validate_symbol(other), do: {:error, {:invalid_symbol, other}}

  @doc """
  Whether `range` is a keyword list whose `:start` and `:end`, where present, are
  `DateTime`s, checked without sending anything.

  A non-list range raised in `Keyword.get/3`. A non-keyword-list is
  `{:error, {:invalid_range, range}}`, and so is a bound that is not a `DateTime` (the
  family shape; it used to be `{:invalid_range, :start | :end, value}`, which a consumer
  matching the family shape never saw). Exposed so `DpExchange.Gemini.Fake` refuses with
  this function.
  """
  @spec validate_range(term()) :: :ok | {:error, {:invalid_range, term()}}
  def validate_range(range) do
    if is_list(range) and Keyword.keyword?(range) and
         Enum.all?([:start, :end], &range_bound?(Keyword.get(range, &1))) do
      :ok
    else
      {:error, {:invalid_range, range}}
    end
  end

  @doc """
  Whether a spot candle request for `timeframe` and `range` is one the venue's fixed window
  can answer, checked without sending it.

  The width first (`{:error, {:unsupported_timeframe, timeframe}}`), then the range's bounds
  (`{:error, {:invalid_range, range}}`), then the window itself
  (`{:error, {:range_unavailable, timeframe, earliest: _, requested: _}}`) — the refusals
  `get_historical_prices/4` makes before it reaches the network, in that order. Exposed so
  `DpExchange.Gemini.Fake` refuses with this exact function rather than a second copy of the
  window arithmetic, which is how its boundary once sat a bar away from the real one.
  """
  @spec validate_history(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_history(timeframe, range) do
    with {:ok, _time_frame} <- time_frame(timeframe), do: range_within_window(timeframe, range)
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
  spot pairs, but this is the spot catalogue (perpetuals have their own endpoints), and a
  perpetual has no canonical `BASE-QUOTE` form — emitting one would invent a spot pair
  that does not exist.

  **Closed symbols are included**: `/v1/symbols` keeps them, and nothing here says which
  pairs trade (issue #4). For status, use `list_instruments/1`.
  """
  @spec get_symbols(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_symbols(opts) do
    with {:ok, body} <- get_body("/v1/symbols", opts),
         {:ok, symbols} <- list(body),
         :ok <- all_symbol_text(symbols) do
      {:ok,
       symbols
       |> Enum.reject(&SymbolFormat.perpetual?/1)
       |> Enum.map(&SymbolFormat.to_canonical_symbol/1)
       |> Enum.sort()}
    end
  end

  # `/v1/symbols` is documented as an array of strings. An entry that is not one (`null`, a
  # number, an object) used to be dropped, so the catalogue came back with a silent hole in
  # it — a pair the venue lists that no caller could then see. One unreadable entry refuses
  # the whole listing instead.
  defp all_symbol_text(symbols) do
    if Enum.all?(symbols, &is_binary/1), do: :ok, else: {:error, :unexpected_response_shape}
  end

  @doc """
  Every pair with its last price and 24-hour change, in one call.

  `/v1/pricefeed` is the only endpoint here that describes the whole catalogue at once,
  which is what makes an overview affordable — the alternative is one request per symbol
  across 346 symbols, which is not an overview, it is a rate-limit incident.

  **`change_24h` is the venue's `percentChange24h`, unchanged, and its unit is not established
  here.** The vendor's own example reads as a percent (`"5.23"` for BTCUSD,
  `docs/reference/gemini/openapi/rest.yaml`) while this package's fixtures carry fractions
  (`"-0.0424"`), and nothing in this repository measured the endpoint to say which is true.
  Do not scale it; check one value against a chart before relying on it. A pair whose `price`
  or `percentChange24h` is absent has `nil` for that field.
  """
  @spec get_market_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def get_market_overview(opts) do
    with {:ok, body} <- get_body("/v1/pricefeed", opts),
         {:ok, rows} <- list(body) do
      Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
        case overview_entry(row) do
          {:ok, pair, entry} -> {:cont, {:ok, Map.put(acc, pair, entry)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  # **A row that cannot be identified refuses the overview.** A row with no string `pair`
  # (not an object, no `pair`, `pair` a number or `null`) used to be skipped, so the overview
  # came back looking complete with a pair the venue priced missing from it.
  defp overview_entry(%{"pair" => pair} = row) when is_binary(pair) do
    with {:ok, price} <- stated_overview_price(row),
         {:ok, change} <- stated_or_absent(row, "percentChange24h") do
      {:ok, SymbolFormat.to_canonical_symbol(pair), %{price: price, change_24h: change}}
    end
  end

  defp overview_entry(_unidentifiable), do: {:error, :unexpected_response_shape}

  # A field the venue left out (or sent as `null`) is unstated and stays `nil`. One it SENT
  # and this package cannot read — a bad string, NaN, an absurd exponent, a boolean, an
  # object — is not "unstated": it is a malformed reply, and a map entry with a `nil` price
  # standing in for it would read as a symbol the venue has no price for.
  defp stated_or_absent(body, key), do: stated_decimal(Map.get(body, key))

  # A negative last price is not a price; carried into the overview it read as the pair's. Zero
  # is NOT refused here: the venue lists pairs that have not traded, and one such row would
  # refuse the whole catalogue overview. Absent stays `nil`.
  defp stated_overview_price(row) do
    with {:ok, price} <- stated_or_absent(row, "price") do
      if price && Decimal.compare(price, 0) == :lt,
        do: {:error, :unexpected_response_shape},
        else: {:ok, price}
    end
  end

  defp stated_decimal(nil), do: {:ok, nil}

  defp stated_decimal(value) do
    case decimal(value) do
      nil -> {:error, :unexpected_response_shape}
      parsed -> {:ok, parsed}
    end
  end

  # A symbol the venue echoes back: text, or absent (the caller's own is then the one named).
  # A number or an object in `symbol` went onto the struct as it came.
  # Text where the contract types a string; absent is `nil`, and any other present value is
  # unreadable rather than carried into a string field.
  defp stated_text(nil), do: {:ok, nil}
  defp stated_text(text) when is_binary(text), do: {:ok, text}
  defp stated_text(_unreadable), do: {:error, :unexpected_response_shape}

  defp echoed_symbol(%{"symbol" => symbol}, _asked) when is_binary(symbol) and symbol != "",
    do: {:ok, symbol}

  defp echoed_symbol(%{"symbol" => nil}, asked), do: {:ok, asked}
  defp echoed_symbol(%{"symbol" => _unreadable}, _asked), do: {:error, :unexpected_response_shape}
  defp echoed_symbol(_absent, asked), do: {:ok, asked}

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
    with :ok <- validate_symbol(symbol),
         native = SymbolFormat.to_exchange_symbol(symbol),
         {:ok, raw} <- get_symbol_body("/v1/symbols/details/#{segment(native)}", opts),
         {:ok, body} <- object(raw),
         {:ok, price_increment} <- stated_increment(body, "quote_increment"),
         {:ok, quantity_increment} <- stated_increment(body, "tick_size"),
         {:ok, min_quantity} <- stated_minimum(body, "min_order_size"),
         {:ok, status} <- stated_status(body) do
      {:ok,
       %{
         price_increment: price_increment,
         quantity_increment: quantity_increment,
         min_quantity: min_quantity,
         status: status
       }}
    end
  end

  # An increment is a step a price or size is a multiple of: zero or less is no step, and a
  # consumer rounding to it divides by it. A minimum is zero or more.
  defp stated_increment(body, key) do
    with {:ok, value} <- stated_or_absent(body, key) do
      if value && Decimal.compare(value, 0) != :gt,
        do: {:error, :unexpected_response_shape},
        else: {:ok, value}
    end
  end

  defp stated_minimum(body, key) do
    with {:ok, value} <- stated_or_absent(body, key) do
      if value && Decimal.compare(value, 0) == :lt,
        do: {:error, :unexpected_response_shape},
        else: {:ok, value}
    end
  end

  # `status` is a string where the venue states one; any other present value is unreadable.
  defp stated_status(%{"status" => status}) when is_binary(status), do: {:ok, status}
  defp stated_status(%{"status" => nil}), do: {:ok, nil}
  defp stated_status(%{"status" => _unreadable}), do: {:error, :unexpected_response_shape}
  defp stated_status(_absent), do: {:ok, nil}

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
    case requested_instrument_symbols(Keyword.get(opts, :symbols)) do
      {:ok, nil} -> get_symbols(opts)
      other -> other
    end
  end

  @doc """
  The symbols `list_instruments/1` was asked to detail — `{:ok, nil}` when `:symbols` was
  not given (meaning every listed non-perpetual symbol), otherwise the canonical spellings,
  each once.

  **Deduplicated by canonical spelling, not by what the caller typed.** `["BTC-USD",
  "btcusd"]` is one pair, and de-duplicating the raw strings detailed it twice — two
  requests spent against the public budget and two identical instruments returned.

  Anything that is not a list of strings was a `CaseClauseError` or a `FunctionClauseError`
  in the caller (`symbols: "BTC-USD"` reads as one symbol to a person); it is
  `{:error, {:invalid_option, :symbols, value}}`. Exposed so `DpExchange.Gemini.Fake` refuses
  with this function rather than a second copy of the rule.
  """
  @spec requested_instrument_symbols(term()) ::
          {:ok, [String.t()] | nil} | {:error, {:invalid_option, :symbols, term()}}
  def requested_instrument_symbols(nil), do: {:ok, nil}

  def requested_instrument_symbols(symbols) when is_list(symbols) do
    if Enum.all?(symbols, &(validate_symbol(&1) == :ok)) do
      {:ok, symbols |> Enum.map(&canonical_symbol/1) |> Enum.uniq()}
    else
      {:error, {:invalid_option, :symbols, symbols}}
    end
  end

  def requested_instrument_symbols(other), do: {:error, {:invalid_option, :symbols, other}}

  defp canonical_symbol(symbol) do
    symbol |> SymbolFormat.to_exchange_symbol() |> SymbolFormat.to_canonical_symbol()
  end

  defp instrument(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)

    with {:ok, raw} <- get_symbol_body("/v1/symbols/details/#{segment(native)}", opts),
         {:ok, body} <- object(raw),
         # Text or absent: a number or an object in a currency code went onto the instrument.
         {:ok, base} <- stated_text(body["base_currency"]),
         {:ok, quote_currency} <- stated_text(body["quote_currency"]) do
      {:ok,
       DpExchange.Core.Instrument.new(
         symbol: SymbolFormat.to_canonical_symbol(native),
         base: base,
         quote: quote_currency,
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
  is 50" verbatim — rather than to a plausible-looking guess. It is a whole number of levels
  per side, `0` included; anything else is `{:error, {:invalid_option, :depth, value}}`
  before a request is made (see `validate_book_opts/1`).
  """
  @spec get_order_book(String.t(), keyword()) ::
          {:ok, OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, opts) do
    # 50 is the venue's own documented default for both limit_bids and limit_asks — see
    # this function's own @doc and docs/reference/gemini/order-book.md.
    depth = Config.opt(opts, :depth, 50)
    params = [limit_bids: depth, limit_asks: depth]

    with :ok <- validate_symbol(symbol),
         native = SymbolFormat.to_exchange_symbol(symbol),
         :ok <- validate_book_opts(opts),
         {:ok, body} <-
           get_symbol_body("/v1/book/#{segment(native)}", Keyword.put(opts, :params, params)),
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
  Whether `opts[:depth]` is a value `get_order_book/2` can send, checked without sending
  anything: a whole number of levels, `0` included (the vendor's prose: "May be 0 to return the
  full order book on this side"), or absent. Anything else is
  `{:error, {:invalid_option, :depth, value}}`.

  The value went into the query string as given, so `depth: "ten"` was a venue 400 read as a
  refusal, `depth: -1` asked the venue for a count it never describes, and a map raised in
  `URI.encode_query/1` in the caller's process. (The vendor's schema says `minimum: 1` beside
  its prose that `0` is allowed; which is true is unmeasured, and `0` is passed through rather
  than refused on a guess.) Exposed so `DpExchange.Gemini.Fake` refuses with this function.
  """
  @spec validate_book_opts(keyword()) :: :ok | {:error, {:invalid_option, :depth, term()}}
  def validate_book_opts(opts) do
    case Config.opt(opts, :depth, nil) do
      nil -> :ok
      depth when is_integer(depth) and depth >= 0 -> :ok
      other -> {:error, {:invalid_option, :depth, other}}
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
  precedence rather than one chosen here. `opts[:limit]` is the venue's `limit_trades`, at
  most 500 (the vendor: "Each request will show at most 500 records"); more is
  `{:error, {:invalid_option, :limit, value}}`.

  **A cursor read that fills its limit may have a hole.** With `:since` or `:since_tid` the
  venue returns the most recent `limit` trades after the cursor, not the oldest. A reply of
  exactly `limit` rows (the venue's default of 50 when none is given) cannot be told from a
  window that dropped the older rows, so it is `{:error, :history_truncated}`: narrow the
  cursor or raise the limit. UNMEASURED against the live venue beyond the vendor's text.

  Every print's price must be greater than zero; one that is not refuses the reply
  (`{:error, {:non_positive_price, :price, value}}`).

  **This endpoint reaches seven calendar days**, and 90 days with a timestamp; the venue
  states both. A caller asking for more gets what the venue serves, which is why the window
  is worth knowing rather than discovering from a short list.
  """
  @spec get_trades(String.t(), keyword()) ::
          {:ok, [Trade.t()]} | {:error, term()} | {:refused, term()}
  def get_trades(symbol, opts) do
    with :ok <- validate_symbol(symbol),
         :ok <- validate_trade_opts(opts),
         do: fetch_trades(symbol, opts)
  end

  # `limit_trades`: at most 500 per request, and 50 when none is sent (rest.yaml, List Trades).
  @trades_limit_max 500
  @trades_limit_default 50

  @doc """
  Whether `opts[:since]`, `opts[:since_tid]` and `opts[:limit]` are values `get_trades/2` can
  send, checked without sending anything.

  `:since` is a `DateTime` or a non-negative integer (the venue takes seconds or
  milliseconds), `:since_tid` a non-negative integer and `:limit` a positive integer of at
  most 500 (the vendor's per-request maximum); absent
  or `nil` is fine for all three. Anything else is `{:error, {:invalid_option, key, value}}`.
  These used to reach the venue as whatever the caller wrote (`limit: "ten"` became a 400,
  `since: ~D[...]` raised in `URI.encode_query/1`). A `limit` of `0` is refused because the
  venue documents a minimum of 0 and says nothing about what 0 returns. Exposed so
  `DpExchange.Gemini.Fake` refuses exactly as this does.
  """
  @spec validate_trade_opts(keyword()) :: :ok | {:error, {:invalid_option, atom(), term()}}
  def validate_trade_opts(opts) do
    checks = [
      since: &(is_nil(&1) or is_struct(&1, DateTime) or non_negative?(&1)),
      since_tid: &(is_nil(&1) or non_negative?(&1)),
      limit: &(is_nil(&1) or (is_integer(&1) and &1 > 0 and &1 <= @trades_limit_max))
    ]

    case Enum.find(checks, fn {key, ok?} -> not ok?.(Keyword.get(opts, key)) end) do
      nil -> :ok
      {key, _ok?} -> {:error, {:invalid_option, key, Keyword.get(opts, key)}}
    end
  end

  defp non_negative?(value), do: is_integer(value) and value >= 0

  @doc false
  # A cursor read (`:since` or `:since_tid`) that fills its limit may have dropped the older
  # rows, since the venue answers the MOST RECENT `limit` after the cursor. `count` is the
  # rows the venue answered. Shared with `DpExchange.Gemini.Fake`.
  @spec check_trade_window(non_neg_integer(), keyword()) :: :ok | {:error, :history_truncated}
  def check_trade_window(count, opts) do
    cursor? = Keyword.get(opts, :since) != nil or Keyword.get(opts, :since_tid) != nil
    limit = Keyword.get(opts, :limit) || @trades_limit_default

    if cursor? and count >= limit, do: {:error, :history_truncated}, else: :ok
  end

  defp fetch_trades(symbol, opts) do
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
           trades_body("/v1/trades/#{segment(native)}", Keyword.put(opts, :params, params)),
         {:ok, rows} <- list(rows),
         :ok <- check_trade_window(length(rows), opts) do
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
         {:ok, price} <- required_price(Map.get(row, "price"), :price),
         {:ok, quantity} <- required_quantity(Map.get(row, "amount"), :quantity),
         {:ok, broken} <- broken_flag(Map.get(row, "broken")) do
      {:ok,
       %Trade{
         id: row |> Map.get("tid") |> to_string_or_nil(),
         symbol: symbol,
         # The taker's side. See the note on get_trades/2.
         side: trade_side(Map.get(row, "type")),
         price: price,
         quantity: quantity,
         timestamp: timestamp,
         broken: broken,
         provider: :gemini
       }}
    end
  end

  # **`broken` is a JSON boolean or absent; anything else refuses the print.** It was read as
  # `Map.get(row, "broken", false) == true`, so `"true"`, `1` or `"yes"` counted as NOT broken:
  # a busted trade, which did not stand, passed `reject_broken/2` and sat in the tape as an
  # ordinary print. A flag this package cannot read is not the venue saying the trade stood.
  defp broken_flag(flag) when flag in [nil, false], do: {:ok, false}
  defp broken_flag(true), do: {:ok, true}
  defp broken_flag(other), do: {:error, {:invalid_broken_flag, other}}

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
    assets
    |> Enum.reduce_while({:ok, []}, fn
      {asset, %{} = row}, {:ok, acc} ->
        case staking_rate(asset, provider_id, row) do
          {:ok, rate} -> {:cont, {:ok, [rate | acc]}}
          error -> {:halt, error}
        end

      {_asset, _not_an_object}, _acc ->
        {:halt, {:error, :unexpected_response_shape}}
    end)
    |> case do
      {:ok, rates} -> {:ok, Enum.reverse(rates)}
      error -> error
    end
  end

  defp rates_for_provider(_provider_id, _other), do: {:error, :unexpected_response_shape}

  # A figure absent or `null` is `nil` (the vendor marks every one optional); one the venue
  # SENT and this package cannot read refuses the reply, because `nil` says "not published".
  defp staking_rate(asset, provider_id, row) do
    with {:ok, rate_pct} <- rate_pct(row),
         {:ok, apy_pct} <- stated_or_absent(row, "apyPct"),
         {:ok, limit} <- stated_or_absent(row, "depositUsdLimit") do
      {:ok,
       %StakingRate{
         asset: String.upcase(asset),
         provider_id: provider_id,
         rate_pct: rate_pct,
         apy_pct: apy_pct,
         deposit_limit_usd: limit,
         venue_time: nil,
         provider: :gemini
       }}
    end
  end

  # `ratePct` where the venue publishes it; otherwise `rate`, which is basis points, divided
  # by a hundred. Never `apyPct`, which is a different number for the same position.
  defp rate_pct(row) do
    case stated_or_absent(row, "ratePct") do
      {:ok, nil} -> basis_points_pct(row)
      other -> other
    end
  end

  defp basis_points_pct(row) do
    case stated_or_absent(row, "rate") do
      {:ok, nil} -> {:ok, nil}
      {:ok, bps} -> {:ok, Decimal.div(bps, Decimal.new(100))}
      error -> error
    end
  end

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
    with :ok <- validate_symbol(symbol),
         {:ok, raw} <- get_symbol_body("/v1/fundingamount/#{segment(symbol)}", opts),
         {:ok, body} <- object(raw),
         {:ok, echoed} <- echoed_symbol(body, symbol),
         # A figure the venue SENT and this package cannot read refuses the reply: `nil` is
         # "the venue stated none", and a funding amount of `nil` reads as nothing to pay.
         {:ok, amount} <- stated_decimal(body["amount"] || body["fundingAmount"]),
         {:ok, estimated} <- stated_or_absent(body, "estimatedFundingAmount"),
         {:ok, funded_at} <- stated_epoch(body, "fundingTimestampMilliSecs"),
         {:ok, next_funding_at} <- stated_epoch(body, "nextFundingTimestamp") do
      {:ok,
       %Funding{
         symbol: echoed,
         amount: amount,
         estimated_amount: estimated,
         funded_at: funded_at,
         next_funding_at: next_funding_at,
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
    with :ok <- validate_symbol(symbol),
         {:ok, body} <- get_symbol_body("/v1/nextfundingtimestamp/#{segment(symbol)}", opts) do
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
    with :ok <- validate_symbol(symbol),
         {:ok, raw} <- get_symbol_body("/v1/riskstats/#{segment(symbol)}", opts),
         {:ok, body} <- object(raw),
         {:ok, echoed} <- echoed_symbol(body, symbol),
         {:ok, product_type} <- stated_text(body["product_type"]),
         {:ok, mark} <- stated_or_absent(body, "mark_price"),
         {:ok, index} <- stated_or_absent(body, "index_price"),
         {:ok, interest} <- stated_or_absent(body, "open_interest"),
         {:ok, notional} <- stated_or_absent(body, "open_interest_notional") do
      {:ok,
       %ContractStats{
         symbol: echoed,
         product_type: product_type,
         mark_price: mark,
         index_price: index,
         open_interest: interest,
         open_interest_notional: notional,
         venue_time: nil,
         provider: :gemini
       }}
    end
  end

  # A time absent or `null` is `nil`; one the venue SENT that is not a positive, in-range epoch
  # in milliseconds refuses the reply rather than reading as "no funding time".
  defp stated_epoch(body, key) do
    case Map.get(body, key) do
      nil ->
        {:ok, nil}

      value ->
        case epoch_ms(value) do
          nil -> {:error, :unexpected_response_shape}
          at -> {:ok, at}
        end
    end
  end

  # Positive and in range, or `nil`. Zero and negatives are valid Unix times and would date a
  # funding event to 1970 — the same substitution `Private`'s `epoch_ms/1` refuses.
  defp epoch_ms(value) when is_integer(value) and value > 0 do
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
    with {:ok, body, _headers} <- get_with_headers(path, opts, :collection), do: {:ok, body}
  end

  # A read scoped to one symbol: the venue's "not listed" answers are read into the family
  # reason `:not_listed` (see `symbol_refusal/2`), with no venue text in the reason.
  defp get_symbol_body(path, opts) do
    with {:ok, body, _headers} <- get_with_headers(path, opts, :symbol), do: {:ok, body}
  end

  # `GET /v1/trades/{symbol}` refuses an unlisted symbol with `{"reason":"BadRequest"}`
  # (measured live 2026-09-06). Its parameters are validated locally before the request, so
  # on this route the word names the symbol.
  defp trades_body(path, opts) do
    case get_symbol_body(path, opts) do
      {:refused, {:unknown_reason, "BadRequest"}} -> {:refused, :not_listed}
      other -> other
    end
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
  defp get_with_headers(path, opts, scope) do
    url = base_url(opts) <> path <> query(opts)

    case HttpClient.request(:get, url, [], nil, request_opts(opts)) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        with {:ok, decoded} <- decoded_body(body), do: {:ok, decoded, headers}

      {:ok, %{status: status, body: body}} when status in [400, 404] ->
        {:refused, refusal(scope, status, body)}

      # Quoted bounded, as Core and `Private` do: a CDN error page is not an error message.
      {:ok, %{status: status, body: body}} ->
        message = "HTTP #{status}: #{inspect(body, limit: 50, printable_limit: 2_048)}"
        {:error, {:exchange_error, :gemini, message}}

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
    |> Keyword.merge(provider: :gemini, raw_status: true, decode_body: false)
  end

  # `decode_body: false` (request_opts/1) hands this module the venue's BYTES, decoded here
  # with `floats: :decimals`. Gemini types money fields as JSON numbers on public routes too
  # (`/v1/symbols/details` `tick_size` and `quote_increment`, `/v1/fundingamount`'s
  # `fundingAmount`, the `/v2/candles` rows), and Req's own decoder turns each into a float
  # that holds at most 17 significant digits. A fractional number is a `Decimal` here and an
  # integer stays an integer; every reader below goes through `decimal/1`, which accepts
  # both. Core before 0.3.65 drops the option, so the dependency floor is 0.3.65.
  #
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
  #
  # **The body is always bytes.** A pass-through clause for an already-decoded body stood
  # below this one and could not run (tick AA coverage sweep, 2026-10-13): Core streams every
  # response through `into: capped_into/1`, which appends binaries (a `:plug` included), and
  # `request_opts/1` forwards no transport that could skip it. It was removed because it was
  # also the only way a float could reach `decimal/1` or `candle_time/1`, whose float clauses
  # went with it.
  defp decoded_body(body) when is_binary(body) do
    case Jason.decode(body, floats: :decimals) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:undecodable_response, :gemini}}
    end
  end

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
  defp refusal(:collection, _status, body), do: refusal_reason(body)
  defp refusal(:symbol, status, body), do: status |> symbol_refusal(refusal_reason(body))

  # ## A symbol-scoped read answers in the family's reasons, never the venue's text
  #
  #   * `{:refused, :not_listed}` — the venue does not list the symbol: a JSON `InvalidSymbol`
  #     (already `:not_listed` after `classify/2`), the plain-text `Supplied value 'X' is not a
  #     valid symbol` of `/v2/candles`, or an empty 404 (`/v1/fundingamount`).
  #     Also `'X' does not have available data yet`, the plain-text 404 of `/v1/pubticker`:
  #     measured live 2026-09-06 for a symbol that does not exist (`nonexistentsymbolxyz`),
  #     so what was measured is an unlisted symbol. The design first read it as
  #     `:no_quote`; the measurement wins. No listed-but-unquoted answer has been observed
  #     on this venue, so `:no_quote` is never returned here.
  #
  # The venue's wording is not stable across venues, so it does not ride in the reason.
  defp symbol_refusal(404, :refused), do: :not_listed
  defp symbol_refusal(_status, {:unknown_reason, text}), do: unknown_symbol_text(text)
  defp symbol_refusal(_status, reason), do: reason

  defp unknown_symbol_text(text) do
    cond do
      String.contains?(text, "does not have available data yet") -> :not_listed
      String.contains?(text, "is not a valid symbol") -> :not_listed
      true -> {:unknown_reason, text}
    end
  end

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
  @doc """
  Classifies a venue refusal body (a decoded JSON map, or plain text) into a reason.

  A recognised category is an atom, or `{atom, message}` when the venue also sent a message;
  a word nothing here recognises is `{:unknown_reason, text}` with the text bounded; a body
  with no readable reason is `:refused`.
  """
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
            {:unknown_reason, bounded_text(trimmed)}
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
      # The family reason carries no venue text (D1): `InvalidSymbol` is `:not_listed`.
      {:ok, :not_listed} -> :not_listed
      {:ok, known} when is_binary(message) -> {known, message}
      {:ok, known} -> known
      :error -> {:unknown_reason, bounded_text(reason)}
    end
  end

  # Only a non-empty binary counts. An absent, null or blank `message` becomes `nil`, so a
  # caller can test one thing — "did the venue say more?" — instead of also guarding "" .
  defp message_from(%{"message" => message}) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> bounded_text(trimmed)
    end
  end

  defp message_from(_no_message), do: nil

  # **The venue's words are quoted bounded.** A 4xx body reaches `refusal_reason/1` whole
  # (Core's default cap is 16 MiB), and a CDN or proxy error page answers a 400 or 404 as
  # readily as Gemini's own one-line JSON does. Kept whole, the page became the payload of
  # `{:unknown_reason, text}` and from there went into every caller's log, the hole
  # `status_error/2` and Core already close for the other statuses. Text inside the bound is
  # returned byte-identical, so a real Gemini reason or message is unchanged.
  @refusal_text_max 2_048

  defp bounded_text(text) when byte_size(text) <= @refusal_text_max, do: text

  defp bounded_text(text) do
    text
    |> binary_part(0, @refusal_text_max)
    |> drop_partial_codepoint(3)
    |> Kernel.<>("... [truncated]")
  end

  # The cut may land inside a multi-byte character; at most three bytes of it are dropped.
  defp drop_partial_codepoint(text, 0), do: text

  defp drop_partial_codepoint(text, left) do
    if String.valid?(text),
      do: text,
      else: drop_partial_codepoint(binary_part(text, 0, byte_size(text) - 1), left - 1)
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

  #
  # **A price listed twice on one side is not a book either.** The snapshot's levels are
  # absolute, one size per price: two rows at one price leave no way to say which size rests
  # there, and both were carried into the book as separate levels, every value real. `1.0`
  # and `1.00` are one price. Refused with the other unreadable shapes.
  defp readable_book_side(rows) when is_list(rows) do
    if Enum.all?(rows, &readable_book_row?/1) and distinct_book_prices?(rows),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  defp distinct_book_prices?(rows) do
    prices = Enum.map(rows, fn row -> row["price"] |> decimal() |> Decimal.normalize() end)
    length(prices) == length(Enum.uniq(prices))
  end

  # A level is a price above zero and a size of zero or more. A price of `0` or `-5` sorted into
  # the book and sat there as a level, and a negative amount carried through as a real size.
  defp readable_book_row?(%{"price" => price, "amount" => amount}),
    do: book_price?(decimal(price)) and book_size?(decimal(amount))

  defp readable_book_row?(_row), do: false

  defp book_price?(nil), do: false
  defp book_price?(%Decimal{} = value), do: Decimal.compare(value, 0) == :gt

  defp book_size?(nil), do: false
  defp book_size?(%Decimal{} = value), do: Decimal.compare(value, 0) != :lt

  defp levels(nil, _direction), do: []

  # Sorted. `Core.Types.OrderBook` makes the ordering part of the contract, and
  # `@type level :: {Decimal.t(), Decimal.t()}` has no nil in it, so `hd(bids)` must be able
  # to answer "the best bid" with a real number.
  #
  # Every row reaching here is a map whose price and amount both read: `get_order_book/2`
  # runs `readable_book_side/1` on both sides first and refuses the whole reply otherwise.
  # This used to drop a non-map row or an unreadable price itself and keep a nil amount; with
  # the all-or-error check in front, those branches could no longer run (tick AA coverage
  # sweep, 2026-10-13) and were removed rather than left to suggest a second, lenient rule.
  #
  # `{direction, Decimal}` rather than term order, because `Decimal` structs do not compare
  # correctly as plain terms.
  defp levels(rows, direction) when is_list(rows) do
    rows
    |> Enum.map(fn row -> {decimal(row["price"]), decimal(row["amount"])} end)
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
  # `range` afterward, so a caller reaching before the venue's reply gets the bars the reply
  # holds, from wherever it begins, without this pre-flight refusal naming the boundary.
  # A `:start` or `:end` that is not a `DateTime` is refused here. It reached
  # `DateTime.compare/2` in the row filter and raised in the caller's process.
  defp range_within_window(timeframe, range) do
    with :ok <- validate_range(range), do: window_check(timeframe, range)
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
         {:ok, open} <- required_price(open, :open),
         {:ok, high} <- required_price(high, :high),
         {:ok, low} <- required_price(low, :low),
         {:ok, close} <- required_price(close, :close),
         :ok <- consistent_range(low, high, opened_at),
         {:ok, volume} <- candle_volume(volume),
         :ok <- aligned_candle(opened_at, time_ms, timeframe) do
      {:ok,
       %Candle{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: opened_at,
         open: open,
         high: high,
         low: low,
         close: close,
         volume: volume,
         provider: :gemini
       }}
    end
  end

  # A row that is not six elements. This used to have no such clause, so the venue sending a
  # seventh field — or one fewer — raised `FunctionClauseError` out of a `GenServer`'s own
  # fetch rather than returning an error the caller could act on.
  defp row_to_candle(_row, _symbol, _timeframe), do: {:error, :unexpected_response_shape}

  # A bar whose low is above its high is not a bar. Every price in it parses and is positive,
  # which is why nothing else refused it; a consumer computing a range from it gets a negative.
  defp consistent_range(low, high, opened_at) do
    if Decimal.compare(low, high) == :gt,
      do: {:error, {:inconsistent_candle, opened_at}},
      else: :ok
  end

  # `volume` is not an enforced key, so an ABSENT one is `nil`. One the venue SENT and this
  # package cannot read (a string, NaN, an absurd exponent) or that is negative is a malformed
  # row: `nil` would say the venue stated none, and a negative would sum into a series.
  defp candle_volume(nil), do: {:ok, nil}

  defp candle_volume(value) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, :volume, value}}
      parsed -> non_negative_volume(parsed, value)
    end
  end

  defp non_negative_volume(parsed, raw) do
    if Decimal.compare(parsed, 0) == :lt,
      do: {:error, {:negative_volume, raw}},
      else: {:ok, parsed}
  end

  # One unreadable row refuses the whole series rather than leaving a gap in it. A candle
  # list with a bar silently missing reads as "the venue published nothing for that minute",
  # which a consumer will treat as a real gap in the market rather than as a decode failure.
  #
  # Two bars with the same `opened_at` in one reply refuse it too (family rule MD3): the
  # vendor's own example repeats a timestamp, and which of the two is the bar is not
  # something this package can know. UNMEASURED against the live venue.
  defp rows_to_candles(rows, symbol, timeframe) do
    rows
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn row, {:ok, acc, seen} ->
      with {:ok, candle} <- row_to_candle(row, symbol, timeframe),
           :ok <- unseen_candle(candle, seen) do
        {:cont, {:ok, [candle | acc], MapSet.put(seen, candle.opened_at)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, candles, _seen} -> {:ok, Enum.reverse(candles)}
      error -> error
    end
  end

  defp unseen_candle(candle, seen) do
    if MapSet.member?(seen, candle.opened_at),
      do: {:error, {:duplicate_candle, candle.opened_at}},
      else: :ok
  end

  # A bar's time is not provably its open time (the vendor does not say), so one that is not
  # on a width boundary is refused with the venue's value as given. `Timeframe.aligned?/2`
  # answers `true` for the widths it has no rule for (`1w`, `1M`), which stay unchecked.
  defp aligned_candle(opened_at, time, timeframe) do
    if Timeframe.aligned?(opened_at, timeframe),
      do: :ok,
      else: {:error, {:unaligned_candle, time}}
  end

  defp candle_time(value) when is_integer(value), do: from_unix_ms(value)

  # `floats: :decimals` (see `decoded_body/1`) turns a fractional JSON number into a
  # `Decimal`, truncated here to whole milliseconds. No float ever reaches this function: the
  # body is always bytes decoded that way, so the float clause that stood above this one
  # could not run and was removed (tick AA coverage sweep, 2026-10-13). A float would now
  # fall to the last clause and be refused as unparseable, never raise.
  # The exponent is bounded BEFORE any arithmetic: `Decimal` aligns exponents to round or
  # compare, so `1E999999999` would try to build an integer of a billion digits. A real
  # epoch has an exponent of 0, a handful of negative places, or a short mantissa like `1.7E12`.
  defp candle_time(%Decimal{exp: exp} = value) when exp in -30..18 do
    value |> Decimal.round(0, :down) |> Decimal.to_integer() |> from_unix_ms()
  end

  defp candle_time(%Decimal{} = value), do: {:error, {:unparseable_venue_timestamp, value}}

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

  # A bar at or before the epoch is not a bar this venue traded: zero and negative do not
  # raise, they become 1970 and earlier, which `from_unix_or_undated/2` above already refuses
  # for a print. Candles took them as given. Refused with the value, like any unreadable time.
  defp from_unix_ms(milliseconds) when milliseconds <= 0,
    do: {:error, {:unparseable_venue_timestamp, milliseconds}}

  defp from_unix_ms(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, at} -> {:ok, at}
      {:error, _reason} -> {:error, {:unparseable_venue_timestamp, milliseconds}}
    end
  end

  # The one selection `get_historical_prices/4` applies, exposed so `DpExchange.Gemini.Fake`
  # keeps exactly the rows it would: the range (`within?/4`), then the bar still forming is
  # dropped unless `opts[:include_partial]` is `true`, then oldest first by `opened_at`.
  @doc false
  @spec select_candles([Candle.t()], String.t(), keyword(), keyword()) :: [Candle.t()]
  def select_candles(candles, timeframe, range, opts) do
    now = DateTime.utc_now()
    partial? = Keyword.get(opts, :include_partial, false) == true

    candles
    |> Enum.filter(&keep_candle?(&1, timeframe, range, now, partial?))
    |> Enum.sort_by(& &1.opened_at, DateTime)
  end

  defp keep_candle?(candle, timeframe, range, now, partial?),
    do:
      within?(candle, range, now, partial?) and
        (partial? or not in_progress?(candle, timeframe, now))

  # `:start` inclusive, `:end` exclusive, on `opened_at`. An absent `:end` is now, EXCEPT for a
  # caller who asked for partial bars: a bar just opened must not vanish because this clock
  # runs a little behind the venue's, so no upper bound is applied then.
  defp within?(candle, range, now, partial?) do
    after_start?(candle, Keyword.get(range, :start)) and
      before_end?(candle, Keyword.get(range, :end), now, partial?)
  end

  defp after_start?(_candle, nil), do: true
  defp after_start?(candle, start), do: DateTime.compare(candle.opened_at, start) != :lt

  defp before_end?(_candle, nil, _now, true), do: true
  defp before_end?(candle, nil, now, false), do: before_end?(candle, now)
  defp before_end?(candle, finish, _now, _partial?), do: before_end?(candle, finish)

  defp before_end?(candle, finish), do: DateTime.compare(candle.opened_at, finish) == :lt

  # A bar is in progress while `opened_at + width > now`. `1w` is seven days; `1M` is the
  # days of the month it opened in (neither has a `Timeframe.seconds/1` width).
  defp in_progress?(candle, timeframe, now) do
    DateTime.compare(DateTime.add(candle.opened_at, bar_seconds(candle, timeframe)), now) == :gt
  end

  defp bar_seconds(candle, timeframe) do
    case Timeframe.seconds(timeframe) do
      {:ok, width} -> width
      :error -> unmodelled_width(candle, timeframe)
    end
  end

  defp unmodelled_width(_candle, "1w"), do: 7 * 86_400

  defp unmodelled_width(candle, "1M"),
    do: Date.days_in_month(DateTime.to_date(candle.opened_at)) * 86_400

  # `/v1/pubticker` reports volume keyed by currency code, so the base asset's key has to
  # be recovered from the symbol rather than assumed to be first.
  #
  # Absent or `null` is `nil` ("not stated"); a `volume` that is not an object, or a base figure
  # the venue sent and this package cannot read, refuses the reply instead of reading as nil.
  defp base_volume(%{"volume" => volume}, native) when is_map(volume) do
    base =
      native
      |> SymbolFormat.to_canonical_symbol()
      |> String.split("-")
      |> List.first()

    stated_decimal(Map.get(volume, base))
  end

  defp base_volume(%{"volume" => nil}, _native), do: {:ok, nil}
  defp base_volume(%{"volume" => _unreadable}, _native), do: {:error, :unexpected_response_shape}
  defp base_volume(_body, _native), do: {:ok, nil}

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: bounded(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)

  # No float clause: every value read here comes from a body decoded with
  # `floats: :decimals` (`decoded_body/1`), which yields a `Decimal` or an integer and never a
  # float. The clause that stood here could not run and was removed (tick AA coverage sweep,
  # 2026-10-13); a float would fall to `decimal(_other)` and read as `nil`, never raise.

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
        bounded(parsed)

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

  # A finite `Decimal` whose exponent is one a price or size can have, or `nil`. `"1e999999999"`
  # parses, and `Decimal.compare/2` or `Decimal.add/2` against it aligns exponents by building
  # an integer of that many digits: one venue string stalls the caller's process. NaN and
  # Infinity carry no integer coefficient and are refused here too. Bodies are decoded with
  # `floats: :decimals`, so a JSON number reaches here as a `Decimal` with whatever exponent
  # the venue wrote.
  defp bounded(%Decimal{coef: coef, exp: exp} = value)
       when is_integer(coef) and exp >= -100 and exp <= 100,
       do: value

  defp bounded(_nan_infinite_or_unbounded), do: nil

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

  # A traded size of zero or less is not a print: nothing changed hands, and a negative one
  # carried through reads as a real quantity on the tape.
  defp required_quantity(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.compare(parsed, 0) == :gt,
        do: {:ok, parsed},
        else: {:error, {:non_positive_quantity, field, value}}
    end
  end

  # A traded price (a quote's `last`, a trade's price, a candle's open/high/low/close) of zero
  # or less is not a price (family rule MD6): it refuses the item or reply rather than being
  # passed through as a plausible value.
  defp required_price(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.compare(parsed, 0) == :gt,
        do: {:ok, parsed},
        else: {:error, {:non_positive_price, field, value}}
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
  #
  # `.` is unreserved, so `..` survived encoding and `/v1/book/..` is a dot-segment a proxy or
  # the venue's router may resolve to another endpoint. A segment that is only dots has its
  # dots encoded (`%2E`), which no normaliser treats as a dot-segment.
  defp segment(value) do
    value |> to_string() |> URI.encode(&URI.char_unreserved?/1) |> encode_dot_segment()
  end

  defp encode_dot_segment("."), do: "%2E"
  defp encode_dot_segment(".."), do: "%2E%2E"
  defp encode_dot_segment(segment), do: segment

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
