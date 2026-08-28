defmodule DpExchange.Gemini.FakeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{OrderBook, Quote}
  alias DpExchange.Gemini.Fake

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
    @credentials %{api_key: "k", api_secret: "s"}

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
end
