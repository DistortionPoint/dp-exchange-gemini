defmodule DpExchange.Gemini.FakeInjectionTest do
  @moduledoc """
  Proves `Fake` actually consults `Core.FakeInjection` — the shared mechanism itself is
  tested in `dp_exchange_core`; this is the wiring, per function, in this package.

  Whole-call injection short-circuits BEFORE a function's own argument validation, so
  these calls use minimal/placeholder arguments throughout — the point is that the
  wrapped logic never runs at all once an outcome is queued.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.FakeInjection
  alias DpExchange.Gemini.Fake

  @credentials %{api_key: "k", api_secret: "s"}

  describe "whole-call injection reaches every non-symbol function with a real success path" do
    for {name, arity, args} <- [
          {:get_symbols, 1, [[]]},
          {:get_fx_rate, 3, ["AUD-USD", ~U[2026-01-01 00:00:00Z], []]},
          {:list_networks, 2, ["ETH", []]},
          {:list_fee_promos, 1, [[]]},
          {:get_market_overview, 1, [[]]},
          {:get_balances, 2, [%{}, []]},
          {:get_accounts, 2, [%{}, []]},
          {:get_fees, 2, [%{}, []]},
          {:get_transfers, 2, [%{}, []]},
          {:place_order, 3, [%{}, %{}, []]},
          {:cancel_order, 3, [%{}, "id", []]},
          {:get_order, 3, [%{}, "id", []]},
          {:get_orders, 2, [%{}, []]},
          {:cancel_all_orders, 2, [%{}, []]},
          {:get_trade_history, 2, [%{}, []]},
          {:test_connection, 2, [%{}, []]},
          {:market_status, 1, [[]]},
          {:get_positions, 1, [[]]},
          {:get_staking_rates, 1, [[]]},
          {:get_staking_balances, 1, [[]]},
          {:get_staking_rewards, 1, [[]]},
          {:get_staking_history, 1, [[]]},
          {:stake, 3, ["eth", Decimal.new("1"), []]},
          {:unstake, 3, ["eth", Decimal.new("1"), []]},
          {:quote_conversion, 4, ["USD", "BTC", Decimal.new("1"), []]},
          {:commit_conversion, 2, ["id", []]},
          {:convert, 4, ["USD", "BTC", Decimal.new("1"), []]},
          {:get_trade_volume, 2, [%{}, []]},
          {:get_deposit_address, 3, ["ETH", "ethereum", []]},
          {:list_approved_addresses, 1, [[]]},
          {:estimate_withdrawal_fee, 4, ["ETH", "ethereum", Decimal.new("1"), []]},
          {:withdraw, 5, ["ETH", "ethereum", Decimal.new("1"), "0xabc", []]},
          {:list_payment_methods, 2, [%{}, []]},
          {:add_payment_method, 2, [%{}, []]},
          {:transfer_internal, 4, ["ETH", Decimal.new("1"), [], []]},
          {:request_approved_address, 4, ["ethereum", "0xabc", "desk", []]},
          {:remove_approved_address, 3, ["ethereum", "0xabc", []]},
          {:get_transactions, 2, [%{}, []]},
          {:get_notional_balances, 3, [%{}, "usd", []]},
          {:list_custody_fees, 2, [%{}, []]},
          {:create_account, 1, [[]]},
          {:rename_account, 3, ["id", "name", []]},
          {:get_roles, 1, [[]]}
        ] do
      test "#{name}/#{arity}" do
        FakeInjection.fail_always(:gemini, {:error, :injected})
        assert apply(Fake, unquote(name), unquote(Macro.escape(args))) == {:error, :injected}
      end
    end

    test "with nothing queued, normal Fake behaviour is unaffected" do
      assert {:ok, _symbols} = Fake.get_symbols([])
    end
  end

  describe "symbol-targeted injection" do
    for {name, arity, symbol_arg_index, other_args} <- [
          {:get_price, 2, 0, [[]]},
          {:get_top_of_book, 2, 0, [[]]},
          {:get_order_book, 2, 0, [[]]},
          {:get_trades, 2, 0, [[]]},
          {:quantization, 1, 0, []},
          {:get_funding, 2, 0, [[]]},
          {:get_contract_stats, 2, 0, [[]]}
        ] do
      test "#{name}/#{arity} only fails for the targeted symbol" do
        FakeInjection.fail_always(:gemini, "BTC-USD", {:error, :injected})

        args_with =
          List.insert_at(unquote(Macro.escape(other_args)), unquote(symbol_arg_index), "BTC-USD")

        args_without =
          List.insert_at(unquote(Macro.escape(other_args)), unquote(symbol_arg_index), "ETH-USD")

        assert apply(Fake, unquote(name), args_with) == {:error, :injected}
        assert apply(Fake, unquote(name), args_without) != {:error, :injected}
      end
    end

    test "a whole-call queue still reaches a symbol-taking function with no symbol-specific override" do
      FakeInjection.fail_always(:gemini, {:error, :whole_call})

      assert Fake.get_price("BTC-USD", []) == {:error, :whole_call}
    end
  end

  describe "queue_failures/2 is deterministic and pops in order" do
    test "returns queued outcomes, then resumes normal behaviour" do
      FakeInjection.queue_failures(:gemini, [{:error, :first}, {:error, :second}])

      assert Fake.get_symbols([]) == {:error, :first}
      assert Fake.get_symbols([]) == {:error, :second}
      assert {:ok, _symbols} = Fake.get_symbols([])
    end
  end

  describe "bypass_credentials/1" do
    test "skips the venue-faithful credential refusal" do
      assert Fake.get_balances(%{}, []) == {:refused, :missing_credentials}

      FakeInjection.bypass_credentials(:gemini)

      assert {:ok, _balances} = Fake.get_balances(%{}, [])
    end

    test "the default, without calling bypass_credentials/1, is still venue-faithful" do
      assert Fake.get_balances(%{}, []) == {:refused, :missing_credentials}
    end
  end

  describe "sanity: real credentials still work through the injection wrapper" do
    test "get_balances/2 succeeds normally with valid credentials and nothing queued" do
      assert {:ok, [_balance | _rest]} = Fake.get_balances(@credentials, [])
    end
  end
end
