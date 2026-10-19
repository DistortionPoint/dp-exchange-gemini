defmodule DpExchange.Gemini.StakingReviewTest do
  @moduledoc """
  Staking, notional-balance and OAuth-revoke reads: a field the venue SENT and this package
  cannot read fails the row (absent stays `nil`), the epoch readers refuse 1970 and absurd
  exponents, and the writes that have already moved funds keep answering.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}

  defp json(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> Req.Test.json(body)
    end
  end

  defp raw(bytes) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, bytes)
    end
  end

  @opts [retry_attempts: 0]

  describe "get_staking_balances/2" do
    test "an unreadable present field fails the page; an absent one stays nil" do
      good = %{"currency" => "ETH", "balance" => "10"}

      for {field, bad} <- [
            {"available", "abc"},
            {"availableForWithdrawal", "NaN"},
            {"balanceByProvider", "oops"},
            {"balanceByProvider", %{"p" => %{"balance" => "x"}}},
            {"balanceByProvider", %{"p" => %{}}},
            {"balanceByProvider", %{"p" => 5}}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_staking_balances(
                   @credentials,
                   [plug: json([Map.put(good, field, bad)])] ++ @opts
                 ),
               "#{field}: #{inspect(bad)}"
      end

      assert {:ok, [balance]} =
               Private.get_staking_balances(@credentials, [plug: json([good])] ++ @opts)

      assert balance.available_to_trade == nil
      assert balance.by_provider == %{}
    end
  end

  describe "get_staking_history/2" do
    defp history(txn) do
      base = %{
        "transactionId" => "t1",
        "transactionType" => "Redeem",
        "amountCurrency" => "ETH",
        "amount" => "10"
      }

      [%{"providerId" => "p", "transactions" => [Map.merge(base, txn)]}]
    end

    test "unreadable times fail the page; progress fields are not history fields, so ignored" do
      assert {:ok, [tx]} =
               Private.get_staking_history(
                 @credentials,
                 [plug: json(history(%{"amountRemaining" => "soon"}))] ++ @opts
               )

      assert tx.amount_remaining == nil

      for txn <- [
            %{"dateTime" => "yesterday"},
            %{"dateTime" => 0},
            %{"dateTime" => -5}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_staking_history(@credentials, [plug: json(history(txn))] ++ @opts),
               inspect(txn)
      end
    end

    test "a dateTime with an absurd exponent is refused without building the integer" do
      bytes =
        ~s([{"providerId":"p","transactions":[{"transactionId":"t1","amountCurrency":"ETH",) <>
          ~s("amount":"1","dateTime":1E+999999999}]}])

      # Refused either way. Under decimal 3 the decoder will not build that number, so the reply
      # is refused before any row is read; under decimal 2 (down to the 2.0.0 floor) it builds,
      # and the exponent bound refuses the time without building the integer.
      assert {:error, reason} =
               Private.get_staking_history(@credentials, [plug: raw(bytes)] ++ @opts)

      assert reason in [{:undecodable_response, :gemini}, :unexpected_response_shape]
    end

    test "absent progress and time stay nil" do
      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials, [plug: json(history(%{}))] ++ @opts)

      assert tx.amount_remaining == nil
      assert tx.venue_time == nil
    end
  end

  describe "get_staking_rewards/2" do
    defp rewards(period) do
      %{"p" => %{"ETH" => %{"ratePeriods" => [Map.put(period, "accrualTotal", "0.1")]}}}
    end

    test "an unreadable rate, count or bound fails the reply" do
      for period <- [
            %{"apyPct" => "x"},
            %{"numberOfAccruals" => "7"},
            %{"numberOfAccruals" => -1},
            %{"firstAccrualAt" => "soon"},
            %{"lastAccrualAt" => 0}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_staking_rewards(
                   @credentials,
                   [since: ~U[2026-08-25 00:00:00Z], plug: json(rewards(period))] ++ @opts
                 ),
               inspect(period)
      end
    end
  end

  describe "stake/4 and unstake/4 report what the venue accepted" do
    test "a present but unreadable optional field is write_unconfirmed, not a nil" do
      body = %{
        "transactionId" => "9",
        "currency" => "ETH",
        "amount" => "1",
        "amountRemaining" => "bad",
        "requestInitiated" => "bad"
      }

      for broken <- [body, Map.delete(body, "amountRemaining")] do
        assert {:error, {:write_unconfirmed, "9", :unexpected_response_shape}} =
                 Private.unstake(
                   "ETH",
                   Decimal.new(1),
                   @credentials,
                   [provider_id: "p", plug: json(broken)] ++ @opts
                 )
      end

      absent = Map.drop(body, ["amountRemaining", "requestInitiated"])

      assert {:ok, tx} =
               Private.unstake(
                 "ETH",
                 Decimal.new(1),
                 @credentials,
                 [provider_id: "p", plug: json(absent)] ++ @opts
               )

      assert tx.id == "9"
      assert tx.amount_remaining == nil
      assert tx.venue_time == nil
    end
  end

  describe "get_notional_balances/3" do
    test "a blank or non-string currency is refused, and the fake refuses it the same way" do
      for currency <- ["", "  ", nil, :usd] do
        assert {:error, {:invalid_currency, _value}} =
                 real = Private.get_notional_balances(@credentials, currency, @opts)

        assert Fake.get_notional_balances(@credentials, currency, []) == real
        assert Fake.get_notional_balances(%{}, currency, []) == real
      end
    end
  end

  describe "revoke_access_token/2" do
    test "a blank token is refused rather than signed" do
      assert {:error, :oauth_token_required} =
               Private.revoke_access_token(%{access_token: ""}, @opts)
    end
  end
end
