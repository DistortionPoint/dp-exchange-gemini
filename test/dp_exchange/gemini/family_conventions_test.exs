defmodule DpExchange.Gemini.FamilyConventionsTest do
  @moduledoc """
  Tick O family conventions: bad symbols and ranges are refused locally, `subscribe([])`
  opens nothing, a remote feed pid does not raise, the Fake skips an unregistered `to:`
  name, and the supervisor does not print raw credentials.

  Every refusal is asserted against a plug that raises: if the call reached the venue the
  answer would not be the refusal.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini
  alias DpExchange.Gemini.{Fake, Feed, Rest}

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

  @bad_symbols [nil, :btcusd, 5, "", "   ", %{}, ["BTC-USD"]]

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp real_opts, do: [plug: exploding(), retry_attempts: 0]

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp remote_pid do
    node = "tick_o_gemini@nowhere.invalid"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end

  describe "a single-symbol read refuses a symbol that is not a non-blank string" do
    test "every public read answers invalid_symbol, before any request" do
      for bad <- @bad_symbols do
        expected = {:error, {:invalid_symbol, bad}}

        assert Rest.get_price(bad, real_opts()) == expected
        assert Rest.get_top_of_book(bad, real_opts()) == expected
        assert Rest.get_order_book(bad, real_opts()) == expected
        assert Rest.get_historical_prices(bad, "1d", [], real_opts()) == expected
        assert Rest.get_trades(bad, real_opts()) == expected
        assert Rest.quantization(bad, real_opts()) == expected
        assert Rest.get_funding(bad, real_opts()) == expected
        assert Rest.get_contract_stats(bad, real_opts()) == expected
        assert Rest.next_funding_timestamp(bad, real_opts()) == expected
      end
    end

    test "the Fake answers exactly as the real calls do" do
      for bad <- @bad_symbols do
        expected = {:error, {:invalid_symbol, bad}}

        assert Fake.get_price(bad) == expected
        assert Fake.get_top_of_book(bad) == expected
        assert Fake.get_order_book(bad) == expected
        assert Fake.get_historical_prices(bad, "1d", []) == expected
        assert Fake.get_trades(bad) == expected
        assert Fake.quantization(bad) == expected
        assert Fake.get_funding(bad) == expected
        assert Fake.get_contract_stats(bad) == expected
      end
    end

    test "the facade does not raise for a nil symbol" do
      assert Gemini.get_price(nil, real_opts()) == {:error, {:invalid_symbol, nil}}
      assert Gemini.quantization(:btcusd) == {:error, {:invalid_symbol, :btcusd}}
    end

    test "a well-formed symbol is still sent" do
      body = %{"bid" => "1", "ask" => "2", "last" => "1.5", "volume" => %{}}
      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:ok, %{symbol: "BTC-USD"}} =
               Rest.get_price("btcusd", plug: plug, retry_attempts: 0)
    end
  end

  describe "a historical range is validated before any request" do
    test "a range that is not a keyword list is invalid_range, never a raise" do
      for bad <- [5, :now, "2026-01-01", [1, 2], %{start: 1}, {:start, 1}] do
        assert Rest.get_historical_prices("BTC-USD", "1d", bad, real_opts()) ==
                 {:error, {:invalid_range, bad}}

        assert Fake.get_historical_prices("BTC-USD", "1d", bad) ==
                 {:error, {:invalid_range, bad}}
      end
    end

    test "a bound that is not a DateTime is invalid_range with the whole range (D9)" do
      assert Rest.get_historical_prices("BTC-USD", "1d", [start: "x"], real_opts()) ==
               {:error, {:invalid_range, [start: "x"]}}

      assert Fake.get_historical_prices("BTC-USD", "1d", end: 5) ==
               {:error, {:invalid_range, [end: 5]}}

      assert Rest.validate_range(start: ~U[2026-01-01 00:00:00Z], end: :later) ==
               {:error, {:invalid_range, [start: ~U[2026-01-01 00:00:00Z], end: :later]}}

      assert Rest.validate_range(start: ~U[2026-01-01 00:00:00Z]) == :ok
    end
  end

  describe "subscribe([]) opens nothing" do
    test "the subscriber is registered and no socket is dialled" do
      name = unique(:feed)
      {:ok, feed} = Feed.start_link(name: name)

      assert Gemini.subscribe([], feed: name) == :ok

      state = :sys.get_state(feed)
      assert state.socket == nil
      assert MapSet.member?(state.subscribers, self())
      assert MapSet.size(state.wanted) == 0
    end

    test "bad input is still refused first" do
      name = unique(:feed)
      {:ok, _feed} = Feed.start_link(name: name)

      assert Gemini.subscribe(nil, feed: name) == {:error, {:invalid_symbols, nil}}
    end
  end

  describe "a feed addressed by a remote pid does not raise" do
    test "coverage and coverage_by_kind answer the empty map" do
      remote = remote_pid()

      assert Gemini.coverage(feed: remote) == %{}
      assert Gemini.coverage_by_kind(feed: remote) == %{}
    end
  end

  describe "the Fake skips a to: name that no process holds" do
    test "subscribe answers :ok instead of raising ArgumentError" do
      nobody = unique(:nobody_registered)

      assert Fake.subscribe(["BTC-USD"], to: nobody) == :ok
      assert Fake.update_symbols(["BTC-USD", "ETH-USD"]) == :ok
    end

    test "a registered name still receives" do
      name = unique(:receiver)
      Process.register(self(), name)

      assert Fake.subscribe(["BTC-USD"], to: name) == :ok
      assert_receive {:dp_exchange, :gemini, %{symbol: "BTC-USD"}}, 5_000
    end
  end

  describe "the supervisor does not print raw credentials" do
    test "start_link wraps them, so the supervisor's status holds only the redacted struct" do
      canary = "tick-o-gemini-secret-canary"

      {:ok, sup} =
        Gemini.Supervisor.start_link(
          name: unique(:sup),
          feed: unique(:feed),
          limiter: unique(:limiter),
          credentials: %{api_key: "account-k", api_secret: canary}
        )

      status = sup |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)

      # A status that printed nothing of the tree would pass the refutation below for the wrong
      # reason, so the dump is first shown to be the supervisor's own.
      assert status =~ "Gemini"
      refute status =~ canary
    end
  end
end
