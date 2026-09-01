defmodule DpExchange.Gemini.FakeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Core.Types.{OrderBook, Quote}
  alias DpExchange.Gemini.Fake

  @credentials %{api_key: "k", api_secret: "s"}

  # Inside the visibility window the real endpoint enforces, so a candle assertion is not
  # accidentally testing the window check.
  defp within_window do
    [start: DateTime.add(DateTime.utc_now(), -60 * 60, :second), end: DateTime.utc_now()]
  end

  describe "less capable is allowed; differently capable is not" do
    test "it declares the REAL venue's capabilities" do
      # A fake declaring different capabilities from the venue it stands in for is a fake
      # a consumer cannot use to test capability branching.
      assert Fake.capabilities() == DpExchange.Gemini.capabilities()
    end

    test "an unsupported endpoint errors rather than returning an empty success" do
      # `{:ok, []}` for something unsupported is the silent failure: the caller gets a
      # plausible answer and never learns the question was not answered.
      assert Fake.list_instruments([]) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(%{}, []) == {:error, :not_supported}
    end

    test "an account call with no credentials refuses rather than answering emptily" do
      # A fake that accepted `nil` would let a consumer's test pass while the real call
      # fails on a missing key — differently capable, which is the forbidden kind.
      assert Fake.get_balances(%{}, []) == {:refused, :missing_credentials}
      assert Fake.get_accounts(%{}, []) == {:refused, :missing_credentials}
    end

    test "it never stamps the current clock" do
      # A fake that stamps `utc_now/0` cannot be used to test anything about freshness,
      # and is itself the substitution this family refuses.
      {:ok, first} = Fake.get_price("BTC-USD")
      Process.sleep(5)
      {:ok, second} = Fake.get_price("BTC-USD")

      assert first.timestamp == second.timestamp
    end
  end

  describe "it models the venue's refusals, not only its successes" do
    test "an unlisted symbol is a refusal, not an error" do
      assert Fake.get_price("NOPE-USD") == {:refused, :not_listed}
      assert Fake.get_order_book("NOPE-USD") == {:refused, :not_listed}
      assert Fake.quantization("NOPE-USD") == {:refused, :not_listed}
    end

    test "a width the venue does not serve is an error" do
      for width <- ~w(2h 4h 12h) do
        assert {:error, {:unsupported_timeframe, ^width}} =
                 Fake.get_historical_prices("BTC-USD", width)
      end
    end

    test "a range before the fixed window is refused, as the real endpoint's would be" do
      # This venue's distinctive failure mode. A consumer that has not handled it finds
      # out here rather than in production.
      long_ago = ~U[2020-01-01 00:00:00Z]

      assert {:error, {:range_unavailable, "1d", _details}} =
               Fake.get_historical_prices("BTC-USD", "1d", start: long_ago)
    end

    test "a range inside the window succeeds" do
      recent = ~U[2026-08-27 00:00:00Z]

      assert {:ok, [_candle]} = Fake.get_historical_prices("BTC-USD", "1d", start: recent)
    end
  end

  describe "the shapes it returns are the real ones" do
    test "a quote is a Quote with Decimals" do
      assert {:ok, %Quote{} = quote_struct} = Fake.get_price("BTC-USD")
      assert %Decimal{} = quote_struct.price
      assert quote_struct.provider == :gemini
    end

    test "a book is an OrderBook with Decimal level tuples" do
      assert {:ok, %OrderBook{bids: [{price, size}]}} = Fake.get_order_book("BTC-USD")
      assert %Decimal{} = price
      assert %Decimal{} = size
    end

    test "its symbols include the overlapping-quote pairs that break naive splitting" do
      assert {:ok, symbols} = Fake.get_symbols()
      assert "BTC-GUSD" in symbols
      assert "SOL-RLUSD" in symbols
    end
  end

  describe "streaming in memory" do
    test "subscribing delivers immediately, as the venue's first frame does" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}
    end

    test "coverage reports only what it actually pushed" do
      :ok = Fake.subscribe(["BTC-USD", "NOPE-USD"], to: self())

      assert Fake.coverage() == %{"BTC-USD" => :stream}
    end

    test "unsubscribing removes it from coverage" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())
      :ok = Fake.unsubscribe(["BTC-USD"])

      assert Fake.coverage() == %{}
    end
  end

  describe "lifecycle" do
    test "it starts nothing" do
      assert Fake.start_link([]) == :ignore
    end
  end

  describe "order lifecycle in memory" do
    test "get_order/3 answers with the id it was asked about" do
      assert {:ok, order} = Fake.get_order(@credentials, "abc-123", [])
      assert order.id == "abc-123"
    end

    test "cancel_order/3 reports the order cancelled" do
      assert {:ok, order} = Fake.cancel_order(@credentials, "abc-123", [])
      assert order.id == "abc-123"
      assert order.status == :cancelled
    end

    test "both refuse without credentials, as the real adapter does" do
      assert Fake.get_order(%{}, "abc-123", []) == {:refused, :missing_credentials}
      assert Fake.cancel_order(%{}, "abc-123", []) == {:refused, :missing_credentials}
    end

    test "a placed order carries the caller's own values back, unrewritten" do
      # The fake never rewrites what the caller supplied — the rule that stops a fake
      # being usable to prove something the real venue would not do.
      request = %{
        symbol: "ETH-USD",
        side: :sell,
        quantity: "2",
        price: "3000",
        order_type: :limit
      }

      assert {:ok, order} = Fake.place_order(@credentials, request, [])
      assert order.symbol == "ETH-USD"
      assert order.side == :sell
      assert Decimal.equal?(order.price, Decimal.new("3000"))
    end
  end

  describe "it refuses exactly what the real venue refuses" do
    test "every endpoint declared :unsupported returns the atom" do
      # This is the sweep. Without it the fake can drift from the declaration one callback
      # at a time, and each drift is a consumer's suite passing on a call that cannot be
      # made — which is what a fake is for preventing.
      unsupported =
        for {{name, arity}, :unsupported} <- DpExchange.Gemini.capabilities().endpoints,
            name not in [:child_spec, :start_link],
            do: {name, arity}

      refute unsupported == []

      for {name, arity} <- unsupported do
        assert apply(Fake, name, fake_args(arity)) == {:error, :not_supported},
               "Fake.#{name}/#{arity} does not refuse, and the declaration says it should"
      end
    end
  end

  defp fake_args(1), do: [[]]
  defp fake_args(2), do: [@credentials, []]
  defp fake_args(3), do: [@credentials, "id", []]
  defp fake_args(4), do: [@credentials, "id", %{}, []]
  defp fake_args(5), do: [@credentials, "id", "network", Decimal.new("1"), []]

  describe "candles are bars, not quotes" do
    test "a candle carries all four prices" do
      assert {:ok, [bar]} = Fake.get_historical_prices("BTC-USD", "1m", within_window())

      assert %Types.Candle{} = bar
      assert bar.timeframe == "1m"
      assert Types.Candle.coherent?(bar)
      assert bar.provider == :gemini
    end
  end

  describe "bulk cancel" do
    test "no scope is an error, as it is on the real venue" do
      assert {:error, :scope_required} = Fake.cancel_all_orders(@credentials, [])
    end

    test "a scope the venue does not have is an error" do
      assert {:error, {:unsupported_scope, :everything}} =
               Fake.cancel_all_orders(@credentials, scope: :everything)
    end

    test "either scope answers with the venue's two lists" do
      assert {:ok, %{cancelled: [_id], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :session)

      assert {:ok, %{cancelled: [_id2], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :account)
    end

    test "it refuses without credentials, as every account call does" do
      assert {:refused, :missing_credentials} = Fake.cancel_all_orders(%{}, scope: :session)
    end
  end

  describe "orders: resting and closed are different questions" do
    test "asking without saying gets the resting ones" do
      assert {:ok, []} = Fake.get_orders(@credentials, [])
    end

    test "asking for history gets closed ones" do
      assert {:ok, [order]} = Fake.get_orders(@credentials, history: true)
      assert order.status == :filled
    end
  end

  describe "conversions" do
    test "the fake refuses the direction the real package refuses" do
      # This venue quotes in crypto as well as fiat, so USD -> BTC is genuinely ambiguous
      # and only the catalogue resolves it. A fake that picked one would let a consumer's
      # suite pass on a conversion that spends the wrong asset.
      assert {:error, {:ambiguous_conversion, "USD", "BTC"}} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("100"), credentials: @credentials)
    end

    test "an explicit symbol and side get a quote with a real window" do
      assert {:ok, conversion} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("100"),
                 symbol: "BTC-USD",
                 side: :buy,
                 credentials: @credentials
               )

      assert conversion.status == :quoted
      assert conversion.expires_at
      refute Types.Conversion.expired?(conversion, conversion.venue_time)
    end

    test "committing needs the terms the venue quoted against" do
      assert {:error, {:missing_option, [:symbol, :side, :amount, :price]}} =
               Fake.commit_conversion("q-1", credentials: @credentials)
    end

    test "a committed conversion is settled" do
      assert {:ok, conversion} =
               Fake.commit_conversion("q-1",
                 symbol: "BTC-USD",
                 side: :buy,
                 amount: Decimal.new("1"),
                 price: Decimal.new("40000"),
                 credentials: @credentials
               )

      assert conversion.status == :settled
    end

    test "convert/4 settles in one step and holds no rate" do
      assert {:ok, conversion} =
               Fake.convert("GUSD", "USD", Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :sell,
                 credentials: @credentials
               )

      assert conversion.status == :settled
      # No window, so `expired?/2` reports unknown rather than a boolean to act on.
      assert Types.Conversion.expired?(conversion, DateTime.utc_now()) == nil
    end

    test "every conversion call refuses without credentials" do
      assert {:refused, :missing_credentials} =
               Fake.convert("GUSD", "USD", Decimal.new("1"), symbol: "GUSD-USD", side: :sell)

      assert {:refused, :missing_credentials} = Fake.commit_conversion("q-1", [])
    end
  end

  describe "the account's own traded volume" do
    test "rows come back under the venue's own field names" do
      assert {:ok, [row]} = Fake.get_trade_volume(@credentials, [])
      assert row["symbol"] == "btcusd"
    end

    test "it refuses without credentials" do
      assert {:refused, :missing_credentials} = Fake.get_trade_volume(%{}, [])
    end
  end
end
