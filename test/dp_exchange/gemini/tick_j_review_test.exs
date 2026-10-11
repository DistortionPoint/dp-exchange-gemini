defmodule DpExchange.Gemini.TickJReviewTest do
  @moduledoc """
  Defects found reading `Private`, `Fake` and the facade in Tick J: an order or quote id
  `Integer.parse/1` let through with a sign, an order built from a symbol or client order id
  that raised or wrote nothing, a network lookup built from a blank asset or network, a token
  refresh sent with a blank credential, and a feed addressed by a name that is not an atom.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini
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
  @request %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100.00"}
  @order %{
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

  defp exploding(message) do
    fn _conn -> raise message end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      payload =
        conn
        |> Plug.Conn.get_req_header("x-gemini-payload")
        |> hd()
        |> Base.decode64!()
        |> Jason.decode!()

      send(test_pid, {:payload, payload})

      conn
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> Req.Test.json(body)
    end
  end

  describe "an order id is digits and nothing else" do
    test "a signed or padded id is refused, by the real call and the fake alike" do
      for id <- ["+5", "-0", "-5", "5 ", " 5", "", "0x10", "1_000", "5.0"] do
        expected = {:error, {:invalid_order_id, id}}

        assert Private.order_id_param(id) == expected

        assert Private.cancel_order(@credentials, id,
                 plug: exploding("an unsigned id must not be sent"),
                 retry_attempts: 0
               ) == expected

        assert Private.get_order(@credentials, id,
                 plug: exploding("an unsigned id must not be sent"),
                 retry_attempts: 0
               ) == expected

        assert Fake.cancel_order(@credentials, id) == expected
      end
    end

    test "plain digits still parse, up to the unsigned 64-bit maximum" do
      assert Private.order_id_param("12") == {:ok, 12}
      assert Private.order_id_param("18446744073709551615") == {:ok, 18_446_744_073_709_551_615}

      assert Private.order_id_param("18446744073709551616") ==
               {:error, {:invalid_order_id, "18446744073709551616"}}
    end

    test "a quote id with a sign is refused before anything is sent" do
      terms = [
        symbol: "BTC-USD",
        side: :buy,
        amount: Decimal.new("0.015"),
        price: Decimal.new("6445.07"),
        fee: Decimal.new("2.99"),
        plug: exploding("a signed quote id must not be sent"),
        retry_attempts: 0
      ]

      for id <- ["-5", "+5", "5 "] do
        assert {:error, {:invalid_quote_id, ^id}} = Private.commit_conversion(id, terms)
      end

      assert {:error, {:invalid_quote_id, -5}} = Private.commit_conversion(-5, terms)
    end
  end

  describe "place_order/3 refuses a symbol or client order id it cannot send" do
    test "a symbol that is not a non-blank string is an error, not a raise" do
      for symbol <- [:btcusd, 42, "", "   "] do
        request = %{@request | symbol: symbol}
        expected = {:error, {:invalid_symbol, symbol}}

        assert Private.place_order(@credentials, request,
                 plug: exploding("an order with no usable symbol must not be sent"),
                 retry_attempts: 0
               ) == expected

        assert Private.validate_order(request) == expected
        assert Fake.place_order(@credentials, request) == expected
      end
    end

    test "a client order id that is not a non-blank string or an integer is refused" do
      for id <- [%{}, [1], {:a}, :atom, "", "  "] do
        request = Map.put(@request, :client_order_id, id)
        expected = {:error, {:invalid_client_order_id, id}}

        assert Private.place_order(@credentials, request,
                 plug: exploding("a client order id the venue cannot read must not be sent"),
                 retry_attempts: 0
               ) == expected

        assert Fake.place_order(@credentials, request) == expected
      end
    end

    test "an integer client order id is sent as its digits" do
      request = Map.put(@request, :client_order_id, 470_135)

      assert {:ok, _order} =
               Private.place_order(@credentials, request,
                 plug: capturing(@order, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["client_order_id"] == "470135"
    end

    test "no client order id sends no field" do
      assert {:ok, _order} =
               Private.place_order(@credentials, @request,
                 plug: capturing(@order, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      refute Map.has_key?(payload, "client_order_id")
    end
  end

  describe "list_networks/2 refuses a blank or non-string lookup before signing" do
    test "the path is built from the asset, keeping its case, or from the network" do
      assert Private.network_lookup_path("USDC", nil) == {:ok, "/v2/network/USDC"}

      assert Private.network_lookup_path(nil, "ethereum") ==
               {:ok, "/v2/networks/ethereum/assets"}

      assert Private.network_lookup_path(nil, "a/b") == {:ok, "/v2/networks/a%2Fb/assets"}
      assert Private.network_lookup_path(nil, nil) == {:error, :asset_or_network_required}
    end

    test "a blank or non-string asset or network is named, by the real call and the fake" do
      cases = [
        {"", [], {:invalid_asset, ""}},
        {"  ", [], {:invalid_asset, "  "}},
        {:usdc, [], {:invalid_asset, :usdc}},
        {42, [], {:invalid_asset, 42}},
        {nil, [network: ""], {:invalid_network, ""}},
        {nil, [network: :eth], {:invalid_network, :eth}}
      ]

      for {asset, extra, reason} <- cases do
        opts =
          [
            credentials: @credentials,
            plug: exploding("a lookup for a blank resource must not be sent"),
            retry_attempts: 0
          ] ++ extra

        assert Private.list_networks(asset, opts) == {:error, reason}
        assert Fake.list_networks(asset, [credentials: @credentials] ++ extra) == {:error, reason}
      end
    end
  end

  describe "refresh_access_token/3 refuses a blank credential before sending it" do
    test "a blank client id or refresh token is named" do
      opts = [plug: exploding("a blank refresh must not be sent"), retry_attempts: 0]

      for client_id <- ["", "  "] do
        assert Private.refresh_access_token(client_id, "refresh-1", opts) ==
                 {:error, :client_id_required}
      end

      assert Private.refresh_access_token("client-1", "", opts) ==
               {:error, :refresh_token_required}

      assert Gemini.refresh_access_token("client-1", " ", opts) ==
               {:error, :refresh_token_required}
    end
  end

  describe "the facade's reads of a feed addressed by something other than an atom" do
    test "coverage answers empty, not a FunctionClauseError, for a {:global, name} feed" do
      feed = {:global, {:gemini_tick_j_missing_feed, make_ref()}}

      assert Gemini.coverage(feed: feed) == %{}
      assert Gemini.coverage_by_kind(feed: feed) == %{}
    end
  end
end
