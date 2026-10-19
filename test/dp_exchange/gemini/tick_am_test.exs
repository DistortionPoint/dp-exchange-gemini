defmodule DpExchange.Gemini.TickAMTest do
  @moduledoc """
  Tick AM: the venue's documented list filters are reachable, the decoders read only fields the
  vendor's schema names, and the socket reports what it used to drop or repeat.

  * **Filters.** `/v1/clearing/list`, `/v1/clearing/broker/list` and `/v1/clearing/trades`
    document filters the facade could not pass (`funded`, `status`, `timestamp`,
    `limit_orders`, `limit_trades`, the broker listing's submission window), as do
    `/v2/transfers` (`show_completed_deposit_advances`) and the staking reads (`currency`,
    `interestOnly`, `sortAsc`). Each is an option with the same check on the real path and the
    Fake, and each is sent only when given.
  * **Schema.** A fee estimate, a staking write and a withdrawal no longer read field names the
    vendor's schema does not have.
  * **Socket.** One `link_down` per `link_up` however many reconnects fail, a text frame that
    is not a JSON object raises a notice, and a depth diff in flight after an unsubscribe is
    not delivered as the absolute book.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Gemini
  alias DpExchange.Gemini.{Fake, OptionKeys, Private, Socket}

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
  @terms %{symbol: "btcusd", amount: "1", price: "2", side: :buy}

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

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

  defp creds(extra), do: Keyword.merge([credentials: @credentials], extra)

  describe "the clearing listings pass every documented filter" do
    test "list_clearing_orders sends funded, status, timestamp and limit_orders when given" do
      me = self()

      assert {:ok, []} =
               Private.list_clearing_orders(@credentials,
                 funded: false,
                 status: "AwaitTargetConfirm",
                 timestamp: ~U[2026-08-28 17:00:01Z],
                 limit_orders: 25,
                 plug: capturing(%{"orders" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/list"}, 5_000
      # `false` is a value, not an absence.
      assert payload["funded"] == false
      assert payload["status"] == "AwaitTargetConfirm"
      assert payload["timestamp"] == 1_787_936_401_000
      assert payload["limit_orders"] == 25
    end

    test "nothing is sent that was not asked for" do
      me = self()

      assert {:ok, []} =
               Private.list_clearing_orders(@credentials,
                 plug: capturing(%{"orders" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}, 5_000
      assert Enum.sort(Map.keys(payload)) == ["nonce", "request"]
    end

    test "list_clearing_brokers sends the submission window and the shared filters" do
      me = self()

      assert {:ok, []} =
               Private.list_clearing_brokers(@credentials,
                 symbol: "BTC-EUR",
                 submission_start: ~U[2026-08-01 00:00:00Z],
                 submission_end: ~U[2026-08-02 00:00:00Z],
                 funded: true,
                 status: "AwaitSourceConfirm",
                 timestamp: 1_785_542_400_000,
                 limit_orders: 3,
                 plug: capturing(%{"orders" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/broker/list"}, 5_000
      assert payload["symbol"] == "btceur"
      assert payload["submission_start"] == 1_785_542_400_000
      assert payload["submission_end"] == 1_785_628_800_000
      assert payload["funded"] == true
      assert payload["status"] == "AwaitSourceConfirm"
      assert payload["timestamp"] == 1_785_542_400_000
      assert payload["limit_orders"] == 3
    end

    test "a broker listing's submission window needs both bounds, as the orders listing's does" do
      assert {:error, {:window_needs_both_bounds, :submission}} =
               Private.list_clearing_brokers(@credentials,
                 submission_start: ~U[2026-08-01 00:00:00Z],
                 plug: exploding(),
                 retry_attempts: 0
               )
    end

    test "a filter of the wrong type is refused before a request goes out, on both listings" do
      bad = [
        funded: "yes",
        status: "",
        timestamp: "soon",
        limit_orders: 0,
        limit_orders: "ten"
      ]

      for {key, value} <- bad, call <- [:list_clearing_orders, :list_clearing_brokers] do
        assert {:error, {:invalid_option, ^key, ^value}} =
                 apply(Private, call, [
                   @credentials,
                   [{key, value}, plug: exploding(), retry_attempts: 0]
                 ])

        assert apply(Fake, call, [creds([{key, value}])]) ==
                 {:error, {:invalid_option, key, value}}
      end
    end

    test "list_clearing_trades sends the venue's timestamp and limit_trades when given" do
      me = self()

      assert {:ok, []} =
               Private.list_clearing_trades(@credentials,
                 timestamp: ~U[2026-08-28 17:00:01Z],
                 limit_trades: 20,
                 plug: capturing(%{"results" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/clearing/trades"}, 5_000
      assert payload["timestamp"] == 1_787_936_401_000
      assert payload["limit_trades"] == 20
      # The default page size is for a caller who named none; `limit_trades` is the page size.
      refute Map.has_key?(payload, "limit_per_account")
      refute Map.has_key?(payload, "timestamp_nanos")
    end

    test "a full page taken with limit_trades is one page on purpose, not a truncation" do
      rows = for n <- 1..300, do: %{"clearingId" => "c-#{n}"}

      assert {:ok, ^rows} =
               Private.list_clearing_trades(@credentials,
                 limit_trades: 300,
                 plug: responding(%{"results" => rows}),
                 retry_attempts: 0
               )
    end

    test "naming both spellings of one ask is refused, not guessed at" do
      assert {:error, {:conflicting_options, [:since_nanos, :timestamp]}} =
               Private.list_clearing_trades(@credentials,
                 since_nanos: 1,
                 timestamp: 1,
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert {:error, {:conflicting_options, [:limit, :limit_trades]}} =
               Private.list_clearing_trades(@credentials,
                 limit: 5,
                 limit_trades: 5,
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert Fake.list_clearing_trades(creds(since_nanos: 1, timestamp: 1)) ==
               {:error, {:conflicting_options, [:since_nanos, :timestamp]}}

      assert Fake.list_clearing_trades(creds(limit: 5, limit_trades: 5)) ==
               {:error, {:conflicting_options, [:limit, :limit_trades]}}
    end

    test "the option table accepts the new keys and still refuses a stray one" do
      for key <- [:funded, :status, :timestamp, :limit_orders] do
        assert key in OptionKeys.allowed(:list_clearing_orders)
        assert key in OptionKeys.allowed(:list_clearing_brokers)
      end

      assert :submission_start in OptionKeys.allowed(:list_clearing_brokers)
      assert :submission_end in OptionKeys.allowed(:list_clearing_brokers)
      assert :timestamp in OptionKeys.allowed(:list_clearing_trades)
      assert :limit_trades in OptionKeys.allowed(:list_clearing_trades)
      refute :side in OptionKeys.allowed(:list_clearing_brokers)

      assert Gemini.list_clearing_orders(credentials: @credentials, misspelt: true) ==
               {:error, {:unknown_option, :misspelt}}

      stray = [credentials: @credentials, side: :buy, limit_orders: 0]

      assert Gemini.list_clearing_orders(stray) ==
               {:error, {:invalid_option, :limit_orders, 0}}
    end
  end

  describe "the Fake narrows by the filters the venue documents" do
    test "counterparty, status, windows, timestamp and limit_orders narrow the fixed rows" do
      assert {:ok, [%{"clearing_id" => "9LVQE9X5"}]} =
               Fake.list_clearing_orders(creds(counterparty: "YZ43LX81"))

      assert {:ok, [%{"clearing_id" => "2MYR07XP"}]} =
               Fake.list_clearing_orders(creds(status: "AwaitSourceConfirm"))

      assert {:ok, [_first, _second]} = Fake.list_clearing_orders(creds(limit_orders: 5))
      assert {:ok, [_first]} = Fake.list_clearing_orders(creds(limit_orders: 1))

      # Only the second row expires inside this window.
      assert {:ok, [%{"clearing_id" => "2MYR07XP"}]} =
               Fake.list_clearing_orders(
                 creds(expiration_start: 1_642_000_000_000, expiration_end: 1_642_300_000_000)
               )

      # Only the first row was submitted after this instant (its `submission` is 020, the
      # second's 016).
      assert {:ok, [%{"clearing_id" => "9LVQE9X5"}]} =
               Fake.list_clearing_orders(creds(timestamp: 1_641_790_800_017))

      assert {:ok, []} =
               Fake.list_clearing_orders(creds(submission_start: 1, submission_end: 2))
    end

    test "funded is validated and accepted, and narrows nothing" do
      assert {:ok, [_first, _second]} = Fake.list_clearing_orders(creds(funded: true))
      assert {:ok, [_first, _second]} = Fake.list_clearing_orders(creds(funded: false))
    end

    test "the broker listing narrows by symbol, status and windows too" do
      assert {:ok, [%{"clearing_id" => "9LVQ98X5"}]} = Fake.list_clearing_brokers(creds([]))
      assert {:ok, []} = Fake.list_clearing_brokers(creds(symbol: "ethusd"))
      assert {:ok, []} = Fake.list_clearing_brokers(creds(status: "Settled"))
      assert {:ok, [_row]} = Fake.list_clearing_brokers(creds(limit_orders: 1))

      assert {:ok, []} =
               Fake.list_clearing_brokers(creds(submission_start: 1, submission_end: 2))
    end

    test "the clearing rows carry the quantity the vendor's example rows do" do
      assert {:ok, rows} = Fake.list_clearing_orders(creds([]))
      assert Enum.map(rows, & &1["quantity"]) == [10, 50]
    end

    test "limit_trades takes the first rows like limit does" do
      assert {:ok, [_one]} = Fake.list_clearing_trades(creds(limit_trades: 1))

      assert Fake.list_clearing_trades(limit_trades: 0) ==
               {:error, {:invalid_option, :limit_trades, 0}}
    end

    test "a clearing order's state names is_confirmed, the field its own docs say to read" do
      assert {:ok, %{"is_confirmed" => true, "clearing_id" => "c-1"}} =
               Fake.get_clearing_order("c-1", creds([]))

      assert {:ok, %{"is_confirmed" => false}} = Fake.create_clearing_order(@terms, creds([]))
    end
  end

  describe "transfers and staking reads pass the filters the venue documents" do
    test "get_transfers sends show_completed_deposit_advances, false included" do
      me = self()

      for value <- [false, true] do
        assert {:ok, []} =
                 Private.get_transfers(@credentials,
                   show_completed_deposit_advances: value,
                   plug: capturing([], me),
                   retry_attempts: 0
                 )

        assert_receive {:payload, payload, "/v2/transfers"}, 5_000
        assert payload["show_completed_deposit_advances"] == value
      end

      assert {:ok, []} =
               Private.get_transfers(@credentials, plug: capturing([], me), retry_attempts: 0)

      assert_receive {:payload, payload, "/v2/transfers"}, 5_000
      refute Map.has_key?(payload, "show_completed_deposit_advances")
    end

    test "a non-boolean show_completed_deposit_advances is refused, real path and Fake" do
      assert {:error, {:invalid_option, :show_completed_deposit_advances, "no"}} =
               Private.get_transfers(@credentials,
                 show_completed_deposit_advances: "no",
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert Fake.get_transfers(@credentials, show_completed_deposit_advances: "no") ==
               {:error, {:invalid_option, :show_completed_deposit_advances, "no"}}
    end

    test "get_staking_history sends currency, interestOnly and sortAsc when given" do
      me = self()

      assert {:ok, []} =
               Private.get_staking_history(@credentials,
                 currency: "ETH",
                 interest_only: false,
                 sort_asc: true,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/staking/history"}, 5_000
      assert payload["currency"] == "ETH"
      assert payload["interestOnly"] == false
      assert payload["sortAsc"] == true
    end

    test "get_staking_rewards sends currency, beside the required since" do
      me = self()

      assert {:ok, []} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-01 00:00:00Z],
                 currency: "ETH",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/staking/rewards"}, 5_000
      assert payload["currency"] == "ETH"
    end

    test "the staking filters are checked before a request goes out, Fake alike" do
      assert {:error, {:invalid_option, :interest_only, 1}} =
               Private.get_staking_history(@credentials,
                 interest_only: 1,
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert {:error, {:invalid_option, :currency, ""}} =
               Private.get_staking_rewards(@credentials,
                 since: ~U[2026-08-01 00:00:00Z],
                 currency: "",
                 plug: exploding(),
                 retry_attempts: 0
               )

      assert Fake.get_staking_history(creds(sort_asc: "up")) ==
               {:error, {:invalid_option, :sort_asc, "up"}}

      assert Fake.get_staking_rewards(creds(since: "2026-08-01T00:00:00Z", currency: "")) ==
               {:error, {:invalid_option, :currency, ""}}
    end

    test "the Fake narrows staking reads by currency, interest_only and order" do
      assert {:ok, [_row]} = Fake.get_staking_history(creds(currency: "eth"))
      assert {:ok, []} = Fake.get_staking_history(creds(currency: "btc"))
      assert {:ok, []} = Fake.get_staking_history(creds(interest_only: true))
      assert {:ok, [_row]} = Fake.get_staking_history(creds(interest_only: false, sort_asc: true))

      since = [since: "2026-08-01T00:00:00Z"]
      assert {:ok, [_row]} = Fake.get_staking_rewards(creds([{:currency, "ETH"} | since]))
      assert {:ok, []} = Fake.get_staking_rewards(creds([{:currency, "SOL"} | since]))
    end

    test "the option table lists the new keys" do
      assert :show_completed_deposit_advances in OptionKeys.allowed(:get_transfers)
      assert :currency in OptionKeys.allowed(:get_staking_rewards)

      for key <- [:currency, :interest_only, :sort_asc] do
        assert key in OptionKeys.allowed(:get_staking_history)
      end

      # `showPendingBalances` is deliberately not exposed (the Balance type cannot carry it).
      refute :show_pending_balances in OptionKeys.allowed(:get_balances)
    end
  end

  describe "decoders read only the fields the vendor's schema names" do
    defp estimate(body) do
      Private.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("0.01"), @credentials,
        address: "0xabc",
        plug: responding(body),
        retry_attempts: 0
      )
    end

    test "a fee estimate is read from fee and currency, not from transfer-row spellings" do
      # `feeAmount` and `feeCurrency` are `/v2/transfers` row names; the estimate has neither.
      assert {:error, :unexpected_response_shape} = estimate(%{"feeAmount" => "0.001"})

      assert {:ok, %{fee_currency: nil}} =
               estimate(%{"fee" => "0.001", "feeCurrency" => "ETH"})

      assert {:ok, %{fee_currency: "ETH"}} =
               estimate(%{"fee" => "0.001", "currency" => "ETH"})
    end

    test "a staking write's id is its transactionId, not a field named id" do
      reply = %{"id" => "stk-1", "currency" => "ETH", "amount" => "1"}

      assert {:error, {:write_unconfirmed, nil, {:missing_required_field, :id}}} =
               Private.stake("ETH", Decimal.new("1"), @credentials,
                 provider_id: "p-1",
                 plug: responding(reply),
                 retry_attempts: 0
               )

      assert {:ok, %{id: "stk-1"}} =
               Private.stake("ETH", Decimal.new("1"), @credentials,
                 provider_id: "p-1",
                 plug: responding(Map.put(reply, "transactionId", "stk-1")),
                 retry_attempts: 0
               )
    end

    test "a withdrawal's id is the venue's withdrawalId or the key that was sent" do
      assert {:ok, withdrawal} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 client_transfer_id: "mine-1",
                 plug: responding(%{"clientTransferId" => "venue-says-other"}),
                 retry_attempts: 0
               )

      assert withdrawal.id == "mine-1"

      assert {:ok, %{tx_id: nil}} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 plug: responding(%{"withdrawalId" => "w-1", "txn_hash" => "0xinvented"}),
                 retry_attempts: 0
               )
    end
  end

  describe "the socket reports what it used to drop or repeat" do
    defp socket_state(overrides \\ %{}) do
      Map.merge(
        %{
          subscriber: self(),
          request_id: 0,
          connected_once?: false,
          last_heard_at: nil,
          liveness: nil
        },
        overrides
      )
    end

    test "text that is not a JSON object raises one notice and never its text" do
      for raw <- ["{not json", "[1, 2]", "\"just a string\"", "5", "null"] do
        assert {:ok, _state} = Socket.handle_frame({:text, raw}, socket_state())

        assert_received {:dp_exchange, :gemini,
                         %Notice{
                           kind: :data_quality,
                           details: %{reason: :undecodable_frame, bytes: bytes} = details
                         }}

        assert bytes == byte_size(raw)
        refute Map.has_key?(details, :text)
        refute_received {:dp_exchange, :gemini, _anything}
      end
    end

    test "an answer whose status is not a number is reported as refused, not a crash" do
      for status <- [%{"x" => 1}, [1, 2], "teapot", nil, 4.5] do
        frame = Jason.encode!(%{"id" => 7, "status" => status})
        assert {:ok, _state} = Socket.handle_frame({:text, frame}, socket_state())

        assert_received {:dp_exchange, :gemini, %Notice{kind: :refusal} = notice}
        assert notice.details.reason == :subscribe_refused
        assert is_binary(notice.message)
        refute_received {:dp_exchange, :gemini, _anything}
      end

      # The documented integer status is unchanged.
      frame = Jason.encode!(%{"id" => 7, "status" => 400})
      assert {:ok, _state} = Socket.handle_frame({:text, frame}, socket_state())

      assert_received {:dp_exchange, :gemini,
                       %Notice{details: %{subscribe_status: 400}, message: message}}

      assert message == "gemini refused a subscription: status 400"
    end

    test "a JSON object this package does not model is still ignored without a notice" do
      assert {:ok, _state} =
               Socket.handle_frame({:text, Jason.encode!(%{"e" => "kline"})}, socket_state())

      refute_received {:dp_exchange, :gemini, _anything}
    end

    test "the loss of a connection is reported once however many reconnects then fail" do
      assert {:ok, connected} = Socket.handle_connect(:conn, socket_state())
      assert connected.link_open?
      assert_received {:dp_exchange, :gemini, %Notice{kind: :link_up}}

      # A session that lasted, so the first drop reconnects at once (no short-session backoff).
      lasted = %{connected | connected_at: System.monotonic_time(:millisecond) - 60_000}

      assert {:reconnect, down} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, lasted)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :link_down}}
      refute down.link_open?

      # `websockex` calls the callback again for each reconnect that fails; the link is already
      # reported down, and each attempt is still visible on its own event.
      reconnect_attempts = attach_reconnect_attempts()

      failed_again = %{reason: {:error, :econnrefused}, attempt_number: 2}
      assert {:reconnect, still_down} = Socket.handle_disconnect(failed_again, down)

      refute_received {:dp_exchange, :gemini, %Notice{kind: :link_down}}
      refute still_down.link_open?
      assert_receive {^reconnect_attempts, %{attempt: 2}}, 5_000
    end

    test "a connect that follows reopens the link, so its loss is reported again" do
      assert {:ok, connected} = Socket.handle_connect(:conn, socket_state(%{link_open?: false}))
      assert connected.link_open?
      assert_received {:dp_exchange, :gemini, %Notice{kind: :link_up}}

      lasted = %{connected | connected_at: System.monotonic_time(:millisecond) - 60_000}

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, lasted)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :link_down}}
    end

    @diff %{
      "e" => "depthUpdate",
      "E" => 1_787_936_147_000_000_000,
      "s" => "btcusd",
      "U" => 11,
      "u" => 15,
      "b" => [["3610.00", "1.5"]],
      "a" => [["3611.00", "0"]]
    }

    test "a depth diff in flight after an unsubscribe is not delivered as the absolute book" do
      unsubscribed =
        socket_state(%{
          depth_snapshot?: true,
          depth_streams: MapSet.new(),
          depth_anchored: MapSet.new(),
          last_depth_update: %{}
        })

      assert {:ok, after_frame} =
               Socket.handle_frame({:text, Jason.encode!(@diff)}, unsubscribed)

      refute_received {:dp_exchange, :gemini, _anything}
      # Nothing was recorded for it either: no anchor, no sequence.
      assert after_frame.depth_anchored == MapSet.new()
      assert after_frame.last_depth_update == %{}
    end

    test "the same frame for a subscribed symbol is still the anchor" do
      subscribed =
        socket_state(%{
          depth_snapshot?: true,
          depth_streams: MapSet.new([{"BTC-USD", :depth}]),
          depth_anchored: MapSet.new(),
          last_depth_update: %{}
        })

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(@diff)}, subscribed)
      assert_received {:dp_exchange, :gemini, %DpExchange.Core.Types.OrderBook{sequence: 15}}
    end
  end

  describe "Fake.get_trade_history/2 applies the real call's validation and filters" do
    test "it answers fills shaped as the decoder makes them, oldest first" do
      assert {:ok, [first, second]} = Fake.get_trade_history(@credentials, [])
      assert %DpExchange.Core.Types.Fill{symbol: "BTC-USD", side: :buy} = first
      assert %DpExchange.Core.Types.Fill{symbol: "ETH-USD", side: :sell} = second
      assert DateTime.compare(first.timestamp, second.timestamp) == :lt
      assert Decimal.equal?(first.fee, Decimal.new("0.5"))
    end

    test "symbol, since and limit narrow it like the request does" do
      assert {:ok, [%{symbol: "ETH-USD"}]} =
               Fake.get_trade_history(@credentials, symbol: "ethusd")

      assert {:ok, [%{symbol: "ETH-USD"}]} =
               Fake.get_trade_history(@credentials, since: ~U[2026-08-28 12:00:01Z])

      assert {:ok, []} = Fake.get_trade_history(@credentials, since: ~U[2026-08-28 12:00:02Z])

      # The most recent N, as the venue's `limit_trades` returns.
      assert {:ok, [%{symbol: "ETH-USD"}]} = Fake.get_trade_history(@credentials, limit: 1)
    end

    test "a bad option is refused, before the credential, as the real call refuses it" do
      for {key, value} <- [limit: 0, limit: 501, since: "soon", symbol: ""] do
        expected = {:error, {:invalid_option, key, value}}

        assert Fake.get_trade_history(%{}, [{key, value}]) == expected

        assert Private.get_trade_history(
                 @credentials,
                 [{key, value}, plug: exploding(), retry_attempts: 0]
               ) == expected
      end
    end
  end

  # Attaches a handler for the reconnect-attempt event that forwards it to this test, scoped to
  # the emitting process so another async test's event cannot satisfy an assertion here.
  defp attach_reconnect_attempts do
    test_pid = self()
    tag = {:reconnect_attempt, make_ref()}
    handler_id = "tick-am-reconnect-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:dp_exchange, :link, :reconnect_attempt],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata.provider == :gemini,
          do: send(test_pid, {tag, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    tag
  end
end
