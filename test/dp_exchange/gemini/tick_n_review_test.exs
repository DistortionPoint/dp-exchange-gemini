defmodule DpExchange.Gemini.TickNReviewTest do
  @moduledoc """
  Tick N: error paths and option values.

  Every refusal here is asserted against a plug that raises: if the call reached the venue,
  the result would not be the refusal. Where the fake has the same call, it is held to the
  real call's answer.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.{Balance, DepositAddress, FxRate}
  alias DpExchange.Gemini.{Credentials, Fake, Feed, Private, Rest}

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
  @terms %{symbol: "BTC-USD", amount: "1", price: "100", side: :buy}
  @fx_at ~U[2023-11-14 22:13:20Z]

  defp json(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp real_opts(opts), do: opts ++ [plug: exploding(), retry_attempts: 0]

  # A plug that reports the query string it was sent, and answers `body`.
  defp reporting(body, test_pid) do
    fn conn ->
      send(test_pid, {:query, conn.query_string})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp withdraw(opts) do
    Private.withdraw("ETH", "ethereum", 1, "0xabc", @credentials, real_opts(opts))
  end

  defp fake_withdraw(opts) do
    Fake.withdraw("ETH", "ethereum", 1, "0xabc", opts ++ [credentials: @credentials])
  end

  describe "a wrapped Credentials struct is a credential, not an ambiguous one" do
    # `Credentials.wrap/1` is public for a host that builds its own child spec, and always
    # carries all three fields. `%{api_key: _, access_token: _}` matched it as BOTH header
    # families, so every call made with a wrapped credential was refused as ambiguous.
    test "the scheme follows the values that are present" do
      both = Map.put(@credentials, :access_token, "t")

      assert Private.credential_scheme(Credentials.wrap(@credentials)) == :api_key
      assert Private.credential_scheme(Credentials.wrap(%{access_token: "t"})) == :oauth
      assert Private.credential_scheme(both) == :ambiguous
      assert Private.credential_scheme(%{api_key: "k", access_token: nil}) == :api_key
      assert Private.credential_scheme(%{api_key: nil, access_token: "t"}) == :oauth
      assert Private.credential_scheme(%{api_key: nil}) == :api_key
      assert Private.credential_scheme(%{access_token: nil}) == :oauth
      assert Private.credential_scheme(%{}) == nil
      assert Private.credential_scheme(nil) == nil
    end

    test "a signed call made with one is sent" do
      wrapped = Credentials.wrap(@credentials)
      body = [%{"currency" => "USD", "amount" => "5", "available" => "4"}]

      assert {:ok, [%Balance{currency: "USD"}]} =
               Private.get_balances(wrapped, plug: json(body), retry_attempts: 0)

      assert {:ok, [_first | _rest]} = Fake.get_balances(wrapped, [])
    end
  end

  describe "the fake refuses a blank or non-string credential, as Auth.headers/5 does" do
    test "the same answer as the real call, for every such credential" do
      for credentials <- [
            %{api_key: "", api_secret: "s"},
            %{api_key: "k", api_secret: "  "},
            %{api_key: nil, api_secret: nil},
            %{api_key: "k", api_secret: 5},
            %{access_token: ""},
            %{access_token: nil},
            %{access_token: 12_345}
          ] do
        real = Private.get_balances(credentials, real_opts([]))

        assert {:error, {:missing_credentials, :gemini}} = real
        assert Fake.get_balances(credentials, []) == real, inspect(credentials)
      end
    end
  end

  describe "a clearing id is a non-blank string" do
    test "the three calls that act on one refuse anything else, before anything is signed" do
      for bad <- [nil, :c1, 5, "", "   ", %{}] do
        expected = {:error, {:invalid_clearing_id, bad}}
        opts = real_opts([])

        assert Private.get_clearing_order(bad, @credentials, opts) == expected
        assert Private.cancel_clearing_order(bad, @credentials, opts) == expected
        assert Private.confirm_clearing_order(bad, @terms, @credentials, opts) == expected
      end
    end

    test "a valid id still reaches the venue" do
      opts = [plug: json(%{}), retry_attempts: 0]

      assert {:ok, %{}} = Private.get_clearing_order("c-1", @credentials, opts)
    end
  end

  describe "refresh_access_token/3 with a client id or token that is not a string" do
    test "is the required-error, not a FunctionClauseError" do
      for bad <- [nil, :id, 5, %{}] do
        assert Private.refresh_access_token(bad, "refresh", real_opts([])) ==
                 {:error, :client_id_required}

        assert Private.refresh_access_token("client", bad, real_opts([])) ==
                 {:error, :refresh_token_required}
      end
    end
  end

  describe "refresh_access_token/3 :client_secret" do
    defp form_plug(test_pid) do
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:form, URI.decode_query(raw)})
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => "a"}))
      end
    end

    test "a blank secret is not sent: a public client must not send one" do
      for blank <- ["", "   "] do
        assert {:ok, _tokens} =
                 Private.refresh_access_token("client", "refresh",
                   client_secret: blank,
                   plug: form_plug(self()),
                   retry_attempts: 0
                 )

        assert_receive {:form, form}, 5_000
        refute Map.has_key?(form, "client_secret")
      end
    end

    test "a secret that is not a string is refused, not dropped or raised on" do
      # The refusal names the key and never echoes the value: it is a secret in a shape that
      # could not be sent (a charlist, iodata, a map holding it).
      for bad <- [5, %{}, :secret, ~c"hunter2-canary", ["hunter2", "-canary"]] do
        assert Private.refresh_access_token("client", "refresh", real_opts(client_secret: bad)) ==
                 {:error, {:invalid_option, :client_secret, :redacted}}
      end
    end
  end

  describe "create_account" do
    defp payload_plug(body, test_pid) do
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

    test "a missing, blank or non-string name is name_required, in the real call and the fake" do
      for bad <- [nil, "", "  ", :bot, 5] do
        assert Private.create_account(bad, @credentials, real_opts([])) ==
                 {:error, :name_required}

        assert Fake.create_account(name: bad, credentials: @credentials) ==
                 {:error, :name_required}
      end
    end

    test "the type is exchange or custody, as a string or an atom" do
      for bad <- ["vault", :vault, 5, %{}] do
        expected = {:error, {:invalid_option, :type, bad}}

        assert Private.create_account("Bot", @credentials, real_opts(type: bad)) == expected
        assert Fake.create_account(name: "Bot", type: bad, credentials: @credentials) == expected
      end
    end

    test "an atom type is sent as its string" do
      plug = payload_plug(%{"account" => "bot", "type" => "custody"}, self())

      assert {:ok, %{"account" => "bot"}} =
               Private.create_account("Bot", @credentials,
                 type: :custody,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:payload, %{"type" => "custody", "name" => "Bot"}}, 5_000

      assert {:ok, %{"account" => "bot", "type" => "custody"}} =
               Fake.create_account(name: "Bot", type: :custody, credentials: @credentials)
    end
  end

  describe "rename_account" do
    test "a blank or non-string account, name or shortname is refused before signing" do
      for bad <- ["", "  ", 5, %{}] do
        base = [account: "old", name: "New"]

        for key <- [:account, :name, :shortname] do
          opts = Keyword.put(base, key, bad)

          assert Private.rename_account(@credentials, real_opts(opts)) ==
                   {:error, {:invalid_option, key, bad}}
        end

        creds = [credentials: @credentials]

        assert Fake.rename_account(bad, "New", creds) ==
                 {:error, {:invalid_option, :account, bad}}

        assert Fake.rename_account("old", bad, creds) == {:error, {:invalid_option, :name, bad}}

        assert Fake.rename_account("old", "New", [shortname: bad] ++ creds) ==
                 {:error, {:invalid_option, :shortname, bad}}
      end
    end

    test "nothing to rename is still its own refusal" do
      assert Private.rename_account(@credentials, real_opts(account: "old")) ==
               {:error, :nothing_to_rename}
    end
  end

  describe "get_fees/2 :symbol" do
    test "a symbol that cannot be sent is refused, not dropped" do
      for bad <- [:btcusd, "", "   ", 42, %{}] do
        real = Private.get_fees(@credentials, real_opts(symbol: bad))

        assert real == {:error, {:invalid_option, :symbol, bad}}
        assert Fake.get_fees(@credentials, symbol: bad) == real
      end
    end

    test "absent and nil are the general schedule" do
      body = %{"api_maker_fee_bps" => 10}

      for opts <- [[], [symbol: nil]] do
        assert {:ok, ^body} =
                 Private.get_fees(@credentials, [plug: json(body), retry_attempts: 0] ++ opts)
      end

      assert {:ok, _fees} = Fake.get_fees(@credentials, symbol: "BTC-USD")
    end
  end

  describe "withdrawals and transfers: memo and idempotency key" do
    test "a memo that is neither a string nor a whole number is refused" do
      for bad <- [%{"a" => 1}, [1], 1.5, -1, :tag, true] do
        assert withdraw(memo: bad) == {:error, {:invalid_memo, bad}}
        assert fake_withdraw(memo: bad) == {:error, {:invalid_memo, bad}}
      end
    end

    test "a client_transfer_id that is neither a string nor absent is refused" do
      for bad <- [42, %{}, :id, ["a"]] do
        expected = {:error, {:invalid_option, :client_transfer_id, bad}}
        transfer = [from: "primary", to: "other", client_transfer_id: bad]

        assert withdraw(client_transfer_id: bad) == expected
        assert fake_withdraw(client_transfer_id: bad) == expected

        real = Private.transfer_internal("USD", 1, transfer, @credentials, real_opts([]))

        assert real == expected
        assert Fake.transfer_internal("USD", 1, transfer, credentials: @credentials) == expected
      end
    end
  end

  describe "preview_margin_order/3 with a side or type that is not text" do
    test "is the missing-fields refusal, not a Protocol.UndefinedError" do
      request = %{symbol: "BTC-USD", side: :buy, type: "limit"}

      for bad <- [%{}, [:buy], {:buy}] do
        bad_side = %{request | side: bad}
        bad_type = %{request | type: bad}

        assert Private.preview_margin_order(bad_side, @credentials, real_opts([])) ==
                 {:error, :missing_order_fields}

        assert Private.preview_margin_order(bad_type, @credentials, real_opts([])) ==
                 {:error, :missing_order_fields}
      end
    end
  end

  describe "the funding reports check their query before signing it" do
    test "the amount report needs a symbol" do
      for bad <- [nil, "", "  ", :btc, 5] do
        assert Private.funding_amount_report(bad, @credentials, real_opts([])) ==
                 {:error, {:invalid_option, :symbol, bad}}
      end
    end

    test "a row count is a positive integer" do
      for bad <- ["abc", 0, -5, 1.5, %{}] do
        expected = {:error, {:invalid_option, :rows, bad}}
        opts = real_opts(rows: bad)

        assert Private.funding_payment_report(@credentials, opts) == expected
        assert Private.funding_payment_report_file(@credentials, opts) == expected
        assert Private.funding_amount_report("BTCGUSDPERP", @credentials, opts) == expected
      end
    end

    test "a date is a date" do
      for bad <- ["yesterday", 5, %{}, "2024-13-45"] do
        assert Private.funding_payment_report(@credentials, real_opts(from: bad)) ==
                 {:error, {:invalid_option, :from, bad}}

        assert Private.funding_payment_report(@credentials, real_opts(to: bad)) ==
                 {:error, {:invalid_option, :to, bad}}

        both = real_opts(from: bad, to: ~D[2024-04-25])

        assert Private.funding_payment_report_file(@credentials, both) ==
                 {:error, {:invalid_option, :from, bad}}
      end
    end

    test "an ISO date string is a date, and reaches the signed query" do
      me = self()

      assert {:ok, []} =
               Private.funding_payment_report(@credentials,
                 from: "2024-04-10",
                 to: ~D[2024-04-25],
                 rows: 1000,
                 plug: reporting([], me),
                 retry_attempts: 0
               )

      assert_receive {:query, query}, 5_000
      assert query =~ "fromDate=2024-04-10"
      assert query =~ "toDate=2024-04-25"
      assert query =~ "numRows=1000"
    end

    test "the payment reports take no symbol, so a shared one is not sent" do
      me = self()

      assert {:ok, []} =
               Private.funding_payment_report(@credentials,
                 symbol: "BTCGUSDPERP",
                 plug: reporting([], me),
                 retry_attempts: 0
               )

      assert_receive {:query, ""}, 5_000

      file_plug = fn conn ->
        send(me, {:query, conn.query_string})
        Plug.Conn.resp(conn, 200, "bytes")
      end

      assert {:ok, "bytes"} =
               Private.funding_payment_report_file(@credentials,
                 symbol: "BTCGUSDPERP",
                 plug: file_plug,
                 retry_attempts: 0
               )

      assert_receive {:query, ""}, 5_000
    end
  end

  describe "staking writes: provider_id" do
    test "anything but a non-blank string is refused, in the real call and the fake" do
      for bad <- [5, %{}, :p, "", "  "] do
        expected = {:error, {:invalid_option, :provider_id, bad}}
        fake_opts = [provider_id: bad, credentials: @credentials]

        assert Private.stake("ETH", 1, @credentials, real_opts(provider_id: bad)) == expected
        assert Private.unstake("ETH", 1, @credentials, real_opts(provider_id: bad)) == expected
        assert Fake.stake("ETH", 1, fake_opts) == expected
        assert Fake.unstake("ETH", 1, fake_opts) == expected
      end
    end

    test "absent is still the missing-provider refusal" do
      assert Private.stake("ETH", 1, @credentials, real_opts([])) ==
               {:error, :missing_provider_id}

      assert Fake.stake("ETH", 1, credentials: @credentials) == {:error, :missing_provider_id}
    end
  end

  describe "get_deposit_address/4 asset and free-text fields" do
    test "a blank or non-string asset is refused, in the real call and the fake" do
      for bad <- [nil, "", "  ", :eth] do
        expected = {:error, {:invalid_asset, bad}}

        real = Private.get_deposit_address(bad, "ethereum", @credentials, real_opts([]))

        assert real == expected
        assert Fake.get_deposit_address(bad, "ethereum", credentials: @credentials) == expected
      end
    end

    test "the network is checked before the asset" do
      assert Private.get_deposit_address(nil, nil, @credentials, real_opts([])) ==
               {:error, {:invalid_network, nil}}
    end

    test "a memo or label that is not text does not reach a string field" do
      body = %{"address" => "0xabc", "network" => "ethereum", "memo" => 12_345, "label" => %{}}

      assert {:ok, %DepositAddress{memo: "12345", label: nil}} =
               Private.get_deposit_address("ETH", "ethereum", @credentials,
                 plug: json(body),
                 retry_attempts: 0
               )
    end

    test "an approved address label that is not text is nil" do
      body = %{"approvedAddresses" => [%{"address" => "0x1", "label" => %{"x" => 1}}]}

      assert {:ok, [address]} =
               Private.list_approved_addresses(@credentials,
                 network: "ethereum",
                 plug: json(body),
                 retry_attempts: 0
               )

      assert address.label == nil
    end

    test "an FX rate's source and benchmark are text or nil" do
      body = %{
        "fxPair" => "EURUSD",
        "rate" => "1.1",
        "asOf" => 1_700_000_000_000,
        "provider" => %{"a" => 1},
        "benchmark" => true
      }

      opts = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, %FxRate{pair: "EURUSD", source: nil, benchmark: nil}} =
               Private.get_fx_rate("EURUSD", @fx_at, [plug: json(body)] ++ opts)

      unnamed = %{body | "fxPair" => %{}}

      assert {:ok, %FxRate{pair: "EURUSD"}} =
               Private.get_fx_rate("EURUSD", @fx_at, [plug: json(unnamed)] ++ opts)
    end
  end

  describe "get_order_book/2 :depth" do
    test "anything but a whole number of levels is refused, in the real call and the fake" do
      for bad <- ["ten", -1, 1.5, %{}, :all] do
        expected = {:error, {:invalid_option, :depth, bad}}

        assert Rest.get_order_book("BTC-USD", real_opts(depth: bad)) == expected
        assert Fake.get_order_book("BTC-USD", depth: bad) == expected
        # Before the symbol: the venue is never asked, so it never refuses it.
        assert Fake.get_order_book("NOPE-USD", depth: bad) == expected
      end
    end

    test "zero, a positive number and nil are sent or defaulted" do
      me = self()
      body = %{"bids" => [], "asks" => []}
      cases = [{0, "limit_bids=0"}, {7, "limit_bids=7"}, {nil, "limit_bids=50"}]

      for {depth, expected} <- cases do
        assert {:ok, _book} =
                 Rest.get_order_book("BTC-USD",
                   depth: depth,
                   plug: reporting(body, me),
                   retry_attempts: 0
                 )

        assert_receive {:query, query}, 5_000
        assert query =~ expected
      end

      assert {:ok, _book} = Fake.get_order_book("BTC-USD", depth: 3)
    end
  end

  describe "Feed forwards :ssl_options to the sockets it dials" do
    # `usage-rules.md` tells a consumer to pass its own `:ssl_options`, and `Feed` kept only
    # four options for its sockets, so there was no way to.
    test "the option reaches the socket options" do
      name = :"feed_#{System.unique_integer([:positive])}"
      ssl = [verify: :verify_none]

      {:ok, feed} = Feed.start_link(name: name, ssl_options: ssl)

      assert :sys.get_state(feed).socket_opts[:ssl_options] == ssl
    end
  end
end
