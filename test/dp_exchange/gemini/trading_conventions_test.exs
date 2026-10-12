defmodule DpExchange.Gemini.TradingConventionsTest do
  @moduledoc """
  The family's trading conventions (tick P), applied to Gemini: an order says what it is and
  nothing is defaulted (T3, T4, T5, T7), a placement that may have reached the venue is never a
  bare error (T1), order ids and not-found answers are one shape (T8, T9), cancel is sent once
  (T10), the facade takes `opts` everywhere (T13), and the fake answers what the real path
  answers (T14).
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}

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

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  defp answering(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end
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
      Req.Test.json(conn, body)
    end
  end

  describe "the request is checked in the family's order, and never raises" do
    test "a request that is not a plain map is an invalid_order_request" do
      for bad <- [nil, [], "BTC-USD", 5, [symbol: "BTC-USD"], ~D[2026-01-01]] do
        expected = {:error, {:invalid_order_request, bad}}

        assert Private.place_order(@credentials, bad, opts(exploding())) == expected
        assert Private.validate_order(bad) == expected
        assert Fake.place_order(@credentials, bad, []) == expected
        assert Gemini.place_order(@credentials, bad, opts(exploding())) == expected
      end
    end

    test "a key the builder does not read is refused, not dropped" do
      # `post_only: true` used to place a plain exchange limit order.
      for {key, value} <- [post_only: true, account: "sub", margin_order: true, extra: 1] do
        request = Map.put(@request, key, value)
        expected = {:error, {:unsupported_order_field, key}}

        assert Private.place_order(@credentials, request, opts(exploding())) == expected
        assert Fake.place_order(@credentials, request, []) == expected
      end

      assert {:error, {:unsupported_order_field, "symbol"}} =
               Private.validate_order(Map.put(@request, "symbol", "BTC-USD"))
    end

    test "unread keys are refused before any field is looked at" do
      assert {:error, {:unsupported_order_field, :post_only}} =
               Private.validate_order(%{post_only: true})
    end

    test "each field is checked in turn: symbol, side, type, duration, quantity, price" do
      steps = [
        {%{}, {:invalid_symbol, nil}},
        {Map.take(@request, [:symbol]), {:missing_field, :side}},
        {Map.take(@request, [:symbol, :side]), {:missing_field, :order_type}},
        {Map.take(@request, [:symbol, :side, :order_type]), {:missing_field, :time_in_force}},
        {Map.delete(Map.delete(@request, :price), :quantity), {:missing_field, :quantity}},
        {Map.delete(@request, :price), {:missing_field, :price}}
      ]

      for {request, reason} <- steps do
        assert Private.validate_order(request) == {:error, reason}
        assert Fake.place_order(@credentials, request, []) == {:error, reason}
      end

      assert :ok = Private.validate_order(@request)
    end

    test "a bad symbol is reported before a bad type, and a bad type before a bad quantity" do
      assert {:error, {:invalid_symbol, ""}} =
               Private.validate_order(%{@request | symbol: "", order_type: :market})

      assert {:error, {:unsupported_order_type, :market}} =
               Private.validate_order(%{@request | order_type: :market, quantity: "0"})

      assert {:error, {:invalid_quantity, "0"}} =
               Private.validate_order(%{@request | quantity: "0", price: "x"})
    end

    test "a side is buy or sell in any case, and goes out lower-case" do
      for side <- ["Sell", "SELL", :sell] do
        assert {:ok, %Order{}} =
                 Private.place_order(
                   @credentials,
                   %{@request | side: side},
                   plug: capturing(@order_body, self()),
                   retry_attempts: 0
                 )

        assert_receive {:payload, %{"side" => "sell"}}, 5_000
      end

      assert {:error, {:invalid_side, "short"}} =
               Private.validate_order(%{@request | side: "short"})

      assert {:error, {:invalid_side, 1}} = Private.validate_order(%{@request | side: 1})
    end

    test "quantity, price and stop price use their own tags, and a float is refused" do
      for {field, tag, bad} <- [
            {:quantity, :invalid_quantity, 1.5},
            {:quantity, :invalid_quantity, "abc"},
            {:quantity, :invalid_quantity, Decimal.new("NaN")},
            {:quantity, :invalid_quantity, -1},
            {:price, :invalid_price, 100.0},
            {:price, :invalid_price, Decimal.new("Infinity")},
            {:price, :invalid_price, "0"}
          ] do
        assert {:error, {^tag, ^bad}} = Private.validate_order(Map.put(@request, field, bad))
      end

      stop = Map.merge(Map.delete(@request, :time_in_force), %{order_type: :stop_limit})

      assert {:error, {:invalid_stop_price, 9.5}} =
               Private.validate_order(Map.put(stop, :stop_price, 9.5))

      assert {:error, {:missing_field, :stop_price}} = Private.validate_order(stop)
    end

    test "an account option that is not a non-blank string is refused, by both" do
      for bad <- [5, "", :primary] do
        expected = {:error, {:invalid_option, :account, bad}}
        real_opts = Keyword.put(opts(exploding()), :account, bad)

        assert Private.place_order(@credentials, @request, real_opts) == expected
        assert Fake.place_order(@credentials, @request, account: bad) == expected
      end

      assert :ok = Private.validate_order(@request, account: "primary")
    end

    test "the fake refuses what the real path refuses, with the same answer" do
      for bad <- [
            %{@request | order_type: :maker_or_cancel},
            Map.delete(@request, :time_in_force),
            Map.put(@request, :time_in_force, :gtd),
            %{@request | order_type: :ioc},
            Map.put(@request, :stop_price, "9"),
            Map.put(@request, :client_order_id, ""),
            %{@request | price: 1.5}
          ] do
        real = Private.place_order(@credentials, bad, opts(exploding()))

        assert {:error, _reason} = real
        assert Fake.place_order(@credentials, bad, []) == real
      end
    end

    test "the facade takes opts on every order call" do
      assert Code.ensure_loaded?(Gemini)

      for {name, arity} <- [place_order: 2, cancel_order: 2, get_order: 2, get_orders: 1] do
        assert function_exported?(Gemini, name, arity), "#{name}/#{arity} has no default opts"
      end
    end
  end

  describe "an unconfirmed placement carries the id it was sent with" do
    defp place(request, plug), do: Private.place_order(@credentials, request, opts(plug))

    test "a 5xx is order_unconfirmed with the caller's client_order_id" do
      request = Map.put(@request, :client_order_id, "mine-1")

      assert {:error, {:order_unconfirmed, "mine-1", {:exchange_error, :gemini, message}}} =
               place(request, answering(503, ~s({"result":"error"})))

      assert message =~ "503"
    end

    test "with no client_order_id the carried id is nil, and a number is sent as its digits" do
      assert {:error, {:order_unconfirmed, nil, {:exchange_error, :gemini, _message}}} =
               place(@request, answering(500, "oops"))

      assert {:error, {:order_unconfirmed, "470135", {:exchange_error, :gemini, _message}}} =
               place(Map.put(@request, :client_order_id, 470_135), answering(502, "oops"))
    end

    test "a timeout after the send is unconfirmed" do
      timing_out = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error, {:order_unconfirmed, "c-1", {:exchange_error, :gemini, message}}} =
               place(Map.put(@request, :client_order_id, "c-1"), timing_out)

      assert is_binary(message)
    end

    test "a 2xx that is not an object naming an order_id is unconfirmed" do
      for body <- [~s({"result":"ok"}), "[]", "null", "{}"] do
        assert {:error, {:order_unconfirmed, nil, :unexpected_response_shape}} =
                 place(@request, answering(200, body))
      end
    end

    test "a 2xx that is not JSON is unconfirmed, not an undecodable bare error" do
      assert {:error, {:order_unconfirmed, "c-2", {:undecodable_response, :gemini}}} =
               place(
                 Map.put(@request, :client_order_id, "c-2"),
                 answering(200, "<html>maintenance</html>")
               )
    end

    test "a 2xx that names the order stays an order, even with an unreadable id" do
      assert {:ok, %Order{id: nil}} =
               place(@request, answering(200, ~s({"order_id":null})))

      confirmed = answering(200, Jason.encode!(@order_body))
      assert {:ok, %Order{id: "1234"}} = place(@request, confirmed)
    end

    test "the reason is bounded" do
      huge = String.duplicate("x", 100_000)

      assert {:error, {:order_unconfirmed, nil, {:exchange_error, :gemini, message}}} =
               place(@request, answering(500, huge))

      assert String.length(message) <= 256
    end

    test "a venue refusal and a decided-before-sending error are not unconfirmed" do
      assert {:refused, :invalid_symbol} =
               place(@request, answering(400, ~s({"result":"error","reason":"InvalidSymbol"})))

      assert {:error, {:exchange_error, :gemini, message}} =
               place(@request, answering(422, ~s({"reason":"x"})))

      assert message =~ "HTTP 422"

      assert {:error, {:missing_credentials, :gemini}} =
               Private.place_order(%{}, @request, opts(exploding()))
    end

    test "our own rate limiter refusing is plain, because nothing was sent" do
      Config.put_override(:rate_limit_module, DenyingLimiter)

      assert {:error, {:exchange_error, :gemini, message}} =
               place(Map.put(@request, :client_order_id, "c-3"), exploding())

      assert message =~ "not the venue"
    end

    test "a placement is sent exactly once" do
      me = self()

      plug = fn conn ->
        send(me, :attempt)
        Plug.Conn.resp(conn, 503, "down")
      end

      assert {:error, {:order_unconfirmed, nil, _reason}} =
               Private.place_order(@credentials, @request, plug: plug, retry_delay: 1)

      assert_receive :attempt, 5_000
      refute_receive :attempt, 100
    end
  end

  describe "order ids and not-found answers" do
    test "nil, a number and a blank are not order ids, before any request" do
      for bad <- [nil, 7, 0, "", "   ", :id] do
        expected = {:error, {:invalid_order_id, bad}}

        assert Private.get_order(@credentials, bad, opts(exploding())) == expected
        assert Private.cancel_order(@credentials, bad, opts(exploding())) == expected
        assert Gemini.get_order(@credentials, bad, opts(exploding())) == expected
        assert Gemini.cancel_order(%{}, bad, opts(exploding())) == expected
        assert Fake.get_order(@credentials, bad, []) == expected
        assert Fake.cancel_order(@credentials, bad, []) == expected
      end
    end

    test "a string of digits is still an id, sent as the number the schema names" do
      assert {:ok, %Order{}} =
               Private.get_order(
                 @credentials,
                 "1234",
                 plug: capturing(@order_body, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, %{"order_id" => 1234}}, 5_000
    end

    test "a 404 for an order is a refusal, :not_found, on read and on cancel" do
      for call <- [&Private.get_order/3, &Private.cancel_order/3] do
        assert call.(@credentials, "999", opts(answering(404, "not found"))) ==
                 {:refused, :not_found}
      end
    end

    test "the venue's OrderNotFound reason is the same answer" do
      body = ~s({"result":"error","reason":"OrderNotFound","message":"Order 999 not found"})

      assert Private.get_order(@credentials, "999", opts(answering(400, body))) ==
               {:refused, :not_found}

      assert Private.cancel_order(@credentials, "999", opts(answering(400, body))) ==
               {:refused, :not_found}
    end

    test "other refusals keep their reasons, and a 404 on placing is not an order missing" do
      assert {:refused, {:unknown_reason, "Boom"}} =
               Private.get_order(@credentials, "1", opts(answering(400, ~s({"reason":"Boom"}))))

      assert {:refused, reason} = place_404()
      refute reason == :not_found
    end

    defp place_404, do: Private.place_order(@credentials, @request, opts(answering(404, "no")))

    test "a cancel is sent once" do
      me = self()

      plug = fn conn ->
        send(me, :attempt)
        Plug.Conn.resp(conn, 503, "down")
      end

      assert {:error, {:exchange_error, :gemini, _message}} =
               Private.cancel_order(@credentials, "1", plug: plug, retry_delay: 1)

      assert_receive :attempt, 5_000
      refute_receive :attempt, 100
    end
  end

  describe "the fake answers what the real path answers" do
    test "an unknown id is the real 404's answer" do
      real = Private.get_order(@credentials, "424242", opts(answering(404, "no")))

      assert real == {:refused, :not_found}
      assert Fake.get_order(@credentials, "424242", []) == real
      assert Fake.cancel_order(@credentials, "424242", []) == real
    end

    test "each placement has its own id, readable and cancellable, and the side is an atom" do
      request = %{@request | side: "SELL"}

      ids =
        for _n <- 1..3 do
          assert {:ok, %Order{id: id, side: :sell, status: :open}} =
                   Fake.place_order(@credentials, request, [])

          id
        end

      assert length(Enum.uniq(ids)) == 3

      for id <- ids do
        assert {:ok, %Order{id: ^id, side: :sell}} = Fake.get_order(@credentials, id, [])
      end

      [first | rest] = ids
      assert {:ok, %Order{status: :cancelled}} = Fake.cancel_order(@credentials, first, [])
      assert {:ok, open} = Fake.get_orders(@credentials, [])
      assert Enum.sort(Enum.map(open, & &1.id)) == Enum.sort(rest)

      assert {:ok, closed} = Fake.get_orders(@credentials, history: true)
      assert first in Enum.map(closed, & &1.id)
    end

    test "orders placed in one process are not seen from another" do
      assert {:ok, %Order{id: id}} = Fake.place_order(@credentials, @request, [])

      task = Task.async(fn -> Fake.get_order(@credentials, id, []) end)
      assert Task.await(task, 5_000) == {:refused, :not_found}
    end

    test "the facade's order calls run with no opts" do
      assert {:error, {:invalid_order_id, nil}} = Gemini.get_order(@credentials, nil)
      assert {:error, {:invalid_order_id, nil}} = Gemini.cancel_order(@credentials, nil)
      assert {:error, {:invalid_order_request, nil}} = Gemini.place_order(@credentials, nil)
    end
  end
end
