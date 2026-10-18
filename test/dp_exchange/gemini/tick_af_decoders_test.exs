defmodule DpExchange.Gemini.TickAfDecodersTest do
  @moduledoc """
  Decoder edge cases (tick AF): duplicate entries, huge values, empty strings and out-of-order
  arrays through the snapshot and trade decoders. In-process only; nothing reaches the venue.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Rest, WsDecode}

  @observed ~U[2026-10-14 12:00:00Z]
  @date "Fri, 28 Aug 2026 17:00:01 GMT"
  @ns 1_787_936_147_000_000_000

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

  defp public_opts(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end

    [plug: plug, retry_attempts: 0]
  end

  defp prices(levels), do: Enum.map(levels, fn {price, _size} -> Decimal.to_integer(price) end)

  describe "WS snapshot: a price listed twice on one side" do
    @duplicates [
      [["100", "1"], ["100", "2"]],
      [["100", "1"], ["100.0", "2"]],
      [["100.00", "1"], ["99", "1"], ["1E+2", "3"]]
    ]

    test "to_order_book/3 refuses it, on either side" do
      for rows <- @duplicates do
        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(%{"bids" => rows, "asks" => []}, "BTC-USD", @observed)

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book(%{"bids" => [], "asks" => rows}, "BTC-USD", @observed)
      end
    end

    test "the depth anchor refuses it too" do
      for rows <- @duplicates do
        frame = %{"b" => rows, "a" => [], "u" => 5, "E" => @ns}

        assert {:error, :unexpected_response_shape} =
                 WsDecode.to_order_book_from_depth_update(frame, "BTC-USD", @observed)
      end
    end

    test "the same price on opposite sides is not a duplicate, and an unsorted side is sorted" do
      frame = %{"bids" => [["99", "1"], ["101", "1"], ["100", "1"]], "asks" => [["101", "2"]]}

      assert {:ok, book} = WsDecode.to_order_book(frame, "BTC-USD", @observed)
      assert prices(book.bids) == [101, 100, 99]
    end

    test "a diff may repeat a price: its rows are applied in order" do
      frame = %{
        "E" => @ns,
        "u" => 9,
        "b" => [["100", "1"], ["100", "0"]],
        "a" => []
      }

      assert {:ok, delta} = WsDecode.to_order_book_delta(frame, "BTC-USD")
      assert length(delta.levels) == 2
    end
  end

  describe "WS trade and ticker: values that are not a price or a size" do
    @trade %{"E" => @ns, "t" => 1, "p" => "100", "q" => "1", "m" => false}

    test "an empty string, a huge exponent and a word refuse the print" do
      for bad <- ["", "1e999999999", "-1e999999999", "NaN", "Infinity", "ten"],
          {field, name} <- [{"p", :price}, {"q", :quantity}] do
        assert {:error, {:invalid_decimal, ^name, ^bad}} =
                 WsDecode.to_trade(%{@trade | field => bad}, "BTC-USD")
      end
    end

    test "a missing price or size refuses the print as a missing field" do
      for field <- ["p", "q"] do
        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_trade(Map.delete(@trade, field), "BTC-USD")
      end
    end

    test "a huge exponent or an empty-and-garbage size refuses the book ticker" do
      for bad <- ["1e999999999", "ten", [], %{}] do
        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(%{"b" => bad, "a" => "1"}, "BTC-USD", @observed)

        assert {:error, :unexpected_frame_shape} =
                 WsDecode.to_top_of_book(%{"B" => bad}, "BTC-USD", @observed)
      end
    end

    test "a huge quantity in a diff refuses the frame" do
      frame = %{"E" => @ns, "u" => 9, "b" => [["100", "1e999999999"]], "a" => []}

      assert {:error, :unexpected_response_shape} = WsDecode.to_order_book_delta(frame, "BTC-USD")
    end
  end

  describe "REST order book: a price listed twice on one side" do
    test "is refused, however it is spelled" do
      for rows <- [
            [%{"price" => "100", "amount" => "1"}, %{"price" => "100", "amount" => "2"}],
            [%{"price" => "100", "amount" => "1"}, %{"price" => "100.00", "amount" => "2"}]
          ] do
        assert {:error, :unexpected_response_shape} =
                 Rest.get_order_book("BTC-USD", public_opts(%{"bids" => rows, "asks" => []}))

        assert {:error, :unexpected_response_shape} =
                 Rest.get_order_book("BTC-USD", public_opts(%{"bids" => [], "asks" => rows}))
      end
    end

    test "distinct prices out of order are returned best first" do
      rows = [
        %{"price" => "99", "amount" => "1"},
        %{"price" => "101", "amount" => "1"},
        %{"price" => "100", "amount" => "1"}
      ]

      assert {:ok, book} =
               Rest.get_order_book("BTC-USD", public_opts(%{"bids" => rows, "asks" => rows}))

      assert prices(book.bids) == [101, 100, 99]
      assert prices(book.asks) == [99, 100, 101]
    end
  end
end
