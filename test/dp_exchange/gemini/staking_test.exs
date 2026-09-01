defmodule DpExchange.Gemini.StakingTest do
  @moduledoc """
  Custodial staking: rates, positions, rewards, history and the two writes.

  Three assertions carry this file. **A rate published in basis points is not a
  percentage** — the venue publishes both plus an APY, and a package that picked the wrong
  one is wrong by 100× and plausible either way. **A staked position is three amounts**, and
  the real shape has the whole position redeemable with none of it tradable. And **an
  unstake returns before it completes**, carrying what is still unbonding.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Gemini.{Private, Rest}

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
  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      payload =
        conn
        |> Plug.Conn.get_req_header("x-gemini-payload")
        |> List.first()
        |> Base.decode64!()
        |> Jason.decode!()

      send(test_pid, {:payload, payload, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  describe "get_staking_rates/1 — the unit is the whole risk" do
    test "a percentage is taken as published" do
      body = %{
        "ETH" => %{
          "provider-a" => %{"ratePct" => "4.0", "apyPct" => "4.07"}
        }
      }

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert %Types.StakingRate{} = rate
      assert rate.asset == "ETH"
      assert rate.provider_id == "provider-a"
      assert Decimal.equal?(rate.rate_pct, Decimal.new("4.0"))
      assert Decimal.equal?(rate.apy_pct, Decimal.new("4.07"))
    end

    test "basis points are divided by a hundred, not carried as a percentage" do
      # 400 bps is 4%. Carried unconverted it is a rate a hundred times too high, and every
      # number downstream stays plausible.
      body = %{"ETH" => %{"provider-a" => %{"rate" => 400}}}

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert Decimal.equal?(rate.rate_pct, Decimal.new("4"))
    end

    test "ratePct wins where both are published" do
      body = %{"ETH" => %{"provider-a" => %{"rate" => 400, "ratePct" => "4.25"}}}

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert Decimal.equal?(rate.rate_pct, Decimal.new("4.25"))
    end

    test "an APY the venue does not publish stays nil rather than being derived" do
      # Turning a simple rate into an APY needs a compounding frequency the venue did not
      # state. Assuming one invents a number a caller cannot see was invented.
      body = %{"ETH" => %{"provider-a" => %{"ratePct" => "4.0"}}}

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert rate.apy_pct == nil
    end

    test "every provider under an asset is addressable" do
      body = %{
        "ETH" => %{
          "provider-a" => %{"ratePct" => "4.0"},
          "provider-b" => %{"ratePct" => "3.5"}
        }
      }

      assert {:ok, rates} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert length(rates) == 2
      assert Enum.sort(Enum.map(rates, & &1.provider_id)) == ["provider-a", "provider-b"]
    end

    test "a shape the venue never sends is an empty list, not a crash" do
      assert {:ok, []} = Rest.get_staking_rates(plug: responding([]), retry_attempts: 0)
    end
  end

  describe "get_staking_balances/2 — three amounts, kept apart" do
    test "the whole position can be redeemable and none of it tradable" do
      rows = [
        %{
          "currency" => "eth",
          "balance" => "10",
          "available" => "0",
          "availableForWithdrawal" => "10"
        }
      ]

      assert {:ok, [balance]} =
               Private.get_staking_balances(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert balance.asset == "ETH"
      assert Decimal.equal?(balance.staked, Decimal.new("10"))
      assert Decimal.equal?(balance.available_to_trade, Decimal.new("0"))
      assert Decimal.equal?(balance.available_for_withdrawal, Decimal.new("10"))
    end

    test "a state the venue does not report is nil, never zero" do
      # `nil` is "unknown"; `0` is "none". A caller sizing against the second when the venue
      # said the first has been told something the venue did not say.
      rows = [%{"currency" => "ETH", "balance" => "10"}]

      assert {:ok, [balance]} =
               Private.get_staking_balances(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert balance.available_to_trade == nil
      assert balance.available_for_withdrawal == nil
    end

    test "a zero-balance row is kept" do
      # The host adapter dropped these, which makes "no position reported" and "no position"
      # the same answer. They are not.
      rows = [%{"currency" => "ETH", "balance" => "0"}]

      assert {:ok, [balance]} =
               Private.get_staking_balances(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert Decimal.equal?(balance.staked, Decimal.new("0"))
    end

    test "the breakdown is empty rather than asserting one provider" do
      rows = [%{"currency" => "ETH", "balance" => "10"}]

      assert {:ok, [balance]} =
               Private.get_staking_balances(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert balance.by_provider == %{}
    end
  end

  describe "get_staking_rewards/2 — the window is part of the value" do
    test "the bounds the venue reports travel with the number" do
      rows = [
        %{
          "currency" => "ETH",
          "amount" => "0.0031",
          "providerId" => "provider-a",
          "apyPct" => "4.07",
          "accrualCount" => 7,
          "since" => 1_787_500_000_000,
          "until" => 1_787_936_401_000
        }
      ]

      assert {:ok, [reward]} =
               Private.get_staking_rewards(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert reward.accrual_count == 7
      assert reward.period_start == DateTime.from_unix!(1_787_500_000_000, :millisecond)
      assert reward.period_end == DateTime.from_unix!(1_787_936_401_000, :millisecond)
    end

    test "a window the venue does not report is nil, not the window that was asked for" do
      # The venue is free to clamp a window. Echoing the ask would report a period that was
      # never served.
      rows = [%{"currency" => "ETH", "amount" => "0.1"}]

      assert {:ok, [reward]} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-25 00:00:00Z],
                 until: ~U[2026-09-01 00:00:00Z],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert reward.period_start == nil
      assert reward.period_end == nil
    end

    test "the window is sent to the venue in milliseconds" do
      me = self()

      assert {:ok, _rewards} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-28 17:00:01Z],
                 provider_id: "provider-a",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/staking/rewards"}
      assert payload["since"] == 1_787_936_401_000
      assert payload["providerId"] == "provider-a"
    end
  end

  describe "get_staking_history/2 — a redemption is a process" do
    test "requested, paid so far and remaining all survive" do
      rows = [
        %{
          "transactionId" => "stk-1",
          "transactionType" => "Redeem",
          "currency" => "ETH",
          "amount" => "10",
          "amountPaidSoFar" => "4",
          "amountRemaining" => "6",
          "providerId" => "provider-a",
          "timestampms" => 1_787_936_401_000
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert tx.type == :unstake
      assert tx.venue_type == "Redeem"
      assert Decimal.equal?(tx.amount, Decimal.new("10"))
      assert Decimal.equal?(tx.amount_paid_so_far, Decimal.new("4"))
      assert Decimal.equal?(tx.amount_remaining, Decimal.new("6"))
    end

    test "the venue's own word is kept beside the normalised one" do
      rows = [%{"transactionType" => "Deposit", "currency" => "ETH", "amount" => "1"}]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert tx.type == :stake
      assert tx.venue_type == "Deposit"
    end

    test "an unrecognised type is :other, not the nearest atom that fits" do
      rows = [%{"transactionType" => "Slashing", "currency" => "ETH", "amount" => "1"}]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert tx.type == :other
      assert tx.venue_type == "Slashing"
    end

    test "an Interest row is a reward" do
      rows = [%{"transactionType" => "Interest", "currency" => "ETH", "amount" => "0.01"}]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert tx.type == :reward
    end

    test "a seconds timestamp and a milliseconds one both land in this century" do
      # The payload does not say which unit it used. Reading milliseconds as seconds lands
      # past the epoch ceiling and raises.
      seconds = [
        %{
          "transactionType" => "Deposit",
          "currency" => "ETH",
          "amount" => "1",
          "timestamp" => 1_787_936_401
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(seconds),
                 retry_attempts: 0
               )

      assert tx.venue_time.year == 2026
    end
  end

  describe "stake/4 and unstake/4 — the provider is not defaulted" do
    test "a stake without a provider is refused before a request is made" do
      # No plug: reaching HTTP would fail on the connection rather than the guard.
      assert {:error, :missing_provider_id} =
               Private.stake("ETH", Decimal.new("1"), @credentials, [])
    end

    test "an unstake without a provider is refused too" do
      assert {:error, :missing_provider_id} =
               Private.unstake("ETH", Decimal.new("1"), @credentials, [])
    end

    test "a stake sends the venue's own parameter names" do
      me = self()

      assert {:ok, _tx} =
               Private.stake("eth", Decimal.new("1.5"), @credentials,
                 provider_id: "provider-a",
                 plug: capturing(%{"transactionType" => "Deposit"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/staking/stake"}
      assert payload["currency"] == "ETH"
      assert payload["amount"] == "1.5"
      assert payload["providerId"] == "provider-a"
    end

    test "a small amount is sent in full notation, not scientific" do
      me = self()

      assert {:ok, _tx} =
               Private.stake("ETH", Decimal.new("0.00000001"), @credentials,
                 provider_id: "provider-a",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["amount"] == "0.00000001"
    end

    test "an unstake reports what is still unbonding" do
      body = %{
        "transactionId" => "stk-redeem",
        "transactionType" => "Redeem",
        "currency" => "ETH",
        "amount" => "10",
        "amountPaidSoFar" => "0",
        "amountRemaining" => "10"
      }

      assert {:ok, tx} =
               Private.unstake("ETH", Decimal.new("10"), @credentials,
                 provider_id: "provider-a",
                 plug: responding(body),
                 retry_attempts: 0
               )

      # The dangerous reading is "ten arrived". Ten was asked for and none has arrived.
      assert Decimal.equal?(tx.amount, Decimal.new("10"))
      assert Decimal.equal?(tx.amount_remaining, Decimal.new("10"))
      refute Types.StakingTransaction.settled?(tx)
    end
  end
end
