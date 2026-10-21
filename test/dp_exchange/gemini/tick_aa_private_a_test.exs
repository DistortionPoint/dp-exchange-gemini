defmodule DpExchange.Gemini.TickAAPrivateATest do
  @moduledoc """
  Tick AA: branches of `DpExchange.Gemini.Private` the full suite never ran (first half of
  the module).

  Each test reaches one branch through the public surface and asserts what the code's own
  comments say it must do: an integer order id is an id, our own limiter refusing before a
  send stays plain while an oversized reply after a send is unconfirmed, an unreadable side
  or amount is never guessed, and a reply without a `Date` header has no expiry rather than
  one measured from the local clock.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Conversion, Order}
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

  defmodule DenyingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 7_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # A limiter whose backing store does not answer: Core reports "Rate limiter unavailable".
  defmodule UnavailableLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :store_down}
    @impl true
    def check(_provider, _weight, _opts), do: {:error, :store_down}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # Lets the first request through and refuses every later one. The count lives in the
  # calling process, where `Core.HttpClient` runs.
  defmodule FirstThenDenyLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts) do
      seen = Process.get({__MODULE__, :seen}, 0)
      Process.put({__MODULE__, :seen}, seen + 1)
      if seen == 0, do: :ok, else: {:error, :rate_limit_timeout}
    end

    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 7_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  @request %{
    symbol: "BTC-USD",
    side: :buy,
    order_type: :limit,
    time_in_force: :gtc,
    quantity: "1",
    price: "100.00"
  }

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

  @quote_body %{
    "quoteId" => 20_930,
    "maxAgeMs" => 60_000,
    "pair" => "BTCUSD",
    "price" => "6445.07",
    "priceCurrency" => "USD",
    "side" => "buy",
    "quantity" => "0.01505181",
    "quantityCurrency" => "BTC",
    "fee" => "2.9900309233",
    "feeCurrency" => "USD",
    "totalSpend" => "100",
    "totalSpendCurrency" => "USD"
  }

  @fill_row %{
    "order_id" => "1",
    "tid" => 2,
    "symbol" => "btcusd",
    "price" => "100",
    "amount" => "0.5",
    "type" => "Buy",
    "timestampms" => 1_787_936_147_000
  }

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp place(request, plug, extra \\ []) do
    Private.place_order(@credentials, request, [plug: plug, retry_attempts: 0] ++ extra)
  end

  defp withdraw(extra) do
    Private.withdraw(
      "ETH",
      "ethereum",
      Decimal.new("1"),
      "0xabc",
      @credentials,
      [retry_attempts: 3, retry_delay: 1] ++ extra
    )
  end

  defp approved(body) do
    Private.list_approved_addresses(@credentials,
      network: "ethereum",
      plug: responding(body),
      retry_attempts: 0
    )
  end

  describe "a placement's answer" do
    test "an integer order_id is an id, returned as its digits" do
      body = Map.put(@order_body, "order_id", 1234)

      assert {:ok, %Order{id: "1234"}} = place(@request, responding(body))
    end

    test "a blocking limiter that times out before the send is a plain error, not unconfirmed" do
      Config.put_override(:rate_limit_module, DenyingLimiter)
      request = Map.put(@request, :client_order_id, "c-blk")

      assert {:error, {:exchange_error, :gemini, :rate_limit_timeout}} =
               place(request, exploding(), rate_limit_blocking: true)
    end

    test "a reply too large to read, after the send, is unconfirmed with the id sent" do
      oversized = fn conn -> Plug.Conn.resp(conn, 200, String.duplicate("x", 16_777_217)) end

      assert {:error, {:order_unconfirmed, "c-big", reason}} =
               place(Map.put(@request, :client_order_id, "c-big"), oversized)

      assert is_binary(reason)
      assert reason =~ "response_too_large"
    end

    test "an unreadable executed amount on a live order is no fill, not a guessed one" do
      body = Map.put(@order_body, "executed_amount", "not-a-number")

      assert {:ok, %Order{status: :open, filled_quantity: nil, average_price: nil}} =
               place(@request, responding(body))
    end

    test "an unreadable original amount is never vouched for as a full fill" do
      body =
        @order_body
        |> Map.put("original_amount", "not-a-number")
        |> Map.put("executed_amount", "1")
        |> Map.put("is_live", false)

      # Not live and not provably complete: no status is stated (tick AR), never :filled.
      assert {:ok, %Order{status: nil, quantity: nil} = order} =
               place(@request, responding(body))

      assert Decimal.equal?(order.filled_quantity, Decimal.new("1"))
    end

    test "order_wire/2 names a missing order type" do
      assert Private.order_wire(nil, :gtc) == {:error, {:missing_field, :order_type}}
    end
  end

  describe "cancel_all_orders/2" do
    test "a reply naming no cancelRejects is none rejected" do
      body = %{"result" => "ok", "details" => %{"cancelledOrders" => [1, 2]}}

      assert {:ok, %{cancelled: ["1", "2"], rejected: []}} =
               Private.cancel_all_orders(@credentials,
                 scope: :session,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  describe "an authenticated call needs a URL it can check" do
    test "a base_url that is not a string is refused before anything is signed" do
      for base_url <- [nil, 123, ~c"https://api.gemini.com"] do
        assert {:error, {:insecure_url, :gemini}} =
                 Private.get_balances(@credentials,
                   base_url: base_url,
                   plug: exploding(),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "the token refresh" do
    test "a status that is not a refusal is an error quoting the venue's body" do
      plug = fn conn -> Plug.Conn.resp(conn, 422, "unprocessable") end
      opts = [plug: plug, retry_attempts: 0]

      assert Private.refresh_access_token("client-1", "old-refresh", opts) ==
               {:error, {:exchange_error, :gemini, ~s(HTTP 422: "unprocessable")}}
    end
  end

  describe "a fill row that cannot be read refuses the page" do
    test "a row with no symbol, on a read that named none, is a missing symbol" do
      opts = [plug: responding([Map.delete(@fill_row, "symbol")]), retry_attempts: 0]

      assert {:error, {:missing_required_field, :symbol}} =
               Private.get_trade_history(@credentials, opts)
    end

    test "a type that is neither buy nor sell is an unknown side" do
      opts = [plug: responding([Map.put(@fill_row, "type", "Hold")]), retry_attempts: 0]

      assert {:error, {:unknown_side, "Hold"}} = Private.get_trade_history(@credentials, opts)
    end
  end

  describe "quote_conversion/4" do
    defp quote_with(plug) do
      Private.quote_conversion("USD", "BTC", Decimal.new("100"),
        symbol: "BTC-USD",
        side: :buy,
        credentials: @credentials,
        plug: plug,
        retry_attempts: 0
      )
    end

    test "a reply that is not an object is unreadable" do
      assert {:error, :unexpected_response_shape} = quote_with(responding([@quote_body]))
    end

    test "with no Date header the quote has no expiry and no venue time" do
      # `maxAgeMs` is measured from the venue's own clock. Without it the window is unknown,
      # which `Conversion.expired?/2` reports as unknown rather than as still valid.
      plug = fn conn -> Req.Test.json(conn, @quote_body) end

      assert {:ok, %Conversion{} = conversion} = quote_with(plug)
      assert conversion.id == "20930"
      assert conversion.expires_at == nil
      assert conversion.venue_time == nil
    end
  end

  describe "get_fx_rate/3" do
    test "an instant that is not a DateTime is refused before anything is sent" do
      at = ~N[2026-01-01 00:00:00]

      assert Private.get_fx_rate("EUR-USD", at, plug: exploding(), retry_attempts: 0) ==
               {:error, {:invalid_fx_instant, at}}
    end
  end

  describe "get_deposit_address/4" do
    test "a reply naming its network as something other than a string is a mismatch" do
      assert {:error, {:network_mismatch, "ethereum", 123}} =
               Private.get_deposit_address("ETH", "ethereum", @credentials,
                 plug: responding(%{"address" => "0xabc", "network" => 123}),
                 retry_attempts: 0
               )
    end
  end

  describe "list_approved_addresses/2" do
    test "an explicit null list is none, and a bare list is read as the list" do
      assert {:ok, []} = approved(%{"approvedAddresses" => nil})

      rows = [%{"address" => "0x1", "status" => "active"}]
      assert {:ok, [%{address: "0x1", status: :active}]} = approved(rows)
    end

    test "a rejected address is rejected" do
      body = %{"approvedAddresses" => [%{"address" => "0x1", "status" => "rejected"}]}

      assert {:ok, [%{status: :rejected}]} = approved(body)
    end

    test "a createdAt that is not a positive, in-range epoch refuses, not 1970 and not nil" do
      for created_at <- ["not-an-epoch", 100_000_000_000_000_000_000, 0, -5, %{"ms" => 1}] do
        body = %{"approvedAddresses" => [%{"address" => "0x1", "createdAt" => created_at}]}

        assert {:error, :unexpected_response_shape} = approved(body),
               "createdAt #{inspect(created_at)} must refuse"
      end

      absent = %{"approvedAddresses" => [%{"address" => "0x1", "createdAt" => nil}]}
      assert {:ok, [%{requested_at: nil}]} = approved(absent)
    end
  end

  describe "withdraw/6 — a fee in the 2xx reply" do
    test "present but unreadable is write_unconfirmed with the key sent; absent or null is nil" do
      for bad <- ["abc", "NaN", true, %{}] do
        body = %{"withdrawalId" => "w-1", "fee" => bad}

        assert {:error, {:write_unconfirmed, "k-fee", :unexpected_response_shape}} =
                 withdraw(client_transfer_id: "k-fee", plug: responding(body))
      end

      for body <- [%{"withdrawalId" => "w-1"}, %{"withdrawalId" => "w-1", "fee" => nil}] do
        assert {:ok, withdrawal} = withdraw(client_transfer_id: "k-fee", plug: responding(body))
        assert withdrawal.fee == nil
      end

      readable = %{"withdrawalId" => "w-1", "fee" => "0.0005"}
      assert {:ok, withdrawal} = withdraw(client_transfer_id: "k-fee", plug: responding(readable))
      assert Decimal.equal?(withdrawal.fee, Decimal.new("0.0005"))
    end
  end

  describe "withdraw/6 and our own limiter" do
    test "a blocking limiter that times out before anything was sent stays plain" do
      Config.put_override(:rate_limit_module, DenyingLimiter)

      assert {:error, {:exchange_error, :gemini, :rate_limit_timeout}} =
               withdraw(client_transfer_id: "k-b", rate_limit_blocking: true, plug: exploding())
    end

    test "an unavailable limiter before anything was sent stays plain" do
      Config.put_override(:rate_limit_module, UnavailableLimiter)

      assert {:error, {:exchange_error, :gemini, "Rate limiter unavailable"}} =
               withdraw(client_transfer_id: "k-down", plug: exploding())
    end

    test "a blocking limiter refusing the retry after a send is unconfirmed" do
      Config.put_override(:rate_limit_module, FirstThenDenyLimiter)
      me = self()

      plug = fn conn ->
        send(me, :attempt)
        Req.Test.transport_error(conn, :timeout)
      end

      assert {:error, {:write_unconfirmed, "k-retry", reason}} =
               withdraw(client_transfer_id: "k-retry", rate_limit_blocking: true, plug: plug)

      assert reason =~ "rate_limit_timeout"
      assert_receive :attempt, 5_000
      # The plug runs inside the call above, so every attempt there will ever be is already
      # in the mailbox: no window decides this.
      refute_received :attempt
    end
  end
end
