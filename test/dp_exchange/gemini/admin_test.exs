defmodule DpExchange.Gemini.AdminTest do
  @moduledoc """
  Account administration and the OAuth token lifecycle.

  **The name you send is not the name you address by.** `create_account/3` takes a display
  name and the venue answers with a kebab-cased *shortname*, and that shortname is what every
  other endpoint's `account` parameter takes. A caller that kept what it sent would address
  the wrong subaccount, or nothing.

  **Refreshing rotates the refresh token.** The response carries a new one and the old stops
  working, so a caller that stores only the access token has a session that ends at the next
  refresh.

  And the refresh endpoint is on **a different host** with a form body — the same URL the
  host's initial code exchange posts to, separated only by `grant_type`. That is the
  concrete case for why the package/host split cannot be read off a path.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "master-test", api_secret: "test-secret-not-real"}
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
        |> case do
          nil -> %{}
          encoded -> encoded |> Base.decode64!() |> Jason.decode!()
        end

      send(test_pid, {:payload, payload, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  describe "create_account/3" do
    test "the shortname the venue returns is not the name that was sent" do
      body = %{"account" => "my-secondary-account", "type" => "exchange"}

      assert {:ok, account} =
               Private.create_account("My Secondary Account", @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert account["account"] == "my-secondary-account"
      refute account["account"] == "My Secondary Account"
    end

    test "no type is sent unless the caller chose one" do
      # Choosing between an exchange account and a custody account for a caller who did not
      # is choosing what the account can do.
      me = self()

      assert {:ok, _account} =
               Private.create_account("Bot One", @credentials,
                 plug: capturing(%{"account" => "bot-one"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/account/create"}
      assert payload["name"] == "Bot One"
      refute Map.has_key?(payload, "type")

      assert {:ok, _account} =
               Private.create_account("Vault", @credentials,
                 type: "custody",
                 plug: capturing(%{"account" => "vault"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload2, _path}
      assert payload2["type"] == "custody"
    end
  end

  describe "rename_account/2" do
    test "the display name and the shortname are different fields" do
      # Changing the second changes how the account is addressed.
      me = self()

      assert {:ok, _result} =
               Private.rename_account(@credentials,
                 account: "bot-one",
                 name: "Bot One (retired)",
                 shortname: "bot-one-retired",
                 plug: capturing(%{"name" => "Bot One (retired)"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, "/v1/account/rename"}
      assert payload["account"] == "bot-one"
      assert payload["newName"] == "Bot One (retired)"
      assert payload["newAccount"] == "bot-one-retired"
    end

    test "either alone is enough" do
      me = self()

      assert {:ok, _result} =
               Private.rename_account(@credentials,
                 name: "Renamed",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload, _path}
      assert payload["newName"] == "Renamed"
      refute Map.has_key?(payload, "newAccount")
    end

    test "neither is refused rather than sent as a call that changes nothing" do
      assert {:error, :nothing_to_rename} =
               Private.rename_account(@credentials, account: "bot-one")
    end
  end

  describe "list_accounts/2 and get_roles/2" do
    test "no limit is sent unless asked, and the cap is the venue's" do
      # 500 is both maximum and default and there is no cursor, so a larger group returns a
      # truncated list with nothing to say it was truncated.
      me = self()

      assert {:ok, []} =
               Private.list_accounts(@credentials, plug: capturing([], me), retry_attempts: 0)

      assert_receive {:payload, payload, "/v1/account/list"}
      refute Map.has_key?(payload, "limit_accounts")

      assert {:ok, []} =
               Private.list_accounts(@credentials,
                 limit: 500,
                 since: ~U[2026-08-28 17:00:01Z],
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload2, _path}
      assert payload2["limit_accounts"] == 500
      assert payload2["timestamp"] == 1_787_936_401_000
    end

    test "rows carry the shortname other endpoints address by" do
      body = [
        %{"name" => "Primary", "account" => "primary", "type" => "exchange"},
        %{
          "name" => "Vault",
          "account" => "vault",
          "type" => "custody",
          "counterparty_id" => "None"
        }
      ]

      assert {:ok, [primary, vault]} =
               Private.list_accounts(@credentials, plug: responding(body), retry_attempts: 0)

      assert primary["account"] == "primary"
      # The venue's own string on a custody account, not a nil.
      assert vault["counterparty_id"] == "None"
    end

    test "roles come back as three booleans, because two of them combine" do
      body = %{"isAuditor" => false, "isFundManager" => true, "isTrader" => true}

      assert {:ok, roles} =
               Private.get_roles(@credentials, plug: responding(body), retry_attempts: 0)

      assert roles["isFundManager"] and roles["isTrader"]
      refute roles["isAuditor"]
    end
  end

  describe "the OAuth token lifecycle" do
    test "a refresh posts a form to the auth host, not the API host" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.host, conn.request_path, raw})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new-access",
            "refresh_token" => "new-refresh",
            "token_type" => "bearer",
            "expires_in" => 86_400
          })
        )
      end

      assert {:ok, tokens} =
               Private.refresh_access_token("client-1", "old-refresh",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:request, host, path, raw}
      assert host == "exchange.gemini.com"
      assert path == "/auth/token"

      form = URI.decode_query(raw)
      assert form["grant_type"] == "refresh_token"
      assert form["client_id"] == "client-1"
      assert form["refresh_token"] == "old-refresh"
      # A public client must not send one, and none was given.
      refute Map.has_key?(form, "client_secret")

      # The new refresh token replaces the old: a caller storing only the access token has a
      # session that ends at the next refresh.
      assert tokens["refresh_token"] == "new-refresh"
      refute tokens["refresh_token"] == "old-refresh"
    end

    test "a confidential client's secret is sent when given" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:form, URI.decode_query(raw)})
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"access_token" => "a"}))
      end

      assert {:ok, _tokens} =
               Private.refresh_access_token("client-1", "old-refresh",
                 client_secret: "s3cret",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:form, form}
      assert form["client_secret"] == "s3cret"
    end

    test "a rejected refresh is a refusal, because retrying the same token cannot work" do
      plug = fn conn ->
        Plug.Conn.resp(conn, 400, Jason.encode!(%{"error" => "invalid_grant"}))
      end

      assert {:refused, _body} =
               Private.refresh_access_token("client-1", "expired", plug: plug, retry_attempts: 0)
    end

    test "revoking needs an OAuth token and refuses an API key" do
      # An API-key-signed call would revoke nothing and come back shaped like success.
      assert {:error, :oauth_token_required} =
               Private.revoke_access_token(@credentials, [])
    end

    test "revoking with a token reaches the venue" do
      me = self()

      assert {:ok, _result} =
               Private.revoke_access_token(%{access_token: "tok"},
                 plug: capturing(%{"message" => "revoked"}, me),
                 retry_attempts: 0
               )

      assert_receive {:payload, _payload, "/v1/oauth/revokeByToken"}
    end
  end

  describe "the fake and the facade" do
    test "the fake derives a shortname rather than echoing the name" do
      assert {:ok, account} =
               Fake.create_account(credentials: @credentials, name: "My Secondary Account")

      assert account["account"] == "my-secondary-account"
    end

    test "the fake refuses a nameless create and reports combined roles" do
      assert {:error, :name_required} = Fake.create_account(credentials: @credentials)

      assert {:ok, %{"isTrader" => true, "isFundManager" => true, "isAuditor" => false}} =
               Fake.get_roles(credentials: @credentials)
    end

    test "the facade delegates each" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:error, :name_required} = DpExchange.Gemini.create_account(base)

      assert {:ok, _account} =
               DpExchange.Gemini.create_account(
                 base ++ [name: "Bot", plug: responding(%{"account" => "bot"})]
               )

      assert {:ok, _renamed} =
               DpExchange.Gemini.rename_account("bot", "Bot Two", base ++ [plug: responding(%{})])

      assert {:ok, []} = DpExchange.Gemini.list_accounts(base ++ [plug: responding([])])
      assert {:ok, _roles} = DpExchange.Gemini.get_roles(base ++ [plug: responding(%{})])

      assert {:error, :oauth_token_required} = DpExchange.Gemini.revoke_access_token(base)
    end
  end
end
