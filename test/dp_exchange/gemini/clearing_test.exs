defmodule DpExchange.Gemini.ClearingTest do
  @moduledoc """
  Bilateral and broker clearing.

  **A clearing order is not an order on the book.** It is one half of a trade agreed with a
  named counterparty and it does nothing until that counterparty confirms; a caller reading a
  successful response as a fill holds a position it does not have. Every assertion here is
  about that gap, or about the terms that describe which trade is being agreed.

  The sharpest one is `confirm_clearing_order/4`: the venue re-asks for the symbol, amount,
  price and side, and this package fills **none** of them in from the order being confirmed.
  Reading them back from the venue would confirm whatever the venue had, which is the one
  thing re-stating them exists to prevent.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.Private

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
        |> Base.decode64!()
        |> Jason.decode!()

      send(test_pid, {:payload, payload, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  @terms %{
    symbol: "BTC-USD",
    amount: Decimal.new("0.5"),
    price: Decimal.new("60000"),
    side: :buy
  }

  describe "creating a clearing order" do
    test "the four terms reach the venue in its own vocabulary" do
      me = self()

      assert {:ok, _order} =
               Private.create_clearing_order(@terms, @credentials,
                 counterparty_id: "cp-1",
                 expires_in_hrs: 24,
                 plug: capturing(%{"clearing_id" => "c-1", "is_confirmed" => false}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/new"}
      assert payload["symbol"] == "btcusd"
      assert payload["amount"] == "0.5"
      assert payload["price"] == "60000"
      assert payload["side"] == "buy"
      assert payload["counterparty_id"] == "cp-1"
      assert payload["expires_in_hrs"] == 24
    end

    test "an order missing any term is refused before a request is made" do
      assert {:error, :missing_clearing_terms} =
               Private.create_clearing_order(%{symbol: "BTC-USD", side: :buy}, @credentials, [])
    end

    test "a created order is not confirmed, and that is what the caller must read" do
      assert {:ok, order} =
               Private.create_clearing_order(@terms, @credentials,
                 plug: responding(%{"clearing_id" => "c-1", "is_confirmed" => false}),
                 retry_attempts: 0
               )

      assert order["is_confirmed"] == false
    end

    test "a small amount is sent in full notation, not scientific" do
      me = self()

      assert {:ok, _order} =
               Private.create_clearing_order(
                 %{@terms | amount: Decimal.new("0.00000001")},
                 @credentials,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["amount"] == "0.00000001"
    end
  end

  describe "the broker form names both sides" do
    test "source and target both reach the venue, and side belongs to the source" do
      me = self()

      assert {:ok, _order} =
               Private.create_broker_clearing_order(@terms, @credentials,
                 source_counterparty_id: "src",
                 target_counterparty_id: "tgt",
                 expires_in_hrs: 12,
                 plug: capturing(%{"result" => "AwaitSourceTargetConfirm"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/broker/new"}
      assert payload["source_counterparty_id"] == "src"
      assert payload["target_counterparty_id"] == "tgt"
      assert payload["side"] == "buy"
      assert payload["expires_in_hrs"] == 12
    end

    test "each required counterparty is refused by name when missing" do
      # Passing the two the wrong way round produces a valid order in which each side trades
      # the direction the other meant; a missing one is caught here instead.
      assert {:error, {:missing_option, :source_counterparty_id}} =
               Private.create_broker_clearing_order(@terms, @credentials,
                 target_counterparty_id: "tgt",
                 expires_in_hrs: 12
               )

      assert {:error, {:missing_option, :target_counterparty_id}} =
               Private.create_broker_clearing_order(@terms, @credentials,
                 source_counterparty_id: "src",
                 expires_in_hrs: 12
               )
    end

    test "the expiry is required on the broker form, unlike the bilateral one" do
      assert {:error, {:missing_option, :expires_in_hrs}} =
               Private.create_broker_clearing_order(@terms, @credentials,
                 source_counterparty_id: "src",
                 target_counterparty_id: "tgt"
               )
    end
  end

  describe "reading, cancelling and confirming" do
    test "status takes only the clearing id" do
      me = self()

      assert {:ok, _order} =
               Private.get_clearing_order("c-1", @credentials,
                 plug: capturing(%{"clearing_id" => "c-1", "is_confirmed" => true}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/status"}
      assert payload["clearing_id"] == "c-1"
    end

    test "cancel carries the venue's details, which is where it says why one did not take" do
      assert {:ok, result} =
               Private.cancel_clearing_order("c-1", @credentials,
                 plug: responding(%{"result" => "ok", "details" => "cancelled"}),
                 retry_attempts: 0
               )

      assert result["details"] == "cancelled"
    end

    test "confirm re-states every term and invents none of them" do
      # Reading them back from the venue would confirm whatever the venue had.
      me = self()

      assert {:ok, _result} =
               Private.confirm_clearing_order("c-1", %{@terms | side: :sell}, @credentials,
                 plug: capturing(%{"result" => "confirmed"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/confirm"}
      assert payload["clearing_id"] == "c-1"
      assert payload["symbol"] == "btcusd"
      assert payload["amount"] == "0.5"
      assert payload["price"] == "60000"
      # The confirming party's own side — the opposite of the creator's.
      assert payload["side"] == "sell"
    end

    test "a confirm missing a term is refused rather than filled in" do
      assert {:error, :missing_clearing_terms} =
               Private.confirm_clearing_order("c-1", %{symbol: "BTC-USD"}, @credentials, [])
    end
  end

  describe "the three listings" do
    test "every filter is optional and none is sent unasked" do
      me = self()

      assert {:ok, []} =
               Private.list_clearing_orders(@credentials,
                 plug: capturing(%{"result" => "ok", "orders" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/list"}
      assert Map.keys(payload) |> Enum.sort() == ["nonce", "request"]
    end

    test "expiration and submission windows are different parameters" do
      # An order submitted last week can expire tomorrow; filtering on the wrong one returns
      # a real list that is not the one asked for.
      me = self()

      assert {:ok, []} =
               Private.list_clearing_orders(@credentials,
                 symbol: "BTC-USD",
                 counterparty: "cp-1",
                 side: :buy,
                 expiration_start: ~U[2026-08-28 17:00:01Z],
                 submission_start: ~U[2026-08-01 00:00:00Z],
                 plug: capturing(%{"orders" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["symbol"] == "btcusd"
      assert payload["counterparty"] == "cp-1"
      assert payload["side"] == "buy"
      assert payload["expiration_start"] == 1_787_936_401_000
      assert payload["submission_start"] == 1_785_542_400_000
    end

    test "the broker listing has its own path and its own row shape" do
      body = %{
        "result" => "ok",
        "orders" => [
          %{
            "clearing_id" => "c-1",
            "source_counterparty_id" => "src",
            "target_counterparty_id" => "tgt",
            "source_side" => "buy"
          }
        ]
      }

      assert {:ok, [order]} =
               Private.list_clearing_brokers(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # A broker row has a source side, not a side. Merging the two listings would leave a
      # caller reading `side` on a row that has none.
      assert order["source_side"] == "buy"
      refute Map.has_key?(order, "side")
    end

    test "trades come back under `results`, not `orders`" do
      body = %{
        "results" => [
          %{"clearingId" => "c-1", "sourceSide" => "buy", "pair" => "BTCUSD", "price" => "60000"}
        ]
      }

      assert {:ok, [trade]} =
               Private.list_clearing_trades(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # camelCase here and snake_case on the order listings. The venue's own keys are kept
      # either way rather than normalised into a shape that matches neither.
      assert trade["clearingId"] == "c-1"
    end

    test "the trade filters use the venue's own names, nanoseconds included" do
      me = self()

      assert {:ok, []} =
               Private.list_clearing_trades(@credentials,
                 symbol: "BTC-USD",
                 since_nanos: 1_787_936_401_000_000_000,
                 limit: 300,
                 plug: capturing(%{"results" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/trades"}
      assert payload["timestamp_nanos"] == 1_787_936_401_000_000_000
      assert payload["limit_per_account"] == 300
      assert payload["symbol"] == "btcusd"
    end

    test "a body without the expected key is an empty list, not a crash" do
      assert {:ok, []} =
               Private.list_clearing_orders(@credentials,
                 plug: responding(%{"result" => "ok"}),
                 retry_attempts: 0
               )
    end
  end

  describe "the facade reaches all eight" do
    test "each clearing function delegates" do
      creds = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, _order} =
               DpExchange.Gemini.create_clearing_order(
                 @terms,
                 creds ++ [plug: responding(%{"clearing_id" => "c-1"})]
               )

      assert {:ok, _order} =
               DpExchange.Gemini.create_broker_clearing_order(
                 @terms,
                 creds ++
                   [
                     source_counterparty_id: "src",
                     target_counterparty_id: "tgt",
                     expires_in_hrs: 12,
                     plug: responding(%{"clearing_id" => "c-1"})
                   ]
               )

      assert {:ok, _order} =
               DpExchange.Gemini.get_clearing_order("c-1", creds ++ [plug: responding(%{})])

      assert {:ok, _result} =
               DpExchange.Gemini.cancel_clearing_order("c-1", creds ++ [plug: responding(%{})])

      assert {:ok, _result} =
               DpExchange.Gemini.confirm_clearing_order(
                 "c-1",
                 @terms,
                 creds ++ [plug: responding(%{})]
               )

      assert {:ok, []} =
               DpExchange.Gemini.list_clearing_orders(creds ++ [plug: responding(%{})])

      assert {:ok, []} =
               DpExchange.Gemini.list_clearing_brokers(creds ++ [plug: responding(%{})])

      assert {:ok, []} =
               DpExchange.Gemini.list_clearing_trades(creds ++ [plug: responding(%{})])
    end

    test "the short arities refuse without credentials, reaching no network" do
      assert {:error, {:unsupported_auth_scheme, nil}} = DpExchange.Gemini.get_clearing_order("c")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               DpExchange.Gemini.cancel_clearing_order("c")

      assert {:error, {:unsupported_auth_scheme, nil}} = DpExchange.Gemini.list_clearing_orders()
      assert {:error, {:unsupported_auth_scheme, nil}} = DpExchange.Gemini.list_clearing_brokers()
      assert {:error, {:unsupported_auth_scheme, nil}} = DpExchange.Gemini.list_clearing_trades()

      assert {:error, :missing_clearing_terms} = DpExchange.Gemini.create_clearing_order(%{})

      assert {:error, :missing_clearing_terms} =
               DpExchange.Gemini.create_broker_clearing_order(%{})

      assert {:error, :missing_clearing_terms} =
               DpExchange.Gemini.confirm_clearing_order("c", %{})
    end
  end
end
