defmodule DpExchange.Gemini.DecimalBodyTest do
  @moduledoc """
  Private-endpoint bodies are decoded with `floats: :decimals`, so a money field the venue
  types as a JSON number keeps every digit; a withdrawal answered 2xx with an error is a
  refusal; and `Fake` refuses an order id exactly as `Private` does.

  The long-digit and timestamp tests send RAW BYTES through `Plug.Conn.send_resp/3` with
  `content-type: application/json`. The digit test depends on dp_exchange_core passing
  `:decode_body` through to Req: on an older Core, Req decodes the bytes to a float first and
  the assertion fails. The timestamp test passes either way.
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

  defp raw(bytes) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, bytes)
    end
  end

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  describe "a JSON number keeps every digit" do
    test "a fee estimate's number is a Decimal equal to the digits on the wire" do
      assert {:ok, %{fee: fee}} =
               Private.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("1"), @credentials,
                 address: "0xabc",
                 plug: raw(~s({"fee": 1234.567890123456789, "currency": "ETH"})),
                 retry_attempts: 0
               )

      # As a float this is 1234.567890123457: the last digits are gone.
      assert Decimal.equal?(fee, Decimal.new("1234.567890123456789"))
    end

    test "an integer number stays an integer and still reads as a fee" do
      assert {:ok, %{fee: fee}} =
               Private.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("1"), @credentials,
                 address: "0xabc",
                 plug: raw(~s({"fee": 2, "currency": "ETH"})),
                 retry_attempts: 0
               )

      assert Decimal.equal?(fee, Decimal.new("2"))
    end
  end

  describe "a fractional epoch timestamp" do
    defp history_body(date_time) do
      ~s([{"providerId": "p", "transactions": [{"transactionId": "s-1",) <>
        ~s("transactionType": "Deposit", "amountCurrency": "ETH", "amount": "1",) <>
        ~s("dateTime": #{date_time}}]}])
    end

    test "float seconds decode to the right DateTime" do
      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: raw(history_body("1667418560.153")),
                 retry_attempts: 0
               )

      assert tx.venue_time == ~U[2022-11-02 19:49:20Z]
    end

    test "float milliseconds decode to the right DateTime" do
      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: raw(history_body("1667418560153.5")),
                 retry_attempts: 0
               )

      assert tx.venue_time == ~U[2022-11-02 19:49:20.153Z]
    end
  end

  describe "a withdrawal answered 2xx" do
    defp withdraw(plug) do
      Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
        client_transfer_id: "sent-id",
        plug: plug,
        retry_attempts: 0
      )
    end

    test "with result error is a refusal, carrying the body" do
      body = %{"result" => "error", "reason" => "InsufficientFunds", "message" => "no"}
      assert {:refused, ^body} = withdraw(responding(body))
    end

    test "with result failed is a refusal" do
      body = %{"result" => "failed"}
      assert {:refused, ^body} = withdraw(responding(body))
    end

    test "with an error reason or message and no withdrawal id is a refusal" do
      for body <- [%{"reason" => "Nope"}, %{"message" => "address not approved"}] do
        assert {:refused, ^body} = withdraw(responding(body))
      end
    end

    test "with a withdrawal id is accepted even if it also carries a message" do
      assert {:ok, withdrawal} =
               withdraw(responding(%{"withdrawalId" => "w-9", "message" => "queued"}))

      assert withdrawal.id == "w-9"
    end

    test "with an empty object is accepted under the key that was sent" do
      assert {:ok, withdrawal} = withdraw(responding(%{}))
      assert withdrawal.id == "sent-id"
      assert withdrawal.status == :pending
    end

    test "with a JSON body that is not an object is accepted under the key that was sent" do
      assert {:ok, withdrawal} = withdraw(raw("[]"))
      assert withdrawal.id == "sent-id"
    end

    test "with bytes that are not JSON is an error, not a success" do
      assert {:error, {:undecodable_response, :gemini}} = withdraw(raw("<html>"))
    end
  end

  describe "Fake refuses an order id as Private does" do
    # An integer is refused too: every id this package hands out is a string.
    @bad_ids [
      "abc-123",
      "abc",
      "-1",
      "1.5",
      "",
      "   ",
      "18446744073709551616",
      nil,
      :atom,
      1.5,
      12,
      0
    ]

    test "cancel_order/3 and get_order/3 give the identical refusal" do
      for bad <- @bad_ids do
        real_cancel =
          Private.cancel_order(@credentials, bad, plug: exploding(), retry_attempts: 0)

        real_get = Private.get_order(@credentials, bad, plug: exploding(), retry_attempts: 0)

        assert real_cancel == {:error, {:invalid_order_id, bad}}
        assert Fake.cancel_order(@credentials, bad, []) == real_cancel
        assert Fake.get_order(@credentials, bad, []) == real_get
      end
    end

    test "the id is checked before the credential, in both" do
      assert Fake.cancel_order(%{}, "abc", []) == {:error, {:invalid_order_id, "abc"}}
      assert Fake.get_order(%{}, "abc", []) == {:error, {:invalid_order_id, "abc"}}
    end

    test "a numeric id the fake issued is accepted, one it did not is not found" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "1",
        price: "100",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, placed} = Fake.place_order(@credentials, request, [])
      assert {:ok, order} = Fake.get_order(@credentials, placed.id, [])
      assert order.id == placed.id
      assert Fake.get_order(@credentials, "106817811", []) == {:refused, :not_found}
    end
  end
end
