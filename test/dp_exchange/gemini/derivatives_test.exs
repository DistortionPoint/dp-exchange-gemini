defmodule DpExchange.Gemini.DerivativesTest do
  @moduledoc """
  Perpetuals and margin.

  **Three assertions carry this file, and each is a number that stays plausible when it is
  wrong.**

  A short arrives as a negative quantity, and `Types.Position` refuses to carry one: a
  package that passed the sign through hands a caller a position that is exactly backwards.
  Settled funding and estimated funding differ by 40% in a real response, and a caller
  reading "the funding" books a number that had not happened. And a private GET signs the
  **full path including its query string** — signing the bare path yields a valid signature
  over the wrong string, which the venue reports as a credential problem.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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
        |> case do
          nil -> %{}
          encoded -> encoded |> Base.decode64!() |> Jason.decode!()
        end

      send(test_pid, {:request, conn.request_path, conn.query_string, payload})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  describe "get_funding/2 — settled is not estimated" do
    test "both amounts and both timestamps survive" do
      body = %{
        "symbol" => "BTCGUSDPERP",
        "amount" => -1.50991,
        "estimatedFundingAmount" => -2.10595,
        "fundingTimestampMilliSecs" => 1_787_936_401_000,
        "nextFundingTimestamp" => 1_787_940_001_000
      }

      assert {:ok, funding} =
               Rest.get_funding("BTCGUSDPERP", plug: responding(body), retry_attempts: 0)

      assert %Types.Funding{} = funding
      assert Decimal.equal?(funding.amount, Decimal.from_float(-1.50991))
      assert Decimal.equal?(funding.estimated_amount, Decimal.from_float(-2.10595))
      refute Decimal.equal?(funding.amount, funding.estimated_amount)
      assert funding.funded_at == DateTime.from_unix!(1_787_936_401_000, :millisecond)
      assert funding.next_funding_at == DateTime.from_unix!(1_787_940_001_000, :millisecond)
    end

    test "the sign is carried through rather than normalised" do
      # A negative amount means one side paid the other, and which is which is a venue
      # convention this layer does not reinterpret.
      body = %{"symbol" => "BTCGUSDPERP", "amount" => -1.5, "estimatedFundingAmount" => 2.0}

      assert {:ok, funding} =
               Rest.get_funding("BTCGUSDPERP", plug: responding(body), retry_attempts: 0)

      assert Decimal.negative?(funding.amount)
      refute Decimal.negative?(funding.estimated_amount)
    end
  end

  describe "next_funding_timestamp/2 — a bare integer" do
    test "an integer body becomes a DateTime" do
      assert {:ok, at} =
               Rest.next_funding_timestamp("BTCGUSDPERP",
                 plug: responding(1_787_940_001_000),
                 retry_attempts: 0
               )

      assert at == DateTime.from_unix!(1_787_940_001_000, :millisecond)
    end

    test "a body that is not an integer is unreadable, not a nil timestamp" do
      # "The venue said something else" and "there is no next funding" are different
      # answers, and the second would be remarkable on a perpetual.
      assert {:error, :unexpected_response_shape} =
               Rest.next_funding_timestamp("BTCGUSDPERP",
                 plug: responding(%{"unexpected" => true}),
                 retry_attempts: 0
               )
    end
  end

  describe "get_contract_stats/2 — three prices, none of them the other" do
    test "mark and index stay apart" do
      body = %{
        "product_type" => "PerpetualSwapContract",
        "mark_price" => "59500",
        "index_price" => "59480",
        "open_interest" => "1240",
        "open_interest_notional" => "73780000"
      }

      assert {:ok, stats} =
               Rest.get_contract_stats("BTCGUSDPERP", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(stats.mark_price, Decimal.new("59500"))
      assert Decimal.equal?(stats.index_price, Decimal.new("59480"))
      refute Decimal.equal?(stats.mark_price, stats.index_price)
    end

    test "open interest arrives in contracts and in notional" do
      body = %{"open_interest" => "1240", "open_interest_notional" => "73780000"}

      assert {:ok, stats} =
               Rest.get_contract_stats("BTCGUSDPERP", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(stats.open_interest, Decimal.new("1240"))
      assert Decimal.equal?(stats.open_interest_notional, Decimal.new("73780000"))
    end

    test "venue_time is nil rather than the local clock" do
      # This endpoint publishes no timestamp. Stamping one makes a stale response
      # indistinguishable from a current one.
      assert {:ok, stats} =
               Rest.get_contract_stats("BTCGUSDPERP",
                 plug: responding(%{"mark_price" => "1"}),
                 retry_attempts: 0
               )

      assert stats.venue_time == nil
    end
  end

  describe "get_positions/2 — the sign convention" do
    test "a negative quantity becomes a positive size and an explicit short" do
      body = %{
        "openPositions" => [
          %{
            "symbol" => "BTCGUSDPERP",
            "instrument_type" => "perp",
            "quantity" => "-0.2",
            "notional_value" => "-11900",
            "realised_pnl" => "12.5",
            "unrealised_pnl" => "100",
            "average_cost" => "60000",
            "mark_price" => "59500"
          }
        ]
      }

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == :short
      assert Decimal.equal?(position.quantity, Decimal.new("0.2"))
      refute Decimal.negative?(position.quantity)
    end

    test "a positive quantity is a long" do
      body = %{"openPositions" => [%{"symbol" => "BTCGUSDPERP", "quantity" => "0.2"}]}

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == :long
    end

    test "a zero quantity has no side, because guessing one invents a direction" do
      body = %{"openPositions" => [%{"symbol" => "BTCGUSDPERP", "quantity" => "0"}]}

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == nil
    end

    test "notional value keeps the venue's sign, unlike quantity" do
      # It is a value, not a magnitude with a direction beside it; flipping it would change
      # what the number means.
      body = %{"openPositions" => [%{"quantity" => "-0.2", "notional_value" => "-11900"}]}

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.negative?(position.notional_value)
    end

    test "realised and unrealised P&L are never merged" do
      body = %{
        "openPositions" => [
          %{"quantity" => "1", "realised_pnl" => "12.5", "unrealised_pnl" => "100"}
        ]
      }

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(position.realised_pnl, Decimal.new("12.5"))
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("100"))
    end

    test "liquidation price is nil here, and that does not mean safe" do
      body = %{"openPositions" => [%{"quantity" => "1"}]}

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.liquidation_price == nil
    end

    test "no open positions is an empty list" do
      assert {:ok, []} =
               Private.get_positions(@credentials,
                 plug: responding(%{"openPositions" => []}),
                 retry_attempts: 0
               )
    end
  end

  describe "the account-scoped perpetuals reads" do
    test "the margin account carries the liquidation price positions do not" do
      body = %{
        "margin_assets_value" => "10000",
        "initial_margin" => "2500",
        "available_margin" => "7500",
        "estimated_liquidation_price" => "42000"
      }

      assert {:ok, margin} =
               Private.get_account_margin(@credentials, plug: responding(body), retry_attempts: 0)

      assert margin["estimated_liquidation_price"] == "42000"
    end

    test "funding payments keep the venue's Credit/Debit rather than a sign" do
      rows = [
        %{
          "eventType" => "Hourly Funding Transfer",
          "hourlyFundingTransfer" => %{
            "action" => "Debit",
            "assetCode" => "GUSD",
            "quantity" => %{"currency" => "GUSD", "value" => "1.50991"}
          }
        }
      ]

      assert {:ok, [payment]} =
               Private.list_funding_payments(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert payment["hourlyFundingTransfer"]["action"] == "Debit"
      # A positive quantity beside a direction, not a signed number.
      assert payment["hourlyFundingTransfer"]["quantity"]["value"] == "1.50991"
    end
  end

  describe "the reports — what gets signed" do
    test "the JSON report signs the path with its query string attached" do
      # Signing the bare path yields a valid signature over the wrong string, which the
      # venue reports as a credential problem rather than a parameter one.
      me = self()

      assert {:ok, []} =
               Private.funding_payment_report(@credentials,
                 from: ~D[2024-04-10],
                 to: ~D[2024-04-25],
                 rows: 1000,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query, payload}
      assert path == "/v1/perpetuals/fundingpaymentreport/records.json"
      assert query =~ "fromDate=2024-04-10"
      assert payload["request"] == path <> "?" <> query
    end

    test "no dates means no date parameters, and the venue's own default row count" do
      # A page size chosen here would silently truncate a report the caller asked for in
      # full.
      me = self()

      assert {:ok, []} =
               Private.funding_payment_report(@credentials,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query, payload}
      assert query == ""
      assert payload["request"] == path
    end

    test "one date without the other is refused before the request" do
      # The venue makes each mandatory if the other is present; one alone comes back bounded
      # by numRows instead, which is a real report over the wrong window.
      assert {:error, :from_and_to_together} =
               Private.funding_amount_report("BTCGUSDPERP", @credentials, from: ~D[2024-04-10])

      assert {:error, :from_and_to_together} =
               Private.funding_payment_report_file(@credentials, to: ~D[2024-04-25])
    end

    test "the spreadsheet comes back as bytes, not as a parsed map" do
      # A parsed cell is a number this package chose from a layout the venue can change.
      xlsx = <<0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02>>

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.ms-excel")
        |> Plug.Conn.resp(200, xlsx)
      end

      assert {:ok, ^xlsx} =
               Private.funding_amount_report("BTCGUSDPERP", @credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "the symbol reaches the amount report's query" do
      me = self()

      plug = fn conn ->
        send(me, {:request, conn.request_path, conn.query_string, %{}})
        Plug.Conn.resp(conn, 200, "bytes")
      end

      assert {:ok, "bytes"} =
               Private.funding_amount_report("BTCGUSDPERP", @credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:request, "/v1/fundingamountreport/records.xlsx", query, _payload}
      assert query =~ "symbol=BTCGUSDPERP"
    end

    test "the payment report file takes no symbol, because a payment is the account's" do
      me = self()

      plug = fn conn ->
        send(me, {:request, conn.request_path, conn.query_string, %{}})
        Plug.Conn.resp(conn, 200, "bytes")
      end

      assert {:ok, "bytes"} =
               Private.funding_payment_report_file(@credentials, plug: plug, retry_attempts: 0)

      assert_receive {:request, path, query, _payload}
      assert path == "/v1/perpetuals/fundingpaymentreport/records.xlsx"
      refute query =~ "symbol"
    end
  end

  describe "spot margin — a different system from the perpetuals one" do
    test "amounts arrive with their currency attached, and keep it" do
      # Flattening the currency off an amount is how a caller adds a BTC number to a USD one.
      body = %{
        "marginAssetValue" => %{"currency" => "USD", "value" => "10000.00"},
        "totalBorrowed" => %{"currency" => "BTC", "value" => "0.5"},
        "leverage" => "1.5"
      }

      assert {:ok, summary} =
               Private.get_margin_account(@credentials, plug: responding(body), retry_attempts: 0)

      assert summary["marginAssetValue"]["currency"] == "USD"
      assert summary["totalBorrowed"]["currency"] == "BTC"
    end

    test "all three borrow rates travel" do
      # Taking the hourly rate for the annual one is an error of four orders of magnitude
      # that still looks like a rate.
      body = %{
        "rates" => [
          %{
            "currency" => "BTC",
            "borrowRate" => "0.00001141552511",
            "borrowRateDaily" => "0.00027397260264",
            "borrowRateAnnual" => "0.1",
            "lastUpdated" => 1_700_000_000_000
          }
        ]
      }

      assert {:ok, [rate]} =
               Private.get_margin_rates(@credentials, plug: responding(body), retry_attempts: 0)

      assert rate["borrowRate"] != rate["borrowRateDaily"]
      assert rate["borrowRateAnnual"] == "0.1"
    end

    test "a market buy is sized in quote currency, and refuses an amount" do
      # The venue's own rule. Sending `amount` on a market buy previews a different order
      # than the caller described.
      assert {:error, :total_spend_required} =
               Private.preview_margin_order(
                 %{symbol: "BTC-USD", side: :buy, type: :market, amount: Decimal.new("0.5")},
                 @credentials,
                 []
               )
    end

    test "a market buy with total_spend reaches the venue" do
      me = self()

      assert {:ok, _preview} =
               Private.preview_margin_order(
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   type: :market,
                   total_spend: Decimal.new("25000")
                 },
                 @credentials,
                 plug: capturing(%{"preorder" => %{}, "postorder" => %{}}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "/v1/margin/order/preview", _query, payload}
      assert payload["totalSpend"] == "25000"
      assert payload["symbol"] == "btcusd"
      refute Map.has_key?(payload, "amount")
    end

    test "a limit order needs both an amount and a price" do
      assert {:error, :amount_required} =
               Private.preview_margin_order(
                 %{symbol: "BTC-USD", side: :buy, type: :limit, price: Decimal.new("50000")},
                 @credentials,
                 []
               )

      assert {:error, :price_required} =
               Private.preview_margin_order(
                 %{symbol: "BTC-USD", side: :buy, type: :limit, amount: Decimal.new("0.5")},
                 @credentials,
                 []
               )
    end

    test "a market sell is sized in base currency" do
      me = self()

      assert {:ok, _preview} =
               Private.preview_margin_order(
                 %{symbol: "BTC-USD", side: :sell, type: :market, amount: Decimal.new("0.5")},
                 @credentials,
                 plug: capturing(%{"preorder" => %{}}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, _query, payload}
      assert payload["amount"] == "0.5"
      refute Map.has_key?(payload, "totalSpend")
    end

    test "a request missing the three required fields is refused" do
      assert {:error, :missing_order_fields} =
               Private.preview_margin_order(%{side: :buy}, @credentials, [])
    end

    test "a small amount is sent in full notation, not scientific" do
      me = self()

      assert {:ok, _preview} =
               Private.preview_margin_order(
                 %{
                   symbol: "BTC-USD",
                   side: :sell,
                   type: :market,
                   amount: Decimal.new("0.00000001")
                 },
                 @credentials,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, _query, payload}
      assert payload["amount"] == "0.00000001"
    end
  end
end
