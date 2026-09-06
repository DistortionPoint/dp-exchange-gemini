defmodule DpExchange.GeminiTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Config, Venue}
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Gemini
  alias DpExchange.Gemini.Feed

  @moduletag :capture_log

  # A stand-in socket for the coverage_by_kind facade tests below — see
  # `DpExchange.Gemini.FeedTest` for the same pattern and why it is a real process rather
  # than a mock.
  defp fake_socket do
    spawn_link(fn -> accept_frames() end)
  end

  defp accept_frames do
    receive do
      {:"$websockex_send", from, {:text, _frame}} ->
        :gen.reply(from, :ok)
        accept_frames()
    end
  end

  defp start_feed do
    name = :"gemini_test_feed_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Feed.start_link(name: name, socket: fake_socket())
    name
  end

  describe "the declaration" do
    test "names every callback exactly once" do
      declared = Gemini.capabilities().endpoints |> Map.keys() |> Enum.sort()
      callbacks = Venue.behaviour_info(:callbacks) |> Enum.sort()

      assert declared == callbacks
    end

    test "an endpoint declared :unsupported actually returns the atom" do
      # Both directions, because a declaration that disagrees with the behaviour is worse
      # than no declaration — a caller branches on it.
      for {{name, arity}, :unsupported} <- Gemini.capabilities().endpoints do
        args = unsupported_args(name, arity)

        assert apply(Gemini, name, args) == {:error, :not_supported},
               "#{name}/#{arity} is declared :unsupported but did not say so"
      end
    end

    test "ceilings carry the venue's published burst depth" do
      # Gemini is the only venue in the family that publishes one, and `:burst` exists in
      # Core.Capabilities because this declaration needed it.
      caps = Gemini.capabilities()

      assert caps.public_ceiling == %{limit: 120, per_ms: 60_000, burst: 5}
      assert caps.authenticated_ceiling == %{limit: 600, per_ms: 60_000, burst: 5}
    end

    test "the private ceiling is five times the public one, as the venue states" do
      caps = Gemini.capabilities()

      assert caps.authenticated_ceiling.limit == caps.public_ceiling.limit * 5
    end

    test "provenance says what was measured AND what was not" do
      caps = Gemini.capabilities()

      assert caps.measured_at == ~D[2026-08-28]
      assert caps.measured_against =~ "measured live against api.gemini.com"
      # The ceilings were read, not probed. An unlabelled number is worse than a missing
      # one, and probing a limit means deliberately exceeding a third party's.
      assert caps.measured_against =~ "NOT probed"
    end

    test "declares no timeframe the venue rejects" do
      for absent <- ~w(2h 4h 12h) do
        refute absent in Gemini.capabilities().historical_timeframes
      end
    end

    test "max_candles_per_request is nil, and that is a statement not an omission" do
      # The endpoint accepts no bounds and no limit, so there is no page to size. A number
      # here would imply pagination that does not exist.
      assert Gemini.capabilities().max_candles_per_request == nil
    end

    test "the declaration survives Capabilities' own validation" do
      assert %Capabilities{} = Gemini.capabilities()
    end
  end

  describe "identity" do
    test "provider is the atom, everywhere" do
      assert Gemini.runtime_id() == :gemini
      assert Gemini.provider_name() == "Gemini"
      assert Gemini.asset_classes() == [:crypto]
    end
  end

  describe "market_status/1" do
    test "crypto is always open" do
      assert Gemini.market_status([]) == {:ok, :open}
    end
  end

  describe "live?/1" do
    test "production, the default, moves real money" do
      assert Gemini.live?([]) == true
      assert Gemini.live?(environment: :production) == true
    end

    test "sandbox does not" do
      assert Gemini.live?(environment: :sandbox) == false
    end

    test "an explicit option beats the process-scoped Core.Config setting" do
      Config.put_override(:environment, :sandbox)

      assert Gemini.live?(environment: :production) == true
    end

    test "with no explicit option, the process-scoped setting is what resolves" do
      Config.put_override(:environment, :sandbox)

      assert Gemini.live?([]) == false
    end
  end

  describe "coverage/1" do
    test "an unstarted feed reports an empty map, not a crash" do
      # `coverage/1` returns a map and so has no way to say `{:error, :not_supported}`.
      # Empty is the honest answer for a venue delivering nothing.
      assert Gemini.coverage(feed: :no_such_feed_process) == %{}
    end
  end

  describe "coverage_by_kind/1" do
    test "an unstarted feed reports an empty map, not a crash" do
      assert Gemini.coverage_by_kind(feed: :no_such_feed_process) == %{}
    end

    test "every kind key it reports is one capabilities().streamable declares" do
      feed = start_feed()
      :ok = Gemini.subscribe(["BTC-USD"], to: self(), feed: feed)

      send(
        feed,
        {:dp_exchange, :gemini,
         %TopOfBook{
           symbol: "BTC-USD",
           bid: Decimal.new("1"),
           ask: Decimal.new("2"),
           bid_size: nil,
           ask_size: nil,
           venue_time: ~U[2026-08-28 12:00:00Z],
           observed_at: ~U[2026-08-28 12:00:00Z],
           provider: :gemini
         }}
      )

      _settled = Gemini.coverage(feed: feed)

      declared = MapSet.new(Gemini.capabilities().streamable)
      reported = [feed: feed] |> Gemini.coverage_by_kind() |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(reported, declared)
    end

    test "the union of its symbols across kinds matches coverage/1's keys exactly" do
      # The same invariant Core's conformance suite (assertion 15) checks, exercised
      # through the facade rather than through `Feed` directly.
      feed = start_feed()
      :ok = Gemini.subscribe(["BTC-USD", "ETH-USD"], to: self(), feed: feed)

      send(
        feed,
        {:dp_exchange, :gemini,
         %TopOfBook{
           symbol: "BTC-USD",
           bid: Decimal.new("1"),
           ask: Decimal.new("2"),
           bid_size: nil,
           ask_size: nil,
           venue_time: ~U[2026-08-28 12:00:00Z],
           observed_at: ~U[2026-08-28 12:00:00Z],
           provider: :gemini
         }}
      )

      send(
        feed,
        {:dp_exchange, :gemini,
         %Quote{
           symbol: "ETH-USD",
           price: Decimal.new("1"),
           timestamp: ~U[2026-08-28 12:00:00Z],
           provider: :gemini
         }}
      )

      _settled = Gemini.coverage(feed: feed)

      union =
        [feed: feed]
        |> Gemini.coverage_by_kind()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert union == [feed: feed] |> Gemini.coverage() |> Map.keys() |> Enum.sort()
    end
  end

  # Argument shapes for the declared-unsupported sweep. A lookup rather than a case, so
  # adding a callback to the facade adds a row here instead of a branch.
  @unsupported_args %{
    {:list_instruments, 1} => [[]],
    {:place_order, 3} => [:credentials, %{}, []],
    {:replace_order, 4} => [:credentials, "id", %{}, []],
    {:withdraw, 5} => ["BTC", "bitcoin", :one, "addr", []],
    {:estimate_withdrawal_fee, 4} => ["BTC", "bitcoin", :one, []],
    {:quote_conversion, 4} => ["BTC", "USD", :one, []],
    {:get_deposit_address, 3} => ["BTC", "bitcoin", []],
    {:create_watchlist, 3} => ["name", [], []],
    {:get_financials, 3} => ["BTC-USD", :balance_sheet, []],
    {:rename_account, 3} => ["id", "name", []],
    {:stake, 3} => ["BTC", :one, []],
    {:unstake, 3} => ["BTC", :one, []],
    {:get_funding, 2} => ["BTC-USD", []],
    {:get_contract_stats, 2} => ["BTC-USD", []],
    {:get_option_chain, 2} => ["BTC-USD", []],
    {:get_option_expirations, 2} => ["BTC-USD", []],
    {:get_option_greeks, 2} => ["id", []],
    {:get_watchlist, 2} => ["id", []],
    {:update_watchlist, 2} => ["id", []],
    {:delete_watchlist, 2} => ["id", []],
    {:get_filings, 2} => ["id", []],
    {:get_screener, 2} => ["id", []],
    {:commit_conversion, 2} => ["id", []],
    {:get_conversion, 2} => ["id", []]
  }

  defp unsupported_args(name, arity) do
    case Map.fetch(@unsupported_args, {name, arity}) do
      {:ok, args} -> Enum.map(args, &resolve_arg/1)
      :error -> generic_args(arity)
    end
  end

  defp resolve_arg(:credentials), do: %{api_key: "k", api_secret: "s"}
  defp resolve_arg(:one), do: Decimal.new("1")
  defp resolve_arg(other), do: other

  defp generic_args(4), do: [resolve_arg(:credentials), "id", %{}, []]
  defp generic_args(3), do: [resolve_arg(:credentials), "id", []]
  defp generic_args(2), do: [resolve_arg(:credentials), []]
  defp generic_args(1), do: [[]]
end
