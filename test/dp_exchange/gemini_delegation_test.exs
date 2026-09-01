defmodule DpExchange.GeminiDelegationTest do
  @moduledoc """
  The facade's market-data and streaming callbacks, exercised through the real
  supervision tree with the venue replaced by a plug.

  Separate from `DpExchange.GeminiTest`, which asserts the *declaration*. This asserts
  that calling the facade actually reaches the code the declaration describes — the two
  fail differently and a package can pass one while failing the other.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Core.Types.{OrderBook, Quote}
  alias DpExchange.Gemini

  @moduletag :capture_log

  setup do
    unique = System.unique_integer([:positive])

    opts = [
      name: :"deleg_sup_#{unique}",
      feed: :"deleg_feed_#{unique}",
      limiter: :"deleg_limiter_#{unique}"
    ]

    {:ok, pid} = Gemini.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    {:ok, opts: opts}
  end

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> then(&Req.Test.json(%{&1 | status: status}, body))
    end
  end

  @ticker %{
    "bid" => "77791.77",
    "ask" => "77791.92",
    "last" => "77829.80",
    "volume" => %{"BTC" => "183.72", "USD" => "14298954.22", "timestamp" => 1_787_936_340_000}
  }

  describe "market data reaches the venue through the facade" do
    test "get_price/2", %{opts: opts} do
      assert {:ok, %Quote{symbol: "BTC-USD"}} =
               Gemini.get_price("BTC-USD",
                 plug: responding(@ticker),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_symbols/1", %{opts: opts} do
      assert {:ok, ["BTC-USD"]} =
               Gemini.get_symbols(
                 plug: responding(~w(btcusd)),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_order_book/2", %{opts: opts} do
      body = %{
        "bids" => [%{"price" => "1", "amount" => "2", "timestamp" => "1787936377"}],
        "asks" => []
      }

      assert {:ok, %OrderBook{symbol: "BTC-USD"}} =
               Gemini.get_order_book("BTC-USD",
                 plug: responding(body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_market_overview/1", %{opts: opts} do
      body = [%{"pair" => "BTCUSD", "price" => "1", "percentChange24h" => "0.1"}]

      assert {:ok, %{"BTC-USD" => _entry}} =
               Gemini.get_market_overview(
                 plug: responding(body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_historical_prices/4", %{opts: opts} do
      body = [[1_787_935_740_000, 1.0, 2.0, 0.5, 1.5, 3.0]]

      assert {:ok, [_candle]} =
               Gemini.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "an unsupported timeframe is refused at the facade, without a request" do
      assert {:error, {:unsupported_timeframe, "4h"}} =
               Gemini.get_historical_prices("BTC-USD", "4h")
    end
  end

  describe "quantization/1 is optional in the contract and implemented here" do
    test "it is NOT declared unsupported" do
      # Coinbase declares it unsupported; this venue publishes the numbers, so declaring
      # it unsupported would understate what the package can do.
      assert Gemini.capabilities().endpoints[{:quantization, 1}] == :experimental
    end
  end

  describe "streaming reaches the feed through the facade" do
    test "subscribe, coverage and unsubscribe round-trip", %{opts: opts} do
      feed = Process.whereis(opts[:feed])

      quote_struct = %Quote{
        symbol: "BTC-USD",
        price: Decimal.new("1"),
        timestamp: ~U[2026-08-28 12:00:00Z],
        provider: :gemini
      }

      # Delivering directly is what the socket does; the facade's job is the routing.
      send(feed, {:dp_exchange, :gemini, quote_struct})
      _settled = Gemini.coverage(feed: opts[:feed])

      assert Gemini.coverage(feed: opts[:feed]) == %{"BTC-USD" => :stream}
      assert Gemini.unsubscribe(["BTC-USD"], feed: opts[:feed]) == :ok
      assert Gemini.coverage(feed: opts[:feed]) == %{}
    end

    test "update_symbols/2 reaches the feed", %{opts: opts} do
      assert Gemini.update_symbols(["BTC-USD"], feed: opts[:feed]) == :ok
    end

    test "subscribe_notices/1 registers the caller", %{opts: opts} do
      assert Gemini.subscribe_notices(feed: opts[:feed], to: self()) == :ok

      send(
        Process.whereis(opts[:feed]),
        {:dp_exchange, :gemini, DpExchange.Core.Notice.new(:link_up, :gemini)}
      )

      assert_receive {:dp_exchange, :gemini, %DpExchange.Core.Notice{kind: :link_up}}
    end
  end

  describe "account and trading reach the venue through the facade" do
    @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}

    @order_body %{
      "order_id" => "1234",
      "symbol" => "btcusd",
      "side" => "buy",
      "type" => "exchange limit",
      "price" => "100.00",
      "original_amount" => "1",
      "executed_amount" => "0",
      "is_live" => true,
      "is_cancelled" => false,
      "timestampms" => 1_787_936_147_000
    }

    test "get_balances/2", %{opts: opts} do
      body = [%{"currency" => "USD", "amount" => "100.00", "available" => "90.00"}]

      assert {:ok, [%DpExchange.Core.Types.Balance{currency: "USD"}]} =
               Gemini.get_balances(@credentials,
                 plug: responding(body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_accounts/2", %{opts: opts} do
      assert {:ok, [_account]} =
               Gemini.get_accounts(@credentials,
                 plug: responding(%{"account" => "primary"}),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_fees/2", %{opts: opts} do
      assert {:ok, %{"api_maker_fee_bps" => 10}} =
               Gemini.get_fees(@credentials,
                 plug: responding(%{"api_maker_fee_bps" => 10}),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_transfers/2", %{opts: opts} do
      assert {:ok, []} =
               Gemini.get_transfers(@credentials,
                 plug: responding([]),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "place_order/3", %{opts: opts} do
      request = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100.00"}

      assert {:ok, %DpExchange.Core.Types.Order{id: "1234"}} =
               Gemini.place_order(@credentials, request,
                 plug: responding(@order_body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "place_order/3 refuses a market order without reaching the venue" do
      request = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "1", order_type: :market}

      assert {:error, {:unsupported_order_type, :market}} =
               Gemini.place_order(@credentials, request, retry_attempts: 0)
    end

    test "cancel_order/3", %{opts: opts} do
      body = %{@order_body | "is_live" => false, "is_cancelled" => true}

      assert {:ok, %DpExchange.Core.Types.Order{status: :cancelled}} =
               Gemini.cancel_order(@credentials, "1234",
                 plug: responding(body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_order/3", %{opts: opts} do
      assert {:ok, %DpExchange.Core.Types.Order{id: "1234"}} =
               Gemini.get_order(@credentials, "1234",
                 plug: responding(@order_body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_orders/2", %{opts: opts} do
      assert {:ok, [%DpExchange.Core.Types.Order{}]} =
               Gemini.get_orders(@credentials,
                 plug: responding([@order_body]),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_orders/2 stops at the first row it cannot read", %{opts: opts} do
      # A list where one entry is unreadable is not a list minus one entry. Dropping it
      # would report fewer open orders than the account actually has.
      assert {:error, :unexpected_response_shape} =
               Gemini.get_orders(@credentials,
                 plug: responding([@order_body, %{"nope" => true}]),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_trade_history/2", %{opts: opts} do
      body = [
        %{
          "order_id" => "1",
          "tid" => "2",
          "price" => "100",
          "amount" => "0.5",
          "type" => "Buy",
          "aggressor" => false,
          "timestampms" => 1_787_936_147_000
        }
      ]

      assert {:ok, [%DpExchange.Core.Types.Fill{liquidity: :maker}]} =
               Gemini.get_trade_history(@credentials,
                 symbol: "BTC-USD",
                 plug: responding(body),
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "test_connection/2 uses the venue's own authenticated heartbeat", %{opts: opts} do
      plug = fn conn ->
        assert conn.request_path == "/v1/heartbeat"
        Req.Test.json(conn, %{"result" => "ok"})
      end

      assert {:ok, %{reachable: true, environment: :production}} =
               Gemini.test_connection(@credentials,
                 plug: plug,
                 limiter: opts[:limiter],
                 retry_attempts: 0
               )
    end

    test "get_rate_limit_status/2 stays unsupported — no headers exist to report" do
      assert Gemini.get_rate_limit_status(@credentials, []) == {:error, :not_supported}
    end
  end

  describe "subscribe/2 through the facade" do
    # A stand-in socket speaking WebSockex's own `:gen.call` protocol, so the facade's
    # subscribe path runs end to end without reaching a venue.
    defp fake_socket(report_to) do
      spawn_link(fn -> accept_frames(report_to) end)
    end

    defp accept_frames(report_to) do
      receive do
        {:"$websockex_send", from, {:text, frame}} ->
          send(report_to, {:frame_sent, Jason.decode!(frame)})
          :gen.reply(from, :ok)
          accept_frames(report_to)
      end
    end

    test "reaches the feed and puts the venue's stream name on the wire" do
      name = :"facade_sub_#{System.unique_integer([:positive])}"
      {:ok, feed} = DpExchange.Gemini.Feed.start_link(name: name, socket: fake_socket(self()))

      assert :ok = Gemini.subscribe(["BTC-USD"], feed: name, to: self())

      assert_receive {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
      assert Process.alive?(feed)
    end

    test "coverage/1 accepts a pid as well as a name" do
      name = :"facade_pid_#{System.unique_integer([:positive])}"
      {:ok, feed} = DpExchange.Gemini.Feed.start_link(name: name, socket: fake_socket(self()))

      assert Gemini.coverage(feed: feed) == %{}
    end
  end

  describe "the money surface reaches the venue through the facade" do
    @money_creds %{api_key: "account-test", api_secret: "test-secret-not-real"}

    defp money_plug(body) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(body)
      end
    end

    # The facade points at the supervisor's limiter, which the setup starts. Passing it
    # through is what makes these exercise the real path rather than a bypass.
    defp money_opts(sup, body, extra \\ []) do
      Keyword.merge(
        [
          credentials: @money_creds,
          plug: money_plug(body),
          limiter: sup[:limiter],
          retry_attempts: 0
        ],
        extra
      )
    end

    test "get_deposit_address/3", %{opts: sup} do
      assert {:ok, address} =
               Gemini.get_deposit_address(
                 "BTC",
                 "bitcoin",
                 money_opts(sup, %{"address" => "mi98"})
               )

      assert address.network == "bitcoin"
    end

    test "list_approved_addresses/1", %{opts: sup} do
      body = %{"approvedAddresses" => [%{"address" => "0x1", "status" => "active"}]}

      assert {:ok, [address]} =
               Gemini.list_approved_addresses(money_opts(sup, body, network: "ethereum"))

      assert address.status == :active
    end

    test "estimate_withdrawal_fee/4", %{opts: sup} do
      assert {:ok, estimate} =
               Gemini.estimate_withdrawal_fee(
                 "ETH",
                 "ethereum",
                 Decimal.new("1"),
                 money_opts(sup, %{"fee" => "0.0005"}, address: "0xabc")
               )

      assert estimate.address == "0xabc"
    end

    test "withdraw/5", %{opts: sup} do
      assert {:ok, withdrawal} =
               Gemini.withdraw(
                 "ETH",
                 "ethereum",
                 Decimal.new("1"),
                 "0xabc",
                 money_opts(sup, %{"withdrawalId" => "w-1"})
               )

      assert withdrawal.status == :pending
    end

    test "list_payment_methods/2 and add_payment_method/2", %{opts: sup} do
      assert {:ok, [_method]} =
               Gemini.list_payment_methods(@money_creds, money_opts(sup, [%{"id" => "b-1"}]))

      assert {:ok, _added} =
               Gemini.add_payment_method(
                 %{"accountNumber" => "1"},
                 money_opts(sup, %{"id" => "b-2"})
               )
    end

    test "transfer_internal/4", %{opts: sup} do
      assert {:ok, _transfer} =
               Gemini.transfer_internal(
                 "BTC",
                 Decimal.new("1"),
                 [from: "a", to: "b"],
                 money_opts(sup, %{"ok" => true})
               )
    end

    test "request_approved_address/4 and remove_approved_address/3", %{opts: sup} do
      assert {:ok, _requested} =
               Gemini.request_approved_address(
                 "ethereum",
                 "0xabc",
                 "desk",
                 money_opts(sup, %{"status" => "pending-time"})
               )

      assert {:ok, _removed} =
               Gemini.remove_approved_address(
                 "ethereum",
                 "0xabc",
                 money_opts(sup, %{"ok" => true})
               )
    end

    test "get_transactions/2", %{opts: sup} do
      assert {:ok, [_row]} =
               Gemini.get_transactions(@money_creds, money_opts(sup, [%{"type" => "Trade"}]))
    end

    test "list_networks/2 and list_fee_promos/1", %{opts: sup} do
      assert {:ok, [_row]} = Gemini.list_networks("USDC", money_opts(sup, [%{"token" => "USDC"}]))

      assert {:ok, [_promo]} =
               Gemini.list_fee_promos(money_opts(sup, %{"symbols" => ["btcusd"]}))
    end

    test "get_fx_rate/3", %{opts: sup} do
      body = %{"fxPair" => "AUDUSD", "rate" => "0.69", "provider" => "bcb"}

      assert {:ok, rate} =
               Gemini.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z], money_opts(sup, body))

      assert rate.source == "bcb"
    end

    test "get_notional_balances/3", %{opts: sup} do
      rows = [%{"currency" => "BTC", "amount" => "1", "amountNotional" => "40000"}]

      assert {:ok, [row]} =
               Gemini.get_notional_balances(@money_creds, "usd", money_opts(sup, rows))

      assert row["amountNotional"] == "40000"
    end

    test "list_custody_fees/2", %{opts: sup} do
      rows = [%{"currency" => "BTC", "amount" => "0.0001"}]
      assert {:ok, [_fee]} = Gemini.list_custody_fees(@money_creds, money_opts(sup, rows))
    end

    test "get_payment_method/3 refuses rather than filtering the listing" do
      assert {:error, :not_supported} = Gemini.get_payment_method(@money_creds, "bank-1")
    end

    test "get_staking_rates/1", %{opts: sup} do
      body = %{"ETH" => %{"provider-a" => %{"ratePct" => "4.0"}}}

      assert {:ok, [rate]} =
               Gemini.get_staking_rates(Keyword.merge(money_opts(sup, body), credentials: nil))

      assert rate.provider_id == "provider-a"
    end

    test "get_staking_balances/1", %{opts: sup} do
      rows = [%{"currency" => "ETH", "balance" => "10"}]
      assert {:ok, [balance]} = Gemini.get_staking_balances(money_opts(sup, rows))
      assert balance.asset == "ETH"
    end

    test "get_staking_rewards/1", %{opts: sup} do
      rows = [%{"currency" => "ETH", "amount" => "0.1"}]
      assert {:ok, [_reward]} = Gemini.get_staking_rewards(money_opts(sup, rows))
    end

    test "get_staking_history/1", %{opts: sup} do
      rows = [%{"transactionType" => "Redeem", "currency" => "ETH", "amount" => "1"}]
      assert {:ok, [tx]} = Gemini.get_staking_history(money_opts(sup, rows))
      assert tx.type == :unstake
    end

    test "stake/3 and unstake/3 both reach the venue", %{opts: sup} do
      body = %{"transactionType" => "Deposit", "currency" => "ETH", "amount" => "1"}

      assert {:ok, _tx} =
               Gemini.stake(
                 "ETH",
                 Decimal.new("1"),
                 money_opts(sup, body, provider_id: "provider-a")
               )

      assert {:ok, _tx} =
               Gemini.unstake(
                 "ETH",
                 Decimal.new("1"),
                 money_opts(sup, body, provider_id: "provider-a")
               )
    end

    test "get_positions/1", %{opts: sup} do
      body = %{"openPositions" => [%{"symbol" => "BTCGUSDPERP", "quantity" => "-1"}]}
      assert {:ok, [position]} = Gemini.get_positions(money_opts(sup, body))
      assert position.side == :short
    end

    test "get_funding/2 and get_contract_stats/2 are public", %{opts: sup} do
      funding = %{"symbol" => "BTCGUSDPERP", "amount" => -1.5}

      assert {:ok, %{symbol: "BTCGUSDPERP"}} =
               Gemini.get_funding(
                 "BTCGUSDPERP",
                 Keyword.merge(money_opts(sup, funding), credentials: nil)
               )

      assert {:ok, %{mark_price: mark}} =
               Gemini.get_contract_stats(
                 "BTCGUSDPERP",
                 Keyword.merge(money_opts(sup, %{"mark_price" => "1"}), credentials: nil)
               )

      assert Decimal.equal?(mark, Decimal.new("1"))
    end

    test "next_funding_timestamp/2", %{opts: sup} do
      assert {:ok, %DateTime{}} =
               Gemini.next_funding_timestamp(
                 "BTCGUSDPERP",
                 Keyword.merge(money_opts(sup, 1_787_940_001_000), credentials: nil)
               )
    end

    test "get_account_margin/1 and list_funding_payments/1", %{opts: sup} do
      assert {:ok, %{"leverage" => "1.5"}} =
               Gemini.get_account_margin(money_opts(sup, %{"leverage" => "1.5"}))

      assert {:ok, [_payment]} =
               Gemini.list_funding_payments(money_opts(sup, [%{"eventType" => "x"}]))
    end

    test "the three reports", %{opts: sup} do
      assert {:ok, []} = Gemini.funding_payment_report(money_opts(sup, []))

      assert {:ok, _bytes} =
               Gemini.funding_amount_report("BTCGUSDPERP", money_opts(sup, %{}))

      assert {:ok, _bytes} = Gemini.funding_payment_report_file(money_opts(sup, %{}))
    end

    test "the spot margin trio", %{opts: sup} do
      assert {:ok, %{"leverage" => "1.5"}} =
               Gemini.get_margin_account(money_opts(sup, %{"leverage" => "1.5"}))

      assert {:ok, [_rate]} =
               Gemini.get_margin_rates(money_opts(sup, %{"rates" => [%{"currency" => "BTC"}]}))

      assert {:ok, _preview} =
               Gemini.preview_margin_order(
                 %{symbol: "BTC-USD", side: :sell, type: :market, amount: Decimal.new("1")},
                 money_opts(sup, %{"preorder" => %{}})
               )
    end
  end

  describe "a private call with no credentials never reaches the network" do
    # Every one of these is called at its **shortest arity**, with no options at all — no
    # credentials, no plug, no base URL. Each must come back as a credential error, and the
    # absence of a plug is the assertion: if any of them built a request, the test would
    # fail on a connection rather than on a refusal.
    #
    # This is also the only thing that exercises each function's defaulted-argument head. A
    # facade function whose default `opts \\ []` was wired to the wrong helper compiles, and
    # is never called at that arity by anything else in this suite.

    test "the perpetuals and margin reads refuse" do
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_positions()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_account_margin()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.list_funding_payments()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.funding_payment_report()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_margin_account()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_margin_rates()
    end

    test "the report files refuse" do
      assert {:error, {:unsupported_auth_scheme, nil}} =
               Gemini.funding_amount_report("BTCGUSDPERP")

      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.funding_payment_report_file()
    end

    test "the margin preview refuses on its own fields before it refuses on credentials" do
      # Order of refusal matters: a request this package cannot build is not a credential
      # problem, and reporting it as one sends the reader to the wrong place.
      assert {:error, :missing_order_fields} = Gemini.preview_margin_order(%{side: :buy})
    end

    test "the staking reads and writes refuse" do
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_staking_balances()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_staking_rewards()
      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.get_staking_history()
      assert {:error, :missing_provider_id} = Gemini.stake("ETH", Decimal.new("1"))
      assert {:error, :missing_provider_id} = Gemini.unstake("ETH", Decimal.new("1"))
    end

    test "the money-movement writes refuse" do
      # Two of these refuse on a **missing argument** before they look at a credential, and
      # that order is the point: a request this package cannot build is not an auth failure,
      # and reporting it as one sends the reader looking at the wrong thing.
      assert {:error, {:missing_option, :network}} = Gemini.list_approved_addresses()

      assert {:error, {:missing_option, :address}} =
               Gemini.estimate_withdrawal_fee("BTC", "bitcoin", Decimal.new("1"))

      assert {:error, {:unsupported_auth_scheme, nil}} = Gemini.add_payment_method(%{})

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Gemini.get_deposit_address("BTC", "bitcoin")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Gemini.withdraw("BTC", "bitcoin", Decimal.new("1"), "addr")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Gemini.transfer_internal("BTC", Decimal.new("1"), from: "a", to: "b")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Gemini.request_approved_address("ethereum", "0xabc", "label")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Gemini.remove_approved_address("ethereum", "0xabc")
    end

    test "the conversion calls refuse, and one of them on direction first" do
      # `convert/3` cannot tell which way "BTC to USD" goes without a side, and it says so
      # before it looks at a credential — an ambiguous conversion is not an auth failure.
      assert {:error, {:ambiguous_conversion, "BTC", "USD"}} =
               Gemini.convert("BTC", "USD", Decimal.new("1"))

      assert {:error, {:ambiguous_conversion, "BTC", "USD"}} =
               Gemini.quote_conversion("BTC", "USD", Decimal.new("1"))

      assert {:error, {:missing_option, [:symbol, :side, :amount, :price]}} =
               Gemini.commit_conversion("q-1")
    end
  end
end
