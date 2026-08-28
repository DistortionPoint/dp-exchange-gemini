defmodule DpExchange.Gemini.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Quote
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
    test "become a Quote with the canonical symbol and Decimal numerics" do
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{} = quote_struct}
      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.bid, Decimal.new("77845.79000"))
      assert Decimal.equal?(quote_struct.ask, Decimal.new("77846.48000"))
      assert quote_struct.provider == :gemini
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

    test "price falls back to the bid when the book has never traded" do
      # `c` is documented as present only once the book has traded. Inventing a last
      # price for an untraded book would be a substitution; the bid is a real quoted
      # number and is labelled as the bid too.
      assert {:ok, _state} = deliver(Map.drop(@book_ticker, ["c", "C"]))

      assert_receive {:dp_exchange, :gemini, %Quote{price: price, bid: bid}}
      assert Decimal.equal?(price, bid)
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
