defmodule DpExchange.Gemini.NonceReorderTest do
  @moduledoc """
  An `InvalidNonce` refusal is answered by signing once more with a fresh nonce.

  Two processes draw ordered nonces, but the one holding the smaller can reach the venue
  second, and the venue refuses it although it never acted on it. The refusal is scripted by
  hand here: the first request is answered `InvalidNonce`, the rest as the test says.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.Private

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

  @reordered %{
    "result" => "error",
    "reason" => "InvalidNonce",
    "message" => "Nonce '1790688000001' has not increased since your last call to the Gemini API."
  }

  # Answers the n-th request with the n-th `{status, body}`, and reports each request's nonce.
  defp scripted(test_pid, answers) do
    counter = :counters.new(1, [])

    fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      [payload] = Plug.Conn.get_req_header(conn, "x-gemini-payload")
      %{"nonce" => nonce} = payload |> Base.decode64!() |> Jason.decode!()
      send(test_pid, {:request, n, nonce})
      {status, body} = Enum.at(answers, n - 1, List.last(answers))

      # A balance is dated by the venue's own `Date` header, so a successful read needs one.
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  test "a read refused InvalidNonce is signed again with a fresh nonce, and succeeds" do
    plug = scripted(self(), [{400, @reordered}, {200, []}])

    assert {:ok, []} =
             Private.get_balances(@credentials,
               plug: plug,
               retry_attempts: 0,
               nonce_mode: :incremental
             )

    assert_received {:request, 1, first}
    assert_received {:request, 2, second}
    assert second != first
    refute_received {:request, 3, _nonce}
  end

  test "a second InvalidNonce is returned as the venue said it, after exactly two requests" do
    plug = scripted(self(), [{400, @reordered}])

    assert {:refused, {:invalid_nonce, _message}} =
             Private.get_balances(@credentials,
               plug: plug,
               retry_attempts: 0,
               nonce_mode: :incremental
             )

    assert_received {:request, 2, _nonce}
    refute_received {:request, 3, _nonce}
  end

  test "a withdrawal refused InvalidNonce, then refused on its merits, is a refusal" do
    # The first attempt provably did nothing, so the second is not "a repeat of a request the
    # venue may already have taken": its refusal is the venue's verdict, not unconfirmed.
    refusal = %{"result" => "error", "reason" => "InsufficientFunds", "message" => "no"}
    plug = scripted(self(), [{400, @reordered}, {400, refusal}])

    assert {:refused, reason} =
             Private.withdraw("ETH", "ethereum", Decimal.new("1"), "0xabc", @credentials,
               client_transfer_id: "sent-id",
               nonce_mode: :incremental,
               plug: plug,
               retry_attempts: 0
             )

    refute inspect(reason) =~ "refused_after_retry"
    assert_received {:request, 2, _nonce}
  end

  test "under the default :time_based mode an InvalidNonce is clock skew, sent once" do
    # Whole seconds checked against a window around the venue's clock: signing again inside the
    # same second would send the identical nonce, and skew is not cured by a second try.
    plug = scripted(self(), [{400, @reordered}, {200, []}])

    assert {:refused, {:invalid_nonce, _message}} =
             Private.get_balances(@credentials, plug: plug, retry_attempts: 0)

    assert_received {:request, 1, _nonce}
    refute_received {:request, 2, _nonce}
  end
end
