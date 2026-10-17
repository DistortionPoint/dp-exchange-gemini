defmodule DpExchange.Gemini.TickAaRestTest do
  @moduledoc """
  Tick AA: the `DpExchange.Gemini.Rest` branches a full `mix test --cover` run never
  executed, each driven through the public function a consumer calls, with the HTTP layer
  replaced by a `plug:`. Every assertion is what the branch's own comment, the function's
  `@doc` or the family conventions say it must answer.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  # 2026-08-24 00:00:00Z: on a boundary of every width up to a day.
  @day_ms 1_787_270_400_000
  @day ~U[2026-08-21 00:00:00Z]

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp reporting(test_pid, body) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  describe "quantization/2 — the stated status" do
    test "a null status is no status, not an unreadable reply" do
      body = %{"tick_size" => "0.00000001", "quote_increment" => "0.01", "status" => nil}

      assert {:ok, %{status: nil}} = Rest.quantization("BTC-USD", opts(responding(body)))
    end

    test "an absent status is no status" do
      body = %{"tick_size" => "0.00000001", "quote_increment" => "0.01"}

      assert {:ok, %{status: nil}} = Rest.quantization("BTC-USD", opts(responding(body)))
    end
  end

  describe "list_instruments/1" do
    test "post_only trades, with restrictions: :tradable" do
      body = %{
        "symbol" => "btcusd",
        "base_currency" => "BTC",
        "quote_currency" => "USD",
        "product_type" => "spot",
        "status" => "post_only"
      }

      assert {:ok, [instrument]} =
               Rest.list_instruments([symbols: ["BTC-USD"]] ++ opts(responding(body)))

      assert instrument.status == :tradable
    end
  end

  describe "get_trades/2" do
    @trade %{
      "timestampms" => @day_ms,
      "tid" => 4_242,
      "price" => "100.5",
      "amount" => "0.1",
      "type" => "buy"
    }

    test "an integer :since goes on the wire as given" do
      plug = reporting(self(), [@trade])

      assert {:ok, [_trade]} = Rest.get_trades("BTC-USD", [since: 1_787_270_400] ++ opts(plug))

      assert_receive {:request, "/v1/trades/btcusd", query}, 5_000
      assert query =~ "timestamp=1787270400"
    end

    test "a string tid is the id as the venue wrote it" do
      row = Map.put(@trade, "tid", "tid-abc-1")

      assert {:ok, [trade]} = Rest.get_trades("BTC-USD", opts(responding([row])))
      assert trade.id == "tid-abc-1"
    end

    test "a row with no amount refuses the reply rather than carrying a nil quantity" do
      row = Map.delete(@trade, "amount")

      assert Rest.get_trades("BTC-USD", opts(responding([row]))) ==
               {:error, {:missing_required_field, :quantity}}
    end
  end

  describe "list_fee_promos/1" do
    test "an object with no \"symbols\" key is one bare row" do
      row = %{"symbol" => "BTCUSD"}

      assert Rest.list_fee_promos(opts(responding(row))) == {:ok, [row]}
    end

    test "a body that is neither an object nor a list is unreadable, not \"no promotions\"" do
      for body <- [nil, "no promotions", 7] do
        result = Rest.list_fee_promos(opts(responding(body)))
        assert result == {:error, :unexpected_response_shape}
      end
    end
  end

  describe "get_staking_rates/1 — rate_pct is never derived from what is not there" do
    test "neither rate field at all leaves rate_pct nil" do
      body = %{"provider-uuid-1" => %{"SOL" => %{"apyPct" => "4.1", "rate" => nil}}}

      assert {:ok, [sol]} = Rest.get_staking_rates(opts(responding(body)))

      assert sol.rate_pct == nil
      assert Decimal.equal?(sol.apy_pct, Decimal.new("4.1"))
    end

    test "a figure that is present but unreadable refuses the whole reply" do
      for {key, bad} <- [
            {"rate", "not-a-number"},
            {"ratePct", "NaN"},
            {"ratePct", true},
            {"apyPct", "3.5%"},
            {"apyPct", %{}},
            {"depositUsdLimit", "Infinity"},
            {"depositUsdLimit", []}
          ] do
        body = %{
          "provider-uuid-1" => %{
            "ETH" => %{key => bad},
            "SOL" => %{"ratePct" => "4.1"}
          }
        }

        assert Rest.get_staking_rates(opts(responding(body))) ==
                 {:error, :unexpected_response_shape}
      end
    end
  end

  describe "funding timestamps" do
    test "an out-of-range millisecond time refuses the reply, and a string one is read whole" do
      body = %{
        "symbol" => "btcgusdperp",
        "fundingTimestampMilliSecs" => 100_000_000_000_000_000_000,
        "nextFundingTimestamp" => Integer.to_string(@day_ms)
      }

      assert Rest.get_funding("BTCGUSDPERP", opts(responding(body))) ==
               {:error, :unexpected_response_shape}

      stated = %{body | "fundingTimestampMilliSecs" => nil}

      assert {:ok, funding} = Rest.get_funding("BTCGUSDPERP", opts(responding(stated)))
      assert funding.funded_at == nil
      assert DateTime.compare(funding.next_funding_at, @day) == :eq
    end

    test "next_funding_timestamp/2 reads a string body, and refuses one that is not a number" do
      stated = opts(responding(Integer.to_string(@day_ms)))

      assert {:ok, at} = Rest.next_funding_timestamp("BTCGUSDPERP", stated)
      assert DateTime.compare(at, @day) == :eq

      assert Rest.next_funding_timestamp("BTCGUSDPERP", opts(responding("soon"))) ==
               {:error, :unexpected_response_shape}
    end
  end

  describe "a status that is neither success nor a stated refusal" do
    test "a 403 is an exchange error carrying the status, not a refusal" do
      plug = responding(%{"reason" => "Forbidden"}, 403)

      assert {:error, {:exchange_error, :gemini, "HTTP 403: " <> _quoted}} =
               Rest.get_funding("BTCGUSDPERP", opts(plug))
    end
  end

  describe "get_historical_prices/4 — the candle's time" do
    test "a string millisecond time is read whole" do
      row = [Integer.to_string(@day_ms), "1.5", "2.5", "1.0", "2.0", "3.0"]

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1d", [], opts(responding([row])))

      assert DateTime.compare(candle.opened_at, @day) == :eq
    end

    test "a time at or before the epoch is refused, not dated 1970" do
      for time <- [0, -60_000, "0"] do
        row = [time, "1.5", "2.5", "1.0", "2.0", "3.0"]

        assert {:error, {:unparseable_venue_timestamp, _time}} =
                 Rest.get_historical_prices("BTC-USD", "1d", [], opts(responding([row])))
      end
    end

    test "a missing time is refused, not dated" do
      row = [nil, "1.5", "2.5", "1.0", "2.0", "3.0"]

      assert Rest.get_historical_prices("BTC-USD", "1d", [], opts(responding([row]))) ==
               {:error, {:unparseable_venue_timestamp, nil}}
    end

    test "an integer time outside DateTime's range is refused, not raised" do
      huge = 100_000_000_000_000_000_000
      row = [huge, "1.5", "2.5", "1.0", "2.0", "3.0"]

      assert Rest.get_historical_prices("BTC-USD", "1d", [], opts(responding([row]))) ==
               {:error, {:unparseable_venue_timestamp, huge}}
    end
  end

  describe "refusal_reason/1" do
    test "a body with no readable reason is a bare :refused" do
      assert Rest.refusal_reason(nil) == :refused
      assert Rest.refusal_reason(%{"reason" => 42}) == :refused
    end

    test "an over-long body that is not UTF-8 is still cut to the bound" do
      # The cut drops at most three bytes looking for a codepoint boundary. Text that is not
      # UTF-8 anywhere has none to find, and is returned cut at the bound regardless.
      body = "x" <> :binary.copy(<<0xFF>>, 3_000) <> "x"

      assert Rest.refusal_reason(body) ==
               {:unknown_reason, "x" <> :binary.copy(<<0xFF>>, 2_044) <> "... [truncated]"}
    end
  end

  describe "a path parameter that is only dots" do
    test "`.` and `..` are percent-encoded, never sent as dot-segments" do
      for {symbol, encoded} <- [{".", "%2E"}, {"..", "%2E%2E"}] do
        assert {:ok, _funding} = Rest.get_funding(symbol, opts(reporting(self(), %{})))

        assert_receive {:request, path, _query}, 5_000
        assert path == "/v1/fundingamount/" <> encoded
      end
    end
  end
end
