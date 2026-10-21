defmodule DpExchange.Gemini.TickARRestDocsTest do
  @moduledoc """
  Tick AR, lens V: a documented promise that the code did not keep, and a declaration that
  contradicted the code beside it.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini

  describe "child_spec/1 and an environment start_link/1 refuses" do
    test "a mistyped environment is not raised in the consumer's supervisor" do
      assert %{id: DpExchange.Gemini, type: :supervisor} =
               Gemini.child_spec(environment: :sandox)

      assert %{id: DpExchange.Gemini} = Gemini.child_spec(environment: nil)
    end

    test "an explicit name still names the child when the environment is bad" do
      assert %{id: :tick_ar_named} = Gemini.child_spec(environment: :sandox, name: :tick_ar_named)
    end

    test "start_link/1 is the one that refuses it, with nothing started" do
      assert {:error, {:invalid_option, :environment, :sandox}} =
               Gemini.start_link(environment: :sandox)

      assert {:error, {:invalid_option, :environment, nil}} =
               Gemini.start_link(environment: nil)
    end

    test "a valid environment keeps its distinct default ids" do
      assert %{id: DpExchange.Gemini} = Gemini.child_spec(environment: :production)
      assert %{id: DpExchange.Gemini.Sandbox} = Gemini.child_spec(environment: :sandbox)
    end
  end

  describe "get_conversion/2 is the venue's absence, not the package's backlog" do
    test "it is named by venue_does_not_serve/0 and declared :unsupported" do
      assert {:get_conversion, 2} in Gemini.venue_does_not_serve()
      assert Gemini.capabilities().endpoints[{:get_conversion, 2}] == :unsupported
    end

    test "list_portfolios/1 stays declared :unsupported and is not claimed as the venue's" do
      refute {:list_portfolios, 1} in Gemini.venue_does_not_serve()
      assert Gemini.capabilities().endpoints[{:list_portfolios, 1}] == :unsupported
    end

    test "it still answers :not_supported" do
      assert Gemini.get_conversion("1", []) == {:error, :not_supported}
    end
  end

  describe "capabilities/0 provenance" do
    test "the leverage ceiling and the order vocabulary say they were not probed" do
      against = Gemini.capabilities().measured_against

      assert against =~ "max_leverage 5"
      assert against =~ "NOT in the committed OpenAPI"
      assert against =~ "supported_order_types and supported_time_in_force are read from"
    end
  end
end
