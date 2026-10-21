defmodule DpExchange.Gemini.TickLPrivateTest do
  @moduledoc """
  Tick L: the private surface and its fake.

  Four things are pinned here. History reads refuse a page size or a window the venue's schema
  does not name BEFORE anything is signed; the fake refuses and filters by exactly the same
  options; the allowlist writes check their network and address; and a value the contract types
  as a `Decimal` or a string comes back as one whatever shape the caller held it in.

  A plug that raises stands in for the venue wherever a refusal is asserted: if the call
  reached it, the result would not be the refusal.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Conversion, StakingTransaction, Withdrawal}
  alias DpExchange.Gemini.{Auth, Fake, Private}

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
  @rewards_since ~U[2026-08-01 00:00:00Z]

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

      send(test_pid, {:payload, payload})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp exploding do
    fn _conn -> raise "must not reach the venue" end
  end

  defp real_opts(opts), do: opts ++ [plug: exploding(), retry_attempts: 0]

  # One call per history read, real side. Each takes the options under test.
  defp real(:orders, opts) do
    Private.get_orders(@credentials, real_opts([history: true] ++ opts))
  end

  defp real(:trades, opts) do
    Private.get_trade_history(@credentials, real_opts(opts))
  end

  defp real(:transfers, opts) do
    Private.get_transfers(@credentials, real_opts(opts))
  end

  defp real(:custody_fees, opts) do
    Private.list_custody_fees(@credentials, real_opts(opts))
  end

  defp real(:accounts, opts) do
    Private.list_accounts(@credentials, real_opts(opts))
  end

  defp real(:staking_history, opts) do
    Private.get_staking_history(@credentials, real_opts(opts))
  end

  defp real(:staking_rewards, opts) do
    Private.get_staking_rewards(@credentials, real_opts([since: @rewards_since] ++ opts))
  end

  defp real(:clearing_trades, opts) do
    Private.list_clearing_trades(@credentials, real_opts(opts))
  end

  defp real(:clearing_orders, opts) do
    Private.list_clearing_orders(@credentials, real_opts(opts))
  end

  defp real(:transactions, opts) do
    Private.get_transactions(@credentials, real_opts(opts))
  end

  defp real(:funding_payments, opts) do
    Private.list_funding_payments(@credentials, real_opts(opts))
  end

  # The fake side, for the reads the behaviour has one for. The others (accounts, clearing,
  # funding payments) are Gemini-only calls with no fake, so they are not compared: comparing
  # the real call with itself could never fail.
  @fake_reads [
    :orders,
    :trades,
    :transfers,
    :custody_fees,
    :transactions,
    :staking_history,
    :staking_rewards
  ]

  defp fake(:orders, opts, creds) do
    Fake.get_orders(creds, [history: true] ++ opts)
  end

  defp fake(:trades, opts, creds) do
    Fake.get_trade_history(creds, opts)
  end

  defp fake(:transfers, opts, creds) do
    Fake.get_transfers(creds, opts)
  end

  defp fake(:custody_fees, opts, creds) do
    Fake.list_custody_fees(creds, opts)
  end

  defp fake(:transactions, opts, creds) do
    Fake.get_transactions(creds, opts)
  end

  defp fake(:staking_history, opts, creds) do
    Fake.get_staking_history([credentials: creds] ++ opts)
  end

  defp fake(:staking_rewards, opts, creds) do
    Fake.get_staking_rewards([credentials: creds, since: @rewards_since] ++ opts)
  end

  @refused [
    {:orders, :limit, 0},
    {:orders, :limit, 501},
    {:orders, :limit, "10"},
    {:orders, :since, ~D[2026-01-01]},
    {:orders, :since, -5},
    {:orders, :symbol, :btcusd},
    {:orders, :symbol, " "},
    {:trades, :limit, 0},
    {:trades, :limit, 501},
    {:trades, :since, "yesterday"},
    {:transfers, :limit_transfers, 51},
    {:transfers, :limit_transfers, 0},
    {:transfers, :timestamp, -1},
    {:transfers, :currency, ""},
    {:custody_fees, :limit, 51},
    {:custody_fees, :since, ~D[2026-01-01]},
    {:accounts, :limit, 501},
    {:accounts, :since, 1.5},
    {:staking_history, :limit, 501},
    {:staking_history, :since, 5},
    {:staking_history, :until, "not a time"},
    {:staking_rewards, :until, 5},
    {:staking_rewards, :provider_id, ""},
    {:clearing_trades, :limit, 301},
    {:clearing_trades, :since_nanos, "soon"},
    {:clearing_orders, :side, :hold},
    {:clearing_orders, :symbol, 5},
    {:transactions, :limit, 301},
    {:transactions, :since, %{}},
    {:funding_payments, :to, "soon"}
  ]

  describe "history reads refuse an option the venue's schema does not name" do
    test "before anything is signed, naming the option and the value" do
      for {read, key, value} <- @refused do
        assert {:error, {:invalid_option, ^key, ^value}} = real(read, [{key, value}]),
               "#{read} #{key}: #{inspect(value)}"
      end
    end

    test "the fake refuses the same value in the same shape, even with no credential" do
      with_fakes = for {read, _key, _value} = row <- @refused, read in @fake_reads, do: row
      assert length(with_fakes) >= 15

      for {read, key, value} <- with_fakes do
        refusal = real(read, [{key, value}])

        assert {:error, {:invalid_option, ^key, ^value}} = refusal
        assert fake(read, [{key, value}], %{}) == refusal, "#{read} #{key}: #{inspect(value)}"
        assert fake(read, [{key, value}], @credentials) == refusal
      end
    end

    test "the maxima and the documented spellings are accepted" do
      me = self()

      assert {:ok, []} =
               Private.get_trade_history(@credentials,
                 limit: 500,
                 since: "1591084414000",
                 symbol: "BTC-USD",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}, 5_000
      assert payload["limit_trades"] == 500
      assert payload["timestamp"] == "1591084414000"

      assert {:ok, []} =
               Private.get_staking_history(@credentials,
                 limit: 500,
                 since: "2022-11-01T00:00:00.000Z",
                 until: ~U[2022-11-02 00:00:00Z],
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, []} =
               Private.get_orders(@credentials,
                 history: true,
                 limit: 1,
                 since: 0,
                 plug: responding([]),
                 retry_attempts: 0
               )
    end

    test "the resting-orders read takes none of them, so it checks none" do
      assert {:ok, []} =
               Private.get_orders(@credentials,
                 limit: 0,
                 since: ~D[2026-01-01],
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, []} = Fake.get_orders(@credentials, limit: 0, since: ~D[2026-01-01])
    end
  end

  describe "the fake filters by what it is given" do
    test "closed orders: symbol, since and limit narrow the closed orders it holds" do
      assert {:ok, [order]} = Fake.get_orders(@credentials, history: true, symbol: "btcusd")
      assert order.symbol == "BTC-USD"

      assert {:ok, []} = Fake.get_orders(@credentials, history: true, symbol: "ETH-USD")
      assert {:ok, [_order]} = Fake.get_orders(@credentials, history: true, limit: 1)

      exact = ~U[2026-08-28 12:00:00Z]
      later = ~U[2026-08-28 12:00:01Z]

      assert {:ok, [_order]} = Fake.get_orders(@credentials, history: true, since: exact)
      assert {:ok, []} = Fake.get_orders(@credentials, history: true, since: later)

      # An epoch in milliseconds and a string of digits are read the way the real call sends
      # them.
      since_ms = DateTime.to_unix(later, :millisecond)
      assert {:ok, []} = Fake.get_orders(@credentials, history: true, since: since_ms)

      since_text = Integer.to_string(since_ms)
      assert {:ok, []} = Fake.get_orders(@credentials, history: true, since: since_text)

      # The resting read is not narrowed by a history option: it holds none.
      assert {:ok, []} = Fake.get_orders(@credentials, symbol: "BTC-USD")
    end

    test "custody fees: since is on or after, and limit takes the first" do
      at = DateTime.from_unix!(1_700_000_000_000, :millisecond)
      later = DateTime.add(at, 1, :second)

      assert {:ok, [_fee]} = Fake.list_custody_fees(@credentials, since: at)
      assert {:ok, [_fee]} = Fake.list_custody_fees(@credentials, since: 1_700_000_000)
      assert {:ok, []} = Fake.list_custody_fees(@credentials, since: later)
      assert {:ok, [_fee]} = Fake.list_custody_fees(@credentials, limit: 1)
    end

    test "transactions: since is MILLISECONDS, as on the real call" do
      assert {:ok, all} = Fake.get_transactions(@credentials)
      assert length(all) == 3

      # The rows are the vendor's `Transaction` shapes: one trade (`type: "trade"`) and two
      # transfers, told apart by their `eid`.
      assert {:ok, later} = Fake.get_transactions(@credentials, since: 1_700_000_000_001)
      assert Enum.map(later, & &1["eid"]) == [368_598_436_530, 368_598_436_531]

      assert {:ok, [%{"type" => "trade"}]} = Fake.get_transactions(@credentials, limit: 1)

      at = DateTime.from_unix!(1_700_000_000_002, :millisecond)
      assert {:ok, [%{"eid" => 368_598_436_531}]} = Fake.get_transactions(@credentials, since: at)
    end

    test "staking history: provider, window and limit narrow it; the row is dated" do
      opts = [credentials: @credentials]
      assert {:ok, [row]} = Fake.get_staking_history(opts)
      assert DateTime.compare(row.venue_time, ~U[2026-08-28 12:00:00Z]) == :eq

      assert {:ok, []} = Fake.get_staking_history(opts ++ [provider_id: "provider-b"])
      assert {:ok, [_row]} = Fake.get_staking_history(opts ++ [provider_id: "provider-a"])
      assert {:ok, [_row]} = Fake.get_staking_history(opts ++ [limit: 1])

      assert {:ok, [_row]} = Fake.get_staking_history(opts ++ [since: "2026-08-28T12:00:00Z"])
      assert {:ok, []} = Fake.get_staking_history(opts ++ [since: ~U[2026-08-28 12:00:01Z]])

      assert {:ok, []} = Fake.get_staking_history(opts ++ [until: "2026-08-28T11:59:59Z"])
      assert {:ok, [_row]} = Fake.get_staking_history(opts ++ [until: ~U[2026-08-28 12:00:00Z]])
    end

    test "staking rewards: the provider narrows them" do
      opts = [credentials: @credentials, since: @rewards_since]
      assert {:ok, [_reward]} = Fake.get_staking_rewards(opts)
      assert {:ok, [_reward]} = Fake.get_staking_rewards(opts ++ [provider_id: "provider-a"])
      assert {:ok, []} = Fake.get_staking_rewards(opts ++ [provider_id: "provider-b"])
    end
  end

  describe "the allowlist writes check their network and address" do
    test "request: label first, then network, then address, before the credential" do
      cases = [
        {nil, "0xabc", "desk", {:error, {:invalid_network, nil}}},
        {"", "0xabc", "desk", {:error, {:invalid_network, ""}}},
        {"ethereum", nil, "desk", {:error, {:invalid_address, nil}}},
        {"ethereum", "  ", "desk", {:error, {:invalid_address, "  "}}},
        {"ethereum", "0xabc", nil, {:error, {:missing_required_field, :label}}},
        {"", "", nil, {:error, {:missing_required_field, :label}}}
      ]

      opts = real_opts([])

      for {network, address, label, expected} <- cases do
        real = Private.request_approved_address(network, address, label, @credentials, opts)

        assert real == expected
        assert Fake.request_approved_address(network, address, label) == expected
      end
    end

    test "remove: network, then address" do
      cases = [
        {nil, "0xabc", {:error, {:invalid_network, nil}}},
        {"ethereum", "", {:error, {:invalid_address, ""}}},
        {"ethereum", 5, {:error, {:invalid_address, 5}}}
      ]

      for {network, address, expected} <- cases do
        real = Private.remove_approved_address(network, address, @credentials, real_opts([]))

        assert real == expected
        assert Fake.remove_approved_address(network, address) == expected
      end
    end

    test "the list names a usable network" do
      for network <- ["", "  ", :eth, 5] do
        expected = {:error, {:invalid_network, network}}
        real = Private.list_approved_addresses(@credentials, real_opts(network: network))

        assert real == expected
        assert Fake.list_approved_addresses(network: network) == expected
      end
    end

    test "a well-formed request still reaches the venue" do
      me = self()

      assert {:ok, %{"message" => "Approved address addition is now waiting."}} =
               Private.request_approved_address("ethereum", "0xabc", "desk", @credentials,
                 plug: capturing(%{"message" => "Approved address addition is now waiting."}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, %{"address" => "0xabc", "label" => "desk"}}, 5_000
    end
  end

  describe "a value the contract types is returned in that type" do
    @withdrawal %{
      "withdrawalId" => "02176a83-a6b1-4202-9b85-1c1c92dd25c4",
      "address" => "0xabc",
      "amount" => "2.5",
      "currency" => "ETH",
      "fee" => "0.001"
    }

    test "a withdrawal's tx_id is nil: the schema's reply has no txHash to read" do
      cases = ["0xhash", 123, "  ", %{"a" => 1}]

      for sent <- cases do
        assert {:ok, %Withdrawal{tx_id: nil}} =
                 Private.withdraw("ETH", "ethereum", 1, "0xabc", @credentials,
                   plug: responding(Map.put(@withdrawal, "txHash", sent)),
                   retry_attempts: 0
                 )
      end
    end

    test "a withdrawal's amount is a Decimal and its memo a string, whatever was passed" do
      # A float is refused (W4); see write_conventions_test.exs.
      for amount <- [Decimal.new("2.5"), "2.5"] do
        assert {:ok, %Withdrawal{} = withdrawal} =
                 Private.withdraw("ETH", "ethereum", amount, "0xabc", @credentials,
                   memo: 12_345,
                   plug: responding(@withdrawal),
                   retry_attempts: 0
                 )

        assert withdrawal.memo == "12345"
        assert %Decimal{} = withdrawal.amount
        assert Decimal.equal?(withdrawal.amount, Decimal.new("2.5"))
      end

      assert {:ok, %Withdrawal{} = blank_memo} =
               Private.withdraw("ETH", "ethereum", 3, "0xabc", @credentials,
                 memo: "  ",
                 plug: responding(@withdrawal),
                 retry_attempts: 0
               )

      assert blank_memo.memo == nil
      assert blank_memo.amount == Decimal.new("3")
    end

    test "the fake's withdrawal is typed the same way" do
      assert {:ok, %Withdrawal{} = withdrawal} =
               Fake.withdraw("ETH", "ethereum", "2.5", "0xabc",
                 memo: 12_345,
                 client_transfer_id: "  ",
                 credentials: @credentials
               )

      # A blank key is none, so one is generated (a UUID-4), as the real path does (W6).
      assert withdrawal.id =~ ~r/\A[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}\z/
      assert withdrawal.memo == "12345"
      assert withdrawal.amount == Decimal.new("2.5")
    end

    test "a blank memo does not satisfy memo_required in the fake either" do
      for memo <- ["", "  ", nil] do
        opts = [memo: memo, memo_required: true, credentials: @credentials]
        real = Private.withdraw("ETH", "ethereum", 1, "0xabc", @credentials, real_opts(opts))

        assert real == {:error, :memo_required}
        assert Fake.withdraw("ETH", "ethereum", 1, "0xabc", opts) == real
      end

      assert {:ok, %Withdrawal{memo: "0"}} =
               Fake.withdraw("ETH", "ethereum", 1, "0xabc",
                 memo: 0,
                 memo_required: true,
                 credentials: @credentials
               )
    end

    test "the fake's staking, conversion and settlement amounts are Decimals" do
      assert {:ok, %StakingTransaction{amount: stake}} =
               Fake.stake("eth", "1.5", provider_id: "p", credentials: @credentials)

      assert stake == Decimal.new("1.5")

      assert {:ok, %StakingTransaction{} = unstake} =
               Fake.unstake("ETH", 2, provider_id: "p", credentials: @credentials)

      assert unstake.amount == Decimal.new("2")
      assert unstake.amount_remaining == Decimal.new("2")

      opts = [symbol: "GUSD-USD", side: :sell, credentials: @credentials]

      assert {:ok, %Conversion{} = settled} = Fake.convert("GUSD", "USD", "5", opts)
      assert settled.from_amount == Decimal.new("5")
      assert %Decimal{} = settled.to_amount

      assert {:ok, %Conversion{} = quoted} =
               Fake.quote_conversion("GUSD", "USD", Decimal.new("7.5"), opts)

      assert quoted.from_amount == Decimal.new("7.5")

      # A float has already lost digits: refused, as the real path refuses it (W4).
      assert {:error, {:invalid_amount, 7.5}} = Fake.quote_conversion("GUSD", "USD", 7.5, opts)
    end

    test "a committed conversion's id is a string, as the real decode makes it" do
      terms = [
        symbol: "BTC-USD",
        side: :buy,
        amount: Decimal.new("1"),
        price: Decimal.new("100"),
        fee: Decimal.new("0.3"),
        credentials: @credentials
      ]

      assert {:ok, %Conversion{id: "7"}} = Fake.commit_conversion(7, terms)
      assert {:ok, %Conversion{id: "7"}} = Fake.commit_conversion("7", terms)
    end
  end

  describe "the fake's heartbeat answers what the real one does" do
    test "reachable, the environment and the venue's own body" do
      assert {:ok, answer} =
               Private.test_connection(@credentials,
                 plug: responding(%{"result" => "ok"}),
                 retry_attempts: 0
               )

      assert Fake.test_connection(@credentials, []) == {:ok, answer}

      assert {:ok, answer} = Fake.test_connection(@credentials, environment: :sandbox)
      assert answer.environment == :sandbox
    end
  end

  describe "a status the module has no answer for" do
    defp status_plug(status, body) do
      fn conn -> Plug.Conn.resp(conn, status, body) end
    end

    defp erroring_post(plug) do
      Private.get_balances(@credentials, plug: plug, retry_attempts: 0)
    end

    defp erroring_get(plug) do
      Private.list_networks("BTC", credentials: @credentials, plug: plug, retry_attempts: 0)
    end

    test "quotes a small body whole" do
      small = status_plug(502, "nope")

      # A 5xx is worded by Core (0.3.82: "Server error (502): ..."), not by `status_error/2`,
      # since no 4xx but a 429 reaches that function any more.
      assert {:error, {:exchange_error, :gemini, "Server error (502): nope"}} =
               erroring_post(small)

      assert {:error, {:exchange_error, :gemini, "Server error (502): nope"}} =
               erroring_get(small)
    end

    test "a 5xx stays a plain error on a POST and on a signed GET" do
      page = status_plug(502, "gateway down")

      for result <- [erroring_post(page), erroring_get(page)] do
        assert {:error, {:exchange_error, :gemini, message}} = result
        assert message =~ "502"
      end

      big = status_plug(502, String.duplicate("x", 100_000))

      for result <- [erroring_post(big), erroring_get(big)] do
        assert {:error, {:exchange_error, :gemini, message}} = result
        assert byte_size(message) < 4_096
      end
    end

    test "any 4xx but a 429 is a refusal, bounded, on a POST and on a signed GET (DV6)" do
      for status <- [405, 409, 413, 415, 422] do
        small = status_plug(status, "nope")
        assert {:refused, {:unknown_reason, "nope"}} = erroring_post(small)
        assert {:refused, {:unknown_reason, "nope"}} = erroring_get(small)
      end

      page = status_plug(413, String.duplicate("x", 100_000))

      for result <- [erroring_post(page), erroring_get(page)] do
        assert {:refused, {:unknown_reason, text}} = result
        assert String.length(text) < 2_200
      end
    end
  end

  describe "a fill's fee" do
    defp fill_row(extra) do
      Map.merge(
        %{
          "order_id" => "1",
          "tid" => 2,
          "price" => "100",
          "amount" => "0.5",
          "type" => "Buy",
          "aggressor" => false,
          "fee_currency" => "USD",
          "timestampms" => 1_787_936_147_000
        },
        extra
      )
    end

    defp trade_history(row) do
      Private.get_trade_history(@credentials,
        symbol: "BTC-USD",
        plug: responding([row]),
        retry_attempts: 0
      )
    end

    test "is read as the venue's decimal, and absent stays nil" do
      assert {:ok, [fill]} = trade_history(fill_row(%{"fee_amount" => "0.024937655575035"}))
      assert Decimal.equal?(fill.fee, Decimal.new("0.024937655575035"))
      assert fill.liquidity == :maker

      assert {:ok, [fill]} = trade_history(fill_row(%{}))
      assert fill.fee == nil
    end

    test "that is present and unreadable refuses the page instead of becoming nil" do
      for bad <- ["abc", "NaN", "Infinity", %{"x" => 1}] do
        assert {:error, :unexpected_response_shape} =
                 trade_history(fill_row(%{"fee_amount" => bad}))
      end
    end

    test "currency is a string or nil" do
      assert {:ok, [fill]} = trade_history(fill_row(%{"fee_currency" => %{"x" => 1}}))
      assert fill.fee_currency == nil
    end
  end

  describe "a transport failure on an authenticated call" do
    defp timing_out do
      fn conn -> Req.Test.transport_error(conn, :timeout) end
    end

    test "is tagged with the venue, not with the private limiter bucket" do
      opts = [plug: timing_out(), retry_attempts: 1, retry_delay: 1]

      for result <- [
            Private.get_balances(@credentials, opts),
            Private.list_networks("BTC", [credentials: @credentials] ++ opts)
          ] do
        assert {:error, {:exchange_error, :gemini, _reason}} = result
      end
    end
  end

  describe "arguments that used to raise in the caller" do
    test "a payment method's details must be a map, in the real call and the fake" do
      # Never echoed: a keyword list of bank fields is the likeliest mistake.
      keyword_fields = [country: "US", account: "000123456789"]

      for details <- [nil, keyword_fields, "routing", ~D[2026-01-01]] do
        expected = {:error, {:invalid_details, :not_a_map}}

        assert Private.add_payment_method(details, @credentials, real_opts([])) == expected
        assert Fake.add_payment_method(details, credentials: @credentials) == expected
      end
    end

    test "details the JSON encoder cannot write are a refusal to sign, not a raise" do
      assert {:error, :unencodable_payload} =
               Private.add_payment_method(%{"routing" => {1, 2}}, @credentials, real_opts([]))

      assert {:error, :unencodable_payload} =
               Auth.headers(:api_key, "/v1/balances", %{"x" => self()}, @credentials)
    end

    test "an FX pair that is not text is an unsupported pair, not a Protocol.UndefinedError" do
      at = ~U[2026-08-28 12:00:00Z]

      for pair <- [%{}, {:eur, :usd}, ["EUR", "USD"], 5] do
        expected = {:error, {:unsupported_fx_pair, inspect(pair)}}

        assert Private.get_fx_rate(pair, at, real_opts(credentials: @credentials)) == expected
        assert Fake.get_fx_rate(pair, at, credentials: @credentials) == expected
      end

      assert {:error, {:unsupported_fx_pair, "EURJPY"}} = Private.validate_fx_pair("eur-jpy")
      assert {:ok, "EURUSD"} = Private.validate_fx_pair(:"EUR-USD")
    end
  end
end
