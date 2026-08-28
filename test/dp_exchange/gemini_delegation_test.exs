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
end
