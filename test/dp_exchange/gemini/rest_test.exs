defmodule DpExchange.Gemini.RestTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Gemini.Rest

  @moduletag :capture_log

  # A real limiter answering from configuration, injected through the same process-scoped
  # seam a consumer would use. Not a mock: nothing is stubbed and no call is verified.
  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  defp responding(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    date = Keyword.get(opts, :date, @date)

    fn conn ->
      conn = if date, do: Plug.Conn.put_resp_header(conn, "date", date), else: conn
      Req.Test.json(%{conn | status: status}, body)
    end
  end

  @ticker %{
    "bid" => "77791.77000",
    "ask" => "77791.92000",
    "last" => "77829.80000",
    "volume" => %{
      "BTC" => "183.72081422",
      "USD" => "14298954.22",
      "timestamp" => 1_787_936_340_000
    }
  }

  describe "get_price/2" do
    test "returns a Quote with Decimal numerics" do
      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("77829.80000"))
      assert quote_struct.provider == :gemini
      assert quote_struct.symbol == "BTC-USD"
    end

    test "the book side comes back from get_top_of_book/2, not on the Quote" do
      # One payload, two facts. `Core.Types.Quote` has no bid or ask to put them on, which
      # is what stops a caller reading a resting order as a traded price.
      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(top.bid, Decimal.new("77791.77000"))
      assert Decimal.equal?(top.ask, Decimal.new("77791.92000"))
      assert top.symbol == "BTC-USD"
      assert top.observed_at
      refute Map.has_key?(top, :price)
    end

    test "the timestamp is the venue's Date header, not our clock" do
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert quote_struct.timestamp == ~U[2026-08-28 17:00:01Z]
    end

    test "volume is the BASE asset's, recovered from the symbol" do
      # `/v1/pubticker` keys volume by currency code and reports both sides. Taking the
      # first key would give USD volume for a BTC-USD quote — a number 78,000 times too
      # large that still looks like a volume.
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.volume, Decimal.new("183.72081422"))
    end

    test "a non-numeric last price refuses the quote rather than delivering price: nil" do
      # Decimal.new/1 used to raise here; the fix must not trade a crash for a Quote whose
      # required :price is silently nil, which is the same substitution wearing a
      # different shape.
      body = %{@ticker | "last" => "null"}

      assert {:error, {:invalid_decimal, :price, "null"}} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "an empty-string last price refuses the quote" do
      body = %{@ticker | "last" => ""}

      assert {:error, {:invalid_decimal, :price, ""}} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "a response with NO Date header fails rather than substituting now" do
      # The failure this family is built to refuse. Gemini publishes no quote timestamp in
      # the payload at all, so the header is the only venue-supplied time available — and
      # without it the quote's freshness cannot be stated.
      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD",
                 plug: responding(@ticker, date: nil),
                 retry_attempts: 0
               )
    end

    test "an unparseable Date header also fails" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD",
                 plug: responding(@ticker, date: "not a date"),
                 retry_attempts: 0
               )
    end

    test "the volume timestamp is NOT used as the quote time" do
      # `volume.timestamp` stamps the 24-hour volume window and lags about a minute. It is
      # the only timestamp in the payload, which makes it the obvious thing to reach for
      # and the wrong thing to reach for.
      volume_time = DateTime.from_unix!(1_787_936_340_000, :millisecond)

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      refute quote_struct.timestamp == volume_time
    end

    test "a 400 is a REFUSAL carrying the venue's own reason" do
      # Permanent versus transient is what a caller acts on. Gemini names its reason, so
      # the refusal can carry it rather than flattening to a generic atom.
      body = %{"result" => "error", "reason" => "InvalidSymbol", "message" => "no such symbol"}

      assert {:refused, :invalid_symbol} =
               Rest.get_price("NOPE-USD", plug: responding(body, status: 400), retry_attempts: 0)
    end

    test "a 500 stays an error" do
      assert {:error, _reason} =
               Rest.get_price("BTC-USD", plug: responding(%{}, status: 500), retry_attempts: 0)
    end
  end

  defp to_ms(datetime), do: DateTime.to_unix(datetime, :millisecond)

  describe "get_historical_prices/4 — the fixed window" do
    @candles [
      [1_787_935_740_000, 77_986.74, 77_995.93, 77_908.94, 77_941.47, 0.0],
      [1_787_935_680_000, 77_950.54, 77_981.02, 77_923.57, 77_934.41, 0.04]
    ]

    test "maps canonical widths to the literals the venue actually accepts" do
      # The venue rejects `1h`, `6h` and `1d` — all three of which its own documentation
      # lists. What goes on the wire is `1hr`, `6hr`, `1day`.
      for {canonical, native} <- [{"1h", "1hr"}, {"6h", "6hr"}, {"1d", "1day"}] do
        plug = fn conn ->
          assert String.ends_with?(conn.request_path, "/#{native}")
          Req.Test.json(conn, @candles)
        end

        assert {:ok, _candles} =
                 Rest.get_historical_prices("BTC-USD", canonical, [],
                   plug: plug,
                   retry_attempts: 0
                 )
      end
    end

    test "a width the venue does not serve is an error, never the nearest one" do
      for width <- ~w(2h 4h 12h) do
        assert {:error, {:unsupported_timeframe, ^width}} =
                 Rest.get_historical_prices("BTC-USD", width, [], retry_attempts: 0)
      end
    end

    test "a range starting before the fixed window is REFUSED, not truncated" do
      # The venue ignores bounds and serves a fixed window. Returning what it happens to
      # hold would read as a complete answer for a period it does not serve.
      long_ago = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)

      assert {:error, {:range_unavailable, "1d", _details}} =
               Rest.get_historical_prices("BTC-USD", "1d", [start: long_ago],
                 plug: responding(@candles),
                 retry_attempts: 0
               )
    end

    test "a range inside the window is filtered here, because the venue will not" do
      # Built relative to now, not from a fixed epoch. The `1m` window is 1,440 bars —
      # twenty-four hours — so a hardcoded fixture stops being "inside the window" the
      # day after it is written, and this test failed for exactly that reason three days
      # after it was added. A time-relative fixture cannot rot that way.
      newest = DateTime.utc_now() |> DateTime.add(-60, :second) |> to_ms()
      older = newest - 60_000

      candles = [
        [newest, 77_986.74, 77_995.93, 77_908.94, 77_941.47, 0.0],
        [older, 77_950.54, 77_981.02, 77_923.57, 77_934.41, 0.04]
      ]

      start = DateTime.from_unix!(newest - 40_000, :millisecond)

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [start: start],
                 plug: responding(candles),
                 retry_attempts: 0
               )

      assert candle.opened_at == DateTime.from_unix!(newest, :millisecond)
    end

    test "candles come back oldest-first with Decimal numerics" do
      assert {:ok, [first, second]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], plug: responding(@candles))

      assert DateTime.compare(first.opened_at, second.opened_at) == :lt
      assert Decimal.equal?(first.open, Decimal.from_float(77_950.54))
      assert first.provider == :gemini
    end
  end

  describe "get_symbols/1" do
    test "returns canonical symbols, sorted" do
      assert {:ok, symbols} =
               Rest.get_symbols(plug: responding(~w(btcusd aavegusd solrlusd)), retry_attempts: 0)

      assert symbols == ["AAVE-GUSD", "BTC-USD", "SOL-RLUSD"]
    end

    test "perpetuals are excluded rather than given an invented spot pair" do
      assert {:ok, symbols} =
               Rest.get_symbols(
                 plug: responding(~w(btcusd avaxgusdperp avaxusdcperp)),
                 retry_attempts: 0
               )

      assert symbols == ["BTC-USD"]
    end
  end

  describe "get_order_book/2" do
    @book %{
      "bids" => [%{"price" => "77792.91", "amount" => "0.0031", "timestamp" => "1787936377"}],
      "asks" => [%{"price" => "77792.92", "amount" => "0.0182", "timestamp" => "1787936377"}]
    }

    test "levels are Decimal tuples and the time is the venue's own" do
      # Unlike a quote, the book carries per-level timestamps, so nothing is derived.
      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("BTC-USD", plug: responding(@book), retry_attempts: 0)

      assert [{bid_price, bid_size}] = book.bids
      assert Decimal.equal?(bid_price, Decimal.new("77792.91"))
      assert Decimal.equal?(bid_size, Decimal.new("0.0031"))
      assert book.timestamp == DateTime.from_unix!(1_787_936_377)
      assert book.provider == :gemini
    end

    test "a book with no level timestamps fails rather than guessing" do
      body = %{"bids" => [%{"price" => "1", "amount" => "1"}], "asks" => []}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)
    end
  end

  describe "quantization/1" do
    test "keeps the price and quantity increments apart" do
      # `tick_size` is the BASE increment and `quote_increment` the PRICE increment. The
      # names do not say so, and for btcusd they differ by six orders of magnitude.
      body = %{
        "symbol" => "BTCUSD",
        "tick_size" => 1.0e-8,
        "quote_increment" => 0.01,
        "min_order_size" => "0.00001",
        "status" => "open"
      }

      assert {:ok, quantization} =
               Rest.quantization("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quantization.price_increment, Decimal.from_float(0.01))
      assert Decimal.equal?(quantization.quantity_increment, Decimal.from_float(1.0e-8))
      assert Decimal.equal?(quantization.min_quantity, Decimal.new("0.00001"))
      assert quantization.status == "open"
    end
  end

  describe "get_market_overview/1" do
    test "keys the whole catalogue by canonical symbol in one call" do
      body = [
        %{"pair" => "BTCUSD", "price" => "77845.79", "percentChange24h" => "-0.0424"},
        %{"pair" => "AAVEGUSD", "price" => "141.20", "percentChange24h" => "0.0258"}
      ]

      assert {:ok, overview} = Rest.get_market_overview(plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(overview["BTC-USD"].price, Decimal.new("77845.79"))
      assert Decimal.equal?(overview["AAVE-GUSD"].change_24h, Decimal.new("0.0258"))
    end
  end

  describe "timeframes/0" do
    test "is the seven the venue serves, shortest first" do
      assert Rest.timeframes() == ~w(1m 5m 15m 30m 1h 6h 1d)
    end

    test "excludes every width the venue rejects" do
      for absent <- ~w(2h 4h 12h), do: refute(absent in Rest.timeframes())
    end
  end

  describe "refusals on the remaining endpoints" do
    test "quantization refuses an unlisted symbol rather than erroring" do
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :invalid_symbol} =
               Rest.quantization("NOPE-USD",
                 plug: responding(body, status: 400),
                 retry_attempts: 0
               )
    end

    test "get_symbols surfaces a venue error rather than an empty catalogue" do
      # An empty list would read as "this venue lists nothing", which is a very different
      # claim from "the request failed".
      assert {:error, _reason} =
               Rest.get_symbols(plug: responding(%{}, status: 503), retry_attempts: 0)
    end

    test "get_market_overview surfaces a venue error the same way" do
      assert {:error, _reason} =
               Rest.get_market_overview(plug: responding(%{}, status: 503), retry_attempts: 0)
    end

    test "a candle request for an unlisted symbol is refused" do
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :invalid_symbol} =
               Rest.get_historical_prices("NOPE-USD", "1d", [],
                 plug: responding(body, status: 400),
                 retry_attempts: 0
               )
    end

    test "an order book request for an unlisted symbol is refused" do
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :invalid_symbol} =
               Rest.get_order_book("NOPE-USD",
                 plug: responding(body, status: 400),
                 retry_attempts: 0
               )
    end
  end

  describe "get_fx_rate/3 refuses a non-numeric rate rather than delivering rate: nil" do
    test "Decimal.new/1 used to raise here; now the record is refused" do
      body = %{"rate" => "null", "fxPair" => "GBPUSD"}

      assert {:error, {:invalid_decimal, :rate, "null"}} =
               Rest.get_fx_rate(
                 "GBP-USD",
                 ~U[2026-08-28 17:00:01Z],
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end
end
