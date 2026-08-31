defmodule DpExchange.Gemini.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Gemini.Socket

  @moduletag :capture_log

  # The frame handlers are pure given a state, so they are driven directly. No socket is
  # opened and no venue is reached — a tier-1 test that dials a venue is a tier-2 test
  # wearing the wrong tag, and it will fail in CI on a bad day rather than a bad commit.
  defp state, do: %{subscriber: self(), request_id: 0}

  defp deliver(payload) do
    Socket.handle_frame({:text, Jason.encode!(payload)}, state())
  end

  # A real frame, captured from ws.gemini.com on 2026-08-28.
  @book_ticker %{
    "u" => 1_764_553_979_097_789,
    "E" => 1_787_936_147_810_330_084,
    "s" => "btcusd",
    "b" => "77845.79000",
    "B" => "0.0457361300",
    "a" => "77846.48000",
    "A" => "0.0143148700",
    "c" => "77834.11000",
    "C" => "0.0012854500"
  }

  describe "bookTicker frames" do
    test "deliver top-of-book with the canonical symbol and Decimal numerics" do
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{} = top}
      assert top.symbol == "BTC-USD"
      assert Decimal.equal?(top.bid, Decimal.new("77845.79000"))
      assert Decimal.equal?(top.ask, Decimal.new("77846.48000"))
      # The frame carries sizes, so they are carried too rather than dropped.
      assert Decimal.equal?(top.bid_size, Decimal.new("0.0457361300"))
      assert Decimal.equal?(top.ask_size, Decimal.new("0.0143148700"))
      assert top.provider == :gemini
    end

    test "a frame carrying a last trade also delivers it, as a separate Quote" do
      # Two facts on one frame, and each arrives in the type that says which it is: the
      # book in a TopOfBook, the execution in a Quote. Neither stands in for the other.
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{} = quote_struct}
      assert Decimal.equal?(quote_struct.price, Decimal.new("77834.11000"))
      refute Map.has_key?(quote_struct, :bid)
    end

    test "event time is read as NANOseconds" do
      # A factor of a million. Read as milliseconds this timestamp lands in the year
      # 58,000 and every staleness check passes forever.
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{timestamp: timestamp}}
      assert timestamp.year == 2026
    end

    test "price is the last trade when the book has traded" do
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{price: price}}
      assert Decimal.equal?(price, Decimal.new("77834.11000"))
    end

    test "a book that has never traded delivers top-of-book and NO quote" do
      # This test used to assert the opposite — that `price` falls back to the bid — and
      # its comment defended the bid as "a real quoted number". It is real, and it is not a
      # price: a bid is a resting order, a price is an execution. The fallback was the same
      # substitution this family shipped once already on another venue.
      #
      # An untraded book has a top and no last trade. That is what is delivered.
      assert {:ok, _state} = deliver(Map.drop(@book_ticker, ["c", "C"]))

      assert_receive {:dp_exchange, :gemini, %TopOfBook{bid: bid, ask: ask}}
      assert Decimal.equal?(bid, Decimal.new("77845.79000"))
      assert ask

      refute_receive {:dp_exchange, :gemini, %Quote{}}, 50
    end

    test "a frame with NO event time delivers nothing at all" do
      # On a stream, refusing to substitute means dropping the frame. A quote whose
      # freshness cannot be stated must not reach a consumer.
      assert {:ok, _state} = deliver(Map.delete(@book_ticker, "E"))

      refute_receive {:dp_exchange, :gemini, %Quote{}}, 50
    end

    test "a symbol with an overlapping quote still splits correctly off the wire" do
      assert {:ok, _state} = deliver(%{@book_ticker | "s" => "aavegusd"})

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "AAVE-GUSD"}}
    end
  end

  describe "control frames" do
    test "a failed subscribe raises a notice rather than passing silently" do
      # Continuing quietly is how a feed reports healthy while delivering nothing.
      assert {:ok, _state} = deliver(%{"id" => 1, "status" => 400})

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change} = notice}
      assert notice.details.subscribe_status == 400
    end

    test "a successful subscribe ack is not noise" do
      assert {:ok, _state} = deliver(%{"id" => 1, "status" => 200})

      refute_receive {:dp_exchange, :gemini, %Notice{}}, 50
    end
  end

  describe "frames this package does not model" do
    test "unrecognised JSON is ignored, not crashed on" do
      assert {:ok, _state} = deliver(%{"e" => "depthUpdate", "s" => "btcusd"})
    end

    test "malformed JSON is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
    end

    test "a binary frame is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:binary, <<1, 2, 3>>}, state())
    end
  end

  describe "connection lifecycle" do
    test "connecting raises link_up" do
      assert {:ok, _state} = Socket.handle_connect(:conn, state())

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_up}}
    end

    test "disconnecting raises link_down and asks to reconnect" do
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}
    end

    test "the disconnect notice carries no credential-shaped keys" do
      # `Notice.new/3` refuses them, and these packages are public — notices get pasted
      # into issues.
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:dp_exchange, :gemini, %Notice{details: details}}
      assert Map.keys(details) == [:reason]
    end
  end
end
