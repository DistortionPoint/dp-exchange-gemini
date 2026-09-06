defmodule DpExchange.Gemini.SocketChannelsTest do
  @moduledoc """
  The socket beyond `bookTicker`.

  It delivered one channel before the AsyncAPI document was read. These assertions are about
  the three that carry the traps: **the trade side is inverted from `m`**, a **depth diff is
  not a book**, and a **sequence gap must be announced** because a consumer that keeps
  applying holds a silently wrong book.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Notice, Types}
  alias DpExchange.Gemini.Socket

  defp state(overrides \\ %{}) do
    Map.merge(%{subscriber: self(), request_id: 0}, overrides)
  end

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  describe "addresses come from the channel registry, not concatenation" do
    test "a per-symbol channel builds one address per symbol" do
      assert Socket.streams(["BTC-USD", "ETH-USD"], :trade) == ["btcusd@trade", "ethusd@trade"]
    end

    test "the interval is part of the address for the Fast channels" do
      # A hand-assembled "{symbol}@depthFast" subscribes to nothing and produces silence
      # rather than an error.
      assert Socket.streams(["BTC-USD"], :depth_fast) == ["btcusd@depth@100ms"]
    end

    test "a per-account channel takes no symbols and yields one address" do
      assert Socket.streams([], :orders_account) == ["orders@account"]
      assert Socket.streams([], :balances_account_snapshot) == ["balances@account@1s"]
    end

    test "the default is still bookTicker, which is what this socket delivered before" do
      assert Socket.streams(["BTC-USD"]) == ["btcusd@bookTicker"]
    end

    test "an unknown channel yields no address rather than a guessed one" do
      assert Socket.streams(["BTC-USD"], :candles) == []
    end
  end

  describe "subscribe/3 and unsubscribe/3 refuse two shapes before building any frame" do
    test "symbols against a channel that takes none is refused, not silently dropped" do
      # `streams/2` itself silently drops an address that fails to build (see above), which
      # used to mean `subscribe(socket, ["BTC-USD"], :contract_status)` built zero frames
      # and `send_rpc/3` answered `:ok` — a subscription for nothing, reported as success.
      # `:contract_status` is public, so this exercises the symbol-shape check on its own,
      # apart from the credential check below.
      assert Socket.subscribe(self(), ["BTC-USD"], :contract_status) ==
               {:error, {:channel_takes_no_symbol, :contract_status}}

      assert Socket.unsubscribe(self(), ["BTC-USD"], :contract_status) ==
               {:error, {:channel_takes_no_symbol, :contract_status}}
    end

    test "a channel requiring a credential is refused — this socket never authenticates" do
      assert Socket.subscribe(self(), [], :orders_account) ==
               {:error, {:credential_required, :orders_account}}

      assert Socket.subscribe(self(), [], :request_for_quote_session) ==
               {:error, {:credential_required, :request_for_quote_session}}
    end

    test "the public requestForQuote channel is not refused for lacking a credential" do
      refute Socket.subscribe(:no_such_socket, [], :request_for_quote) ==
               {:error, {:credential_required, :request_for_quote}}
    end

    test "empty symbols against a public per-symbol channel is not refused — registers, asks for nothing" do
      assert Socket.subscribe(:no_such_socket, [], :book_ticker) == :ok
    end

    test "an unknown channel is not double-refused here — streams/2 already answers it" do
      assert Socket.subscribe(:no_such_socket, ["BTC-USD"], :candles) == :ok
    end
  end

  describe "a trade frame's side is inverted from `m`" do
    @trade %{
      "e" => "trade",
      "E" => 1_787_936_147_000_000_000,
      "s" => "btcusd",
      "t" => 5_335_307_668,
      "p" => "3610.85",
      "q" => "0.27413495",
      "m" => true
    }

    test "buyer-is-maker delivers a SELL-aggressed trade" do
      # /v1/trades reports the taker's side; @trade reports the maker flag. Passing `m`
      # through as a buy inverts every trade on the socket.
      assert {:ok, _state} = Socket.handle_frame(frame(@trade), state())

      assert_received {:dp_exchange, :gemini, %Types.Trade{} = trade}
      assert trade.side == :sell
      assert Decimal.equal?(trade.price, Decimal.new("3610.85"))
    end

    test "buyer-is-taker delivers a BUY-aggressed trade" do
      assert {:ok, _state} = Socket.handle_frame(frame(%{@trade | "m" => false}), state())

      assert_received {:dp_exchange, :gemini, %Types.Trade{side: :buy}}
    end

    test "an undated print is dropped rather than placed at the wrong moment" do
      undated = Map.delete(@trade, "E")

      assert {:ok, _state} = Socket.handle_frame(frame(undated), state())
      refute_received {:dp_exchange, :gemini, %Types.Trade{}}
    end
  end

  describe "a depth diff is not a book" do
    @diff %{
      "e" => "depthUpdate",
      "E" => 1_787_936_147_000_000_000,
      "s" => "btcusd",
      "U" => 11,
      "u" => 15,
      "b" => [["3610.00", "1.5"]],
      "a" => [["3611.00", "0"]]
    }

    test "it is delivered as an OrderBookDelta, never a raw frame or a full OrderBook" do
      # Handing a subscriber the changed levels under a type that means "the whole book" is
      # the substitution this family refuses — and handing them the undecoded venue JSON
      # is the same substitution one layer further out: a decoder (`WsDecode.
      # to_order_book_delta/2`) exists precisely so nothing downstream has to parse `"b"`
      # and `"a"` for itself.
      assert {:ok, _state} = Socket.handle_frame(frame(@diff), state())

      assert_received {:dp_exchange, :gemini, %Types.OrderBookDelta{} = delta}
      assert delta.symbol == "BTC-USD"
      assert delta.sequence == 15

      assert {:bid, price, quantity} =
               Enum.find(delta.levels, &match?({:bid, _price, _quantity}, &1))

      assert Decimal.equal?(price, Decimal.new("3610.00"))
      assert Decimal.equal?(quantity, Decimal.new("1.5"))

      # A quantity of zero is a DELETE, carried through unresolved — see `depth_changes/1`
      # and `OrderBookDelta`'s own moduledoc.
      assert {:ask, ask_price, ask_quantity} =
               Enum.find(delta.levels, &match?({:ask, _price, _quantity}, &1))

      assert Decimal.equal?(ask_price, Decimal.new("3611.00"))
      assert Decimal.equal?(ask_quantity, Decimal.new("0"))

      refute_received {:dp_exchange, :gemini, {:depth_update, _message}}
      refute_received {:dp_exchange, :gemini, %Types.OrderBook{}}
    end

    test "a contiguous frame raises no alarm and advances the sequence" do
      assert {:ok, new_state} =
               Socket.handle_frame(frame(@diff), state(%{last_depth_update: 10}))

      assert new_state.last_depth_update == 15
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    test "a sequence GAP is announced, because the local book is already wrong" do
      # The vendor's rule: discard the book and resubscribe. A consumer that keeps applying
      # holds a book that is silently wrong from here on, with every price real.
      assert {:ok, _state} =
               Socket.handle_frame(frame(@diff), state(%{last_depth_update: 5}))

      assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
      assert details.reason == "depth sequence gap"
    end

    test "the first frame is never a gap" do
      assert {:ok, _state} = Socket.handle_frame(frame(@diff), state())
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    test "an undated diff delivers nothing, but still advances the sequence" do
      # A delta whose place in the sequence cannot be stated must not reach a consumer —
      # same rule as an undated trade or a book ticker with no event time. The sequence
      # bookkeeping is unaffected: `depth_gap?/2` reads `u`, not the decoded delta.
      undated = Map.delete(@diff, "E")

      assert {:ok, new_state} = Socket.handle_frame(frame(undated), state())

      refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
      assert new_state.last_depth_update == 15
    end
  end

  describe "a partial-depth snapshot IS a book" do
    test "it carries absolute levels and the venue's lastUpdateId as the sequence" do
      snapshot = %{
        "s" => "btcusd",
        "lastUpdateId" => 4242,
        "bids" => [["3610.00", "1.5"]],
        "asks" => [["3611.00", "0.5"]]
      }

      assert {:ok, _state} = Socket.handle_frame(frame(snapshot), state())

      assert_received {:dp_exchange, :gemini, %Types.OrderBook{} = book}
      assert book.sequence == 4242
      assert length(book.bids) == 1
    end
  end
end
