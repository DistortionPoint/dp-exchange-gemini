defmodule DpExchange.Gemini.WriteOnceTest do
  @moduledoc """
  A write the venue cannot tell from its own repeat is sent once — under OAuth too.

  `post/4` signs once and `Core.HttpClient` re-sends the same signed request after a
  transport error. Under API-key auth the repeat is refused for its nonce; under OAuth
  there is no nonce, and the repeat takes effect a second time. See `Private.post_once/4`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  @oauth %{access_token: "oauth-token-not-real"}

  @terms %{
    symbol: "BTC-USD",
    amount: Decimal.new("0.5"),
    price: Decimal.new("60000"),
    side: :buy
  }

  # Every request times out after reaching the plug, which is exactly the case where the
  # venue may have acted without the caller hearing. Counted, so a retry shows.
  defp timing_out(test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path})
      Req.Test.transport_error(conn, :timeout)
    end
  end

  defp opts(extra), do: [plug: timing_out(self()), retry_delay: 1] ++ extra

  defp requests(acc \\ []) do
    receive do
      {:request, path} -> requests([path | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "an internal transfer is sent once" do
    Private.transfer_internal("USD", Decimal.new("1"), [from: "a", to: "b"], @oauth, opts([]))
    assert [_one] = requests()
  end

  test "an internal transfer with an asset or amount that is not real is never sent" do
    accounts = [from: "a", to: "b"]

    assert {:error, {:non_positive_amount, :amount, 0}} =
             Private.transfer_internal("USD", 0, accounts, @oauth, opts([]))

    assert {:error, {:invalid_decimal, :amount, "abc"}} =
             Private.transfer_internal("USD", "abc", accounts, @oauth, opts([]))

    assert {:error, {:invalid_asset, nil}} =
             Private.transfer_internal(nil, 1, accounts, @oauth, opts([]))

    assert [] = requests()
  end

  test "a staking write with an asset or amount that is not real is never sent" do
    for write <- [&Private.stake/4, &Private.unstake/4] do
      assert {:error, {:non_positive_amount, :amount, _zero}} =
               write.("ETH", Decimal.new(0), @oauth, opts(provider_id: "p"))

      assert {:error, {:invalid_decimal, :amount, _nan}} =
               write.("ETH", Decimal.new("NaN"), @oauth, opts(provider_id: "p"))

      assert {:error, {:invalid_asset, nil}} =
               write.(nil, Decimal.new(1), @oauth, opts(provider_id: "p"))
    end

    assert [] = requests()
  end

  test "committing a conversion is sent once, so a lost reply is not read as a refusal" do
    terms = [
      symbol: "BTC-USD",
      side: :buy,
      amount: Decimal.new("1"),
      price: Decimal.new("100"),
      fee: Decimal.new("0.3"),
      credentials: @oauth
    ]

    assert {:error, _transport} = Private.commit_conversion("20930", opts(terms))
    assert [_one] = requests()
  end

  test "a new deposit address is requested once" do
    Private.get_deposit_address("ETH", "ethereum", @oauth, opts([]))
    assert [_one] = requests()
  end

  test "a margin preview with a number that is not real is never sent" do
    base = %{symbol: "BTC-USD", side: :buy, type: "limit", amount: "1", price: "100"}

    for {terms, expected} <- [
          {%{amount: 0}, {:non_positive_amount, :amount, 0}},
          {%{amount: "abc"}, {:invalid_decimal, :amount, "abc"}},
          {%{price: "-1"}, {:non_positive_amount, :price, "-1"}}
        ] do
      assert {:error, ^expected} =
               Private.preview_margin_order(Map.merge(base, terms), @oauth, opts([]))
    end

    assert {:error, {:invalid_decimal, :price, %Decimal{}}} =
             Private.preview_margin_order(
               Map.put(base, :price, Decimal.new("NaN")),
               @oauth,
               opts([])
             )

    market_buy = %{symbol: "BTC-USD", side: :buy, type: "market", total_spend: "0"}

    assert {:error, {:non_positive_amount, :total_spend, "0"}} =
             Private.preview_margin_order(market_buy, @oauth, opts([]))

    assert {:error, :amount_required} =
             Private.preview_margin_order(Map.delete(base, :amount), @oauth, opts([]))

    assert [] = requests()
  end

  test "a clearing order is sent once" do
    Private.create_clearing_order(@terms, @oauth, opts(counterparty_id: "cp-1"))
    assert [_one] = requests()
  end

  test "confirming and cancelling a clearing order are sent once" do
    Private.confirm_clearing_order("c-1", @terms, @oauth, opts([]))
    assert ["/v1/clearing/confirm"] = requests()

    Private.cancel_clearing_order("c-1", @oauth, opts([]))
    assert ["/v1/clearing/cancel"] = requests()
  end

  test "a rename and a revoke are sent once" do
    Private.rename_account(@oauth, opts(account: "old", name: "New"))
    assert ["/v1/account/rename"] = requests()

    Private.revoke_access_token(@oauth, opts([]))
    assert ["/v1/oauth/revokeByToken"] = requests()
  end

  test "a broker clearing order is sent once" do
    Private.create_broker_clearing_order(
      @terms,
      @oauth,
      opts(source_counterparty_id: "s", target_counterparty_id: "t", expires_in_hrs: 24)
    )

    assert [_one] = requests()
  end
end
