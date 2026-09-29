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
    test "the real venue shape: outer key is the provider, inner key is the asset" do
      # Captured live against `GET https://api.gemini.com/v1/staking/rates` on 2026-09-05:
      #
      #     {"62bb4d27-a9c8-4493-a737-d4fa33994f1f":
      #        {"ETH": {"providerId": "62bb4d27-a9c8-4493-a737-d4fa33994f1f", "rate": 22.95,
      #                 "apyPct": 0.23, "ratePct": 0.2295, "depositUsdLimit": 10000000}}}
      #
      # The code used to read this backwards — asset from the outer key, provider from the
      # inner one — so it would have asserted `rate.asset ==
      # "62BB4D27-A9C8-4493-A737-D4FA33994F1F"` here instead of "ETH", and
      # `rate.deposit_limit_usd == nil` because it read `depositLimitUsd`, a field the venue
      # does not send.
      body = %{
        "62bb4d27-a9c8-4493-a737-d4fa33994f1f" => %{
          "ETH" => %{
            "providerId" => "62bb4d27-a9c8-4493-a737-d4fa33994f1f",
            "rate" => 22.95,
            "apyPct" => 0.23,
            "ratePct" => 0.2295,
            "depositUsdLimit" => 10_000_000
          }
        }
      }

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert %Types.StakingRate{} = rate
      assert rate.asset == "ETH"
      assert rate.provider_id == "62bb4d27-a9c8-4493-a737-d4fa33994f1f"
      assert Decimal.equal?(rate.rate_pct, Decimal.new("0.2295"))
      assert Decimal.equal?(rate.apy_pct, Decimal.new("0.23"))
      assert Decimal.equal?(rate.deposit_limit_usd, Decimal.new("10000000"))
    end

    test "a percentage is taken as published" do
      body = %{
        "provider-a" => %{
          "ETH" => %{"ratePct" => "4.0", "apyPct" => "4.07"}
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
      body = %{"provider-a" => %{"ETH" => %{"rate" => 400}}}

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert Decimal.equal?(rate.rate_pct, Decimal.new("4"))
    end

    test "ratePct wins where both are published" do
      body = %{"provider-a" => %{"ETH" => %{"rate" => 400, "ratePct" => "4.25"}}}

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert Decimal.equal?(rate.rate_pct, Decimal.new("4.25"))
    end

    test "an APY the venue does not publish stays nil rather than being derived" do
      # Turning a simple rate into an APY needs a compounding frequency the venue did not
      # state. Assuming one invents a number a caller cannot see was invented.
      body = %{"provider-a" => %{"ETH" => %{"ratePct" => "4.0"}}}

      assert {:ok, [rate]} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert rate.apy_pct == nil
    end

    test "every asset under a provider is addressable" do
      body = %{
        "provider-a" => %{
          "ETH" => %{"ratePct" => "4.0"},
          "SOL" => %{"ratePct" => "3.5"}
        }
      }

      assert {:ok, rates} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert length(rates) == 2
      assert Enum.sort(Enum.map(rates, & &1.asset)) == ["ETH", "SOL"]
      assert Enum.all?(rates, &(&1.provider_id == "provider-a"))
    end

    test "a shape the venue never sends is refused, not a crash and not an empty list" do
      # `{:ok, []}` here said no provider stakes anything, from a reply that was not the
      # provider map at all. The same for a provider entry, or an asset row, that is not an
      # object: it used to be skipped, or built into a rate with every number `nil`.
      for body <- [[], %{"p-1" => "x"}, %{"p-1" => %{"ETH" => "x"}}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      end
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

    test "a balance row naming no asset or no staked amount is refused" do
      # `:asset` and `:staked` are both in `StakingBalance`'s `@enforce_keys`, so its `new/1`
      # refuses a `nil` in either — and nothing calls `new/1`, the struct being built
      # literally as everywhere in this family, so that check never ran.
      #
      # `asset` had the sharper version: `String.upcase(row["currency"] || "")` answered `""`
      # for an absent currency, which passes every `nil` check a consumer might write while
      # naming no asset at all. The identical line appeared in three functions here; only
      # `to_staking_transaction/1` was fixed the first time, and this is one of the two that
      # were left.
      for {field, expected} <- [
            {"currency", {:missing_required_field, :asset}},
            {"balance", {:missing_required_field, :staked}}
          ] do
        rows = [Map.delete(%{"currency" => "ETH", "balance" => "10"}, field)]

        assert {:error, ^expected} =
                 Private.get_staking_balances(@credentials,
                   plug: responding(rows),
                   retry_attempts: 0
                 ),
               "a balance row missing #{field} must be refused"
      end
    end

    test "a balance response that is not a row at all is an unreadable response" do
      # This used to hand-build `%StakingBalance{asset: "", staked: nil}` for any non-map
      # row — the exact placeholder the guards exist to prevent.
      assert {:error, :unexpected_response_shape} =
               Private.get_staking_balances(@credentials,
                 plug: responding(["not a row"]),
                 retry_attempts: 0
               )
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

    test "a real breakdown is read from balanceByProvider, not hardcoded away" do
      # This used to hardcode `by_provider: %{}` unconditionally, with a comment claiming
      # the venue never breaks the position down. It does: `rest.yaml:6565,6573` (schema
      # `:9429-9465`), `balanceByProvider` is `{<providerId uuid>: {balance: <number>}}`,
      # sent on every row in the venue's own example.
      rows = [
        %{
          "currency" => "ETH",
          "balance" => "10",
          "balanceByProvider" => %{
            "62b21e17-2534-4b9f-afcf-b7edb609dd8d" => %{"balance" => "7"},
            "provider-b" => %{"balance" => "3"}
          }
        }
      ]

      assert {:ok, [balance]} =
               Private.get_staking_balances(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert Decimal.equal?(
               balance.by_provider["62b21e17-2534-4b9f-afcf-b7edb609dd8d"],
               Decimal.new("7")
             )

      assert Decimal.equal?(balance.by_provider["provider-b"], Decimal.new("3"))
    end
  end

  describe "get_staking_rewards/2 — the window is part of the value" do
    # Every fixture in this describe block was corrected to the vendor's documented reply
    # shape (`rest.yaml`, 2026-09-29): `StakingRewardsResponse` is an object keyed by
    # provider UUID, then by currency, each holding `ratePeriods` — not the flat array of
    # rows these fixtures used to build. Matching the spec's own example provider id and
    # asset (`"62b21e17-2534-4b9f-afcf-b7edb609dd8d"`, `MATIC`) is not required for what
    # these tests prove, so the plainer stand-ins already used here ("provider-a", "ETH")
    # are kept, except where a test is specifically about a rate period's own fields, where
    # `MATIC` is used to mirror the documented example.
    defp rewards_body(provider_id, currency, periods) do
      %{provider_id => %{currency => %{"ratePeriods" => periods}}}
    end

    test "the bounds the venue reports travel with the number" do
      period = %{
        "apyPct" => "4.07",
        "numberOfAccruals" => 7,
        "accrualTotal" => "0.0031",
        "firstAccrualAt" => "2026-08-25T00:00:00.000Z",
        "lastAccrualAt" => "2026-09-01T00:00:00.000Z"
      }

      body = rewards_body("provider-a", "ETH", [period])

      assert {:ok, [reward]} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-25 00:00:00Z],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert reward.asset == "ETH"
      assert reward.provider_id == "provider-a"
      assert reward.accrual_count == 7
      assert reward.period_start == ~U[2026-08-25 00:00:00.000Z]
      assert reward.period_end == ~U[2026-09-01 00:00:00.000Z]
    end

    test "one currency with two rate periods is two rewards, each with its own apy" do
      periods = [
        %{"apyPct" => "5.75", "accrualTotal" => "0.0065678", "numberOfAccruals" => 1},
        %{"apyPct" => "5.20", "accrualTotal" => "0.0031", "numberOfAccruals" => 1}
      ]

      body = rewards_body("provider-a", "MATIC", periods)

      assert {:ok, [first, second]} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-25 00:00:00Z],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Enum.map([first, second], & &1.asset) == ["MATIC", "MATIC"]
      assert Decimal.equal?(first.apy_pct, Decimal.new("5.75"))
      assert Decimal.equal?(second.apy_pct, Decimal.new("5.20"))
    end

    test "a reward period naming no asset or no amount is refused" do
      # The third function that carried `String.upcase(row["currency"] || "")`. Same
      # reasoning as `get_staking_balances/2` and `get_staking_history/2`: `""` names no
      # asset while passing every `nil` check a consumer might write. The asset now comes
      # from the currency KEY, so "no asset" is an empty-string key rather than a missing
      # field; "no amount" is a period with no `accrualTotal`.
      for {body, expected} <- [
            {rewards_body("provider-a", "", [%{"accrualTotal" => "0.1"}]),
             {:missing_required_field, :asset}},
            {rewards_body("provider-a", "ETH", [%{}]), {:missing_required_field, :amount}}
          ] do
        assert {:error, ^expected} =
                 Private.get_staking_rewards(@credentials,
                   since: ~U[2026-08-25 00:00:00Z],
                   plug: responding(body),
                   retry_attempts: 0
                 ),
               "a reward period producing #{inspect(expected)} must be refused"
      end
    end

    test "a window the venue does not report is nil, not the window that was asked for" do
      # The venue is free to clamp a window. Echoing the ask would report a period that was
      # never served. A period with no `firstAccrualAt`/`lastAccrualAt` is exactly that.
      body = rewards_body("provider-a", "ETH", [%{"accrualTotal" => "0.1"}])

      assert {:ok, [reward]} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-25 00:00:00Z],
                 until: ~U[2026-09-01 00:00:00Z],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert reward.period_start == nil
      assert reward.period_end == nil
    end

    test "the window is sent to the venue as an ISO datetime, not epoch milliseconds" do
      # `rest.yaml:6896`; the request example at `:6910` gives
      # `"2022-08-20T00:00:00.000Z"`.
      me = self()

      assert {:ok, []} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-28 17:00:01Z],
                 provider_id: "provider-a",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/staking/rewards"}
      assert payload["since"] == "2026-08-28T17:00:01Z"
      assert payload["providerId"] == "provider-a"
    end

    test "since is required — rest.yaml:6885 lists it among the request's required fields" do
      exploding = fn _conn -> raise "must not ask for rewards over no window" end

      assert {:error, {:missing_option, :since}} =
               Private.get_staking_rewards(@credentials,
                 provider_id: "provider-a",
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "get_staking_history/2 — a redemption is a process" do
    # Every fixture in this describe block was corrected to the vendor's documented reply
    # shape (`rest.yaml:6770-6794`, schemas `:9499-9545`), 2026-09-29: an array of
    # `{providerId, transactions: [{transactionId, transactionType, amountCurrency,
    # amount, dateTime}]}` — not the flat array of transaction rows these fixtures used to
    # build, and `amountCurrency`/`dateTime`, not `currency`/`timestamp(ms)`.
    defp history_body(provider_id, transactions) do
      [%{"providerId" => provider_id, "transactions" => transactions}]
    end

    test "requested, paid so far and remaining all survive" do
      transactions = [
        %{
          "transactionId" => "stk-1",
          "transactionType" => "Redeem",
          "amountCurrency" => "ETH",
          "amount" => "10",
          "amountPaidSoFar" => "4",
          "amountRemaining" => "6",
          "dateTime" => 1_787_936_401_000
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(history_body("provider-a", transactions)),
                 retry_attempts: 0
               )

      assert tx.type == :unstake
      assert tx.venue_type == "Redeem"
      assert Decimal.equal?(tx.amount, Decimal.new("10"))
      assert Decimal.equal?(tx.amount_paid_so_far, Decimal.new("4"))
      assert Decimal.equal?(tx.amount_remaining, Decimal.new("6"))
    end

    test "the provider id comes from the parent group, not the transaction" do
      transactions = [
        %{
          "transactionId" => "stk-1",
          "transactionType" => "Redeem",
          "amountCurrency" => "ETH",
          "amount" => "10"
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug:
                   responding(history_body("62b21e17-2534-4b9f-afcf-b7edb609dd8d", transactions)),
                 retry_attempts: 0
               )

      assert tx.provider_id == "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
    end

    test "two providers each contribute their own transactions" do
      body = [
        %{
          "providerId" => "provider-a",
          "transactions" => [
            %{
              "transactionId" => "stk-a1",
              "transactionType" => "Deposit",
              "amountCurrency" => "ETH",
              "amount" => "1"
            }
          ]
        },
        %{
          "providerId" => "provider-b",
          "transactions" => [
            %{
              "transactionId" => "stk-b1",
              "transactionType" => "Deposit",
              "amountCurrency" => "MATIC",
              "amount" => "30"
            }
          ]
        }
      ]

      assert {:ok, [first, second]} =
               Private.get_staking_history(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert {first.provider_id, first.asset} == {"provider-a", "ETH"}
      assert {second.provider_id, second.asset} == {"provider-b", "MATIC"}
    end

    test "the venue's own word is kept beside the normalised one" do
      transactions = [
        %{
          "transactionId" => "stk-2",
          "transactionType" => "Deposit",
          "amountCurrency" => "ETH",
          "amount" => "1"
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(history_body("provider-a", transactions)),
                 retry_attempts: 0
               )

      assert tx.type == :stake
      assert tx.venue_type == "Deposit"
    end

    test "a transaction missing an identifying field is refused, not filled with placeholders" do
      # `StakingTransaction` names `:id`, `:type`, `:asset`, `:amount` and `:provider` in its
      # `@enforce_keys`, so its `new/1` refuses a `nil` in any of them. Nothing here calls
      # `new/1` — the struct is built literally, as everywhere in this family — so that check
      # never ran and none of these was guarded.
      complete = %{
        "transactionId" => "stk-9",
        "transactionType" => "Deposit",
        "amountCurrency" => "ETH",
        "amount" => "1"
      }

      for {field, expected} <- [
            {"transactionId", {:missing_required_field, :id}},
            {"amountCurrency", {:missing_required_field, :asset}},
            {"amount", {:missing_required_field, :amount}}
          ] do
        assert {:error, ^expected} =
                 Private.get_staking_history(@credentials,
                   plug: responding(history_body("provider-a", [Map.delete(complete, field)])),
                   retry_attempts: 0
                 ),
               "a transaction missing #{field} must be refused"
      end
    end

    test "a group naming no provider or no transaction list is refused" do
      for group <- [
            %{"transactions" => []},
            %{"providerId" => "provider-a"},
            %{"providerId" => "provider-a", "transactions" => "not a list"}
          ] do
        assert {:error, :unexpected_response_shape} =
                 Private.get_staking_history(@credentials,
                   plug: responding([group]),
                   retry_attempts: 0
                 ),
               "#{inspect(group)} must be refused"
      end
    end

    test "a staking response that is not a row at all is an unreadable response" do
      # This used to hand-build the exact struct the guards exist to prevent — `id: nil`,
      # `asset: ""`, `amount: nil` — for any row that was not a map. A staking transaction
      # naming no id, no asset and no amount is not a degraded record, it is a placeholder
      # wearing the shape of one.
      assert {:error, :unexpected_response_shape} =
               Private.get_staking_history(@credentials,
                 plug: responding(["not a row"]),
                 retry_attempts: 0
               )
    end

    test "an unrecognised type is :other, not the nearest atom that fits" do
      transactions = [
        %{
          "transactionId" => "stk-3",
          "transactionType" => "Slashing",
          "amountCurrency" => "ETH",
          "amount" => "1"
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(history_body("provider-a", transactions)),
                 retry_attempts: 0
               )

      assert tx.type == :other
      assert tx.venue_type == "Slashing"
    end

    test "an Interest row is a reward" do
      transactions = [
        %{
          "transactionId" => "stk-4",
          "transactionType" => "Interest",
          "amountCurrency" => "ETH",
          "amount" => "0.01"
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(history_body("provider-a", transactions)),
                 retry_attempts: 0
               )

      assert tx.type == :reward
    end

    test "an epoch-millisecond dateTime, the venue's own example shape, lands in this century" do
      # `StakingTransaction.dateTime`'s own example (`rest.yaml:9532`) is
      # `1667418560153` — an epoch-millisecond integer, despite the field being described
      # as "the time of the transaction in milliseconds". `staking_time/1` reads it whether
      # it is that, an epoch-second integer, or an ISO string.
      transactions = [
        %{
          "transactionId" => "stk-5",
          "transactionType" => "Deposit",
          "amountCurrency" => "ETH",
          "amount" => "1",
          "dateTime" => 1_787_936_401_000
        }
      ]

      assert {:ok, [tx]} =
               Private.get_staking_history(@credentials,
                 plug: responding(history_body("provider-a", transactions)),
                 retry_attempts: 0
               )

      assert tx.venue_time.year == 2026
    end

    test "since and until go out as ISO datetime strings, not epoch milliseconds" do
      # `rest.yaml:6729,6733`; the request example at `:6758` gives
      # `"2022-11-01T00:00:00.000Z"`.
      me = self()

      assert {:ok, []} =
               Private.get_staking_history(@credentials,
                 since: ~U[2026-08-25 00:00:00Z],
                 until: ~U[2026-09-01 00:00:00Z],
                 plug: capturing(history_body("provider-a", []), me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/staking/history"}
      assert payload["since"] == "2026-08-25T00:00:00Z"
      assert payload["until"] == "2026-09-01T00:00:00Z"
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
                 plug:
                   capturing(
                     %{
                       "transactionId" => "stk-6",
                       "transactionType" => "Deposit",
                       "currency" => "ETH",
                       "amount" => "1.5"
                     },
                     me
                   ),
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
                 plug:
                   capturing(
                     %{
                       "transactionId" => "stk-7",
                       "transactionType" => "Deposit",
                       "currency" => "ETH",
                       "amount" => "0.00000001"
                     },
                     me
                   ),
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
