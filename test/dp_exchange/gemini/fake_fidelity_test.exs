defmodule DpExchange.Gemini.FakeFidelityTest do
  @moduledoc """
  `Fake` refuses what the real call refuses, in the same order and with the same value.

  Every assertion compares `Fake` against the real function's OWN return for a call that is
  refused before a request is made, so there is no literal here to drift: a change to the real
  refusal breaks the comparison instead of leaving the fake green for the wrong reason.

  The real calls below never reach the network. Each is refused by a check that runs before
  anything is signed.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.{Fake, Private, Rest}

  @moduletag :capture_log

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  @bad_amounts [
    "abc",
    0,
    "-1",
    "0",
    nil,
    Decimal.new("NaN"),
    %Decimal{sign: 1, coef: 1, exp: 999_999_999}
  ]

  describe "quote_conversion/4 and convert/4 check the amount" do
    test "the same refusal as the real call, after the direction and before the credential" do
      for amount <- @bad_amounts do
        opts = [credentials: @credentials]

        assert {:error, _reason} = real = Private.quote_conversion("USD", "BTC", amount, opts)
        assert Fake.quote_conversion("USD", "BTC", amount, opts) == real

        convert_opts = [symbol: "GUSD-USD", side: :sell, credentials: @credentials]
        assert {:error, _reason} = real = Private.convert("GUSD", "USD", amount, convert_opts)
        assert Fake.convert("GUSD", "USD", amount, convert_opts) == real

        # No credential at all: still the amount's refusal, as nothing is signed for it.
        assert Fake.quote_conversion("USD", "BTC", amount, []) ==
                 Private.quote_conversion("USD", "BTC", amount, [])
      end
    end

    test "a string amount reads in the fake and a float is refused, as the real call refuses" do
      opts = [symbol: "BTC-USD", side: :buy, credentials: @credentials]

      assert {:ok, %{to_amount: %Decimal{}}} = Fake.quote_conversion("USD", "BTC", "100", opts)

      assert {:error, {:invalid_amount, 100.5}} =
               Fake.quote_conversion("USD", "BTC", 100.5, opts)

      assert Fake.quote_conversion("USD", "BTC", 100.5, opts) ==
               Private.quote_conversion("USD", "BTC", 100.5, opts)
    end
  end

  describe "withdraw/5 and estimate_withdrawal_fee/4 check what the real call checks" do
    test "withdraw: asset, network, destination and amount" do
      cases = [
        {nil, "ethereum", Decimal.new(1), "0xabc"},
        {"ETH", "", Decimal.new(1), "0xabc"},
        {"ETH", nil, Decimal.new(1), "0xabc"},
        {"ETH", "ethereum", Decimal.new(1), "  "},
        {"ETH", "ethereum", Decimal.new(1), nil},
        {"ETH", "ethereum", "abc", "0xabc"},
        {"ETH", "ethereum", 0, "0xabc"},
        {"ETH", "ethereum", Decimal.new("NaN"), "0xabc"}
      ]

      for {asset, network, amount, address} <- cases do
        assert {:error, _reason} =
                 real = Private.withdraw(asset, network, amount, address, @credentials, [])

        assert Fake.withdraw(asset, network, amount, address, credentials: @credentials) == real
        # And before the credential.
        assert Fake.withdraw(asset, network, amount, address) == real
      end
    end

    test "estimate_withdrawal_fee: destination, asset, network and amount" do
      cases = [
        {"ETH", "ethereum", Decimal.new(1), [address: 5]},
        {nil, "ethereum", Decimal.new(1), [address: "0xabc"]},
        {"ETH", " ", Decimal.new(1), [address: "0xabc"]},
        {"ETH", "ethereum", "abc", [address: "0xabc"]},
        {"ETH", "ethereum", -1, [address: "0xabc"]}
      ]

      for {asset, network, amount, opts} <- cases do
        real = Private.estimate_withdrawal_fee(asset, network, amount, @credentials, opts)
        assert {:error, _reason} = real

        assert Fake.estimate_withdrawal_fee(
                 asset,
                 network,
                 amount,
                 [credentials: @credentials] ++ opts
               ) == real
      end
    end

    test "an unblemished call still succeeds" do
      assert {:ok, %{address: "0xabc"}} =
               Fake.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new(1),
                 address: "0xabc",
                 credentials: @credentials
               )
    end
  end

  describe "get_deposit_address/3 and request_approved_address/4" do
    test "a blank or missing network is refused before the credential, as the real call does" do
      for network <- ["", "  ", nil, :bitcoin] do
        assert {:error, _reason} = real = Private.get_deposit_address("BTC", network, %{}, [])
        assert Fake.get_deposit_address("BTC", network) == real
        assert Fake.get_deposit_address("BTC", network, credentials: @credentials) == real
      end
    end

    test "a missing label is refused before the credential" do
      for label <- [nil, ""] do
        assert {:error, {:missing_required_field, :label}} =
                 Private.request_approved_address("ethereum", "0xabc", label, %{}, [])

        assert {:error, {:missing_required_field, :label}} =
                 Fake.request_approved_address("ethereum", "0xabc", label)
      end
    end
  end

  describe "perpetuals" do
    test "funding and risk statistics are for a perpetual, not a spot symbol" do
      assert {:ok, %DpExchange.Core.Types.Funding{symbol: "BTCGUSDPERP"}} =
               Fake.get_funding("BTCGUSDPERP")

      assert {:ok, %DpExchange.Core.Types.ContractStats{symbol: "BTCGUSDPERP"}} =
               Fake.get_contract_stats("BTCGUSDPERP")

      assert {:refused, :not_listed} = Fake.get_funding("BTC-USD")
      assert {:refused, :not_listed} = Fake.get_contract_stats("BTC-USD")
    end

    test "a perpetual's candles are 1m only, refused before the range, as the real call does" do
      for {timeframe, range} <- [{"5m", []}, {"1d", []}, {"4h", []}, {"5m", [start: "nope"]}] do
        assert {:error, _reason} =
                 real = Rest.get_historical_prices("BTCGUSDPERP", timeframe, range, [])

        assert Fake.get_historical_prices("BTCGUSDPERP", timeframe, range) == real
      end
    end
  end
end
