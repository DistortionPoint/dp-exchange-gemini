defmodule DpExchange.Gemini.AuthTest do
  use ExUnit.Case, async: true

  alias DpExchange.Gemini.Auth

  @api_key %{api_key: "account-abc123", api_secret: "test-secret-not-a-real-key"}
  @oauth %{access_token: "test-access-token-not-a-real-one"}

  defp header(headers, name) do
    Enum.find_value(headers, fn {header_name, value} -> if header_name == name, do: value end)
  end

  describe "the scheme is named by the host and never inferred" do
    test "an unknown scheme is refused rather than guessed at" do
      # Guessing is not a kindness here. Gemini returns `AmbiguousAuthentication` (400)
      # when V1 key headers and OAuth headers arrive together, so a module that attached
      # whatever it recognised would eventually attach both.
      assert {:error, {:unsupported_auth_scheme, :jwt}} =
               Auth.headers(:jwt, "/v1/balances", %{}, @api_key)
    end

    test "credentials that do not match the named scheme are refused, not half-signed" do
      # A partially-signed request fails at the venue with an error about signatures,
      # which sends the reader looking in the wrong place.
      assert {:error, {:missing_credentials, :api_key}} =
               Auth.headers(:api_key, "/v1/balances", %{}, @oauth)

      assert {:error, {:missing_credentials, :oauth}} =
               Auth.headers(:oauth, "/v1/balances", %{}, @api_key)
    end

    test "there is no default scheme" do
      # Not a missing feature. Which authentication an application uses is a decision
      # about its users and its deployment, and this package is not entitled to make it.
      assert {:error, {:unsupported_auth_scheme, nil}} =
               Auth.headers(nil, "/v1/balances", %{}, @api_key)
    end
  end

  describe "API key signing" do
    test "carries the six headers the venue requires" do
      assert {:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, @api_key)
      names = headers |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert names == [
               "Cache-Control",
               "Content-Length",
               "Content-Type",
               "X-GEMINI-APIKEY",
               "X-GEMINI-PAYLOAD",
               "X-GEMINI-SIGNATURE"
             ]
    end

    test "the body is empty and the payload rides in a header" do
      assert {:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, @api_key)

      assert {"Content-Length", "0"} in headers
      assert {"Content-Type", "text/plain"} in headers
    end

    test "the payload names the endpoint it is for" do
      # Gemini requires the path INSIDE the signed payload. It is what makes a captured
      # request unusable against a different endpoint — the signature covers the target.
      assert {:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, @api_key)
      payload = headers |> header("X-GEMINI-PAYLOAD") |> Base.decode64!() |> Jason.decode!()

      assert payload["request"] == "/v1/balances"
    end

    test "the signature is HMAC-SHA384 over the base64 payload, hex-encoded" do
      assert {:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, @api_key)
      payload = header(headers, "X-GEMINI-PAYLOAD")

      expected =
        :hmac
        |> :crypto.mac(:sha384, @api_key.api_secret, payload)
        |> Base.encode16(case: :lower)

      assert header(headers, "X-GEMINI-SIGNATURE") == expected
      assert String.length(expected) == 96
    end

    test "caller parameters survive into the payload" do
      assert {:ok, headers} =
               Auth.headers(:api_key, "/v1/order/status", %{"order_id" => 123}, @api_key)

      payload = headers |> header("X-GEMINI-PAYLOAD") |> Base.decode64!() |> Jason.decode!()

      assert payload["order_id"] == 123
    end

    test "the secret never appears in any header value" do
      # These packages are public and headers get pasted into issues.
      assert {:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, @api_key)

      for {_name, value} <- headers do
        refute String.contains?(value, @api_key.api_secret)
      end
    end
  end

  describe "OAuth" do
    test "the token is attached, and nothing else happens" do
      # This package cannot refresh what it did not fetch. Obtaining the token, keeping it
      # fresh, and deciding what to do when refresh fails are the host's flow.
      assert {:ok, headers} = Auth.headers(:oauth, "/v1/balances", %{}, @oauth)

      assert headers == [{"Authorization", "Bearer " <> @oauth.access_token}]
    end

    test "no nonce, no signature, no key headers" do
      # Sending both families together is `AmbiguousAuthentication` at the venue.
      assert {:ok, headers} = Auth.headers(:oauth, "/v1/balances", %{}, @oauth)
      names = Enum.map(headers, &elem(&1, 0))

      refute "X-GEMINI-APIKEY" in names
      refute "X-GEMINI-PAYLOAD" in names
      refute "X-GEMINI-SIGNATURE" in names
    end
  end

  describe "nonce/1 — the two modes need differently-shaped values" do
    test "time-based is Unix SECONDS, inside the venue's ±30s window" do
      nonce = Auth.nonce(:time_based)
      now = System.system_time(:second)

      assert is_integer(nonce)
      assert abs(nonce - now) <= 1
    end

    test "incremental is milliseconds, which a time-based key would reject" do
      # A millisecond value is ~1000x a seconds timestamp, so it lands far outside the
      # ±30 second window a time-based key validates against.
      assert Auth.nonce(:incremental) > System.system_time(:second) * 100
    end

    test "incremental never repeats, even called in a tight loop" do
      nonces = for _index <- 1..500, do: Auth.nonce(:incremental)

      assert length(Enum.uniq(nonces)) == 500
      assert nonces == Enum.sort(nonces)
    end

    test "incremental is monotonic ACROSS processes, not just within one" do
      # The property that matters, and the one a process-dictionary counter would not
      # have. The counter is established up front exactly as the supervisor does it — a
      # lazy init races here, and that race is what this test caught.
      Auth.ensure_counter()

      task = Task.async(fn -> for _index <- 1..200, do: Auth.nonce(:incremental) end)
      mine = for _index <- 1..200, do: Auth.nonce(:incremental)
      theirs = Task.await(task)

      assert length(Enum.uniq(mine ++ theirs)) == 400
    end

    test "the default is the venue's own recommendation" do
      assert Auth.nonce() == Auth.nonce(:time_based)
    end

    test "the mode reaches the signed payload" do
      assert {:ok, timed} = Auth.headers(:api_key, "/v1/balances", %{}, @api_key)

      assert {:ok, incremental} =
               Auth.headers(:api_key, "/v1/balances", %{}, @api_key, nonce_mode: :incremental)

      assert nonce_from(timed) < nonce_from(incremental) / 100
    end
  end

  defp nonce_from(headers) do
    headers
    |> header("X-GEMINI-PAYLOAD")
    |> Base.decode64!()
    |> Jason.decode!()
    |> Map.fetch!("nonce")
  end
end
