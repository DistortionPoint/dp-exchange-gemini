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
      # The assertion moved from `Quote` to `TopOfBook` when the book left the quote — the
      # rule did not change, only where the field lives.
      body = %{"last" => "1.5", "ask" => "2"}

      assert {:ok, top} = Rest.get_top_of_book("BTC-USD", plug: json(body), retry_attempts: 0)
      assert top.bid == nil
      assert Decimal.equal?(top.ask, Decimal.new("2"))
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
      # This test's NAME was always right and its assertion was the opposite: it asserted
      # `book.venue_time == DateTime.from_unix!(0)`, pinning the very substitution the name
      # says must not happen. The old comment defended it — "`to_integer` answering 0 for
      # unparseable input would date the book to 1970, which every staleness check would
      # then reject — loudly, which is the point."
      #
      # It is not loud. `DateTime.from_unix!(0)` is a perfectly valid `DateTime`, and the
      # argument assumes a staleness check this package neither requires nor can see. A
      # consumer computing an age gets fifty-six years and may well skip the book; one that
      # logs or charts the timestamp shows 1970 and calls it data. The honest answer was
      # already in this function's own vocabulary: `{:error, :missing_venue_timestamp}` is
      # what `book_time/1` returns when no level carries a timestamp at all, which is
      # precisely what "none of them could be read" means.
      #
      # "Return `:error`. Raise. Refuse. Do not guess a value that looks right."
      body = %{
        "bids" => [%{"price" => "1", "amount" => "1", "timestamp" => "not a time"}],
        "asks" => []
      }

      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("BTC-USD", plug: json(body), retry_attempts: 0)
    end

    test "one unreadable level timestamp among readable ones still dates the book" do
      # The other half, and why `to_integer/1` answers `nil` rather than refusing outright:
      # `book_time/1` takes the MAX across levels, so one unreadable stamp among real ones is
      # not a book that cannot be dated. Only a book where nothing could be read is.
      body = %{
        "bids" => [
          %{"price" => "1", "amount" => "1", "timestamp" => "not a time"},
          %{"price" => "2", "amount" => "1", "timestamp" => 1_757_000_000}
        ],
        "asks" => []
      }

      assert {:ok, book} = Rest.get_order_book("BTC-USD", plug: json(body), retry_attempts: 0)
      assert book.venue_time == DateTime.from_unix!(1_757_000_000)
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
    test "a 404 on a public call is a refusal, not an error naming the status" do
      # This used to assert the opposite — that a 404 is "the shape of a wrong URL, our
      # bug rather than the venue's answer" — and that was the substitution: measured
      # live 2026-09-06, `GET /v1/pubticker/nonexistentsymbolxyz` returns 404 with the
      # venue naming exactly the condition, `'nonexistentsymbolxyz' does not have
      # available data yet`. `Rest.get_with_headers/2` now treats 404 the same as 400 on
      # every symbol-scoped GET. A body with no reason at all still degrades to a plain
      # refusal rather than inventing one.
      assert {:refused, :refused} =
               Rest.get_price("BTC-USD", plug: json(%{}, 404), retry_attempts: 0)
    end

    test "a 404 on a private call is still an error — unmeasured, so unchanged" do
      # Unlike the public GETs above, no live measurement backs a 404 shape for this
      # venue's authenticated POSTs, and guessing one is the mistake this family's own
      # conventions rule out. `Private`'s status list stays 400/401/403 until a 404 is
      # actually observed here.
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

  describe "candle rows the venue could not have meant" do
    # `/v2/candles/{symbol}/{width}` answers an array of
    # `[time_ms, open, high, low, close, volume]` arrays. `Core.Types.Candle` enforces
    # `:opened_at` and all four prices, and its `new/1` refuses a `nil` in any of them — but
    # this decoder builds the struct literally, so that check never ran here.
    # `Types.Validate`'s moduledoc uses this exact type as its worked example of the gap.
    #
    # `dp_exchange_coinbase` and `dp_exchange_webull` both guard all four with
    # `required_decimal/2`. This module already had that helper; the candle decoder was the
    # one place not using it.

    test "an unparseable price refuses the series rather than carrying a nil price" do
      body = [[1_757_000_000_000, "not a number", "2", "1", "1.5", "10"]]

      assert {:error, {:invalid_decimal, :open, "not a number"}} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "a NaN price refuses too — the guard this package added made nil reachable" do
      # `decimal/1` maps "NaN" and "Inf" to `nil` rather than to a poisonous `Decimal`, which
      # is right and which made a nil OHLC reachable from a value that was present all along.
      body = [[1_757_000_000_000, "1", "NaN", "1", "1.5", "10"]]

      assert {:error, {:invalid_decimal, :high, "NaN"}} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "an unreadable bar time refuses rather than opening the bar in 1970" do
      # `to_integer/1` answered `0` for a string `Integer.parse/1` could not read, and `0`
      # went straight into `DateTime.from_unix!/2`: a bar opened 1 January 1970, sorted to
      # the front of the series, every price in it real. The family's named failure exactly.
      body = [["not a time", "1", "2", "1", "1.5", "10"]]

      assert {:error, {:unparseable_venue_timestamp, "not a time"}} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "a partially numeric bar time is not read as its leading digits" do
      body = [["1757000000000-ish", "1", "2", "1", "1.5", "10"]]

      assert {:error, {:unparseable_venue_timestamp, "1757000000000-ish"}} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "a row that is not six elements is an unreadable response, not a crash" do
      # There was no clause for this, so the venue adding a seventh field raised
      # `FunctionClauseError` out of the caller's own process rather than returning an error.
      body = [[1_757_000_000_000, "1", "2", "1", "1.5", "10", "extra"]]

      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "one unreadable bar refuses the whole series rather than leaving a gap" do
      # A candle list with a bar silently missing reads as "the venue published nothing for
      # that minute", which a consumer treats as a real gap in the market rather than as a
      # decode failure.
      body = [
        [1_757_000_000_000, "1", "2", "1", "1.5", "10"],
        [1_757_000_060_000, "1", "2", "1", "", "10"]
      ]

      assert {:error, {:invalid_decimal, :close, ""}} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "an ordinary row still decodes" do
      body = [[1_757_000_000_000, "1", "2", "0.5", "1.5", "10"]]

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: json(body),
                 retry_attempts: 0
               )

      assert candle.opened_at == DateTime.from_unix!(1_757_000_000_000, :millisecond)
      assert Decimal.equal?(candle.open, Decimal.new("1"))
      assert Decimal.equal?(candle.close, Decimal.new("1.5"))
      assert Decimal.equal?(candle.volume, Decimal.new("10"))
      assert candle.provider == :gemini
    end
  end

  describe "a trade the venue did not identify" do
    test "an absent tid stays nil rather than becoming an empty string" do
      # `to_string(nil)` is `""`, so a row with no `tid` produced `id: ""` — a value that
      # passes every `nil` check a consumer might write while identifying no print at all. An
      # empty string is not a weaker id; it is a different kind of wrong, because `nil` is at
      # least detectable.
      #
      # `Private.to_fill/2` carried the identical substitution and was fixed first; this is
      # the same mistake in the sibling decoder. `WsDecode.to_trade/2` — the socket arm of
      # this same type — already used the nil-preserving form.
      body = [%{"price" => "1", "amount" => "1", "timestampms" => 1_757_000_000_000}]

      assert {:ok, [trade]} =
               Rest.get_trades("BTC-USD", plug: json(body), retry_attempts: 0)

      assert trade.id == nil
    end

    test "a stated tid is still carried, as a string" do
      body = [
        %{
          "tid" => 5_335_307_668,
          "price" => "1",
          "amount" => "1",
          "timestampms" => 1_757_000_000_000
        }
      ]

      assert {:ok, [trade]} =
               Rest.get_trades("BTC-USD", plug: json(body), retry_attempts: 0)

      assert trade.id == "5335307668"
    end
  end
end
