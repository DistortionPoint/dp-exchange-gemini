defmodule DpExchange.Gemini.WriteConventionsTest do
  @moduledoc """
  The family's non-order write conventions (tick Q), applied to Gemini.

    * W1: a write that may have reached the venue and is not proven is
      `{:error, {:write_unconfirmed, key_or_nil, reason}}`, never a bare error
    * W2: only `withdraw/6` retries (it carries a key the venue honours); everything else,
      `cancel_all_orders/2` and the allowlist writes included, is sent once
    * W3: an accepted write whose body cannot be read is unconfirmed, not a hard error
    * W4: a float amount is `{:invalid_amount, v}`; an account name is a non-blank string; a
      transfer to the same account is refused
    * W6: the fake refuses what the real path refuses and answers with what was committed
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Conversion, StakingTransaction, Withdrawal}
  alias DpExchange.Gemini.{Fake, Private}

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

  defmodule DenyingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 7_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # Lets the first request through and refuses every later one, so a retry is the thing our
  # own limiter turns away. The count lives in the calling process, where `HttpClient` runs.
  defmodule FirstThenDenyLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts) do
      seen = Process.get({__MODULE__, :seen}, 0)
      Process.put({__MODULE__, :seen}, seen + 1)
      if seen == 0, do: :ok, else: {:error, :rate_limit_timeout}
    end

    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 7_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  @oauth %{access_token: "oauth-token-not-real"}
  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  @clearing_terms %{
    symbol: "BTC-USD",
    amount: Decimal.new("1"),
    price: Decimal.new("100"),
    side: :buy
  }

  @commit_terms [
    symbol: "BTC-USD",
    side: :buy,
    amount: Decimal.new("0.015"),
    price: Decimal.new("6445.07"),
    fee: Decimal.new("2.99"),
    credentials: @credentials
  ]

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp answering(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end
  end

  defp timing_out, do: fn conn -> Req.Test.transport_error(conn, :timeout) end

  # Tells the test process about every request and its signed payload, then answers `step`.
  defp watching(test_pid, step) do
    fn conn ->
      # An OAuth request carries no signed payload header.
      payload =
        case Plug.Conn.get_req_header(conn, "x-gemini-payload") do
          [encoded | _rest] -> encoded |> Base.decode64!() |> Jason.decode!()
          [] -> %{}
        end

      send(test_pid, {:attempt, payload})
      step.(conn)
    end
  end

  # The nth plug of a sequence answers the nth request; the last one answers the rest.
  defp sequence(test_pid, steps) do
    counter = :counters.new(1, [])

    watching(test_pid, fn conn ->
      :counters.add(counter, 1, 1)
      step = Enum.at(steps, :counters.get(counter, 1) - 1, List.last(steps))
      step.(conn)
    end)
  end

  defp attempts(acc \\ []) do
    receive do
      {:attempt, payload} -> attempts([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp withdraw(extra) do
    Private.withdraw(
      "ETH",
      "ethereum",
      Decimal.new("1"),
      "0xabc",
      @credentials,
      [retry_attempts: 3, retry_delay: 1] ++ extra
    )
  end

  describe "withdraw/6 keeps its key on every failure after a send (W1, W2)" do
    test "a timeout on every attempt carries the generated clientTransferId" do
      assert {:error, {:write_unconfirmed, key, {:exchange_error, :gemini, _reason}}} =
               withdraw(plug: watching(self(), timing_out()))

      assert is_binary(key)
      sent = attempts()
      assert length(sent) >= 3
      assert Enum.all?(sent, &(&1["clientTransferId"] == key))
    end

    test "the caller's own key is the one carried" do
      assert {:error, {:write_unconfirmed, "stable-1", _reason}} =
               withdraw(client_transfer_id: "stable-1", plug: timing_out())
    end

    test "a 5xx on every attempt is unconfirmed with the key" do
      assert {:error, {:write_unconfirmed, "k-5xx", {:exchange_error, :gemini, message}}} =
               withdraw(client_transfer_id: "k-5xx", plug: answering(503, "down"))

      assert is_binary(message)
    end

    test "a 2xx that is not JSON is unconfirmed, not an undecodable bare error" do
      assert {:error, {:write_unconfirmed, "k-html", {:undecodable_response, :gemini}}} =
               withdraw(
                 client_transfer_id: "k-html",
                 plug: answering(200, "<html>maintenance</html>")
               )
    end

    test "a 4xx answered to a RETRY is unconfirmed, not a refusal of the first attempt" do
      plug =
        sequence(self(), [
          timing_out(),
          answering(400, ~s({"result":"error","reason":"DuplicateClientTransferId"}))
        ])

      assert {:error, {:write_unconfirmed, "k-dup", reason}} =
               withdraw(client_transfer_id: "k-dup", plug: plug)

      assert inspect(reason) =~ "refused_after_retry"
      assert [_first, _second] = attempts()
    end

    test "a refusal to the only attempt made is still a refusal" do
      plug = watching(self(), answering(400, ~s({"result":"error","reason":"InvalidSymbol"})))

      assert {:refused, _reason} = withdraw(client_transfer_id: "k-once", plug: plug)
      assert [_only] = attempts()
    end

    test "a 2xx error body on a retry is unconfirmed too" do
      plug =
        sequence(self(), [
          timing_out(),
          answering(200, ~s({"result":"error","reason":"Duplicate","message":"seen"}))
        ])

      assert {:error, {:write_unconfirmed, "k-body", _reason}} =
               withdraw(client_transfer_id: "k-body", plug: plug)
    end

    test "our own limiter refusing before anything was sent stays plain" do
      Config.put_override(:rate_limit_module, DenyingLimiter)

      assert {:error, {:exchange_error, :gemini, message}} =
               withdraw(client_transfer_id: "k-plain", plug: exploding())

      assert message =~ "not the venue"
    end

    test "our own limiter refusing a retry after a send is unconfirmed" do
      Config.put_override(:rate_limit_module, FirstThenDenyLimiter)

      assert {:error, {:write_unconfirmed, "k-limit", {:exchange_error, :gemini, message}}} =
               withdraw(client_transfer_id: "k-limit", plug: watching(self(), timing_out()))

      assert message =~ "not the venue"
      assert [_one] = attempts()
    end

    test "validation and credentials stay plain" do
      assert {:error, {:non_positive_amount, :amount, 0}} =
               Private.withdraw("ETH", "ethereum", 0, "0xabc", @credentials, plug: exploding())

      assert {:error, {:missing_credentials, :gemini}} =
               Private.withdraw("ETH", "ethereum", 1, "0xabc", %{}, plug: exploding())
    end

    test "a 2xx object that lacks fields is still a withdrawal, carrying the key" do
      assert {:ok, %Withdrawal{id: "k-ok"}} =
               withdraw(client_transfer_id: "k-ok", plug: answering(200, "{}"))
    end
  end

  # Every sent-once write, how to call it, and the key an unconfirmed outcome must carry.
  defp write(:transfer, opts) do
    {Private.transfer_internal(
       "USD",
       Decimal.new("1"),
       [from: "a", to: "b", client_transfer_id: "t-1"],
       @credentials,
       opts
     ), "t-1"}
  end

  defp write(:stake, opts) do
    {Private.stake("ETH", Decimal.new("1"), @credentials, [provider_id: "p"] ++ opts), nil}
  end

  defp write(:unstake, opts) do
    {Private.unstake("ETH", Decimal.new("1"), @credentials, [provider_id: "p"] ++ opts), nil}
  end

  defp write(:convert, opts) do
    {Private.convert(
       "GUSD",
       "USD",
       Decimal.new("1"),
       [symbol: "GUSD-USD", side: :sell, credentials: @credentials] ++ opts
     ), nil}
  end

  defp write(:commit, opts) do
    {Private.commit_conversion("20930", @commit_terms ++ opts), "20930"}
  end

  defp write(:create_clearing, opts) do
    {Private.create_clearing_order(@clearing_terms, @credentials, opts), nil}
  end

  defp write(:create_broker_clearing, opts) do
    broker = [source_counterparty_id: "s", target_counterparty_id: "t", expires_in_hrs: 24]
    {Private.create_broker_clearing_order(@clearing_terms, @credentials, broker ++ opts), nil}
  end

  defp write(:confirm_clearing, opts) do
    {Private.confirm_clearing_order("c-1", @clearing_terms, @credentials, opts), "c-1"}
  end

  defp write(:cancel_clearing, opts) do
    {Private.cancel_clearing_order("c-1", @credentials, opts), "c-1"}
  end

  defp write(:add_payment_method, opts) do
    {Private.add_payment_method(%{"accountnumber" => "1"}, @credentials, opts), nil}
  end

  defp write(:request_approved_address, opts) do
    {Private.request_approved_address("ethereum", "0xabc", "desk", @credentials, opts), nil}
  end

  defp write(:remove_approved_address, opts) do
    {Private.remove_approved_address("ethereum", "0xabc", @credentials, opts), nil}
  end

  defp write(:cancel_all_orders, opts) do
    {Private.cancel_all_orders(@credentials, [scope: :session] ++ opts), nil}
  end

  defp write(:revoke, opts), do: {Private.revoke_access_token(@oauth, opts), nil}

  @writes [
    :transfer,
    :stake,
    :unstake,
    :convert,
    :commit,
    :create_clearing,
    :create_broker_clearing,
    :confirm_clearing,
    :cancel_clearing,
    :add_payment_method,
    :request_approved_address,
    :remove_approved_address,
    :cancel_all_orders,
    :revoke
  ]

  describe "a write sent once that may have been acted on is write_unconfirmed (W1, W2)" do
    test "a timeout carries the key, and the request was sent exactly once" do
      for name <- @writes do
        plug = watching(self(), timing_out())
        {result, key} = write(name, plug: plug, retry_attempts: 3, retry_delay: 1)

        assert {:error, {:write_unconfirmed, ^key, {:exchange_error, :gemini, _reason}}} = result,
               "#{name}: #{inspect(result)}"

        assert [_only] = attempts()
      end
    end

    test "a 5xx carries the key" do
      for name <- @writes do
        {result, key} = write(name, plug: answering(502, "bad gateway"), retry_delay: 1)

        assert {:error, {:write_unconfirmed, ^key, {:exchange_error, :gemini, _reason}}} = result,
               "#{name}: #{inspect(result)}"
      end
    end

    test "a 2xx that is not JSON carries the key" do
      for name <- @writes do
        plug = answering(200, "<html>maintenance</html>")
        {result, key} = write(name, plug: plug)

        assert {:error, {:write_unconfirmed, ^key, {:undecodable_response, :gemini}}} = result,
               "#{name}: #{inspect(result)}"
      end
    end

    test "a refusal is a refusal, not unconfirmed" do
      body = ~s({"result":"error","reason":"InvalidSymbol","message":"no"})

      for name <- @writes do
        {result, _key} = write(name, plug: answering(400, body))
        assert {:refused, _reason} = result, "#{name}: #{inspect(result)}"
      end
    end

    test "our own limiter refusing before the send is plain" do
      Config.put_override(:rate_limit_module, DenyingLimiter)

      for name <- @writes do
        {result, _key} = write(name, plug: exploding())

        assert {:error, {:exchange_error, :gemini, message}} = result,
               "#{name}: #{inspect(result)}"

        assert message =~ "not the venue"
      end
    end

    test "a transfer with no key of its own carries the generated one it sent" do
      accounts = [from: "a", to: "b"]

      assert {:error, {:write_unconfirmed, key, _reason}} =
               Private.transfer_internal(
                 "USD",
                 Decimal.new("1"),
                 accounts,
                 @credentials,
                 plug: watching(self(), timing_out())
               )

      assert [%{"clientTransferId" => ^key}] = attempts()
    end
  end

  describe "an accepted write whose body cannot be read is unconfirmed (W1, W3)" do
    test "a conversion reply that names no conversion" do
      assert {:error, {:write_unconfirmed, nil, _reason}} =
               Private.convert(
                 "GUSD",
                 "USD",
                 Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :sell,
                 credentials: @credentials,
                 plug: answering(200, "{}")
               )

      assert {:error, {:write_unconfirmed, "20930", _reason}} =
               Private.commit_conversion("20930", [plug: answering(200, "{}")] ++ @commit_terms)
    end

    test "a stake reply names the transaction it could not otherwise read" do
      stake = fn body ->
        Private.stake("ETH", Decimal.new("1"), @credentials,
          provider_id: "p",
          plug: answering(200, Jason.encode!(body))
        )
      end

      assert {:error, {:write_unconfirmed, nil, _reason}} = stake.(%{})
      assert {:error, {:write_unconfirmed, nil, _reason}} = stake.([])

      assert {:error, {:write_unconfirmed, "tx-9", _reason}} =
               stake.(%{"transactionId" => "tx-9"})
    end

    test "an unreadable optional field is nil, the write still reported" do
      body = %{
        "transactionId" => "tx-1",
        "currency" => "ETH",
        "amount" => "1",
        "amountPaidSoFar" => "not a number",
        "amountRemaining" => %{"x" => 1}
      }

      assert {:ok, %StakingTransaction{id: "tx-1", amount_paid_so_far: nil}} =
               Private.stake("ETH", Decimal.new("1"), @credentials,
                 provider_id: "p",
                 plug: answering(200, Jason.encode!(body))
               )
    end

    test "a transfer, clearing offer and payment method reply that is not an object" do
      for body <- ["[]", "7", "\"ok\""] do
        {result, key} = write(:transfer, plug: answering(200, body))
        assert {:error, {:write_unconfirmed, ^key, :unexpected_response_shape}} = result

        {result, _key} = write(:create_clearing, plug: answering(200, body))
        assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} = result

        {result, _key} = write(:add_payment_method, plug: answering(200, body))
        assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} = result
      end
    end

    test "a bulk cancel whose reply cannot be read" do
      {result, nil} = write(:cancel_all_orders, plug: answering(200, ~s({"result":"ok"})))
      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} = result
    end

    test "a readable conversion is still a conversion" do
      body = %{
        "orderId" => "77",
        "price" => "1.00",
        "quantity" => "1",
        "quantityCurrency" => "USD",
        "totalSpend" => "1",
        "totalSpendCurrency" => "GUSD",
        "side" => "buy"
      }

      assert {:ok, %Conversion{id: "77", status: :settled}} =
               Private.convert(
                 "GUSD",
                 "USD",
                 Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :buy,
                 credentials: @credentials,
                 plug: answering(200, Jason.encode!(body))
               )
    end
  end

  describe "the allowlist writes and the bulk cancel are sent once (W2)" do
    test "a failing request is not repeated" do
      for name <- [:cancel_all_orders, :request_approved_address, :remove_approved_address] do
        {_result, _key} =
          write(name, plug: watching(self(), answering(503, "down")), retry_attempts: 3)

        assert [_only] = attempts(), "#{name} was sent more than once"
      end
    end
  end

  describe "amounts are never floats (W4)" do
    test "every money write refuses one before anything is signed" do
      plug = exploding()
      ctx = [plug: plug]

      assert {:error, {:invalid_amount, 0.1}} =
               Private.withdraw("ETH", "ethereum", 0.1, "0xabc", @credentials, ctx)

      assert {:error, {:invalid_amount, 0.1}} =
               Private.transfer_internal("USD", 0.1, [from: "a", to: "b"], @credentials, ctx)

      for stake <- [&Private.stake/4, &Private.unstake/4] do
        assert {:error, {:invalid_amount, 0.1}} =
                 stake.("ETH", 0.1, @credentials, [provider_id: "p"] ++ ctx)
      end

      instant = [symbol: "BTC-USD", side: :buy, credentials: @credentials] ++ ctx

      assert {:error, {:invalid_amount, 0.1}} =
               Private.quote_conversion("USD", "BTC", 0.1, instant)

      assert {:error, {:invalid_amount, 0.1}} = Private.convert("USD", "BTC", 0.1, instant)

      for field <- [:amount, :price, :fee] do
        terms = Keyword.put(@commit_terms ++ ctx, field, 0.1)

        assert {:error, {:invalid_amount, 0.1}} = Private.commit_conversion("1", terms),
               "#{field}"
      end

      for field <- [:amount, :price] do
        terms = Map.put(@clearing_terms, field, 0.1)

        assert {:error, {:invalid_amount, 0.1}} =
                 Private.create_clearing_order(terms, @credentials, ctx)

        assert {:error, {:invalid_amount, 0.1}} =
                 Private.confirm_clearing_order("c-1", terms, @credentials, ctx)
      end

      assert [] = attempts()
    end

    test "a Decimal, an integer and a numeric string are still amounts" do
      for amount <- [Decimal.new("0.5"), 1, "0.5"] do
        assert {:ok, %Withdrawal{}} =
                 Private.withdraw("ETH", "ethereum", amount, "0xabc", @credentials,
                   plug: answering(200, ~s({"withdrawalId":"w-1"})),
                   retry_attempts: 0
                 )
      end
    end

    test "the fake refuses a float exactly as the real path does" do
      real = Private.withdraw("ETH", "ethereum", 0.1, "0xabc", @credentials, [])
      assert {:error, {:invalid_amount, 0.1}} = real
      assert Fake.withdraw("ETH", "ethereum", 0.1, "0xabc", credentials: @credentials) == real
    end
  end

  describe "an account name is a non-blank string and a transfer moves between two (W4)" do
    test "a transfer from an account to itself is refused, in the real path and the fake" do
      accounts = [from: "primary", to: "primary"]
      expected = {:error, {:invalid_transfer, :same_account}}

      assert Private.transfer_internal("USD", 1, accounts, @credentials, plug: exploding()) ==
               expected

      assert Fake.transfer_internal("USD", 1, accounts, credentials: @credentials) == expected
      assert Private.validate_internal_accounts(accounts) == expected
    end

    test "an end that is an integer or blank is refused, not signed" do
      for {key, bad} <- [from: 5, to: 5, from: "", to: "  ", from: :a, to: ["b"]] do
        accounts = Keyword.merge([from: "a", to: "b"], [{key, bad}])
        expected = {:error, {:invalid_option, key, bad}}

        assert Private.transfer_internal("USD", 1, accounts, @credentials, plug: exploding()) ==
                 expected

        assert Fake.transfer_internal("USD", 1, accounts, credentials: @credentials) == expected
      end
    end

    test "an absent end is still the missing option, :from first" do
      assert {:error, {:missing_option, :from}} = Private.validate_internal_accounts(to: "b")
      assert {:error, {:missing_option, :to}} = Private.validate_internal_accounts(from: "a")
      assert {:error, {:missing_option, :from}} = Private.validate_internal_accounts([])
    end

    test "a broker clearing counterparty is a non-blank string too" do
      for bad <- [5, "", "  "] do
        opts = [source_counterparty_id: bad, target_counterparty_id: "t", expires_in_hrs: 24]

        assert {:error, {:invalid_option, :source_counterparty_id, ^bad}} =
                 Private.create_broker_clearing_order(
                   @clearing_terms,
                   @credentials,
                   [plug: exploding()] ++ opts
                 )
      end
    end
  end

  describe "the fake answers with what was committed (W6)" do
    test "a commit names the pair and terms it was made on" do
      sell = Keyword.merge(@commit_terms, symbol: "ETH-USD", side: :sell)

      assert {:ok, %Conversion{} = conversion} = Fake.commit_conversion("7", sell)
      assert conversion.from_asset == "ETH"
      assert conversion.to_asset == "USD"
      assert conversion.rate == Decimal.new("6445.07")
      assert conversion.fee == Decimal.new("2.99")
      assert conversion.from_amount == Decimal.new("0.015")
      assert conversion.to_amount == nil

      assert {:ok, %Conversion{} = buy} = Fake.commit_conversion("8", @commit_terms)
      assert buy.from_asset == "USD"
      assert buy.to_asset == "BTC"
      assert buy.to_amount == Decimal.new("0.015")
      assert buy.from_amount == nil
    end

    test "a commit the real path refuses is refused alike" do
      terms = Keyword.put(@commit_terms, :amount, 0.5)
      real = Private.commit_conversion("7", Keyword.put(terms, :plug, exploding()))

      assert {:error, {:invalid_amount, 0.5}} = real
      assert Fake.commit_conversion("7", terms) == real
    end

    test "withdrawals with no key get a different generated id each" do
      ids =
        for _call <- 1..3 do
          {:ok, %Withdrawal{id: id}} =
            Fake.withdraw("ETH", "ethereum", 1, "0xabc", credentials: @credentials)

          id
        end

      assert length(Enum.uniq(ids)) == 3
      assert Enum.all?(ids, &String.match?(&1, ~r/\A[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}\z/))
    end

    test "a supplied key is the id" do
      assert {:ok, %Withdrawal{id: "mine"}} =
               Fake.withdraw("ETH", "ethereum", 1, "0xabc",
                 client_transfer_id: "mine",
                 credentials: @credentials
               )
    end

    test "an internal transfer returns only the venue's own reply fields" do
      assert {:ok, transfer} =
               Fake.transfer_internal("USD", Decimal.new("1.50"), [from: "a", to: "b"],
                 credentials: @credentials
               )

      assert Map.keys(transfer) |> Enum.sort() ==
               ["amount", "fromAccount", "message", "toAccount", "uuid"]

      assert transfer["fromAccount"] == "a"
      assert transfer["toAccount"] == "b"
      assert transfer["amount"] == "1.50"

      assert {:ok, other} =
               Fake.transfer_internal("USD", 1, [from: "a", to: "b"], credentials: @credentials)

      refute other["uuid"] == transfer["uuid"]
    end
  end
end
