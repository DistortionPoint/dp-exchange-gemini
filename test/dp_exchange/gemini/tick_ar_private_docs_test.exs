defmodule DpExchange.Gemini.TickARPrivateDocsTest do
  @moduledoc """
  Tick AR, lens V: what `DpExchange.Gemini.Private`'s docs say, held against what it does.

  Each test pins a claim a `@doc` makes (an error tuple, a status word, a dropped row) so a
  doc that drifts from the code fails here. The approved-address status is the one code
  change: an unknown word was read as `:pending`, a guess about a status that may be terminal.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.ApprovedAddress
  alias DpExchange.Gemini.Private

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

  defp approved(rows) do
    Private.list_approved_addresses(@credentials,
      network: "ethereum",
      plug: responding(%{"approvedAddresses" => rows}),
      retry_attempts: 0
    )
  end

  describe "list_approved_addresses/2 status words" do
    test "the spec's pending words are both :pending, and active is :active" do
      for {word, expected} <- [
            {"active", :active},
            {"pending-time", :pending},
            {"pending-mua", :pending}
          ] do
        assert {:ok, [%{status: ^expected}]} =
                 approved([%{"address" => "0x1", "status" => word}]),
               "status #{word} must read as #{expected}"
      end
    end

    test "a status the venue did not state is :pending, which usable?/2 cannot call ready" do
      assert {:ok, [%{status: :pending, active_from: nil} = entry]} =
               approved([%{"address" => "0x1"}])

      assert ApprovedAddress.usable?(entry, DateTime.utc_now()) == nil
    end

    test "a status the venue stated and this package has no word for refuses the page" do
      for word <- ["frozen", "Active", "pending", "", 7, %{"state" => "active"}] do
        rows = [
          %{"address" => "0x0", "status" => "active"},
          %{"address" => "0x1", "status" => word}
        ]

        assert {:error, :unexpected_response_shape} = approved(rows),
               "status #{inspect(word)} must not be read as :pending"
      end
    end

    test "the network is required, as the doc says" do
      assert {:error, {:missing_option, :network}} =
               Private.list_approved_addresses(@credentials,
                 plug: responding(%{"approvedAddresses" => []}),
                 retry_attempts: 0
               )
    end
  end

  describe "refusals the docs name" do
    test "estimate_withdrawal_fee/5 needs opts[:address] before anything is sent" do
      assert {:error, {:missing_option, :address}} =
               Private.estimate_withdrawal_fee(
                 "ETH",
                 "ethereum",
                 Decimal.new("1"),
                 @credentials,
                 plug: responding(%{"fee" => "0.1", "currency" => "ETH"}),
                 retry_attempts: 0
               )

      assert {:error, {:invalid_address, 5}} =
               Private.estimate_withdrawal_fee(
                 "ETH",
                 "ethereum",
                 Decimal.new("1"),
                 @credentials,
                 address: 5,
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "cancel_scope/1 names a scope it does not know" do
      assert {:error, :scope_required} = Private.cancel_scope(nil)
      assert {:error, {:unsupported_scope, :everything}} = Private.cancel_scope(:everything)
      assert {:ok, "/v1/order/cancel/session"} = Private.cancel_scope(:session)
    end

    test "funding_amount_report/3 refuses one date bound with :from_and_to_together" do
      assert {:error, :from_and_to_together} =
               Private.funding_amount_report("btcgusdperp", @credentials,
                 from: ~D[2026-01-01],
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "commit_terms/2 refuses a side it cannot send after the quote id" do
      opts = [symbol: "btcusd", side: :hold, amount: "1", price: "2", fee: "0"]

      assert {:error, {:invalid_side, :hold}} = Private.commit_terms("123", opts)
      assert {:error, {:invalid_quote_id, "-1"}} = Private.commit_terms("-1", opts)

      assert {:ok, %{"side" => "buy"}} =
               Private.commit_terms("123", Keyword.put(opts, :side, "buy"))
    end

    test "instant_pair/3 reads only an atom side, and a string side is not 'given'" do
      assert {:error, {:missing_option, [:symbol, :side]}} =
               Private.instant_pair("BTC", "USD", symbol: "btcusd", side: "buy")

      assert {:ok, "btcusd", "buy"} =
               Private.instant_pair("BTC", "USD", symbol: "btcusd", side: :buy)

      assert {:error, {:invalid_option, :symbol, " "}} =
               Private.instant_pair("BTC", "USD", symbol: " ", side: :buy)
    end
  end

  describe "get_positions/2 as documented" do
    test "a flat row is dropped, a short is positive-sized, an unknown instrument is nil" do
      body = %{
        "openPositions" => [
          %{"symbol" => "btcgusdperp", "instrument_type" => "perp", "quantity" => "0"},
          %{"symbol" => "ethgusdperp", "instrument_type" => "swap", "quantity" => "-2"}
        ]
      }

      assert {:ok, [position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == :short
      assert Decimal.equal?(position.quantity, Decimal.new(2))
      assert position.instrument_type == nil
      assert position.liquidation_price == nil
    end

    test "a row with no symbol is refused by name" do
      body = %{"openPositions" => [%{"instrument_type" => "perp", "quantity" => "1"}]}

      assert {:error, {:missing_required_field, :symbol}} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "get_staking_history/2 transaction types as documented" do
    test "Deposit, Redeem and Interest are named; every other enum word is :other, kept" do
      words = [
        {"Deposit", :stake},
        {"Redeem", :unstake},
        {"Interest", :reward},
        {"RedeemPayment", :other},
        {"AdminRedeem", :other},
        {"AdminCreditAdjustment", :other},
        {"AdminDebitAdjustment", :other},
        {"SomethingNew", :other}
      ]

      transactions =
        words
        |> Enum.with_index()
        |> Enum.map(fn {{word, _type}, index} ->
          %{
            "transactionId" => "t#{index}",
            "transactionType" => word,
            "amountCurrency" => "ETH",
            "amount" => "1",
            "dateTime" => 1_787_936_147_000
          }
        end)

      body = [%{"providerId" => "provider-1", "transactions" => transactions}]

      assert {:ok, rows} =
               Private.get_staking_history(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Enum.map(rows, &{&1.venue_type, &1.type}) == words
    end
  end
end
