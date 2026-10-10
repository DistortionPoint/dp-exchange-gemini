defmodule DpExchange.Gemini.OrderFidelityTest do
  @moduledoc """
  An order read back says what the venue said, and no more. Found reviewing the order and
  history paths on 2026-10-10.
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

  defp read(body),
    do: Private.get_order(@credentials, "1234", plug: responding(body), retry_attempts: 0)

  test "an unfilled order has no average price, not one of zero" do
    assert {:ok, order} = read(@order)
    assert order.average_price == nil
  end

  test "an order neither live nor cancelled with part executed is not :filled" do
    body = %{
      @order
      | "is_live" => false,
        "executed_amount" => "0.4",
        "avg_execution_price" => "99"
    }

    assert {:ok, order} = read(body)
    assert order.status == :partially_filled
    assert Decimal.equal?(order.average_price, Decimal.new("99"))
  end

  test "updated_at is not the placement time repeated" do
    assert {:ok, order} = read(@order)
    assert order.created_at != nil
    assert order.updated_at == nil
  end

  test "a full history page with no :limit is refused as possibly truncated" do
    rows = for n <- 1..500, do: %{@order | "order_id" => Integer.to_string(n)}

    assert {:error, {:history_truncated, 500}} =
             Private.get_orders(@credentials,
               history: true,
               plug: responding(rows),
               retry_attempts: 0
             )
  end

  test "the fake refuses an order with no quantity or side, as the real path does" do
    request = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100.00"}

    assert {:error, {:missing_field, :quantity}} =
             Fake.place_order(@credentials, Map.delete(request, :quantity))

    assert {:error, {:missing_field, :side}} =
             Fake.place_order(@credentials, Map.delete(request, :side))
  end
end
