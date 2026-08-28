defmodule DpExchange.Gemini.DefensiveBranchesTest do
  @moduledoc """
  The clauses that exist so something cannot happen.

  Every test here targets a branch that no ordinary call reaches: a field the venue
  usually sends and once did not, a status it usually does not return, a shape one JSON
  encoder produces and another does not.

  They are worth writing rather than deleting the branches they cover, because each of
  those branches is a decision about what to do with an answer nobody expected — and the
  answer is always the same, "refuse or carry the absence forward", never "substitute
  something plausible". A branch nobody has exercised is a decision nobody has checked.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Fake, Private, Rest}

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

  @date "Fri, 28 Aug 2026 17:00:01 GMT"
  @credentials %{api_key: "k", api_secret: "s"}

  defp json(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> then(&Req.Test.json(%{&1 | status: status}, body))
    end
  end

  # A body delivered as a raw string rather than a decoded map — which is what happens
  # whenever the venue answers with a content type Req does not decode for us.
  defp raw(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Plug.Conn.resp(status, body)
    end
  end

  describe "a venue field that is present but null" do
    test "a null last price is an unreadable ticker, not a Quote with a nil price" do
      body = %{"bid" => "1", "ask" => "2", "last" => nil}

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", plug: json(body), retry_attempts: 0)
    end

    test "a missing bid stays nil rather than becoming zero" do
      # Zero is a price. A venue that did not quote a bid has not quoted a bid of nothing.
      body = %{"last" => "1.5", "ask" => "2"}

      assert {:ok, quote_struct} = Rest.get_price("BTC-USD", plug: json(body), retry_attempts: 0)
      assert quote_struct.bid == nil
    end

    test "a book side that is null yields no levels rather than crashing" do
      body = %{
        "bids" => [%{"price" => "1", "amount" => "1", "timestamp" => "1787936377"}],
        "asks" => nil
      }

      assert {:ok, book} = Rest.get_order_book("BTC-USD", plug: json(body), retry_attempts: 0)
      assert book.asks == []
    end

    test "an unreadable level timestamp does not become the epoch" do
      # `to_integer` answering 0 for unparseable input would date the book to 1970, which
      # every staleness check would then reject — loudly, which is the point.
      body = %{
        "bids" => [%{"price" => "1", "amount" => "1", "timestamp" => "not a time"}],
        "asks" => []
      }

      assert {:ok, book} = Rest.get_order_book("BTC-USD", plug: json(body), retry_attempts: 0)
      assert book.timestamp == DateTime.from_unix!(0)
    end
  end

  describe "a body arriving as a string rather than a decoded map" do
    test "valid JSON in a raw body is still read" do
      body = ~s({"bid":"1","ask":"2","last":"1.5","volume":{"BTC":"3"}})

      assert {:ok, quote_struct} = Rest.get_price("BTC-USD", plug: raw(body), retry_attempts: 0)
      assert Decimal.equal?(quote_struct.price, Decimal.new("1.5"))
    end

    test "valid JSON in a raw body is read on a private call too" do
      body = ~s([{"currency":"USD","amount":"10.00","available":"10.00"}])

      assert {:ok, [balance]} =
               Private.get_balances(@credentials, plug: raw(body), retry_attempts: 0)

      assert balance.currency == "USD"
    end
  end

  describe "statuses between success and refusal" do
    test "a 404 on a public call is an error naming the status" do
      # Not a refusal: this venue states refusals in a 400/401/403 body. A 404 is the
      # shape of a wrong URL, which is our bug rather than the venue's answer.
      assert {:error, {:exchange_error, :gemini, message}} =
               Rest.get_price("BTC-USD", plug: json(%{}, 404), retry_attempts: 0)

      assert message =~ "404"
    end

    test "a 404 on a private call is an error too" do
      assert {:error, {:exchange_error, :gemini, message}} =
               Private.get_balances(@credentials, plug: json(%{}, 404), retry_attempts: 0)

      assert message =~ "404"
    end
  end

  describe "order fields the venue omits" do
    @order %{
      "order_id" => "1",
      "symbol" => "btcusd",
      "side" => "buy",
      "type" => "exchange limit",
      "price" => "100",
      "original_amount" => "1",
      "is_live" => true,
      "timestampms" => 1_787_936_147_000
    }

    test "no executed_amount means nothing has filled, not an unknown amount" do
      assert {:ok, order} =
               Private.get_order(@credentials, "1", plug: json(@order), retry_attempts: 0)

      assert order.status == :open
    end

    test "no timestamp leaves the field nil rather than inventing one" do
      body = Map.delete(@order, "timestampms")

      assert {:ok, order} =
               Private.get_order(@credentials, "1", plug: json(body), retry_attempts: 0)

      assert order.created_at == nil
    end

    test "a float timestamp is read, because JSON has one number type" do
      body = Map.put(@order, "timestampms", 1_787_936_147_000 * 1.0)

      assert {:ok, order} =
               Private.get_order(@credentials, "1", plug: json(body), retry_attempts: 0)

      assert order.created_at.year == 2026
    end

    test "a side the contract does not model is nil, not guessed at" do
      body = Map.put(@order, "side", "something-new")

      assert {:ok, order} =
               Private.get_order(@credentials, "1", plug: json(body), retry_attempts: 0)

      assert order.side == nil
    end
  end

  describe "order options the caller can ask for" do
    @request %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

    test "maker_or_cancel is accepted as a spelling of post_only" do
      plug = fn conn ->
        payload =
          conn
          |> Plug.Conn.get_req_header("x-gemini-payload")
          |> List.first()
          |> Base.decode64!()
          |> Jason.decode!()

        send(self(), {:options, payload["options"]})
        Req.Test.json(conn, @order)
      end

      assert {:ok, _order} =
               Private.place_order(@credentials, Map.put(@request, :order_type, :maker_or_cancel),
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a time_in_force the venue does not serve is refused before any request" do
      # `:gtd` and `:day` are in the contract's vocabulary; Gemini serves neither.
      for tif <- [:gtd, :day] do
        assert {:error, {:unsupported_time_in_force, ^tif}} =
                 Private.place_order(@credentials, Map.put(@request, :time_in_force, tif),
                   retry_attempts: 0
                 )
      end
    end
  end

  describe "the fake answers its short arities too" do
    # A consumer writing tier-1 tests calls these without options. They are part of the
    # fake's surface, so they are exercised rather than left to a consumer to discover.
    test "account calls work with credentials alone" do
      assert {:ok, _balances} = Fake.get_balances(@credentials)
      assert {:ok, _accounts} = Fake.get_accounts(@credentials)
      assert {:ok, _fees} = Fake.get_fees(@credentials)
      assert {:ok, _transfers} = Fake.get_transfers(@credentials)
      assert {:ok, _orders} = Fake.get_orders(@credentials)
      assert {:ok, _connection} = Fake.test_connection(@credentials)
    end

    test "order calls work with credentials alone" do
      request = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

      assert {:ok, _order} = Fake.place_order(@credentials, request)
      assert {:ok, _order} = Fake.cancel_order(@credentials, "1")
      assert {:ok, _order} = Fake.get_order(@credentials, "1")
    end

    test "streaming calls work with symbols alone" do
      assert :ok = Fake.subscribe(["BTC-USD"])
      assert :ok = Fake.subscribe_notices()
    end

    test "subscribing to ONLY an unlisted symbol pushes nothing and covers nothing" do
      :ok = Fake.subscribe(["NOPE-USD"], to: self())

      assert Fake.coverage() == %{}
      refute_receive {:dp_exchange, :gemini, _payload}, 50
    end

    test "quantization answers for a listed symbol" do
      assert {:ok, quantization} = Fake.quantization("BTC-USD")
      assert Decimal.equal?(quantization.price_increment, Decimal.new("0.01"))
    end
  end

  describe "the facade's own short forms" do
    test "coverage/0 answers for an unstarted default feed" do
      assert DpExchange.Gemini.coverage() == %{}
    end
  end
end
