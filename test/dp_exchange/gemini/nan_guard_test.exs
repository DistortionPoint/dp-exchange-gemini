defmodule DpExchange.Gemini.NaNGuardTest do
  use ExUnit.Case, async: true

  alias DpExchange.Gemini.WsDecode

  # `Decimal.parse/1` requiring the whole string be consumed is not a sufficient guard on its
  # own: "NaN", "Inf" and "-Inf" all parse fully and case-insensitively, so each arrived as a
  # well-formed `Decimal` and flowed onward as a real bid or ask.
  #
  # That is worse than a raise, and it fails a long way from the cause. `Decimal.add(nan, 1)`
  # is NaN, so it poisons a consumer's arithmetic silently; `Decimal.compare(nan, _)` RAISES
  # `invalid_operation: operation on NaN`, in the consumer's own process, naming Decimal
  # rather than the venue that sent it. An Infinity is quieter still — it compares greater
  # than everything and never raises.
  #
  # `dp_exchange_webull` found this and guarded both of its copies. This package guarded none
  # of its four.
  @observed_at ~U[2026-09-11 00:00:00Z]

  # Lowercase and mixed forms included deliberately: `Decimal.parse/1` is case-insensitive
  # here, so a guard that only matched the canonical spelling would let `"inf"` straight
  # through.
  @poison ["NaN", "nan", "-NaN", "Inf", "inf", "-Inf", "Infinity", "-Infinity"]

  describe "a NaN or Infinity from the venue is dropped, never admitted as a number" do
    for value <- @poison do
      test "#{value} in a bookTicker bid refuses the book, never a Decimal and never nil" do
        # It used to become `bid: nil` beside a real ask. `TopOfBook` reads a `nil` level
        # as "no resting order", a claim the venue never made, so a stated but unreadable
        # level now refuses the book (2026-10-10). `Socket` reports that as `:data_quality`.
        frame = %{"E" => 1_757_548_800_000_000_000, "b" => unquote(value), "a" => "100.5"}

        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(frame, "BTC-USD", @observed_at)
      end
    end

    test "a real number still decodes, so the guard has not eaten the happy path" do
      frame = %{"E" => 1_757_548_800_000_000_000, "b" => "99.5", "a" => "100.5"}

      assert {:ok, top} = WsDecode.to_top_of_book(frame, "BTC-USD", @observed_at)
      assert Decimal.equal?(top.bid, Decimal.new("99.5"))
      assert Decimal.equal?(top.ask, Decimal.new("100.5"))
    end

    test "an ask that is poison refuses the book too, whichever side carries it" do
      for value <- @poison do
        frame = %{"E" => 1_757_548_800_000_000_000, "b" => "99.5", "a" => value}

        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(frame, "BTC-USD", @observed_at),
               "#{value} in the ask was admitted"
      end
    end
  end
end
