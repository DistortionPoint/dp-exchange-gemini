defmodule DpExchange.Gemini.PrivateReviewTest do
  @moduledoc """
  Defects found reading `Private` in the second Tick I round: a fill symbol echoed in the
  caller's spelling, a non-string asset that raised before anything was signed, and an OAuth
  refusal body handed back as raw bytes.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Fake, Private}

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

  defp json(body) do
    fn conn ->
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
    "executed_amount" => "0.5",
    "avg_execution_price" => "99.00",
    "is_live" => true,
    "is_cancelled" => false,
    "timestampms" => 1_787_936_147_000
  }

  describe "an order row with a present but unreadable numeric field" do
    test "get_order/3 and get_orders/2 fail closed, for every such field" do
      for {field, bad} <- [
            {"original_amount", "abc"},
            {"price", "NaN"},
            {"price", ""},
            {"stop_price", "1e999999999"},
            {"executed_amount", true},
            {"avg_execution_price", "x"},
            {"timestampms", "later"}
          ] do
        body = Map.put(@order, field, bad)

        assert {:error, :unexpected_response_shape} =
                 Private.get_order(@credentials, "1", plug: json(body), retry_attempts: 0),
               "get_order #{field}: #{inspect(bad)}"

        assert {:error, :unexpected_response_shape} =
                 Private.get_orders(@credentials, plug: json([@order, body]), retry_attempts: 0),
               "get_orders #{field}: #{inspect(bad)}"
      end
    end

    test "an absent or null field stays nil" do
      body = @order |> Map.delete("price") |> Map.put("stop_price", nil)

      assert {:ok, order} =
               Private.get_order(@credentials, "1", plug: json(body), retry_attempts: 0)

      assert order.price == nil
      assert order.stop_price == nil
    end

    test "place_order/3 still returns the order it placed, with the field nil" do
      body = Map.put(@order, "price", "garbage")

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "1",
        price: "100.00",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, order} =
               Private.place_order(@credentials, request, plug: json(body), retry_attempts: 0)

      assert order.id == "1234"
      assert order.price == nil
    end
  end

  describe "a fill row that names no symbol" do
    test "takes the caller's symbol in its canonical spelling" do
      row = %{
        "order_id" => "77",
        "type" => "Buy",
        "amount" => "1",
        "price" => "2",
        "timestampms" => 1_787_936_147_000
      }

      for spelling <- ["btcusd", "BTCUSD", "BTC-USD"] do
        assert {:ok, [fill]} =
                 Private.get_trade_history(@credentials,
                   symbol: spelling,
                   plug: json([row]),
                   retry_attempts: 0
                 )

        assert fill.symbol == "BTC-USD"
      end
    end
  end

  describe "a conversion between assets that are not strings" do
    test "is refused, not raised, and the fake refuses it the same way" do
      for {from, to} <- [{nil, "BTC"}, {"USD", nil}, {:usd, "BTC"}, {1, 2}] do
        opts = [credentials: @credentials]

        assert {:error, {:invalid_asset, _asset}} = real = Private.instant_pair(from, to, opts)
        assert Private.quote_conversion(from, to, Decimal.new(1), opts) == real
        assert Fake.quote_conversion(from, to, Decimal.new(1), opts) == real
        assert Fake.convert(from, to, Decimal.new(1), opts) == real
      end
    end
  end

  describe "refresh_access_token/3 refusal" do
    test "the OAuth error comes back as the map the venue sent" do
      plug = fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "invalid_grant"}))
      end

      assert {:refused, %{"error" => "invalid_grant"}} =
               Private.refresh_access_token("client-1", "expired", plug: plug, retry_attempts: 0)
    end

    test "a refusal that is not JSON keeps the venue's text" do
      plug = fn conn -> Plug.Conn.resp(conn, 401, "invalid client") end

      assert {:refused, "invalid client"} =
               Private.refresh_access_token("client-1", "expired", plug: plug, retry_attempts: 0)
    end
  end
end
