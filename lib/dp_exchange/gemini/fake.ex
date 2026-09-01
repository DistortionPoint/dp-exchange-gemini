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

    * a symbol it does not carry, with `{:refused, :not_listed}` — permanent, and
      distinct from a transient error;
    * a timeframe Gemini does not serve, including `2h`, `4h` and `12h`, which the shared
      vocabulary models and this venue does not;
    * a range reaching **before the venue's fixed window**, with `{:range_unavailable,
      …}` rather than a short answer — because the real endpoint ignores bounds entirely
      and a truncated result reads as a complete one.

  That last one is this venue's distinctive failure mode, and a consumer that has not
  handled it will find out here rather than in production.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Notice, Timeframe, Types, Venue}
  alias DpExchange.Gemini.Rest

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
        {:refused, :not_listed}
    end
  end

  @impl true
  def get_top_of_book(symbol, _opts \\ []) do
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
        {:refused, :not_listed}
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], _opts \\ []) do
    cond do
      symbol not in @symbols ->
        {:refused, :not_listed}

      timeframe not in Rest.timeframes() ->
        # Includes `2h`, `4h` and `12h` — modelled by the vocabulary, not served here.
        {:error, {:unsupported_timeframe, timeframe}}

      before_window?(timeframe, range) ->
        {:error, {:range_unavailable, timeframe, earliest: earliest(timeframe)}}

      true ->
        {:ok, [candle(symbol, timeframe)]}
    end
  end

  @impl true
  def get_symbols(_opts \\ []), do: {:ok, @symbols}

  @impl true
  def get_order_book(symbol, _opts \\ []) do
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
        {:refused, :not_listed}
    end
  end

  @impl true
  def get_market_overview(_opts \\ []) do
    {:ok,
     Map.new(@symbols, fn symbol ->
       {symbol, %{price: Decimal.new(@price[symbol]), change_24h: Decimal.new("-0.0424")}}
     end)}
  end

  @impl true
  def quantization(symbol) do
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
        {:refused, :not_listed}
    end
  end

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  # --- account and trading, in memory -------------------------------------
  #
  # Credentials are an argument here exactly as in the real adapter. The fake checks that
  # something credential-shaped arrived and otherwise refuses — a fake that accepted `nil`
  # would let a consumer's test pass while the real call fails on a missing key.

  @impl true
  def get_balances(credentials, _opts \\ []) do
    with :ok <- authenticated(credentials) do
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
  end

  @impl true
  def get_accounts(credentials, _opts \\ []) do
    with :ok <- authenticated(credentials) do
      {:ok, [%{"account" => "primary", "type" => "exchange"}]}
    end
  end

  @impl true
  def get_fees(credentials, _opts \\ []) do
    with :ok <- authenticated(credentials) do
      {:ok, %{"api_maker_fee_bps" => 10, "api_taker_fee_bps" => 35}}
    end
  end

  @impl true
  def get_transfers(credentials, _opts \\ []) do
    with :ok <- authenticated(credentials), do: {:ok, []}
  end

  @impl true
  def place_order(credentials, request, _opts \\ []) do
    # The refusals matter more than the success. A fake where every order works proves
    # only that the happy path compiles.
    with :ok <- authenticated(credentials),
         :ok <- supported_order_type(Map.get(request, :order_type, :limit)),
         :ok <- supported_tif(Map.get(request, :time_in_force, :gtc)),
         :ok <- priced(request),
         :ok <- listed(Map.get(request, :symbol)) do
      {:ok, order(request)}
    end
  end

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
  def cancel_order(credentials, order_id, _opts \\ []) do
    with :ok <- authenticated(credentials) do
      {:ok, %{order(%{}) | id: order_id, status: :cancelled}}
    end
  end

  @impl true
  def get_order(credentials, order_id, _opts \\ []) do
    with :ok <- authenticated(credentials) do
      {:ok, %{order(%{}) | id: order_id}}
    end
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    # Open and historical are two endpoints on this venue, not one with a filter, and the
    # fake says so rather than answering the same empty list to both.
    with :ok <- authenticated(credentials) do
      if Keyword.get(opts, :history, false),
        do: {:ok, [%{order(%{}) | status: :filled}]},
        else: {:ok, []}
    end
  end

  @impl true
  def cancel_all_orders(credentials, opts \\ []) do
    # The fake enforces the contract's rule, so a consumer's suite cannot go green on a
    # bulk cancel that never said which orders it meant.
    with :ok <- authenticated(credentials) do
      case Keyword.get(opts, :scope) do
        scope when scope in [:session, :account] ->
          {:ok, %{cancelled: ["fake-gemini-order-1"], rejected: []}}

        nil ->
          {:error, :scope_required}

        other ->
          {:error, {:unsupported_scope, other}}
      end
    end
  end

  @impl true
  def get_trade_history(credentials, opts) do
    # The real adapter requires a symbol — Gemini offers no all-symbols variant — so the
    # fake requires one too. Less capable is allowed; differently capable is not.
    with :ok <- authenticated(credentials) do
      case Keyword.get(opts, :symbol) do
        nil -> {:error, {:missing_option, :symbol}}
        _symbol -> {:ok, []}
      end
    end
  end

  defp authenticated(%{api_key: _key, api_secret: _secret}), do: :ok
  defp authenticated(%{access_token: _token}), do: :ok
  defp authenticated(_other), do: {:refused, :missing_credentials}

  # `:market` and `:stop` are refused because the venue serves neither, and reaching the
  # nearest thing would mean choosing a price the caller never supplied.
  defp supported_order_type(type)
       when type in [:limit, :stop_limit, :post_only, :maker_or_cancel, :ioc, :fok],
       do: :ok

  defp supported_order_type(other), do: {:error, {:unsupported_order_type, other}}

  defp supported_tif(tif) when tif in [:gtc, :ioc, :fok], do: :ok
  defp supported_tif(other), do: {:error, {:unsupported_time_in_force, other}}

  defp priced(request) do
    if Map.get(request, :price), do: :ok, else: {:error, {:missing_field, :price}}
  end

  defp listed(symbol) do
    if symbol in @symbols, do: :ok, else: {:refused, :not_listed}
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

  @impl true
  def subscribe_notices(opts \\ []) do
    send(Keyword.get(opts, :to, self()), {:dp_exchange, :gemini, Notice.new(:link_up, :gemini)})
    :ok
  end

  @impl true
  def test_connection(credentials, _opts \\ []) do
    with :ok <- authenticated(credentials), do: {:ok, %{reachable: true}}
  end

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def market_status(_opts), do: {:ok, :open}

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
  def get_positions(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

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
  def create_account(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()
end
