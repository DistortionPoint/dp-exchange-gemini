defmodule DpExchange.Gemini.TradesTest do
  @moduledoc """
  The public tape.

  Two assertions carry the weight. **`type` is the taker's side** — the venue says `buy`
  means an ask was removed by an incoming buy order, which is the *opposite* of the resting
  order's side, and reading it the other way inverts every entry while every number stays
  real. And **broken trades are excluded**: a busted print did not stand, and its price in a
  series becomes a phantom high or low in every range and volatility figure built on it.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Gemini.Rest

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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> Req.Test.json(body)
    end
  end

  defp trade(overrides \\ %{}) do
    Map.merge(
      %{
        "timestamp" => 1_547_146_811,
        "timestampms" => 1_547_146_811_357,
        "tid" => 5_335_307_668,
        "price" => "3610.85",
        "amount" => "0.27413495",
        "exchange" => "gemini",
        "type" => "buy",
        "broken" => false
      },
      overrides
    )
  end

  describe "the tape" do
    test "a print comes back with the venue's numbers" do
      assert {:ok, [%Types.Trade{} = t]} =
               Rest.get_trades("BTC-USD", plug: responding([trade()]), retry_attempts: 0)

      assert t.id == "5335307668"
      assert t.symbol == "BTC-USD"
      assert Decimal.equal?(t.price, Decimal.new("3610.85"))
      assert Decimal.equal?(t.quantity, Decimal.new("0.27413495"))
      assert t.provider == :gemini
    end

    test "the side is the TAKER's, which is the venue's own meaning" do
      # "buy means that an ask was removed from the book by an incoming buy order." A
      # package reading it as the maker's side inverts every entry on the tape.
      assert {:ok, [buy]} =
               Rest.get_trades("BTC-USD", plug: responding([trade()]), retry_attempts: 0)

      assert buy.side == :buy

      assert {:ok, [sell]} =
               Rest.get_trades("BTC-USD",
                 plug: responding([trade(%{"type" => "sell"})]),
                 retry_attempts: 0
               )

      assert sell.side == :sell
    end

    test "a side the package does not know is nil, not the nearer of the two" do
      assert {:ok, [t]} =
               Rest.get_trades("BTC-USD",
                 plug: responding([trade(%{"type" => "auction"})]),
                 retry_attempts: 0
               )

      assert t.side == nil
    end

    test "millisecond precision is used where the venue sends it" do
      assert {:ok, [t]} =
               Rest.get_trades("BTC-USD", plug: responding([trade()]), retry_attempts: 0)

      assert t.timestamp == DateTime.from_unix!(1_547_146_811_357, :millisecond)
    end

    test "seconds are used when milliseconds are absent" do
      row = trade() |> Map.delete("timestampms")

      assert {:ok, [t]} =
               Rest.get_trades("BTC-USD", plug: responding([row]), retry_attempts: 0)

      assert t.timestamp == DateTime.from_unix!(1_547_146_811)
    end

    test "an undated print is refused, never stamped with the local clock" do
      row = trade() |> Map.delete("timestampms") |> Map.delete("timestamp")

      assert {:error, :missing_venue_timestamp} =
               Rest.get_trades("BTC-USD", plug: responding([row]), retry_attempts: 0)
    end

    test "an empty tape is an empty list, not an error" do
      assert {:ok, []} = Rest.get_trades("BTC-USD", plug: responding([]), retry_attempts: 0)
    end
  end

  describe "broken trades" do
    test "they are excluded by default" do
      body = [trade(), trade(%{"tid" => 999, "broken" => true})]

      assert {:ok, [only]} =
               Rest.get_trades("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert only.id == "5335307668"
      refute only.broken
    end

    test "asking for them includes them, rather than hiding a bust entirely" do
      # Hiding them would conceal that the exchange made a correction.
      body = [trade(), trade(%{"tid" => 999, "broken" => true})]

      assert {:ok, both} =
               Rest.get_trades("BTC-USD",
                 include_broken: true,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(both) == 2
      assert Enum.any?(both, & &1.broken)
    end

    test "the venue's own filter is asked for too, not just applied here" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json([])
      end

      assert {:ok, []} =
               Rest.get_trades("BTC-USD",
                 include_broken: true,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "include_breaks=true"
    end

    test "a print with no broken field is not broken" do
      # A venue that says nothing has not said a trade was busted.
      row = trade() |> Map.delete("broken")

      assert {:ok, [t]} =
               Rest.get_trades("BTC-USD", plug: responding([row]), retry_attempts: 0)

      refute t.broken
    end
  end

  describe "the window the venue offers" do
    test "since is sent as the venue's timestamp, in milliseconds" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json([])
      end

      assert {:ok, []} =
               Rest.get_trades("BTC-USD",
                 since: ~U[2026-08-28 17:00:01Z],
                 limit: 100,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "timestamp=1787936401000"
      assert query =~ "limit_trades=100"
    end

    test "since_tid is passed through, and the venue's precedence is left to the venue" do
      # The venue states since_tid trumps timestamp. This sends both when both are given
      # rather than dropping one, so the precedence stays the venue's.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json([])
      end

      assert {:ok, []} =
               Rest.get_trades("BTC-USD",
                 since: ~U[2026-08-28 17:00:01Z],
                 since_tid: 0,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "since_tid=0"
      assert query =~ "timestamp="
    end
  end

  describe "the FX rate is relayed, not traded" do
    @fx %{
      "fxPair" => "AUDUSD",
      "rate" => "0.69",
      "asOf" => 1_594_651_859_000,
      "provider" => "bcb",
      "benchmark" => "Spot"
    }

    test "the source is the institution and the provider is the venue" do
      # Collapsing them makes a Gemini-relayed BCB rate indistinguishable from one Gemini
      # computed itself, and only the second would be the venue's own claim.
      assert {:ok, %Types.FxRate{} = rate} =
               Rest.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z],
                 plug: responding(@fx),
                 retry_attempts: 0
               )

      assert rate.source == "bcb"
      assert rate.provider == :gemini
      assert rate.benchmark == "Spot"
      assert Decimal.equal?(rate.rate, Decimal.new("0.69"))
    end

    test "the venue's own asOf wins over the instant asked for" do
      # The venue may answer for a nearby moment, and its word is what happened.
      assert {:ok, rate} =
               Rest.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z],
                 plug: responding(@fx),
                 retry_attempts: 0
               )

      assert rate.as_of == DateTime.from_unix!(1_594_651_859_000, :millisecond)
    end

    test "no asOf falls back to the instant requested, which is still a time" do
      assert {:ok, rate} =
               Rest.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z],
                 plug: responding(Map.delete(@fx, "asOf")),
                 retry_attempts: 0
               )

      assert rate.as_of == ~U[2020-07-13 15:30:59Z]
    end

    test "the instant is sent as milliseconds in the path" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(@fx)
      end

      assert {:ok, _rate} =
               Rest.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z],
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path}
      # 2020-07-13T15:30:59Z in milliseconds. The venue's doc example uses a different
      # instant; this asserts the conversion, not the example.
      assert path == "/v2/fxrate/AUDUSD/1594654259000"
    end

    test "a hyphenated pair is normalised to the venue's form" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(@fx)
      end

      assert {:ok, _rate} =
               Rest.get_fx_rate("aud-usd", ~U[2020-07-13 15:30:59Z],
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path}
      assert path =~ "/AUDUSD/"
    end

    test "a pair the venue does not serve is refused BEFORE the request" do
      # The venue's 404 for an unsupported pair reads the same as one for a bad timestamp,
      # so a caller sent there cannot tell which it got wrong.
      exploding = fn _conn -> raise "must not ask for a pair the venue does not serve" end

      assert {:error, {:unsupported_fx_pair, "USDJPY"}} =
               Rest.get_fx_rate("USDJPY", ~U[2020-07-13 15:30:59Z],
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "all fourteen documented pairs are accepted" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(@fx)
      end

      for pair <- ~w(AUDUSD CADUSD COPUSD EURUSD CHFUSD HKDUSD NZDUSD GBPUSD BRLUSD INRUSD
                     SGDUSD KRWUSD JPYUSD CNYUSD) do
        assert {:ok, _rate} =
                 Rest.get_fx_rate(pair, ~U[2020-07-13 15:30:59Z],
                   plug: plug,
                   retry_attempts: 0
                 ),
               "#{pair} was refused"
      end
    end

    test "a body with no rate is unreadable, not a rate of nothing" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z],
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "convert applies the rate without rounding" do
      assert {:ok, rate} =
               Rest.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z],
                 plug: responding(@fx),
                 retry_attempts: 0
               )

      assert Decimal.equal?(Types.FxRate.convert(rate, Decimal.new("100")), Decimal.new("69.00"))
    end
  end

  describe "perpetuals have their own candles endpoint" do
    @bars [[1_787_935_740_000, 1.0, 2.0, 0.5, 1.5, 3.0]]

    test "a perpetual goes to the derivatives path" do
      # Sending one to the spot path does not error — the symbol is well-formed and the
      # endpoint answers — so a caller would get bars back with no way to tell they were
      # not the instrument asked about.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(@bars)
      end

      assert {:ok, [_candle]} =
               Rest.get_historical_prices("BTCGUSDPERP", "1m", [],
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path}
      assert path =~ "/v2/derivatives/candles/"
    end

    test "a spot pair still goes to the spot path" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(@bars)
      end

      assert {:ok, [_candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], plug: plug, retry_attempts: 0)

      assert_receive {:path, path}
      assert path =~ "/v2/candles/"
      refute path =~ "derivatives"
    end

    test "the derivatives endpoint serves 1m and NOTHING else" do
      # Falling back to the spot path would answer about a different instrument; falling
      # back to 1m would relabel someone else's bars.
      exploding = fn _conn -> raise "must not ask the derivatives endpoint for 5m" end

      assert {:error, {:unsupported_timeframe, "5m"}} =
               Rest.get_historical_prices("BTCGUSDPERP", "5m", [],
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a spot pair keeps the full width vocabulary" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(@bars)
      end

      assert {:ok, [_candle]} =
               Rest.get_historical_prices("BTC-USD", "5m", [], plug: plug, retry_attempts: 0)
    end
  end
end
