defmodule DpExchange.Gemini.TickAAFacadeTest do
  @moduledoc """
  Tick AA: the facade lines no other test ran.

  Most are a public function's shortest arity, the one a consumer writes when it has no
  options to give. Each is called here exactly that way, with nothing to point it at a
  network, and each must answer with a refusal decided in the process: if any of them built
  and sent a request, the test would fail on a connection rather than on the refusal.

  The rest are the facade's two exit catches around the feed: a feed call that exits
  `:timeout`, and a coverage read whose feed exits mid-call.

  `async: false` because the streaming calls address the default-named feed, and
  `DpExchange.Gemini.SideBySideTest` (also synchronous) starts one under that name. Run
  synchronously, the two never overlap.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Core.Config
  alias DpExchange.Gemini

  @moduletag :capture_log

  # A limiter whose backing store cannot answer. `Core.HttpClient` fails closed on it before
  # anything is sent, which is what lets a public read be called with no options at all.
  defmodule UnavailableLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :store_unreachable}
    @impl true
    def check(_provider, _weight, _opts), do: {:error, :store_unreachable}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  @no_credentials %{}

  # A stand-in feed that takes one call and exits with `reason` instead of replying. Not
  # linked, so its exit reaches the caller only through `GenServer.call/3`'s monitor.
  defp feed_exiting_with(reason) do
    spawn(fn ->
      receive do
        {:"$gen_call", _from, _request} -> exit(reason)
      end
    end)
  end

  describe "public reads at their shortest arity" do
    test "list_instruments/0 meters before it sends, and fails closed on the limiter" do
      Config.put_override(:rate_limit_module, UnavailableLimiter)

      assert {:error, {:exchange_error, :gemini, "Rate limiter unavailable"}} =
               Gemini.list_instruments()
    end

    test "get_contract_stats/1 and next_funding_timestamp/1 refuse a blank symbol" do
      assert {:error, {:invalid_symbol, ""}} = Gemini.get_contract_stats("")
      assert {:error, {:invalid_symbol, ""}} = Gemini.next_funding_timestamp("")
    end
  end

  describe "private calls with no credentials never reach the network" do
    test "get_orders/1" do
      assert {:error, {:missing_credentials, :gemini}} = Gemini.get_orders(@no_credentials)
    end

    test "cancel_all_orders/2 refuses on scope first, then on credentials, and plainly" do
      # Decided before the send, so never `{:write_unconfirmed, _, _}`.
      assert {:error, :scope_required} = Gemini.cancel_all_orders(@no_credentials, [])

      assert {:error, {:missing_credentials, :gemini}} =
               Gemini.cancel_all_orders(@no_credentials, scope: :session)
    end

    test "get_trade_volume/2" do
      assert {:error, {:missing_credentials, :gemini}} =
               Gemini.get_trade_volume(@no_credentials, [])
    end

    test "the account administration calls" do
      assert {:error, :name_required} = Gemini.create_account()

      assert {:error, {:missing_credentials, :gemini}} =
               Gemini.rename_account("primary", "Renamed")

      assert {:error, {:missing_credentials, :gemini}} = Gemini.list_accounts()
    end

    test "the OAuth token calls refuse what they cannot send" do
      assert {:error, :client_id_required} =
               Gemini.refresh_access_token("", "refresh-token-not-real")

      assert {:error, :oauth_token_required} = Gemini.revoke_access_token()
    end

    test "seed_nonce/1 refuses a seed it cannot hold, without moving the counter" do
      # Neither value is applied, so the process-wide nonce counter is left as it was.
      assert {:error, :invalid_seed} = Gemini.seed_nonce(0)
      assert {:error, :above_counter_range} = Gemini.seed_nonce(0xFFFF_FFFF_FFFF_FFFF)
    end
  end

  describe "streaming calls at their shortest arity, with no feed running" do
    test "the writes answer, and do not exit the caller" do
      assert {:error, :feed_not_started} = Gemini.subscribe(["BTC-USD"])
      assert :ok = Gemini.unsubscribe(["BTC-USD"])
      assert {:error, :feed_not_started} = Gemini.update_symbols(["BTC-USD"])
      assert {:error, :feed_not_started} = Gemini.subscribe_notices()
    end

    test "the coverage reads answer \"not observed\"" do
      assert Gemini.coverage() == %{}
      assert Gemini.coverage_by_kind() == %{}
    end
  end

  describe "a feed that exits during the call" do
    test "an exit with :timeout is the feed timing out, not the caller exiting" do
      # A real feed reaches this by taking longer than its call budget (tens of seconds); a
      # feed process exiting `:timeout` produces the same `{:timeout, _}` exit in the caller.
      feed = feed_exiting_with(:timeout)

      assert {:error, :feed_timeout} = Gemini.subscribe(["BTC-USD"], feed: feed)
    end

    test "coverage/1 and coverage_by_kind/1 answer empty when the feed dies mid-read" do
      assert Gemini.coverage(feed: feed_exiting_with(:boom)) == %{}
      assert Gemini.coverage_by_kind(feed: feed_exiting_with(:boom)) == %{}
    end
  end
end
