defmodule DpExchange.Gemini.WriteOnceTest do
  @moduledoc """
  A write the venue cannot tell from its own repeat is sent once — under OAuth too.

  `post/4` signs once and `Core.HttpClient` re-sends the same signed request after a
  transport error. Under API-key auth the repeat is refused for its nonce; under OAuth
  there is no nonce, and the repeat takes effect a second time. See `Private.post_once/4`.
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

  @oauth %{access_token: "oauth-token-not-real"}

  @terms %{
    symbol: "BTC-USD",
    amount: Decimal.new("0.5"),
    price: Decimal.new("60000"),
    side: :buy
  }

  # Every request times out after reaching the plug, which is exactly the case where the
  # venue may have acted without the caller hearing. Counted, so a retry shows.
  defp timing_out(test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path})
      Req.Test.transport_error(conn, :timeout)
    end
  end

  defp opts(extra), do: [plug: timing_out(self()), retry_delay: 1] ++ extra

  defp requests(acc \\ []) do
    receive do
      {:request, path} -> requests([path | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "an internal transfer is sent once" do
    Private.transfer_internal("USD", Decimal.new("1"), [from: "a", to: "b"], @oauth, opts([]))
    assert [_one] = requests()
  end

  test "a clearing order is sent once" do
    Private.create_clearing_order(@terms, @oauth, opts(counterparty_id: "cp-1"))
    assert [_one] = requests()
  end

  test "a broker clearing order is sent once" do
    Private.create_broker_clearing_order(
      @terms,
      @oauth,
      opts(source_counterparty_id: "s", target_counterparty_id: "t", expires_in_hrs: 24)
    )

    assert [_one] = requests()
  end
end
