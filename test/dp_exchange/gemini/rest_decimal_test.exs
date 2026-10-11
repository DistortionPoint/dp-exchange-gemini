defmodule DpExchange.Gemini.RestDecimalTest do
  @moduledoc """
  Public REST bodies are decoded with `floats: :decimals`, as `Private` has been since 0.2.108.

  Gemini types money as a JSON number on public routes too: `tick_size` and `quote_increment`
  on `/v1/symbols/details`, `fundingAmount` on `/v1/fundingamount`, `ratePct` on
  `/v1/staking/rates` and every price in a `/v2/candles` row (`docs/reference/gemini/openapi/
  rest.yaml`). Req's own decoder turns each into a float, which holds 17 significant digits.

  Every test sends RAW BYTES through `Plug.Conn.send_resp/3` with a JSON content type. The
  digit assertions depend on `dp_exchange_core` passing `:decode_body` through to Req (0.3.65).
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

  defp raw(bytes, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, bytes)
    end
  end

  defp assert_exact(%Decimal{} = actual, expected) do
    assert Decimal.equal?(actual, Decimal.new(expected)),
           "expected #{expected}, got #{Decimal.to_string(actual)}"
  end

  test "quantization/2 keeps every digit of a numeric increment" do
    # As a float `0.000000012345678901234567` is `1.2345678901234568e-8`.
    body =
      ~s({"symbol": "BTCUSD", "tick_size": 0.000000012345678901234567, ) <>
        ~s("quote_increment": 0.01, "min_order_size": "0.00001", "status": "open"})

    assert {:ok, quantization} = Rest.quantization("BTC-USD", plug: raw(body), retry_attempts: 0)

    assert_exact(quantization.quantity_increment, "0.000000012345678901234567")
    assert_exact(quantization.price_increment, "0.01")
    assert_exact(quantization.min_quantity, "0.00001")
  end

  test "get_funding/2 keeps every digit of a numeric funding amount" do
    body =
      ~s({"symbol": "BTCGUSDPERP", "fundingTimestampMilliSecs": 1745344800000, ) <>
        ~s("nextFundingTimestamp": 1745348400000, "fundingAmount": -1.509910000000000001, ) <>
        ~s("estimatedFundingAmount": -2.105950000000000001})

    assert {:ok, funding} = Rest.get_funding("BTCGUSDPERP", plug: raw(body), retry_attempts: 0)

    assert_exact(funding.amount, "-1.509910000000000001")
    assert_exact(funding.estimated_amount, "-2.105950000000000001")
    assert funding.funded_at == ~U[2025-04-22 18:00:00.000Z]
  end

  test "a numeric ratePct is read, not dropped" do
    # The `is_number/1` guard on `rate_pct/1` did not admit the `Decimal` a fractional JSON
    # number now is, so every row publishing `ratePct` as a number (the live shape) came
    # back with `rate_pct: nil` once bodies were decoded exactly.
    body = ~s({"p-1": {"ETH": {"ratePct": 4.123456789012345678, "rate": 412.5}}})

    assert {:ok, [%Types.StakingRate{} = rate]} =
             Rest.get_staking_rates(plug: raw(body), retry_attempts: 0)

    assert_exact(rate.rate_pct, "4.123456789012345678")
  end

  test "a numeric basis-point rate is converted exactly" do
    body = ~s({"p-1": {"ETH": {"rate": 412.3456789012345678}}})

    assert {:ok, [rate]} = Rest.get_staking_rates(plug: raw(body), retry_attempts: 0)

    assert_exact(rate.rate_pct, "4.123456789012345678")
  end

  test "a candle keeps every digit of a numeric price" do
    body =
      ~s([[1787935740000, 77986.740000000000000001, 77995.93, 77908.94, 77941.47, ) <>
        ~s(0.123456789012345678]])

    assert {:ok, [candle]} =
             Rest.get_historical_prices("BTC-USD", "1m", [], plug: raw(body), retry_attempts: 0)

    assert_exact(candle.open, "77986.740000000000000001")
    assert_exact(candle.volume, "0.123456789012345678")
  end

  test "a fractional candle time is truncated to whole milliseconds, not refused" do
    body = ~s([[1787935740000.5, 1, 2, 0.5, 1.5, 3]])

    assert {:ok, [candle]} =
             Rest.get_historical_prices("BTC-USD", "1m", [], plug: raw(body), retry_attempts: 0)

    assert candle.opened_at == DateTime.from_unix!(1_787_935_740_000, :millisecond)
  end

  test "an absurd candle time is refused instead of building a huge integer" do
    body = ~s([[1E40, 1, 2, 0.5, 1.5, 3]])

    assert {:error, {:unparseable_venue_timestamp, _value}} =
             Rest.get_historical_prices("BTC-USD", "1m", [], plug: raw(body), retry_attempts: 0)
  end

  test "a plain-text refusal still keeps the venue's words" do
    # With `decode_body: false` every 4xx body reaches `refusal/1` as bytes.
    text = "Supplied value 'X' is not a valid symbol"

    assert {:refused, {:unknown_reason, ^text}} =
             Rest.get_historical_prices("BTC-USD", "1m", [],
               plug: raw(text, 400),
               retry_attempts: 0
             )
  end

  test "a JSON refusal body is still classified" do
    body = ~s({"result": "error", "reason": "InvalidSymbol", "message": "no such symbol"})

    assert {:refused, {:invalid_symbol, "no such symbol"}} =
             Rest.get_price("BTC-USD", plug: raw(body, 400), retry_attempts: 0)
  end

  test "bytes that are not JSON on a 200 are an error, not an empty success" do
    assert {:error, {:undecodable_response, :gemini}} =
             Rest.get_price("BTC-USD", plug: raw("<html>"), retry_attempts: 0)
  end
end
