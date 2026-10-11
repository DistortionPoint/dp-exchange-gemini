defmodule DpExchange.Gemini.WsDecodeSinglePassTest do
  @moduledoc """
  Book sides are decoded once per frame, and the refusals that used to come from a second
  pass over the same rows (`readable_side/1`) still come from the one.

  Pins the equivalence the performance change relies on: a side is refused exactly when a
  row is not a pair of two readable decimals, whichever of the snapshot, anchor or delta
  paths it arrives on.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.WsDecode

  @observed ~U[2026-08-28 12:00:00Z]
  @ns 1_787_936_147_000_000_000

  @bad_sides [
    {"unreadable price", [["100.00", "1"], ["not-a-price", "3"]]},
    {"unreadable quantity", [["100.00", "garbage"]]},
    {"a null quantity", [["100.00", nil]]},
    {"NaN", [["NaN", "1"]]},
    {"a row that is not a pair", [["100.00", "1"], ["100.50"]]},
    {"a three element row", [["100.00", "1", "2"]]},
    {"a row that is not a list", ["100.00"]},
    {"an unbounded exponent", [["1e999999999", "1"]]}
  ]

  defp prices(levels), do: Enum.map(levels, fn {price, _quantity} -> Decimal.to_string(price) end)

  describe "a damaged side is refused on every path" do
    for {name, side} <- @bad_sides do
      test "#{name}: snapshot, anchor and delta" do
        side = unquote(Macro.escape(side))

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(%{"bids" => side, "asks" => []}, "BTC-USD", @observed)

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(%{"bids" => [], "asks" => side}, "BTC-USD", @observed)

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_from_depth_update(
                   %{"E" => @ns, "u" => 1, "b" => side, "a" => []},
                   "BTC-USD",
                   @observed
                 )

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_delta(
                   %{"E" => @ns, "U" => 1, "u" => 2, "b" => [], "a" => side},
                   "BTC-USD"
                 )
      end
    end
  end

  describe "a readable side is delivered whole" do
    test "a delta carries every row in the venue's order, a zero quantity included" do
      frame = %{
        "E" => @ns,
        "U" => 1,
        "u" => 2,
        "b" => [["100.00", "1"], ["99.00", "0"]],
        "a" => [["101.00", "2"]]
      }

      assert {:ok, delta} = WsDecode.to_order_book_delta(frame, "BTC-USD")

      assert [{:bid, p1, q1}, {:bid, p2, q2}, {:ask, p3, q3}] = delta.levels

      assert Enum.map([p1, q1, p2, q2, p3, q3], &Decimal.to_string/1) ==
               ["100.00", "1", "99.00", "0", "101.00", "2"]
    end

    test "an absent side on a delta is an unchanged side" do
      assert {:ok, delta} =
               WsDecode.to_order_book_delta(
                 %{"E" => @ns, "U" => 1, "u" => 2, "b" => [["100.00", "1"]]},
                 "BTC-USD"
               )

      assert [{:bid, _price, _quantity}] = delta.levels
    end

    test "snapshot and anchor sides are sorted best-first from the single parse" do
      side = [["100.00", "1"], ["102.00", "2"], ["101.00", "3"]]

      assert {:ok, book} =
               WsDecode.to_order_book(%{"bids" => side, "asks" => side}, "BTC-USD", @observed)

      assert prices(book.bids) == ["102.00", "101.00", "100.00"]
      assert prices(book.asks) == ["100.00", "101.00", "102.00"]

      assert {:ok, anchor} =
               WsDecode.to_order_book_from_depth_update(
                 %{"E" => @ns, "u" => 7, "b" => side, "a" => side},
                 "BTC-USD",
                 @observed
               )

      assert anchor.sequence == 7
      assert prices(anchor.bids) == ["102.00", "101.00", "100.00"]
      assert prices(anchor.asks) == ["100.00", "101.00", "102.00"]
    end
  end

  describe "a JSON float is bounded like every other number" do
    test "1.0e300 as a price refuses the book side instead of carrying a 1E+300 exponent" do
      assert {:error, :unexpected_frame_shape} =
               WsDecode.to_top_of_book(%{"b" => 1.0e300, "a" => "1"}, "BTC-USD", @observed)

      assert {:error, {:invalid_decimal, :price, 1.0e300}} =
               WsDecode.to_trade(%{"p" => 1.0e300, "q" => "1", "E" => @ns}, "BTC-USD")
    end

    test "an ordinary float still reads" do
      assert {:ok, book} =
               WsDecode.to_top_of_book(%{"b" => 100.5, "a" => "101"}, "BTC-USD", @observed)

      assert Decimal.equal?(book.bid, Decimal.new("100.5"))
    end
  end
end
