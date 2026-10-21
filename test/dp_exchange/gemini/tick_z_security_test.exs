defmodule DpExchange.Gemini.TickZSecurityTest do
  @moduledoc """
  Pins the tick-Z security audit findings: header injection through a credential, cleartext
  transport for authenticated calls, and dot-segments in path parameters. Each test names the
  property; a plug that raises stands in for the venue, so a refusal asserted here happened
  BEFORE anything was sent.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  describe "a credential cannot carry a control character into a header" do
    test "an interior CR/LF in the key is refused, and the value is not echoed" do
      credentials = %{api_key: "account-x\r\nX-Injected: 1", api_secret: "test-secret-not-real"}

      assert {:error, {:invalid_credentials, :gemini}} =
               result = Auth.headers(:api_key, "/v1/balances", %{}, credentials)

      refute inspect(result) =~ "Injected"
    end

    test "an interior control character in the secret or the bearer token is refused" do
      assert {:error, {:invalid_credentials, :gemini}} =
               Auth.headers(:api_key, "/v1/balances", %{}, %{
                 api_key: "account-test",
                 api_secret: "test-secret\nnot-real"
               })

      assert {:error, {:invalid_credentials, :gemini}} =
               Auth.headers(:oauth, "/v1/balances", %{}, %{access_token: "tok\r\nX-Evil: 1"})
    end

    test "the payload and signature headers never contain CR or LF, whatever the params hold" do
      params = %{"note" => "a\r\nb\nc", "symbol" => String.duplicate("x", 10_000)}

      assert {:ok, headers} = Auth.headers(:api_key, "/v1/order/new", params, @credentials)

      for {name, value} <- headers, name in ["X-GEMINI-PAYLOAD", "X-GEMINI-SIGNATURE"] do
        refute String.contains?(value, ["\r", "\n"])
      end
    end

    test "the call is refused before it is sent, and the fake refuses it alike" do
      credentials = %{api_key: "account-x\r\nX-Injected: 1", api_secret: "test-secret-not-real"}

      assert {:error, {:invalid_credentials, :gemini}} =
               Private.get_balances(credentials, plug: exploding(), retry_attempts: 0)

      assert {:error, {:invalid_credentials, :gemini}} = Fake.get_balances(credentials, [])
    end
  end

  describe "an authenticated call is never sent over cleartext" do
    test "a signed POST to an http:// base_url is refused before it is signed or sent" do
      assert {:error, {:insecure_url, :gemini}} =
               Private.get_balances(@credentials,
                 base_url: "http://api.gemini.example",
                 plug: exploding(),
                 retry_attempts: 0
               )
    end

    test "a signed GET to an http:// base_url is refused" do
      assert {:error, {:insecure_url, :gemini}} =
               Private.list_networks("BTC",
                 credentials: @credentials,
                 base_url: "http://api.gemini.example",
                 plug: exploding(),
                 retry_attempts: 0
               )
    end

    test "the token refresh, which carries a refresh token and a client secret, is https only" do
      assert {:error, {:insecure_url, :gemini}} =
               Private.refresh_access_token("client-1", "old-refresh",
                 auth_url: "http://exchange.gemini.example",
                 client_secret: "test-secret-not-real",
                 plug: exploding(),
                 retry_attempts: 0
               )
    end

    test "a loopback http:// stub stays usable" do
      plug = fn conn -> Req.Test.json(conn, %{"isAuditor" => false}) end

      # The positive answer, not merely "not the cleartext refusal": the stub was reached and
      # its body decoded.
      assert {:ok, %{"isAuditor" => false}} =
               Private.get_roles(@credentials,
                 base_url: "http://localhost:4000",
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "a path parameter cannot be a dot-segment" do
    test "a signed route encodes `..` so it is not a traversal" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:request_path, conn.request_path})
        Req.Test.json(conn, [])
      end

      _answer =
        Private.list_networks("..",
          credentials: @credentials,
          plug: plug,
          retry_attempts: 0
        )

      assert_receive {:request_path, path}, 5_000
      refute String.ends_with?(path, "/..")
      assert String.ends_with?(path, "%2E%2E")
    end
  end
end
