defmodule DpExchange.Gemini.Fake do
  @moduledoc """
  An in-process Gemini, for a consumer's tier-1 tests and for the conformance suite's
  active-endpoint assertion.

  **It is not a mock.** Nothing is stubbed, no expectation is recorded, and no call is
  verified. It is a real implementation of `DpExchange.Core.Venue` that answers from
  memory instead of from the network, and it runs the *same* conformance suite as the
  real adapter.

  ## Two rules

  **Less capable is allowed. Differently capable is not.** Where this cannot answer, it
  returns an error. It never returns an empty success for something unsupported — a
  plausible wrong answer is worse than a failure, because only one of the two gets
  noticed.

  **It never rewrites a value the caller supplied**, and it never stamps the current
  clock. `@at` below is fixed, because a fake that stamps `utc_now/0` cannot be used to
  test anything about freshness and is itself the substitution this family refuses.

  ## It models Gemini's refusals, and its two shapes of refusal differ

  A fake where everything works proves half the contract. This one refuses:

    * a symbol it does not carry, with **the real reason for that endpoint**: the family's
      `{:refused, :not_listed}` wherever the real call answers it (a JSON `InvalidSymbol`
      on `get_order_book/2`, `quantization/1` and `place_order/3`, the plain-text 400 of
      `get_historical_prices/4`, `get_trades/2`'s `BadRequest`, and the empty 404s of the
      funding and risk reads), and `{:refused, :no_quote}` for `get_price/2` and
      `get_top_of_book/2`, where `/v1/pubticker` answers `'X' does not have available data
      yet`. No venue text rides in either reason;
    * a timeframe Gemini does not serve, including `2h`, `4h` and `12h`, which the shared
      vocabulary models and this venue does not;
    * a range reaching **before the venue's fixed window**, with `{:range_unavailable,
      …}` rather than a short answer — because the real endpoint ignores bounds entirely
      and a truncated result reads as a complete one.

  That last one is this venue's distinctive failure mode, and a consumer that has not
  handled it will find out here rather than in production.

  ## Failure injection and anonymous mode

  Every function below that has a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is.
  `authenticated/2` also checks `FakeInjection.credentials_bypassed?/1` before running the
  same scheme-resolution `Private`'s `Auth.headers/5` runs — see that function's own
  comment for the shapes it returns. Neither changes anything for a test that never calls
  `FakeInjection` — see that module for the full contract.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired: each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express — see `FakeInjection`'s own moduledoc.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Config, FakeInjection, Fanout, Timeframe, Types, Venue}
  alias DpExchange.Gemini.{Auth, Environment, Feed, Private, Rest, SymbolFormat}

  @symbols ~w(BTC-USD BTC-GUSD ETH-USD SOL-RLUSD)

  @price %{
    "BTC-USD" => "77845.79",
    "BTC-GUSD" => "77851.02",
    "ETH-USD" => "2951.40",
    "SOL-RLUSD" => "121.66"
  }

  # Fixed, not `utc_now/0`.
  @at ~U[2026-08-28 12:00:00Z]

  # When the ledger rows `list_custody_fees/2` and `get_transactions/2` answer with are dated,
  # in epoch milliseconds, so the `:since` filters have something to compare against.
  @ledger_ms 1_700_000_000_000

  # `subscribe/2`'s `:channels` default — matches `DpExchange.Gemini.Feed`'s own
  # `@default_channels` exactly, so a caller of neither sees any change from before
  # `:trades` existed as a kind.
  @default_channels [:quotes, :top_of_book]

  # Process-dictionary key for which symbols were subscribed WITH `:trades` in their
  # `:channels` — kept apart from `__MODULE__` (which `subscribed/0` reads) because a
  # symbol can be subscribed for quotes without trades, or vice versa across two separate
  # `subscribe/2` calls, and the two facts must not collapse into one set the way a single
  # boolean would.
  @trades_key {__MODULE__, :trades}
  @top_of_book_key {__MODULE__, :top_of_book}

  @doc """
  A child spec for the fake. It is accepted anywhere the real one is, but starts nothing:
  `start_link/1` answers `:ignore`.

  See `c:DpExchange.Core.Venue.child_spec/1`.
  """
  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Starts nothing and answers `:ignore`: the fake keeps its state per process, not in a tree.

  See `c:DpExchange.Core.Venue.start_link/1`.
  """
  @impl true
  def start_link(_opts), do: :ignore

  @doc "The real adapter's `DpExchange.Gemini.provider_name/0`, unchanged."
  @impl true
  def provider_name, do: DpExchange.Gemini.provider_name()

  @doc "The real adapter's `DpExchange.Gemini.runtime_id/0`, unchanged."
  @impl true
  def runtime_id, do: DpExchange.Gemini.runtime_id()

  @doc "The real adapter's `DpExchange.Gemini.asset_classes/0`, unchanged."
  @impl true
  def asset_classes, do: DpExchange.Gemini.asset_classes()

  # The real declaration, deliberately. A fake declaring different capabilities from the
  # venue it stands in for is a fake a consumer cannot use to test capability branching.
  @doc "The real adapter's `DpExchange.Gemini.capabilities/0`, unchanged, deliberately."
  @impl true
  def capabilities, do: DpExchange.Gemini.capabilities()

  @doc """
  A fixed in-memory price for a symbol the fake carries; one it does not carry is refused
  as the real endpoint refuses it.

  See `DpExchange.Gemini.get_price/2` and `c:DpExchange.Core.Venue.get_price/2`.
  """
  @impl true
  def get_price(symbol, _opts \\ []) do
    with :ok <- Rest.validate_symbol(symbol) do
      symbol = canonical(symbol)
      with_injection(symbol, fn -> fake_quote(symbol) end)
    end
  end

  # Outside `with_injection/2`, so `subscribe/2` builds its push without consuming a failure
  # a test queued for `get_price/2` — the stream never touches the REST endpoint it would
  # otherwise have stood in for.
  defp fake_quote(symbol) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        {:ok,
         %Types.Quote{
           symbol: symbol,
           price: Decimal.new(price),
           volume: Decimal.new("183.72"),
           # As the real `get_price/2`: the ticker's 24-hour volume.
           volume_window: :rolling_24h,
           # `nil`, as the real REST quote: the venue states no trade time (MD7).
           venue_time: nil,
           observed_at: @at,
           provider: :gemini
         }}

      :error ->
        no_quote(symbol)
    end
  end

  @doc """
  A fixed in-memory top of book for a symbol the fake carries.

  See `DpExchange.Gemini.get_top_of_book/2` and `c:DpExchange.Core.Venue.get_top_of_book/2`.
  """
  @impl true
  def get_top_of_book(symbol, _opts \\ []) do
    with :ok <- Rest.validate_symbol(symbol) do
      symbol = canonical(symbol)
      with_injection(symbol, fn -> fake_top_of_book(symbol) end)
    end
  end

  defp fake_top_of_book(symbol) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        {:ok,
         %Types.TopOfBook{
           symbol: symbol,
           # A spread around the fake's price. The bid is deliberately *not* equal to the
           # price: a test that passes only when they coincide is not testing the split
           # this type exists to enforce.
           bid: Decimal.sub(Decimal.new(price), Decimal.new("0.31")),
           ask: Decimal.add(Decimal.new(price), Decimal.new("0.69")),
           bid_size: nil,
           ask_size: nil,
           # `nil`, as the real REST top of book: no quote time is stated (MD7).
           venue_time: nil,
           observed_at: @at,
           provider: :gemini
         }}

      :error ->
        no_quote(symbol)
    end
  end

  @doc """
  In-memory candles on this venue's own grid, with its refusals: a timeframe Gemini does not
  serve, and a range starting before the fixed window (`{:range_unavailable, ...}`).

  See `DpExchange.Gemini.get_historical_prices/4` and
  `c:DpExchange.Core.Venue.get_historical_prices/4`.
  """
  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []) do
    # The real call's own order: the symbol, then the options it cannot honour (`:limit`,
    # a non-boolean `:include_partial`), then the width and the range.
    with :ok <- Rest.validate_symbol(symbol),
         :ok <- Rest.validate_candle_opts(opts) do
      fake_candles(canonical(symbol), timeframe, range, opts)
    end
  end

  defp fake_candles(symbol, timeframe, range, opts) do
    with_injection(symbol, fn ->
      # **The width and the range are checked by the real function, and before the symbol.**
      # `Rest.get_historical_prices/4` refuses an unsupported width (`2h`, `4h` and `12h` are
      # modelled by the vocabulary and not served), a bound that is not a `DateTime`, and a
      # start before the venue's fixed window, all before it makes a request, so the venue
      # never gets the chance to refuse the symbol. This checked the symbol first, so a call
      # wrong in both ways answered with the venue's refusal where the real package answers
      # with its own, and it carried its own copy of the window arithmetic, anchored a bar
      # away from the real boundary and without the `:invalid_range` refusal.
      with :ok <- perpetual_width(symbol, timeframe),
           :ok <- Rest.validate_history(timeframe, range) do
        if symbol in @symbols do
          # Selected with the real call's own `Rest.select_candles/4`: a range the bar
          # falls outside of (`:end` exclusive), or a bar still forming without
          # `include_partial: true`, is `{:ok, []}` there and here.
          bar = candle_for(timeframe, symbol, range)
          {:ok, Rest.select_candles([bar], timeframe, range, opts)}
        else
          # Measured live 2026-09-06: `/v2/candles/{symbol}/{width}` refuses an unknown
          # symbol with a plain-text 400, `Supplied value '#{symbol}' is not a valid
          # symbol` — see `Rest.get_body/2`'s own comment. `:not_listed` never appeared
          # anywhere in the real vocabulary; found in the parity sweep.
          {:refused, :not_listed}
        end
      end
    end)
  end

  # The one bar this fake has, opened at its fixed clock. A `:start` after that clock moves
  # the bar to the first bar boundary at or after `:start`, so a range the venue window admits
  # (for the narrow widths that only reaches the present) still holds a bar to return.
  # `Rest.select_candles/4` then decides whether the range keeps it, as it does for real rows.
  defp candle_for(timeframe, symbol, range) do
    bar = candle(symbol, timeframe)

    case Keyword.get(range, :start) do
      %DateTime{} = start ->
        moved_bar(bar, start, timeframe)

      _no_start ->
        bar
    end
  end

  # The bar moved to the first boundary at or after `start`, when `start` is after it. A
  # boundary `DateTime` cannot represent (a `:start` in the last bar of year 9999) leaves the
  # bar where it is, which `Rest.select_candles/4` then drops as before `start`: the answer the
  # real call gives for a range past every bar, an empty list, where `from_unix!/2` raised in
  # the caller's process.
  defp moved_bar(bar, start, timeframe) do
    with :lt <- DateTime.compare(bar.opened_at, start),
         {:ok, at} <- bar_at_or_after(start, timeframe) do
      %{bar | opened_at: at}
    else
      _keep -> bar
    end
  end

  # `1w` and `1M` have no fixed width in Core, so the bar opens at `start` itself.
  defp bar_at_or_after(start, timeframe) do
    case Timeframe.seconds(timeframe) do
      {:ok, width} ->
        width_us = width * 1_000_000
        start_us = DateTime.to_unix(start, :microsecond)
        DateTime.from_unix(div(start_us + width_us - 1, width_us) * width_us, :microsecond)

      :error ->
        {:ok, start}
    end
  end

  # A perpetual's candles come from `/v2/derivatives/candles`, which serves `1m` and nothing
  # else, and `Rest` refuses any other width for one before it makes a request (and before it
  # looks at the range). The fake lists no perpetual, so it cannot answer one, but it must not
  # answer a width the real call refuses with a symbol refusal instead.
  defp perpetual_width(symbol, timeframe) do
    if perpetual_symbol?(symbol) and timeframe != "1m",
      do: {:error, {:unsupported_timeframe, timeframe}},
      else: :ok
  end

  @doc """
  The four symbols the fake carries.

  See `DpExchange.Gemini.get_symbols/1` and `c:DpExchange.Core.Venue.get_symbols/1`.
  """
  @impl true
  def get_symbols(_opts \\ []) do
    with_injection(fn -> {:ok, @symbols} end)
  end

  @doc """
  An in-memory book for a symbol the fake carries. The book options are validated by the
  real `DpExchange.Gemini.Rest` check before anything is answered.

  See `DpExchange.Gemini.get_order_book/2` and `c:DpExchange.Core.Venue.get_order_book/2`.
  """
  @impl true
  def get_order_book(symbol, opts \\ []) do
    with :ok <- Rest.validate_symbol(symbol),
         :ok <- Rest.validate_book_opts(opts) do
      symbol = canonical(symbol)
      # The depth was checked above by the real call's own `Rest.validate_book_opts/1`, after
      # the symbol's shape and before the symbol is looked up: the venue is never asked, so it
      # never gets to refuse the symbol.
      depth = Config.opt(opts, :depth, nil)
      with_injection(symbol, fn -> fake_order_book(symbol, depth) end)
    end
  end

  # The first `depth` levels a side, as the real call's `limit_bids`/`limit_asks`; `nil` and
  # `0` (the venue: "May be 0 to return the full order book on this side") are the whole ladder.
  defp take_depth(levels, depth) when is_integer(depth) and depth > 0,
    do: Enum.take(levels, depth)

  defp take_depth(levels, _whole_book), do: levels

  defp fake_order_book(symbol, depth) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        bid = Decimal.new(price)

        # **Three levels a side, and the depth is load-bearing.** This fake returned one
        # level each way, and `Core.AdapterContract`'s assertion 25 — the one that exists
        # to check that bids come back highest-first and asks lowest-first — ran against
        # it, reached the behaviour, and passed. It could not have done anything else: a
        # list of one is sorted under every comparator, so there was no edit to this
        # function that could have made that assertion fail. Adding a second, deliberately
        # misordered level turned the suite red immediately (48 tests, 1 failure), which
        # is how the inertness was measured rather than argued.
        #
        # Core now refuses a book this thin, so this cannot silently go back to one level.
        # Keeping the ladder here as well, rather than relying only on that refusal, is
        # the point: the fixture is what gives the assertion something to be wrong about.
        {:ok,
         %Types.OrderBook{
           symbol: symbol,
           bids:
             take_depth(
               [
                 {bid, Decimal.new("0.0031")},
                 {Decimal.sub(bid, Decimal.new("0.01")), Decimal.new("0.0140")},
                 {Decimal.sub(bid, Decimal.new("0.02")), Decimal.new("0.2500")}
               ],
               depth
             ),
           asks:
             take_depth(
               [
                 {Decimal.add(bid, Decimal.new("0.01")), Decimal.new("0.0182")},
                 {Decimal.add(bid, Decimal.new("0.02")), Decimal.new("0.0910")},
                 {Decimal.add(bid, Decimal.new("0.03")), Decimal.new("0.3300")}
               ],
               depth
             ),
           # `nil`, not `@at` — `Rest.get_order_book/2` never has a real time to report
           # here: the venue's own schema marks the only field this endpoint carries a
           # "timestamp" — `OrderBookEntry.timestamp` — a dummy value, "DO NOT USE". A
           # fake reporting a real `venue_time` would be more capable than the endpoint
           # it fakes, which this family's parity rule ("less capable is allowed;
           # differently capable is not") refuses exactly as much as the reverse.
           venue_time: nil,
           observed_at: @at,
           provider: :gemini
         }}

      :error ->
        # `Rest.get_order_book/2`'s own test pins `/v1/book/{symbol}` to a JSON
        # `InvalidSymbol` refusal for an unlisted symbol, not the invented `:not_listed`
        # this used to answer — found in the parity sweep.
        {:refused, :not_listed}
    end
  end

  @doc """
  An in-memory trade tape. `:since`, `:since_tid` and `:limit` are checked by the real
  `DpExchange.Gemini.Rest` validator first.

  See `DpExchange.Gemini.get_trades/2` and `c:DpExchange.Core.Venue.get_trades/2`.
  """
  @impl true
  def get_trades(symbol, opts \\ []) do
    # The real call's own checks, before the venue is asked: a symbol that is not a
    # non-blank string, then a `:since`, `:since_tid` or `:limit` it cannot send.
    with :ok <- Rest.validate_symbol(symbol),
         :ok <- Rest.validate_trade_opts(opts) do
      symbol = canonical(symbol)
      with_injection(symbol, fn -> fake_tape(symbol, opts) end)
    end
  end

  # `:since_tid` wins over `:since`, as the venue states; both are "after", so exclusive. A
  # raw integer `:since` is read as milliseconds from 1e11 up and seconds below it, the vendor's
  # "either seconds or milliseconds" (unmeasured beyond the spec's own examples). `:limit`
  # keeps the most recent N of what survives, oldest first, as `Rest.get_trades/2` returns.
  defp fake_tape(symbol, opts) do
    if symbol in @symbols do
      trades =
        if Keyword.get(opts, :include_broken, false),
          do: tape(symbol),
          else: Enum.reject(tape(symbol), & &1.broken)

      returned = trades |> after_cursor(opts) |> most_recent(Keyword.get(opts, :limit))

      # As the real call: a cursor read that fills its limit may have a hole.
      with :ok <- Rest.check_trade_window(length(returned), opts), do: {:ok, returned}
    else
      # This used to answer unconditionally for ANY symbol — never refusing at all,
      # which is more capable than `Rest.get_trades/2` rather than less. Measured live
      # 2026-09-06: `GET /v1/trades/{symbol}` refuses an unlisted symbol with
      # `{"reason":"BadRequest",...}`, a reason outside `Rest`'s recognised vocabulary
      # and so `{:unknown_reason, ...}` there too. Found in the parity sweep.
      {:refused, :not_listed}
    end
  end

  defp tape(symbol) do
    [
      %Types.Trade{
        id: "5335307668",
        symbol: symbol,
        # The taker's side: a buyer lifted the offer.
        side: :buy,
        price: Decimal.new("3610.85"),
        quantity: Decimal.new("0.27413495"),
        timestamp: @at,
        broken: false,
        provider: :gemini
      },
      %Types.Trade{
        id: "5335307669",
        symbol: symbol,
        side: :sell,
        price: Decimal.new("9999.99"),
        quantity: Decimal.new("1"),
        timestamp: @at,
        # A busted print. The fake carries one so a consumer's suite exercises the
        # exclusion rather than assuming it.
        broken: true,
        provider: :gemini
      }
    ]
  end

  defp after_cursor(trades, opts) do
    case {Keyword.get(opts, :since_tid), Keyword.get(opts, :since)} do
      {tid, _since} when is_integer(tid) ->
        Enum.filter(trades, &(String.to_integer(&1.id) > tid))

      {nil, nil} ->
        trades

      {nil, since} ->
        Enum.filter(trades, &(DateTime.compare(&1.timestamp, since_instant(since)) == :gt))
    end
  end

  defp since_instant(%DateTime{} = at), do: at
  defp since_instant(ms) when ms >= 100_000_000_000, do: unix_or_end_of_time(ms, :millisecond)
  defp since_instant(seconds), do: unix_or_end_of_time(seconds, :second)

  # A cursor beyond `DateTime`'s range is after every trade, not a raise.
  defp unix_or_end_of_time(value, unit) do
    case DateTime.from_unix(value, unit) do
      {:ok, at} -> at
      {:error, _out_of_range} -> ~U[9999-12-31 23:59:59Z]
    end
  end

  defp most_recent(trades, nil), do: trades
  defp most_recent(trades, limit), do: Enum.take(trades, -limit)

  @doc """
  An in-memory reference rate. An unsupported pair is refused before the credential, and a
  credential is required, as on the real call.

  See `DpExchange.Gemini.get_fx_rate/3` and `c:DpExchange.Core.Venue.get_fx_rate/3`.
  """
  @impl true
  def get_fx_rate(pair, at, opts \\ []) do
    with_injection(fn ->
      # The fourteen pairs the venue serves, refused by the real function and BEFORE the
      # credential: `Private.get_fx_rate/3` refuses an unsupported pair (its 404 reads the
      # same as one for a bad timestamp) without signing anything, so a call wrong in both
      # ways was answered `:missing_credentials` here and `:unsupported_fx_pair` there.
      #
      # Signed on the real venue (`Private.get_fx_rate/3`'s own doc — measured against
      # `rest.yaml:7836-7851`), so the fake requires a credential too, the same as
      # `list_networks/2` does for both of its directions: a fake that accepted `nil` here
      # would let a consumer's test pass while the real call was refused before it ever
      # signed a request.
      with :ok <- Private.validate_fx_instant(at),
           {:ok, native} <- Private.validate_fx_pair(pair),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.FxRate{
           pair: native,
           rate: Decimal.new("0.69"),
           as_of: at,
           # The institution that computed it — not the venue, which is `provider`.
           source: "bcb",
           benchmark: "Spot",
           provider: :gemini
         }}
      end
    end)
  end

  @doc """
  In-memory network lookups for an asset, or for `opts[:network]`. A blank asset or network
  is refused before the credential, as on the real call.

  See `DpExchange.Gemini.list_networks/2` and `c:DpExchange.Core.Venue.list_networks/2`.
  """
  @impl true
  def list_networks(asset, opts \\ []) do
    with_injection(fn ->
      # Refused first by the function the real call builds its path with: a blank or
      # non-string asset or network is an error there before anything is signed.
      with {:ok, _path} <- Private.network_lookup_path(asset, Keyword.get(opts, :network)) do
        list_networks_answer(asset, Keyword.get(opts, :network), opts)
      end
    end)
  end

  defp list_networks_answer(asset, network_opt, opts) do
    case {asset, network_opt} do
      {nil, network} ->
        # Scoped to the credential on the real venue, so the fake requires one: an empty
        # answer means this account cannot move anything on that network, not that the
        # network carries nothing.
        with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
          {:ok, [%{"network" => network, "assets" => ["USDC", "USDT"]}]}
        end

      {asset, _network} ->
        # **Signed too.** This answered the asset→networks direction with no credential,
        # calling it "the public direction". `Private.list_networks/2` has never had one:
        # `GET /v2/network/{token}` measured `401 MissingSecurityHeaders` unauthenticated
        # (see its own doc), so a consumer's tier-1 test passed here with no key where the
        # real call is refused before a request is made.
        with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
          {:ok, [%{"asset" => asset, "networks" => ["ethereum", "solana"]}]}
        end
    end
  end

  @doc """
  One fixed promotional symbol.

  See `DpExchange.Gemini.list_fee_promos/1` and `c:DpExchange.Core.Venue.list_fee_promos/1`.
  """
  @impl true
  def list_fee_promos(_opts \\ []) do
    with_injection(fn -> {:ok, [%{"symbol" => "btcusd"}]} end)
  end

  @doc """
  A fixed price and 24-hour change for each symbol the fake carries.

  See `DpExchange.Gemini.get_market_overview/1` and
  `c:DpExchange.Core.Venue.get_market_overview/1`.
  """
  @impl true
  def get_market_overview(_opts \\ []) do
    with_injection(fn ->
      {:ok,
       Map.new(@symbols, fn symbol ->
         {symbol, %{price: Decimal.new(@price[symbol]), change_24h: Decimal.new("-0.0424")}}
       end)}
    end)
  end

  @doc """
  Fixed increments for a symbol the fake carries.

  See `DpExchange.Gemini.quantization/1` and `c:DpExchange.Core.Venue.quantization/1`.
  """
  @impl true
  def quantization(symbol) do
    with :ok <- Rest.validate_symbol(symbol), do: fake_quantization(canonical(symbol))
  end

  defp fake_quantization(symbol) do
    with_injection(symbol, fn ->
      case Map.fetch(@price, symbol) do
        {:ok, _price} ->
          {:ok,
           %{
             price_increment: Decimal.new("0.01"),
             quantity_increment: Decimal.new("0.00000001"),
             min_quantity: Decimal.new("0.00001"),
             status: "open"
           }}

        :error ->
          # Measured live 2026-09-06: `/v1/symbols/details/{symbol}` refuses an unlisted
          # symbol with `{"reason":"InvalidSymbol",...}` — the one case in this sweep
          # confirmed against the venue itself, not just against `Rest`'s own tests.
          {:refused, :not_listed}
      end
    end)
  end

  # `Rest.list_instruments/1`'s shape: every listed symbol `:tradable`, honouring `symbols:`, and
  # an unlisted one failing the whole call with the venue's own `InvalidSymbol` refusal
  # inside, as the real call does.
  @doc """
  The instruments the fake carries, or those named by `opts[:symbols]`; a symbol it does not
  carry is refused.

  See `DpExchange.Gemini.list_instruments/1` and `c:DpExchange.Core.Venue.list_instruments/1`.
  """
  @impl true
  def list_instruments(opts \\ []) do
    with_injection(fn ->
      # The real function's own reading of `:symbols`: canonical spellings, each once, and
      # a value that is not a list of strings refused rather than raised on.
      with {:ok, requested} <- Rest.requested_instrument_symbols(Keyword.get(opts, :symbols)) do
        symbols = requested || @symbols

        case Enum.find(symbols, &(&1 not in @symbols)) do
          nil ->
            {:ok, Enum.map(symbols, &fake_instrument/1)}

          unlisted ->
            {:error, {:instrument_detail_failed, unlisted, {:refused, :not_listed}}}
        end
      end
    end)
  end

  defp fake_instrument(symbol) do
    [base, quote_asset] = String.split(symbol, "-")

    DpExchange.Core.Instrument.new(
      symbol: symbol,
      base: base,
      quote: quote_asset,
      instrument: :spot,
      status: :tradable
    )
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_auction_imbalance/2`.
  """
  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_volume_profile/3`.
  """
  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  # --- account and trading, in memory -------------------------------------
  #
  # Credentials are an argument here exactly as in the real adapter. The fake checks that
  # something credential-shaped arrived and otherwise refuses — a fake that accepted `nil`
  # would let a consumer's test pass while the real call fails on a missing key.

  @doc """
  Fixed USD and BTC balances for an accepted credential.

  See `DpExchange.Gemini.get_balances/2` and `c:DpExchange.Core.Venue.get_balances/2`.
  """
  @impl true
  def get_balances(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok,
         [
           %Types.Balance{
             currency: "USD",
             balance: Decimal.new("100000.00"),
             available_balance: Decimal.new("99000.00"),
             hold: Decimal.new("1000.00"),
             timestamp: @at,
             provider: :gemini
           },
           %Types.Balance{
             currency: "BTC",
             balance: Decimal.new("1000.00000000"),
             available_balance: Decimal.new("1000.00000000"),
             hold: Decimal.new("0E-8"),
             timestamp: @at,
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @doc """
  One fixed account row for an accepted credential.

  See `DpExchange.Gemini.get_accounts/2` and `c:DpExchange.Core.Venue.get_accounts/2`.
  """
  @impl true
  def get_accounts(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, [%{"account" => "primary", "type" => "exchange"}]}
      end
    end)
  end

  @doc """
  A fixed fee schedule. A `:symbol` the real call would refuse is refused before the
  credential.

  See `DpExchange.Gemini.get_fees/2` and `c:DpExchange.Core.Venue.get_fees/2`.
  """
  @impl true
  def get_fees(credentials, opts \\ []) do
    with_injection(fn ->
      # The `:symbol` is refused by the real function's own check, before the credential.
      with {:ok, _params} <- Private.fees_params(opts),
           :ok <- authenticated(credentials, opts) do
        {:ok, %{"api_maker_fee_bps" => 10, "api_taker_fee_bps" => 35}}
      end
    end)
  end

  @doc """
  An empty transfer history for an accepted credential; the window and page options are
  validated by the real function first.

  See `DpExchange.Gemini.get_transfers/2` and `c:DpExchange.Core.Venue.get_transfers/2`.
  """
  @impl true
  def get_transfers(credentials, opts \\ []) do
    with_injection(fn ->
      # The window and page options are refused by the real function, before the credential:
      # `Private.get_transfers/2` signs nothing for a `limit_transfers: 0`.
      with :ok <- Private.validate_history_opts(:transfers, opts),
           :ok <- authenticated(credentials, opts),
           do: {:ok, []}
    end)
  end

  @doc """
  Validates the request with the same `DpExchange.Gemini.Private` function the real adapter
  uses, then remembers the order in this process.

  See `DpExchange.Gemini.place_order/3` and `c:DpExchange.Core.Venue.place_order/3`.
  """
  @impl true
  def place_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The refusals matter more than the success. A fake where every order works proves
      # only that the happy path compiles. `Private.validate_order/2` is the SAME function
      # the real adapter validates against, in its order: the request shape, unread keys,
      # symbol, side, type, time in force (one table, not a second copy, which is how this
      # fake used to accept `:stop_limit` with any `time_in_force` and `:post_only` with
      # `:fok`), quantity, prices, client order id and the `:account` option.
      #
      # **Before the credential, not after.** `Private.place_order/3` refuses a malformed
      # request before it signs anything, so a request wrong in both ways is
      # `{:error, {:missing_field, _}}` there. This answered `:missing_credentials`.
      #
      # Each placement is a NEW order with its own numeric id, kept in the calling process
      # (as the subscriptions are), so `get_order/3`, `cancel_order/3` and `get_orders/2`
      # answer for what was placed (and for the one closed order the history read always
      # holds) and `{:refused, :not_found}` for what was not, which is what the real venue's
      # 404 becomes. The venue is not known to dedupe on
      # `client_order_id` (nothing here measured it), so a reused one is a second order.
      with :ok <- Private.validate_order(request, opts),
           :ok <- authenticated(credentials, opts),
           :ok <- listed(canonical(Map.get(request, :symbol))) do
        placed = order(request)
        remember_order(placed)
        {:ok, placed}
      end
    end)
  end

  @orders_key {__MODULE__, :orders}

  defp remember_order(%Types.Order{id: id} = order),
    do: Process.put(@orders_key, Map.put(placed_orders(), id, order))

  defp placed_orders, do: Process.get(@orders_key, %{})

  # The one order the history read always holds (see `closed_orders/1`), so an id that read
  # lists is one `get_order/3` knows.
  @closed_id "9000000000000000001"

  defp find_order(wire_id) do
    id = Integer.to_string(wire_id)

    cond do
      Map.has_key?(placed_orders(), id) -> {:ok, Map.fetch!(placed_orders(), id)}
      id == @closed_id -> {:ok, closed_order()}
      true -> {:refused, :not_found}
    end
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.place_orders/3`.
  """
  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  # These four are refused (`{:error, :not_supported}`), matching the facade. A fake that
  # answered where the real package refuses lets a consumer's suite go green against
  # behaviour that cannot happen.
  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.preview_order/3`.
  """
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.replace_order/4`.
  """
  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.preview_replace/4`.
  """
  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.close_position/3`.
  """
  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Cancels an order this process knows. The id is checked before the credential, as the real
  call does; an order that already filled stays `:filled`.

  See `DpExchange.Gemini.cancel_order/3` and `c:DpExchange.Core.Venue.cancel_order/3`.
  """
  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with_injection(fn ->
      # The id is checked BEFORE the credential, as `Private.cancel_order/3` does, through
      # the same `Private.order_id_param/1`, so the fake cannot be the more permissive one.
      with {:ok, wire_id} <- Private.order_id_param(order_id),
           :ok <- authenticated(credentials, opts),
           {:ok, found} <- find_order(wire_id) do
        # An order that already executed in full stays `:filled`, as `status_of/1` reads it
        # from the venue's own body when a cancel arrives after the last fill.
        cancelled = if found.status == :filled, do: found, else: %{found | status: :cancelled}
        if Map.has_key?(placed_orders(), found.id), do: remember_order(cancelled)
        {:ok, cancelled}
      end
    end)
  end

  @doc """
  One order's state, from this process's memory. An unknown id is `{:refused, :not_found}`.

  See `DpExchange.Gemini.get_order/3` and `c:DpExchange.Core.Venue.get_order/3`.
  """
  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with_injection(fn ->
      with {:ok, wire_id} <- Private.order_id_param(order_id),
           :ok <- authenticated(credentials, opts) do
        find_order(wire_id)
      end
    end)
  end

  @doc """
  Open orders, or history with `history: true`, as two separate reads like the venue's two
  endpoints. The history read filters by `:symbol`, `:since` and `:limit`.

  See `DpExchange.Gemini.get_orders/2` and `c:DpExchange.Core.Venue.get_orders/2`.
  """
  @impl true
  def get_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # Open and historical are two endpoints on this venue, not one with a filter, and the
      # fake says so rather than answering the same empty list to both.
      #
      # **The history read filters by what it is given**, as the venue does: `:symbol`, `:since`
      # and `:limit` narrow the closed orders this fake holds (the one fixed order plus any
      # placed here and since cancelled), and are refused as `Private.validate_history_opts/2`
      # refuses them. This returned the same order whatever
      # the symbol asked for, so a consumer's test of "orders for ETH-USD" saw a BTC-USD fill.
      # What the venue's `timestamp` means for orders is unmeasured (its own recipe
      # contradicts itself); the fake reads it as "on or after".
      with :ok <- Private.validate_history_opts(:orders, opts),
           :ok <- authenticated(credentials, opts) do
        if Keyword.get(opts, :history, false),
          do: {:ok, closed_orders(opts)},
          else: {:ok, open_orders()}
      end
    end)
  end

  # What was placed in this process and not cancelled: the resting set. The endpoint takes no
  # filter, so neither does this.
  defp open_orders do
    placed_orders()
    |> Map.values()
    |> Enum.filter(&(&1.status == :open))
    |> Enum.sort_by(&String.to_integer(&1.id))
  end

  defp closed_order do
    %Types.Order{
      id: @closed_id,
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      quantity: Decimal.new("1"),
      price: Decimal.new("1"),
      stop_price: nil,
      status: :filled,
      filled_quantity: Decimal.new("1"),
      created_at: @at,
      updated_at: @at,
      provider: :gemini
    }
  end

  defp closed_orders(opts) do
    symbol = Keyword.get(opts, :symbol)
    since = Keyword.get(opts, :since)

    cancelled = placed_orders() |> Map.values() |> Enum.reject(&(&1.status == :open))

    [closed_order() | cancelled]
    |> Enum.filter(&(is_nil(symbol) or &1.symbol == canonical(symbol)))
    |> Enum.filter(&(is_nil(since) or on_or_after?(&1.created_at, since)))
    |> Enum.take(Keyword.get(opts, :limit) || 500)
  end

  # Whether `at` is on or after a window bound given as the options accept it: a `DateTime`,
  # or an epoch number or string of digits read the way `since_instant/1` reads one.
  defp on_or_after?(at, %DateTime{} = bound), do: DateTime.compare(at, bound) != :lt

  defp on_or_after?(at, bound) when is_binary(bound),
    do: on_or_after?(at, String.to_integer(bound))

  defp on_or_after?(at, bound), do: DateTime.compare(at, since_instant(bound)) != :lt

  @doc """
  Bulk cancel. `opts[:scope]` is required and checked first, as on the real call.

  See `DpExchange.Gemini.cancel_all_orders/2` and
  `c:DpExchange.Core.Venue.cancel_all_orders/2`.
  """
  @impl true
  def cancel_all_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # The fake enforces the contract's rule, so a consumer's suite cannot go green on a
      # bulk cancel that never said which orders it meant. `Private.cancel_scope/1` is the
      # real function, and runs first as it does there: a call with no scope is
      # `:scope_required` whether or not it carries credentials, because nothing is signed
      # for it. This asked for the credential first.
      with {:ok, _path} <- Private.cancel_scope(Keyword.get(opts, :scope)),
           :ok <- authenticated(credentials, opts) do
        {:ok, %{cancelled: ["fake-gemini-order-1"], rejected: []}}
      end
    end)
  end

  @doc """
  The account's fills from memory. `opts[:symbol]` is optional, as on the real endpoint.

  See `DpExchange.Gemini.get_trade_history/2` and
  `c:DpExchange.Core.Venue.get_trade_history/2`.
  """
  @impl true
  def get_trade_history(credentials, opts) do
    with_injection(fn ->
      # `opts[:symbol]` is optional on the real endpoint — `MyTradesRequest`
      # (`rest.yaml:8294-8298`) names only `request` and `nonce` as required — so the fake
      # no longer refuses a call with none. This used to require one; a fake that refused
      # what the real venue accepts is differently capable, not less.
      with :ok <- Private.validate_history_opts(:trades, opts),
           :ok <- authenticated(credentials, opts) do
        {:ok, []}
      end
    end)
  end

  # Mirrors `Private`'s `auth_scheme/2` + `Auth.headers/5` decision tree exactly — not
  # the cryptography, which the fake never does, but the SHAPE of what a caller with no
  # credentials, or the wrong ones, gets back. That tree found here used to be flattened
  # to one bare `{:refused, :missing_credentials}` for every case, which was wrong on two
  # axes at once against the real path's most common outcome: the wrong *kind*
  # (`:refused`, which the real adapter reserves for the venue's own 401/403 body, never
  # for a call this package refused to even sign and send) and the wrong *shape*
  # (`:missing_credentials` alone, dropping which scheme was missing it). Found in the
  # 2026-09-06 real/fake parity sweep — `fake_parity_test.exs` pins this fake's answers
  # against the real path's for these cases.
  defp authenticated(credentials, opts) do
    with :ok <- authenticated_group(credentials, opts),
         do: account_named(credentials, opts)
  end

  # For the calls that act on the key or the whole group (`create_account/1`, `get_roles/1`),
  # which a master key makes without naming an account; see `Private`'s `@group_level_paths`.
  defp authenticated_group(credentials, opts) do
    if FakeInjection.credentials_bypassed?(:gemini) do
      :ok
    else
      scheme = Config.opt(opts, :auth_scheme, Private.credential_scheme(credentials))
      authenticated_venue_faithful(scheme, credentials)
    end
  end

  # dp-exchange-core issue #38. A master-scoped key must name the subaccount on every
  # account-level call, and the venue answers `MissingAccounts` when it does not. A fake
  # credential declares itself master-scoped with `key_scope: :master` (the real package
  # ignores the field; the venue documents no way to read a key's scope from the key), and
  # then an account-level call without `opts[:account]` is refused with the exact shape the
  # real path returns, so a consumer's test catches the omission before production does.
  defp account_named(%{key_scope: :master}, opts) do
    case Keyword.get(opts, :account) do
      account when is_binary(account) and account != "" -> :ok
      _absent -> {:refused, {:unknown_reason, "MissingAccounts"}}
    end
  end

  defp account_named(_credentials, _opts), do: :ok

  # The scheme is `Private.credential_scheme/1`, the function `Private`'s own `auth_scheme/2`
  # runs when the caller named no scheme explicitly. Both fields present is the venue's own
  # `AmbiguousAuthentication` (400) waiting to happen, caught here before either header
  # family is built rather than sent and rejected.
  #
  # **A blank or non-string credential is refused here as `Auth.headers/5` refuses it**
  # (`{:missing_credentials, :gemini}`). The `:api_key` clause accepted any value for the pair,
  # `nil` and `""` included, so a consumer's tier-1 test passed with an unset `.env` variable
  # (`GEMINI_SECRET=` is `""`) that the real call refuses before it signs. A value with
  # surrounding whitespace is `{:invalid_credentials, :gemini}`, as there: never trimmed and
  # accepted.
  defp authenticated_venue_faithful(:api_key, %{api_key: key, api_secret: secret})
       when is_binary(key) and is_binary(secret) do
    cond do
      String.trim(key) == "" or String.trim(secret) == "" ->
        {:error, {:missing_credentials, :gemini}}

      Auth.unsafe_credential?(key) or Auth.unsafe_credential?(secret) ->
        {:error, {:invalid_credentials, :gemini}}

      true ->
        :ok
    end
  end

  defp authenticated_venue_faithful(:oauth, %{access_token: token}) when is_binary(token) do
    cond do
      String.trim(token) == "" -> {:error, {:missing_credentials, :gemini}}
      Auth.unsafe_credential?(token) -> {:error, {:invalid_credentials, :gemini}}
      true -> :ok
    end
  end

  defp authenticated_venue_faithful(scheme, _credentials) when scheme in [:api_key, :oauth] do
    {:error, {:missing_credentials, :gemini}}
  end

  # `nil` — nothing credential-shaped, and no scheme was named — is not an unsupported
  # SCHEME, it is an absent CREDENTIAL: there was never a scheme to be unsupported.
  # `Auth.headers/5` used to fall this through to its catch-all and answer
  # `{:error, {:unsupported_auth_scheme, nil}}`, mislabelling the one condition every
  # other venue in this family calls `{:error, {:missing_credentials, venue}}`. Fixed in
  # both places together 2026-09-07 — see `Auth.headers/5`'s own moduledoc for the
  # argument this mirrors.
  defp authenticated_venue_faithful(nil, _credentials) do
    {:error, {:missing_credentials, :gemini}}
  end

  # What remains is `:ambiguous` — both header families present, refused before either is
  # built — which really is a scheme this module declines to resolve, exactly as
  # `Auth.headers/5`'s own catch-all treats it.
  defp authenticated_venue_faithful(scheme, _credentials) do
    {:error, {:unsupported_auth_scheme, scheme}}
  end

  defp with_injection(symbol \\ nil, fun) do
    case FakeInjection.next_outcome(:gemini, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  # The staking callbacks carry no credentials argument; the fake finds them where the
  # facade does, so a consumer wiring them wrong fails here rather than in production.
  defp fake_credentials(opts), do: Keyword.get(opts, :credentials, %{})

  defp listed(symbol) do
    # `/v1/order/new` shares `Private`'s `refusal(body)` -> `Rest.refusal_reason/1`
    # vocabulary with every other private POST, and `InvalidSymbol` is the one entry in
    # that table that names a bad symbol rather than a credential problem.
    if symbol in @symbols, do: :ok, else: {:refused, :not_listed}
  end

  # `/v1/pubticker/{symbol}` — the endpoint behind `get_price/2` and `get_top_of_book/2`
  # — 404s on an unlisted symbol with plain text, not JSON: `'<symbol>' does not have
  # available data yet`, measured live 2026-09-06 (`rest_test.exs`). That
  # sentence is the venue saying it has nothing to quote, so the real call answers
  # `{:refused, :no_quote}` (family decision D2) and so does this, for the same input.
  defp no_quote(_symbol), do: {:refused, :no_quote}

  # The order the venue would describe back for `request`, with the type recovered the way
  # `Private.to_order/1` recovers it from the venue's own body: `maker_or_cancel` is
  # `:post_only`, and an `:ioc` or `:fok` time in force on a plain limit order is `:ioc` or
  # `:fok`. The request's own spelling used to be echoed, so `order_type: :maker_or_cancel`
  # came back as `:maker_or_cancel` — an atom no real order carries — and a limit order sent
  # with `time_in_force: :ioc` came back `:limit`, naming a different order from the one
  # the venue holds. `request` has passed `Private.validate_order/2`, so `order_wire/2` cannot
  # refuse it here, and its side is `:buy`/`:sell` in some spelling: the order carries the
  # atom, never the caller's string.
  defp order(request) do
    {:ok, {wire_type, options}} =
      Private.order_wire(Map.get(request, :order_type), Map.get(request, :time_in_force))

    %Types.Order{
      # Numeric, as the venue's are, so `Private.order_id_param/1` (which `get_order/3` and
      # `cancel_order/3` check through) accepts the id this fake issued itself, and unique per
      # placement so two orders are two ids. It was `"fake-order-1"` (issue #5) and then `"1"`
      # for every placement.
      id: Integer.to_string(System.unique_integer([:positive, :monotonic])),
      symbol: canonical(Map.fetch!(request, :symbol)),
      side: request |> Map.fetch!(:side) |> side_atom(),
      order_type: order_type_of(wire_type, options),
      quantity: decimal(Map.fetch!(request, :quantity)),
      price: decimal(Map.fetch!(request, :price)),
      stop_price: optional_decimal(Map.get(request, :stop_price)),
      status: :open,
      filled_quantity: Decimal.new(0),
      created_at: @at,
      updated_at: @at,
      provider: :gemini
    }
  end

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value), do: value |> to_string() |> Decimal.new()

  # Streaming, in memory. The fake pushes immediately on subscribe, which is what the
  # real venue's first `@bookTicker` frame does from the caller's side — and the caller
  # cannot tell the difference, which is the property the facade exists to hold.
  #
  # `opts[:channels]` mirrors `DpExchange.Gemini.Feed`'s own `:channels` option — see its
  # moduledoc's "`channels:`" section — defaulting to the same `[:quotes, :top_of_book]`.
  # Unlike `Feed`, where it is a `start_link/1`-time choice for the whole connection, here
  # it is per `subscribe/2` call: this fake has no persistent connection to configure, so
  # the option is read where it is given. `:trades` in the list pushes a `Types.Trade` for
  # each valid symbol alongside the streamed `Quote`, consistent with the real decode
  # (`WsDecode.to_trade/2`) — a real `id`, a real `side`, `broken: false` because the
  # socket publishes no bust flag, and a non-nil `timestamp`, never the placeholders a
  # less careful fake would reach for.
  @doc """
  Pushes a quote (and a top of book, per `opts[:channels]`) for each carried symbol to
  `opts[:to]` (default: the caller), and records the symbols as covered for this process.

  Not wired to failure injection. See `DpExchange.Gemini.subscribe/2` and
  `c:DpExchange.Core.Venue.subscribe/2`.
  """
  @impl true
  def subscribe(symbols, opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols),
         {:ok, _subscriber} <- Feed.valid_subscriber(Config.opt(opts, :to, self())) do
      do_subscribe(symbols, opts)
    end
  end

  # `Feed.canonical_symbols/1` is what the real feed spells and refuses symbols with —
  # `btcusd` and `BTCUSD` are `BTC-USD`, not merely upper-cased, and a value that is not a
  # list of strings is refused rather than raised on. `canonical_case/1` upper-cased only, so
  # `BTCUSD` was filtered out as unlisted and nothing was delivered where the real package
  # delivers `BTC-USD`.
  defp do_subscribe(symbols, opts) do
    target = Config.opt(opts, :to, self())
    channels = Config.opt(opts, :channels, @default_channels)
    # Coverage is only for what was delivered: a `to:` name nothing holds receives nothing,
    # so no symbol is recorded as covered for it.
    wanted =
      if Fanout.resolve(target), do: Enum.filter(symbols, &(&1 in @symbols)), else: []

    push(wanted, target, channels)

    # **Added to, never replacing.** This was the identical line `update_symbols/2`
    # carries below — the two callbacks were byte-for-byte the same function — so a
    # second `subscribe/2` dropped whatever the first had subscribed. The real
    # facade unions (`wanted: MapSet.union(state.wanted, MapSet.new(symbols))` in
    # `Feed`), so a consumer's tier-1 tests against this fake certified the opposite
    # of what the venue does: subscribe twice, keep one symbol here, keep both there.
    #
    # The contract settles which is right without needing a new sentence in it.
    # `c:DpExchange.Core.Venue.update_symbols/2` exists to "change a live
    # subscription's symbol set", and `c:unsubscribe/2` to stop delivery for named
    # symbols. Neither has any purpose if `subscribe/2` already replaces — you would
    # just subscribe the new list. Two callbacks the contract distinguishes,
    # implemented as one function, is the tell.
    Process.put(__MODULE__, MapSet.union(subscribed(), MapSet.new(wanted)))

    if :top_of_book in channels do
      Process.put(@top_of_book_key, MapSet.union(subscribed_top_of_book(), MapSet.new(wanted)))
    end

    # Unioned the same way, and only for symbols this very call actually pushed a trade
    # for — a symbol subscribed earlier WITHOUT `:trades` does not retroactively gain
    # trade coverage just because a later, unrelated call asked for trades on other
    # symbols.
    if :trades in channels do
      Process.put(@trades_key, MapSet.union(subscribed_trades(), MapSet.new(wanted)))
    end

    :ok
  end

  @doc """
  Drops `symbols` from this process's covered sets and answers `:ok`.

  See `DpExchange.Gemini.unsubscribe/2` and `c:DpExchange.Core.Venue.unsubscribe/2`.
  """
  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols) do
      dropped = MapSet.new(symbols)
      Process.put(__MODULE__, MapSet.difference(subscribed(), dropped))
      Process.put(@trades_key, MapSet.difference(subscribed_trades(), dropped))
      Process.put(@top_of_book_key, MapSet.difference(subscribed_top_of_book(), dropped))
      :ok
    end
  end

  @doc """
  Replaces this process's covered symbols with `symbols`, pushing data for any it adds.

  See `DpExchange.Gemini.update_symbols/2` and `c:DpExchange.Core.Venue.update_symbols/2`.
  """
  @impl true
  def update_symbols(symbols, _opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols) do
      do_update_symbols(symbols)
    end
  end

  defp do_update_symbols(symbols) do
    wanted = MapSet.new(Enum.filter(symbols, &(&1 in @symbols)))

    # **A symbol this adds is pushed for, as `subscribe/2` pushes.** It used to be put
    # straight into the covered set with nothing sent, so `coverage/1` answered `:stream`
    # for a symbol that had delivered nothing, the intent-for-evidence substitution
    # `c:DpExchange.Core.Venue.coverage/1` forbids. Pushed to the caller, with the default
    # channels: the contract's callback takes neither a `to:` nor `:channels`.
    added = wanted |> MapSet.difference(subscribed()) |> MapSet.to_list()
    push(added, self(), @default_channels)

    Process.put(__MODULE__, wanted)

    Process.put(
      @top_of_book_key,
      subscribed_top_of_book() |> MapSet.union(MapSet.new(added)) |> MapSet.intersection(wanted)
    )

    # Narrowed to the new set, never expanded by it — `update_symbols/2` carries no
    # `:channels` of its own (the contract's callback takes none), so a symbol it adds
    # cannot be assumed to want trades; one it keeps can only keep what it already had.
    Process.put(@trades_key, MapSet.intersection(subscribed_trades(), wanted))
    :ok
  end

  # What a real `@bookTicker` frame delivers for each symbol — a `Quote` and, with
  # `:top_of_book` asked for, a `TopOfBook` — plus a `Trade` per symbol for `:trades`. The
  # real Feed's default delivers both of the first two, and this fake used to push only the
  # `Quote`, so a consumer's book handling had nothing to run against.
  defp push(symbols, target, channels) do
    for symbol <- symbols do
      with {:ok, quote_struct} <- fake_quote(symbol),
           do: deliver(target, streamed(quote_struct))

      if :top_of_book in channels do
        with {:ok, book} <- fake_top_of_book(symbol),
             do: deliver(target, %{book | venue_time: nil})
      end

      if :trades in channels, do: deliver(target, trade_for(symbol))
    end

    :ok
  end

  # As the real `Core.Fanout` delivers: a `to:` name that no process holds (or a dead pid) is
  # nobody, skipped. A bare `send/2` raised `ArgumentError` for an unregistered atom.
  #
  # Deliberately defensive: `do_subscribe/2` already pushes nothing for a target that does not
  # resolve, and `update_symbols/2` pushes to `self()`, so the `nil` branch is reached only
  # when the target dies or its name is unregistered between that check and this send — a
  # race no test can stage deterministically, and one that must not raise in the caller.
  defp deliver(target, payload) do
    case Fanout.resolve(target) do
      nil -> :ok
      pid -> send(pid, {:dp_exchange, :gemini, payload})
    end
  end

  # Observed, not intended — only symbols actually pushed for.
  @doc """
  Every symbol this process has subscribed, each as `:stream`.

  See `DpExchange.Gemini.coverage/1` and `c:DpExchange.Core.Venue.coverage/1`.
  """
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  @doc """
  See `DpExchange.Gemini.coverage_by_kind/1`.

  `subscribe/2` pushes a `Types.Quote` for every symbol, a `Types.TopOfBook` when
  `:top_of_book` is in `opts[:channels]` (the default, as on the real Feed), and
  `update_symbols/2` pushes both for a symbol it adds. Each kind reads here only for symbols
  it was actually pushed for.
  `:trades` is real, not empty: a symbol reads here only for a `subscribe/2` call that
  named it AND asked for `:trades` in `opts[:channels]` — narrowed the same way
  `subscribed/0` narrows `:quotes` on `unsubscribe/2` and `update_symbols/2`, so a symbol
  no longer wanted, or one dropped from a later `update_symbols/2` call, stops reading as
  covered here too. **Less capable than the real adapter is allowed; answering a
  different shape is not**, so the keys match `capabilities().streamable` exactly, the
  same three the real adapter reports.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{
          Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}
        }
  def coverage_by_kind(_opts \\ []) do
    %{
      quotes: Map.new(subscribed(), &{&1, :stream}),
      top_of_book: Map.new(subscribed_top_of_book(), &{&1, :stream}),
      trades: Map.new(subscribed_trades(), &{&1, :stream})
    }
  end

  @doc """
  See `DpExchange.Gemini.wanted/1`. The symbols `subscribe/2` and `update_symbols/2` hold,
  sorted; narrowed by `unsubscribe/2` as the real feed's wanted set is. A symbol the fake does
  not carry is never held (it is filtered out at `subscribe/2`), so this is `coverage/1`'s keys:
  less capable than the real feed, which holds a wanted symbol the venue never delivers.
  """
  @spec wanted(keyword()) :: [String.t()]
  @impl true
  def wanted(_opts \\ []), do: subscribed() |> MapSet.to_list() |> Enum.sort()

  @doc """
  Registers `opts[:to]` (default: the caller) for notices and sends nothing, as the real feed
  does.

  See `DpExchange.Gemini.subscribe_notices/1` and
  `c:DpExchange.Core.Venue.subscribe_notices/1`.
  """
  @impl true
  def subscribe_notices(opts \\ []) do
    # Registers, and sends nothing: the real Feed answers `:ok` and notifies on the next
    # event, so a `:link_up` here was a notice a consumer's test saw that production never
    # sends. Found 2026-10-10.
    with {:ok, _subscriber} <- Feed.valid_subscriber(Config.opt(opts, :to, self())), do: :ok
  end

  @doc """
  The same keys the real call answers, with the venue's heartbeat body, for an accepted
  credential.

  See `DpExchange.Gemini.test_connection/2` and `c:DpExchange.Core.Venue.test_connection/2`.
  """
  @impl true
  def test_connection(credentials, opts \\ []) do
    with_injection(fn ->
      # The same three keys `Private.test_connection/2` answers, with the venue's own
      # heartbeat body (`{"result": "ok"}`, rest.yaml `/v1/heartbeat`).
      with :ok <- authenticated(credentials, opts) do
        {:ok,
         %{
           reachable: true,
           environment: Environment.resolve(opts),
           response: %{"result" => "ok"}
         }}
      end
    end)
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_rate_limit_status/2`.
  """
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Always `{:ok, :open}`, as the real adapter answers.

  See `DpExchange.Gemini.market_status/1` and `c:DpExchange.Core.Venue.market_status/1`.
  """
  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  defp subscribed_trades, do: Process.get(@trades_key, MapSet.new())

  defp subscribed_top_of_book, do: Process.get(@top_of_book_key, MapSet.new())

  # `get_price/2`'s `Quote` is the REST shape — `venue_time` is `nil` (the venue states no
  # trade time; the HTTP `Date` header is not one). The streamed
  # `Quote` is a different fact from a different transport: it comes off a `bookTicker`
  # frame's `c`, which the vendor's own AsyncAPI documents no trade time for at all
  # (websocket.yaml:1254-1256), so `DpExchange.Gemini.Socket` delivers it with `venue_time: nil` unconditionally — see
  # `Socket.deliver_last_trade/3`. Reusing `get_price/2`'s struct unmodified here answered
  # `venue_time: @at` on the stream, which is not "less capable than the real adapter", the
  # only kind of divergence this fake is allowed — it is a DIFFERENT capability: a
  # consumer's test asserting on the streamed Quote's `venue_time` would pass against this
  # fake and fail against the real venue, the exact defect `CLAUDE.md` names as the family's
  # own fail-closed rule for fakes.
  #
  # The same holds for volume: the streamed `Quote` carries none (`Socket` builds it with
  # `volume: nil`, the venue's volume arriving as `Trade.quantity`), where `get_price/2`'s
  # carries the ticker's 24-hour total. Kept, the fake's stream showed a volume the real one
  # never sends — the kind of quantity dp-exchange-core issue #42 found consumers summing.
  defp streamed(%Types.Quote{} = quote_struct),
    do: %{quote_struct | venue_time: nil, volume: nil, volume_window: nil}

  # A `Types.Trade` consistent with `WsDecode.to_trade/2`'s own shape: a real `id`
  # (`to_string_or_nil/1` never turns an absent id into `""` there, so this never does
  # either), a real `side` rather than `nil` (`aggressor/1` only answers `nil` for a frame
  # missing `m` entirely, which this fake never has to model), `broken: false` because the
  # socket publishes no bust flag and a venue that says nothing has not said a trade was
  # busted, and a fixed, non-nil `timestamp` — `Types.Trade` enforces one, and `@at` is
  # this fake's one clock throughout, never `DateTime.utc_now/0`.
  defp trade_for(symbol) do
    %Types.Trade{
      id: "fake-trade-1",
      symbol: symbol,
      side: :buy,
      price: Decimal.new(@price[symbol]),
      quantity: Decimal.new("1"),
      timestamp: @at,
      broken: false,
      provider: :gemini
    }
  end

  defp candle(symbol, timeframe) do
    price = Decimal.new(@price[symbol])

    %Types.Candle{
      symbol: symbol,
      timeframe: timeframe,
      # On a width boundary, as the real call requires of every bar (`:unaligned_candle`).
      opened_at: Timeframe.boundary(@at, timeframe),
      open: price,
      high: price,
      low: price,
      close: price,
      volume: Decimal.new("4.81"),
      provider: :gemini
    }
  end

  # The spelling every real call resolves a symbol to. `Rest` and `Private` send
  # `to_exchange_symbol/1` and report `to_canonical_symbol/1`, so `get_price("btcusd")`,
  # `get_price("BTCUSD")` and `get_price("BTC-USD")` are one request there and one answer
  # under `BTC-USD`. This looked the caller's spelling up verbatim, so only the exact
  # canonical one was found and the others were refused as unlisted, with a venue refusal the
  # venue never sent. A value that is not a string never gets here from a public function:
  # `Rest.validate_symbol/1` (the market reads), `Private.validate_order/2` (`place_order/3`)
  # or `Private.validate_history_opts/2` (`get_orders/2`'s `:symbol`) has already refused it
  # as the real functions do. A pass-through clause for non-strings sat here "to keep the
  # helper total"; no caller could reach it (tick AA coverage audit), and a non-string
  # reaching this now is a crash, not a value carried on as though it were a symbol.
  defp canonical(symbol) when is_binary(symbol) do
    symbol |> SymbolFormat.to_exchange_symbol() |> SymbolFormat.to_canonical_symbol()
  end

  # A side `Private.validate_order/2` accepted: `:buy`/`:sell` or that word in any case. The
  # order reports the atom, as the venue's `"buy"` becomes one in `Private.to_order/1`.
  defp side_atom(side) when is_atom(side), do: side

  defp side_atom(side) when is_binary(side) do
    case String.downcase(side) do
      "buy" -> :buy
      "sell" -> :sell
    end
  end

  # What `Private.to_order/1` makes of the venue's own `type` and `options`: a stop-limit by
  # its type, otherwise the single execution option, otherwise a plain limit order.
  defp order_type_of("exchange stop limit", _options), do: :stop_limit
  defp order_type_of(_type, ["maker-or-cancel" | _rest]), do: :post_only
  defp order_type_of(_type, ["immediate-or-cancel" | _rest]), do: :ioc
  defp order_type_of(_type, ["fill-or-kill" | _rest]), do: :fok
  defp order_type_of(_type, _options), do: :limit

  defp optional_decimal(nil), do: nil
  defp optional_decimal(value), do: decimal(value)

  # --- Derivatives, staking, conversion, money movement and administration -----
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. What this
  # section answers, it answers from memory with the real function's refusals in the real
  # order. The callbacks at its end that Gemini does not serve (options, watchlists,
  # financials, news, ...) answer `{:error, :not_supported}` and are declared `:unsupported`
  # in `capabilities/0`, so a consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` is a statement about the declaration, and it is not always about the
  # venue.** That distinction is the one Phase 1 had to correct after a package spent a year
  # asserting a venue had no streaming API when it had fifteen services. See
  # `DpExchange.Gemini`'s `@venue_does_not_serve` for which of these the venue itself lacks.

  @doc """
  Fixed perpetual positions including a short, so the sign convention is exercised.

  See `DpExchange.Gemini.get_positions/1` and `c:DpExchange.Core.Venue.get_positions/1`.
  """
  @impl true
  def get_positions(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # A short, because the short is where the sign convention bites: the venue sends a
        # negative quantity and a fake that only ever returned a long would never exercise it.
        {:ok,
         [
           %Types.Position{
             symbol: "BTCGUSDPERP",
             side: :short,
             quantity: Decimal.new("0.2"),
             instrument_type: :perp,
             average_cost: Decimal.new("60000"),
             mark_price: Decimal.new("59500"),
             notional_value: Decimal.new("-11900"),
             realised_pnl: Decimal.new("12.5"),
             unrealised_pnl: Decimal.new("100"),
             # Not published on /v1/positions. `nil` is "not stated", never "no risk".
             liquidation_price: nil,
             leverage: nil,
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @doc """
  Fixed funding for a perpetual; a symbol that is not a perpetual is refused as the venue
  refuses it.

  See `DpExchange.Gemini.get_funding/2` and `c:DpExchange.Core.Venue.get_funding/2`.
  """
  @impl true
  def get_funding(symbol, _opts \\ []) do
    with :ok <- Rest.validate_symbol(symbol), do: fake_funding(symbol)
  end

  defp fake_funding(symbol) do
    with_injection(symbol, fn ->
      # Funding is a property of a perpetual, and `Rest.get_funding/2` sends the symbol as
      # given. A name that is not a perpetual is the venue's "no data" 404 — measured 2026-09-06
      # for `nonexistentsymbolxyz` (empty body, so `{:refused, :not_listed}`); what it says for a
      # real SPOT symbol was never probed, and this does not claim to know.
      if perpetual_symbol?(symbol) do
        # Settled and estimated differ, and by a lot — a fake that made them equal would let a
        # consumer read either as the other and still pass.
        {:ok,
         %Types.Funding{
           symbol: symbol,
           amount: Decimal.new("-1.50991"),
           estimated_amount: Decimal.new("-2.10595"),
           funded_at: ~U[2026-09-01 18:00:00Z],
           next_funding_at: ~U[2026-09-01 19:00:00Z],
           provider: :gemini
         }}
      else
        {:refused, :not_listed}
      end
    end)
  end

  defp perpetual_symbol?(symbol), do: is_binary(symbol) and SymbolFormat.perpetual?(symbol)

  @doc """
  Fixed risk statistics for a perpetual; any other symbol is refused as the venue refuses it.

  See `DpExchange.Gemini.get_contract_stats/2` and
  `c:DpExchange.Core.Venue.get_contract_stats/2`.
  """
  @impl true
  def get_contract_stats(symbol, _opts \\ []) do
    with :ok <- Rest.validate_symbol(symbol), do: fake_contract_stats(symbol)
  end

  defp fake_contract_stats(symbol) do
    with_injection(symbol, fn ->
      # Risk statistics exist for perpetuals only. The venue's refusal body for anything else
      # was never measured (only `/v1/fundingamount`'s empty 404 was), so this answers the bare
      # `:refused` that an empty body reads as and does not claim a reason.
      if perpetual_symbol?(symbol) do
        # Mark away from index, because that divergence is the reason both are carried.
        {:ok,
         %Types.ContractStats{
           symbol: symbol,
           product_type: "PerpetualSwapContract",
           mark_price: Decimal.new("59500"),
           index_price: Decimal.new("59480"),
           open_interest: Decimal.new("1240"),
           open_interest_notional: Decimal.new("73780000"),
           venue_time: nil,
           provider: :gemini
         }}
      else
        {:refused, :not_listed}
      end
    end)
  end

  @doc """
  Fixed staking rates, with two providers for one asset at different rates.

  See `DpExchange.Gemini.get_staking_rates/1` and
  `c:DpExchange.Core.Venue.get_staking_rates/1`.
  """
  @impl true
  def get_staking_rates(_opts \\ []) do
    with_injection(fn ->
      # Two providers for one asset, at different rates. One rate would hide the reason
      # `provider_id` is required on stake/3 and unstake/3.
      {:ok,
       [
         %Types.StakingRate{
           asset: "ETH",
           provider_id: "provider-a",
           rate_pct: Decimal.new("4.0"),
           apy_pct: Decimal.new("4.07"),
           provider: :gemini
         },
         %Types.StakingRate{
           asset: "ETH",
           provider_id: "provider-b",
           rate_pct: Decimal.new("3.5"),
           # APY absent where the venue publishes none — never derived from the rate above it.
           apy_pct: nil,
           provider: :gemini
         }
       ]}
    end)
  end

  @doc """
  Fixed staked positions for an accepted credential.

  See `DpExchange.Gemini.get_staking_balances/1` and
  `c:DpExchange.Core.Venue.get_staking_balances/1`.
  """
  @impl true
  def get_staking_balances(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # The whole position redeemable and none of it tradable — the real shape that breaks
        # a caller reading a single "available". `by_provider` carries a real breakdown
        # rather than the empty map this used to hardcode — `balanceByProvider`
        # (`rest.yaml:6565,6573`) is sent on every row in the venue's own example, and an
        # always-empty fake taught nothing about the field it exists for.
        {:ok,
         [
           %Types.StakingBalance{
             asset: "ETH",
             staked: Decimal.new("10"),
             available_to_trade: Decimal.new("0"),
             available_for_withdrawal: Decimal.new("10"),
             by_provider: %{"provider-a" => Decimal.new("10")},
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @doc """
  Fixed staking rewards for an accepted credential.

  See `DpExchange.Gemini.get_staking_rewards/1` and
  `c:DpExchange.Core.Venue.get_staking_rewards/1`.
  """
  @impl true
  def get_staking_rewards(opts \\ []) do
    with_injection(fn ->
      # `since` is required at the venue (`rest.yaml:6885`, in the request schema's
      # `required` list) — the fake refuses its absence the same way
      # `Private.get_staking_rewards/2` does now, rather than answering for a window the
      # caller never named. Before the credential, as there: a call with no `:since` is
      # refused before anything is signed, and was asked for its credential first here. The
      # staking writes below do the same with `:provider_id`.
      with {:ok, _since} <- fake_required_since(opts),
           :ok <- Private.validate_history_opts(:staking_rewards, opts),
           :ok <- authenticated(fake_credentials(opts), opts) do
        # `:provider_id` narrows it, as the venue's `providerId` does. The window cannot: the
        # venue computes the periods itself and a fake that clipped them would invent some.
        {:ok, staking_rewards(Keyword.get(opts, :provider_id))}
      end
    end)
  end

  defp staking_rewards(provider_id) do
    reward = %Types.StakingReward{
      asset: "ETH",
      amount: Decimal.new("0.0031"),
      provider_id: "provider-a",
      apy_pct: Decimal.new("4.07"),
      accrual_count: 7,
      period_start: ~U[2026-08-25 00:00:00Z],
      period_end: ~U[2026-09-01 00:00:00Z],
      provider: :gemini
    }

    Enum.filter([reward], &provider_matches?(&1, provider_id))
  end

  defp provider_matches?(_row, nil), do: true
  defp provider_matches?(row, provider_id), do: row.provider_id == provider_id

  defp fake_required_since(opts) do
    case Keyword.get(opts, :since) do
      nil -> {:error, {:missing_option, :since}}
      since -> {:ok, since}
    end
  end

  @doc """
  Fixed staking history for an accepted credential.

  See `DpExchange.Gemini.get_staking_history/1` and
  `c:DpExchange.Core.Venue.get_staking_history/1`.
  """
  @impl true
  def get_staking_history(opts \\ []) do
    with_injection(fn ->
      with :ok <- Private.validate_history_opts(:staking_history, opts),
           :ok <- authenticated(fake_credentials(opts), opts) do
        # A redemption mid-unbond: requested, part paid, part outstanding. A fake whose rows
        # all settled would never exercise the field this type exists for.
        #
        # **Dated, and filtered by what it is given**: `:since` and `:until` (inclusive),
        # `:provider_id` and `:limit` narrow it as the venue's request does. It carried no
        # `venue_time` and ignored all four.
        {:ok, staking_history(opts)}
      end
    end)
  end

  defp staking_history(opts) do
    redemption = %Types.StakingTransaction{
      id: "stk-1",
      type: :unstake,
      venue_type: "Redeem",
      asset: "ETH",
      amount: Decimal.new("10"),
      amount_paid_so_far: Decimal.new("4"),
      amount_remaining: Decimal.new("6"),
      provider_id: "provider-a",
      venue_time: @at,
      provider: :gemini
    }

    [redemption]
    |> Enum.filter(&provider_matches?(&1, Keyword.get(opts, :provider_id)))
    |> Enum.filter(&within_iso_window?(&1.venue_time, opts))
    |> Enum.take(Keyword.get(opts, :limit) || 500)
  end

  defp within_iso_window?(at, opts) do
    bound_ok?(at, Keyword.get(opts, :since), :lower) and
      bound_ok?(at, Keyword.get(opts, :until), :upper)
  end

  # `at` against an inclusive bound: a `:lower` one means `at` must not be before it, an
  # `:upper` one not after it. A string bound has already passed `validate_history_opts/2`.
  defp bound_ok?(_at, nil, _side), do: true

  defp bound_ok?(at, bound, side) when is_binary(bound) do
    {:ok, parsed, _offset} = DateTime.from_iso8601(bound)
    bound_ok?(at, parsed, side)
  end

  defp bound_ok?(at, %DateTime{} = bound, :lower), do: DateTime.compare(at, bound) != :lt
  defp bound_ok?(at, %DateTime{} = bound, :upper), do: DateTime.compare(at, bound) != :gt

  @doc """
  A fixed staking deposit. `opts[:provider_id]` is required, and the terms are validated by
  the real function before the credential.

  See `DpExchange.Gemini.stake/3` and `c:DpExchange.Core.Venue.stake/3`.
  """
  @impl true
  def stake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with {:ok, provider_id} <- fake_provider_id(opts),
           {:ok, _currency, wire_amount} <- Private.validate_staking_terms(asset, amount),
           :ok <- authenticated(fake_credentials(opts), opts) do
        {:ok,
         %Types.StakingTransaction{
           id: "stk-new",
           type: :stake,
           # `nil`, not `"Deposit"` — `StakingDeposit` (`rest.yaml:9466-9497`), this
           # endpoint's own reply shape, carries no `transactionType` field at all; that
           # belongs to the *history* endpoint's row, a different schema. A fake naming a
           # word the real reply never sends is more capable than the endpoint it fakes.
           venue_type: nil,
           asset: String.upcase(asset),
           # A `Decimal`, as the real decode makes it from the venue's reply, whatever shape
           # the caller held the amount in (a string, an integer or a `Decimal`).
           amount: Decimal.new(wire_amount),
           amount_paid_so_far: nil,
           amount_remaining: nil,
           provider_id: provider_id,
           provider: :gemini
         }}
      end
    end)
  end

  @doc """
  A fixed staking redemption. `opts[:provider_id]` is required, as for `stake/3`.

  See `DpExchange.Gemini.unstake/3` and `c:DpExchange.Core.Venue.unstake/3`.
  """
  @impl true
  def unstake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with {:ok, provider_id} <- fake_provider_id(opts),
           {:ok, _currency, wire_amount} <- Private.validate_staking_terms(asset, amount),
           :ok <- authenticated(fake_credentials(opts), opts) do
        # Nothing has arrived yet. A fake reporting the full amount paid would teach a
        # consumer to spend an asset that is still unbonding.
        requested = Decimal.new(wire_amount)

        {:ok,
         %Types.StakingTransaction{
           id: "stk-redeem",
           type: :unstake,
           # `nil` — `StakingWithdrawal` (`rest.yaml:9663-9692`) carries no `transactionType`
           # either. `venue_time` is `requestInitiated`, the one field this reply DOES carry
           # that `StakingDeposit` does not — `stake/3`'s fake stays `nil` for the reason
           # given there.
           venue_type: nil,
           asset: String.upcase(asset),
           amount: requested,
           amount_paid_so_far: Decimal.new("0"),
           amount_remaining: requested,
           provider_id: provider_id,
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  defp fake_provider_id(opts), do: Private.provider_id(opts)

  @doc """
  A fixed conversion quote. An ambiguous direction is refused by the real function before
  the credential.

  See `DpExchange.Gemini.quote_conversion/4` and
  `c:DpExchange.Core.Venue.quote_conversion/4`.
  """
  @impl true
  def quote_conversion(from, to, amount, opts \\ []) do
    with_injection(fn ->
      # The fake refuses the ambiguous direction the real package refuses, with the real
      # function (`Private.instant_pair/3`) and before the credential, as the real path does:
      # nothing is signed for a direction it cannot determine. A fake that picked one would
      # let a consumer's suite pass on a conversion that spends the wrong asset.
      #
      # The amount is checked by the function the real call uses (a finite number above zero),
      # after the direction and before the credential, as there.
      with {:ok, _symbol, _side} <- Private.instant_pair(from, to, opts),
           {:ok, wire_amount} <- Private.validate_amount(amount, :amount),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.Conversion{
           # Numeric, as the venue's `quoteId` is, so `commit_conversion/2` (which checks the id
           # through `Private.commit_terms/2`) accepts the quote this fake issued.
           # `"fake-gemini-quote-1"` was refused as `:invalid_quote_id`, the same defect as
           # issue #5 for orders.
           id: "1",
           status: :quoted,
           from_asset: from,
           to_asset: to,
           from_amount: Decimal.new(wire_amount),
           to_amount: Decimal.div(Decimal.new(wire_amount), Decimal.new("40000")),
           rate: Decimal.new("40000"),
           fee: Decimal.new("0.30"),
           # A real window, so a consumer testing expiry has something to test against.
           expires_at: DateTime.add(@at, 60, :second),
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @doc """
  Commits a quoted conversion. The quoted terms are required, checked by the real function
  before the credential.

  See `DpExchange.Gemini.commit_conversion/2` and
  `c:DpExchange.Core.Venue.commit_conversion/2`.
  """
  @impl true
  def commit_conversion(id, opts \\ []) do
    with_injection(fn ->
      # The venue's execute call needs the terms it quoted against, not the id alone —
      # `:symbol`, `:side`, `:amount`, `:price` and `:fee` (the venue requires the last and
      # states it "must match fee returned in the quote", `rest.yaml:5071`). Checked by the
      # real function, `Private.commit_terms/2`, and before the credential, exactly
      # as `Private.commit_conversion/2` does. This used its own `Keyword.has_key?/2` test,
      # which `price: nil` and `price: ""` satisfy (the real one counts neither as given),
      # never looked at the quote id, and asked for the credential first.
      with {:ok, terms} <- Private.commit_terms(id, opts),
           {:ok, base, quote_asset} <- committed_pair(terms["symbol"]),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok, committed_conversion(id, terms, base, quote_asset)}
      end
    end)
  end

  # The pair the conversion was committed on, from the symbol that was committed. It used to be
  # a fixed `USD -> BTC` whatever was committed: a consumer that converted ETH to GBP was told
  # it had converted USD to BTC. A symbol that does not split into two assets is refused, not
  # guessed.
  defp committed_pair(symbol) do
    case symbol |> SymbolFormat.to_canonical_symbol() |> String.split("-") do
      [base, quote_asset] when base != "" and quote_asset != "" -> {:ok, base, quote_asset}
      _unsplit -> {:error, {:invalid_symbol, symbol}}
    end
  end

  # What a settled conversion carries that the commit itself stated: the pair (a buy gives up
  # the quote asset for the base, a sell the reverse), the price as the rate, the fee, and the
  # base quantity on the side it lands on. The other amount is the venue's own figure and the
  # real reply reports no proceeds for a sell, so it is `nil` here rather than arithmetic.
  defp committed_conversion(id, terms, base, quote_asset) do
    {from_asset, to_asset} =
      if terms["side"] == "buy", do: {quote_asset, base}, else: {base, quote_asset}

    quantity = Decimal.new(terms["quantity"])

    %Types.Conversion{
      # A string, as the real decode makes it; the id may arrive as the integer the venue
      # names, which `commit_terms/2` also accepts.
      id: to_string(id),
      status: :settled,
      from_asset: from_asset,
      to_asset: to_asset,
      from_amount: if(terms["side"] == "buy", do: nil, else: quantity),
      to_amount: if(terms["side"] == "buy", do: quantity, else: nil),
      rate: Decimal.new(terms["price"]),
      fee: Decimal.new(terms["fee"]),
      venue_time: @at,
      provider: :gemini
    }
  end

  @doc """
  A one-step conversion, already settled: no rate is held.

  See `DpExchange.Gemini.convert/4` and `c:DpExchange.Core.Venue.convert/4`.
  """
  @impl true
  def convert(from, to, amount, opts \\ []) do
    with_injection(fn ->
      # One step and already settled — no rate was held, which is the whole difference from
      # quote_conversion/4.
      with {:ok, _symbol, _side} <- Private.instant_pair(from, to, opts),
           {:ok, wire_amount} <- Private.validate_amount(amount, :amount),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        # A `Decimal` whatever shape the caller held the amount in, as the real decode makes it.
        settled = Decimal.new(wire_amount)

        {:ok,
         %Types.Conversion{
           id: "fake-gemini-wrap-1",
           status: :settled,
           from_asset: from,
           to_asset: to,
           from_amount: settled,
           to_amount: settled,
           rate: Decimal.new("1"),
           expires_at: nil,
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @doc """
  One fixed volume row for an accepted credential.

  See `DpExchange.Gemini.get_trade_volume/2` and
  `c:DpExchange.Core.Venue.get_trade_volume/2`.
  """
  @impl true
  def get_trade_volume(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok,
         [%{"symbol" => "btcusd", "total_volume_base" => "10.5", "data_date" => "2026-08-31"}]}
      end
    end)
  end

  @doc """
  Not served by this package: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_conversion/2`.
  """
  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this package yet: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_portfolios/1`.
  """
  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  A fixed deposit address. The network and asset are validated by the real function before
  the credential.

  See `DpExchange.Gemini.get_deposit_address/3` and
  `c:DpExchange.Core.Venue.get_deposit_address/3`.
  """
  @impl true
  def get_deposit_address(asset, network, opts \\ []) do
    with_injection(fn ->
      # The network first, as `Private.get_deposit_address/4` builds its path from it before it
      # signs anything, then the asset it names the address for.
      with :ok <- Private.validate_deposit_request(asset, network),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.DepositAddress{
           asset: asset,
           network: network,
           address: "0x0000000000000000000000000000000000000000",
           memo: nil,
           # `nil`, as in production. `false` would tell a consumer no memo is needed, which
           # on Solana or XRP loses the deposit.
           memo_required: nil,
           label: Keyword.get(opts, :label),
           created_at: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @doc """
  Fixed approved addresses. `opts[:network]` is required and checked before the credential.

  See `DpExchange.Gemini.list_approved_addresses/1` and
  `c:DpExchange.Core.Venue.list_approved_addresses/1`.
  """
  @impl true
  def list_approved_addresses(opts \\ []) do
    with_injection(fn ->
      # The network is named before the credential is asked for, as
      # `Private.list_approved_addresses/2` does: there is no all-networks variant, and a
      # call that names none is refused before anything is signed.
      case Keyword.get(opts, :network) do
        nil ->
          {:error, {:missing_option, :network}}

        network ->
          # A blank or non-string network is refused by the real function before it signs
          # anything: it would build `/v1/approvedAddresses/account/` for the route.
          with :ok <- Private.validate_deposit_network(network),
               :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            # One active and one still time-locked, because a consumer that only ever sees
            # active addresses never handles the pending case — and a withdrawal to a pending
            # address is refused.
            {:ok,
             [
               %Types.ApprovedAddress{
                 address: "0x1111111111111111111111111111111111111111",
                 network: network,
                 status: :active,
                 label: "desk",
                 requested_at: @at,
                 provider: :gemini
               },
               %Types.ApprovedAddress{
                 address: "0x2222222222222222222222222222222222222222",
                 network: network,
                 status: :pending,
                 # No activation time, so `usable?/2` answers nil — unknown, not "ready".
                 active_from: nil,
                 label: "new",
                 requested_at: @at,
                 provider: :gemini
               }
             ]}
          end
      end
    end)
  end

  @doc """
  A fixed withdrawal fee estimate. Moves nothing; the request is validated by the real
  function before the credential.

  See `DpExchange.Gemini.estimate_withdrawal_fee/4` and
  `c:DpExchange.Core.Venue.estimate_withdrawal_fee/4`.
  """
  @impl true
  def estimate_withdrawal_fee(asset, network, amount, opts \\ []) do
    with_injection(fn ->
      # The destination, asset, network and amount first, by the function the real call uses,
      # then the credential — `Private.estimate_withdrawal_fee/5` refuses all of them before it
      # signs anything.
      with :ok <- Private.validate_fee_estimate(asset, network, amount, opts),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %{
           fee: Decimal.new("0.0005"),
           fee_currency: "ETH",
           network: network,
           address: Keyword.fetch!(opts, :address)
         }}
      end
    end)
  end

  @doc """
  A fixed withdrawal answer; moves nothing. The memo rule, destination and amount are
  validated by the real functions before the credential.

  See `DpExchange.Gemini.withdraw/5` and `c:DpExchange.Core.Venue.withdraw/5`.
  """
  @impl true
  def withdraw(asset, network, amount, address, opts \\ []) do
    with_injection(fn ->
      # The request first (memo rule, destination, amount, transfer id), then the credential:
      # `Private.withdraw/6` refuses a required memo that is missing "here, where nothing has
      # moved", before it signs anything.
      #
      # The memo rule is the real function's: a blank memo does not satisfy `memo_required`,
      # where this tested only for `nil` and accepted `memo: ""`.
      memo = Keyword.get(opts, :memo)

      with :ok <- Private.validate_memo(memo, Keyword.get(opts, :memo_required, false)),
           :ok <- Private.validate_withdrawal(asset, network, amount, address),
           {:ok, wire_amount} <- Private.validate_amount(amount, :amount),
           {:ok, supplied_id} <-
             Private.client_transfer_id(Keyword.get(opts, :client_transfer_id)),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.Withdrawal{
           # The idempotency key the real package always sends, echoed so a consumer can
           # assert its own was used. A blank one is no key there, and is none here.
           # Unique per call when the caller gave none, as the real path's generated key is: one
           # fixed id for every withdrawal made two withdrawals look like one.
           id: supplied_id || Private.generate_transfer_id(),
           # **`:pending`, never `:completed`.** The venue accepting a withdrawal is not the
           # chain confirming it, and a fake that reported completion would teach a consumer
           # the money has arrived.
           status: :pending,
           asset: asset,
           # A `Decimal` amount and a string memo (an integer memo is spelled out, a blank one
           # is none), as the real call returns them whatever shape the caller held them in.
           amount: Decimal.new(wire_amount),
           network: network,
           address: address,
           memo: fake_withdrawal_memo(memo),
           fee: Decimal.new("0.0005"),
           tx_id: nil,
           requested_at: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @doc """
  Fixed payment methods in the venue's two-array shape, tagged balance or bank.

  See `DpExchange.Gemini.list_payment_methods/2` and
  `c:DpExchange.Core.Venue.list_payment_methods/2`.
  """
  @impl true
  def list_payment_methods(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # `PaymentMethodsResponse` (`rest.yaml:5454`, schema `:9316-9328`) is
        # `{balances: [...], banks: [...]}`, not the `"methods"` list this used to fake.
        # `Private.list_payment_methods/2` tags each row `"kind" => "balance"` or
        # `"kind" => "bank"` to keep the split the venue's own two arrays make; this mirrors
        # that split with the venue's own example values rather than an invented
        # verified/pending pair neither array actually carries (`PaymentMethodBank` has no
        # status field at all).
        {:ok,
         [
           %{
             "kind" => "balance",
             "type" => "exchange",
             "currency" => "USD",
             "amount" => "50893484.26",
             "available" => "50889972.01",
             "availableForWithdrawal" => "50889972.01"
           },
           %{
             "kind" => "bank",
             "bank" => "Jpmorgan Chase Bank Checking  - 1111",
             "bankId" => "97631a24-ca40-4277-b3d5-38c37673d029"
           }
         ]}
      end
    end)
  end

  @doc """
  Registers a bank account as pending, never verified. `opts[:country]` selects the endpoint.

  See `DpExchange.Gemini.add_payment_method/2` and
  `c:DpExchange.Core.Venue.add_payment_method/2`.
  """
  @impl true
  def add_payment_method(details, opts \\ []) do
    with_injection(fn ->
      # The details, then the country, then the credential — `Private.add_payment_method/3`
      # refuses malformed details, picks the endpoint by country and refuses a country it has
      # none for, all before it signs anything.
      with :ok <- Private.validate_payment_details(details),
           {:ok, _path} <- fake_country(Config.opt(opts, :country, "US")),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        # **Pending, never verified.** The venue verifies out of band; a fake that returned a
        # usable method would teach a consumer the first transfer will work.
        {:ok, Map.merge(%{"id" => "bank-3", "status" => "pending"}, details)}
      end
    end)
  end

  defp fake_country("US"), do: {:ok, :us}
  defp fake_country("CA"), do: {:ok, :ca}
  defp fake_country(country), do: {:error, {:unsupported_country, country}}

  @doc """
  A fixed transfer between two accounts. `:from` and `:to` are required and validated by the
  real function before the credential.

  See `DpExchange.Gemini.transfer_internal/4` and
  `c:DpExchange.Core.Venue.transfer_internal/4`.
  """
  @impl true
  def transfer_internal(asset, amount, transfer_opts, opts \\ []) do
    with_injection(fn ->
      # `Private.transfer_internal/5` refuses a missing `:from` or `:to` before it signs
      # anything. The account names are checked by the real function (non-blank strings, and
      # not the same account), then the asset and amount (the amount written out in full, as
      # there), then the key, then the credential, as there.
      #
      # The reply carries the venue's own response fields (`rest.yaml`, "Transfer Between
      # Accounts"): `fromAccount`, `toAccount`, `amount` and a `uuid` unique to the transfer.
      # It no longer echoes the request's `asset`, a field the venue's reply does not have.
      with {:ok, from, to} <- Private.validate_internal_accounts(transfer_opts),
           {:ok, _currency, wire_amount} <- Private.validate_internal_transfer(asset, amount),
           {:ok, _supplied_id} <-
             Private.client_transfer_id(Keyword.get(transfer_opts, :client_transfer_id)),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %{
           "fromAccount" => from,
           "toAccount" => to,
           "amount" => wire_amount,
           # The venue's id for the completed transfer, unique per call; not the caller's key.
           "uuid" => Private.generate_transfer_id(),
           "message" => "Success, transfer completed."
         }}
      end
    end)
  end

  @doc """
  Requests an allowlist entry; the answer is pending, never active.

  See `DpExchange.Gemini.request_approved_address/4` and
  `c:DpExchange.Core.Venue.request_approved_address/4`.
  """
  @impl true
  def request_approved_address(network, address, label, opts \\ []) do
    with_injection(fn ->
      # The label before the credential, by the real function: nothing is signed for a call
      # that names no label.
      with :ok <- Private.validate_label(label),
           :ok <- Private.validate_approved_address(network, address),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        # **Pending.** A successful response is not permission to withdraw, and a fake that
        # returned "active" would teach a consumer it is.
        {:ok,
         %{
           "network" => network,
           "address" => address,
           "label" => label,
           "status" => "pending-time"
         }}
      end
    end)
  end

  @doc """
  Removes an allowlist entry; the answer carries `"status" => "removed"`.

  See `DpExchange.Gemini.remove_approved_address/3` and
  `c:DpExchange.Core.Venue.remove_approved_address/3`.
  """
  @impl true
  def remove_approved_address(network, address, opts \\ []) do
    with_injection(fn ->
      with :ok <- Private.validate_approved_address(network, address),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok, %{"network" => network, "address" => address, "status" => "removed"}}
      end
    end)
  end

  @doc """
  Fixed ledger rows that are neither trades nor transfers. `:since` is nanoseconds (or a
  `DateTime`) and `:limit` takes the first rows.

  See `DpExchange.Gemini.get_transactions/2` and
  `c:DpExchange.Core.Venue.get_transactions/2`.
  """
  @impl true
  def get_transactions(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- Private.validate_history_opts(:transactions, opts),
           :ok <- authenticated(credentials, opts) do
        # Kinds that are not trades and not transfers, because that is the point of the
        # endpoint and a fake returning only fills would hide it. `:since` is NANOSECONDS (or
        # a `DateTime`), as on the real call, and `:limit` takes the first rows.
        {:ok, transactions(opts)}
      end
    end)
  end

  defp transactions(opts) do
    at = @ledger_ms

    rows = [
      %{"type" => "Trade", "amount" => "1", "timestampms" => at},
      %{"type" => "Deposit", "amount" => "100", "timestampms" => at + 1},
      %{"type" => "Fee", "amount" => "-0.5", "timestampms" => at + 2}
    ]

    rows
    |> Enum.filter(&(transactions_since_ms(Keyword.get(opts, :since)) <= &1["timestampms"]))
    |> Enum.take(Keyword.get(opts, :limit) || 300)
  end

  # The window bound in milliseconds: a `DateTime`, or the nanoseconds `:since` takes (an
  # integer or a string of digits). Absent is before everything.
  defp transactions_since_ms(nil), do: 0
  defp transactions_since_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  defp transactions_since_ms(nanos) when is_binary(nanos) do
    transactions_since_ms(String.to_integer(nanos))
  end

  defp transactions_since_ms(nanos), do: div(nanos, 1_000_000)

  @doc """
  Fixed balances each carrying a quantity and a separate notional valuation. A blank
  currency is refused before the credential.

  See `DpExchange.Gemini.get_notional_balances/3` and
  `c:DpExchange.Core.Venue.get_notional_balances/3`.
  """
  @impl true
  def get_notional_balances(credentials, currency, opts \\ []) do
    with_injection(fn ->
      # The currency first, by the real function: nothing is signed for a blank one.
      with :ok <- Private.validate_notional_currency(currency),
           :ok <- authenticated(credentials, opts) do
        # The quantity and its valuation are different keys and different numbers. A fake that
        # made them equal would let a consumer read either as the other and still pass.
        {:ok,
         [
           %{
             "currency" => "BTC",
             "amount" => "1.5",
             "amountNotional" => "60000.00",
             "available" => "1.5",
             "availableNotional" => "60000.00",
             "notionalCurrency" => String.upcase(currency)
           }
         ]}
      end
    end)
  end

  @doc """
  Fixed custody charges. `:since` and `:limit` narrow them.

  See `DpExchange.Gemini.list_custody_fees/2` and
  `c:DpExchange.Core.Venue.list_custody_fees/2`.
  """
  @impl true
  def list_custody_fees(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- Private.validate_history_opts(:custody_fees, opts),
           :ok <- authenticated(credentials, opts) do
        # A charge with no trade behind it — the gap a consumer reconciling against fills
        # alone cannot otherwise explain. `:since` (on or after) and `:limit` narrow it.
        {:ok, custody_fees(opts)}
      end
    end)
  end

  defp custody_fees(opts) do
    fee = %{
      "currency" => "BTC",
      "amount" => "0.00012",
      "timestampms" => @ledger_ms,
      "eid" => 123_456
    }

    since = Keyword.get(opts, :since)
    charged_at = DateTime.from_unix!(@ledger_ms, :millisecond)

    [fee]
    |> Enum.filter(fn _fee -> is_nil(since) or on_or_after?(charged_at, since) end)
    |> Enum.take(Keyword.get(opts, :limit) || 50)
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_payment_method/3`.
  """
  @impl true
  def get_payment_method(_credentials, _id, _opts \\ []), do: Venue.not_supported()

  defp fake_withdrawal_memo(memo) when is_integer(memo), do: Integer.to_string(memo)

  defp fake_withdrawal_memo(memo) when is_binary(memo) do
    if String.trim(memo) == "", do: nil, else: memo
  end

  defp fake_withdrawal_memo(memo), do: memo

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_option_chain/2`.
  """
  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_option_expirations/2`.
  """
  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_option_greeks/2`.
  """
  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.list_watchlists/1`.
  """
  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_watchlist/2`.
  """
  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.create_watchlist/3`.
  """
  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.update_watchlist/2`.
  """
  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.delete_watchlist/2`.
  """
  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_financials/3`.
  """
  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_corporate_events/1`.
  """
  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_filings/2`.
  """
  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_news/1`.
  """
  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`. See
  `c:DpExchange.Core.Venue.get_screener/2`.
  """
  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Creates a subaccount. `opts[:name]` is required; the answer carries a kebab-cased
  shortname, not the name sent.

  See `DpExchange.Gemini.create_account/1` and `c:DpExchange.Core.Venue.create_account/1`.
  """
  @impl true
  def create_account(opts \\ []) do
    with_injection(fn ->
      # The name and type are checked by the real call's own function, before the credential.
      with {:ok, params} <- Private.create_account_params(Keyword.get(opts, :name), opts),
           :ok <- authenticated_group(fake_credentials(opts), opts) do
        # The venue answers with a kebab-cased shortname, not the name that was sent —
        # a fake that echoed the name would let a consumer address the wrong thing.
        {:ok,
         %{
           "account" =>
             params["name"] |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
           "type" => Map.get(params, "type", "exchange")
         }}
      end
    end)
  end

  @doc """
  Renames a subaccount. A call that would change nothing is refused as `:nothing_to_rename`.

  See `DpExchange.Gemini.rename_account/3` and `c:DpExchange.Core.Venue.rename_account/3`.
  """
  @impl true
  def rename_account(id, name, opts \\ []) do
    with_injection(fn ->
      # As `DpExchange.Gemini.rename_account/3` hands `Private.rename_account/2` its options:
      # `id` IS the `account` the call is made against, so a master key that names the
      # account by `id` has named it. Without the merge a master-scoped fake credential was
      # refused `MissingAccounts` for an account the caller had named.
      opts = Keyword.merge(opts, account: id, name: name)
      shortname = Keyword.get(opts, :shortname)

      # `Private.rename_account/2` refuses a call that would change nothing, before it signs
      # anything: no new name and no new shortname is `:nothing_to_rename`, not a success. It
      # refuses a blank or non-string account, name or shortname the same way, and the fake
      # asks the same function.
      with {:ok, _params} <- Private.rename_account_params(opts),
           :ok <- authenticated(fake_credentials(opts), opts),
           do: {:ok, renamed(id, name, shortname)}
    end)
  end

  # Only the fields that changed come back, as the venue documents: the account's (new)
  # shortname, and the display name when one was sent.
  defp renamed(id, nil, shortname), do: %{"account" => shortname || id}
  defp renamed(id, name, shortname), do: %{"name" => name, "account" => shortname || id}

  @doc """
  Fixed roles: trader and fund manager, not auditor.

  See `DpExchange.Gemini.get_roles/1` and `c:DpExchange.Core.Venue.get_roles/1`.
  """
  @impl true
  def get_roles(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated_group(fake_credentials(opts), opts) do
        # Trader and Fund Manager combined, and Auditor false — the combination the venue
        # allows. One role field would not be able to say this.
        {:ok, %{"isAuditor" => false, "isFundManager" => true, "isTrader" => true}}
      end
    end)
  end
end
