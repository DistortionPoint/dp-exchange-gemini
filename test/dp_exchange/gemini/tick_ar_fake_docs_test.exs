defmodule DpExchange.Gemini.TickArFakeDocsTest do
  @moduledoc """
  Tick AR, lens V and X over `DpExchange.Gemini.Fake` and `DpExchange.Gemini.Feed`: the Fake
  states an order the way `Private.to_order/1` does, refuses a history read that fills the page
  as the real call does, and refuses the start options the real feed raises on.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.Fake

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}

  @closed_id "9000000000000000001"

  @request %{
    symbol: "BTC-USD",
    side: :buy,
    quantity: "1",
    price: "100.00",
    order_type: :limit,
    time_in_force: :gtc
  }

  defp place_and_cancel_all(count) do
    for _n <- 1..count do
      assert {:ok, _order} = Fake.place_order(@credentials, @request)
    end

    assert {:ok, %{cancelled: cancelled}} =
             Fake.cancel_all_orders(@credentials, scope: :account)

    assert length(cancelled) == count
  end

  describe "an order the Fake states" do
    test "carries no update time, as the real order body states none" do
      assert {:ok, placed} = Fake.place_order(@credentials, @request)
      assert placed.updated_at == nil
      assert %DateTime{} = placed.created_at

      assert {:ok, read} = Fake.get_order(@credentials, placed.id)
      assert read.updated_at == nil

      assert {:ok, closed} = Fake.get_order(@credentials, @closed_id)
      assert closed.updated_at == nil
      assert closed.status == :filled
    end

    test "a cancelled order keeps its fill and its id; a filled one stays filled" do
      assert {:ok, placed} = Fake.place_order(@credentials, @request)
      assert {:ok, cancelled} = Fake.cancel_order(@credentials, placed.id)
      assert cancelled.status == :cancelled
      assert cancelled.id == placed.id
      assert Decimal.equal?(cancelled.filled_quantity, placed.filled_quantity)
      assert cancelled.updated_at == nil

      assert {:ok, again} = Fake.cancel_order(@credentials, placed.id)
      assert again.status == :cancelled

      assert {:ok, read} = Fake.get_order(@credentials, placed.id)
      assert read.status == :cancelled

      assert {:ok, closed} = Fake.cancel_order(@credentials, @closed_id)
      assert closed.status == :filled
      assert Decimal.equal?(closed.filled_quantity, Decimal.new(1))
    end
  end

  describe "get_orders/2 history on the Fake" do
    test "a read that fills the 500-row page with no :limit is history_truncated" do
      # The fixed closed order plus 498 placed and cancelled is 499 rows: not a full page.
      place_and_cancel_all(498)

      assert {:ok, rows} = Fake.get_orders(@credentials, history: true)
      assert length(rows) == 499

      place_and_cancel_all(1)

      assert {:error, :history_truncated} = Fake.get_orders(@credentials, history: true)

      assert {:ok, one_page} = Fake.get_orders(@credentials, history: true, limit: 500)
      assert length(one_page) == 500

      assert {:ok, small} = Fake.get_orders(@credentials, history: true, limit: 2)
      assert length(small) == 2

      assert {:ok, []} = Fake.get_orders(@credentials, history: true, symbol: "ETH-USD")
    end
  end

  describe "Fake.start_link/1 refuses what the real feed raises on in init/1" do
    test "a :channels that is empty, not a list, or names a kind the venue does not stream" do
      assert Fake.start_link(channels: [:quotes, :top_of_book, :trades]) == :ignore
      assert Fake.start_link(channels: [:trades]) == :ignore

      assert Fake.start_link(channels: [:quotes, :depth]) ==
               {:error, {:invalid_option, :channels, [:quotes, :depth]}}

      assert Fake.start_link(channels: []) == {:error, {:invalid_option, :channels, []}}

      assert Fake.start_link(channels: :trades) == {:error, {:invalid_option, :channels, :trades}}
    end

    test "a :max_queue_len that is not a positive integer" do
      assert Fake.start_link(max_queue_len: 10) == :ignore

      assert Fake.start_link(max_queue_len: "3") ==
               {:error, {:invalid_option, :max_queue_len, "3"}}

      assert Fake.start_link(max_queue_len: 0) == {:error, {:invalid_option, :max_queue_len, 0}}
    end
  end
end
