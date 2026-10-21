defmodule DpExchange.Gemini.MoneyMovementTest do
  @moduledoc """
  The group where a defect moves funds (D2), and the one that can never be tested against
  the live venue here (D7 tier 4).

  Every assertion below guards something that is *irreversible* when it goes wrong: a
  retried withdrawal that sends twice, a deposit address on a chain the venue does not
  credit, a memo-less transfer on a network that needs one, and a withdrawal reported as
  arrived when the chain has not confirmed it.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
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

  describe "withdrawing — the call that cannot be undone" do
    test "an idempotency key is ALWAYS sent, even when the caller gives none" do
      # A withdrawal request that times out has an unknown outcome — the funds may already
      # be moving. Without a key, the safe-looking response (retry) sends the money again.
      me = self()

      assert {:ok, _withdrawal} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 plug: capturing(%{"withdrawalId" => "w-1"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v2/withdraw/ethereum/eth"
      assert is_binary(payload["clientTransferId"])
      assert payload["clientTransferId"] != ""
    end

    test "a caller's own key is used, so a retry across a restart is the same request" do
      me = self()

      assert {:ok, _withdrawal} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 client_transfer_id: "stable-uuid",
                 plug: capturing(%{"withdrawalId" => "w-1"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["clientTransferId"] == "stable-uuid"
    end

    test "two generated keys differ, so two distinct withdrawals are not deduplicated" do
      me = self()

      for _attempt <- 1..2 do
        assert {:ok, _w} =
                 Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                   plug: capturing(%{"withdrawalId" => "w"}, me),
                   retry_attempts: 0
                 )
      end

      assert_receive {:payload, first, _p1}
      assert_receive {:payload, second, _p2}
      refute first["clientTransferId"] == second["clientTransferId"]
    end

    test "a memo the caller says is required and did not supply is refused BEFORE sending" do
      # Stopped where nothing has moved, rather than at the venue after the transfer is
      # accepted. A memo-less transfer to an exchange address on Solana or XRP is credited
      # to nobody and is generally not recoverable.
      exploding = fn _conn -> raise "must not withdraw without a required memo" end

      assert {:error, :memo_required} =
               Private.withdraw("USDC", "solana", Decimal.new("100"), "7Ec…", @credentials,
                 memo_required: true,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "a memo is sent when given" do
      me = self()

      assert {:ok, withdrawal} =
               Private.withdraw("USDC", "solana", Decimal.new("100"), "7Ec…", @credentials,
                 memo: "12345",
                 memo_required: true,
                 plug: capturing(%{"withdrawalId" => "w-1"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["memo"] == "12345"
      assert withdrawal.memo == "12345"
    end

    test "the venue accepting a withdrawal is NOT the chain confirming it" do
      # :completed on an unconfirmed transfer tells a caller the money has arrived.
      assert {:ok, withdrawal} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 plug: responding(%{"withdrawalId" => "w-1"}),
                 retry_attempts: 0
               )

      assert withdrawal.status == :pending
    end

    test "a status the package does not recognise is pending, not completed" do
      # A withdrawal the venue has not described has not arrived.
      assert {:ok, withdrawal} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 plug: responding(%{"withdrawalId" => "w-1", "status" => "somethingNew"}),
                 retry_attempts: 0
               )

      assert withdrawal.status == :pending
    end

    test "a status the schema does not define is not read, even a completion" do
      assert {:ok, withdrawal} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 plug: responding(%{"withdrawalId" => "w-1", "status" => "complete"}),
                 retry_attempts: 0
               )

      assert withdrawal.status == :pending
    end

    test "the destination and network are carried back; the reply is the schema's fields" do
      # `WithdrawCryptoFundsResponse`: withdrawalId, address, amount, currency, fee. `txHash`
      # is a `/v2/transfers` row field, so a reply carrying one gives no `tx_id`.
      reply = %{
        "withdrawalId" => "w-1",
        "address" => "0xabc",
        "amount" => "1",
        "currency" => "ETH",
        "fee" => "0.001",
        "txHash" => "0xdeadbeef"
      }

      assert {:ok, w} =
               Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
                 plug: responding(reply),
                 retry_attempts: 0
               )

      assert w.id == "w-1"
      assert w.address == "0xabc"
      assert w.network == "ethereum"
      assert w.asset == "ETH"
      assert Decimal.equal?(w.fee, Decimal.new("0.001"))
      assert w.tx_id == nil
    end
  end

  describe "deposit addresses" do
    test "the address is generated on the network asked for" do
      me = self()

      assert {:ok, address} =
               Private.get_deposit_address("BTC", "bitcoin", @credentials,
                 plug: capturing(%{"address" => "mi98Z…"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, _payload, path}
      assert path == "/v1/deposit/bitcoin/newAddress"
      assert address.network == "bitcoin"
      assert address.asset == "BTC"
    end

    test "memo_required is nil, NOT false" do
      # false would be a claim that no memo is needed, which on Solana or XRP loses the
      # deposit. This endpoint does not say, so neither does the package.
      assert {:ok, address} =
               Private.get_deposit_address("BTC", "bitcoin", @credentials,
                 plug: responding(%{"address" => "mi98Z…"}),
                 retry_attempts: 0
               )

      assert address.memo_required == nil
    end

    test "a label is passed through when given" do
      me = self()

      assert {:ok, _address} =
               Private.get_deposit_address("BTC", "bitcoin", @credentials,
                 label: "desk-1",
                 plug: capturing(%{"address" => "mi98Z…"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["label"] == "desk-1"
    end
  end

  describe "approved addresses — on the list is not the same as usable" do
    @approved %{
      "approvedAddresses" => [
        %{
          "network" => "ethereum",
          "label" => "desk",
          "status" => "active",
          "createdAt" => "1602692572349",
          "address" => "0x1111"
        },
        %{
          "network" => "ethereum",
          "label" => "new",
          "status" => "pending-time",
          "createdAt" => "1602692542296",
          "address" => "0x2222"
        }
      ]
    }

    test "a pending address is pending, and usable? says unknown rather than ready" do
      # The venue reports pending-time for an address still inside its time lock, and a
      # withdrawal to it is refused. It publishes no activation time, so guessing when the
      # lock lifts would be a claim.
      assert {:ok, [active, pending]} =
               Private.list_approved_addresses(@credentials,
                 network: "ethereum",
                 plug: responding(@approved),
                 retry_attempts: 0
               )

      assert active.status == :active
      assert Types.ApprovedAddress.usable?(active, DateTime.utc_now())

      assert pending.status == :pending
      assert Types.ApprovedAddress.usable?(pending, DateTime.utc_now()) == nil
    end

    test "a status the venue invents later is refused, never read as active or pending" do
      # Treating an unknown status as usable is the direction that loses money, and reading
      # it as `:pending` was a guess too: Core's ApprovedAddress leaves a word it has no
      # mapping for to the venue package to refuse (tick AR).
      body = %{"approvedAddresses" => [%{"address" => "0x3", "status" => "somethingNew"}]}

      assert {:error, :unexpected_response_shape} =
               Private.list_approved_addresses(@credentials,
                 network: "ethereum",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "the network is required — the venue keeps one list per network" do
      exploding = fn _conn -> raise "must not list approved addresses without a network" end

      assert {:error, {:missing_option, :network}} =
               Private.list_approved_addresses(@credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "the fee estimate moves nothing" do
    test "the address is part of the estimate" do
      # Fees differ by destination on some networks, so an estimate for one address does
      # not hold for another.
      me = self()

      assert {:ok, estimate} =
               Private.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("1"), @credentials,
                 address: "0xabc",
                 plug: capturing(%{"fee" => "0.0005", "currency" => "ETH"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v2/withdraw/ethereum/eth/feeEstimate"
      assert payload["address"] == "0xabc"
      assert Decimal.equal?(estimate.fee, Decimal.new("0.0005"))
      assert estimate.address == "0xabc"
    end

    test "no address is an error rather than an estimate for nowhere" do
      exploding = fn _conn -> raise "must not estimate a fee with no destination" end

      assert {:error, {:missing_option, :address}} =
               Private.estimate_withdrawal_fee("ETH", "ethereum", Decimal.new("1"), @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "payment methods" do
    test "balances and banks come back tagged by kind, because the reply is two arrays under two names" do
      # `PaymentMethodsResponse` is `{balances: [...], banks: [...]}` (`rest.yaml:5454`,
      # schema `:9316-9328`), not a `"methods"` array. This used to fixture the shape the
      # endpoint has never sent.
      body = %{
        "balances" => [%{"currency" => "USD", "amount" => "100.00"}],
        "banks" => [%{"bank" => "Test Bank", "bankId" => "b-1"}]
      }

      assert {:ok, methods} =
               Private.list_payment_methods(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(methods) == 2
      assert Enum.any?(methods, &(&1["kind"] == "balance"))
      assert Enum.any?(methods, &(&1["kind"] == "bank"))
    end

    test "neither array present is no rows, not an error" do
      assert {:ok, []} =
               Private.list_payment_methods(@credentials,
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "the country picks the endpoint, because the details differ" do
      # Sending Canadian details to the US endpoint would have the fields read as the other
      # country's and the account registered wrong.
      me = self()

      assert {:ok, _method} =
               Private.add_payment_method(%{"accountNumber" => "1"}, @credentials,
                 plug: capturing(%{"referenceId" => "BankAccountRefId(18428)"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, _p1, us_path}
      assert us_path == "/v1/payments/addbank"

      assert {:ok, _ca} =
               Private.add_payment_method(%{"transitNumber" => "1"}, @credentials,
                 country: "CA",
                 plug: capturing(%{"result" => "OK"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, _p2, ca_path}
      assert ca_path == "/v1/payments/addbank/cad"
    end

    test "a country this venue has no endpoint for is refused, not sent to the wrong one" do
      exploding = fn _conn -> raise "must not register a bank on the wrong country's path" end

      assert {:error, {:unsupported_country, "GB"}} =
               Private.add_payment_method(%{"iban" => "GB…"}, @credentials,
                 country: "GB",
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "internal transfers are not withdrawals" do
    test "both ends are required" do
      # A transfer with one end missing is not a transfer, and defaulting either would move
      # funds between accounts the caller did not name.
      exploding = fn _conn -> raise "must not transfer with an end missing" end

      assert {:error, {:missing_option, :from}} =
               Private.transfer_internal("BTC", Decimal.new("1"), [to: "b"], @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )

      assert {:error, {:missing_option, :to}} =
               Private.transfer_internal("BTC", Decimal.new("1"), [from: "a"], @credentials,
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "no address and no network are sent — nothing leaves the venue" do
      me = self()

      assert {:ok, _transfer} =
               Private.transfer_internal(
                 "BTC",
                 Decimal.new("1"),
                 [from: "a", to: "b"],
                 @credentials,
                 plug:
                   capturing(
                     %{
                       "fromAccount" => "a",
                       "toAccount" => "b",
                       "amount" => "1",
                       "uuid" => "9c153d64-83ba-4532-a159-ebe3f6797766",
                       "message" => "Success, transfer completed."
                     },
                     me
                   ),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v1/account/transfer/btc"
      assert payload["sourceAccount"] == "a"
      assert payload["targetAccount"] == "b"
      refute Map.has_key?(payload, "address")
    end
  end

  describe "the allowlist writes" do
    test "requesting an address sends it and any label" do
      me = self()

      assert {:ok, _requested} =
               Private.request_approved_address("ethereum", "0xabc", "desk", @credentials,
                 plug:
                   capturing(
                     %{"message" => "Approved address addition is now waiting a 7-day hold."},
                     me
                   ),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v1/approvedAddresses/ethereum/request"
      assert payload["address"] == "0xabc"
      assert payload["label"] == "desk"
    end

    test "a missing label is refused before a request goes out (the venue requires it)" do
      # `rest.yaml:5702` lists `label` in `required`. No plug: reaching HTTP would fail on
      # the connection rather than on the guard.
      assert {:error, {:missing_required_field, :label}} =
               Private.request_approved_address("ethereum", "0xabc", nil, @credentials, [])

      assert {:error, {:missing_required_field, :label}} =
               Private.request_approved_address("ethereum", "0xabc", "", @credentials, [])
    end

    test "a memo is sent when given, and only then" do
      me = self()

      assert {:ok, _requested} =
               Private.request_approved_address("cosmos", "cosmos1abc", "desk", @credentials,
                 memo: "12345",
                 plug: capturing(%{"message" => "ok"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, with_memo, _path}
      assert with_memo["memo"] == "12345"

      assert {:ok, _requested} =
               Private.request_approved_address("ethereum", "0xabc", "desk", @credentials,
                 plug: capturing(%{"message" => "ok"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, without_memo, _path}
      refute Map.has_key?(without_memo, "memo")
    end

    test "removal is its own endpoint" do
      me = self()

      assert {:ok, _removed} =
               Private.remove_approved_address("ethereum", "0xabc", @credentials,
                 plug: capturing(%{"message" => "0xabc removed from approved addresses."}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v1/approvedAddresses/ethereum/remove"
      assert payload["address"] == "0xabc"
    end
  end

  describe "transactions are wider than fills and transfers" do
    # Both fixtures here were corrected to the vendor's documented reply and request shape
    # (`rest.yaml`, 2026-09-29): the reply wraps its rows under `"results"` rather than being
    # a bare array, the page size parameter is `limit` rather than `limit_transactions`, and
    # the window parameter is `timestamp_nanos`, in nanoseconds, rather than `timestamp` in
    # milliseconds.
    test "every kind the venue sends comes back" do
      # `Transaction` (rest.yaml): a trade row (`type: "trade"`, `tid`) and transfer rows
      # (`eid`, `currency`, `amount`, `status`).
      body = %{
        "results" => [
          %{"type" => "trade", "amount" => "1", "tid" => 144_115_199_446_910_513},
          %{"eid" => 368_598_436_530, "currency" => "USD", "amount" => "100"},
          %{"eid" => 368_598_436_531, "currency" => "USD", "amount" => "50"}
        ]
      }

      assert {:ok, rows} =
               Private.get_transactions(@credentials, plug: responding(body), retry_attempts: 0)

      assert Enum.map(rows, & &1["amount"]) == ["1", "100", "50"]
      assert Enum.any?(rows, &(&1["type"] == "trade"))
      assert Enum.any?(rows, &Map.has_key?(&1, "eid"))
    end

    test "the filters go to the venue in its own names" do
      me = self()
      since = ~U[2026-08-28 17:00:01Z]

      assert {:ok, _rows} =
               Private.get_transactions(@credentials,
                 since: since,
                 limit: 50,
                 plug: capturing(%{"results" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v1/transactions"
      assert payload["limit"] == 50
      assert payload["timestamp_nanos"] == DateTime.to_unix(since, :nanosecond)
    end

    test "an integer :since is milliseconds, like every other :since, and goes out as nanos" do
      me = self()

      for since <- [1_700_000_000_001, "1700000000001"] do
        assert {:ok, _rows} =
                 Private.get_transactions(@credentials,
                   since: since,
                   limit: 50,
                   plug: capturing(%{"results" => []}, me),
                   retry_attempts: 0
                 )

        assert_receive {:payload, payload, "/v1/transactions"}, 5_000
        assert payload["timestamp_nanos"] == 1_700_000_000_001_000_000
      end
    end

    test "the Fake filters an integer millisecond :since exactly as the request bound reads it" do
      # The same value the real call turns into 1_700_000_000_001_000_000 nanoseconds keeps
      # the rows at or after that millisecond, not the whole ledger (a 1970 window).
      assert {:ok, rows} =
               DpExchange.Gemini.Fake.get_transactions(@credentials, since: 1_700_000_000_001)

      assert Enum.map(rows, & &1["eid"]) == [368_598_436_530, 368_598_436_531]
    end
  end

  describe "get_transactions/2 follows the venue's continuationToken" do
    # `Core.Venue` types this call `{:ok, [map()]}`, with no cursor to hand back, so without
    # `opts[:limit]` this walks every page itself. Each test below is one shape that walk
    # must get right: two real pages concatenate in order, a caller-given `:limit` takes
    # exactly one page (the caller asked for a bounded amount, not the whole history), and a
    # token the venue echoes back unchanged is refused rather than followed forever.
    defp paging_plug(test_pid, responses) do
      counter = :counters.new(1, [])

      fn conn ->
        payload =
          conn
          |> Plug.Conn.get_req_header("x-gemini-payload")
          |> List.first()
          |> Base.decode64!()
          |> Jason.decode!()

        send(test_pid, {:payload, payload})
        :counters.add(counter, 1, 1)
        body = Enum.at(responses, :counters.get(counter, 1) - 1, List.last(responses))

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json(body)
      end
    end

    test "two pages' rows concatenate; the second request carries the token and no timestamp_nanos" do
      me = self()

      responses = [
        %{"results" => [%{"type" => "trade"}], "continuationToken" => "tok-1"},
        %{"results" => [%{"eid" => 368_598_436_530}]}
      ]

      assert {:ok, rows} =
               Private.get_transactions(@credentials,
                 since: ~U[2026-08-28 17:00:01Z],
                 plug: paging_plug(me, responses),
                 retry_attempts: 0
               )

      assert Enum.map(rows, &(&1["type"] || &1["eid"])) == ["trade", 368_598_436_530]

      assert_receive {:payload, first}
      assert_receive {:payload, second}
      refute Map.has_key?(first, "continuation_token")
      assert Map.has_key?(first, "timestamp_nanos")
      assert second["continuation_token"] == "tok-1"
      refute Map.has_key?(second, "timestamp_nanos")
    end

    test "opts[:limit] returns exactly one page" do
      me = self()

      responses = [%{"results" => [%{"type" => "trade"}], "continuationToken" => "tok-1"}]

      assert {:ok, rows} =
               Private.get_transactions(@credentials,
                 limit: 10,
                 plug: paging_plug(me, responses),
                 retry_attempts: 0
               )

      assert length(rows) == 1
      assert_receive {:payload, payload}
      assert payload["limit"] == 10
      refute_receive {:payload, _second_request}, 500
    end

    test "a token the venue echoes back unchanged is refused, never followed forever" do
      me = self()

      responses = [%{"results" => [%{"type" => "trade"}], "continuationToken" => "tok-1"}]

      assert {:error, :repeated_continuation_token} =
               Private.get_transactions(@credentials,
                 plug: paging_plug(me, responses),
                 retry_attempts: 0
               )
    end

    test "an empty page ends the walk even though the venue still sends a token" do
      # A venue that attaches a token to every page, the last included, used to be walked
      # into an empty page and then into `:repeated_continuation_token` (or the page cap):
      # a complete history reported as an error.
      me = self()

      responses = [
        %{"results" => [%{"type" => "trade"}], "continuationToken" => "tok-1"},
        %{"results" => [], "continuationToken" => "tok-1"}
      ]

      assert {:ok, [%{"type" => "trade"}]} =
               Private.get_transactions(@credentials,
                 plug: paging_plug(me, responses),
                 retry_attempts: 0
               )

      assert_receive {:payload, _first}
      assert_receive {:payload, second}
      assert second["continuation_token"] == "tok-1"
      refute_receive {:payload, _third}, 500
    end
  end

  describe "get_notional_balances/3 — a valuation is not a balance" do
    test "the quantity and the venue's valuation stay separate keys" do
      # Merging them is the failure this endpoint invites: the notional figure is Gemini's
      # own estimate at a rate it does not publish here, and the amount is the ledger.
      rows = [
        %{"currency" => "BTC", "amount" => "1.5", "amountNotional" => "60000.00"}
      ]

      assert {:ok, [row]} =
               Private.get_notional_balances(@credentials, "usd",
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert row["amount"] == "1.5"
      assert row["amountNotional"] == "60000.00"
    end

    test "the currency is a path segment, down-cased, not a parameter" do
      me = self()

      assert {:ok, _rows} =
               Private.get_notional_balances(@credentials, "USD",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v1/notionalbalances/usd"
      refute Map.has_key?(payload, "currency")
    end

    test "a currency carrying path characters cannot change the signed path" do
      me = self()

      assert {:ok, _rows} =
               Private.get_notional_balances(@credentials, "us/d?x=1",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["request"] == "/v1/notionalbalances/us%2Fd%3Fx%3D1"
    end

    test "an undocumented currency is sent as given rather than refused here" do
      # A package that allowed only `usd` would be wrong the day a second one is added, and
      # the venue is the thing that knows.
      me = self()

      assert {:ok, _rows} =
               Private.get_notional_balances(@credentials, "GBP",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, _payload, "/v1/notionalbalances/gbp"}
    end
  end

  describe "list_custody_fees/2 — a charge with no trade behind it" do
    test "the rows are the venue's own" do
      rows = [
        %{
          "txTime" => 1_700_000_000_000,
          "feeAmount" => "0.00012",
          "feeCurrency" => "BTC",
          "eid" => 9016,
          "eventType" => "CustodyFeeDebit"
        }
      ]

      assert {:ok, [fee]} =
               Private.list_custody_fees(@credentials,
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert fee["feeCurrency"] == "BTC"
      assert fee["feeAmount"] == "0.00012"
    end

    test "an empty list is 'nothing charged', and reaches the caller as one" do
      # The dangerous reading is "no such fee". An account billed nothing this period and an
      # account with no custody balance return the same thing, and neither is an error.
      assert {:ok, []} =
               Private.list_custody_fees(@credentials, plug: responding([]), retry_attempts: 0)
    end

    test "the window goes to the venue under its own parameter names" do
      me = self()

      assert {:ok, _rows} =
               Private.list_custody_fees(@credentials,
                 since: ~U[2026-08-28 17:00:01Z],
                 limit: 25,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, path}
      assert path == "/v1/custodyaccountfees"
      assert payload["limit_transfers"] == 25
      assert payload["timestamp"] == 1_787_936_401_000
    end

    test "a full page with no :limit is refused, since the venue gives no cursor" do
      # Default page is 10, maximum 50 (rest.yaml:3446). A full page cannot be told from the
      # whole history, so it is not answered as one.
      rows = for n <- 1..50, do: %{"feeCurrency" => "BTC", "feeAmount" => "0.0001", "eid" => n}
      me = self()

      assert {:error, :history_truncated} =
               Private.list_custody_fees(@credentials,
                 plug: capturing(rows, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["limit_transfers"] == 50

      assert {:ok, ^rows} =
               Private.list_custody_fees(@credentials,
                 limit: 50,
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end
  end

  describe "a write the venue cannot deduplicate is sent exactly once" do
    test "an order that fails transiently is not placed again" do
      # `Core.HttpClient` retries any error that is not a 4xx — a timeout, a reset, a 503 —
      # which are exactly the failures where the venue may have received and ACTED ON the
      # request. Retried, a `/v1/order/new` Gemini accepted before the failure places a
      # SECOND order, and the caller sees one call and one answer either way.
      #
      # This is not a ban on retrying. It is a ban on repeating an ACTION the venue cannot
      # tell apart from the first one: `withdraw/6` always sends a `clientTransferId` and
      # therefore still retries, which `write_conventions_test.exs` pins.
      me = self()

      plug = fn conn ->
        send(me, :attempt)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"result":"error","reason":"ServiceUnavailable"}))
      end

      # The answer is the other half of "sent once": a send that may have been acted on is
      # reported as unconfirmed, never as a plain failure the caller would retry.
      assert {:error, {:order_unconfirmed, _client_order_id, _reason}} =
               Private.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   order_type: :limit,
                   time_in_force: :gtc,
                   quantity: Decimal.new("1"),
                   price: Decimal.new("100")
                 },
                 plug: plug,
                 retry_delay: 1
               )

      assert_receive :attempt, 5_000
      refute_receive :attempt, 500
    end

    test "a staking write is sent once too" do
      me = self()

      plug = fn conn ->
        send(me, :attempt)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"result":"error"}))
      end

      assert {:error, {:write_unconfirmed, _id, _reason}} =
               Private.stake("ETH", Decimal.new("1"), @credentials,
                 provider_id: "p-1",
                 plug: plug,
                 retry_delay: 1
               )

      assert_receive :attempt, 5_000
      refute_receive :attempt, 500
    end

    test "a read still retries, because re-asking a question repeats nothing" do
      me = self()

      plug = fn conn ->
        send(me, :attempt)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"result":"error"}))
      end

      assert {:error, _reason} =
               Private.get_balances(@credentials, plug: plug, retry_attempts: 2, retry_delay: 1)

      assert_receive :attempt, 5_000
      assert_receive :attempt, 5_000
    end
  end

  describe "a write the venue cannot dedupe is sent once" do
    # `Core.HttpClient` retries a timeout or a 5xx three times by default. `post_once/4`
    # exists because a retried write is only safe when the venue can tell the second attempt
    # from the first, and it states that test in its own comment. This asserts the rule is
    # applied where it holds and NOT applied where it does not — both halves, because a rule
    # flattened onto every write would cost callers their retries on requests that are
    # perfectly safe to repeat.
    setup do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.resp(conn, 500, "upstream is having a bad day")
      end

      {:ok, counter: counter, plug: plug}
    end

    test "add_payment_method/3 — the body is the caller's, so nothing here is a key",
         %{counter: counter, plug: plug} do
      assert {:error, _reason} =
               Private.add_payment_method(%{"type" => "bank"}, @credentials,
                 plug: plug,
                 retry_delay: 1
               )

      assert :counters.get(counter, 1) == 1,
             "adding a bank account twice is a second payment method, not a retry"
    end

    test "create_account/3 — a duplicate subaccount is an Administrator's problem",
         %{counter: counter, plug: plug} do
      assert {:error, _reason} =
               Private.create_account("second-desk", @credentials, plug: plug, retry_delay: 1)

      assert :counters.get(counter, 1) == 1
    end

    test "request_approved_address/4 is sent once — nothing shows the venue dedupes on it",
         %{counter: counter, plug: plug} do
      # This was a control that kept the retries on the assumption that re-sending asks for
      # the same allowlist entry. The spec never says so (unmeasured), and a request that
      # took effect and lost its reply, repeated, is answered as a refusal that reads as
      # "nothing was added". Sent once (tick Q, W2); a possible send is write_unconfirmed.
      assert {:error, {:write_unconfirmed, nil, _reason}} =
               Private.request_approved_address("ethereum", "0xabc", "cold", @credentials,
                 plug: plug,
                 retry_delay: 1
               )

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "amounts go on the wire in full notation, and a missing one is refused" do
    # `to_string/1` on a `Decimal` goes through `String.Chars`, which is scientific notation:
    # measured on the wire, a one-satoshi quantity went out as `"1E-8"` and 1,500,000 as
    # `"1.5E+6"`, on `withdraw/6`, `transfer_internal/5` and the conversion execute alike.
    # `place_order/3` in the same module already sent through `decimal_string/1`; these three
    # money-moving paths were the ones an earlier sweep missed.
    @tiny Decimal.new("0.00000001")
    @large Decimal.new("1.5E+6")

    test "withdraw/6 sends a one-satoshi amount as 0.00000001, not 1E-8" do
      assert {:ok, _withdrawal} =
               Private.withdraw("BTC", "bitcoin", @tiny, "bc1q-addr", @credentials,
                 plug: capturing(%{"withdrawalId" => "w-1"}, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["amount"] == "0.00000001"
    end

    test "transfer_internal/5 sends a large amount as 1500000, not 1.5E+6" do
      assert {:ok, _transfer} =
               Private.transfer_internal("BTC", @large, [from: "a", to: "b"], @credentials,
                 plug: capturing(%{"ok" => true}, self()),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["amount"] == "1500000"
    end

    test "commit_conversion/2 sends quantity and price in full notation" do
      Private.commit_conversion("20930",
        credentials: @credentials,
        symbol: "BTC-USD",
        side: :buy,
        amount: @tiny,
        price: @large,
        fee: Decimal.new("2.50"),
        plug: capturing(%{"orderId" => 375_089_415}, self()),
        retry_attempts: 0
      )

      assert_receive {:payload, payload, "/v1/instant/execute"}
      assert payload["quantity"] == "0.00000001"
      assert payload["price"] == "1500000"
      # `quoteId` is `type: integer` in the venue's own schema (`rest.yaml:5072`) — sent as
      # a number, not the string `commit_conversion/2` received it as.
      assert payload["quoteId"] == 20_930
    end

    test "commit_conversion/2 refuses a forwarded nil amount rather than sending an empty one" do
      # The guard was `Keyword.has_key?/2`, which is `true` for `price: nil`, so a caller
      # forwarding options its own caller never set passed it and `to_string(nil)` put
      # `"quantity": ""` and `"price": ""` into a signed execute — measured on the wire. This
      # module's own comment promises "a missing one is an error rather than a value
      # invented here".
      assert {:error, {:missing_option, missing}} =
               Private.commit_conversion("20930",
                 credentials: @credentials,
                 symbol: "BTC-USD",
                 side: :buy,
                 amount: nil,
                 price: "  ",
                 fee: Decimal.new("2.50"),
                 plug: capturing(%{"orderId" => 375_089_415}, self()),
                 retry_attempts: 0
               )

      assert Enum.sort(missing) == [:amount, :price]
      refute_receive {:payload, _payload, _path}, 500
    end
  end
end
