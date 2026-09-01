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

  So a range is honoured by **filtering here**, and a range the window cannot cover is an
  **error** rather than a short answer. Handing back 364 daily bars to a caller who asked
  for five years is the family's named failure mode in its quietest form: every value real,
  only the meaning wrong.

  ## Neither ticker carries a quote timestamp, so the venue's own clock is used

  `/v1/pubticker` returns a `timestamp`, but it is **inside the `volume` object** — it
  stamps the 24-hour volume window, updates about once a minute, and is not when the bid
  and ask were true. `/v2/ticker` carries no timestamp at all. Using either as the quote
  time would be a substitution of exactly the kind this family exists to stop, and the
  host adapter does something worse: `parse_timestamp(nil)` returns `DateTime.utc_now()`,
  so a quote with no venue time gets the *client's* clock and looks perfectly fresh.

  This package uses the HTTP `Date` **response header** — the venue's own statement of
  when it served the answer, which bounds the quote's age and is not our clock. When that
  header is absent the request fails with `{:error, :missing_venue_timestamp}` rather than
  returning a quote whose freshness cannot be stated.
  """

  alias DpExchange.Core.{HttpClient, Timeframe}
  alias DpExchange.Core.Types.{Candle, FxRate, OrderBook, Quote, TopOfBook, Trade}
  alias DpExchange.Gemini.{Environment, SymbolFormat}

  # Canonical width => the literal Gemini accepts. Measured 2026-08-28: the venue names
  # its own accepted set in the 400 body — `[1m, 5m, 15m, 30m, 1hr, 6hr, 1day]` — while
  # its documentation lists `1h`, `6h` and `1d`, none of which work. Three of the seven
  # documented values are rejected by the venue that documents them.
  @time_frames %{
    "1m" => "1m",
    "5m" => "5m",
    "15m" => "15m",
    "30m" => "30m",
    "1h" => "1hr",
    "6h" => "6hr",
    "1d" => "1day"
  }

  # Bars served per width, measured 2026-08-28 and identical to the host's independent
  # 2026-08-06 measurement on all seven. Used to refuse a range the window cannot cover.
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

    with {:ok, body, headers} <- get_with_headers("/v1/pubticker/#{native}", opts),
         {:ok, last} <- quoted_price(body),
         {:ok, timestamp} <- venue_time(headers) do
      {:ok,
       %Quote{
         symbol: SymbolFormat.to_canonical_symbol(native),
         price: decimal(last),
         volume: base_volume(body, native),
         timestamp: timestamp,
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

    with {:ok, body, headers} <- get_with_headers("/v1/pubticker/#{native}", opts) do
      {:ok,
       %TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bid: decimal(body["bid"]),
         ask: decimal(body["ask"]),
         bid_size: nil,
         ask_size: nil,
         venue_time: header_time_or_nil(headers),
         observed_at: DateTime.utc_now(),
         provider: :gemini
       }}
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

    with {:ok, path, time_frame} <- candles_path(native, timeframe),
         :ok <- range_within_window(timeframe, range),
         {:ok, rows} <- get_body("#{path}/#{native}/#{time_frame}", opts) do
      {:ok,
       rows
       |> Enum.map(&row_to_candle(&1, symbol, timeframe))
       |> Enum.filter(&within?(&1, range))
       |> Enum.sort_by(& &1.opened_at, DateTime)}
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
  """
  @spec get_symbols(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_symbols(opts) do
    with {:ok, symbols} <- get_body("/v1/symbols", opts) do
      {:ok,
       symbols
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
    with {:ok, rows} <- get_body("/v1/pricefeed", opts) do
      {:ok,
       Map.new(rows, fn row ->
         {SymbolFormat.to_canonical_symbol(row["pair"]),
          %{price: decimal(row["price"]), change_24h: decimal(row["percentChange24h"])}}
       end)}
    end
  end

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

    with {:ok, body} <- get_body("/v1/symbols/details/#{native}", opts) do
      {:ok,
       %{
         price_increment: decimal(body["quote_increment"]),
         quantity_increment: decimal(body["tick_size"]),
         min_quantity: decimal(body["min_order_size"]),
         status: body["status"]
       }}
    end
  end

  # --- order book ---------------------------------------------------------

  @doc """
  A price-level snapshot for one symbol.

  Each level carries the venue's own `timestamp`, so unlike a quote there is nothing to
  derive: the book's time is the newest level's time.
  """
  @spec get_order_book(String.t(), keyword()) ::
          {:ok, OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    depth = Keyword.get(opts, :depth, 50)
    params = [limit_bids: depth, limit_asks: depth]

    with {:ok, body} <- get_body("/v1/book/#{native}", Keyword.put(opts, :params, params)),
         {:ok, timestamp} <- book_time(body) do
      {:ok,
       %OrderBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bids: levels(body["bids"]),
         asks: levels(body["asks"]),
         timestamp: timestamp,
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

    params =
      []
      |> put_param(:timestamp, timestamp_ms(Keyword.get(opts, :since)))
      |> put_param(:since_tid, Keyword.get(opts, :since_tid))
      |> put_param(:limit_trades, Keyword.get(opts, :limit))
      |> put_param(:include_breaks, include_breaks(opts))

    with {:ok, rows} <- get_body("/v1/trades/#{native}", Keyword.put(opts, :params, params)) do
      rows
      |> List.wrap()
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case to_trade(row, symbol) do
          {:ok, trade} -> {:cont, {:ok, [trade | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, trades} -> {:ok, trades |> Enum.reverse() |> reject_broken(opts)}
        error -> error
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

  defp to_trade(row, symbol) do
    with {:ok, timestamp} <- trade_time(row) do
      {:ok,
       %Trade{
         id: row |> Map.get("tid") |> to_string(),
         symbol: symbol,
         # The taker's side. See the note on get_trades/2.
         side: trade_side(Map.get(row, "type")),
         price: decimal(Map.get(row, "price")),
         quantity: decimal(Map.get(row, "amount")),
         timestamp: timestamp,
         broken: Map.get(row, "broken", false) == true,
         provider: :gemini
       }}
    end
  end

  # Milliseconds where the venue sends them, seconds otherwise — the venue publishes both
  # fields and `timestampms` is the precise one.
  defp trade_time(%{"timestampms" => ms}) when is_integer(ms),
    do: {:ok, DateTime.from_unix!(ms, :millisecond)}

  defp trade_time(%{"timestamp" => seconds}) when is_integer(seconds),
    do: {:ok, DateTime.from_unix!(seconds)}

  # An undated print cannot be placed on a tape, and the local clock would place it wrongly
  # while looking right.
  defp trade_time(_row), do: {:error, :missing_venue_timestamp}

  defp trade_side("buy"), do: :buy
  defp trade_side("sell"), do: :sell
  defp trade_side(_other), do: nil

  # The pairs the venue serves, from its own documentation. **Enumerated rather than passed
  # through** because an unsupported pair returns a 404 the caller cannot distinguish from
  # a bad timestamp, and the list is short and stated.
  @fx_pairs ~w(AUDUSD CADUSD COPUSD EURUSD CHFUSD HKDUSD NZDUSD GBPUSD BRLUSD INRUSD
               SGDUSD KRWUSD JPYUSD CNYUSD)

  @doc """
  A foreign-exchange reference rate for `pair` at `at` — `/v2/fxrate/{symbol}/{timestamp}`.

  **This is not a rate the venue trades at.** Gemini's own documentation: *"Gemini does not
  offer foreign exchange services. This endpoint is for historical reference only and does
  not provide any guarantee of future exchange rates."* The number comes from a third party
  the venue names in `provider`, which this package carries as `Types.FxRate`'s `:source` —
  `:provider` stays `:gemini`, the venue relaying it.

  **Requires the Auditor role**, which the vendor states on the endpoint.

  Fourteen pairs are served and they are all `…USD`; a pair outside the list is refused here
  rather than sent, because the venue's 404 for an unsupported pair reads the same as one
  for a bad timestamp.

  `at` is the instant, sent as milliseconds.
  """
  @spec get_fx_rate(String.t(), DateTime.t(), keyword()) ::
          {:ok, FxRate.t()} | {:error, term()} | {:refused, term()}
  def get_fx_rate(pair, %DateTime{} = at, opts) do
    native = pair |> to_string() |> String.replace("-", "") |> String.upcase()

    with :ok <- fx_pair(native) do
      timestamp = DateTime.to_unix(at, :millisecond)

      with {:ok, body} <- get_body("/v2/fxrate/#{native}/#{timestamp}", opts) do
        to_fx_rate(body, native, at)
      end
    end
  end

  defp fx_pair(pair) when pair in @fx_pairs, do: :ok
  defp fx_pair(pair), do: {:error, {:unsupported_fx_pair, pair}}

  defp to_fx_rate(%{"rate" => rate} = body, native, requested_at) do
    {:ok,
     %FxRate{
       pair: body["fxPair"] || native,
       rate: decimal(rate),
       # The venue echoes the instant in `asOf`. Where it does, that is the authority —
       # the venue may answer for a nearby moment and its own word is what happened.
       as_of: as_of(body["asOf"], requested_at),
       # The institution that computed the rate. Named `provider` by the venue and carried
       # as `source` here, because `provider` in this contract means the venue.
       source: body["provider"],
       benchmark: body["benchmark"],
       provider: :gemini
     }}
  end

  defp to_fx_rate(_body, _native, _requested_at), do: {:error, :unexpected_response_shape}

  defp as_of(ms, _requested_at) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp as_of(_absent, requested_at), do: requested_at
  # --- internals ----------------------------------------------------------

  defp get_body(path, opts) do
    with {:ok, body, _headers} <- get_with_headers(path, opts), do: {:ok, body}
  end

  # Everything goes through `request/5` rather than `get/3`, for two reasons that both
  # come down to what `get/3` throws away: it drops the response headers, which is where
  # this venue's only usable quote timestamp lives, and it maps a 4xx to a message string,
  # which is where this venue states its refusal reason.
  defp get_with_headers(path, opts) do
    url = base_url(opts) <> path <> query(opts)

    case HttpClient.request(:get, url, [], nil, request_opts(opts)) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        {:ok, decode(body), headers}

      {:ok, %{status: 400, body: body}} ->
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
    case Keyword.get(opts, :params, []) do
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
  defp request_opts(opts) do
    opts
    |> Keyword.take([:limiter, :timeout, :retry_attempts, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :gemini, raw_status: true)
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode(body), do: body

  # A 400 from Gemini names its own reason, and the ones below are permanent for the
  # request as sent — no retry can make an unknown symbol known. That is a refusal, not
  # an error, and the distinction is the whole point of having two shapes.
  defp refusal(body) do
    case decode(body) do
      %{"reason" => reason} -> String.to_atom(Macro.underscore(reason))
      _other -> :refused
    end
  end

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
    with [_day, d, mon, y, time, _tz] <- String.split(value, [" ", ", "], trim: true),
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

  # `List.wrap/1` on each side rather than `bids ++ asks`: a venue that sends
  # `"asks": null` for an empty side crashed this with a FunctionClauseError from deep
  # inside `Enum.map`, reaching a caller as a crash rather than an answer. An absent side
  # is a book with no asks, not a malformed response. Found by a test, not in production.
  defp book_time(%{"bids" => bids, "asks" => asks}) do
    (List.wrap(bids) ++ List.wrap(asks))
    |> Enum.map(&Map.get(&1, "timestamp"))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_integer/1)
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> {:error, :missing_venue_timestamp}
      seconds -> DateTime.from_unix(seconds)
    end
  end

  defp book_time(_other), do: {:error, :missing_venue_timestamp}

  defp levels(nil), do: []

  defp levels(rows) do
    Enum.map(rows, fn row -> {decimal(row["price"]), decimal(row["amount"])} end)
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
  defp range_within_window(timeframe, range) do
    with %DateTime{} = start <- Keyword.get(range, :start),
         {:ok, bars} <- Map.fetch(@window_bars, timeframe),
         {:ok, width} <- Timeframe.seconds(timeframe) do
      earliest = DateTime.add(DateTime.utc_now(), -bars * width, :second)

      if DateTime.compare(start, earliest) == :lt do
        {:error, {:range_unavailable, timeframe, earliest: earliest, requested: start}}
      else
        :ok
      end
    else
      _no_start_or_unknown_width -> :ok
    end
  end

  defp row_to_candle([time_ms, open, high, low, close, volume], symbol, timeframe) do
    %Candle{
      symbol: symbol,
      timeframe: timeframe,
      opened_at: DateTime.from_unix!(to_integer(time_ms), :millisecond),
      open: decimal(open),
      high: decimal(high),
      low: decimal(low),
      close: decimal(close),
      volume: decimal(volume),
      provider: :gemini
    }
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
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: trunc(value)

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp width!(timeframe) do
    {:ok, seconds} = Timeframe.seconds(timeframe)
    seconds
  end
end
