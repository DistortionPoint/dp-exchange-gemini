defmodule DpExchange.Gemini.EdgeCasesTest do
  @moduledoc """
  The branches that only run when something is wrong.

  Grouped rather than scattered because they share a subject: **what this package does
  with input it did not expect.** The answer must never be "carry on with a plausible
  value", and a branch that is never exercised is a branch nobody has checked answers that
  way.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Fake, Rest, Socket}

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

  defp responding(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    date = Keyword.get(opts, :date, "Fri, 28 Aug 2026 17:00:01 GMT")

    fn conn ->
      conn = if date, do: Plug.Conn.put_resp_header(conn, "date", date), else: conn
      Req.Test.json(%{conn | status: status}, body)
    end
  end

  describe "malformed venue responses" do
    test "a 400 with no reason field still refuses, generically" do
      # The venue names its reason in every 4xx observed, but a refusal must not depend on
      # that — an unnamed refusal is still permanent.
      assert {:refused, :refused} =
               Rest.get_price("BTC-USD",
                 plug: responding(%{"result" => "error"}, status: 400),
                 retry_attempts: 0
               )
    end

    test "an empty order book has no timestamp and therefore fails" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("BTC-USD",
                 plug: responding(%{"bids" => [], "asks" => []}),
                 retry_attempts: 0
               )
    end

    test "a book missing a side entirely fails rather than half-answering" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("BTC-USD",
                 plug: responding(%{"bids" => []}),
                 retry_attempts: 0
               )
    end

    test "a ticker with no volume object yields a nil volume, not a zero" do
      # Zero is a volume. A venue that did not report one has not reported none.
      body = %{"bid" => "1", "ask" => "2", "last" => "1.5"}

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert quote_struct.volume == nil
    end

    test "a Date header with an unknown month name fails closed" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD",
                 plug:
                   responding(%{"bid" => "1", "ask" => "2", "last" => "1"},
                     date: "Fri, 28 Xxx 2026 17:00:01 GMT"
                   ),
                 retry_attempts: 0
               )
    end

    test "a Date header with a non-numeric field fails closed" do
      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD",
                 plug:
                   responding(%{"bid" => "1", "ask" => "2", "last" => "1"},
                     date: "Fri, XX Aug 2026 17:00:01 GMT"
                   ),
                 retry_attempts: 0
               )
    end

    test "a 200 that is not a ticker is an error, not a Quote full of nils" do
      # A struct that passes every type check and means nothing is worse than a failure.
      # This is the family's failure mode arriving through the parser rather than the
      # venue: plausible shape, no content.
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD",
                 plug: responding(%{"unexpected" => true}),
                 retry_attempts: 0
               )
    end

    test "a 200 whose body is not JSON at all is an error too" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Plug.Conn.resp(200, "<html>maintenance</html>")
      end

      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD", plug: plug, retry_attempts: 0)
    end

    test "a 400 whose body is not JSON still refuses, keeping the venue's own words" do
      # A venue behind a proxy can answer a 4xx with an HTML error page. It is still a
      # refusal — permanent for the request as sent — and must not be reported as a
      # transient error a caller will retry forever.
      #
      # This used to collapse to a bare `{:refused, :refused}`: `refusal/1` decoded the
      # body through the same helper a 2xx success path uses, whose fallback for
      # unparseable JSON is `%{}` — discarding whatever text the venue actually sent
      # before `refusal_reason/1` ever saw it. `/v2/candles`'s 400 body is plain text on
      # the real venue (measured live 2026-09-06), so this was not a hypothetical shape.
      body = "<html>Bad Request</html>"
      plug = fn conn -> Plug.Conn.resp(conn, 400, body) end

      assert {:refused, {:unknown_reason, ^body}} =
               Rest.get_price("BTC-USD", plug: plug, retry_attempts: 0)
    end

    test "a float epoch on a candle row is read without losing the bar" do
      # JSON has one number type, so a venue that emits 1.7879357e12 is emitting the same
      # instant. Truncating to an integer is right; dropping the row would silently lose a
      # bar from a series a caller believes is complete.
      rows = [[1_787_935_740_000.0, "1", "2", "0.5", "1.5", "3"]]

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert candle.opened_at == DateTime.from_unix!(1_787_935_740_000, :millisecond)
    end

    test "a 5xx is an error the caller may retry" do
      assert {:error, _reason} =
               Rest.get_symbols(plug: responding(%{}, status: 500), retry_attempts: 0)
    end
  end

  describe "numeric conversion never loses the venue's precision" do
    test "integer and float candle fields both become Decimals" do
      rows = [[1_787_935_740_000, 1, 2.5, 0.5, 2, 0]]

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert Decimal.equal?(candle.open, Decimal.new(1))
      assert Decimal.equal?(candle.high, Decimal.from_float(2.5))
      assert Decimal.equal?(candle.volume, Decimal.new(0))
    end

    test "a string epoch on a book level is read as a number" do
      body = %{
        "bids" => [%{"price" => "1", "amount" => "1", "timestamp" => "1787936377"}],
        "asks" => [%{"price" => "2", "amount" => "1", "timestamp" => 1_787_936_378}]
      }

      assert {:ok, book} = Rest.get_order_book("BTC-USD", plug: responding(body))
      # The newest level's time, across both sides and both representations.
      assert book.timestamp == DateTime.from_unix!(1_787_936_378)
    end
  end

  describe "query parameters" do
    test "depth is sent to the venue rather than trimmed here" do
      plug = fn conn ->
        assert conn.query_string =~ "limit_bids=5"
        Req.Test.json(conn, %{"bids" => [], "asks" => []})
      end

      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("BTC-USD", plug: plug, depth: 5, retry_attempts: 0)
    end
  end

  describe "the socket's unhappy paths" do
    test "sending to a socket that will not answer returns an error, never an exit" do
      # A caller can retry a batch; it cannot recover from a linked exit it did not
      # expect. The guard turns one into the other.
      silent = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(silent, :kill) end)

      assert {:error, :send_timeout} = Socket.subscribe(silent, ["BTC-USD"])
    end

    test "subscribing to nothing sends nothing" do
      assert Socket.subscribe(:no_such_socket, []) == :ok
      assert Socket.unsubscribe(:no_such_socket, []) == :ok
    end
  end

  describe "the feed without a socket" do
    test "unsubscribing before anything was dialled is a no-op, not an error" do
      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(name: :"nosock_#{System.unique_integer([:positive])}")

      assert DpExchange.Gemini.Feed.unsubscribe(feed, ["BTC-USD"]) == :ok
      assert DpExchange.Gemini.Feed.coverage(feed) == %{}
    end

    test "a socket that cannot be dialled is reported, and the feed survives it" do
      # Claiming success when the connection failed is how a feed reports healthy while
      # delivering nothing.
      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(
          name: :"badsock_#{System.unique_integer([:positive])}",
          url: "wss://127.0.0.1:1/nowhere"
        )

      assert {:error, _reason} = DpExchange.Gemini.Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert Process.alive?(feed)
    end
  end

  describe "the rate limiter is not a suggestion" do
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

    test "our own throttle says it was OURS, so it is not mistaken for the venue's" do
      # Core distinguishes "we throttled you" from "the venue threw a 429". A caller acts
      # differently on each: one means slow down locally, the other means the venue is
      # already unhappy. Collapsing them loses the only fact that separates them.
      Config.put_override(:rate_limit_module, DenyingLimiter)

      assert {:error, {:exchange_error, :gemini, message}} =
               Rest.get_price("BTC-USD", plug: responding(%{}), retry_attempts: 0)

      assert message =~ "not the venue"
      assert message =~ "retry after 7s"
    end
  end

  describe "declared constants" do
    test "the mapping is exposed so the conformance suite can drive CanonicalPair with it" do
      mapping = DpExchange.Gemini.SymbolFormat.mapping()

      assert mapping.sep == ""
      assert mapping.quotes == DpExchange.Gemini.SymbolFormat.quotes()
    end

    test "the base URL is the venue's, and is overridable for tests" do
      assert Rest.base_url() == "https://api.gemini.com"
      assert Rest.base_url(base_url: "https://elsewhere.test") == "https://elsewhere.test"
    end
  end

  describe "the fake's remaining surface" do
    test "account and trading answer, because credentials are an argument" do
      credentials = %{api_key: "k", api_secret: "s"}

      assert {:ok, [_first | _rest]} = Fake.get_balances(credentials, [])
      assert {:ok, [_account]} = Fake.get_accounts(credentials, [])
      assert {:ok, %{}} = Fake.get_fees(credentials, [])
      assert {:ok, []} = Fake.get_transfers(credentials, [])
      assert {:ok, []} = Fake.get_orders(credentials, [])
      assert {:ok, %{reachable: true}} = Fake.test_connection(credentials, [])
    end

    test "the two endpoints that really are unsupported say so" do
      # Neither is about authentication: one is a listing that would cost 346 requests,
      # the other a header set the venue does not publish.
      assert Fake.list_instruments([]) == {:error, :not_supported}

      assert Fake.get_rate_limit_status(%{api_key: "k", api_secret: "s"}, []) ==
               {:error, :not_supported}
    end

    test "an order refuses every shape the venue will not take" do
      credentials = %{api_key: "k", api_secret: "s"}
      base = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

      # The expensive one: the venue serves no market order, and its documented
      # workaround needs a limit price only the caller can choose.
      assert {:error, {:unsupported_order_type, :market}} =
               Fake.place_order(credentials, Map.put(base, :order_type, :market), [])

      assert {:error, {:unsupported_order_type, :stop}} =
               Fake.place_order(credentials, Map.put(base, :order_type, :stop), [])

      assert {:error, {:missing_field, :price}} =
               Fake.place_order(credentials, Map.delete(base, :price), [])

      assert {:refused, :not_listed} =
               Fake.place_order(credentials, Map.put(base, :symbol, "NOPE-USD"), [])

      assert {:refused, :missing_credentials} = Fake.place_order(%{}, base, [])
    end

    test "an order the venue does take comes back as an Order" do
      credentials = %{api_key: "k", api_secret: "s"}
      base = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

      for order_type <- [:limit, :stop_limit, :post_only, :ioc, :fok] do
        assert {:ok, %DpExchange.Core.Types.Order{}} =
                 Fake.place_order(credentials, Map.put(base, :order_type, order_type), [])
      end
    end

    test "trade history requires a symbol, because the venue offers no all-symbols call" do
      credentials = %{api_key: "k", api_secret: "s"}

      assert Fake.get_trade_history(credentials, []) == {:error, {:missing_option, :symbol}}
      assert {:ok, []} = Fake.get_trade_history(credentials, symbol: "BTC-USD")
    end

    test "it answers the same identity questions as the real package" do
      assert Fake.provider_name() == DpExchange.Gemini.provider_name()
      assert Fake.runtime_id() == DpExchange.Gemini.runtime_id()
      assert Fake.asset_classes() == DpExchange.Gemini.asset_classes()
      assert Fake.market_status([]) == {:ok, :open}
    end

    test "child_spec/1 takes its id from the name" do
      assert %{id: :fake_name} = Fake.child_spec(name: :fake_name)
    end

    test "an unlisted symbol is refused for historical prices too" do
      assert Fake.get_historical_prices("NOPE-USD", "1d") == {:refused, :not_listed}
    end

    test "update_symbols narrows what coverage reports" do
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())
      :ok = Fake.update_symbols(["BTC-USD"])

      assert Fake.coverage() == %{"BTC-USD" => :stream}
    end

    test "notices reach a notice subscriber" do
      :ok = Fake.subscribe_notices(to: self())

      assert_receive {:dp_exchange, :gemini, %DpExchange.Core.Notice{kind: :link_up}}
    end

    test "the market overview covers every symbol it lists" do
      {:ok, symbols} = Fake.get_symbols()
      {:ok, overview} = Fake.get_market_overview()

      assert Enum.sort(Map.keys(overview)) == Enum.sort(symbols)
    end
  end

  describe "private-call branches that only run when the venue misbehaves" do
    @credentials %{api_key: "k", api_secret: "s"}

    test "a balances response with no Date header fails rather than stamping our clock" do
      # Same rule as a quote: a balance a caller cannot date is a balance whose staleness
      # cannot be judged.
      plug = fn conn -> Req.Test.json(conn, []) end

      assert {:error, :missing_venue_timestamp} =
               DpExchange.Gemini.Private.get_balances(@credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a malformed Date header on a private call fails the same way" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "whenever")
        |> Req.Test.json([])
      end

      assert {:error, :missing_venue_timestamp} =
               DpExchange.Gemini.Private.get_balances(@credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a refusal with a non-JSON body is still a refusal, keeping the venue's words" do
      # See `Rest.refusal_reason/1`'s moduledoc: this used to collapse to a bare
      # `{:refused, :refused}` because `refusal/1` pre-decoded the body through the same
      # helper a 2xx success path uses, discarding unparseable text before
      # `refusal_reason/1` got a chance to keep it.
      body = "<html>denied</html>"
      plug = fn conn -> Plug.Conn.resp(conn, 401, body) end

      assert {:refused, {:unknown_reason, ^body}} =
               DpExchange.Gemini.Private.get_balances(@credentials,
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "numeric order fields survive whichever JSON type the venue used" do
      # JSON has one number type. A venue emitting 100 and one emitting "100.00" are
      # saying the same thing, and both must reach Decimal rather than one being dropped.
      body = %{
        "order_id" => 1234,
        "symbol" => "btcusd",
        "side" => "buy",
        "type" => "exchange limit",
        "price" => 100,
        "original_amount" => 1.5,
        "executed_amount" => 0,
        "is_live" => true,
        "timestampms" => 1_787_936_147_000
      }

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(body)
      end

      assert {:ok, order} =
               DpExchange.Gemini.Private.get_order(@credentials, "1234",
                 plug: plug,
                 retry_attempts: 0
               )

      assert Decimal.equal?(order.price, Decimal.new(100))
      assert Decimal.equal?(order.quantity, Decimal.from_float(1.5))
      assert order.id == "1234"
    end
  end

  describe "the fake's own remaining branches" do
    test "it accepts an OAuth token as readily as a key pair" do
      # The fake must not be pickier about authentication than the real adapter, or a
      # consumer's OAuth path passes here and fails there.
      assert {:ok, _balances} = Fake.get_balances(%{access_token: "tok"}, [])
    end

    test "maker_or_cancel is accepted under either spelling" do
      credentials = %{api_key: "k", api_secret: "s"}
      base = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

      for spelling <- [:post_only, :maker_or_cancel] do
        assert {:ok, _order} =
                 Fake.place_order(credentials, Map.put(base, :order_type, spelling), [])
      end
    end

    test "an unsupported time_in_force is refused" do
      credentials = %{api_key: "k", api_secret: "s"}
      base = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

      assert {:error, {:unsupported_time_in_force, :gtd}} =
               Fake.place_order(credentials, Map.put(base, :time_in_force, :gtd), [])
    end

    test "a Decimal quantity is passed through, not re-parsed" do
      credentials = %{api_key: "k", api_secret: "s"}

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("1.5"),
        price: Decimal.new("100")
      }

      assert {:ok, order} = Fake.place_order(credentials, request, [])
      assert Decimal.equal?(order.quantity, Decimal.new("1.5"))
    end
  end

  describe "the feed's delta and fan-out branches" do
    defp answering_socket(report_to) do
      spawn_link(fn -> answer_frames(report_to) end)
    end

    defp answer_frames(report_to) do
      receive do
        {:"$websockex_send", from, {:text, frame}} ->
          send(report_to, {:frame, Jason.decode!(frame)})
          :gen.reply(from, :ok)
          answer_frames(report_to)
      end
    end

    test "update_symbols sends an unsubscribe AND a subscribe when the set changes" do
      # One call can wait out two send windows, which is why the feed's call timeout is
      # three of them rather than one.
      name = :"delta_#{System.unique_integer([:positive])}"

      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(name: name, socket: answering_socket(self()))

      :ok = DpExchange.Gemini.Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame, %{"method" => "subscribe"}}

      :ok = DpExchange.Gemini.Feed.update_symbols(feed, ["ETH-USD"])

      assert_receive {:frame, %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}}
      assert_receive {:frame, %{"method" => "subscribe", "params" => ["ethusd@bookTicker"]}}
    end

    test "a notice reaches a live notice subscriber and skips a dead one" do
      name = :"notice_#{System.unique_integer([:positive])}"

      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(name: name, socket: answering_socket(self()))

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      :ok = DpExchange.Gemini.Feed.subscribe_notices(feed, to: dead)
      :ok = DpExchange.Gemini.Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :gemini, DpExchange.Core.Notice.new(:degraded, :gemini)})

      assert_receive {:dp_exchange, :gemini, %DpExchange.Core.Notice{kind: :degraded}}
    end
  end

  describe "REST branches not otherwise reached" do
    test "a candle range with only an :end bound filters from the top" do
      rows = [
        [1_787_935_740_000, "1", "2", "0.5", "1.5", "3"],
        [1_787_935_680_000, "1", "2", "0.5", "1.5", "3"]
      ]

      finish = DateTime.from_unix!(1_787_935_700_000, :millisecond)

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [end: finish],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert candle.opened_at == DateTime.from_unix!(1_787_935_680_000, :millisecond)
    end

    test "a market overview with an integer price still yields a Decimal" do
      body = [%{"pair" => "BTCUSD", "price" => 100, "percentChange24h" => 0.5}]

      assert {:ok, overview} =
               Rest.get_market_overview(plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(overview["BTC-USD"].price, Decimal.new(100))
    end
  end
end
