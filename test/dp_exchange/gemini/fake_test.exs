defmodule DpExchange.Gemini.FakeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Core.Types.{OrderBook, Quote}
  alias DpExchange.Gemini.{Fake, Rest}

  @credentials %{api_key: "k", api_secret: "s"}

  # Inside the visibility window the real endpoint enforces, so a candle assertion is not
  # accidentally testing the window check.
  defp within_window do
    [start: DateTime.add(DateTime.utc_now(), -60 * 60, :second), end: DateTime.utc_now()]
  end

  describe "less capable is allowed; differently capable is not" do
    test "it declares the REAL venue's capabilities" do
      # A fake declaring different capabilities from the venue it stands in for is a fake
      # a consumer cannot use to test capability branching.
      assert Fake.capabilities() == DpExchange.Gemini.capabilities()
    end

    test "an unsupported endpoint errors rather than returning an empty success" do
      # `{:ok, []}` for something unsupported is the silent failure: the caller gets a
      # plausible answer and never learns the question was not answered.
      assert Fake.list_portfolios([]) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(%{}, []) == {:error, :not_supported}
    end

    test "an account call with no credentials refuses rather than answering emptily" do
      # A fake that accepted `nil` would let a consumer's test pass while the real call
      # fails on a missing key — differently capable, which is the forbidden kind.
      assert Fake.get_balances(%{}, []) == {:error, {:missing_credentials, :gemini}}
      assert Fake.get_accounts(%{}, []) == {:error, {:missing_credentials, :gemini}}
    end

    test "it never stamps the current clock" do
      # A fake that stamps `utc_now/0` cannot be used to test anything about freshness,
      # and is itself the substitution this family refuses.
      {:ok, first} = Fake.get_price("BTC-USD")
      {:ok, second} = Fake.get_price("BTC-USD")

      # `venue_time` is `nil` on the REST quote (the venue states none), so the clock the fake
      # could stamp is `observed_at`: two reads are the same fixed instant, in the past.
      assert first.observed_at == second.observed_at
      assert first.observed_at == ~U[2026-08-28 12:00:00Z]
    end
  end

  describe "it models the venue's refusals, not only its successes" do
    test "an unlisted symbol is a refusal, not an error" do
      # Each shape mirrors the specific endpoint behind it — see `Fake`'s own moduledoc —
      # rather than one invented atom standing in for all three.
      assert Fake.get_price("NOPE-USD") == {:refused, :not_listed}

      assert Fake.get_order_book("NOPE-USD") == {:refused, :not_listed}
      assert Fake.quantization("NOPE-USD") == {:refused, :not_listed}
    end

    test "a width the venue does not serve is an error" do
      for width <- ~w(2h 4h 12h) do
        assert {:error, {:unsupported_timeframe, ^width}} =
                 Fake.get_historical_prices("BTC-USD", width)
      end
    end

    test "a range before the fixed window is refused, as the real endpoint's would be" do
      # This venue's distinctive failure mode. A consumer that has not handled it finds
      # out here rather than in production.
      long_ago = ~U[2020-01-01 00:00:00Z]

      assert {:error, {:range_unavailable, "1d", _details}} =
               Fake.get_historical_prices("BTC-USD", "1d", start: long_ago)
    end

    test "a range inside the window succeeds" do
      # Relative to now, not a fixed date: the `1d` window is 364 bars, so a hardcoded start
      # stops being inside it a year after it was written. The fake moves its bar to the first
      # boundary at or after `start`, which for a start this recent is still forming, hence
      # `include_partial: true`.
      recent = DateTime.add(DateTime.utc_now(), -12 * 3_600, :second)

      assert {:ok, [_candle]} =
               Fake.get_historical_prices("BTC-USD", "1d", [start: recent], include_partial: true)
    end

    test "a range the bar falls outside of is an empty list, as Rest's own filter would give" do
      # The fake's daily bar opens at 2026-08-28 00:00:00Z, on its width boundary. `:end` is
      # exclusive: a range ending AT the bar's open keeps nothing, one second later keeps it.
      assert {:ok, []} =
               Fake.get_historical_prices("BTC-USD", "1d", end: ~U[2026-08-28 00:00:00Z])

      assert {:ok, [bar]} =
               Fake.get_historical_prices("BTC-USD", "1d", end: ~U[2026-08-28 00:00:01Z])

      assert bar.opened_at == ~U[2026-08-28 00:00:00Z]

      # A `start` after the bar moves it to the first boundary at or after `start`, and a range
      # that ends before that boundary keeps nothing, exactly as `Rest.within?/2` decides.
      start = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:second)
      assert {:ok, [moved]} = Fake.get_historical_prices("BTC-USD", "1m", start: start)
      assert DateTime.compare(moved.opened_at, start) != :lt
      assert rem(DateTime.to_unix(moved.opened_at), 60) == 0
      assert DateTime.diff(moved.opened_at, start) <= 60

      assert {:ok, []} =
               Fake.get_historical_prices("BTC-USD", "1m",
                 start: start,
                 end: DateTime.add(start, -1, :second)
               )

      for bar <- [bar, moved] do
        range = [start: bar.opened_at, end: DateTime.add(bar.opened_at, 1, :second)]
        assert [^bar] = Rest.select_candles([bar], "1m", range, include_partial: true)

        assert [] =
                 Rest.select_candles([bar], "1m", [start: bar.opened_at, end: bar.opened_at],
                   include_partial: true
                 )
      end
    end

    test "1w and 1M never refuse on range — no Timeframe.seconds/1 width to check against" do
      # Real venue behaviour, found live 2026-09-08: `range_within_window/2` has no bar
      # count to compute an earliest instant from for either width, so it never refuses
      # here — see `Rest`'s moduledoc. The fake mirrors that rather than crashing on the
      # `Timeframe.seconds/1` mismatch a naive port of the five-width logic would hit.
      long_ago = ~U[2000-01-01 00:00:00Z]

      for canonical <- ~w(1w 1M) do
        assert {:ok, [_candle]} =
                 Fake.get_historical_prices("BTC-USD", canonical, start: long_ago)
      end
    end
  end

  describe "the shapes it returns are the real ones" do
    test "a quote is a Quote with Decimals" do
      assert {:ok, %Quote{} = quote_struct} = Fake.get_price("BTC-USD")
      assert %Decimal{} = quote_struct.price
      assert quote_struct.provider == :gemini
    end

    test "a book is an OrderBook with Decimal level tuples" do
      assert {:ok, %OrderBook{bids: bids, asks: asks}} = Fake.get_order_book("BTC-USD")

      for {price, size} <- bids ++ asks do
        assert %Decimal{} = price
        assert %Decimal{} = size
      end
    end

    test "the book is deep enough for its own ordering to be checkable" do
      # This pinned `bids: [{price, size}]` — one level, exactly — and that pin was part of
      # why the fixture stayed one level deep. `Core.AdapterContract`'s assertion 25 checks
      # that bids come back highest-first and asks lowest-first, and against a one-element
      # list it cannot fail: there is no pair of prices to put in the wrong order. The
      # assertion ran, reached this function, and reported green for having looked at
      # nothing.
      #
      # So the depth is asserted here as a property of the fixture, in this package, next to
      # the fake it constrains — Core refuses a thinner book too, and the two are meant to
      # be saying the same thing from both ends.
      assert {:ok, %OrderBook{bids: bids, asks: asks}} = Fake.get_order_book("BTC-USD")

      assert length(bids) >= 2, "a one-level book makes assertion 25 incapable of failing"
      assert length(asks) >= 2, "a one-level book makes assertion 25 incapable of failing"
    end

    test "depth takes the first N levels a side; 0 or absent is the whole ladder" do
      {:ok, whole} = Fake.get_order_book("BTC-USD")
      assert length(whole.bids) == 3

      assert {:ok, one} = Fake.get_order_book("BTC-USD", depth: 1)
      assert one.bids == Enum.take(whole.bids, 1)
      assert one.asks == Enum.take(whole.asks, 1)

      assert {:ok, two} = Fake.get_order_book("BTC-USD", depth: 2)
      assert two.bids == Enum.take(whole.bids, 2)

      assert {:ok, ^whole} = Fake.get_order_book("BTC-USD", depth: 0)
      assert {:ok, ^whole} = Fake.get_order_book("BTC-USD", depth: 50)
    end

    test "the book is ordered the way Core.Types.OrderBook requires" do
      assert {:ok, %OrderBook{bids: bids, asks: asks}} = Fake.get_order_book("BTC-USD")

      prices = fn levels -> Enum.map(levels, fn {price, _size} -> price end) end

      assert prices.(bids) == Enum.sort_by(prices.(bids), & &1, {:desc, Decimal})
      assert prices.(asks) == Enum.sort_by(prices.(asks), & &1, {:asc, Decimal})
    end

    test "its symbols include the overlapping-quote pairs that break naive splitting" do
      assert {:ok, symbols} = Fake.get_symbols()
      assert "BTC-GUSD" in symbols
      assert "SOL-RLUSD" in symbols
    end
  end

  describe "streaming in memory" do
    test "subscribing delivers immediately, as the venue's first frame does" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}
    end

    test "the streamed Quote's venue_time is nil, unlike get_price/2's" do
      # The real venue's `bookTicker` `c` carries no trade time (websocket.yaml:1254-1256),
      # so `Socket.deliver_last_trade/3` sends `venue_time: nil` unconditionally on the
      # stream — a different fact from `get_price/2`'s REST `Quote`, whose `venue_time` is
      # also `nil` (the venue states no trade time; the `Date` header is not one).
      assert {:ok, %Quote{venue_time: nil}} = Fake.get_price("BTC-USD")

      :ok = Fake.subscribe(["BTC-USD"], to: self())
      assert_receive {:dp_exchange, :gemini, %Quote{venue_time: nil}}
    end

    test "coverage reports only what it actually pushed" do
      :ok = Fake.subscribe(["BTC-USD", "NOPE-USD"], to: self())

      assert Fake.coverage() == %{"BTC-USD" => :stream}
    end

    test "unsubscribing removes it from coverage" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())
      :ok = Fake.unsubscribe(["BTC-USD"])

      assert Fake.coverage() == %{}
    end
  end

  describe "wanted/1" do
    test "is the sorted set of symbols subscribed, narrowed by unsubscribe" do
      assert Fake.wanted() == []

      :ok = Fake.subscribe(["ETH-USD", "BTC-USD"], to: self())
      assert Fake.wanted() == ["BTC-USD", "ETH-USD"]

      :ok = Fake.unsubscribe(["BTC-USD"])
      assert Fake.wanted() == ["ETH-USD"]
    end
  end

  describe "coverage_by_kind/1" do
    test "reports what it pushed under each kind, and declares the rest honestly empty" do
      # The default channels are the real Feed's, `[:quotes, :top_of_book]`, so a `Quote`
      # and a `TopOfBook` are both pushed. It used to push only the `Quote`. Every declared
      # key still appears, empty where nothing of that kind was observed: `:trades` stays
      # empty because this call did not ask for it.
      :ok = Fake.subscribe(["BTC-USD", "NOPE-USD"], to: self())

      assert_received {:dp_exchange, :gemini, %DpExchange.Core.Types.TopOfBook{symbol: "BTC-USD"}}

      assert Fake.coverage_by_kind() == %{
               quotes: %{"BTC-USD" => :stream},
               top_of_book: %{"BTC-USD" => :stream},
               trades: %{}
             }
    end

    test "update_symbols pushes for a symbol it adds, so coverage is never intent alone" do
      :ok = Fake.update_symbols(["ETH-USD"])

      assert_received {:dp_exchange, :gemini, %DpExchange.Core.Types.Quote{symbol: "ETH-USD"}}
      assert Fake.coverage() == %{"ETH-USD" => :stream}
    end

    test "subscribe does not consume a failure queued for get_price" do
      DpExchange.Core.FakeInjection.queue_failures(:gemini, [{:error, :queued}])
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert {:error, :queued} = Fake.get_price("BTC-USD")
    end

    test "subscribe_notices registers and sends nothing, as the real Feed does" do
      assert :ok = Fake.subscribe_notices(to: self())
      refute_received {:dp_exchange, :gemini, %DpExchange.Core.Notice{}}
    end

    test "the union of its symbols across kinds matches coverage/1's keys exactly" do
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())

      union =
        Fake.coverage_by_kind()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert union == Fake.coverage() |> Map.keys() |> Enum.sort()
    end

    test "every kind key it reports is one capabilities().streamable declares" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      declared = MapSet.new(Fake.capabilities().streamable)
      reported = Fake.coverage_by_kind() |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(reported, declared)
    end

    test "unsubscribing removes it from every kind's bucket" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())
      :ok = Fake.unsubscribe(["BTC-USD"])

      assert Fake.coverage_by_kind() == %{quotes: %{}, top_of_book: %{}, trades: %{}}
    end
  end

  describe "channels: [:trades] — dp-exchange-core issue #39" do
    alias DpExchange.Core.Types.Trade

    test "without :trades in channels, no Trade is pushed, matching Feed's own default" do
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert_receive {:dp_exchange, :gemini, %Quote{}}
      # `Fake.subscribe/2` pushes inside the call: a Trade would already be in the mailbox.
      refute_received {:dp_exchange, :gemini, %Trade{}}
    end

    test "a channels: option on subscribe is refused, as the real facade refuses it" do
      for value <- [[:trades], [:quotes, :top_of_book], [:bogus], "trades"] do
        assert {:error, {:invalid_option, :channels, ^value}} =
                 Fake.subscribe(["BTC-USD"], to: self(), channels: value)

        assert {:error, {:invalid_option, :channels, ^value}} =
                 DpExchange.Gemini.Feed.subscribe(
                   :no_such_feed_process,
                   ["BTC-USD"],
                   to: self(),
                   channels: value
                 )
      end

      refute_received {:dp_exchange, :gemini, _anything}
      assert Fake.coverage() == %{}
    end

    test "the invalid-symbols and invalid-subscriber refusals still come before it" do
      assert {:error, {:invalid_symbols, "BTC-USD"}} =
               Fake.subscribe("BTC-USD", channels: [:trades])

      assert {:error, {:invalid_subscriber, "x"}} =
               Fake.subscribe(["BTC-USD"], to: "x", channels: [:trades])
    end

    test "configured channels outside the streamable kinds raise, as a feed start does" do
      DpExchange.Core.Config.put_override(:channels, [:bogus])

      assert_raise ArgumentError, fn -> Fake.subscribe(["BTC-USD"], to: self()) end
    end

    test "configured :trades pushes a Trade alongside the streamed Quote" do
      DpExchange.Core.Config.put_override(:channels, [:quotes, :top_of_book, :trades])
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}
      assert_receive {:dp_exchange, :gemini, %Trade{symbol: "BTC-USD"} = trade}

      # Consistent with `WsDecode.to_trade/2`'s own shape: a real id, a real side, no
      # bust flag, and a real timestamp — never the nils a less careful fake would leave
      # in place. See `Fake.trade_for/1`'s own comment.
      assert trade.id != nil
      assert trade.side in [:buy, :sell]
      assert trade.broken == false
      assert trade.timestamp != nil
      assert Decimal.equal?(trade.price, Decimal.new("77845.79"))
    end

    test "an unlisted symbol gets no Trade, same as it gets no Quote" do
      DpExchange.Core.Config.put_override(:channels, [:trades])
      :ok = Fake.subscribe(["NOPE-USD"], to: self())

      refute_received {:dp_exchange, :gemini, _anything}
    end

    test "coverage_by_kind/1 tracks trades coverage independently of quotes coverage" do
      DpExchange.Core.Config.put_override(:channels, [:quotes, :top_of_book, :trades])
      :ok = Fake.subscribe(["BTC-USD"], to: self())
      DpExchange.Core.Config.put_override(:channels, [:quotes, :top_of_book])
      :ok = Fake.subscribe(["ETH-USD"], to: self())

      by_kind = Fake.coverage_by_kind()

      assert by_kind.quotes == %{"BTC-USD" => :stream, "ETH-USD" => :stream}
      assert by_kind.trades == %{"BTC-USD" => :stream}
    end

    test "unsubscribing drops the symbol from :trades coverage too" do
      DpExchange.Core.Config.put_override(:channels, [:trades])
      :ok = Fake.subscribe(["BTC-USD"], to: self())
      assert Fake.coverage_by_kind().trades == %{"BTC-USD" => :stream}

      :ok = Fake.unsubscribe(["BTC-USD"])

      assert Fake.coverage_by_kind().trades == %{}
    end

    test "update_symbols/2 narrows :trades coverage to the new set, same as :quotes" do
      DpExchange.Core.Config.put_override(:channels, [:trades])
      :ok = Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())
      assert Fake.coverage_by_kind().trades == %{"BTC-USD" => :stream, "ETH-USD" => :stream}

      :ok = Fake.update_symbols(["BTC-USD"])

      assert Fake.coverage_by_kind().trades == %{"BTC-USD" => :stream}
    end
  end

  describe "lifecycle" do
    test "it starts nothing" do
      assert Fake.start_link([]) == :ignore
    end
  end

  describe "order lifecycle in memory" do
    test "an order that was never placed is not found, as the real venue's 404 is" do
      assert Fake.get_order(@credentials, "123456", []) == {:refused, :not_found}
      assert Fake.cancel_order(@credentials, "123456", []) == {:refused, :not_found}
    end

    test "both refuse without credentials, as the real adapter does" do
      assert Fake.get_order(%{}, "123456", []) == {:error, {:missing_credentials, :gemini}}
      assert Fake.cancel_order(%{}, "123456", []) == {:error, {:missing_credentials, :gemini}}
    end

    test "a placed order carries the caller's own values back, unrewritten" do
      # The fake never rewrites what the caller supplied — the rule that stops a fake
      # being usable to prove something the real venue would not do.
      request = %{
        symbol: "ETH-USD",
        side: :sell,
        quantity: "2",
        price: "3000",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, order} = Fake.place_order(@credentials, request, [])
      assert order.symbol == "ETH-USD"
      assert order.side == :sell
      assert Decimal.equal?(order.price, Decimal.new("3000"))
    end

    test "the id a placed order carries is one get_order/3 and cancel_order/3 accept" do
      # Issue #5: `place_order/3` issued `"fake-order-1"`, which the id check both of these
      # share with the real adapter refuses, so a place -> get -> cancel round trip failed.
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "0.001",
        price: "100",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, placed} = Fake.place_order(@credentials, request)
      assert {:ok, %{id: id}} = Fake.get_order(@credentials, placed.id, [])
      assert id == placed.id
      assert {:ok, %{id: ^id, status: :cancelled}} = Fake.cancel_order(@credentials, id, [])
      assert {:ok, %{id: ^id, status: :cancelled}} = Fake.get_order(@credentials, id, [])
    end

    test "every placement is a new order with its own id" do
      request = %{
        symbol: "BTC-USD",
        side: "BUY",
        quantity: "1",
        price: "100",
        order_type: :limit,
        time_in_force: :gtc,
        client_order_id: "same-id"
      }

      assert {:ok, first} = Fake.place_order(@credentials, request)
      assert {:ok, second} = Fake.place_order(@credentials, request)

      assert first.id != second.id
      # The caller's "BUY" comes back as the atom, never the string.
      assert first.side == :buy
      assert {:ok, [open_a, open_b]} = Fake.get_orders(@credentials, [])
      assert Enum.sort([open_a.id, open_b.id]) == Enum.sort([first.id, second.id])

      assert {:ok, _cancelled} = Fake.cancel_order(@credentials, first.id)
      assert {:ok, [still_open]} = Fake.get_orders(@credentials, [])
      assert still_open.id == second.id
    end

    test "an integer id is refused, as the real adapter refuses it" do
      expected = {:error, {:invalid_order_id, 123_456}}

      assert Fake.get_order(@credentials, 123_456, []) == expected
      assert Fake.cancel_order(@credentials, 123_456, []) == expected
    end
  end

  describe "it refuses exactly what the real venue refuses" do
    test "every endpoint declared :unsupported returns the atom" do
      # This is the sweep. Without it the fake can drift from the declaration one callback
      # at a time, and each drift is a consumer's suite passing on a call that cannot be
      # made — which is what a fake is for preventing.
      unsupported =
        for {{name, arity}, :unsupported} <- DpExchange.Gemini.capabilities().endpoints,
            name not in [:child_spec, :start_link],
            do: {name, arity}

      refute unsupported == []

      for {name, arity} <- unsupported do
        assert apply(Fake, name, fake_args(arity)) == {:error, :not_supported},
               "Fake.#{name}/#{arity} does not refuse, and the declaration says it should"
      end
    end
  end

  defp fake_args(1), do: [[]]
  defp fake_args(2), do: [@credentials, []]
  defp fake_args(3), do: [@credentials, "id", []]
  defp fake_args(4), do: [@credentials, "id", %{}, []]
  defp fake_args(5), do: [@credentials, "id", "network", Decimal.new("1"), []]

  describe "candles are bars, not quotes" do
    test "a candle carries all four prices" do
      assert {:ok, [bar]} = Fake.get_historical_prices("BTC-USD", "1m", within_window())

      assert %Types.Candle{} = bar
      assert bar.timeframe == "1m"
      assert Types.Candle.coherent?(bar)
      assert bar.provider == :gemini
    end

    test "the bar still forming is dropped unless include_partial: true, as the real call" do
      # A weekly bar opened an hour ago is forming for the next six days, so this cannot
      # race a bar boundary. `1w` has no `Timeframe.seconds/1` width: the fake opens it at
      # `start` itself.
      range = [start: DateTime.add(DateTime.utc_now(), -3_600, :second)]

      assert {:ok, []} = Fake.get_historical_prices("BTC-USD", "1w", range)

      assert {:ok, []} =
               Fake.get_historical_prices("BTC-USD", "1w", range, include_partial: false)

      assert {:ok, [_forming]} =
               Fake.get_historical_prices("BTC-USD", "1w", range, include_partial: true)

      assert {:error, {:invalid_option, :include_partial, "yes"}} =
               Fake.get_historical_prices("BTC-USD", "1w", range, include_partial: "yes")
    end

    test "a candle limit is refused by the fake exactly as the real call refuses it" do
      real = Rest.get_historical_prices("BTC-USD", "1m", [], limit: 5, retry_attempts: 0)

      assert real == {:error, {:unsupported_option, :limit}}
      assert Fake.get_historical_prices("BTC-USD", "1m", [], limit: 5) == real
    end
  end

  describe "bulk cancel" do
    test "no scope is an error, as it is on the real venue" do
      assert {:error, :scope_required} = Fake.cancel_all_orders(@credentials, [])
    end

    test "a scope the venue does not have is an error" do
      assert {:error, {:unsupported_scope, :everything}} =
               Fake.cancel_all_orders(@credentials, scope: :everything)
    end

    test "either scope answers with the venue's two lists, empty when nothing is open" do
      assert {:ok, %{cancelled: [], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :session)

      assert {:ok, %{cancelled: [], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :account)
    end

    test "it cancels the orders this process placed, and names them" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: "1",
        price: "100"
      }

      assert {:ok, first} = Fake.place_order(@credentials, request, [])
      assert {:ok, second} = Fake.place_order(@credentials, request, [])
      assert {:ok, [_one, _two]} = Fake.get_orders(@credentials, [])

      assert {:ok, %{cancelled: cancelled, rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :session)

      assert Enum.sort(cancelled) == Enum.sort([first.id, second.id])
      assert Fake.get_orders(@credentials, []) == {:ok, []}
      assert {:ok, %{status: :cancelled}} = Fake.get_order(@credentials, first.id, [])

      assert {:ok, %{cancelled: [], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :account)
    end

    test "it refuses without credentials, as every account call does" do
      assert {:error, {:missing_credentials, :gemini}} =
               Fake.cancel_all_orders(%{}, scope: :session)
    end
  end

  describe "orders: resting and closed are different questions" do
    test "asking without saying gets the resting ones" do
      assert {:ok, []} = Fake.get_orders(@credentials, [])
    end

    test "asking for history gets closed ones" do
      assert {:ok, [order]} = Fake.get_orders(@credentials, history: true)
      assert order.status == :filled
    end
  end

  describe "conversions" do
    test "the fake refuses the direction the real package refuses" do
      # This venue quotes in crypto as well as fiat, so USD -> BTC is genuinely ambiguous
      # and only the catalogue resolves it. A fake that picked one would let a consumer's
      # suite pass on a conversion that spends the wrong asset.
      assert {:error, {:ambiguous_conversion, "USD", "BTC"}} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("100"), credentials: @credentials)
    end

    test "an explicit symbol and side get a quote with a real window" do
      assert {:ok, conversion} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("100"),
                 symbol: "BTC-USD",
                 side: :buy,
                 credentials: @credentials
               )

      assert conversion.status == :quoted
      assert conversion.expires_at
      refute Types.Conversion.expired?(conversion, conversion.venue_time)
    end

    test "committing needs the terms the venue quoted against" do
      assert {:error, {:missing_option, [:symbol, :side, :amount, :price, :fee]}} =
               Fake.commit_conversion("1234", credentials: @credentials)
    end

    @terms [
      symbol: "BTC-USD",
      side: :buy,
      amount: Decimal.new("1"),
      price: Decimal.new("40000"),
      fee: Decimal.new("2.50"),
      credentials: @credentials
    ]

    test "a committed conversion is settled" do
      assert {:ok, conversion} = Fake.commit_conversion("1234", @terms)

      assert conversion.status == :settled
    end

    test "the quote's own id is one commit_conversion/2 accepts" do
      # The quote id was `"fake-gemini-quote-1"`, which the shared quote-id check refuses.
      assert {:ok, quoted} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("100"),
                 symbol: "BTC-USD",
                 side: :buy,
                 credentials: @credentials
               )

      assert {:ok, %{id: id, status: :settled}} = Fake.commit_conversion(quoted.id, @terms)
      assert id == quoted.id
    end

    test "a term that is nil or blank is missing, as the real package counts it" do
      # `Keyword.has_key?/2` said `price: nil` was given, and the fake committed a conversion
      # the real package refuses before it signs anything.
      assert {:error, {:missing_option, [:price, :fee]}} =
               Fake.commit_conversion("1234", Keyword.merge(@terms, price: nil, fee: " "))
    end

    test "a quote id that is not the venue's integer is refused, as the real package refuses it" do
      assert {:error, {:invalid_quote_id, "q-1"}} = Fake.commit_conversion("q-1", @terms)
    end

    test "a half-given direction is refused as the real package refuses it" do
      assert {:error, {:missing_option, [:symbol, :side]}} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("1"),
                 symbol: "BTC-USD",
                 credentials: @credentials
               )
    end

    test "what the real package refuses before it signs is refused before the credential" do
      # Nothing is signed for a request that is wrong on its face, so a caller with neither a
      # credential nor a valid request is told about the request, as `Private` tells them.
      assert {:error, {:ambiguous_conversion, "USD", "BTC"}} =
               Fake.quote_conversion("USD", "BTC", Decimal.new("1"), [])

      assert {:error, {:missing_option, _terms}} = Fake.commit_conversion("1234", [])
      assert {:error, :scope_required} = Fake.cancel_all_orders(%{}, [])
      assert {:error, {:invalid_symbol, nil}} = Fake.place_order(%{}, %{}, [])
      assert {:error, {:invalid_order_request, nil}} = Fake.place_order(%{}, nil, [])

      assert {:error, {:unsupported_fx_pair, "XYZUSD"}} =
               Fake.get_fx_rate("XYZ-USD", ~U[2026-01-02 00:00:00Z])

      assert {:error, {:invalid_fx_instant, nil}} = Fake.get_fx_rate("XYZ-USD", nil)
      assert {:error, {:missing_option, :network}} = Fake.list_approved_addresses([])
      assert {:error, {:missing_option, :address}} = Fake.estimate_withdrawal_fee("ETH", "x", 1)
      assert {:error, :memo_required} = Fake.withdraw("ETH", "x", 1, "a", memo_required: true)
      assert {:error, {:unsupported_country, "GB"}} = Fake.add_payment_method(%{}, country: "GB")
      assert {:error, {:missing_option, :from}} = Fake.transfer_internal("BTC", 1, [], [])
      assert {:error, {:missing_option, :since}} = Fake.get_staking_rewards()
      assert {:error, :missing_provider_id} = Fake.stake("ETH", Decimal.new("1"))
      assert {:error, :nothing_to_rename} = Fake.rename_account("id", nil, [])
    end

    test "transfer_internal/4 refuses an amount or asset the real call refuses" do
      accounts = [from: "primary", to: "other"]
      opts = [credentials: @credentials]

      for bad <- [0, -1, "abc", Decimal.new("NaN"), nil] do
        assert {:error, {:invalid_amount, ^bad}} =
                 Fake.transfer_internal("BTC", bad, accounts, opts)
      end

      assert {:error, {:invalid_asset, nil}} = Fake.transfer_internal(nil, 1, accounts, opts)

      assert {:ok, %{"amount" => "0.00000001"}} =
               Fake.transfer_internal("BTC", Decimal.new("0.00000001"), accounts, opts)
    end

    test "stake/3 and unstake/3 refuse an amount or asset the real call refuses" do
      opts = [provider_id: "p", credentials: @credentials]

      for write <- [&Fake.stake/3, &Fake.unstake/3] do
        zero = Decimal.new(0)
        assert {:error, {:invalid_amount, ^zero}} = write.("ETH", zero, opts)

        assert {:error, {:invalid_asset, nil}} = write.(nil, Decimal.new(1), opts)
        assert {:ok, _transaction} = write.("eth", Decimal.new(1), opts)
      end
    end

    test "convert/4 settles in one step and holds no rate" do
      assert {:ok, conversion} =
               Fake.convert("GUSD", "USD", Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :sell,
                 credentials: @credentials
               )

      assert conversion.status == :settled
      # No window, so `expired?/2` reports unknown rather than a boolean to act on.
      assert Types.Conversion.expired?(conversion, DateTime.utc_now()) == nil
    end

    test "every conversion call refuses without credentials" do
      assert {:error, {:missing_credentials, :gemini}} =
               Fake.convert("GUSD", "USD", Decimal.new("1"), symbol: "GUSD-USD", side: :sell)

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.commit_conversion("1234", Keyword.delete(@terms, :credentials))
    end
  end

  describe "the account's own traded volume" do
    test "rows come back under the venue's own field names" do
      assert {:ok, [row]} = Fake.get_trade_volume(@credentials, [])
      assert row["symbol"] == "btcusd"
    end

    test "it refuses without credentials" do
      assert {:error, {:missing_credentials, :gemini}} = Fake.get_trade_volume(%{}, [])
    end
  end

  describe "the tape" do
    test "broken trades are excluded by default" do
      assert {:ok, [only]} = Fake.get_trades("BTC-USD")
      refute only.broken
      assert only.side == :buy
    end

    test "asking for them includes the bust" do
      assert {:ok, both} = Fake.get_trades("BTC-USD", include_broken: true)
      assert length(both) == 2
      assert Enum.any?(both, & &1.broken)
    end

    test "since_tid keeps only trades after that id, and wins over since" do
      assert {:ok, [trade]} = Fake.get_trades("BTC-USD", since_tid: 5_335_307_667)
      assert trade.id == "5335307668"

      assert {:ok, []} = Fake.get_trades("BTC-USD", since_tid: 5_335_307_668)

      # `since` far in the past would keep both; the id decides.
      long_ago = ~U[2000-01-01 00:00:00Z]
      assert {:ok, []} = Fake.get_trades("BTC-USD", since_tid: 5_335_307_668, since: long_ago)

      assert {:ok, [_trade, _bust]} =
               Fake.get_trades("BTC-USD", since_tid: 0, include_broken: true)
    end

    test "since keeps only trades strictly after it, as a DateTime or a raw epoch" do
      assert {:ok, [_trade]} = Fake.get_trades("BTC-USD", since: ~U[2026-08-28 11:59:59Z])
      assert {:ok, []} = Fake.get_trades("BTC-USD", since: ~U[2026-08-28 12:00:00Z])
      assert {:ok, []} = Fake.get_trades("BTC-USD", since: ~U[2026-08-28 12:00:01Z])

      seconds = DateTime.to_unix(~U[2026-08-28 12:00:00Z])
      assert {:ok, [_trade]} = Fake.get_trades("BTC-USD", since: seconds - 1)
      assert {:ok, []} = Fake.get_trades("BTC-USD", since: seconds)
      assert {:ok, [_trade]} = Fake.get_trades("BTC-USD", since: seconds * 1_000 - 1)
      assert {:ok, []} = Fake.get_trades("BTC-USD", since: seconds * 1_000)
      assert {:ok, []} = Fake.get_trades("BTC-USD", since: 10 ** 30)
    end

    test "limit keeps the most recent N, after the busted print is dropped" do
      assert {:ok, [only]} = Fake.get_trades("BTC-USD", limit: 1)
      refute only.broken

      assert {:ok, [bust]} = Fake.get_trades("BTC-USD", limit: 1, include_broken: true)
      assert bust.broken

      assert {:ok, both} = Fake.get_trades("BTC-USD", limit: 50, include_broken: true)
      assert length(both) == 2
    end

    test "an option the real call cannot send is refused by the real check, before the symbol" do
      for {key, value} <- [
            limit: 0,
            limit: 501,
            limit: "10",
            since_tid: -1,
            since_tid: "1",
            since: "now"
          ] do
        opts = [{key, value}]
        expected = {:error, {:invalid_option, key, value}}

        assert Fake.get_trades("BTC-USD", opts) == expected
        assert Fake.get_trades("NOPE-USD", opts) == expected
        assert DpExchange.Gemini.Rest.get_trades("BTC-USD", opts) == expected
      end
    end

    test "a cursor read that fills its limit is history_truncated, as the real call (MD4)" do
      assert {:error, :history_truncated} = Fake.get_trades("BTC-USD", since_tid: 0, limit: 1)
      assert {:ok, [_only]} = Fake.get_trades("BTC-USD", since_tid: 0, limit: 2)
      assert {:ok, [_only]} = Fake.get_trades("BTC-USD", limit: 1)
    end

    test "an unlisted symbol is refused, not answered with someone else's tape" do
      # This used to answer unconditionally for ANY symbol, which is MORE capable than
      # `Rest.get_trades/2` — found in the 2026-09-06 real/fake parity sweep.
      assert Fake.get_trades("NOPE-USD") == {:refused, :not_listed}
    end

    test "the tape is not the caller's own fills" do
      # get_trade_history/2 needs credentials (a symbol is optional); the tape needs neither.
      assert {:ok, [_trade]} = Fake.get_trades("BTC-USD")

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.get_trade_history(%{}, symbol: "BTC-USD")
    end
  end

  describe "the fake's money-movement surface" do
    test "a deposit address says nothing about whether a memo is needed" do
      assert {:ok, address} =
               Fake.get_deposit_address("BTC", "bitcoin", credentials: @credentials)

      assert address.memo_required == nil
      assert address.network == "bitcoin"
    end

    test "the approved list carries a pending address, so a consumer must handle one" do
      # A consumer that only ever sees active addresses never handles the pending case, and
      # a withdrawal to a pending address is refused.
      assert {:ok, addresses} =
               Fake.list_approved_addresses(network: "ethereum", credentials: @credentials)

      assert Enum.any?(addresses, &(&1.status == :pending))
      assert Enum.any?(addresses, &(&1.status == :active))

      pending = Enum.find(addresses, &(&1.status == :pending))
      assert Types.ApprovedAddress.usable?(pending, DateTime.utc_now()) == nil
    end

    test "the network is required for the approved list" do
      assert {:error, {:missing_option, :network}} =
               Fake.list_approved_addresses(credentials: @credentials)
    end

    test "a withdrawal is PENDING, never completed" do
      # A fake that reported completion would teach a consumer the money has arrived.
      assert {:ok, withdrawal} =
               Fake.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc",
                 credentials: @credentials
               )

      assert withdrawal.status == :pending
      refute withdrawal.status == :completed
    end

    test "the caller's idempotency key is echoed" do
      assert {:ok, withdrawal} =
               Fake.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc",
                 client_transfer_id: "mine",
                 credentials: @credentials
               )

      assert withdrawal.id == "mine"
    end

    test "a required memo that is missing is refused, as in production" do
      assert {:error, :memo_required} =
               Fake.withdraw("USDC", "solana", Decimal.new("100"), "7Ec",
                 memo_required: true,
                 credentials: @credentials
               )
    end

    test "the fee estimate needs a destination" do
      assert {:error, {:missing_option, :address}} =
               Fake.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("1"),
                 credentials: @credentials
               )

      assert {:ok, estimate} =
               Fake.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("1"),
                 address: "0xabc",
                 credentials: @credentials
               )

      assert estimate.address == "0xabc"
    end

    test "every money call refuses without credentials" do
      assert {:error, {:missing_credentials, :gemini}} =
               Fake.get_deposit_address("BTC", "bitcoin")

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.list_approved_addresses(network: "eth")

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc")
    end
  end

  describe "the fake's payment and transfer surface" do
    test "a payment method list carries both kinds the venue's reply splits into" do
      # `PaymentMethodsResponse` (`rest.yaml:5454`) has no per-row status at all — `banks`
      # (`PaymentMethodBank`) has none, so the "pending" narrative this used to check
      # described a field the real reply never carries.
      assert {:ok, methods} = Fake.list_payment_methods(@credentials)
      assert Enum.any?(methods, &(&1["kind"] == "balance"))
      assert Enum.any?(methods, &(&1["kind"] == "bank"))
    end

    test "a newly added method is pending, never verified" do
      # A fake returning a usable method would teach a consumer the first transfer works.
      assert {:ok, method} =
               Fake.add_payment_method(%{"accountNumber" => "1"},
                 credentials: @credentials
               )

      assert method["status"] == "pending"
    end

    test "a country with no endpoint is refused" do
      assert {:error, {:unsupported_country, "GB"}} =
               Fake.add_payment_method(%{"iban" => "GB"},
                 country: "GB",
                 credentials: @credentials
               )
    end

    test "an internal transfer needs both ends and carries no address" do
      assert {:error, {:missing_option, :from}} =
               Fake.transfer_internal("BTC", Decimal.new("1"), [to: "b"],
                 credentials: @credentials
               )

      assert {:ok, transfer} =
               Fake.transfer_internal("BTC", Decimal.new("1"), [from: "a", to: "b"],
                 credentials: @credentials
               )

      assert transfer["fromAccount"] == "a"
      assert transfer["toAccount"] == "b"
      refute Map.has_key?(transfer, "address")
      refute Map.has_key?(transfer, "asset")
    end

    test "an allowlist request without a label is refused, as the real adapter refuses it" do
      assert {:error, {:missing_required_field, :label}} =
               Fake.request_approved_address("ethereum", "0xabc", nil, credentials: @credentials)
    end

    test "a requested allowlist entry is pending, not active" do
      # A fake returning "active" would teach a consumer a successful response is permission
      # to withdraw.
      assert {:ok, requested} =
               Fake.request_approved_address("ethereum", "0xabc", "desk",
                 credentials: @credentials
               )

      assert requested["status"] == "pending-time"
      refute requested["status"] == "active"
    end

    test "removal answers removed" do
      assert {:ok, %{"status" => "removed"}} =
               Fake.remove_approved_address("ethereum", "0xabc", credentials: @credentials)
    end

    test "transactions include kinds that are neither trades nor transfers" do
      assert {:ok, rows} = Fake.get_transactions(@credentials)
      kinds = Enum.map(rows, & &1["type"])

      assert "Fee" in kinds
      assert "Trade" in kinds
    end

    test "every one refuses without credentials" do
      assert {:error, {:missing_credentials, :gemini}} = Fake.list_payment_methods(%{})
      assert {:error, {:missing_credentials, :gemini}} = Fake.get_transactions(%{})
      assert {:error, {:missing_credentials, :gemini}} = Fake.add_payment_method(%{})

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.request_approved_address("ethereum", "0xabc", "desk")
    end
  end

  describe "the fake's reporting surface" do
    test "a notional balance carries a quantity and a valuation that differ" do
      # A fake that made them equal would let a consumer read either as the other and pass.
      assert {:ok, [row]} = Fake.get_notional_balances(@credentials, "usd")
      assert row["amount"] != row["amountNotional"]
      assert row["notionalCurrency"] == "USD"
    end

    test "a custody fee has no trade behind it" do
      assert {:ok, [fee]} = Fake.list_custody_fees(@credentials)
      assert fee["currency"]
      refute Map.has_key?(fee, "order_id")
    end

    test "there is no per-method read, and the fake says so rather than filtering" do
      assert {:error, :not_supported} = Fake.get_payment_method(@credentials, "bank-1")
    end

    test "both reporting reads still need credentials" do
      assert {:error, {:missing_credentials, :gemini}} = Fake.get_notional_balances(%{}, "usd")
      assert {:error, {:missing_credentials, :gemini}} = Fake.list_custody_fees(%{})
    end
  end

  describe "the fake's staking surface" do
    test "two providers pay different rates for the same asset" do
      # One rate would hide the reason provider_id is required on the writes.
      assert {:ok, rates} = Fake.get_staking_rates()
      assert length(rates) == 2
      assert Enum.map(rates, & &1.provider_id) |> Enum.uniq() |> length() == 2
    end

    test "one provider publishes no APY, and it is not derived from its rate" do
      assert {:ok, rates} = Fake.get_staking_rates()
      assert Enum.any?(rates, &is_nil(&1.apy_pct))
    end

    test "the staked position is redeemable in full and tradable not at all" do
      assert {:ok, [balance]} = Fake.get_staking_balances(credentials: @credentials)
      assert Decimal.equal?(balance.available_to_trade, Decimal.new("0"))
      assert Decimal.equal?(balance.available_for_withdrawal, Decimal.new("10"))
    end

    test "the history carries a redemption mid-unbond" do
      assert {:ok, [tx]} = Fake.get_staking_history(credentials: @credentials)
      refute Decimal.equal?(tx.amount_remaining, Decimal.new("0"))
    end

    test "a reward carries the window it accrued over" do
      assert {:ok, [reward]} =
               Fake.get_staking_rewards(
                 credentials: @credentials,
                 since: ~U[2026-08-01 00:00:00Z]
               )

      assert reward.period_start
      assert reward.period_end
      assert reward.accrual_count == 7
    end

    test "get_staking_rewards refuses a missing since, the way the venue requires it" do
      assert {:error, {:missing_option, :since}} =
               Fake.get_staking_rewards(credentials: @credentials)
    end

    test "the writes refuse without a provider" do
      assert {:error, :missing_provider_id} =
               Fake.stake("ETH", Decimal.new("1"), credentials: @credentials)

      assert {:error, :missing_provider_id} =
               Fake.unstake("ETH", Decimal.new("1"), credentials: @credentials)
    end

    test "an unstake reports nothing arrived yet" do
      assert {:ok, tx} =
               Fake.unstake("ETH", Decimal.new("10"),
                 credentials: @credentials,
                 provider_id: "provider-a"
               )

      assert Decimal.equal?(tx.amount_paid_so_far, Decimal.new("0"))
      assert Decimal.equal?(tx.amount_remaining, Decimal.new("10"))
    end

    test "a stake records the provider it went to" do
      assert {:ok, tx} =
               Fake.stake("eth", Decimal.new("1"),
                 credentials: @credentials,
                 provider_id: "provider-b"
               )

      assert tx.asset == "ETH"
      assert tx.provider_id == "provider-b"
      assert tx.type == :stake
    end

    test "the account-scoped staking reads still need credentials" do
      assert {:error, {:missing_credentials, :gemini}} = Fake.get_staking_balances()

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.get_staking_rewards(since: ~U[2026-08-01 00:00:00Z])

      assert {:error, {:missing_credentials, :gemini}} = Fake.get_staking_history()

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.stake("ETH", Decimal.new("1"), provider_id: "provider-a")

      assert {:error, {:missing_credentials, :gemini}} =
               Fake.unstake("ETH", Decimal.new("1"), provider_id: "provider-a")
    end
  end

  describe "every spelling of a symbol the real package resolves is resolved here" do
    # `Rest` and `Private` send `to_exchange_symbol/1` and report `to_canonical_symbol/1`, so
    # `btcusd`, `BTCUSD` and `BTC-USD` are one request. The fake looked the caller's spelling
    # up verbatim and refused the other two as unlisted, with a refusal the venue never sent.
    test "REST reads answer under the canonical symbol" do
      for spelling <- ["btcusd", "BTCUSD", "btc-usd", "BTC-USD"] do
        assert {:ok, %Quote{symbol: "BTC-USD"}} = Fake.get_price(spelling)
        assert {:ok, %{symbol: "BTC-USD"}} = Fake.get_top_of_book(spelling)
        assert {:ok, %OrderBook{symbol: "BTC-USD"}} = Fake.get_order_book(spelling)
        assert {:ok, [%{symbol: "BTC-USD"}]} = Fake.get_historical_prices(spelling, "1d")
        assert {:ok, [_trade | _rest]} = Fake.get_trades(spelling)
        assert {:ok, %{status: "open"}} = Fake.quantization(spelling)
      end
    end

    test "a placed order is for the canonical symbol" do
      request = %{
        symbol: "solrlusd",
        side: :buy,
        quantity: "1",
        price: "100",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, %Types.Order{symbol: "SOL-RLUSD"}} =
               Fake.place_order(@credentials, request, [])
    end

    test "list_instruments/1 reads symbols: as the real function does" do
      assert {:ok, [%{symbol: "BTC-USD"}]} =
               Fake.list_instruments(symbols: ["BTC-USD", "btcusd"])

      assert {:error, {:invalid_option, :symbols, "BTC-USD"}} =
               Fake.list_instruments(symbols: "BTC-USD")
    end

    test "a subscription by any spelling is delivered and covered under the canonical one" do
      assert :ok = Fake.subscribe(["BTCUSD", "btc-usd", "SOLRLUSD"], to: self())
      assert_receive {:dp_exchange, :gemini, %{symbol: "BTC-USD"}}
      assert_receive {:dp_exchange, :gemini, %{symbol: "SOL-RLUSD"}}
      assert Fake.coverage() == %{"BTC-USD" => :stream, "SOL-RLUSD" => :stream}

      assert :ok = Fake.unsubscribe(["btcusd"])
      assert Fake.coverage() == %{"SOL-RLUSD" => :stream}
    end

    test "symbols that are not a list of strings are refused, as the real feed refuses them" do
      assert {:error, {:invalid_symbols, "BTC-USD"}} = Fake.subscribe("BTC-USD", to: self())
      assert {:error, {:invalid_symbols, [:btc_usd]}} = Fake.update_symbols([:btc_usd])
      assert {:error, {:invalid_symbols, [nil]}} = Fake.unsubscribe([nil])
      assert Fake.coverage() == %{}
    end

    test "a subscriber that is neither a pid nor a name is refused, as the real feed refuses it" do
      assert {:error, {:invalid_subscriber, "consumer"}} =
               Fake.subscribe(["BTC-USD"], to: "consumer")

      assert {:error, {:invalid_subscriber, true}} = Fake.subscribe_notices(to: true)
      assert Fake.coverage() == %{}
    end
  end

  describe "the asset direction of list_networks/2 is signed, as the real one is" do
    test "it refuses without a credential" do
      assert {:error, {:missing_credentials, :gemini}} = Fake.list_networks("USDC", [])
    end

    test "and answers with one" do
      assert {:ok, [%{"asset" => "USDC"}]} =
               Fake.list_networks("USDC", credentials: @credentials)
    end
  end

  describe "a placed order is described the way the venue describes it back" do
    @order %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

    test "the type is recovered from the execution option, not echoed from the request" do
      # A duration is named on a plain limit order and on nothing else.
      for {order_type, time_in_force, expected} <- [
            {:post_only, nil, :post_only},
            {:limit, :ioc, :ioc},
            {:ioc, nil, :ioc},
            {:limit, :fok, :fok},
            {:fok, nil, :fok},
            {:stop_limit, nil, :stop_limit},
            {:limit, :gtc, :limit}
          ] do
        request = Map.put(@order, :order_type, order_type)

        request =
          if time_in_force, do: Map.put(request, :time_in_force, time_in_force), else: request

        # The trigger price belongs to a stop-limit and to nothing else.
        request =
          if order_type == :stop_limit, do: Map.put(request, :stop_price, "99"), else: request

        assert {:ok, %Types.Order{order_type: ^expected}} =
                 Fake.place_order(@credentials, request, [])
      end
    end

    test "a stop price travels back on the order" do
      request = Map.merge(@order, %{order_type: :stop_limit, stop_price: "99"})

      assert {:ok, %Types.Order{stop_price: stop_price}} =
               Fake.place_order(@credentials, request, [])

      assert Decimal.equal?(stop_price, Decimal.new("99"))
    end
  end

  describe "a candle request is refused as Rest refuses it, in Rest's order" do
    test "the width and the range are checked before the symbol" do
      assert {:error, {:unsupported_timeframe, "2h"}} =
               Fake.get_historical_prices("NOPE-USD", "2h")

      assert {:error, {:invalid_range, [start: "yesterday"]}} =
               Fake.get_historical_prices("NOPE-USD", "1d", start: "yesterday")
    end

    test "the window's edge is the real one, a bar in from now minus the whole window" do
      # The real window ends at the START of the current bar and reaches back `bars - 1`
      # widths; `now - bars * width` sat a whole bar further out, so a start in that gap was
      # served here and refused there.
      #
      # `now` is read here and again inside the fake, so a run straddling 00:00 UTC would
      # compute two different edges. Within ten seconds of midnight, wait it out first.
      to_midnight = 86_400 - rem(DateTime.to_unix(DateTime.utc_now()), 86_400)
      if to_midnight <= 10, do: Process.sleep((to_midnight + 1) * 1_000)

      now = DateTime.to_unix(DateTime.utc_now())
      edge = DateTime.from_unix!(div(now, 86_400) * 86_400 - 363 * 86_400)
      inside = DateTime.add(edge, 1, :second)
      outside = DateTime.add(edge, -1, :second)

      assert {:ok, [_candle]} = Fake.get_historical_prices("BTC-USD", "1d", start: inside)

      assert {:error, {:range_unavailable, "1d", earliest: ^edge, requested: ^outside}} =
               Fake.get_historical_prices("BTC-USD", "1d", start: outside)
    end
  end

  describe "a master key that names the account by id has named it" do
    test "rename_account/3 is not refused MissingAccounts" do
      master = Map.put(@credentials, :key_scope, :master)

      assert {:ok, %{"name" => "Desk", "account" => "bot-one"}} =
               Fake.rename_account("bot-one", "Desk", credentials: master)
    end

    test "a shortname change reports the new shortname, a name change the new name" do
      assert {:ok, %{"account" => "bot-two"} = changed} =
               Fake.rename_account("bot-one", nil,
                 shortname: "bot-two",
                 credentials: @credentials
               )

      refute Map.has_key?(changed, "name")
    end
  end

  describe "a lower-case subscription" do
    # The real facade upper-cases symbols on the way in. The fake has to give the same
    # answer, or a consumer's tier-1 tests certify silence where the venue delivers.
    test "is delivered under the canonical symbol, as the real package does" do
      assert :ok = DpExchange.Gemini.Fake.subscribe(["btc-usd"], to: self())
      assert_receive {:dp_exchange, _venue, %{symbol: "BTC-USD"}}, 5_000
      assert Map.has_key?(DpExchange.Gemini.Fake.coverage(), "BTC-USD")
    end
  end

  describe "a master-scoped key must name the account (dp-exchange-core issue #38)" do
    @master Map.put(@credentials, :key_scope, :master)

    test "an account-level call without :account is refused as the venue refuses it" do
      assert {:refused, {:unknown_reason, "MissingAccounts"}} = Fake.get_balances(@master)
      assert {:ok, _balances} = Fake.get_balances(@master, account: "primary")
    end

    test "group-level calls need no account" do
      assert {:ok, _roles} = Fake.get_roles(credentials: @master)
    end

    test "an account-scoped key is unaffected" do
      assert {:ok, _balances} = Fake.get_balances(@credentials)
    end
  end

  describe "order round trip (core conformance assertion 31)" do
    test "the id place_order/3 mints reads back through get_order/3 and cancel_order/3" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: "1",
        price: "100",
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, %Types.Order{id: id}} = Fake.place_order(@credentials, request)
      assert {:ok, %Types.Order{id: ^id}} = Fake.get_order(@credentials, id)

      assert {:ok, %Types.Order{id: ^id, status: :cancelled}} =
               Fake.cancel_order(@credentials, id)
    end

    test "place_orders, replace_order and close_position are declared unsupported and refuse" do
      endpoints = DpExchange.Gemini.capabilities().endpoints

      for key <- [{:place_orders, 3}, {:replace_order, 4}, {:close_position, 3}] do
        assert Map.fetch!(endpoints, key) == :unsupported
      end

      assert Fake.place_orders(@credentials, [], []) == {:error, :not_supported}
      assert Fake.replace_order(@credentials, "1", %{}, []) == {:error, :not_supported}
      assert Fake.close_position(@credentials, "BTC-USD", []) == {:error, :not_supported}
    end
  end
end
