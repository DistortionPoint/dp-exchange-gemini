defmodule DpExchange.Gemini.FakeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Core.Types.{OrderBook, Quote}
  alias DpExchange.Gemini.Fake

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
      assert Fake.list_instruments([]) == {:error, :not_supported}
      assert Fake.get_rate_limit_status(%{}, []) == {:error, :not_supported}
    end

    test "an account call with no credentials refuses rather than answering emptily" do
      # A fake that accepted `nil` would let a consumer's test pass while the real call
      # fails on a missing key — differently capable, which is the forbidden kind.
      assert Fake.get_balances(%{}, []) == {:error, {:unsupported_auth_scheme, nil}}
      assert Fake.get_accounts(%{}, []) == {:error, {:unsupported_auth_scheme, nil}}
    end

    test "it never stamps the current clock" do
      # A fake that stamps `utc_now/0` cannot be used to test anything about freshness,
      # and is itself the substitution this family refuses.
      {:ok, first} = Fake.get_price("BTC-USD")
      Process.sleep(5)
      {:ok, second} = Fake.get_price("BTC-USD")

      assert first.timestamp == second.timestamp
    end
  end

  describe "it models the venue's refusals, not only its successes" do
    test "an unlisted symbol is a refusal, not an error" do
      # Each shape mirrors the specific endpoint behind it — see `Fake`'s own moduledoc —
      # rather than one invented atom standing in for all three.
      assert Fake.get_price("NOPE-USD") ==
               {:refused, {:unknown_reason, "'NOPE-USD' does not have available data yet"}}

      assert Fake.get_order_book("NOPE-USD") == {:refused, :invalid_symbol}
      assert Fake.quantization("NOPE-USD") == {:refused, :invalid_symbol}
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
      recent = ~U[2026-08-27 00:00:00Z]

      assert {:ok, [_candle]} = Fake.get_historical_prices("BTC-USD", "1d", start: recent)
    end
  end

  describe "the shapes it returns are the real ones" do
    test "a quote is a Quote with Decimals" do
      assert {:ok, %Quote{} = quote_struct} = Fake.get_price("BTC-USD")
      assert %Decimal{} = quote_struct.price
      assert quote_struct.provider == :gemini
    end

    test "a book is an OrderBook with Decimal level tuples" do
      assert {:ok, %OrderBook{bids: [{price, size}]}} = Fake.get_order_book("BTC-USD")
      assert %Decimal{} = price
      assert %Decimal{} = size
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

  describe "coverage_by_kind/1" do
    test "reports what it pushed under :quotes, and declares :top_of_book honestly empty" do
      # `subscribe/2` above only ever pushes a `Types.Quote` — never a `Types.TopOfBook` —
      # so this fake is honestly quotes-only. `:top_of_book` still appears, empty, rather
      # than being omitted: an omitted key would read as "this fake doesn't know the
      # kind", where an empty map reads as what is true here — declared, nothing observed.
      :ok = Fake.subscribe(["BTC-USD", "NOPE-USD"], to: self())

      assert Fake.coverage_by_kind() == %{quotes: %{"BTC-USD" => :stream}, top_of_book: %{}}
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

      assert Fake.coverage_by_kind() == %{quotes: %{}, top_of_book: %{}}
    end
  end

  describe "lifecycle" do
    test "it starts nothing" do
      assert Fake.start_link([]) == :ignore
    end
  end

  describe "order lifecycle in memory" do
    test "get_order/3 answers with the id it was asked about" do
      assert {:ok, order} = Fake.get_order(@credentials, "abc-123", [])
      assert order.id == "abc-123"
    end

    test "cancel_order/3 reports the order cancelled" do
      assert {:ok, order} = Fake.cancel_order(@credentials, "abc-123", [])
      assert order.id == "abc-123"
      assert order.status == :cancelled
    end

    test "both refuse without credentials, as the real adapter does" do
      assert Fake.get_order(%{}, "abc-123", []) == {:error, {:unsupported_auth_scheme, nil}}
      assert Fake.cancel_order(%{}, "abc-123", []) == {:error, {:unsupported_auth_scheme, nil}}
    end

    test "a placed order carries the caller's own values back, unrewritten" do
      # The fake never rewrites what the caller supplied — the rule that stops a fake
      # being usable to prove something the real venue would not do.
      request = %{
        symbol: "ETH-USD",
        side: :sell,
        quantity: "2",
        price: "3000",
        order_type: :limit
      }

      assert {:ok, order} = Fake.place_order(@credentials, request, [])
      assert order.symbol == "ETH-USD"
      assert order.side == :sell
      assert Decimal.equal?(order.price, Decimal.new("3000"))
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
  end

  describe "bulk cancel" do
    test "no scope is an error, as it is on the real venue" do
      assert {:error, :scope_required} = Fake.cancel_all_orders(@credentials, [])
    end

    test "a scope the venue does not have is an error" do
      assert {:error, {:unsupported_scope, :everything}} =
               Fake.cancel_all_orders(@credentials, scope: :everything)
    end

    test "either scope answers with the venue's two lists" do
      assert {:ok, %{cancelled: [_id], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :session)

      assert {:ok, %{cancelled: [_id2], rejected: []}} =
               Fake.cancel_all_orders(@credentials, scope: :account)
    end

    test "it refuses without credentials, as every account call does" do
      assert {:error, {:unsupported_auth_scheme, nil}} =
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
      assert {:error, {:missing_option, [:symbol, :side, :amount, :price]}} =
               Fake.commit_conversion("q-1", credentials: @credentials)
    end

    test "a committed conversion is settled" do
      assert {:ok, conversion} =
               Fake.commit_conversion("q-1",
                 symbol: "BTC-USD",
                 side: :buy,
                 amount: Decimal.new("1"),
                 price: Decimal.new("40000"),
                 credentials: @credentials
               )

      assert conversion.status == :settled
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
      assert {:error, {:unsupported_auth_scheme, nil}} =
               Fake.convert("GUSD", "USD", Decimal.new("1"), symbol: "GUSD-USD", side: :sell)

      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.commit_conversion("q-1", [])
    end
  end

  describe "the account's own traded volume" do
    test "rows come back under the venue's own field names" do
      assert {:ok, [row]} = Fake.get_trade_volume(@credentials, [])
      assert row["symbol"] == "btcusd"
    end

    test "it refuses without credentials" do
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.get_trade_volume(%{}, [])
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

    test "an unlisted symbol is refused, not answered with someone else's tape" do
      # This used to answer unconditionally for ANY symbol, which is MORE capable than
      # `Rest.get_trades/2` — found in the 2026-09-06 real/fake parity sweep.
      assert Fake.get_trades("NOPE-USD") == {:refused, {:unknown_reason, "BadRequest"}}
    end

    test "the tape is not the caller's own fills" do
      # get_trade_history/2 needs a symbol and credentials; the tape needs neither.
      assert {:ok, [_trade]} = Fake.get_trades("BTC-USD")

      assert {:error, {:unsupported_auth_scheme, nil}} =
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
      assert {:error, {:unsupported_auth_scheme, nil}} =
               Fake.get_deposit_address("BTC", "bitcoin")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Fake.list_approved_addresses(network: "eth")

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Fake.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc")
    end
  end

  describe "the fake's payment and transfer surface" do
    test "a payment method list carries a pending one" do
      assert {:ok, methods} = Fake.list_payment_methods(@credentials)
      assert Enum.any?(methods, &(&1["status"] == "pending"))
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

      assert transfer["sourceAccount"] == "a"
      refute Map.has_key?(transfer, "address")
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
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.list_payment_methods(%{})
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.get_transactions(%{})
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.add_payment_method(%{})

      assert {:error, {:unsupported_auth_scheme, nil}} =
               Fake.request_approved_address("ethereum", "0xabc", nil)
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
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.get_notional_balances(%{}, "usd")
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.list_custody_fees(%{})
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
      assert {:ok, [reward]} = Fake.get_staking_rewards(credentials: @credentials)
      assert reward.period_start
      assert reward.period_end
      assert reward.accrual_count == 7
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
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.get_staking_balances()
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.get_staking_rewards()
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.get_staking_history()
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.stake("ETH", Decimal.new("1"))
      assert {:error, {:unsupported_auth_scheme, nil}} = Fake.unstake("ETH", Decimal.new("1"))
    end
  end
end
