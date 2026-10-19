defmodule DpExchange.Gemini.TickAnTest do
  @moduledoc """
  Tick AN: dependency floors (decimal 2.0.0 and 3.x read the same numbers), HTTP response
  shapes (a JSON number where an object belongs is a refusal, never a raise in the caller),
  the once-only writes that were still answering a bare error after a send, and the fake's
  `:nonce_mode` check.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Withdrawal
  alias DpExchange.Gemini.{Auth, Fake, Private, Rest, WsDecode}

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

  @credentials %{api_key: "account-k", api_secret: "s"}
  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  # A dated JSON reply: `get_balances/2` and the staking reads need the `Date` header.
  defp json(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end
  end

  defp opts(plug, extra \\ []), do: [plug: plug, retry_attempts: 0] ++ extra

  defp exploding, do: fn _conn -> raise "must not be sent" end

  describe "decimal 2.0.0 and 3.x read the same numbers" do
    # 35 significant digits: decimal 3 refuses to parse it, decimal 2 does not.
    @thirty_five_digits "1." <> String.duplicate("0", 33) <> "1"
    # 34 significant digits: readable under both.
    @thirty_four_digits "1234567890123456789012345678.901234"

    defp trades_body(price) do
      [
        %{
          "tid" => 1,
          "timestampms" => 1_787_936_377_000,
          "price" => price,
          "amount" => "1",
          "type" => "buy"
        }
      ]
    end

    test "REST: a price of more than 34 digits is unreadable, as decimal 3 already read it" do
      assert {:error, {:invalid_decimal, :price, @thirty_five_digits}} =
               Rest.get_trades("BTC-USD", opts(json(trades_body(@thirty_five_digits))))
    end

    test "REST: a price of exactly 34 digits is still a number" do
      assert {:ok, [trade]} =
               Rest.get_trades("BTC-USD", opts(json(trades_body(@thirty_four_digits))))

      assert Decimal.to_string(trade.price, :normal) == @thirty_four_digits
    end

    test "the socket decoder refuses 35 digits too" do
      assert {:error, :unexpected_frame_shape} =
               WsDecode.to_top_of_book(
                 %{"b" => @thirty_five_digits, "a" => "2"},
                 "BTC-USD",
                 DateTime.utc_now()
               )
    end

    test "an order quantity of more than 34 digits, or of thousands, is refused before signing" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: "1",
        price: "100"
      }

      for quantity <- [
            @thirty_five_digits,
            Integer.pow(10, 40),
            Integer.pow(10, 7_000),
            Decimal.new(Integer.pow(10, 7_000))
          ] do
        assert {:error, {:invalid_quantity, ^quantity}} =
                 Private.place_order(
                   @credentials,
                   %{request | quantity: quantity},
                   opts(exploding())
                 )
      end
    end
  end

  describe "a JSON number where an object belongs is refused, not raised" do
    test "the readers answer a shape error for a fractional number in place of a row" do
      for {label, call} <- [
            {"get_balances", fn -> Private.get_balances(@credentials, opts(json([1.5]))) end},
            {"get_trade_history",
             fn -> Private.get_trade_history(@credentials, opts(json([1.5]))) end},
            {"get_staking_balances",
             fn -> Private.get_staking_balances(@credentials, opts(json([1.5]))) end},
            {"get_positions", fn -> Private.get_positions(@credentials, opts(json([1.5]))) end},
            {"list_approved_addresses",
             fn ->
               Private.list_approved_addresses(
                 @credentials,
                 opts(json([1.5]), network: "ethereum")
               )
             end},
            {"list_payment_methods",
             fn -> Private.list_payment_methods(@credentials, opts(json(1.5))) end},
            {"get_fees", fn -> Private.get_fees(@credentials, opts(json(1.5))) end},
            {"get_staking_rewards",
             fn ->
               Private.get_staking_rewards(
                 @credentials,
                 opts(json(%{"provider" => 1.5}), since: "2026-01-01T00:00:00Z")
               )
             end},
            {"get_staking_rates", fn -> Rest.get_staking_rates(opts(json(1.5))) end},
            {"get_staking_rates, a provider",
             fn -> Rest.get_staking_rates(opts(json(%{"p" => 1.5}))) end},
            {"get_staking_rates, an asset",
             fn -> Rest.get_staking_rates(opts(json(%{"p" => %{"ETH" => 1.5}}))) end}
          ] do
        assert {:error, :unexpected_response_shape} = call.(), label
      end
    end

    test "a withdrawal whose 2xx body is such a number is still the withdrawal, with its key" do
      assert {:ok, %Withdrawal{status: :pending, id: id}} =
               Private.withdraw(
                 "ETH",
                 "ethereum",
                 Decimal.new(1),
                 "0xabc",
                 @credentials,
                 opts(json(1.5))
               )

      assert is_binary(id)
    end

    test "a bulk cancel whose details are such a number is unconfirmed, not a raise" do
      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} =
               Private.cancel_all_orders(
                 @credentials,
                 opts(json(%{"details" => 1.5}), scope: :session)
               )
    end
  end

  describe "an object endpoint answers an object or a shape error" do
    test "a list, a string, null or a number is never {:ok, garbage}" do
      request = %{symbol: "BTC-USD", side: :buy, type: "limit", amount: "1", price: "100"}

      for body <- [[], "x", nil, 1.5] do
        for {label, call} <- [
              {"get_roles", fn -> Private.get_roles(@credentials, opts(json(body))) end},
              {"get_account_margin",
               fn ->
                 Private.get_account_margin(
                   @credentials,
                   opts(json(body), symbol: "BTC-GUSD-PERP")
                 )
               end},
              {"get_margin_account",
               fn ->
                 Private.get_margin_account(@credentials, opts(json(body), symbol: "BTC-USD"))
               end},
              {"preview_margin_order",
               fn -> Private.preview_margin_order(request, @credentials, opts(json(body))) end},
              {"get_clearing_order",
               fn -> Private.get_clearing_order("c-1", @credentials, opts(json(body))) end},
              {"test_connection",
               fn -> Private.test_connection(@credentials, opts(json(body))) end}
            ] do
          assert {:error, :unexpected_response_shape} = call.(), "#{label} #{inspect(body)}"
        end
      end
    end

    test "the token refresh answers an object, not whatever decoded" do
      for body <- [[], "x", nil] do
        assert {:error, :unexpected_response_shape} =
                 Private.refresh_access_token("client-1", "refresh-1", opts(json(body)))
      end
    end

    test "an object still decodes" do
      assert {:ok, %{"isAuditor" => false}} =
               Private.get_roles(@credentials, opts(json(%{"isAuditor" => false})))
    end
  end

  describe "a list of rows holds objects or is a shape error" do
    test "strings and numbers are not rows" do
      for {label, call} <- [
            {"get_transfers", fn -> Private.get_transfers(@credentials, opts(json(["x"]))) end},
            {"list_custody_fees",
             fn -> Private.list_custody_fees(@credentials, opts(json([1]))) end},
            {"get_notional_balances",
             fn -> Private.get_notional_balances(@credentials, "usd", opts(json(["x"]))) end},
            {"get_transactions",
             fn ->
               Private.get_transactions(@credentials, opts(json(%{"results" => ["x"]})))
             end},
            {"get_margin_rates",
             fn -> Private.get_margin_rates(@credentials, opts(json(["x"]))) end},
            {"list_clearing_orders",
             fn ->
               Private.list_clearing_orders(@credentials, opts(json(%{"orders" => ["x"]})))
             end},
            {"list_accounts", fn -> Private.list_accounts(@credentials, opts(json([1.5]))) end},
            {"get_trade_volume",
             fn -> Private.get_trade_volume(@credentials, opts(json([["x"]]))) end}
          ] do
        assert {:error, :unexpected_response_shape} = call.(), label
      end
    end
  end

  describe "a write sent once that may have reached the venue is unconfirmed" do
    defp timing_out(test_pid) do
      fn conn ->
        send(test_pid, {:request, conn.request_path})
        Req.Test.transport_error(conn, :timeout)
      end
    end

    defp answering_5xx(test_pid) do
      fn conn ->
        send(test_pid, {:request, conn.request_path})
        Plug.Conn.resp(conn, 503, "unavailable")
      end
    end

    # The plug runs inside the call under test, so every request there will ever be is already
    # in the mailbox when the call returns: no window to wait out.
    defp requests(acc \\ []) do
      receive do
        {:request, path} -> requests([path | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp writes(plug) do
      [
        {"/v1/account/create", fn -> Private.create_account("Bot", @credentials, opts(plug)) end},
        {"/v1/account/rename",
         fn ->
           Private.rename_account(@credentials, opts(plug, account: "old", name: "New"))
         end},
        {"/v1/deposit/ethereum/newAddress",
         fn -> Private.get_deposit_address("ETH", "ethereum", @credentials, opts(plug)) end}
      ]
    end

    test "a timeout carries no key and the request went out exactly once" do
      for {path, call} <- writes(timing_out(self())) do
        assert {:error, {:write_unconfirmed, nil, _reason}} = call.(), path
        assert [^path] = requests()
      end
    end

    test "a 5xx is unconfirmed too" do
      for {path, call} <- writes(answering_5xx(self())) do
        assert {:error, {:write_unconfirmed, nil, _reason}} = call.(), path
        assert [^path] = requests()
      end
    end

    test "a venue refusal stays a refusal, and nothing decided before the send is wrapped" do
      for {path, call} <- writes(json(%{"reason" => "InvalidApiKey"}, 400)) do
        assert {:refused, :invalid_api_key} = call.(), path
      end

      assert {:error, :name_required} =
               Private.create_account("", @credentials, opts(exploding()))
    end

    test "a 2xx that is not an object cannot show what was done, so it is unconfirmed" do
      for {path, call} <- Enum.take(writes(json(["x"])), 2) do
        assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} = call.(), path
      end
    end

    test "a readable reply is still the reply" do
      assert {:ok, %{"account" => "bot"}} =
               Private.create_account("Bot", @credentials, opts(json(%{"account" => "bot"})))
    end
  end

  describe "the fake refuses a :nonce_mode the real call refuses" do
    test "an unknown mode or a scale out of range, under an API key" do
      for mode <- [
            :incremental_ms,
            :bogus,
            {:incremental_ns, scale: 13},
            {:incremental_ns, scale: 0}
          ] do
        expected = Auth.headers(:api_key, "/v1/balances", %{}, @credentials, nonce_mode: mode)
        assert expected == {:error, {:unsupported_nonce_mode, mode}}

        assert Private.get_balances(@credentials, opts(exploding(), nonce_mode: mode)) == expected
        assert Fake.get_balances(@credentials, nonce_mode: mode) == expected
      end
    end

    test "every mode the real call accepts, and nil, is accepted" do
      for mode <- [
            nil,
            :time_based,
            :incremental,
            :incremental_us,
            :incremental_ns,
            {:incremental_ns, scale: 1},
            {:incremental_ns, scale: 12}
          ] do
        assert Auth.check_nonce_mode(mode) == :ok
        assert {:ok, _balances} = Fake.get_balances(@credentials, nonce_mode: mode)
      end
    end

    test "OAuth carries no nonce, so the mode is not judged there" do
      oauth = %{access_token: "token"}

      assert {:ok, _balances} = Fake.get_balances(oauth, nonce_mode: :bogus)
      assert {:ok, []} = Private.get_balances(oauth, opts(json([]), nonce_mode: :bogus))
    end
  end
end
