defmodule DpExchange.Gemini.TickAcDecodersTest do
  @moduledoc """
  Decoder robustness (tick AC): hostile or malformed venue payloads through every decoder.

  Each test names the value that used to pass or raise. All of them drive the real decoders
  (`WsDecode`, `Socket.handle_frame/2`, `Rest`, `Private`) with in-process fakes only; nothing
  reaches the venue.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.{Order, Trade}
  alias DpExchange.Gemini.{Fake, Private, Rest, Socket, WsChannels, WsDecode}

  @moduletag :capture_log

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

  @ns 1_787_936_147_000_000_000
  @observed ~U[2026-10-14 12:00:00Z]
  @date "Fri, 28 Aug 2026 17:00:01 GMT"
  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  # 2026-08-24 00:00:00 UTC, on a daily boundary.
  @day_ms 1_787_270_400_000

  defp json(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp public_opts(body), do: [plug: json(body), retry_attempts: 0]

  # --- WsDecode ---------------------------------------------------------------------------

  describe "WsDecode: an event time in another unit is not a time" do
    # 1_787_936_147_000 is a 2026 timestamp in MILLISECONDS. Read as nanoseconds it is
    # 00:29:47 on 1 January 1970, a perfectly valid DateTime.
    @ms 1_787_936_147_000
    @us 1_787_936_147_000_000

    test "a trade stamped in milliseconds or microseconds is refused, not dated 1970" do
      for wrong <- [@ms, @us, 1, 99_999_999_999_999_999] do
        frame = %{"E" => wrong, "p" => "10", "q" => "1", "m" => true}

        assert {:error, :missing_venue_timestamp} = WsDecode.to_trade(frame, "BTC-USD")
      end

      assert {:ok, %Trade{}} =
               WsDecode.to_trade(%{"E" => @ns, "p" => "10", "q" => "1", "m" => true}, "BTC-USD")
    end

    test "a depth diff stamped in milliseconds is refused" do
      frame = %{"E" => @ms, "u" => 5, "b" => [["1", "1"]], "a" => []}

      assert {:error, :missing_venue_timestamp} = WsDecode.to_order_book_delta(frame, "BTC-USD")
    end

    test "a bookTicker stamped in milliseconds has no venue_time, not a 1970 one" do
      frame = %{"b" => "1", "a" => "2", "E" => @ms}

      assert {:ok, top} = WsDecode.to_top_of_book(frame, "BTC-USD", @observed)
      assert top.venue_time == nil
    end

    test "a nanosecond string in range is still read" do
      frame = %{"b" => "1", "a" => "2", "E" => Integer.to_string(@ns)}

      assert {:ok, top} = WsDecode.to_top_of_book(frame, "BTC-USD", @observed)
      assert top.venue_time == DateTime.from_unix!(@ns, :nanosecond)
    end
  end

  describe "WsDecode: a size or price at or below zero is not a level or a print" do
    test "a trade of zero or negative quantity is refused" do
      for quantity <- ["0", "0.0", "-1", "-0.5"] do
        frame = %{"E" => @ns, "p" => "10", "q" => quantity, "m" => false}

        assert {:error, {:non_positive_quantity, :quantity, ^quantity}} =
                 WsDecode.to_trade(frame, "BTC-USD")
      end
    end

    test "a bookTicker size below zero refuses the book; zero and absent do not" do
      for size <- ["-1", "-0.0001"] do
        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(
                   %{"b" => "1", "a" => "2", "B" => size},
                   "BTC-USD",
                   @observed
                 )

        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(
                   %{"b" => "1", "a" => "2", "A" => size},
                   "BTC-USD",
                   @observed
                 )
      end

      assert {:ok, top} =
               WsDecode.to_top_of_book(
                 %{"b" => "1", "a" => "2", "B" => "0", "A" => ""},
                 "BTC-USD",
                 @observed
               )

      assert Decimal.equal?(top.bid_size, 0)
      assert top.ask_size == nil
    end

    test "a snapshot level priced at or below zero, or sized below zero, refuses the book" do
      for row <- [["0", "1"], ["-5", "1"], ["100", "-1"]] do
        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(%{"bids" => [row], "asks" => []}, "BTC-USD", @observed)

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(%{"bids" => [], "asks" => [row]}, "BTC-USD", @observed)
      end

      assert {:ok, book} =
               WsDecode.to_order_book(
                 %{"bids" => [["100", "0"]], "asks" => []},
                 "BTC-USD",
                 @observed
               )

      assert [{_price, quantity}] = book.bids
      assert Decimal.equal?(quantity, 0)
    end

    test "a diff row at or below zero price or below zero size refuses the frame" do
      for row <- [["0", "1"], ["-5", "1"], ["100", "-1"]] do
        frame = %{"E" => @ns, "u" => 5, "b" => [row], "a" => []}

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_delta(frame, "BTC-USD")
      end

      frame = %{"E" => @ns, "u" => 5, "b" => [["100", "0"]], "a" => []}
      assert {:ok, delta} = WsDecode.to_order_book_delta(frame, "BTC-USD")
      assert [{:bid, _price, quantity}] = delta.levels
      assert Decimal.equal?(quantity, 0)
    end
  end

  describe "WsDecode: the update id is a whole number or absent" do
    test "a snapshot whose lastUpdateId is text or an object is refused" do
      for bad <- ["abc", "5", %{"x" => 1}, -1, 1.5] do
        frame = %{"lastUpdateId" => bad, "bids" => [], "asks" => []}

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(frame, "BTC-USD", @observed)
      end

      assert {:ok, %{sequence: nil}} =
               WsDecode.to_order_book(%{"bids" => [], "asks" => []}, "BTC-USD", @observed)

      assert {:ok, %{sequence: 0}} =
               WsDecode.to_order_book(
                 %{"lastUpdateId" => 0, "bids" => [], "asks" => []},
                 "BTC-USD",
                 @observed
               )
    end

    test "a depth anchor and a diff whose u is not a whole number are refused" do
      for bad <- ["7", %{"x" => 1}, -3] do
        frame = %{"E" => @ns, "u" => bad, "b" => [], "a" => []}

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_from_depth_update(frame, "BTC-USD", @observed)

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_delta(frame, "BTC-USD")
      end
    end
  end

  describe "WsDecode: a frame that is not an object is refused, not raised on" do
    test "to_top_of_book/3 and to_order_book_delta/2" do
      for frame <- [[], [1, 2], "text", 5, nil] do
        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(frame, "BTC-USD", @observed)

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_delta(frame, "BTC-USD")
      end
    end
  end

  describe "WsChannels.address/2: a symbol is text" do
    test "a map or an atom is refused, not raised on or spelled" do
      assert {:error, {:invalid_symbol, %{"a" => 1}}} =
               WsChannels.address(:book_ticker, %{"a" => 1})

      assert {:error, {:invalid_symbol, :btcusd}} = WsChannels.address(:trade, :btcusd)
      assert {:ok, "btcusd@trade"} = WsChannels.address(:trade, "btcusd")
      assert {:ok, "orders@account"} = WsChannels.address(:orders_account)
    end
  end

  # --- Socket -----------------------------------------------------------------------------

  describe "Socket: a notice quotes the venue's symbol bounded" do
    defp socket_state do
      %{
        subscriber: self(),
        request_id: 0,
        connected_once?: false,
        last_heard_at: nil,
        liveness: nil
      }
    end

    defp deliver(payload) do
      Socket.handle_frame({:text, Jason.encode!(payload)}, socket_state())
    end

    @trade_frame %{"e" => "trade", "E" => @ns, "t" => 1, "p" => "1", "q" => "1"}

    test "a trade whose s is an object notices a bounded string, not the object" do
      hostile = %{"a" => List.duplicate("x", 500), "b" => %{"c" => 1}}

      assert {:ok, _state} = deliver(Map.put(@trade_frame, "s", hostile))

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :data_quality, details: %{reason: :undecodable_trade} = d}}

      assert is_binary(d.symbol)
      assert byte_size(d.symbol) < 200
    end

    test "a depth diff whose s is an object notices a bounded string" do
      hostile = %{"a" => List.duplicate("x", 500)}

      assert {:ok, _state} =
               deliver(%{"e" => "depthUpdate", "U" => 1, "u" => 2, "s" => hostile})

      assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality, details: details}}

      assert details.reason == :undecodable_depth_update
      assert is_binary(details.symbol)
      assert byte_size(details.symbol) < 200
    end

    test "a depth diff with no U and an object s notices a bounded string" do
      hostile = %{"a" => List.duplicate("x", 500)}

      assert {:ok, _state} = deliver(%{"e" => "depthUpdate", "s" => hostile})

      assert_received {:dp_exchange, :gemini,
                       %Notice{details: %{reason: :undecodable_depth_update} = d}}

      assert is_binary(d.symbol)
    end

    test "an absent s is still nil" do
      assert {:ok, _state} = deliver(@trade_frame)

      assert_received {:dp_exchange, :gemini,
                       %Notice{details: %{reason: :undecodable_trade, symbol: nil}}}
    end

    test "a trade stamped in milliseconds is noticed, not delivered as a 1970 print" do
      frame = %{
        "e" => "trade",
        "E" => 1_787_936_147_000,
        "s" => "btcusd",
        "t" => 1,
        "p" => "1",
        "q" => "1",
        "m" => true
      }

      assert {:ok, _state} = deliver(frame)

      assert_received {:dp_exchange, :gemini,
                       %Notice{details: %{reason: :undecodable_trade, symbol: "BTC-USD"}}}

      refute_received {:dp_exchange, :gemini, %Trade{}}
    end
  end

  # --- Rest -------------------------------------------------------------------------------

  describe "Rest.get_trades/2" do
    @trade %{
      "tid" => 1,
      "timestampms" => 1_787_936_377_000,
      "price" => "100",
      "amount" => "1",
      "type" => "buy"
    }

    test "a quantity of zero or less refuses the reply" do
      for amount <- ["0", "-2", "0.000"] do
        body = [%{@trade | "amount" => amount}]

        assert {:error, {:non_positive_quantity, :quantity, ^amount}} =
                 Rest.get_trades("BTC-USD", public_opts(body))
      end
    end

    test "a broken flag that is not a boolean refuses the print instead of passing it as good" do
      for flag <- ["true", 1, "yes", %{"a" => 1}] do
        body = [Map.put(@trade, "broken", flag)]

        assert {:error, {:invalid_broken_flag, ^flag}} =
                 Rest.get_trades("BTC-USD", public_opts(body))
      end

      assert {:ok, [_good]} =
               Rest.get_trades("BTC-USD", public_opts([Map.put(@trade, "broken", false)]))

      assert {:ok, []} =
               Rest.get_trades("BTC-USD", public_opts([Map.put(@trade, "broken", true)]))
    end
  end

  describe "Rest.get_order_book/2" do
    test "a level priced at or below zero, or sized below zero, refuses the book" do
      for row <- [
            %{"price" => "0", "amount" => "1"},
            %{"price" => "-5", "amount" => "1"},
            %{"price" => "100", "amount" => "-1"}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_order_book("BTC-USD", public_opts(%{"bids" => [row], "asks" => []}))

        assert {:error, :unexpected_response_shape} =
                 Rest.get_order_book("BTC-USD", public_opts(%{"bids" => [], "asks" => [row]}))
      end
    end

    test "a level of zero size is still a level the venue stated" do
      body = %{"bids" => [%{"price" => "100", "amount" => "0"}], "asks" => []}

      assert {:ok, %{bids: [{_price, size}]}} = Rest.get_order_book("BTC-USD", public_opts(body))
      assert Decimal.equal?(size, 0)
    end
  end

  describe "Rest.get_historical_prices/4: a candle this package cannot trust" do
    defp candles(row), do: Rest.get_historical_prices("BTC-USD", "1d", [], public_opts([row]))

    test "a volume the venue sent and this package cannot read refuses the series" do
      for volume <- ["NaN", "abc", %{"x" => 1}, true] do
        row = [@day_ms, "1.5", "2.5", "1.0", "2.0", volume]

        assert {:error, {:invalid_decimal, :volume, ^volume}} = candles(row)
      end
    end

    test "a negative volume refuses the series" do
      row = [@day_ms, "1.5", "2.5", "1.0", "2.0", "-3"]

      assert {:error, {:negative_volume, "-3"}} = candles(row)
    end

    test "an absent or zero volume is still a bar" do
      assert {:ok, [bar]} = candles([@day_ms, "1.5", "2.5", "1.0", "2.0", nil])
      assert bar.volume == nil

      assert {:ok, [bar]} = candles([@day_ms, "1.5", "2.5", "1.0", "2.0", 0])
      assert Decimal.equal?(bar.volume, 0)
    end

    test "a bar whose low is above its high refuses the series" do
      row = [@day_ms, "1.5", "2.0", "3.0", "2.0", "1"]

      assert {:error, {:inconsistent_candle, opened_at}} = candles(row)
      assert opened_at == DateTime.from_unix!(@day_ms, :millisecond)
    end
  end

  describe "Rest.get_funding/2 and get_contract_stats/2: a figure sent and unreadable" do
    test "an unreadable funding amount refuses the reply, not a nil amount" do
      for body <- [
            %{"symbol" => "BTCGUSDPERP", "amount" => "NaN"},
            %{"symbol" => "BTCGUSDPERP", "fundingAmount" => "abc"},
            %{"symbol" => "BTCGUSDPERP", "amount" => "1", "estimatedFundingAmount" => "x"}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_funding("BTCGUSDPERP", public_opts(body))
      end
    end

    test "a symbol that is not text refuses the reply; an absent one is the caller's" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_funding("BTCGUSDPERP", public_opts(%{"symbol" => 5, "amount" => "1"}))

      assert {:ok, %{symbol: "BTCGUSDPERP"}} =
               Rest.get_funding("BTCGUSDPERP", public_opts(%{"amount" => "1"}))
    end

    test "an unreadable contract price, or a product type that is not text, refuses the reply" do
      for body <- [
            %{"mark_price" => "abc"},
            %{"index_price" => "NaN"},
            %{"open_interest" => %{"x" => 1}},
            %{"open_interest_notional" => true},
            %{"product_type" => 5},
            %{"symbol" => %{"x" => 1}}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_contract_stats("BTCGUSDPERP", public_opts(body))
      end

      assert {:ok, %{mark_price: nil}} =
               Rest.get_contract_stats("BTCGUSDPERP", public_opts(%{"index_price" => "1"}))
    end
  end

  describe "Rest.quantization/2 and get_market_overview/1" do
    @details %{
      "quote_increment" => "0.01",
      "tick_size" => "0.00000001",
      "min_order_size" => "0.00001",
      "status" => "open"
    }

    test "an increment of zero or less is no step, and a negative minimum is refused" do
      for {key, value} <- [
            {"tick_size", "0"},
            {"tick_size", "-0.1"},
            {"quote_increment", "0"},
            {"quote_increment", "-1"},
            {"min_order_size", "-1"}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Rest.quantization("BTC-USD", public_opts(Map.put(@details, key, value)))
      end

      assert {:ok, %{min_quantity: min}} =
               Rest.quantization("BTC-USD", public_opts(%{@details | "min_order_size" => "0"}))

      assert Decimal.equal?(min, 0)
    end

    test "a negative overview price refuses it; zero (a pair that has not traded) does not" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_market_overview(public_opts([%{"pair" => "BTCUSD", "price" => "-5"}]))

      assert {:ok, %{"BTC-USD" => %{price: price}}} =
               Rest.get_market_overview(public_opts([%{"pair" => "BTCUSD", "price" => "0"}]))

      assert Decimal.equal?(price, 0)
    end

    test "list_instruments/1 refuses a currency code that is not text" do
      for field <- ["base_currency", "quote_currency"] do
        body = %{
          "symbol" => "btcusd",
          "base_currency" => "BTC",
          "quote_currency" => "USD",
          "product_type" => "spot",
          "status" => "open"
        }

        opts = [symbols: ["BTC-USD"]] ++ public_opts(Map.put(body, field, %{"x" => 1}))

        assert {:error,
                {:instrument_detail_failed, "BTC-USD", {:error, :unexpected_response_shape}}} =
                 Rest.list_instruments(opts)
      end
    end
  end

  # --- Private ----------------------------------------------------------------------------

  describe "Private: fills" do
    @fill %{
      "order_id" => "1",
      "tid" => "2",
      "price" => "100",
      "amount" => "0.5",
      "type" => "Buy",
      "timestampms" => 1_787_936_147_000
    }

    defp fills(row),
      do: Private.get_trade_history(@credentials, [symbol: "BTC-USD"] ++ public_opts([row]))

    test "a price or quantity of zero or less refuses the page" do
      for price <- ["0", "-1"] do
        assert {:error, {:non_positive_price, :price, ^price}} =
                 fills(%{@fill | "price" => price})
      end

      for amount <- ["0", "-0.5"] do
        assert {:error, {:non_positive_quantity, :quantity, ^amount}} =
                 fills(%{@fill | "amount" => amount})
      end

      assert {:ok, [_fill]} = fills(@fill)
    end

    test "a timestamp with an exponent no epoch has is refused without building the integer" do
      # `1e100` decodes under decimal 2 and 3 alike; the exponent bound keeps the read from
      # building a 100-digit integer first (a billion digits for the exponent decimal 2 allows).
      bytes =
        ~s([{"order_id": "1", "tid": "2", "price": "100", "amount": "0.5", "type": "Buy", ) <>
          ~s("timestampms": 1e100}])

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, bytes)
      end

      assert {:error, {:unparseable_venue_timestamp, _value}} =
               Private.get_trade_history(@credentials,
                 symbol: "BTC-USD",
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "Private: an order's flags are booleans" do
    @order %{
      "order_id" => "1234",
      "symbol" => "btcusd",
      "side" => "buy",
      "type" => "exchange limit",
      "price" => "100.00",
      "original_amount" => "1",
      "executed_amount" => "0",
      "avg_execution_price" => "0.00",
      "is_live" => true,
      "is_cancelled" => false,
      "timestampms" => 1_787_936_147_000
    }

    test "a flag that is a string or a number refuses the read" do
      for {key, value} <- [
            {"is_live", "true"},
            {"is_live", 1},
            {"is_cancelled", "true"},
            {"is_cancelled", %{"x" => 1}}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_order(
                   @credentials,
                   "1234",
                   public_opts(Map.put(@order, key, value))
                 )
      end

      assert {:ok, %Order{status: :open}} =
               Private.get_order(@credentials, "1234", public_opts(@order))
    end

    test "a placement stays lenient: its order is already live at the venue" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "1",
        price: "100.00",
        order_type: :limit,
        time_in_force: :gtc
      }

      for {key, value} <- [{"is_live", "true"}, {"price", "abc"}, {"timestampms", "soon"}] do
        assert {:ok, %Order{id: "1234"}} =
                 Private.place_order(
                   @credentials,
                   request,
                   public_opts(Map.put(@order, key, value))
                 )
      end

      assert {:ok, %Order{id: "1234", price: nil}} =
               Private.place_order(
                 @credentials,
                 request,
                 public_opts(Map.put(@order, "price", "abc"))
               )
    end
  end

  describe "Private: positions, FX rates, fee estimates and approved addresses" do
    test "a price or P&L the venue sent and this package cannot read refuses the row" do
      row = %{"symbol" => "BTCGUSDPERP", "quantity" => "0.2"}

      for {key, value} <- [
            {"mark_price", "abc"},
            {"average_cost", "NaN"},
            {"notional_value", %{"x" => 1}},
            {"realised_pnl", true},
            {"unrealised_pnl", "1e999999"}
          ] do
        body = %{"openPositions" => [Map.put(row, key, value)]}

        assert {:error, :unexpected_response_shape} =
                 Private.get_positions(@credentials, public_opts(body))
      end

      assert {:ok, [%{mark_price: nil}]} =
               Private.get_positions(@credentials, public_opts(%{"openPositions" => [row]}))
    end

    test "an FX rate of zero or less is refused" do
      for rate <- ["0", "-0.69"] do
        body = %{"fxPair" => "AUDUSD", "rate" => rate, "asOf" => 1_594_651_859_000}

        assert {:error, {:non_positive_rate, :rate, ^rate}} =
                 Private.get_fx_rate(
                   "AUDUSD",
                   ~U[2020-07-13 15:30:59Z],
                   [credentials: @credentials] ++ public_opts(body)
                 )
      end
    end

    test "a fee currency that is not text is nil" do
      assert {:ok, %{fee_currency: nil}} =
               Private.estimate_withdrawal_fee(
                 "ETH",
                 "ethereum",
                 Decimal.new("0.01"),
                 @credentials,
                 [address: "0xabc"] ++ public_opts(%{"fee" => "0.001", "currency" => %{"x" => 1}})
               )
    end

    test "an approved address's network that is not text is the one asked for" do
      body = [%{"address" => "0xabc", "network" => %{"x" => 1}, "status" => "active"}]

      assert {:ok, [entry]} =
               Private.list_approved_addresses(
                 @credentials,
                 [network: "ethereum"] ++ public_opts(body)
               )

      assert entry.network == "ethereum"
    end
  end

  # --- Fake -------------------------------------------------------------------------------

  describe "Fake.get_historical_prices/4" do
    test "a :start in the last day of year 9999 is an empty list, not a raise" do
      range = [start: ~U[9999-12-31 23:59:59Z]]

      assert {:ok, []} = Fake.get_historical_prices("BTC-USD", "1d", range)
      assert {:ok, []} = Fake.get_historical_prices("BTC-USD", "1m", range)
    end
  end
end
