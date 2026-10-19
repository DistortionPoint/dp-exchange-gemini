defmodule DpExchange.Gemini.TickAAPrivateBTest do
  @moduledoc """
  Tick AA: branches of `DpExchange.Gemini.Private` that no test reached (the second half of
  the module).

  Each test drives the public function through the `plug:` seam, so what is measured is the
  decode path a consumer reaches. Most are refusals: a reply this package cannot read is an
  error, never an empty or partial answer.
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

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  @date "Fri, 28 Aug 2026 17:00:01 GMT"

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  # The venue's bytes exactly as written, for a JSON number `Req.Test.json/2` cannot produce.
  defp raw(json) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, json)
    end
  end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  describe "withdraw/6 states only what WithdrawCryptoFundsResponse states" do
    test "a status the schema does not define on the reply is not a source: always pending" do
      for venue <- ["completed", "failed", "cancelled", "complete"] do
        body = %{"withdrawalId" => "w-1", "status" => venue}

        assert {:ok, withdrawal} =
                 Private.withdraw(
                   "ETH",
                   "ethereum",
                   Decimal.new("1"),
                   "0xabc",
                   @credentials,
                   opts(responding(body))
                 )

        assert withdrawal.status == :pending
      end
    end
  end

  describe "list_payment_methods/2 refuses what it cannot read" do
    test "a reply that is not an object is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Private.list_payment_methods(@credentials, opts(responding([%{"id" => "b"}])))
    end

    test "a row that is not an object is unreadable, not dropped" do
      body = %{"balances" => [%{"id" => "b-1"}, "x"], "banks" => []}

      assert {:error, :unexpected_response_shape} =
               Private.list_payment_methods(@credentials, opts(responding(body)))
    end
  end

  describe "get_transactions/2 paging" do
    test "a walk that never ends is refused at the page cap, not followed forever" do
      # Every page has rows and a fresh token, so the walk can only stop at the cap.
      plug = fn conn ->
        payload =
          conn
          |> Plug.Conn.get_req_header("x-gemini-payload")
          |> List.first()
          |> Base.decode64!()
          |> Jason.decode!()

        token = (payload["continuation_token"] || "tok") <> "-"
        body = %{"results" => [%{"eid" => 1}], "continuationToken" => token}
        responding(body).(conn)
      end

      assert {:error, {:too_many_pages, 50}} = Private.get_transactions(@credentials, opts(plug))
    end

    test "an empty token is the last page" do
      body = %{"results" => [%{"type" => "trade"}], "continuationToken" => ""}

      assert {:ok, [%{"type" => "trade"}]} =
               Private.get_transactions(@credentials, opts(responding(body)))
    end

    test "a token that is not a string is unreadable" do
      body = %{"results" => [%{"type" => "trade"}], "continuationToken" => 5}

      assert {:error, :unexpected_response_shape} =
               Private.get_transactions(@credentials, opts(responding(body)))
    end
  end

  describe "staking reads refuse what they cannot read" do
    test "a reward period that is not an object is unreadable" do
      body = %{"provider-1" => %{"ETH" => %{"ratePeriods" => ["x"]}}}

      assert {:error, :unexpected_response_shape} =
               Private.get_staking_rewards(
                 @credentials,
                 [since: ~U[2026-08-01 00:00:00Z]] ++ opts(responding(body))
               )
    end

    test "a history transaction that is not an object is unreadable" do
      body = [%{"providerId" => "provider-1", "transactions" => ["x"]}]

      assert {:error, :unexpected_response_shape} =
               Private.get_staking_history(@credentials, opts(responding(body)))
    end

    test "an epoch past the calendar is unreadable, not dated" do
      # 10^16 ms is past year 9999: `DateTime.from_unix/2` refuses it.
      json =
        ~s([{"providerId":"p-1","transactions":[{"transactionId":"t-1",) <>
          ~s("transactionType":"Deposit","amountCurrency":"eth","amount":"1",) <>
          ~s("dateTime":10000000000000000}]}])

      assert {:error, :unexpected_response_shape} =
               Private.get_staking_history(@credentials, opts(raw(json)))
    end

    test "an epoch with an exponent no real time has is unreadable, never expanded" do
      # `1e40` decodes as a `Decimal` with exponent 40, outside the bound read before any
      # arithmetic.
      json =
        ~s([{"providerId":"p-1","transactions":[{"transactionId":"t-1",) <>
          ~s("transactionType":"Deposit","amountCurrency":"eth","amount":"1",) <>
          ~s("dateTime":1e40}]}])

      assert {:error, :unexpected_response_shape} =
               Private.get_staking_history(@credentials, opts(raw(json)))
    end
  end

  describe "get_positions/2" do
    test "a symbol that is not a string names no instrument, so the row is refused" do
      body = %{"openPositions" => [%{"symbol" => 42, "quantity" => "0.2"}]}

      assert {:error, {:missing_required_field, :symbol}} =
               Private.get_positions(@credentials, opts(responding(body)))
    end
  end

  describe "funding_amount_report/3" do
    test "DateTime bounds are sent as the venue's dates" do
      me = self()

      plug = fn conn ->
        send(me, {:query, URI.decode_query(conn.query_string)})
        Plug.Conn.resp(conn, 200, "xlsx-bytes")
      end

      assert {:ok, "xlsx-bytes"} =
               Private.funding_amount_report(
                 "BTCGUSDPERP",
                 @credentials,
                 [from: ~U[2026-08-01 10:00:00Z], to: ~U[2026-08-02 23:59:59Z]] ++ opts(plug)
               )

      assert_receive {:query, query}, 5_000

      assert query == %{
               "symbol" => "BTCGUSDPERP",
               "fromDate" => "2026-08-01",
               "toDate" => "2026-08-02"
             }
    end
  end

  describe "get_margin_rates/2" do
    test "a null rate list is no rates" do
      assert {:ok, []} =
               Private.get_margin_rates(@credentials, opts(responding(%{"rates" => nil})))
    end

    test "a bare list is the rates" do
      rates = [%{"currency" => "BTC", "borrowRate" => "0.0001"}]

      assert {:ok, ^rates} = Private.get_margin_rates(@credentials, opts(responding(rates)))
    end
  end

  describe "refresh_access_token/3" do
    test "a status other than 400, 401 or 403 is an error, not a refusal" do
      plug = fn conn -> Plug.Conn.resp(conn, 404, "no such route") end

      assert {:error, {:exchange_error, :gemini, "HTTP 404" <> _rest}} =
               Private.refresh_access_token("client-1", "old-refresh", opts(plug))
    end
  end

  describe "clearing lists" do
    test "a null order list is no orders" do
      assert {:ok, []} =
               Private.list_clearing_orders(@credentials, opts(responding(%{"orders" => nil})))
    end

    test "an order list that is not a list is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Private.list_clearing_orders(@credentials, opts(responding(%{"orders" => "x"})))
    end

    test "a bare list is the orders" do
      rows = [%{"clearing_id" => "c-1"}]

      assert {:ok, ^rows} = Private.list_clearing_orders(@credentials, opts(responding(rows)))
    end

    test "a reply that is neither an object nor a list is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Private.list_clearing_orders(@credentials, opts(responding("x")))
    end
  end

  describe "a path segment that is only a dot" do
    test "is encoded, so it is not a dot-segment" do
      assert Private.network_lookup_path(".", nil) == {:ok, "/v2/network/%2E"}
    end
  end
end
