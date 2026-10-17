defmodule DpExchange.Gemini.TickAjRobustnessTest do
  @moduledoc """
  Tick AJ: response-parsing robustness. A reply the decoder cannot place is a refusal or an
  honest `nil`, never a nearby substitute that keeps every other field real.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> Req.Test.json(body)
    end
  end

  defp read_order(body),
    do: Private.get_order(@credentials, "1234", plug: responding(body), retry_attempts: 0)

  describe "get_symbols/1 — a catalogue with a hole in it is refused" do
    test "a null, a number or an object among the symbols refuses the whole listing" do
      for bad <- [nil, 7, %{"symbol" => "ethusd"}, ["ethusd"]] do
        body = ["btcusd", bad, "aavegusd"]

        assert Rest.get_symbols(plug: responding(body), retry_attempts: 0) ==
                 {:error, :unexpected_response_shape}
      end
    end

    test "an all-text listing still decodes, perpetuals excluded" do
      assert {:ok, ["BTC-USD"]} =
               Rest.get_symbols(
                 plug: responding(["btcusd", "avaxgusdperp"]),
                 retry_attempts: 0
               )
    end
  end

  describe "quote_conversion/4 — a stated figure is read or the reply is refused" do
    @quote_body %{
      "quoteId" => 1234,
      "side" => "buy",
      "totalSpend" => "100",
      "quantity" => "0.5",
      "price" => "200",
      "fee" => "0",
      "maxAgeMs" => 60_000
    }

    defp quote_with(body) do
      Private.quote_conversion("USDC", "AAVE", Decimal.new(100),
        credentials: @credentials,
        plug: responding(body),
        retry_attempts: 0
      )
    end

    test "readable figures decode, and an absent or null fee or price is nil" do
      assert {:ok, conversion} = quote_with(@quote_body)
      assert Decimal.equal?(conversion.rate, Decimal.new(200))

      assert {:ok, bare} = quote_with(Map.merge(@quote_body, %{"price" => nil, "fee" => nil}))
      assert bare.rate == nil
      assert bare.fee == nil
    end

    test "a price, fee, spend or quantity that is present but unreadable refuses" do
      for key <- ["price", "fee", "totalSpend", "quantity"],
          bad <- ["NaN", "abc", true, %{}] do
        assert quote_with(Map.put(@quote_body, key, bad)) ==
                 {:error, :unexpected_response_shape}
      end
    end
  end

  describe "an order's type is mapped, or it is nil" do
    test "the documented limit spellings are :limit" do
      for type <- ["exchange limit", "limit"] do
        assert {:ok, order} = read_order(Map.put(@order, "type", type))
        assert order.order_type == :limit
      end
    end

    test "a limit with an execution option keeps that option's type" do
      body = Map.put(@order, "options", ["maker-or-cancel"])

      assert {:ok, order} = read_order(body)
      assert order.order_type == :post_only
    end

    test "an unknown type string is nil, not an ordinary limit" do
      for type <- ["auction-only limit", "block_trade", "indication-of-interest limit", 7] do
        assert {:ok, order} = read_order(Map.put(@order, "type", type))
        assert order.order_type == nil
      end
    end

    test "an unknown type does not borrow a type from the options array" do
      body = @order |> Map.put("type", "block_trade") |> Map.put("options", ["fill-or-kill"])

      assert {:ok, order} = read_order(body)
      assert order.order_type == nil
    end

    test "a null or absent type falls back to the options, then :limit" do
      assert {:ok, %{order_type: :limit}} = read_order(Map.put(@order, "type", nil))
      assert {:ok, %{order_type: :limit}} = read_order(Map.delete(@order, "type"))

      body = @order |> Map.delete("type") |> Map.put("options", ["immediate-or-cancel"])
      assert {:ok, %{order_type: :ioc}} = read_order(body)
    end
  end
end
