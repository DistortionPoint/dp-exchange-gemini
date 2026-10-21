defmodule DpExchange.Gemini.TickArStatusTest do
  @moduledoc """
  Tick AR, lens X: every combination of `is_live`, `is_cancelled`, `executed_amount`,
  `original_amount` and `remaining_amount` maps to the one status the venue's own definitions
  allow, or to `nil` when they contradict each other. Never to a nearby status.
  """
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
  alias DpExchange.Gemini.{Fake, Private}

  @moduletag :capture_log
  @working_or_filled [:pending, :open, :partially_filled, :filled]

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

  @base %{
    "order_id" => "4321",
    "symbol" => "btcusd",
    "side" => "buy",
    "type" => "exchange limit",
    "price" => "100.00",
    "original_amount" => "5",
    "executed_amount" => "0",
    "remaining_amount" => "5",
    "avg_execution_price" => "0.00",
    "is_live" => false,
    "is_cancelled" => false,
    "timestampms" => 1_787_936_147_000
  }

  defp order_from(overrides) do
    body = Map.merge(@base, overrides)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end

    Private.get_order(@credentials, "4321", plug: plug, retry_attempts: 0)
  end

  defp placed_from(overrides) do
    body = Map.merge(@base, overrides)

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end

    request = %{
      symbol: "BTC-USD",
      side: :buy,
      quantity: "5",
      price: "100.00",
      order_type: :limit,
      time_in_force: :gtc
    }

    Private.place_order(@credentials, request, plug: plug, retry_attempts: 0)
  end

  describe "status from the venue's flags and amounts" do
    test "cancelled after a partial fill is :cancelled and keeps the fill" do
      assert {:ok, %Order{} = order} =
               order_from(%{
                 "is_cancelled" => true,
                 "executed_amount" => "3.7610296649",
                 "remaining_amount" => "1.2389703351",
                 "avg_execution_price" => "100.50"
               })

      assert order.status == :cancelled
      assert Decimal.equal?(order.filled_quantity, Decimal.new("3.7610296649"))
      assert Decimal.equal?(order.average_price, Decimal.new("100.50"))
    end

    test "cancelled with nothing executed is :cancelled with no average price" do
      assert {:ok, %Order{status: :cancelled, average_price: nil} = order} =
               order_from(%{"is_cancelled" => true})

      assert Decimal.equal?(order.filled_quantity, 0)
    end

    test "live with nothing executed is :open, live with a fill is :partially_filled" do
      assert {:ok, %Order{status: :open}} = order_from(%{"is_live" => true})

      assert {:ok, %Order{status: :partially_filled}} =
               order_from(%{
                 "is_live" => true,
                 "executed_amount" => "2",
                 "remaining_amount" => "3",
                 "avg_execution_price" => "100"
               })
    end

    test "neither live nor cancelled and fully executed is :filled" do
      assert {:ok, %Order{status: :filled}} =
               order_from(%{
                 "executed_amount" => "5",
                 "remaining_amount" => "0",
                 "avg_execution_price" => "100"
               })
    end

    test "neither live nor cancelled with an unfilled remainder is never :filled" do
      assert {:ok, %Order{status: :pending}} = order_from(%{})

      # A partial fill that is neither working nor cancelled is a state the venue never defines.
      assert {:ok, %Order{status: nil}} =
               order_from(%{
                 "executed_amount" => "2",
                 "remaining_amount" => "3",
                 "avg_execution_price" => "100"
               })
    end

    test "contradictory flags or amounts state no status instead of a guess" do
      all_executed = %{"executed_amount" => "5", "avg_execution_price" => "100"}

      contradictions = [
        %{"is_live" => true, "is_cancelled" => true},
        Map.merge(all_executed, %{"is_live" => true, "remaining_amount" => "0"}),
        Map.merge(all_executed, %{"remaining_amount" => "2"})
      ]

      for overrides <- contradictions do
        assert {:ok, %Order{status: nil}} = order_from(overrides),
               "expected no status for #{inspect(overrides)}"
      end
    end

    test "a placement reply goes through the same mapping" do
      assert {:ok, %Order{status: :cancelled}} = placed_from(%{"is_cancelled" => true})

      assert {:ok, %Order{status: nil}} =
               placed_from(%{"is_live" => true, "is_cancelled" => true})
    end
  end

  describe "amounts that no status can sit beside (Core Order.new refuses them)" do
    test "an executed amount above the original states no status" do
      for flags <- [%{"is_live" => true}, %{"is_cancelled" => true}, %{}] do
        overrides = Map.merge(flags, %{"executed_amount" => "6", "remaining_amount" => "0"})

        assert {:ok, %Order{status: nil}} = order_from(overrides),
               "expected no status for #{inspect(overrides)}"
      end
    end

    test "an original amount of zero states no status, and never :filled" do
      assert {:ok, %Order{status: nil}} =
               order_from(%{"original_amount" => "0", "executed_amount" => "0"})
    end

    test "a negative amount refuses the read, and is nil on a placement reply" do
      for overrides <- [%{"executed_amount" => "-1"}, %{"original_amount" => "-5"}] do
        assert {:error, :unexpected_response_shape} = order_from(overrides)

        assert {:ok, %Order{status: nil} = placed} = placed_from(overrides)
        refute negative?(placed.filled_quantity)
        refute negative?(placed.quantity)
      end
    end

    test "every status this decoder gives an order agrees with its fill" do
      all_executed = %{"executed_amount" => "5", "avg_execution_price" => "100"}

      bodies = [
        %{"is_live" => true},
        %{"is_live" => true, "executed_amount" => "2", "avg_execution_price" => "100"},
        %{"is_cancelled" => true},
        Map.merge(all_executed, %{"is_cancelled" => true}),
        Map.merge(all_executed, %{"remaining_amount" => "0"}),
        %{}
      ]

      for overrides <- bodies do
        assert {:ok, %Order{} = order} = order_from(overrides)
        assert consistent?(order), "contradictory order for #{inspect(overrides)}"
      end
    end
  end

  describe "the Fake's orders agree with their fill" do
    test "a placed, a cancelled and a history order are self-consistent" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "2",
        price: "100",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, %Order{} = placed} = Fake.place_order(@credentials, request)
      assert consistent?(placed)

      assert {:ok, %Order{} = cancelled} = Fake.cancel_order(@credentials, placed.id)
      assert consistent?(cancelled)

      assert {:ok, [_one | _rest] = history} = Fake.get_orders(@credentials, history: true)
      assert Enum.all?(history, &consistent?/1)
    end
  end

  defp negative?(nil), do: false
  defp negative?(%Decimal{} = amount), do: Decimal.negative?(amount)

  # Core `Order.new`'s rules, stated here so the check does not depend on the Core version.
  defp consistent?(%Order{status: nil}), do: true

  defp consistent?(%Order{status: status}) when status in [:cancelled, :rejected, :expired],
    do: true

  defp consistent?(%Order{quantity: nil, status: status}), do: status in @working_or_filled
  defp consistent?(%Order{filled_quantity: nil, status: status}), do: status in @working_or_filled

  defp consistent?(%Order{status: status, quantity: quantity, filled_quantity: filled}) do
    whole = Decimal.equal?(quantity, filled)
    zero = Decimal.equal?(filled, 0)

    case status do
      :filled -> whole and not zero
      :partially_filled -> not whole and not zero
      working when working in [:pending, :open] -> not whole
    end
  end
end
