defmodule DpExchange.Gemini.PrivateTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Balance, Conversion, Fill, Order}
  alias DpExchange.Gemini.{Private, Rest}

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

  defp responding(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> then(&Req.Test.json(%{&1 | status: status}, body))
    end
  end

  # Captures the signed payload the venue would receive, which is the only way to assert
  # what this package actually sends rather than what it meant to send.
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

  @request %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100.00"}

  describe "credentials are an argument, used once and not kept" do
    test "the request carries the signed headers the venue requires" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-gemini-apikey") == ["account-test"]
        assert [_signature] = Plug.Conn.get_req_header(conn, "x-gemini-signature")
        assert [_payload] = Plug.Conn.get_req_header(conn, "x-gemini-payload")

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json([])
      end

      assert {:ok, _balances} = Private.get_balances(@credentials, plug: plug, retry_attempts: 0)
    end

    test "an OAuth token is sent as a bearer, with no key headers alongside it" do
      # Sending both families is `AmbiguousAuthentication` at the venue.
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
        assert Plug.Conn.get_req_header(conn, "x-gemini-apikey") == []

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json([])
      end

      assert {:ok, _balances} =
               Private.get_balances(%{access_token: "tok"}, plug: plug, retry_attempts: 0)
    end

    test "credentials carrying BOTH schemes are refused, not resolved by precedence" do
      # Picking one would be this package choosing an authentication the host did not.
      assert {:error, {:unsupported_auth_scheme, :ambiguous}} =
               Private.get_balances(%{api_key: "k", api_secret: "s", access_token: "t"},
                 retry_attempts: 0
               )
    end

    test "the payload names the endpoint, which is what binds a signature to a target" do
      Private.get_balances(@credentials, plug: capturing([], self()), retry_attempts: 0)

      assert_receive {:payload, payload}
      assert payload["request"] == "/v1/balances"
      assert is_integer(payload["nonce"])
    end
  end

  describe "place_order/3 — what actually goes on the wire" do
    test "a limit order sends the venue's own type string and no options" do
      Private.place_order(@credentials, @request,
        plug: capturing(@order, self()),
        retry_attempts: 0
      )

      assert_receive {:payload, payload}
      assert payload["type"] == "exchange limit"
      assert payload["options"] == []
      assert payload["symbol"] == "btcusd"
      assert payload["side"] == "buy"
      assert payload["amount"] == "1"
      assert payload["price"] == "100.00"
    end

    test "the contract's order types map to Gemini's execution options" do
      # The contract models these as order types; Gemini models them as options on a limit
      # order. This is the translation, asserted rather than described.
      for {order_type, option} <- [
            {:post_only, "maker-or-cancel"},
            {:ioc, "immediate-or-cancel"},
            {:fok, "fill-or-kill"}
          ] do
        Private.place_order(@credentials, Map.put(@request, :order_type, order_type),
          plug: capturing(@order, self()),
          retry_attempts: 0
        )

        assert_receive {:payload, payload}
        assert payload["type"] == "exchange limit"
        assert payload["options"] == [option]
      end
    end

    test "time_in_force reaches the same options" do
      for {tif, option} <- [{:ioc, "immediate-or-cancel"}, {:fok, "fill-or-kill"}] do
        Private.place_order(@credentials, Map.put(@request, :time_in_force, tif),
          plug: capturing(@order, self()),
          retry_attempts: 0
        )

        assert_receive {:payload, payload}
        assert payload["options"] == [option]
      end
    end

    test "an order type and a time_in_force that AGREE are fine" do
      Private.place_order(
        @credentials,
        @request |> Map.put(:order_type, :ioc) |> Map.put(:time_in_force, :ioc),
        plug: capturing(@order, self()),
        retry_attempts: 0
      )

      assert_receive {:payload, payload}
      assert payload["options"] == ["immediate-or-cancel"]
    end

    test "an order type and a time_in_force that DISAGREE are refused, not reconciled" do
      # An order saying both post-only and fill-or-kill has no correct reading, and
      # picking one would be this package deciding how someone's money is spent.
      assert {:error, {:conflicting_execution_options, _from_type, _from_tif}} =
               Private.place_order(
                 @credentials,
                 @request |> Map.put(:order_type, :post_only) |> Map.put(:time_in_force, :fok),
                 retry_attempts: 0
               )
    end

    test "MARKET is refused — the venue serves none and the workaround needs OUR price" do
      # The most expensive instance of this family's failure mode. Gemini's documented
      # workaround is IOC "coupled with an aggressive limit price"; how aggressive is a
      # question only the caller can answer, and the answer is money.
      assert {:error, {:unsupported_order_type, :market}} =
               Private.place_order(@credentials, Map.put(@request, :order_type, :market),
                 retry_attempts: 0
               )
    end

    test "a plain STOP is refused too, for the same reason" do
      # Gemini serves stop-limit only. A plain stop would have to become a stop-limit at a
      # price this package would be choosing.
      assert {:error, {:unsupported_order_type, :stop}} =
               Private.place_order(@credentials, Map.put(@request, :order_type, :stop),
                 retry_attempts: 0
               )
    end

    test "no execution option may ride on a stop-limit" do
      request = @request |> Map.put(:order_type, :stop_limit) |> Map.put(:time_in_force, :ioc)

      assert {:error, {:unsupported_time_in_force, _option, :not_allowed_on_stop_limit}} =
               Private.place_order(@credentials, request, retry_attempts: 0)
    end

    test "a missing price is refused rather than defaulted" do
      assert {:error, {:missing_field, :price}} =
               Private.place_order(@credentials, Map.delete(@request, :price), retry_attempts: 0)
    end

    test "a client_order_id is passed through when given" do
      Private.place_order(@credentials, Map.put(@request, :client_order_id, "mine-1"),
        plug: capturing(@order, self()),
        retry_attempts: 0
      )

      assert_receive {:payload, payload}
      assert payload["client_order_id"] == "mine-1"
    end
  end

  describe "order responses" do
    test "become an Order with the canonical symbol and Decimal numerics" do
      assert {:ok, %Order{} = order} =
               Private.place_order(@credentials, @request,
                 plug: responding(@order),
                 retry_attempts: 0
               )

      assert order.id == "1234"
      assert order.symbol == "BTC-USD"
      assert order.side == :buy
      assert order.status == :open
      assert Decimal.equal?(order.price, Decimal.new("100.00"))
      assert order.provider == :gemini
    end

    test "a cancelled MOC/IOC/FOK order is a SUCCESS, not a failure" do
      # These come back 200 with is_cancelled true. A caller that read that as an error
      # would retry an order the venue already handled.
      body = %{@order | "is_live" => false, "is_cancelled" => true}

      assert {:ok, %Order{status: :cancelled}} =
               Private.place_order(@credentials, @request,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a partially filled live order says so" do
      body = %{@order | "executed_amount" => "0.5"}

      assert {:ok, %Order{status: :partially_filled}} =
               Private.get_order(@credentials, "1234", plug: responding(body), retry_attempts: 0)
    end

    test "a cancelled order that did fill is :filled, not :cancelled" do
      # IOC that filled entirely still terminates as cancelled at the venue. What filled
      # is the fact a caller acts on.
      body = %{@order | "is_live" => false, "is_cancelled" => true, "executed_amount" => "1"}

      assert {:ok, %Order{status: :filled}} =
               Private.get_order(@credentials, "1234", plug: responding(body), retry_attempts: 0)
    end

    test "an unexpected shape is an error, not a half-built Order" do
      assert {:error, :unexpected_response_shape} =
               Private.get_order(@credentials, "1234",
                 plug: responding(%{"nope" => true}),
                 retry_attempts: 0
               )
    end
  end

  describe "balances" do
    test "hold is derived from total minus available, not invented" do
      body = [%{"currency" => "USD", "amount" => "100.00", "available" => "90.00"}]

      assert {:ok, [%Balance{} = balance]} =
               Private.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert balance.currency == "USD"
      assert Decimal.equal?(balance.hold, Decimal.new("10.00"))
    end

    test "a missing available leaves hold nil rather than zero" do
      # Zero is a hold. A venue that did not say has not said none.
      body = [%{"currency" => "USD", "amount" => "100.00"}]

      assert {:ok, [balance]} =
               Private.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert balance.hold == nil
    end

    test "a non-numeric available leaves hold nil rather than raising or subtracting garbage" do
      body = [%{"currency" => "USD", "amount" => "100.00", "available" => "null"}]

      assert {:ok, [balance]} =
               Private.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert balance.hold == nil
    end

    test "a non-numeric amount does not raise; balance comes back nil for that currency" do
      # Decimal.new/1 used to raise here. balance is required by the type but this
      # package already tolerates nil there when the venue omits the field outright —
      # a malformed one is treated the same way rather than crashing the whole page.
      body = [%{"currency" => "USD", "amount" => "not-a-number", "available" => "90.00"}]

      assert {:ok, [balance]} =
               Private.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert balance.balance == nil
      assert balance.hold == nil
    end
  end

  describe "trade history" do
    test "requires a symbol, because the venue offers no all-symbols variant" do
      assert {:error, {:missing_option, :symbol}} =
               Private.get_trade_history(@credentials, retry_attempts: 0)
    end

    test "becomes Fills with the venue's own liquidity flag" do
      body = [
        %{
          "order_id" => "1",
          "tid" => "2",
          "price" => "100",
          "amount" => "0.5",
          "type" => "Buy",
          "aggressor" => true,
          "fee_amount" => "0.1",
          "fee_currency" => "USD",
          "timestampms" => 1_787_936_147_000
        }
      ]

      assert {:ok, [%Fill{} = fill]} =
               Private.get_trade_history(@credentials,
                 symbol: "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert fill.side == :buy
      assert fill.liquidity == :taker
      assert fill.symbol == "BTC-USD"
    end
  end

  describe "auth failures are refusals" do
    test "a 401 is a refusal carrying the venue's own reason" do
      # Measured against the live demo environment: an unauthenticated private call
      # returns 401 MissingSecurityHeaders, while the docs say 400 MissingApikeyHeader.
      body = %{"result" => "error", "reason" => "MissingSecurityHeaders"}

      assert {:refused, :missing_security_headers} =
               Private.get_balances(@credentials,
                 plug: responding(body, status: 401),
                 retry_attempts: 0
               )
    end

    test "a 403 is a refusal too — a disabled key cannot be retried into working" do
      body = %{"result" => "error", "reason" => "InvalidApiKey"}

      assert {:refused, :invalid_api_key} =
               Private.get_balances(@credentials,
                 plug: responding(body, status: 403),
                 retry_attempts: 0
               )
    end

    test "a 500 stays an error the caller may retry" do
      assert {:error, _reason} =
               Private.get_balances(@credentials,
                 plug: responding(%{}, status: 500),
                 retry_attempts: 0
               )
    end
  end

  describe "the environment reaches private calls too" do
    test "demo credentials go to the demo host" do
      assert Private.get_balances(@credentials, environment: :sandbox, retry_attempts: 0) != nil
    end
  end

  describe "response mapping covers what the venue actually varies" do
    test "order type is recovered from the options the venue echoes back" do
      # The venue does not echo "post_only"; it echoes the option it applied. Reading the
      # type back from `type` alone would report every one of these as a plain limit.
      for {options, expected} <- [
            {["maker-or-cancel"], :post_only},
            {["immediate-or-cancel"], :ioc},
            {["fill-or-kill"], :fok},
            {[], :limit}
          ] do
        body = Map.put(@order, "options", options)

        assert {:ok, order} =
                 Private.get_order(@credentials, "1", plug: responding(body), retry_attempts: 0)

        assert order.order_type == expected
      end
    end

    test "a stop-limit is reported as one" do
      body = Map.put(@order, "type", "exchange stop limit")

      assert {:ok, %Order{order_type: :stop_limit}} =
               Private.get_order(@credentials, "1", plug: responding(body), retry_attempts: 0)
    end

    test "an order neither live nor cancelled is pending, not silently open" do
      body = @order |> Map.put("is_live", false) |> Map.put("is_cancelled", false)

      assert {:ok, %Order{status: :pending}} =
               Private.get_order(@credentials, "1", plug: responding(body), retry_attempts: 0)
    end

    test "a sell is a sell" do
      body = Map.put(@order, "side", "sell")

      assert {:ok, %Order{side: :sell}} =
               Private.get_order(@credentials, "1", plug: responding(body), retry_attempts: 0)
    end

    test "a string timestamp is read the same as an integer one" do
      body = Map.put(@order, "timestampms", "1787936147000")

      assert {:ok, order} =
               Private.get_order(@credentials, "1", plug: responding(body), retry_attempts: 0)

      assert order.created_at == DateTime.from_unix!(1_787_936_147_000, :millisecond)
    end

    test "an unreadable timestamp leaves the field nil rather than inventing one" do
      body = Map.put(@order, "timestampms", "not a time")

      assert {:ok, %Order{created_at: nil}} =
               Private.get_order(@credentials, "1", plug: responding(body), retry_attempts: 0)
    end

    test "a fill with no aggressor flag has unknown liquidity, not an assumed one" do
      body = [
        %{
          "order_id" => "1",
          "tid" => "2",
          "price" => "100",
          "amount" => "0.5",
          "type" => "Sell",
          "timestampms" => 1_787_936_147_000
        }
      ]

      assert {:ok, [fill]} =
               Private.get_trade_history(@credentials,
                 symbol: "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert fill.liquidity == nil
      assert fill.side == :sell
    end
  end

  describe "options that reach the venue" do
    test "transfer filters are passed through rather than applied here" do
      plug = fn conn ->
        payload =
          conn
          |> Plug.Conn.get_req_header("x-gemini-payload")
          |> List.first()
          |> Base.decode64!()
          |> Jason.decode!()

        assert payload["currency"] == "BTC"
        Req.Test.json(conn, [])
      end

      assert {:ok, []} =
               Private.get_transfers(@credentials,
                 currency: "BTC",
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a stop price is sent when the caller supplies one" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "1",
        price: "100",
        stop_price: "95",
        order_type: :stop_limit
      }

      Private.place_order(@credentials, request,
        plug: capturing(@order, self()),
        retry_attempts: 0
      )

      assert_receive {:payload, payload}
      assert payload["stop_price"] == "95"
      assert payload["type"] == "exchange stop limit"
    end

    test "credentials with no recognisable scheme are refused" do
      assert {:error, {:unsupported_auth_scheme, nil}} =
               Private.get_balances(%{something: "else"}, retry_attempts: 0)
    end

    test "an explicit auth_scheme overrides what the credentials look like" do
      # The host named it; that wins. Shape-based resolution is only the fallback.
      assert {:error, {:missing_credentials, :oauth}} =
               Private.get_balances(@credentials, auth_scheme: :oauth, retry_attempts: 0)
    end
  end

  describe "bulk cancel — the scope is the caller's to state" do
    @cancel_all %{
      "result" => "ok",
      "details" => %{"cancelledOrders" => [330_429_106, 330_429_079], "cancelRejects" => []}
    }

    test "no scope is an error, and nothing is sent" do
      # The account scope reaches orders no API key placed — the venue says so explicitly,
      # including ones a person entered at the web interface. Choosing for a caller who
      # meant the session would cancel work nobody asked about.
      exploding = fn _conn -> raise "must not bulk-cancel without a scope" end

      assert {:error, :scope_required} =
               Private.cancel_all_orders(@credentials, plug: exploding, retry_attempts: 0)
    end

    test "a scope this venue does not have is an error, not the nearest one" do
      exploding = fn _conn -> raise "must not bulk-cancel on an unknown scope" end

      assert {:error, {:unsupported_scope, :everything}} =
               Private.cancel_all_orders(@credentials,
                 scope: :everything,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "the two scopes are two different endpoints" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json(@cancel_all)
      end

      assert {:ok, _session} =
               Private.cancel_all_orders(@credentials,
                 scope: :session,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, session_path}
      assert session_path == "/v1/order/cancel/session"

      assert {:ok, _account} =
               Private.cancel_all_orders(@credentials,
                 scope: :account,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, account_path}
      assert account_path == "/v1/order/cancel/all"
    end

    test "the venue's ids come back as strings, like every other order id here" do
      assert {:ok, %{cancelled: cancelled, rejected: []}} =
               Private.cancel_all_orders(@credentials,
                 scope: :session,
                 plug: responding(@cancel_all),
                 retry_attempts: 0
               )

      assert cancelled == ["330429106", "330429079"]
    end

    test "a rejected order is reported, not turned into a failed call" do
      # The venue answered and some orders were already gone. An error here would tell a
      # caller nothing was cancelled when most of it was.
      body = %{
        "result" => "ok",
        "details" => %{"cancelledOrders" => [1], "cancelRejects" => [2, 3]}
      }

      assert {:ok, %{cancelled: ["1"], rejected: ["2", "3"]}} =
               Private.cancel_all_orders(@credentials,
                 scope: :account,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a body with no details is unreadable, not an empty cancellation" do
      assert {:error, :unexpected_response_shape} =
               Private.cancel_all_orders(@credentials,
                 scope: :session,
                 plug: responding(%{"result" => "ok"}),
                 retry_attempts: 0
               )
    end
  end

  describe "order history is a different endpoint, not a filter" do
    test "without history: the resting orders come from /v1/orders" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json([])
      end

      assert {:ok, []} = Private.get_orders(@credentials, plug: plug, retry_attempts: 0)
      assert_receive {:path, "/v1/orders"}
    end

    test "with history: the closed ones come from /v1/orders/history" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json([])
      end

      assert {:ok, []} =
               Private.get_orders(@credentials, history: true, plug: plug, retry_attempts: 0)

      assert_receive {:path, "/v1/orders/history"}
    end

    test "history filters are sent to the venue in the venue's own names" do
      me = self()

      assert {:ok, _orders} =
               Private.get_orders(@credentials,
                 history: true,
                 symbol: "BTC-USD",
                 limit: 100,
                 since: ~U[2026-08-28 17:00:01Z],
                 plug: capturing([@order], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "btcusd"
      assert payload["limit_orders"] == 100
      # Milliseconds, which is the unit the venue's own examples and responses use.
      assert payload["timestamp"] == 1_787_936_401_000
    end

    test "no filters means no filters — the venue's own defaults apply" do
      # A page size chosen here would silently become the caller's answer.
      me = self()

      assert {:ok, _orders} =
               Private.get_orders(@credentials,
                 history: true,
                 plug: capturing([@order], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, "limit_orders")
      refute Map.has_key?(payload, "symbol")
      refute Map.has_key?(payload, "timestamp")
    end

    test "history rows decode with the same reader the resting ones use" do
      assert {:ok, [order]} =
               Private.get_orders(@credentials,
                 history: true,
                 plug: responding([@order]),
                 retry_attempts: 0
               )

      assert %Order{} = order
      assert order.id == "1234"
      assert order.symbol == "BTC-USD"
    end
  end

  describe "conversions — Instant quotes, and the direction this refuses to guess" do
    @quote_body %{
      "quoteId" => 20_930,
      "maxAgeMs" => 60_000,
      "pair" => "BTCUSD",
      "price" => "6445.07",
      "priceCurrency" => "USD",
      "side" => "buy",
      "quantity" => "0.01505181",
      "quantityCurrency" => "BTC",
      "fee" => "2.9900309233",
      "feeCurrency" => "USD",
      "totalSpend" => "100",
      "totalSpendCurrency" => "USD"
    }

    test "a quote-currency-to-base conversion is a buy of the base's pair" do
      me = self()

      assert {:ok, _conversion} =
               Private.quote_conversion("USD", "DOGE", Decimal.new("100"),
                 credentials: @credentials,
                 plug: capturing(@quote_body, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "dogeusd"
      assert payload["side"] == "buy"
      assert payload["totalSpend"] == "100"
    end

    test "a crypto-to-fiat conversion is a sell of the same pair" do
      # The venue's rule: totalSpend is CCY2 on a buy and CCY1 on a sell. Getting this
      # backwards spends the wrong asset, which is a real loss rather than a wrong number.
      me = self()

      assert {:ok, _conversion} =
               Private.quote_conversion("DOGE", "USD", Decimal.new("1"),
                 credentials: @credentials,
                 plug: capturing(@quote_body, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "dogeusd"
      assert payload["side"] == "sell"
    end

    test "two quote currencies is refused, not resolved" do
      # GUSD -> USD is a real pair in both directions. Picking one spends the wrong asset.
      exploding = fn _conn -> raise "must not guess a conversion direction" end

      assert {:error, {:ambiguous_conversion, "GUSD", "USD"}} =
               Private.quote_conversion("GUSD", "USD", Decimal.new("1"),
                 credentials: @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "an explicit symbol and side settle an ambiguous pair" do
      me = self()

      assert {:ok, _conversion} =
               Private.quote_conversion("GUSD", "USD", Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :sell,
                 credentials: @credentials,
                 plug: capturing(@quote_body, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "gusdusd"
      assert payload["side"] == "sell"
    end

    test "half an override is an error rather than half a guess" do
      exploding = fn _conn -> raise "must not send a half-specified conversion" end

      assert {:error, {:missing_option, [:symbol, :side]}} =
               Private.quote_conversion("GUSD", "USD", Decimal.new("1"),
                 symbol: "GUSD-USD",
                 credentials: @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "the quote carries the venue's numbers and a real expiry" do
      assert {:ok, conversion} =
               Private.quote_conversion("USD", "BTC", Decimal.new("100"),
                 symbol: "BTC-USD",
                 side: :buy,
                 credentials: @credentials,
                 plug: responding(@quote_body),
                 retry_attempts: 0
               )

      assert conversion.id == "20930"
      assert conversion.status == :quoted
      assert Decimal.equal?(conversion.rate, Decimal.new("6445.07"))
      assert Decimal.equal?(conversion.fee, Decimal.new("2.9900309233"))
      # maxAgeMs measured from the venue's own Date header, not the local clock: a window
      # computed against a drifted client expires at the wrong moment, and a conversion
      # committed a second late fills at a rate the caller was never shown.
      assert DateTime.compare(conversion.expires_at, ~U[2026-08-28 17:01:01Z]) == :eq
    end

    test "a quote is :quoted, which is not a conversion that happened" do
      assert {:ok, conversion} =
               Private.quote_conversion("USD", "BTC", Decimal.new("100"),
                 symbol: "BTC-USD",
                 side: :buy,
                 credentials: @credentials,
                 plug: responding(@quote_body),
                 retry_attempts: 0
               )

      refute conversion.status == :settled

      assert Conversion.expired?(conversion, ~U[2026-08-28 17:00:30Z]) ==
               false

      assert Conversion.expired?(conversion, ~U[2026-08-28 17:02:00Z])
    end

    test "committing needs the terms the venue quoted against, not the id alone" do
      exploding = fn _conn -> raise "must not execute without the quoted terms" end

      assert {:error, {:missing_option, [:symbol, :side, :amount, :price]}} =
               Private.commit_conversion("20930",
                 credentials: @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a commit sends the id and the terms, and comes back settled" do
      me = self()

      assert {:ok, conversion} =
               Private.commit_conversion("20930",
                 symbol: "BTC-USD",
                 side: :buy,
                 amount: Decimal.new("0.015"),
                 price: Decimal.new("6445.07"),
                 credentials: @credentials,
                 plug: capturing(@quote_body, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["quoteId"] == "20930"
      assert payload["symbol"] == "btcusd"
      assert conversion.status == :settled
    end
  end

  describe "wrap is the one-step conversion" do
    test "it goes to the wrap path and comes back settled, with no rate held" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json(%{
          "orderId" => "77",
          "price" => "1.00",
          "quantity" => "1",
          "quantityCurrency" => "USD",
          "totalSpend" => "1",
          "totalSpendCurrency" => "GUSD"
        })
      end

      assert {:ok, conversion} =
               Private.convert("GUSD", "USD", Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :sell,
                 credentials: @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, "/v1/wrap/gusdusd"}
      assert conversion.status == :settled
      # No quote was held, so there is no window and `expired?/2` reports unknown rather
      # than a boolean a caller could act on.
      assert conversion.expires_at == nil
    end
  end

  describe "the account's own traded volume" do
    test "rows come back as the venue sends them, flattened from its nesting" do
      body = [
        [
          %{"symbol" => "btcusd", "total_volume_base" => "10.5", "data_date" => "2026-08-31"},
          %{"symbol" => "btcusd", "total_volume_base" => "3.1", "data_date" => "2026-08-30"}
        ]
      ]

      assert {:ok, rows} =
               Private.get_trade_volume(@credentials, plug: responding(body), retry_attempts: 0)

      assert length(rows) == 2
      # The venue's own field names, unrenamed: a caller reading buy_maker_notional wants
      # the venue's number under the venue's name.
      assert hd(rows)["total_volume_base"] == "10.5"
    end

    test "no volume is an empty list, not an error" do
      assert {:ok, []} =
               Private.get_trade_volume(@credentials, plug: responding([]), retry_attempts: 0)
    end
  end

  describe "networks — the call that has to happen before a deposit address" do
    test "the asset direction is public and lists the chains" do
      # get_deposit_address/3 takes a network, and a wrong one produces an address on a
      # chain this venue does not credit. Funds sent there are gone.
      body = [%{"token" => "USDC", "network" => ["ethereum", "solana"]}]

      assert {:ok, rows} =
               Rest.networks_for_asset("USDC", plug: responding(body), retry_attempts: 0)

      assert [%{"token" => "USDC"}] = rows
    end

    test "the network direction is authenticated and asks the venue's own path" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(%{"network" => "ethereum", "assets" => ["USDC"]})
      end

      assert {:ok, [_row]} =
               Private.list_networks(nil,
                 network: "ethereum",
                 credentials: @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, "/v2/networks/ethereum/assets"}
    end

    test "neither an asset nor a network is an error" do
      exploding = fn _conn -> raise "must not ask for networks with neither side given" end

      assert {:error, :asset_or_network_required} =
               Private.list_networks(nil, plug: exploding, retry_attempts: 0)
    end

    test "the asset direction goes through the public endpoint even from Private" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json([%{"token" => "USDC"}])
      end

      assert {:ok, [_row]} =
               Private.list_networks("USDC", plug: plug, retry_attempts: 0)

      assert_receive {:path, "/v2/network/USDC"}
    end
  end

  describe "fee promos are not the fee schedule" do
    test "the symbols come back as rows" do
      # get_fees/2 is the schedule applying to this credential. This is the public list of
      # symbols where the venue charges something other than that schedule, and a caller
      # computing cost from the schedule alone is wrong for exactly these.
      assert {:ok, rows} =
               Rest.list_fee_promos(
                 plug: responding(%{"symbols" => ["btcusd", "ethusd"]}),
                 retry_attempts: 0
               )

      assert rows == [%{"symbol" => "btcusd"}, %{"symbol" => "ethusd"}]
    end

    test "no promotions is an empty list, which is a real state" do
      assert {:ok, []} =
               Rest.list_fee_promos(plug: responding(%{"symbols" => []}), retry_attempts: 0)
    end

    test "a bare list comes back as rows too" do
      assert {:ok, [%{"symbol" => "btcusd"}]} =
               Rest.list_fee_promos(
                 plug: responding([%{"symbol" => "btcusd"}]),
                 retry_attempts: 0
               )
    end
  end
end
