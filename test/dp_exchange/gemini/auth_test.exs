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
      # `nil` here is not an unsupported SCHEME — nothing was named at all, so this is
      # the same shape as absent credentials: `{:missing_credentials, :gemini}`.
      assert {:error, {:missing_credentials, :gemini}} =
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
      # The property that matters, and the one a process-dictionary counter would not have:
      # given ONE counter, `compare_exchange/4` hands two processes ordered values.
      #
      # It used to claim more than that — "a lazy init races here, and that race is what
      # this test caught". It did not catch it. `ensure_counter/0` on the line below
      # establishes the counter, which is exactly what removes the race, and the assertion
      # then measured the loop rather than the creation. The creation race was real and
      # lost 33 of 40 callers; it is `auth_nonce_race_test.exs` that enters this cold.
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

  describe "a blank credential is a missing one, not one to sign with" do
    # `""` satisfies `is_binary/1`, and `is_binary/1` was the whole gate. An empty secret is
    # not a secret — it is the commonest misconfiguration there is, `.env` carrying
    # `NAME=` with nothing after it, which `System.get_env/1` hands back as `""` and not as
    # `nil`. Every module here documents that it refuses to sign a partial credential
    # precisely so the venue's answer does not send the reader to the signing code, which
    # is correct, instead of to the credential, which was never set.
    #
    # Gemini's own case: HMAC-SHA384 over an empty key is a perfectly good HMAC, so nothing
    # local failed and the request went out to be refused for a reason naming signatures.
    test "an empty or blank api_key or api_secret refuses by name" do
      for credentials <- [
            %{api_key: "k", api_secret: ""},
            %{api_key: "k", api_secret: "   "},
            %{api_key: "", api_secret: "s"},
            %{api_key: "   ", api_secret: "s"}
          ] do
        assert Auth.headers(:api_key, "/v1/balances", %{}, credentials) ==
                 {:error, {:missing_credentials, :api_key}},
               "#{inspect(credentials)} was signed with"
      end
    end

    test "an empty bearer token refuses rather than sending `Authorization: Bearer `" do
      assert Auth.headers(:oauth, "/v1/balances", %{}, %{access_token: ""}) ==
               {:error, {:missing_credentials, :oauth}}

      assert Auth.headers(:oauth, "/v1/balances", %{}, %{access_token: "  "}) ==
               {:error, {:missing_credentials, :oauth}}
    end

    test "a credential that is not a string refuses instead of crashing the caller" do
      # The head carried no `is_binary/1` on either field, so a non-binary matched it and
      # died inside `:crypto.mac/4` or `Jason.encode!/1` — in the CALLER's process, naming
      # crypto rather than the credential. It is the same condition as an absent field and
      # now gets the same answer.
      assert Auth.headers(:api_key, "/v1/balances", %{}, %{api_key: 12, api_secret: "s"}) ==
               {:error, {:missing_credentials, :api_key}}

      assert Auth.headers(:api_key, "/v1/balances", %{}, %{api_key: "k", api_secret: nil}) ==
               {:error, {:missing_credentials, :api_key}}
    end

    test "a real pair still signs" do
      assert {:ok, headers} =
               Auth.headers(:api_key, "/v1/balances", %{}, %{
                 api_key: "account-abc",
                 api_secret: "a-secret"
               })

      assert List.keyfind(headers, "X-GEMINI-SIGNATURE", 0) != nil
    end
  end
end
