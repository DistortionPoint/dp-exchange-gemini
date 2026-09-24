defmodule DpExchange.Gemini.ResponseShapeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

  # **A response of the wrong JSON shape is an answer, never a raise.**
  #
  # `Core.Venue`'s error discipline is that a facade call answers — `{:ok, _}`,
  # `{:error, _}`, `{:refused, _}` — and does not raise in the caller's process. These are
  # the calls that did, found by feeding every active facade callback a set of plausible
  # but wrong bodies: `[]`, `null`, `{}`, an object whose list fields are all `null`, and
  # `{"data": {}}`. Each row below is one body that used to raise, and the exception it
  # raised. Driven through the FACADE, with the HTTP layer replaced by a `plug:`, so what
  # is measured is exactly the decode path a consumer reaches.
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

  @credentials %{api_key: "account-k", api_secret: "s"}

  defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

  defp base(body) do
    [
      plug: answering(body),
      retry_attempts: 0,
      credentials: @credentials,
      account_id: "acct",
      account_number: "acct",
      account_hash: "acct"
    ]
  end

  defp answers_without_raising(label, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:raised, _error}, result),
           "gemini: #{label} raised #{inspect(result)} — a response shape it did not " <>
             "expect must be refused, not raised in the caller's process"

    result
  end

  # Gemini's decoders read `body["field"]`, and `Access` on a LIST raises
  # `ArgumentError`; they iterate rows, and iterating `null` raises
  # `Protocol.UndefinedError` while iterating an object walks key/value pairs into a
  # function expecting a row. `Rest.object/1` and `Rest.list/1` now check the shape.
  test "an object endpoint answering [] is refused" do
    v = DpExchange.Gemini

    for {label, call} <- [
          {"get_top_of_book/2", fn -> v.get_top_of_book("BTC-USD", base([])) end},
          {"get_funding/2", fn -> v.get_funding("BTCGUSDPERP", base([])) end},
          {"get_contract_stats/2", fn -> v.get_contract_stats("BTCGUSDPERP", base([])) end},
          {"get_deposit_address/3", fn -> v.get_deposit_address("BTC", "bitcoin", base([])) end}
        ] do
      assert {:error, :unexpected_response_shape} = answers_without_raising(label, call)
    end
  end

  test "a list endpoint answering null or an object is refused" do
    v = DpExchange.Gemini

    for body <- [
          nil,
          Map.new(~w(accounts products fills candles data results orders), &{&1, nil})
        ],
        {label, call} <- [
          {"get_symbols/1", fn -> v.get_symbols(base(body)) end},
          {"get_market_overview/1", fn -> v.get_market_overview(base(body)) end},
          {"get_historical_prices/4",
           fn -> v.get_historical_prices("BTC-USD", "1h", [], base(body)) end}
        ] do
      assert {:error, :unexpected_response_shape} = answers_without_raising(label, call)
    end
  end

  test "get_transfers/2 refuses an object — the vendor documents an array, never one" do
    # It used `List.wrap/1`, which handed any object back as one transfer: the wrapper-
    # as-row defect. The vendor's OpenAPI gives this 200 as `type: array` of V2Transfer.
    assert {:error, :unexpected_response_shape} =
             answers_without_raising("get_transfers/2", fn ->
               DpExchange.Gemini.get_transfers(@credentials, base(%{"transfers" => nil}))
             end)
  end

  test "a well-formed list still decodes" do
    assert {:ok, ["BTC-USD"]} =
             DpExchange.Gemini.get_symbols(base(["btcusd"]))
  end
end
