defmodule DpExchange.Gemini.UnboundedDecimalTest do
  @moduledoc """
  A venue number whose exponent no price or size has, and the public ticker and funding reads
  that used to answer from a body that said nothing.

  `Decimal.parse("1e999999999")` succeeds, and `Decimal.compare/2`, `Decimal.add/2` and the
  sort every book goes through align exponents by building an integer of that many digits.
  One string from the venue stalled the process that decoded it, so every copy of `decimal/1`
  in this package now refuses an exponent outside -100..100 as it refuses NaN and Infinity.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Private, Rest, WsDecode}

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

  @date "Fri, 28 Aug 2026 17:00:01 GMT"
  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}

  defp json(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp raw(bytes) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, bytes)
    end
  end

  describe "an exponent no price has is unreadable, not a number" do
    test "REST: a trade priced 1e999999999 is refused" do
      body = ~s([{"tid": 1, "timestampms": 1787936377000, "price": "1e999999999",
                  "amount": "1", "type": "buy"}])

      assert {:error, {:invalid_decimal, :price, "1e999999999"}} =
               Rest.get_trades("BTC-USD", plug: raw(body), retry_attempts: 0)
    end

    test "REST: a JSON number with that exponent is refused too (floats: :decimals)" do
      body = ~s([{"tid": 1, "timestampms": 1787936377000, "price": 1e999999999,
                  "amount": 1, "type": "buy"}])

      # The decoder itself refuses the body (Decimal will not build that number), so the
      # refusal is the whole reply's, before any price is read.
      assert {:error, {:undecodable_response, :gemini}} =
               Rest.get_trades("BTC-USD", plug: raw(body), retry_attempts: 0)
    end

    test "REST: a book level with that exponent refuses the book instead of sorting it" do
      body = %{
        "bids" => [
          %{"price" => "1e999999999", "amount" => "1"},
          %{"price" => "100", "amount" => "1"}
        ],
        "asks" => []
      }

      assert {:error, :unexpected_response_shape} =
               Rest.get_order_book("BTC-USD", plug: json(body), retry_attempts: 0)
    end

    test "REST: an ordinary small exponent is still a number" do
      body = %{
        "bids" => [%{"price" => "0.00000001", "amount" => "1E-8"}],
        "asks" => [%{"price" => "1.7E12", "amount" => "1"}]
      }

      assert {:ok, book} = Rest.get_order_book("BTC-USD", plug: json(body), retry_attempts: 0)
      assert [{bid, _qty}] = book.bids
      assert Decimal.equal?(bid, Decimal.new("0.00000001"))
    end

    test "socket decoder: a bookTicker bid with that exponent is refused" do
      assert {:error, :unexpected_frame_shape} =
               WsDecode.to_top_of_book(
                 %{"b" => "1e999999999", "a" => "2"},
                 "BTC-USD",
                 DateTime.utc_now()
               )
    end

    test "socket decoder: a depth diff row with that exponent is refused" do
      frame = %{"E" => 1_787_936_377_000_000_000, "u" => 5, "b" => [["1e999999999", "1"]]}

      assert {:error, :unexpected_response_shape} = WsDecode.to_order_book_delta(frame, "BTC-USD")
    end

    test "Private: an available balance with that exponent leaves hold nil" do
      body = [%{"currency" => "USD", "amount" => "100.00", "available" => "1e999999999"}]

      assert {:ok, [balance]} =
               Private.get_balances(@credentials, plug: json(body), retry_attempts: 0)

      assert balance.hold == nil
    end
  end

  describe "get_top_of_book/2 needs a ticker, not just an object" do
    test "an object naming neither side is refused, not a book with no orders" do
      for body <- [%{}, %{"unexpected" => true}, %{"last" => "1.5"}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_top_of_book("BTC-USD", plug: json(body), retry_attempts: 0)
      end
    end

    test "a side the venue states as empty is an absent side, not a refusal" do
      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD",
                 plug: json(%{"bid" => "", "ask" => "2", "last" => "1"}),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert Decimal.equal?(top.ask, Decimal.new("2"))
    end
  end

  describe "quantization/2: absent is unstated, present and unreadable is malformed" do
    @details %{
      "quote_increment" => "0.01",
      "tick_size" => "1e-8",
      "min_order_size" => "0.00001",
      "status" => "open"
    }

    test "an absent or null field stays nil" do
      body = @details |> Map.delete("min_order_size") |> Map.put("tick_size", nil)

      assert {:ok, q} = Rest.quantization("BTC-USD", plug: json(body), retry_attempts: 0)
      assert q.min_quantity == nil
      assert q.quantity_increment == nil
      assert Decimal.equal?(q.price_increment, Decimal.new("0.01"))
    end

    test "a present field this package cannot read is a malformed reply" do
      for {field, bad} <- [
            {"quote_increment", "abc"},
            {"tick_size", "NaN"},
            {"min_order_size", "1e999999999"},
            {"tick_size", ""},
            {"quote_increment", true},
            {"min_order_size", %{"x" => 1}},
            {"status", 5}
          ] do
        body = Map.put(@details, field, bad)

        assert {:error, :unexpected_response_shape} =
                 Rest.quantization("BTC-USD", plug: json(body), retry_attempts: 0),
               "#{field}: #{inspect(bad)} must be refused"
      end
    end
  end

  describe "get_market_overview/1: absent is unstated, present and unreadable is malformed" do
    test "a row without a change keeps nil, not a refusal" do
      body = [%{"pair" => "BTCUSD", "price" => "100"}]

      assert {:ok, %{"BTC-USD" => entry}} =
               Rest.get_market_overview(plug: json(body), retry_attempts: 0)

      assert entry.change_24h == nil
      assert Decimal.equal?(entry.price, Decimal.new("100"))
    end

    test "one unreadable present field refuses the whole overview" do
      for bad <- ["abc", "Infinity", "1e999999999", "", false, [1]],
          field <- ["price", "percentChange24h"] do
        good = %{"price" => "5", "percentChange24h" => "1"}
        row = good |> Map.put("pair", "ETHUSD") |> Map.put(field, bad)
        body = [Map.put(good, "pair", "BTCUSD"), row]

        assert {:error, :unexpected_response_shape} =
                 Rest.get_market_overview(plug: json(body), retry_attempts: 0),
               "#{field}: #{inspect(bad)} must be refused"
      end
    end
  end

  describe "Private amounts: an exponent no amount has is not signed" do
    test "a Decimal with a huge exponent is refused before it is written out" do
      huge = %Decimal{sign: 1, coef: 1, exp: 999_999_999}

      assert {:error, {:invalid_decimal, :amount, ^huge}} =
               Private.validate_amount(huge, :amount)

      assert {:ok, "0.00000001"} = Private.validate_amount(Decimal.new("1E-8"), :amount)
    end
  end

  describe "funding timestamps" do
    test "a zero or negative epoch is unstated, not 1970" do
      body = %{
        "symbol" => "BTCGUSDPERP",
        "amount" => "1",
        "estimatedFundingAmount" => "1",
        "fundingTimestampMilliSecs" => 0,
        "nextFundingTimestamp" => -5
      }

      assert {:ok, funding} =
               Rest.get_funding("BTCGUSDPERP", plug: json(body), retry_attempts: 0)

      assert funding.funded_at == nil
      assert funding.next_funding_at == nil
    end

    test "next_funding_timestamp/2 refuses a zero body" do
      assert {:error, :unexpected_response_shape} =
               Rest.next_funding_timestamp("BTCGUSDPERP", plug: json(0), retry_attempts: 0)
    end
  end
end
