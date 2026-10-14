defmodule DpExchange.Gemini.TickAAFakeTest do
  # Tick AA: the lines of `DpExchange.Gemini.Fake` the full coverage run never executed.
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Gemini.Fake

  @credentials %{api_key: "test-key-not-real", api_secret: "test-secret-not-real"}
  @missing {:error, {:missing_credentials, :gemini}}

  describe "the default arities a consumer calls without options" do
    test "each answers as the explicit-arity call with empty options does" do
      ambiguous = {:error, {:ambiguous_conversion, "USD", "BTC"}}
      one = Decimal.new("1")

      assert Fake.list_networks("USDC") == @missing
      assert Fake.list_fee_promos() == {:ok, [%{"symbol" => "btcusd"}]}

      assert {:ok, instruments} = Fake.list_instruments()
      assert Enum.map(instruments, & &1.symbol) == ~w(BTC-USD BTC-GUSD ETH-USD SOL-RLUSD)

      assert Fake.cancel_all_orders(%{}) == {:error, :scope_required}
      assert Fake.get_positions() == @missing
      assert Fake.unstake("ETH", 1) == {:error, :missing_provider_id}
      assert Fake.quote_conversion("USD", "BTC", one) == ambiguous
      assert Fake.convert("USD", "BTC", one) == ambiguous

      assert {:error, {:missing_option, [:symbol, :side, :amount, :price, :fee]}} =
               Fake.commit_conversion("1234")

      assert Fake.get_trade_volume(%{}) == @missing
      assert Fake.list_approved_addresses() == {:error, {:missing_option, :network}}
      assert Fake.transfer_internal("BTC", 1, []) == {:error, {:missing_option, :from}}
      assert Fake.create_account() == {:error, :name_required}
      assert Fake.rename_account("old", "New") == @missing
      assert Fake.get_roles() == @missing
    end
  end

  describe "the network direction of list_networks/2" do
    test "is signed, as the real one is" do
      assert Fake.list_networks(nil, network: "ethereum") == @missing
    end

    test "answers the assets the network carries for this credential" do
      opts = [network: "ethereum", credentials: @credentials]
      expected = [%{"network" => "ethereum", "assets" => ["USDC", "USDT"]}]

      assert Fake.list_networks(nil, opts) == {:ok, expected}
    end
  end

  describe "list_instruments/1 with a symbol the fake does not carry" do
    test "fails the whole call with the venue's own refusal inside, as the real call does" do
      expected = {:instrument_detail_failed, "DOGE-USD", {:refused, :not_listed}}

      assert Fake.list_instruments(symbols: ["BTC-USD", "DOGE-USD"]) == {:error, expected}
    end
  end

  describe "commit_conversion/2 with a symbol that is not a pair" do
    test "is refused, not committed on a guessed pair" do
      terms = [
        symbol: "XYZ",
        side: :buy,
        amount: Decimal.new("1"),
        price: Decimal.new("40000"),
        fee: Decimal.new("2.50"),
        credentials: @credentials
      ]

      assert {:error, {:invalid_symbol, symbol}} = Fake.commit_conversion("1234", terms)
      assert String.upcase(symbol) == "XYZ"
    end
  end

  describe "add_payment_method/2 for Canada" do
    test "registers the account as pending through the Canadian endpoint" do
      details = %{"accountNumber" => "1"}
      opts = [country: "CA", credentials: @credentials]
      expected = %{"id" => "bank-3", "status" => "pending", "accountNumber" => "1"}

      assert Fake.add_payment_method(details, opts) == {:ok, expected}
    end
  end

  describe "get_transactions/2 with :since as a string of digits" do
    test "reads it as nanoseconds, as an integer :since is read" do
      as_string = [since: "1700000000001000000"]
      as_integer = [since: 1_700_000_000_001_000_000]

      assert {:ok, rows} = Fake.get_transactions(@credentials, as_string)
      assert Enum.map(rows, & &1["type"]) == ["Deposit", "Fee"]
      assert Fake.get_transactions(@credentials, as_integer) == {:ok, rows}
    end
  end

  describe "withdraw/5 with a string memo" do
    test "carries a memo that is not blank as given" do
      opts = [memo: "tag-1", credentials: @credentials]

      assert {:ok, %Types.Withdrawal{memo: "tag-1"}} =
               Fake.withdraw("ETH", "ethereum", 1, "0xabc", opts)
    end

    test "reports a blank memo as none, as the real call sends none" do
      opts = [memo: "   ", credentials: @credentials]

      assert {:ok, %Types.Withdrawal{memo: nil}} =
               Fake.withdraw("ETH", "ethereum", 1, "0xabc", opts)
    end
  end
end
