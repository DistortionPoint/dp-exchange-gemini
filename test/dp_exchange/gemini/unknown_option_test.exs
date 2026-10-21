defmodule DpExchange.Gemini.UnknownOptionTest do
  @moduledoc """
  An option a facade call does not read is refused, not ignored (family decision, tick AJ).

  A misspelt `limt:` or `sinse:` that was dropped answered a different question from the one
  asked, with a plausible value. Every facade function that takes `opts` answers
  `{:error, {:unknown_option, key}}`, and the Fake answers the same from the same table
  (`DpExchange.Gemini.OptionKeys`). One table-driven test per property, over every function in
  that table, so a function added later without a row here fails the first test below.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{FakeInjection, Venue}
  alias DpExchange.Gemini
  alias DpExchange.Gemini.{Fake, OptionKeys}

  @stray :misspelt
  @credentials %{api_key: "account-k", api_secret: "s"}
  @at ~U[2026-08-28 12:00:00Z]
  @request %{
    symbol: "BTC-USD",
    side: :buy,
    order_type: :limit,
    time_in_force: :gtc,
    quantity: "1",
    price: "1"
  }
  @terms %{symbol: "BTC-USD", side: :buy, amount: "1", price: "2"}
  @amount Decimal.new("1")

  # The positional arguments each function is called with, before `opts`, which is last.
  @positional %{
    get_price: ["BTC-USD"],
    get_top_of_book: ["BTC-USD"],
    get_symbols: [],
    get_market_overview: [],
    get_historical_prices: ["BTC-USD", "1d", []],
    get_order_book: ["BTC-USD"],
    get_trades: ["BTC-USD"],
    list_instruments: [],
    list_fee_promos: [],
    get_staking_rates: [],
    get_funding: ["BTCGUSDPERP"],
    get_contract_stats: ["BTCGUSDPERP"],
    next_funding_timestamp: ["BTCGUSDPERP"],
    market_status: [],
    subscribe: [["BTC-USD"]],
    unsubscribe: [["BTC-USD"]],
    update_symbols: [["BTC-USD"]],
    subscribe_notices: [],
    test_connection: [@credentials],
    get_balances: [@credentials],
    get_accounts: [@credentials],
    get_fees: [@credentials],
    get_transfers: [@credentials],
    place_order: [@credentials, @request],
    cancel_order: [@credentials, "1"],
    get_order: [@credentials, "1"],
    get_orders: [@credentials],
    cancel_all_orders: [@credentials],
    get_trade_history: [@credentials],
    get_transactions: [@credentials],
    get_notional_balances: [@credentials, "usd"],
    list_custody_fees: [@credentials],
    get_trade_volume: [@credentials],
    get_fx_rate: ["EURUSD", @at],
    list_networks: ["ETH"],
    get_deposit_address: ["ETH", "ethereum"],
    list_approved_addresses: [],
    estimate_withdrawal_fee: ["ETH", "ethereum", @amount],
    withdraw: ["ETH", "ethereum", @amount, "0xabc"],
    list_payment_methods: [@credentials],
    add_payment_method: [%{}],
    transfer_internal: ["USD", @amount, [from: "a", to: "b"]],
    request_approved_address: ["ethereum", "0xabc", "desk"],
    remove_approved_address: ["ethereum", "0xabc"],
    get_staking_balances: [],
    get_staking_rewards: [],
    get_staking_history: [],
    stake: ["ETH", @amount],
    unstake: ["ETH", @amount],
    quote_conversion: ["USD", "BTC", @amount],
    commit_conversion: ["1"],
    convert: ["USD", "BTC", @amount],
    get_positions: [],
    get_account_margin: [],
    get_margin_account: [],
    get_margin_rates: [],
    preview_margin_order: [@terms],
    list_funding_payments: [],
    funding_payment_report: [],
    funding_amount_report: ["BTCGUSDPERP"],
    funding_payment_report_file: [],
    create_clearing_order: [@terms],
    create_broker_clearing_order: [@terms],
    get_clearing_order: ["c-1"],
    cancel_clearing_order: ["c-1"],
    confirm_clearing_order: ["c-1", @terms],
    list_clearing_orders: [],
    list_clearing_brokers: [],
    list_clearing_trades: [],
    create_account: [],
    rename_account: ["bot", "Bot"],
    list_accounts: [],
    get_roles: [],
    refresh_access_token: ["client", "refresh"],
    revoke_access_token: []
  }

  # Plain-value reads: no error channel, so they raise.
  @raising [:coverage, :coverage_by_kind, :wanted, :live?]

  # Calls that send no HTTP request. `market_status/1` reads nothing; the feed calls and
  # `live?/1` read `:environment` (it picks the feed) and their own keys, and no other
  # transport key. `:credentials` is accepted on all of them.
  @no_request [:market_status]
  @feed_addressing [
    :subscribe,
    :unsubscribe,
    :update_symbols,
    :subscribe_notices,
    :coverage,
    :coverage_by_kind,
    :wanted,
    :live?
  ]

  # The writes sent exactly once whatever the caller gives (`Private.post_once/5`): they
  # never read `:retry_attempts`.
  @sent_once [
    :place_order,
    :cancel_order,
    :cancel_all_orders,
    :commit_conversion,
    :convert,
    :get_deposit_address,
    :add_payment_method,
    :transfer_internal,
    :request_approved_address,
    :remove_approved_address,
    :stake,
    :unstake,
    :create_account,
    :rename_account,
    :revoke_access_token,
    :create_clearing_order,
    :create_broker_clearing_order,
    :cancel_clearing_order,
    :confirm_clearing_order
  ]

  defp not_read(:refresh_access_token),
    do: [:environment, :base_url, :retry_attempts, :retry_delay]

  defp not_read(function) when function in @sent_once, do: [:retry_attempts, :retry_delay]
  defp not_read(_function), do: []

  defp call(module, function, args, opts), do: apply(module, function, args ++ [opts])

  test "every function in this table has a row in OptionKeys" do
    for function <- Map.keys(@positional) ++ @raising do
      assert OptionKeys.check(function, []) == :ok
    end
  end

  # `OptionKeys.allowed/1` raises `KeyError` for a function with no row, which is how a row is
  # told from its absence.
  defp tabled?(function) do
    is_list(OptionKeys.allowed(function))
  rescue
    KeyError -> false
  end

  test "every facade function with a row in OptionKeys has a row in this file's table" do
    # The moduledoc promises that a function added later without a row here fails a test. The
    # test above only goes one way (this table into OptionKeys), so a new facade function with
    # a table row and no entry in `@positional` was never refused-key checked at all.
    covered = Map.keys(@positional) ++ @raising

    tabled =
      for {function, _arity} <- Gemini.__info__(:functions), tabled?(function), uniq: true do
        function
      end

    assert tabled != [], "no facade function is in the table: the sweep is empty"
    assert tabled -- covered == []
  end

  test "get_order_book answers {:unsupported_option, :limit}, never unknown_option" do
    expected = {:error, {:unsupported_option, :limit}}

    assert Gemini.get_order_book("BTC-USD", limit: 1) == expected
    assert Fake.get_order_book("BTC-USD", limit: 1) == expected
  end

  test "every facade function refuses a key nothing reads, and sends nothing" do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {:request_reached_plug, conn.request_path})
      raise "a refused option must not reach the network"
    end

    opts = [{@stray, true}, plug: plug, credentials: @credentials, retry_attempts: 0]

    for {function, args} <- @positional do
      assert call(Gemini, function, args, opts) == {:error, {:unknown_option, @stray}},
             "Gemini.#{function} must refuse #{inspect(@stray)}"
    end

    refute_receive {:request_reached_plug, _path}, 500
  end

  test "every Fake function refuses it too, before failure injection is consulted" do
    # If the check ran after the injection, this outcome would be the answer instead.
    FakeInjection.fail_always(:gemini, {:error, :injection_was_consulted})

    opts = [{@stray, true}, credentials: @credentials]

    for {function, args} <- @positional do
      assert call(Fake, function, args, opts) == {:error, {:unknown_option, @stray}},
             "Fake.#{function} must refuse #{inspect(@stray)}"
    end
  end

  test "options that are not a keyword list are refused on the facade and on the Fake" do
    for {function, args} <- @positional, module <- [Gemini, Fake] do
      assert call(module, function, args, %{not: :keyword}) ==
               {:error, {:invalid_options, %{not: :keyword}}},
             "#{inspect(module)}.#{function} must refuse a map as options"
    end
  end

  test "a key holding nil is still a key" do
    assert Gemini.get_trades("BTC-USD", limt: nil) == {:error, {:unknown_option, :limt}}
    assert Fake.get_trades("BTC-USD", limt: nil) == {:error, {:unknown_option, :limt}}
  end

  test "the first stray key, in the caller's order, is the one named" do
    opts = [limit: 1, sinse: 2, tid: 3]

    assert Gemini.get_trades("BTC-USD", opts) == {:error, {:unknown_option, :sinse}}
    assert Fake.get_trades("BTC-USD", opts) == {:error, {:unknown_option, :sinse}}
  end

  test "the plain-value reads raise ArgumentError for a stray key and for non-keyword options" do
    for module <- [Gemini, Fake], function <- @raising do
      assert_raise ArgumentError, fn -> call(module, function, [], [{@stray, true}]) end
      assert_raise ArgumentError, fn -> call(module, function, [], %{not: :keyword}) end
    end
  end

  test "the plain-value reads still answer for the keys they read" do
    assert Gemini.coverage(feed: :no_such_gemini_feed_for_unknown_option_test) == %{}
    assert Gemini.wanted(feed: :no_such_gemini_feed_for_unknown_option_test) == []
    assert Fake.coverage() == %{}
    assert Fake.wanted([]) == []
    assert Gemini.live?(environment: :sandbox) == false
    assert Fake.live?(environment: :sandbox) == false
  end

  describe "the check order: positional arguments, then options, then credentials" do
    test "a symbol that is not a symbol is named before a stray key" do
      expected = {:error, {:invalid_symbol, ""}}

      for module <- [Gemini, Fake], function <- [:get_price, :get_top_of_book, :get_trades] do
        assert call(module, function, [""], [{@stray, true}]) == expected
      end
    end

    test "symbols are named before a stray key on the streaming calls" do
      expected = {:error, {:invalid_symbols, nil}}

      for module <- [Gemini, Fake], function <- [:subscribe, :unsubscribe, :update_symbols] do
        assert call(module, function, [nil], [{@stray, true}]) == expected
      end
    end

    test "a stray key is named before the missing credential" do
      expected = {:error, {:unknown_option, @stray}}

      assert Gemini.get_balances(%{}, [{@stray, true}]) == expected
      assert Fake.get_balances(%{}, [{@stray, true}]) == expected
      assert Gemini.list_approved_addresses([{@stray, true}]) == expected
      assert Fake.list_approved_addresses([{@stray, true}]) == expected
    end
  end

  describe "a misspelling of a real option" do
    test "is refused on the call that reads the correct spelling" do
      for {function, args, wrong} <- [
            {:get_trades, ["BTC-USD"], :sinse},
            {:get_order_book, ["BTC-USD"], :dept},
            {:get_orders, [@credentials], :limt},
            {:get_staking_history, [], :provider},
            {:withdraw, ["ETH", "ethereum", @amount, "0xabc"], :clientTransferId}
          ],
          module <- [Gemini, Fake] do
        assert call(module, function, args, [{wrong, 1}]) == {:error, {:unknown_option, wrong}}
      end
    end

    test "a real option of another function is a stray here" do
      # `:limit` belongs to the history reads, not to a price, and `:depth` is the book's.
      assert Gemini.get_price("BTC-USD", limit: 1) == {:error, {:unknown_option, :limit}}
      assert Fake.get_price("BTC-USD", limit: 1) == {:error, {:unknown_option, :limit}}
      assert Gemini.get_trades("BTC-USD", depth: 1) == {:error, {:unknown_option, :depth}}
      assert Fake.get_trades("BTC-USD", depth: 1) == {:error, {:unknown_option, :depth}}
    end

    test "a funding payment report takes no symbol, and a staked write takes no :since" do
      assert Gemini.funding_payment_report(symbol: "BTCGUSDPERP") ==
               {:error, {:unknown_option, :symbol}}

      assert Fake.funding_payment_report_file(symbol: "BTCGUSDPERP") ==
               {:error, {:unknown_option, :symbol}}

      assert Gemini.stake("ETH", @amount, since: 1) == {:error, {:unknown_option, :since}}
      assert Fake.unstake("ETH", @amount, since: 1) == {:error, {:unknown_option, :since}}
    end

    test "rename_account/3 takes its account and new name as arguments, not options" do
      assert Gemini.rename_account("bot", "Bot", account: "other") ==
               {:error, {:unknown_option, :account}}

      assert Fake.rename_account("bot", "Bot", name: "Other") ==
               {:error, {:unknown_option, :name}}
    end
  end

  describe "transfer_internal/4 terms" do
    test "an unknown key in the terms is refused, and so are terms that are not keywords" do
      for module <- [Gemini, Fake] do
        assert module.transfer_internal("USD", @amount, [from: "a", to: "b", too: "c"], []) ==
                 {:error, {:unknown_option, :too}}

        assert module.transfer_internal("USD", @amount, %{from: "a", to: "b"}, []) ==
                 {:error, {:invalid_options, %{from: "a", to: "b"}}}
      end
    end

    test "the terms are named before a stray option" do
      for module <- [Gemini, Fake] do
        assert module.transfer_internal("USD", @amount, [too: "c"], [{@stray, true}]) ==
                 {:error, {:unknown_option, :too}}
      end
    end
  end

  describe "the table itself" do
    test "a call that sends a request accepts every shared transport key it can honour" do
      transport = DpExchange.Core.Options.transport_options()
      no_request = @no_request ++ @feed_addressing

      for function <- Map.keys(@positional) ++ @raising,
          function not in no_request,
          key <- transport do
        expected =
          if key in not_read(function), do: {:error, {:unknown_option, key}}, else: :ok

        assert OptionKeys.check(function, [{key, nil}]) == expected,
               "#{function} and the transport key #{inspect(key)}"
      end
    end

    test "the keys a request-sending call does not read are named, with the table's reasons" do
      assert OptionKeys.not_read(:get_price) == []
      assert OptionKeys.not_read(:get_balances) == []
      assert OptionKeys.not_read(:place_order) == [:retry_attempts, :retry_delay]

      assert OptionKeys.not_read(:refresh_access_token) ==
               [:environment, :base_url, :retry_attempts, :retry_delay]

      assert OptionKeys.not_read(:market_status) == []
    end

    test "a function accepts the keys it reads and nothing else" do
      own = [since: 1, since_tid: 2, limit: 3, include_broken: true]

      assert OptionKeys.check(:get_trades, own) == :ok

      assert OptionKeys.check(:get_trades, include_partial: true) ==
               {:error, {:unknown_option, :include_partial}}

      refute :depth in OptionKeys.allowed(:get_price)
      assert :depth in OptionKeys.allowed(:get_order_book)
    end

    test "the group-level calls do not accept an account, the signed ones do" do
      for function <- [:create_account, :rename_account, :list_accounts, :get_roles] do
        assert OptionKeys.check(function, account: "a") == {:error, {:unknown_option, :account}}
      end

      assert OptionKeys.check(:get_balances, account: "a") == :ok
      assert OptionKeys.check(:place_order, account: "a", nonce_mode: :incremental) == :ok
    end

    test "check_terms/2 accepts the terms' keys and refuses the transport ones" do
      assert OptionKeys.check_terms(:transfer_internal, from: "a", to: "b") == :ok
      assert OptionKeys.check_terms(:transfer_internal, credentials: %{}) == :ok

      assert OptionKeys.check_terms(:transfer_internal, plug: nil) ==
               {:error, {:unknown_option, :plug}}
    end
  end

  describe "an endpoint the venue does not serve" do
    test "keeps answering :not_supported whatever the options" do
      expected = Venue.not_supported()

      for module <- [Gemini, Fake] do
        assert module.get_option_chain("BTC", [{@stray, true}]) == expected
        assert module.list_watchlists([{@stray, true}]) == expected
        assert module.get_rate_limit_status(@credentials, [{@stray, true}]) == expected
        assert module.get_conversion("1", [{@stray, true}]) == expected
      end
    end
  end

  describe "an OAuth call cannot carry :account" do
    @oauth %{access_token: "oauth-token-not-real"}
    @unsupported {:error, {:unsupported_option, :account}}

    test "a signed POST and a signed GET refuse it before any request" do
      exploding = fn _conn -> raise "must not reach the venue" end
      opts = [account: "sub", plug: exploding, retry_attempts: 0]

      assert Gemini.get_balances(@oauth, opts) == @unsupported
      assert Gemini.list_networks("BTC", [{:credentials, @oauth} | opts]) == @unsupported
    end

    test "the Fake refuses it the same way, and answers without :account" do
      assert Fake.get_balances(@oauth, account: "sub") == @unsupported
      assert Fake.list_networks("BTC", credentials: @oauth, account: "sub") == @unsupported
      # Answers, rather than merely not being this one refusal: any other error would pass a
      # bare `refute match?`.
      assert {:ok, [_balance | _rest]} = Fake.get_balances(@oauth, [])
    end

    test "an API key still carries :account" do
      assert {:ok, [_balance | _rest]} = Fake.get_balances(@credentials, account: "sub")
    end
  end

  describe "revoke_access_token reads no option of its own" do
    test "a stray :account is refused, on the facade and on the Fake" do
      opts = [credentials: %{access_token: "token"}, account: "sub"]
      expected = {:error, {:unknown_option, :account}}

      assert Gemini.revoke_access_token(opts) == expected
      assert Fake.revoke_access_token(opts) == expected
      transport = DpExchange.Core.Options.transport_options()

      # Its own table entry is empty. `:name` is the tree's (it picks the limiter), not its own.
      assert OptionKeys.allowed(:revoke_access_token) ==
               (transport -- [:retry_attempts, :retry_delay]) ++ [:name]
    end
  end

  describe "a call that sends no request reads no transport key but its own" do
    test "timeout: 5_000 is refused on the facade and on the Fake" do
      calls = [
        {:subscribe, [["BTC-USD"]]},
        {:unsubscribe, [["BTC-USD"]]},
        {:update_symbols, [["BTC-USD"]]},
        {:subscribe_notices, []},
        {:market_status, []}
      ]

      for {function, args} <- calls, module <- [Gemini, Fake] do
        assert call(module, function, args, timeout: 5_000) ==
                 {:error, {:unknown_option, :timeout}},
               "#{inspect(module)}.#{function} reads no :timeout"
      end
    end

    test "the plain-value reads raise on a transport key they cannot read" do
      for module <- [Gemini, Fake], function <- @raising, key <- [:timeout, :weight, :plug] do
        assert_raise ArgumentError, fn -> call(module, function, [], [{key, 5_000}]) end
      end
    end

    test "only :credentials, and :environment where it picks the feed, are accepted" do
      transport = DpExchange.Core.Options.transport_options()

      for key <- transport -- [:credentials] do
        assert OptionKeys.check(:market_status, [{key, nil}]) ==
                 {:error, {:unknown_option, key}}
      end

      assert OptionKeys.check(:market_status, credentials: nil) == :ok

      for function <- @feed_addressing, key <- transport -- [:credentials, :environment] do
        assert OptionKeys.check(function, [{key, nil}]) == {:error, {:unknown_option, key}},
               "#{function} reads no #{inspect(key)}"
      end

      for function <- @feed_addressing, key <- [:credentials, :environment] do
        assert OptionKeys.check(function, [{key, nil}]) == :ok
      end
    end

    test "a feed call still answers for the keys it reads" do
      feed = :no_such_gemini_feed_for_transport_key_test

      assert Gemini.subscribe(["BTC-USD"], feed: feed, to: self(), environment: :sandbox) ==
               {:error, :feed_not_started}

      assert Gemini.coverage(feed: feed, credentials: nil) == %{}
    end
  end

  describe "a call that sends a request refuses the keys it can never honour" do
    test "a sent-once write refuses :retry_attempts on the facade and the Fake" do
      assert Gemini.place_order(@credentials, @request, retry_attempts: 0) ==
               {:error, {:unknown_option, :retry_attempts}}

      assert Fake.place_order(@credentials, @request, retry_attempts: 0) ==
               {:error, {:unknown_option, :retry_attempts}}

      assert Gemini.cancel_order(@credentials, "1", retry_attempts: 3) ==
               {:error, {:unknown_option, :retry_attempts}}

      # `withdraw` always sends a `clientTransferId` (an idempotency key), so it is retried and
      # keeps both retry keys: the table accepts them, and the Fake does not refuse them.
      assert OptionKeys.check(:withdraw, retry_attempts: 3, retry_delay: 1) == :ok

      for key <- [:retry_attempts, :retry_delay] do
        refute Fake.withdraw("ETH", "ethereum", @amount, "0xabc", [{key, 3}]) ==
                 {:error, {:unknown_option, key}}
      end
    end

    test "a sent-once write refuses :retry_delay on the facade and the Fake" do
      assert Gemini.place_order(@credentials, @request, retry_delay: 1) ==
               {:error, {:unknown_option, :retry_delay}}

      assert Fake.place_order(@credentials, @request, retry_delay: 1) ==
               {:error, {:unknown_option, :retry_delay}}

      assert Gemini.cancel_order(@credentials, "1", retry_delay: 0) ==
               {:error, {:unknown_option, :retry_delay}}

      assert Fake.cancel_order(@credentials, "1", retry_delay: 0) ==
               {:error, {:unknown_option, :retry_delay}}
    end

    test "every sent-once write refuses both retry keys at the table" do
      for function <- @sent_once, key <- [:retry_attempts, :retry_delay] do
        assert OptionKeys.check(function, [{key, 1}]) == {:error, {:unknown_option, key}},
               "#{function} must refuse #{inspect(key)}"
      end
    end

    test "the OAuth refresh refuses the environment, the base URL and both retry keys" do
      keys = [:environment, :base_url, :retry_attempts, :retry_delay]

      for key <- keys, module <- [Gemini, Fake] do
        assert module.refresh_access_token("client", "refresh", [{key, nil}]) ==
                 {:error, {:unknown_option, key}}
      end
    end
  end

  describe "the shared transport keys reach Core.HttpClient" do
    defmodule WeightLimiter do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      def acquire(_provider, weight, _opts), do: report(weight)
      @impl true
      def check(_provider, weight, _opts), do: report(weight)
      @impl true
      def record(_provider, _weight, _opts), do: :ok

      defp report(weight) do
        send(self(), {:limiter_weight, weight})
        :ok
      end
    end

    @date "Fri, 28 Aug 2026 17:00:01 GMT"
    @ticker %{
      "bid" => "77791.77",
      "ask" => "77791.92",
      "last" => "77829.80",
      "volume" => %{"BTC" => "183.72", "USD" => "14298954.22", "timestamp" => 1_787_936_340_000}
    }

    setup do
      DpExchange.Core.Config.put_override(:rate_limit_module, WeightLimiter)
      :ok
    end

    defp responding(body) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json(body)
      end
    end

    test "weight: 7 is what the limiter is asked for, on a public read" do
      assert {:ok, _quote} =
               Gemini.get_price("BTC-USD",
                 plug: responding(@ticker),
                 weight: 7,
                 retry_attempts: 0
               )

      assert_receive {:limiter_weight, 7}, 5_000
    end

    test "weight: 7 is what the limiter is asked for, on a signed read" do
      assert {:ok, _balances} =
               Gemini.get_balances(@credentials,
                 plug: responding([]),
                 weight: 7,
                 retry_attempts: 0
               )

      assert_receive {:limiter_weight, 7}, 5_000
    end

    test "max_body_bytes refuses a body over the cap, on a public and on a signed read" do
      expected = {:error, {:exchange_error, :gemini, {:response_too_large, 10}}}

      assert Gemini.get_price("BTC-USD",
               plug: responding(@ticker),
               max_body_bytes: 10,
               retry_attempts: 0
             ) == expected

      assert Gemini.get_balances(@credentials,
               plug: responding([%{"currency" => "USD", "amount" => "1", "available" => "1"}]),
               max_body_bytes: 10,
               retry_attempts: 0
             ) == expected
    end
  end

  describe "the conformance probe" do
    test "get_price, get_top_of_book, get_symbols, get_order_book and get_trades on the Fake" do
      probe = DpExchange.Core.AdapterContract.unknown_option_probe()
      expected = {:error, {:unknown_option, probe}}

      assert Fake.get_price("BTC-USD", [{probe, true}]) == expected
      assert Fake.get_top_of_book("BTC-USD", [{probe, true}]) == expected
      assert Fake.get_symbols([{probe, true}]) == expected
      assert Fake.get_order_book("BTC-USD", [{probe, true}]) == expected
      assert Fake.get_trades("BTC-USD", [{probe, true}]) == expected
    end
  end
end
