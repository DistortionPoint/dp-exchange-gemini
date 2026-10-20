defmodule DpExchange.Gemini.PrivateAuditTest do
  @moduledoc """
  Pins the defects found by auditing `DpExchange.Gemini.Private` against the vendor's
  committed OpenAPI document (`docs/reference/gemini/openapi/rest.yaml`).

  Every test either asserts what goes on the wire or asserts that a refusal happens BEFORE
  anything is sent (a plug that raises stands in for the venue: if the call reached it, the
  result would not be the refusal asserted).
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Conversion, Fill}
  alias DpExchange.Gemini.Private

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

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      payload =
        conn
        |> Plug.Conn.get_req_header("x-gemini-payload")
        |> List.first()
        |> Base.decode64!()
        |> Jason.decode!()

      send(test_pid, {:payload, payload})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp exploding(message \\ "must not reach the venue") do
    fn _conn -> raise message end
  end

  @order_body %{
    "order_id" => "106817811",
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

  @request %{
    symbol: "BTC-USD",
    side: :buy,
    quantity: "1",
    price: "100.00",
    order_type: :limit,
    time_in_force: :gtc
  }

  # A type that carries its own execution option (or takes none) takes no time in force.
  @no_duration Map.delete(@request, :time_in_force)

  describe "order ids go out as the integer the vendor's schema names" do
    # rest.yaml `CancelOrderRequest.order_id` and `OrderStatusRequest.order_id`:
    # `type: integer, format: int64`, "transmitted as an unsigned 64-bit integer in JSON".
    test "cancel_order/3 sends a JSON number" do
      assert {:ok, _order} =
               Private.cancel_order(@credentials, "106817811",
                 plug: capturing(@order_body, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["order_id"] === 106_817_811
      assert payload["request"] == "/v1/order/cancel"
    end

    test "get_order/3 sends a JSON number, including one past the 53-bit float range" do
      assert {:ok, _order} =
               Private.get_order(@credentials, "73751560172006688",
                 plug: capturing(@order_body, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["order_id"] === 73_751_560_172_006_688
    end

    test "an id that is not an unsigned 64-bit whole number is refused before signing" do
      for bad <- ["abc", "-1", "1.5", "", "18446744073709551616", nil, :atom, 1.5, 7] do
        assert {:error, {:invalid_order_id, ^bad}} =
                 Private.cancel_order(@credentials, bad, plug: exploding(), retry_attempts: 0)

        assert {:error, {:invalid_order_id, ^bad}} =
                 Private.get_order(@credentials, bad, plug: exploding(), retry_attempts: 0)
      end
    end
  end

  describe "place_order/3 refuses values it would otherwise put on a live order" do
    test "a side the venue does not know" do
      for bad <- [:hold, "BUY ", 1, "sell-short"] do
        assert {:error, {:invalid_side, ^bad}} =
                 Private.place_order(@credentials, Map.put(@request, :side, bad),
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end

    test "a quantity or price that is not a finite number above zero" do
      cases = [
        {:quantity, Decimal.new("NaN"), :invalid_quantity},
        {:quantity, Decimal.new("Infinity"), :invalid_quantity},
        {:quantity, "abc", :invalid_quantity},
        {:quantity, :one, :invalid_quantity},
        {:quantity, "0", :invalid_quantity},
        {:quantity, Decimal.new("-1"), :invalid_quantity},
        {:quantity, 0.5, :invalid_quantity},
        {:price, "NaN", :invalid_price},
        {:price, "-5", :invalid_price},
        {:price, 0, :invalid_price},
        {:price, 100.5, :invalid_price}
      ]

      for {field, value, tag} <- cases do
        request = Map.put(@request, field, value)

        assert {:error, {^tag, ^value}} =
                 Private.place_order(@credentials, request,
                   plug: exploding(),
                   retry_attempts: 0
                 )

        assert {:error, {^tag, ^value}} = Private.validate_order(request)
      end
    end

    test "an integer or a numeric string is sent in plain notation, never scientific" do
      request = %{@request | quantity: "0.00000001", price: 12_345}

      assert {:ok, _order} =
               Private.place_order(@credentials, request,
                 plug: capturing(@order_body, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["amount"] == "0.00000001"
      assert payload["price"] == "12345"
    end

    test "a stop-limit needs its trigger price" do
      request = Map.put(@no_duration, :order_type, :stop_limit)

      assert {:error, {:missing_field, :stop_price}} =
               Private.place_order(@credentials, request, plug: exploding(), retry_attempts: 0)

      assert {:error, {:missing_field, :stop_price}} = Private.validate_order(request)
    end

    test "a trigger price on any other order type is refused, not sent" do
      # The vendor: "Only available for stop-limit orders." A plain limit order carrying one
      # would not wait for the trigger the caller named.
      for order_type <- [:limit, :post_only, :ioc, :fok] do
        base = if order_type == :limit, do: @request, else: @no_duration
        request = base |> Map.put(:order_type, order_type) |> Map.put(:stop_price, "95")

        assert {:error, {:unexpected_field, :stop_price}} =
                 Private.place_order(@credentials, request,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end

    test "a stop price must itself be a positive number" do
      request =
        @no_duration |> Map.put(:order_type, :stop_limit) |> Map.put(:stop_price, "0")

      assert {:error, {:invalid_stop_price, "0"}} = Private.validate_order(request)

      assert {:error, {:invalid_stop_price, 95.5}} =
               Private.validate_order(%{request | stop_price: 95.5})
    end

    test "a well-formed stop-limit sends the trigger as a plain string" do
      request =
        @no_duration
        |> Map.put(:order_type, :stop_limit)
        |> Map.put(:stop_price, Decimal.new("1E+2"))

      assert {:ok, _order} =
               Private.place_order(@credentials, request,
                 plug: capturing(@order_body, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["stop_price"] == "100"
      assert payload["type"] == "exchange stop limit"
      assert payload["side"] == "buy"
    end

    test "string sides are accepted in any case" do
      for side <- ["sell", "SELL", "Buy", "buy"] do
        assert :ok = Private.validate_order(Map.put(@request, :side, side))
      end
    end
  end

  describe "get_trade_history/2 and reversed trades" do
    @fill %{
      "order_id" => "107317524",
      "symbol" => "BTCUSD",
      "type" => "Buy",
      "amount" => "0.5",
      "price" => "3648.09",
      "timestampms" => 1_547_232_911_021,
      "tid" => 107_317_526,
      "aggressor" => true,
      "fee_amount" => "0.02",
      "fee_currency" => "USD"
    }

    test "a fully broken trade is not an execution and is left out" do
      rows = [
        @fill,
        Map.merge(@fill, %{"tid" => 2, "break" => "full", "amount" => "9"}),
        Map.merge(@fill, %{"tid" => 3, "break" => "", "timestampms" => 1_547_232_911_022})
      ]

      assert {:ok, [%Fill{trade_id: "107317526"}, %Fill{trade_id: "3"}]} =
               Private.get_trade_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end

    test "a manually reversed trade is kept: the vendor says it must be for the balance" do
      rows = [Map.put(@fill, "break", "manual")]

      assert {:ok, [%Fill{} = fill]} =
               Private.get_trade_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert Decimal.equal?(fill.quantity, Decimal.new("0.5"))
    end

    test "a break type the vendor does not define the treatment of refuses the read" do
      for unknown <- ["trade correct", "partial", 1] do
        rows = [@fill, Map.put(@fill, "break", unknown)]

        assert {:error, {:unknown_break_type, ^unknown}} =
                 Private.get_trade_history(@credentials,
                   plug: responding(rows),
                   retry_attempts: 0
                 )
      end
    end

    test "a page that is full of rows is still truncated even when some are broken out" do
      # 500 rows were sent; dropping one for being broken must not make the page look short.
      rows =
        for n <- 1..500 do
          Map.merge(@fill, %{"tid" => n, "break" => if(n == 1, do: "full", else: "")})
        end

      assert {:error, :history_truncated} =
               Private.get_trade_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end
  end

  describe "get_transfers/2 parameters" do
    test "a DateTime timestamp goes out as milliseconds, with the network filter" do
      assert {:ok, []} =
               Private.get_transfers(@credentials,
                 timestamp: ~U[2026-08-28 17:00:01Z],
                 network: "solana",
                 currency: "USDC",
                 plug: capturing([], self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["timestamp"] === 1_787_936_401_000
      assert payload["network"] == "solana"
      assert payload["currency"] == "USDC"
      assert payload["limit_transfers"] === 50
    end

    test "a nil limit is the default, not a null on the wire" do
      assert {:ok, []} =
               Private.get_transfers(@credentials,
                 limit_transfers: nil,
                 timestamp: nil,
                 plug: capturing([], self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["limit_transfers"] === 50
      refute Map.has_key?(payload, "timestamp")
    end
  end

  describe "conversions decode by the side, which is never defaulted" do
    # A sell: totalSpend and quantity are BOTH CCY1, so there is no proceeds figure.
    @sell_body_no_side %{
      "quoteId" => 20_930,
      "maxAgeMs" => 60_000,
      "price" => "225.42",
      "priceCurrency" => "USD",
      "quantity" => "1",
      "quantityCurrency" => "ETH",
      "fee" => "2.99",
      "totalSpend" => "1",
      "totalSpendCurrency" => "ETH"
    }

    test "a reply with no side is read as the side that was asked for" do
      assert {:ok, %Conversion{} = conversion} =
               Private.quote_conversion("ETH", "USD", Decimal.new("1"),
                 symbol: "ETH-USD",
                 side: :sell,
                 credentials: @credentials,
                 plug: responding(@sell_body_no_side),
                 retry_attempts: 0
               )

      assert conversion.from_asset == "ETH"
      assert conversion.to_asset == "USD"
      assert Decimal.equal?(conversion.from_amount, Decimal.new("1"))
      # Read as a buy this was `1`, a CCY1 figure under a CCY2 label.
      assert conversion.to_amount == nil
    end

    test "commit_conversion/2 reads a side-less reply by the terms it sent" do
      assert {:ok, %Conversion{to_amount: nil}} =
               Private.commit_conversion("20930",
                 symbol: "ETH-USD",
                 side: :sell,
                 amount: Decimal.new("1"),
                 price: Decimal.new("225.42"),
                 fee: Decimal.new("2.99"),
                 credentials: @credentials,
                 plug: responding(@sell_body_no_side),
                 retry_attempts: 0
               )
    end

    test "a side that is neither buy nor sell refuses the read" do
      for bad <- ["hold", 1, ""] do
        body = Map.put(@sell_body_no_side, "side", bad)

        assert {:error, :unexpected_response_shape} =
                 Private.quote_conversion("ETH", "USD", Decimal.new("1"),
                   symbol: "ETH-USD",
                   side: :sell,
                   credentials: @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )
      end
    end

    test "the amount to quote or convert must be a finite number above zero" do
      for bad <- [Decimal.new("NaN"), "abc", "0", Decimal.new("-1"), nil] do
        assert {:error, {:invalid_amount, ^bad}} =
                 Private.quote_conversion("ETH", "USD", bad,
                   symbol: "ETH-USD",
                   side: :sell,
                   credentials: @credentials,
                   plug: exploding(),
                   retry_attempts: 0
                 )

        assert {:error, {:invalid_amount, ^bad}} =
                 Private.convert("GUSD", "USD", bad,
                   symbol: "GUSD-USD",
                   side: :sell,
                   credentials: @credentials,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end

    test "commit_conversion/2 allows a zero fee and refuses a negative one" do
      terms = [
        symbol: "GUSD-USD",
        side: :buy,
        amount: Decimal.new("1"),
        price: Decimal.new("1"),
        credentials: @credentials,
        retry_attempts: 0
      ]

      assert {:ok, _conversion} =
               Private.commit_conversion(
                 "77",
                 terms ++
                   [
                     fee: Decimal.new("0"),
                     plug: capturing(Map.put(@sell_body_no_side, "side", "buy"), self())
                   ]
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["fee"] == "0"

      assert {:error, {:negative_amount, :fee, _value}} =
               Private.commit_conversion(
                 "77",
                 terms ++ [fee: Decimal.new("-1"), plug: exploding()]
               )

      assert {:error, {:invalid_decimal, :price, "x"}} =
               Private.commit_conversion(
                 "77",
                 Keyword.merge(terms, price: "x", fee: "1", plug: exploding())
               )

      assert {:error, {:invalid_side, :hold}} =
               Private.commit_conversion(
                 "77",
                 Keyword.merge(terms, side: :hold, fee: "1", plug: exploding())
               )
    end
  end

  describe "withdraw/6 refuses what it would otherwise send" do
    @withdrawal %{"withdrawalId" => "w-1"}

    defp withdraw(amount, address, opts, asset \\ "ETH", network \\ "ethereum") do
      Private.withdraw(
        asset,
        network,
        amount,
        address,
        @credentials,
        Keyword.merge([plug: exploding(), retry_attempts: 0], opts)
      )
    end

    test "an amount that is not a finite number above zero" do
      for bad <- [Decimal.new("NaN"), Decimal.new("Infinity"), "abc", "0", Decimal.new("-1")] do
        assert {:error, {:invalid_amount, ^bad}} = withdraw(bad, "0xabc", [])
      end
    end

    test "a blank or non-string address, asset or network" do
      assert {:error, {:invalid_address, ""}} = withdraw(Decimal.new(1), "", [])
      assert {:error, {:invalid_address, nil}} = withdraw(Decimal.new(1), nil, [])
      assert {:error, {:invalid_asset, nil}} = withdraw(Decimal.new(1), "0xabc", [], nil)
      assert {:error, {:invalid_asset, " "}} = withdraw(Decimal.new(1), "0xabc", [], " ")
      assert {:error, {:invalid_network, nil}} = withdraw(Decimal.new(1), "0xabc", [], "ETH", nil)
      assert {:error, {:invalid_network, ""}} = withdraw(Decimal.new(1), "0xabc", [], "ETH", "")
    end

    test "a memo said to be required is not satisfied by a blank one" do
      assert {:error, :memo_required} =
               withdraw(Decimal.new(1), "0xabc", memo: "  ", memo_required: true)

      assert {:error, :memo_required} =
               withdraw(Decimal.new(1), "0xabc", memo: "", memo_required: true)

      assert {:error, :memo_required} = withdraw(Decimal.new(1), "0xabc", memo_required: true)
    end

    test "a blank idempotency key is replaced, never sent" do
      for blank <- ["", "   "] do
        assert {:ok, _withdrawal} =
                 withdraw(
                   Decimal.new(1),
                   "0xabc",
                   client_transfer_id: blank,
                   plug: capturing(@withdrawal, self())
                 )

        assert_receive {:payload, payload}, 5_000
        assert byte_size(payload["clientTransferId"]) == 36
      end
    end

    test "an integer destination tag is sent as digits and a blank memo is not sent" do
      assert {:ok, _withdrawal} =
               withdraw(Decimal.new(1), "0xabc",
                 memo: 12_345,
                 plug: capturing(@withdrawal, self())
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["memo"] === "12345"

      assert {:ok, _withdrawal} =
               withdraw(Decimal.new(1), "0xabc", memo: "", plug: capturing(@withdrawal, self()))

      assert_receive {:payload, payload}, 5_000
      refute Map.has_key?(payload, "memo")
    end
  end

  describe "estimate_withdrawal_fee/5" do
    defp estimate(body, amount \\ Decimal.new("0.01")) do
      Private.estimate_withdrawal_fee("ETH", "ethereum", amount, @credentials,
        address: "0xabc",
        plug: responding(body),
        retry_attempts: 0
      )
    end

    test "a reply with no readable fee is not an estimate of nil" do
      for body <- [%{"currency" => "ETH"}, %{"fee" => nil}, %{"fee" => "abc"}, %{"fee" => %{}}] do
        assert {:error, :unexpected_response_shape} = estimate(body)
      end
    end

    test "a zero fee is a fee" do
      assert {:ok, %{fee: fee, fee_currency: "ETH"}} =
               estimate(%{"fee" => 0, "currency" => "ETH"})

      assert Decimal.equal?(fee, 0)
    end

    test "the amount and path segments are checked before signing" do
      assert {:error, {:invalid_amount, "0"}} =
               Private.estimate_withdrawal_fee("ETH", "ethereum", "0", @credentials,
                 address: "0xabc",
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert {:error, {:invalid_network, nil}} =
               Private.estimate_withdrawal_fee("ETH", nil, Decimal.new(1), @credentials,
                 address: "0xabc",
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert {:error, {:missing_option, :address}} =
               Private.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new(1), @credentials,
                 address: "  ",
                 plug: exploding(),
                 retry_attempts: 0
               )
    end
  end

  describe "get_deposit_address/4" do
    test "an address the venue says is on another network is not handed back as the asked one" do
      assert {:error, {:network_mismatch, "ethereum", "bitcoin"}} =
               Private.get_deposit_address("ETH", "ethereum", @credentials,
                 plug: responding(%{"network" => "bitcoin", "address" => "n2saq73aDTu42bRg"}),
                 retry_attempts: 0
               )
    end

    test "the same network in another case is the same network" do
      assert {:ok, %{address: "0x1", network: "ethereum"}} =
               Private.get_deposit_address("ETH", "ethereum", @credentials,
                 plug: responding(%{"network" => "Ethereum", "address" => "0x1"}),
                 retry_attempts: 0
               )
    end

    test "a blank network is refused before a path with an empty segment is signed" do
      for bad <- ["", nil] do
        assert {:error, {:invalid_network, ^bad}} =
                 Private.get_deposit_address("ETH", bad, @credentials,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "bodies that are not the vendor's shape are unreadable, not empty" do
    test "get_accounts/2" do
      for body <- [nil, "x", 7, [1], [%{}, nil]] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_accounts(@credentials, plug: responding(body), retry_attempts: 0)
      end

      assert {:ok, [%{"account" => %{}}]} =
               Private.get_accounts(@credentials,
                 plug: responding(%{"account" => %{}}),
                 retry_attempts: 0
               )
    end

    test "list_networks/2, in both directions" do
      for body <- [nil, "x", [1]] do
        assert {:error, :unexpected_response_shape} =
                 Private.list_networks("USDC",
                   credentials: @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert {:error, :unexpected_response_shape} =
                 Private.list_networks(nil,
                   network: "ethereum",
                   credentials: @credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )
      end
    end

    test "get_fees/2" do
      for body <- [nil, "x", [%{}]] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_fees(@credentials, plug: responding(body), retry_attempts: 0)
      end
    end

    test "get_trade_volume/2 rows must be objects" do
      for body <- [[[1, 2]], [nil], ["x"]] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_trade_volume(@credentials,
                   plug: responding(body),
                   retry_attempts: 0
                 )
      end

      assert {:ok, []} =
               Private.get_trade_volume(@credentials, plug: responding([[]]), retry_attempts: 0)
    end
  end
end
