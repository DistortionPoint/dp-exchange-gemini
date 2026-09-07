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

    * a symbol it does not carry, with **the real reason for that endpoint** — Gemini
      does not refuse a bad symbol the same way everywhere, and neither does this fake:
      `:invalid_symbol` where `Rest`'s own tests pin a JSON `InvalidSymbol` body
      (`get_order_book/2`, `quantization/1`, `place_order/3`), `{:unknown_reason, text}`
      where the venue answers with plain text instead (`get_price/2`, `get_top_of_book/2`
      — measured live, `/v1/pubticker` — and `get_historical_prices/4` — measured live,
      `/v2/candles`), or the venue's own unrecognised JSON reason (`get_trades/2`,
      measured live as `BadRequest`). A single invented `:not_listed` used to stand in
      for all of these, which is precisely the divergence the 2026-09-06 real/fake
      parity sweep exists to catch: a consumer's test pattern-matching the real shape
      passed here for the wrong reason;
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

  alias DpExchange.Core.{Capabilities, FakeInjection, Notice, Timeframe, Types, Venue}
  alias DpExchange.Gemini.{Private, Rest, SymbolFormat}

  @symbols ~w(BTC-USD BTC-GUSD ETH-USD SOL-RLUSD)

  @price %{
    "BTC-USD" => "77845.79",
    "BTC-GUSD" => "77851.02",
    "ETH-USD" => "2951.40",
    "SOL-RLUSD" => "121.66"
  }

  # Fixed, not `utc_now/0`.
  @at ~U[2026-08-28 12:00:00Z]

  # Bars the real venue serves per width, so the fake refuses the same ranges it does.
  @window_bars %{
    "1m" => 1_440,
    "5m" => 2_015,
    "15m" => 1_343,
    "30m" => 1_439,
    "1h" => 1_463,
    "6h" => 367,
    "1d" => 364
  }

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def provider_name, do: DpExchange.Gemini.provider_name()

  @impl true
  def runtime_id, do: DpExchange.Gemini.runtime_id()

  @impl true
  def asset_classes, do: DpExchange.Gemini.asset_classes()

  # The real declaration, deliberately. A fake declaring different capabilities from the
  # venue it stands in for is a fake a consumer cannot use to test capability branching.
  @impl true
  def capabilities, do: DpExchange.Gemini.capabilities()

  @impl true
  def get_price(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
      case Map.fetch(@price, symbol) do
        {:ok, price} ->
          {:ok,
           %Types.Quote{
             symbol: symbol,
             price: Decimal.new(price),
             volume: Decimal.new("183.72"),
             timestamp: @at,
             provider: :gemini
           }}

        :error ->
          not_listed(symbol)
      end
    end)
  end

  @impl true
  def get_top_of_book(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
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
             venue_time: @at,
             observed_at: @at,
             provider: :gemini
           }}

        :error ->
          not_listed(symbol)
      end
    end)
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], _opts \\ []) do
    with_injection(symbol, fn ->
      cond do
        symbol not in @symbols ->
          # Measured live 2026-09-06: `/v2/candles/{symbol}/{width}` refuses an unknown
          # symbol with a plain-text 400, `Supplied value '#{symbol}' is not a valid
          # symbol` — see `Rest.get_body/2`'s own comment. `:not_listed` never appeared
          # anywhere in the real vocabulary; found in the parity sweep.
          {:refused, {:unknown_reason, "Supplied value '#{symbol}' is not a valid symbol"}}

        timeframe not in Rest.timeframes() ->
          # Includes `2h`, `4h` and `12h` — modelled by the vocabulary, not served here.
          {:error, {:unsupported_timeframe, timeframe}}

        before_window?(timeframe, range) ->
          # `requested:` matches `Rest.get_historical_prices/4`'s real shape exactly — it
          # used to be omitted here, so a consumer's tier-1 test asserting the documented
          # `{earliest:, requested:}` pair passed against this fake and would have failed
          # against the real venue. Found in the 2026-09-06 real/fake parity sweep.
          {:error,
           {:range_unavailable, timeframe,
            earliest: earliest(timeframe), requested: Keyword.get(range, :start)}}

        true ->
          {:ok, [candle(symbol, timeframe)]}
      end
    end)
  end

  @impl true
  def get_symbols(_opts \\ []) do
    with_injection(fn -> {:ok, @symbols} end)
  end

  @impl true
  def get_order_book(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
      case Map.fetch(@price, symbol) do
        {:ok, price} ->
          bid = Decimal.new(price)

          {:ok,
           %Types.OrderBook{
             symbol: symbol,
             bids: [{bid, Decimal.new("0.0031")}],
             asks: [{Decimal.add(bid, Decimal.new("0.01")), Decimal.new("0.0182")}],
             timestamp: @at,
             provider: :gemini
           }}

        :error ->
          # `Rest.get_order_book/2`'s own test pins `/v1/book/{symbol}` to a JSON
          # `InvalidSymbol` refusal for an unlisted symbol, not the invented `:not_listed`
          # this used to answer — found in the parity sweep.
          {:refused, :invalid_symbol}
      end
    end)
  end

  @impl true
  def get_trades(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      if symbol in @symbols do
        trades = [
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

        if Keyword.get(opts, :include_broken, false) do
          {:ok, trades}
        else
          {:ok, Enum.reject(trades, & &1.broken)}
        end
      else
        # This used to answer unconditionally for ANY symbol — never refusing at all,
        # which is more capable than `Rest.get_trades/2` rather than less. Measured live
        # 2026-09-06: `GET /v1/trades/{symbol}` refuses an unlisted symbol with
        # `{"reason":"BadRequest",...}`, a reason outside `Rest`'s recognised vocabulary
        # and so `{:unknown_reason, ...}` there too. Found in the parity sweep.
        {:refused, {:unknown_reason, "BadRequest"}}
      end
    end)
  end

  @impl true
  def get_fx_rate(pair, at, _opts \\ []) do
    with_injection(fn ->
      native = pair |> to_string() |> String.replace("-", "") |> String.upcase()

      # The fourteen pairs the venue serves, refused the same way the real package refuses:
      # its 404 for an unsupported pair reads the same as one for a bad timestamp.
      if native in ~w(AUDUSD CADUSD COPUSD EURUSD CHFUSD HKDUSD NZDUSD GBPUSD BRLUSD INRUSD
                      SGDUSD KRWUSD JPYUSD CNYUSD) do
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
      else
        {:error, {:unsupported_fx_pair, native}}
      end
    end)
  end

  @impl true
  def list_networks(asset, opts \\ []) do
    with_injection(fn ->
      case {asset, Keyword.get(opts, :network)} do
        {nil, nil} ->
          {:error, :asset_or_network_required}

        {nil, network} ->
          # Scoped to the credential on the real venue, so the fake requires one: an empty
          # answer means this account cannot move anything on that network, not that the
          # network carries nothing.
          with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            {:ok, [%{"network" => network, "assets" => ["USDC", "USDT"]}]}
          end

        {asset, _network} ->
          # The public direction takes no credential.
          {:ok, [%{"asset" => asset, "networks" => ["ethereum", "solana"]}]}
      end
    end)
  end

  @impl true
  def list_fee_promos(_opts \\ []) do
    with_injection(fn -> {:ok, [%{"symbol" => "btcusd"}]} end)
  end

  @impl true
  def get_market_overview(_opts \\ []) do
    with_injection(fn ->
      {:ok,
       Map.new(@symbols, fn symbol ->
         {symbol, %{price: Decimal.new(@price[symbol]), change_24h: Decimal.new("-0.0424")}}
       end)}
    end)
  end

  @impl true
  def quantization(symbol) do
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
          {:refused, :invalid_symbol}
      end
    end)
  end

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  # --- account and trading, in memory -------------------------------------
  #
  # Credentials are an argument here exactly as in the real adapter. The fake checks that
  # something credential-shaped arrived and otherwise refuses — a fake that accepted `nil`
  # would let a consumer's test pass while the real call fails on a missing key.

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

  @impl true
  def get_accounts(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, [%{"account" => "primary", "type" => "exchange"}]}
      end
    end)
  end

  @impl true
  def get_fees(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, %{"api_maker_fee_bps" => 10, "api_taker_fee_bps" => 35}}
      end
    end)
  end

  @impl true
  def get_transfers(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts), do: {:ok, []}
    end)
  end

  @impl true
  def place_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The refusals matter more than the success. A fake where every order works proves
      # only that the happy path compiles. `Private.order_wire/2` is the SAME function
      # the real adapter validates against — not a second copy of the "at most one
      # execution option" table, which is how this fake used to accept combinations
      # (`:stop_limit` with any `time_in_force`, `:post_only` with `:fok`) the venue
      # refuses outright.
      with :ok <- authenticated(credentials, opts),
           {:ok, _wire} <-
             Private.order_wire(
               Map.get(request, :order_type, :limit),
               Map.get(request, :time_in_force, :gtc)
             ),
           :ok <- priced(request),
           :ok <- listed(Map.get(request, :symbol)) do
        {:ok, order(request)}
      end
    end)
  end

  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, %{order(%{}) | id: order_id, status: :cancelled}}
      end
    end)
  end

  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, %{order(%{}) | id: order_id}}
      end
    end)
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # Open and historical are two endpoints on this venue, not one with a filter, and the
      # fake says so rather than answering the same empty list to both.
      with :ok <- authenticated(credentials, opts) do
        if Keyword.get(opts, :history, false),
          do: {:ok, [%{order(%{}) | status: :filled}]},
          else: {:ok, []}
      end
    end)
  end

  @impl true
  def cancel_all_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # The fake enforces the contract's rule, so a consumer's suite cannot go green on a
      # bulk cancel that never said which orders it meant.
      with :ok <- authenticated(credentials, opts) do
        case Keyword.get(opts, :scope) do
          scope when scope in [:session, :account] ->
            {:ok, %{cancelled: ["fake-gemini-order-1"], rejected: []}}

          nil ->
            {:error, :scope_required}

          other ->
            {:error, {:unsupported_scope, other}}
        end
      end
    end)
  end

  @impl true
  def get_trade_history(credentials, opts) do
    with_injection(fn ->
      # The real adapter requires a symbol — Gemini offers no all-symbols variant — so the
      # fake requires one too. Less capable is allowed; differently capable is not.
      with :ok <- authenticated(credentials, opts) do
        case Keyword.get(opts, :symbol) do
          nil -> {:error, {:missing_option, :symbol}}
          _symbol -> {:ok, []}
        end
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
  # 2026-09-06 real/fake parity sweep — every one of `auth_test.exs`'s cases now has a
  # pinned equivalent against this fake in `fake_parity_test.exs`.
  defp authenticated(credentials, opts) do
    if FakeInjection.credentials_bypassed?(:gemini) do
      :ok
    else
      scheme = Keyword.get(opts, :auth_scheme, resolve_scheme(credentials))
      authenticated_venue_faithful(scheme, credentials)
    end
  end

  # The same auto-detection `Private`'s private `auth_scheme/2` runs when the caller
  # named no scheme explicitly. Both fields present is the venue's own
  # `AmbiguousAuthentication` (400) waiting to happen, caught here before either header
  # family is built rather than sent and rejected.
  defp resolve_scheme(%{api_key: _key, access_token: _token}), do: :ambiguous
  defp resolve_scheme(%{api_key: _key}), do: :api_key
  defp resolve_scheme(%{access_token: _token}), do: :oauth
  defp resolve_scheme(_other), do: nil

  defp authenticated_venue_faithful(:api_key, %{api_key: _key, api_secret: _secret}), do: :ok
  defp authenticated_venue_faithful(:oauth, %{access_token: token}) when is_binary(token), do: :ok

  defp authenticated_venue_faithful(scheme, _credentials) when scheme in [:api_key, :oauth] do
    {:error, {:missing_credentials, scheme}}
  end

  # Covers `nil` (nothing credential-shaped, and no scheme was named — Auth.headers/5 has
  # no default) and `:ambiguous` (both header families present, refused before either is
  # built) alike, exactly as `Auth.headers/5`'s own catch-all does.
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

  defp priced(request) do
    if Map.get(request, :price), do: :ok, else: {:error, {:missing_field, :price}}
  end

  defp listed(symbol) do
    # `/v1/order/new` shares `Private`'s `refusal(body)` -> `Rest.refusal_reason/1`
    # vocabulary with every other private POST, and `InvalidSymbol` is the one entry in
    # that table that names a bad symbol rather than a credential problem.
    if symbol in @symbols, do: :ok, else: {:refused, :invalid_symbol}
  end

  # `/v1/pubticker/{symbol}` — the endpoint behind `get_price/2` and `get_top_of_book/2`
  # — 404s on an unlisted symbol with plain text, not JSON: `'<symbol>' does not have
  # available data yet`, measured live 2026-09-06 (`rest_test.exs`, "get_price refuses
  # on a 404, keeping the venue's own words"). `{:refused, :not_listed}` used to stand
  # in here — an atom absent from the venue's own vocabulary and from `Rest`'s — found
  # in the parity sweep.
  defp not_listed(symbol) do
    {:refused, {:unknown_reason, "'#{symbol}' does not have available data yet"}}
  end

  defp order(request) do
    %Types.Order{
      id: "fake-order-1",
      symbol: Map.get(request, :symbol, "BTC-USD"),
      side: Map.get(request, :side, :buy),
      order_type: Map.get(request, :order_type, :limit),
      quantity: decimal(Map.get(request, :quantity, "1")),
      price: decimal(Map.get(request, :price, "1")),
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
  @impl true
  def subscribe(symbols, opts \\ []) do
    target = Keyword.get(opts, :to, self())

    for symbol <- symbols, symbol in @symbols do
      case get_price(symbol, []) do
        {:ok, quote_struct} -> send(target, {:dp_exchange, :gemini, quote_struct})
        _refused -> :ok
      end
    end

    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  # Observed, not intended — only symbols actually pushed for.
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  @doc """
  See `DpExchange.Gemini.coverage_by_kind/1`.

  `subscribe/2` above only ever pushes a `Types.Quote` (via `get_price/2`) — it never
  builds a `Types.TopOfBook`, so this fake is honestly `:quotes`-only. `:top_of_book`
  still appears as a key, empty, rather than being omitted: an omitted key here would
  read as "this fake does not know about that kind", where an empty map reads as what is
  actually true — the kind is declared, and nothing of it has been observed. **Less
  capable than the real adapter is allowed; answering a different shape is not**, so the
  keys match `capabilities().streamable` exactly, the same two the real adapter reports.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{
          Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}
        }
  def coverage_by_kind(_opts \\ []) do
    %{quotes: Map.new(subscribed(), &{&1, :stream}), top_of_book: %{}}
  end

  @impl true
  def subscribe_notices(opts \\ []) do
    send(Keyword.get(opts, :to, self()), {:dp_exchange, :gemini, Notice.new(:link_up, :gemini)})
    :ok
  end

  @impl true
  def test_connection(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts), do: {:ok, %{reachable: true}}
    end)
  end

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  defp candle(symbol, timeframe) do
    price = Decimal.new(@price[symbol])

    %Types.Candle{
      symbol: symbol,
      timeframe: timeframe,
      opened_at: @at,
      open: price,
      high: price,
      low: price,
      close: price,
      volume: Decimal.new("4.81"),
      provider: :gemini
    }
  end

  defp before_window?(timeframe, range) do
    case Keyword.get(range, :start) do
      nil -> false
      start -> DateTime.compare(start, earliest(timeframe)) == :lt
    end
  end

  defp earliest(timeframe) do
    {:ok, width} = Timeframe.seconds(timeframe)
    DateTime.add(@at, -Map.fetch!(@window_bars, timeframe) * width, :second)
  end

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

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

  @impl true
  def get_funding(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
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
    end)
  end

  @impl true
  def get_contract_stats(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
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
    end)
  end

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

  @impl true
  def get_staking_balances(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # The whole position redeemable and none of it tradable — the real shape that breaks
        # a caller reading a single "available".
        {:ok,
         [
           %Types.StakingBalance{
             asset: "ETH",
             staked: Decimal.new("10"),
             available_to_trade: Decimal.new("0"),
             available_for_withdrawal: Decimal.new("10"),
             by_provider: %{},
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def get_staking_rewards(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        {:ok,
         [
           %Types.StakingReward{
             asset: "ETH",
             amount: Decimal.new("0.0031"),
             provider_id: "provider-a",
             apy_pct: Decimal.new("4.07"),
             accrual_count: 7,
             period_start: ~U[2026-08-25 00:00:00Z],
             period_end: ~U[2026-09-01 00:00:00Z],
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def get_staking_history(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # A redemption mid-unbond: requested, part paid, part outstanding. A fake whose rows
        # all settled would never exercise the field this type exists for.
        {:ok,
         [
           %Types.StakingTransaction{
             id: "stk-1",
             type: :unstake,
             venue_type: "Redeem",
             asset: "ETH",
             amount: Decimal.new("10"),
             amount_paid_so_far: Decimal.new("4"),
             amount_remaining: Decimal.new("6"),
             provider_id: "provider-a",
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def stake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts),
           {:ok, provider_id} <- fake_provider_id(opts) do
        {:ok,
         %Types.StakingTransaction{
           id: "stk-new",
           type: :stake,
           venue_type: "Deposit",
           asset: String.upcase(asset),
           amount: amount,
           amount_paid_so_far: nil,
           amount_remaining: nil,
           provider_id: provider_id,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def unstake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts),
           {:ok, provider_id} <- fake_provider_id(opts) do
        # Nothing has arrived yet. A fake reporting the full amount paid would teach a
        # consumer to spend an asset that is still unbonding.
        {:ok,
         %Types.StakingTransaction{
           id: "stk-redeem",
           type: :unstake,
           venue_type: "Redeem",
           asset: String.upcase(asset),
           amount: amount,
           amount_paid_so_far: Decimal.new("0"),
           amount_remaining: amount,
           provider_id: provider_id,
           provider: :gemini
         }}
      end
    end)
  end

  defp fake_provider_id(opts) do
    case Keyword.get(opts, :provider_id) do
      nil -> {:error, :missing_provider_id}
      provider_id -> {:ok, provider_id}
    end
  end

  @impl true
  def quote_conversion(from, to, amount, opts \\ []) do
    with_injection(fn ->
      # The fake refuses the ambiguous direction the real package refuses. A fake that picked
      # one would let a consumer's suite pass on a conversion that spends the wrong asset.
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts),
           :ok <- fake_direction(from, to, opts) do
        {:ok,
         %Types.Conversion{
           id: "fake-gemini-quote-1",
           status: :quoted,
           from_asset: from,
           to_asset: to,
           from_amount: amount,
           to_amount: Decimal.div(amount, Decimal.new("40000")),
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

  @impl true
  def commit_conversion(id, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        case Enum.reject([:symbol, :side, :amount, :price], &Keyword.has_key?(opts, &1)) do
          [] ->
            {:ok,
             %Types.Conversion{
               id: id,
               status: :settled,
               from_asset: "USD",
               to_asset: "BTC",
               rate: Decimal.new("40000"),
               venue_time: @at,
               provider: :gemini
             }}

          missing ->
            # The venue's execute call needs the terms it quoted against, not the id alone.
            {:error, {:missing_option, missing}}
        end
      end
    end)
  end

  @impl true
  def convert(from, to, amount, opts \\ []) do
    with_injection(fn ->
      # One step and already settled — no rate was held, which is the whole difference from
      # quote_conversion/4.
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts),
           :ok <- fake_direction(from, to, opts) do
        {:ok,
         %Types.Conversion{
           id: "fake-gemini-wrap-1",
           status: :settled,
           from_asset: from,
           to_asset: to,
           from_amount: amount,
           to_amount: amount,
           rate: Decimal.new("1"),
           expires_at: nil,
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def get_trade_volume(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok,
         [%{"symbol" => "btcusd", "total_volume_base" => "10.5", "data_date" => "2026-08-31"}]}
      end
    end)
  end

  defp fake_direction(from, to, opts) do
    quotes = SymbolFormat.quotes()

    cond do
      Keyword.has_key?(opts, :symbol) and Keyword.has_key?(opts, :side) -> :ok
      String.upcase(from) in quotes and String.upcase(to) not in quotes -> :ok
      String.upcase(to) in quotes and String.upcase(from) not in quotes -> :ok
      true -> {:error, {:ambiguous_conversion, from, to}}
    end
  end

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()
  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(asset, network, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
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

  @impl true
  def list_approved_addresses(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        case Keyword.get(opts, :network) do
          nil ->
            {:error, {:missing_option, :network}}

          network ->
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

  @impl true
  def estimate_withdrawal_fee(_asset, network, _amount, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        case Keyword.get(opts, :address) do
          nil ->
            {:error, {:missing_option, :address}}

          address ->
            {:ok,
             %{
               fee: Decimal.new("0.0005"),
               fee_currency: "ETH",
               network: network,
               address: address
             }}
        end
      end
    end)
  end

  @impl true
  def withdraw(asset, network, amount, address, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts),
           :ok <- fake_memo(Keyword.get(opts, :memo), Keyword.get(opts, :memo_required, false)) do
        {:ok,
         %Types.Withdrawal{
           # The idempotency key the real package always sends, echoed so a consumer can
           # assert its own was used.
           id: Keyword.get(opts, :client_transfer_id, "fake-transfer-1"),
           # **`:pending`, never `:completed`.** The venue accepting a withdrawal is not the
           # chain confirming it, and a fake that reported completion would teach a consumer
           # the money has arrived.
           status: :pending,
           asset: asset,
           amount: amount,
           network: network,
           address: address,
           memo: Keyword.get(opts, :memo),
           fee: Decimal.new("0.0005"),
           tx_id: nil,
           requested_at: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def list_payment_methods(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # One verified and one pending: a consumer filtering on presence rather than status
        # picks one the venue will refuse.
        {:ok,
         [
           %{"id" => "bank-1", "type" => "bank", "status" => "verified"},
           %{"id" => "bank-2", "type" => "bank", "status" => "pending"}
         ]}
      end
    end)
  end

  @impl true
  def add_payment_method(details, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts),
           {:ok, _path} <- fake_country(Keyword.get(opts, :country, "US")) do
        # **Pending, never verified.** The venue verifies out of band; a fake that returned a
        # usable method would teach a consumer the first transfer will work.
        {:ok, Map.merge(%{"id" => "bank-3", "status" => "pending"}, details)}
      end
    end)
  end

  defp fake_country("US"), do: {:ok, :us}
  defp fake_country("CA"), do: {:ok, :ca}
  defp fake_country(country), do: {:error, {:unsupported_country, country}}

  @impl true
  def transfer_internal(asset, amount, transfer_opts, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        case {Keyword.get(transfer_opts, :from), Keyword.get(transfer_opts, :to)} do
          {nil, _to} ->
            {:error, {:missing_option, :from}}

          {_from, nil} ->
            {:error, {:missing_option, :to}}

          {from, to} ->
            {:ok,
             %{
               "asset" => asset,
               "amount" => to_string(amount),
               "sourceAccount" => from,
               "targetAccount" => to
             }}
        end
      end
    end)
  end

  @impl true
  def request_approved_address(network, address, label, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
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

  @impl true
  def remove_approved_address(network, address, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok, %{"network" => network, "address" => address, "status" => "removed"}}
      end
    end)
  end

  @impl true
  def get_transactions(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # Kinds that are not trades and not transfers, because that is the point of the
        # endpoint and a fake returning only fills would hide it.
        {:ok,
         [
           %{"type" => "Trade", "amount" => "1"},
           %{"type" => "Deposit", "amount" => "100"},
           %{"type" => "Fee", "amount" => "-0.5"}
         ]}
      end
    end)
  end

  @impl true
  def get_notional_balances(credentials, currency, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
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

  @impl true
  def list_custody_fees(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # A charge with no trade behind it — the gap a consumer reconciling against fills
        # alone cannot otherwise explain.
        {:ok,
         [
           %{
             "currency" => "BTC",
             "amount" => "0.00012",
             "timestampms" => 1_700_000_000_000,
             "eid" => 123_456
           }
         ]}
      end
    end)
  end

  @impl true
  def get_payment_method(_credentials, _id, _opts \\ []), do: Venue.not_supported()

  defp fake_memo(nil, true), do: {:error, :memo_required}
  defp fake_memo(_memo, _required), do: :ok

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_account(opts \\ []) do
    with_injection(fn ->
      case Keyword.get(opts, :name) do
        name when is_binary(name) ->
          with :ok <- authenticated(fake_credentials(opts), opts) do
            # The venue answers with a kebab-cased shortname, not the name that was sent —
            # a fake that echoed the name would let a consumer address the wrong thing.
            {:ok,
             %{
               "account" => name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
               "type" => Keyword.get(opts, :type, "exchange")
             }}
          end

        _missing ->
          {:error, :name_required}
      end
    end)
  end

  @impl true
  def rename_account(id, name, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # Only the fields that changed come back, as the venue documents.
        {:ok, %{"name" => name, "account" => id}}
      end
    end)
  end

  @impl true
  def get_roles(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # Trader and Fund Manager combined, and Auditor false — the combination the venue
        # allows. One role field would not be able to say this.
        {:ok, %{"isAuditor" => false, "isFundManager" => true, "isTrader" => true}}
      end
    end)
  end
end
