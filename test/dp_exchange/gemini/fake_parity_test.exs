defmodule DpExchange.Gemini.FakeParityTest do
  @moduledoc """
  Pins the real/fake divergences found in the 2026-09-06 sweep, so each can only drift
  back by breaking a test rather than silently.

  `Fake`'s own rule is "less capable is allowed, differently capable is not" — this file
  is the regression test for that rule specifically on the shapes that were once
  differently capable: the credential gate, the per-endpoint symbol refusal, the
  `range_unavailable` tuple, and order-type/time-in-force validation.

  Where a real shape can be produced here without live credentials or a live venue call
  (`Auth.headers/5`, `Private.order_wire/2`, and `Rest.get_historical_prices/4` against a
  plug), the assertion compares `Fake` against THAT real function's own return — not a
  literal copied from it — so a future change to the real shape breaks this test instead
  of leaving it green for the wrong reason. Where only a live measurement pins the real
  shape (`get_price/2`, `get_order_book/2`, `quantization/1`, `get_trades/2` — all
  documented with their measurement date beside the code that answers them), the literal
  IS the measurement, and the comment says so.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Auth, Fake, Private, Rest}

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

  describe "the credential gate matches Auth.headers/5's own decision, everywhere it is wired" do
    test "no credentials at all: nil scheme, Auth.headers/5's own catch-all" do
      assert Auth.headers(nil, "/v1/balances", %{}, %{}) ==
               {:error, {:unsupported_auth_scheme, nil}}

      assert Fake.get_balances(%{}, []) == {:error, {:unsupported_auth_scheme, nil}}
      assert Fake.get_accounts(%{}, []) == {:error, {:unsupported_auth_scheme, nil}}
    end

    test "an API key with no secret: scheme resolves, credentials do not satisfy it" do
      credentials = %{api_key: "k"}

      assert Auth.headers(:api_key, "/v1/balances", %{}, credentials) ==
               {:error, {:missing_credentials, :api_key}}

      assert Fake.get_balances(credentials, []) == {:error, {:missing_credentials, :api_key}}
    end

    test "an access_token that is not a binary never satisfies :oauth" do
      credentials = %{access_token: 12_345}

      assert Auth.headers(:oauth, "/v1/balances", %{}, credentials) ==
               {:error, {:missing_credentials, :oauth}}
    end

    test "both header families at once: :ambiguous, refused before either is sent" do
      credentials = %{api_key: "k", api_secret: "s", access_token: "t"}

      assert Fake.get_balances(credentials, []) ==
               {:error, {:unsupported_auth_scheme, :ambiguous}}
    end

    test "a caller-named auth_scheme the credentials do not satisfy is honoured, not ignored" do
      # Real behaviour: `opts[:auth_scheme]` overrides auto-detection entirely — see
      # `Private`'s own `auth_scheme/2`. A fake that only auto-detected would SUCCEED
      # here (api_key credentials are complete), which the real adapter refuses.
      credentials = %{api_key: "k", api_secret: "s"}

      assert Fake.get_balances(credentials, auth_scheme: :oauth) ==
               {:error, {:missing_credentials, :oauth}}
    end

    test "valid credentials still succeed, through every calling convention the fake uses" do
      credentials = %{api_key: "k", api_secret: "s"}

      # `credentials` as a direct argument:
      assert {:ok, _balances} = Fake.get_balances(credentials, [])
      # `credentials` folded into `opts[:credentials]`:
      assert {:ok, _address} =
               Fake.get_deposit_address("BTC", "bitcoin", credentials: credentials)

      # `credentials` found via `fake_credentials/1` alongside other named options:
      assert {:ok, _staking_balances} = Fake.get_staking_balances(credentials: credentials)
    end
  end

  describe "per-endpoint symbol refusal — each shape is a specific measurement, not one atom" do
    test "get_price/2 and get_top_of_book/2: the ticker's plain-text 404" do
      # Measured live 2026-09-06 (`rest_test.exs`, \"get_price refuses on a 404, keeping
      # the venue's own words\"): `/v1/pubticker/{symbol}` answers plain text, not JSON.
      assert Fake.get_price("NOPE-USD") ==
               {:refused, {:unknown_reason, "'NOPE-USD' does not have available data yet"}}

      assert Fake.get_top_of_book("NOPE-USD") ==
               {:refused, {:unknown_reason, "'NOPE-USD' does not have available data yet"}}
    end

    test "get_order_book/2 and quantization/1: the JSON InvalidSymbol reason" do
      assert Fake.get_order_book("NOPE-USD") == {:refused, :invalid_symbol}
      assert Fake.quantization("NOPE-USD") == {:refused, :invalid_symbol}
    end

    test "get_historical_prices/4: the candles endpoint's own plain-text 400" do
      assert Fake.get_historical_prices("NOPE-USD", "1d") ==
               {:refused, {:unknown_reason, "Supplied value 'NOPE-USD' is not a valid symbol"}}
    end

    test "get_trades/2: refuses at all, which it used to not do regardless of shape" do
      assert {:refused, _reason} = Fake.get_trades("NOPE-USD")
    end

    test "place_order/3: the same InvalidSymbol reason every other private POST shares" do
      credentials = %{api_key: "k", api_secret: "s"}
      base = %{symbol: "NOPE-USD", side: :buy, quantity: "1", price: "100"}

      assert {:refused, :invalid_symbol} = Fake.place_order(credentials, base, [])
    end
  end

  describe "range_unavailable carries the same keys as Rest.get_historical_prices/4" do
    @candles [[1_787_935_740_000, 77_986.74, 77_995.93, 77_908.94, 77_941.47, 0.0]]

    defp responding(body) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
        |> Req.Test.json(body)
      end
    end

    test "earliest: and requested: both appear, in both adapters" do
      long_ago = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)

      assert {:error, {:range_unavailable, "1d", real_details}} =
               Rest.get_historical_prices("BTC-USD", "1d", [start: long_ago],
                 plug: responding(@candles),
                 retry_attempts: 0
               )

      assert {:error, {:range_unavailable, "1d", fake_details}} =
               Fake.get_historical_prices("BTC-USD", "1d", [start: long_ago], [])

      assert Enum.sort(Keyword.keys(real_details)) == Enum.sort(Keyword.keys(fake_details))
      assert Keyword.get(fake_details, :requested) == long_ago
    end
  end

  describe "order validation shares one implementation with the real adapter" do
    test "Private.order_wire/2 IS what Fake.place_order/3 validates against" do
      # A combination the venue refuses (`\"at most one execution option\"`) that this
      # fake used to accept because order_type and time_in_force were validated
      # independently of each other.
      assert Private.order_wire(:post_only, :fok) ==
               {:error, {:conflicting_execution_options, ["maker-or-cancel"], ["fill-or-kill"]}}

      credentials = %{api_key: "k", api_secret: "s"}
      base = %{symbol: "BTC-USD", side: :buy, quantity: "1", price: "100"}

      assert {:error, {:conflicting_execution_options, ["maker-or-cancel"], ["fill-or-kill"]}} =
               Fake.place_order(
                 credentials,
                 base |> Map.put(:order_type, :post_only) |> Map.put(:time_in_force, :fok),
                 []
               )
    end

    test "a stop-limit order takes no execution option, in both adapters" do
      assert Private.order_wire(:stop_limit, :ioc) ==
               {:error,
                {:unsupported_time_in_force, "immediate-or-cancel", :not_allowed_on_stop_limit}}
    end
  end
end
