defmodule DpExchange.Gemini.ResponseShapeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

  # **A response of the wrong JSON shape is an answer, never a raise.**
  #
  # `Core.Venue`'s error discipline is that a facade call answers — `{:ok, _}`,
  # `{:error, _}`, `{:refused, _}` — and does not raise in the caller's process. These are
  # the calls that did, found by feeding every active facade callback a set of plausible
  # but wrong bodies: `[]`, `null`, `{}`, an object whose list fields are all `null`, and
  # `{"data": {}}`. Each row below is one body that used to raise, and the exception it
  # raised. Driven through the FACADE, with the HTTP layer replaced by a `plug:`, so what
  # is measured is exactly the decode path a consumer reaches.
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

  @credentials %{api_key: "account-k", api_secret: "s"}

  defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

  defp base(body) do
    [
      plug: answering(body),
      retry_attempts: 0,
      credentials: @credentials,
      account_id: "acct",
      account_number: "acct",
      account_hash: "acct"
    ]
  end

  defp answers_without_raising(label, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:raised, _error}, result),
           "gemini: #{label} raised #{inspect(result)} — a response shape it did not " <>
             "expect must be refused, not raised in the caller's process"

    result
  end

  # Gemini's decoders read `body["field"]`, and `Access` on a LIST raises
  # `ArgumentError`; they iterate rows, and iterating `null` raises
  # `Protocol.UndefinedError` while iterating an object walks key/value pairs into a
  # function expecting a row. `Rest.object/1` and `Rest.list/1` now check the shape.
  test "an object endpoint answering [] is refused" do
    v = DpExchange.Gemini

    for {label, call} <- [
          {"get_top_of_book/2", fn -> v.get_top_of_book("BTC-USD", base([])) end},
          {"get_funding/2", fn -> v.get_funding("BTCGUSDPERP", base([])) end},
          {"get_contract_stats/2", fn -> v.get_contract_stats("BTCGUSDPERP", base([])) end},
          {"get_deposit_address/3", fn -> v.get_deposit_address("BTC", "bitcoin", base([])) end}
        ] do
      assert {:error, :unexpected_response_shape} = answers_without_raising(label, call)
    end
  end

  test "a list endpoint answering null or an object is refused" do
    v = DpExchange.Gemini

    for body <- [
          nil,
          Map.new(~w(accounts products fills candles data results orders), &{&1, nil})
        ],
        {label, call} <- [
          {"get_symbols/1", fn -> v.get_symbols(base(body)) end},
          {"get_market_overview/1", fn -> v.get_market_overview(base(body)) end},
          {"get_historical_prices/4",
           fn -> v.get_historical_prices("BTC-USD", "1h", [], base(body)) end}
        ] do
      assert {:error, :unexpected_response_shape} = answers_without_raising(label, call)
    end
  end

  test "get_transfers/2 refuses an object — the vendor documents an array, never one" do
    # It used `List.wrap/1`, which handed any object back as one transfer: the wrapper-
    # as-row defect. The vendor's OpenAPI gives this 200 as `type: array` of V2Transfer.
    assert {:error, :unexpected_response_shape} =
             answers_without_raising("get_transfers/2", fn ->
               DpExchange.Gemini.get_transfers(@credentials, base(%{"transfers" => nil}))
             end)
  end

  test "a well-formed list still decodes" do
    assert {:ok, ["BTC-USD"]} =
             DpExchange.Gemini.get_symbols(base(["btcusd"]))
  end

  # **A value of the wrong type INSIDE a well-shaped body is an answer too.** A REST mutation
  # fuzz (2026-09-27) replaced every nested value of real bodies with `nil`, `true`, `[]`,
  # `[%{}]`, a map, a string and out-of-range numbers, one at a time, across 41 endpoints.
  # 232 of those mutations raised. Each test below is one of the decode paths they raised out
  # of, with the answer that endpoint's own policy gives.
  describe "a value of the wrong type inside a response" do
    alias DpExchange.Gemini.{Private, Rest}

    defp dated(body) do
      [
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
          |> Req.Test.json(body)
        end,
        retry_attempts: 0
      ]
    end

    test "a row that is not an object, or a body that is not a list, refuses the reply" do
      for {label, call} <- [
            {"balances row", fn -> Private.get_balances(@credentials, dated([true])) end},
            {"balances body", fn -> Private.get_balances(@credentials, dated(%{"a" => nil})) end},
            {"fills row",
             fn ->
               Private.get_trade_history(@credentials, [symbol: "BTC-USD"] ++ dated([true]))
             end},
            {"trades row", fn -> Rest.get_trades("BTC-USD", dated([true])) end},
            {"approved row",
             fn ->
               Private.list_approved_addresses(
                 @credentials,
                 [network: "ethereum"] ++ dated(%{"approvedAddresses" => [true]})
               )
             end},
            {"quantization body", fn -> Rest.quantization("BTC-USD", dated([%{}])) end},
            {"fee estimate body",
             fn ->
               Private.estimate_withdrawal_fee(
                 "ETH",
                 "ethereum",
                 Decimal.new(1),
                 @credentials,
                 [address: "0x0"] ++ dated(true)
               )
             end},
            {"book side",
             fn -> Rest.get_order_book("BTC-USD", dated(%{"bids" => "x", "asks" => []})) end}
          ] do
        assert {:error, :unexpected_response_shape} == answers_without_raising(label, call),
               label
      end
    end

    test "an order whose id or symbol is not a string decodes with nil, not a raise or \"\"" do
      order = %{"order_id" => %{"a" => nil}, "symbol" => [1], "side" => "buy"}

      assert {:ok, %{id: nil, symbol: nil}} =
               Private.get_order(@credentials, "1", dated(order))

      # `to_string(nil)` put `""` here, which passes every nil check while naming no order.
      assert {:ok, %{id: nil}} =
               Private.get_order(@credentials, "1", dated(%{"order_id" => nil}))

      assert {:ok, %{id: "7"}} = Private.get_order(@credentials, "1", dated(%{"order_id" => 7}))
    end

    test "a fill whose order id is not an id is refused; a trade id is nil" do
      fill = %{
        "price" => "1",
        "amount" => "1",
        "timestampms" => 1_787_936_145_649,
        "type" => "Buy",
        "tid" => 1,
        "order_id" => %{}
      }

      assert {:error, :unexpected_response_shape} =
               Private.get_trade_history(@credentials, [symbol: "BTC-USD"] ++ dated([fill]))

      assert {:ok, [%{trade_id: nil, order_id: "9"}]} =
               Private.get_trade_history(
                 @credentials,
                 [symbol: "BTC-USD"] ++ dated([%{fill | "order_id" => 9, "tid" => [%{}]}])
               )

      trade = %{"timestampms" => 1_787_936_145_649, "tid" => %{}, "price" => "1", "amount" => "1"}
      assert {:ok, [%{id: nil}]} = Rest.get_trades("BTC-USD", dated([trade]))
    end

    test "a catalogue row naming no pair, or a book level that is not an object, is skipped" do
      rows = [%{"pair" => "BTCUSD", "price" => "1"}, %{"pair" => %{}}, %{}]
      assert {:ok, overview} = Rest.get_market_overview(dated(rows))
      assert map_size(overview) == 1

      book = %{
        "bids" => [true, %{"price" => "2", "amount" => "1", "timestamp" => "1547147541"}],
        "asks" => [[%{}]]
      }

      assert {:ok, %{bids: [{bid, _size}], asks: []}} =
               Rest.get_order_book("BTC-USD", dated(book))

      assert Decimal.equal?(bid, 2)
    end

    test "a cancel-all entry that is not an id refuses the result, never under-reports it" do
      body = fn cancelled ->
        dated(%{"details" => %{"cancelledOrders" => cancelled, "cancelRejects" => []}})
      end

      cancel = &Private.cancel_all_orders(@credentials, [scope: :account] ++ &1)

      assert {:ok, %{cancelled: ["1", "2"], rejected: []}} = cancel.(body.([1, "2"]))
      assert {:error, :unexpected_response_shape} = cancel.(body.([1, %{}]))
      assert {:error, :unexpected_response_shape} = cancel.(body.([1, nil]))
    end

    test "an accepted withdrawal with an unreadable body carries the key that was sent" do
      # Refusing it told the caller the withdrawal failed after the venue accepted it, and a
      # retry without a key would generate a new one and send the money again.
      withdraw = fn body ->
        Private.withdraw(
          "BTC",
          "bitcoin",
          Decimal.new(1),
          "addr",
          @credentials,
          [client_transfer_id: "key-1"] ++ dated(body)
        )
      end

      for body <- [true, [%{}], %{}, %{"withdrawalId" => %{}}] do
        assert {:ok, %{id: "key-1", status: :pending}} = withdraw.(body), inspect(body)
      end

      assert {:ok, %{id: "w-9"}} = withdraw.(%{"withdrawalId" => "w-9"})
    end

    test "a quote window no venue gives is an unknown expiry, answered at once" do
      # `DateTime.add/3` computes a date for any offset. A `maxAgeMs` of 10^27 kept this call
      # running in the caller's process with no answer.
      quote_body = fn max_age ->
        %{
          "quoteId" => 20_930,
          "maxAgeMs" => max_age,
          "pair" => "BTCUSD",
          "price" => "6445.07",
          "side" => "buy",
          "quantity" => "0.01505181",
          "quantityCurrency" => "BTC",
          "fee" => "2.99",
          "totalSpend" => "100",
          "totalSpendCurrency" => "USD"
        }
      end

      quote = fn max_age ->
        task =
          Task.async(fn ->
            Private.quote_conversion(
              "USD",
              "DOGE",
              Decimal.new(100),
              [credentials: @credentials] ++ dated(quote_body.(max_age))
            )
          end)

        Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
      end

      for max_age <- [999_999_999_999_999_999_999_999_999, -(10 ** 27), 3_600_001] do
        assert {:ok, {:ok, %{expires_at: nil}}} = quote.(max_age), inspect(max_age)
      end

      assert {:ok, {:ok, %{expires_at: at}}} = quote.(60_000)
      assert DateTime.compare(at, ~U[2026-08-28 17:01:01Z]) == :eq
    end
  end

  describe "a reply whose list cannot be found is unreadable, not empty" do
    # Each of these used to answer `{:ok, []}` for a wrapper holding a non-list, or a body
    # that was not the shape at all: no positions, no payment methods, no approved
    # addresses, no margin rates, nothing cancelled, no fee promotions. Each is a statement
    # the venue did not make.
    alias DpExchange.Gemini.{Private, Rest}

    @unreadable [%{"openPositions" => "x"}, %{"openPositions" => %{}}]

    test "get_positions/2" do
      for body <- @unreadable do
        assert {:error, :unexpected_response_shape} =
                 Private.get_positions(@credentials, base(body))
      end

      assert {:ok, []} = Private.get_positions(@credentials, base(%{"openPositions" => nil}))
    end

    test "list_payment_methods/2" do
      for body <- [%{"methods" => "x"}, %{"methods" => %{}}] do
        assert {:error, :unexpected_response_shape} =
                 Private.list_payment_methods(@credentials, base(body))
      end

      assert {:ok, []} = Private.list_payment_methods(@credentials, base(%{"methods" => nil}))
    end

    test "list_approved_addresses/2" do
      for body <- [%{"approvedAddresses" => "x"}, %{}] do
        assert {:error, :unexpected_response_shape} =
                 Private.list_approved_addresses(
                   @credentials,
                   [network: "ethereum"] ++ base(body)
                 )
      end
    end

    test "get_margin_rates/2" do
      for body <- [%{"rates" => "x"}, %{}] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_margin_rates(@credentials, base(body))
      end
    end

    test "cancel_all_orders/2" do
      body = %{"result" => "ok", "details" => %{"cancelledOrders" => "x", "cancelRejects" => []}}

      assert {:error, :unexpected_response_shape} =
               Private.cancel_all_orders(@credentials, [scope: :account] ++ base(body))
    end

    test "list_fee_promos/1" do
      for body <- [%{"symbols" => "x"}, %{"symbols" => 1}] do
        assert {:error, :unexpected_response_shape} = Rest.list_fee_promos(base(body))
      end

      assert {:ok, []} = Rest.list_fee_promos(base(%{"symbols" => nil}))
    end
  end
end
