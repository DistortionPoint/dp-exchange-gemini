defmodule DpExchange.GeminiTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Gemini

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

  describe "coverage/1" do
    test "an unstarted feed reports an empty map, not a crash" do
      # `coverage/1` returns a map and so has no way to say `{:error, :not_supported}`.
      # Empty is the honest answer for a venue delivering nothing.
      assert Gemini.coverage(feed: :no_such_feed_process) == %{}
    end
  end

  defp unsupported_args(name, arity) do
    credentials = %{api_key: "k", api_secret: "s"}

    case {name, arity} do
      {:list_instruments, 1} -> [[]]
      {:place_order, 3} -> [credentials, %{}, []]
      {:replace_order, 4} -> [credentials, "id", %{}, []]
      {_name, 3} -> [credentials, "id", []]
      {_name, 2} -> [credentials, []]
      {_name, 1} -> [[]]
    end
  end
end
