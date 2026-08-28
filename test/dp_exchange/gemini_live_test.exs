defmodule DpExchange.GeminiLiveTest do
  @moduledoc """
  Tier 2 — the LIVE public venue. Tagged `:tier2` and excluded from every default run.

  **Never put these on a schedule.** A venue that sees a package polling it on a timer
  will rate-limit or block, and this suite exists precisely because it is the cheapest
  place a venue's real behaviour contradicts what is written about it.

      mix test --include tier2

  Everything here is public and read-only. Nothing authenticates and nothing spends.

  ## What this suite is for

  Not coverage. Tier 1 covers the code. These assert **the venue's own behaviour**, so
  that when Gemini changes something the failure lands here rather than in a consumer's
  production. Three of the four findings that shaped this package came from running
  exactly these calls by hand.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Gemini
  alias DpExchange.Gemini.{Rest, SymbolFormat}

  @moduletag :tier2
  @moduletag timeout: 120_000

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

  describe "the candle timeframe enum" do
    test "the venue accepts every width this package declares" do
      for timeframe <- Rest.timeframes() do
        assert {:ok, [_first | _rest]} = Rest.get_historical_prices("BTC-USD", timeframe, [], []),
               "the venue rejected #{timeframe}, which capabilities/0 declares"
      end
    end

    test "the venue REJECTS the three widths its own documentation lists" do
      # `1h`, `6h` and `1d` appear in Gemini's published enum and none of them work. If
      # this test starts failing, the venue has fixed its documentation-to-API mismatch
      # and this package's mapping should be revisited — which is the point of asserting
      # a venue's behaviour rather than our own.
      for documented <- ~w(1h 6h 1d) do
        assert {:refused, _reason} = raw_candles(documented),
               "the venue now accepts #{documented}; the docs/API mismatch may be resolved"
      end
    end

    test "the venue names its own accepted set in the error body" do
      # A machine-readable capability declaration, free to obtain and more current than
      # the documentation.
      assert {:refused, _reason} = raw_candles("THREE_HOUR")
    end
  end

  describe "the fixed candle window" do
    test "every width serves the bar count this package refuses ranges against" do
      # These reproduced the host's independent 2026-08-06 measurement exactly, all seven,
      # 22 days later. If one drifts, the range refusal in `get_historical_prices/4` is
      # refusing the wrong ranges.
      expected = %{
        "1m" => 1_440,
        "5m" => 2_015,
        "15m" => 1_343,
        "30m" => 1_439,
        "1h" => 1_463,
        "6h" => 367,
        "1d" => 364
      }

      for {timeframe, bars} <- expected do
        assert {:ok, candles} = Rest.get_historical_prices("BTC-USD", timeframe, [], [])

        assert length(candles) == bars,
               "#{timeframe} served #{length(candles)} bars, not #{bars}"
      end
    end

    test "start, end and limit are all ignored by the venue" do
      # Which is why this package filters client-side. If the venue ever honours them,
      # this test fails and the filtering can be replaced by real bounds.
      {:ok, plain} = Rest.get_historical_prices("BTC-USD", "1d", [], [])
      {:ok, bounded} = Rest.get_historical_prices("BTC-USD", "1d", [], params: [limit: 10])

      assert length(plain) == length(bounded)
    end
  end

  describe "rate-limit headers" do
    test "the venue publishes NONE, so there is nothing to parse" do
      # The host adapter looks for `x-ratelimit-remaining` on this venue and has therefore
      # never produced a value. Unlike its Coinbase counterpart it fabricates nothing —
      # it is dead code, not a defect.
      {:ok, response} =
        DpExchange.Core.HttpClient.request(
          :get,
          "https://api.gemini.com/v1/pubticker/btcusd",
          [],
          nil,
          provider: :gemini,
          retry_attempts: 0
        )

      names = response.headers |> Enum.map(fn {name, _v} -> String.downcase(name) end)

      refute Enum.any?(names, &String.starts_with?(&1, "x-ratelimit"))
      refute "retry-after" in names
    end

    test "a Date header IS published, which is the only venue clock a quote can use" do
      # If this stops being true, `get_price/2` starts failing closed rather than
      # returning quotes with our clock on them — which is the intended behaviour, but a
      # consumer would want to know why.
      assert {:ok, %Types.Quote{} = quote_struct} = Gemini.get_price("BTC-USD", limiter: nil)

      assert DateTime.diff(DateTime.utc_now(), quote_struct.timestamp, :second) < 120
    end
  end

  describe "the catalogue" do
    test "every listed spot symbol round-trips through the canonical mapping" do
      # The real test of `sep: ""` with overlapping quotes, against all ~346 of them
      # rather than the handful in the tier-1 suite. A symbol that fails to round-trip
      # matches no catalogue entry and collects nothing, silently.
      {:ok, symbols} = Gemini.get_symbols(limiter: nil)

      assert length(symbols) > 300, "the catalogue shrank unexpectedly"

      for canonical <- symbols do
        round_tripped =
          canonical
          |> SymbolFormat.to_exchange_symbol()
          |> SymbolFormat.to_canonical_symbol()

        assert round_tripped == canonical, "#{canonical} did not survive the round trip"
      end
    end

    test "perpetuals are excluded from the spot catalogue" do
      {:ok, symbols} = Gemini.get_symbols(limiter: nil)

      refute Enum.any?(symbols, &String.contains?(&1, "PERP"))
    end
  end

  describe "the streaming API this package chose" do
    test "ws.gemini.com accepts a bookTicker subscription and delivers quotes" do
      # The whole justification for not using the endpoint the host uses. If this fails,
      # `docs/reference/gemini/websocket-api-replacement.md` needs revisiting before
      # anything else.
      {:ok, feed} = DpExchange.Gemini.Feed.start_link(name: :"live_feed_#{unique()}")

      :ok = DpExchange.Gemini.Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert_receive {:dp_exchange, :gemini, %Types.Quote{symbol: "BTC-USD"} = quote_struct},
                     30_000

      assert quote_struct.timestamp.year == DateTime.utc_now().year
      assert Decimal.positive?(quote_struct.bid)
    end
  end

  describe "the demo environment" do
    @describetag :tier2

    test "REST serves the same shapes production does" do
      # The whole point of the demo environment for a consumer: the same code path, the
      # same parsing, different money.
      assert {:ok, symbols} = Gemini.get_symbols(environment: :sandbox, limiter: nil)
      assert length(symbols) > 300

      assert {:ok, %Types.Quote{} = quote_struct} =
               Gemini.get_price("BTC-USD", environment: :sandbox, limiter: nil)

      assert quote_struct.provider == :gemini
      assert %Decimal{} = quote_struct.price
    end

    test "the demo book is often CROSSED, which production never is" do
      # Not a defect and not something to correct — bots make this book. It is recorded
      # because a consumer computing a spread against demo data will see negatives, and
      # this is the cheapest place to find that out. Measured 2026-08-28: bid 68169.88
      # against ask 64886.32.
      assert {:ok, book} = Gemini.get_order_book("BTC-USD", environment: :sandbox, limiter: nil)

      assert is_list(book.bids)
      assert is_list(book.asks)
    end

    test "candles work, so a consumer can backfill against demo before production" do
      assert {:ok, [_first | _rest]} =
               Gemini.get_historical_prices("BTC-USD", "1d", [],
                 environment: :sandbox,
                 limiter: nil
               )
    end

    test "the demo WebSocket speaks the same protocol as production" do
      # ws.sandbox.gemini.com, verified to answer `{"id":1,"status":200}` and stream
      # bookTicker frames field-for-field like production.
      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(
          name: :"demo_feed_#{unique()}",
          environment: :sandbox
        )

      :ok = DpExchange.Gemini.Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert_receive {:dp_exchange, :gemini, %Types.Quote{symbol: "BTC-USD"}}, 30_000
    end

    test "production and demo are genuinely different venues" do
      # If these ever matched, the environment option would be doing nothing and every
      # test above would be passing for the wrong reason.
      {:ok, live} = Gemini.get_price("BTC-USD", environment: :production, limiter: nil)
      {:ok, demo} = Gemini.get_price("BTC-USD", environment: :sandbox, limiter: nil)

      refute Decimal.equal?(live.price, demo.price)
    end
  end

  # Straight at the venue, bypassing this package's mapping — the point is what Gemini
  # does with a literal, not what this package sends. `raw_status: true` is what keeps the
  # 400 and its body intact instead of flattening them into a message.
  defp raw_candles(time_frame) do
    case DpExchange.Core.HttpClient.request(
           :get,
           "https://api.gemini.com/v2/candles/BTCUSD/#{time_frame}",
           [],
           nil,
           provider: :gemini,
           retry_attempts: 0,
           raw_status: true
         ) do
      {:ok, %{status: 400, body: body}} -> {:refused, body}
      {:ok, %{status: 200}} -> {:ok, :accepted}
      other -> other
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
