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
    Map.merge(
      %{
        subscriber: self(),
        request_id: 0,
        connected_once?: false,
        last_heard_at: nil,
        liveness: nil
      },
      overrides
    )
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

    test "a print priced at zero or less is not delivered, and says so (MD6)" do
      for price <- ["0", "-1"] do
        assert {:ok, _state} = Socket.handle_frame(frame(%{@trade | "p" => price}), state())

        refute_received {:dp_exchange, :gemini, %Types.Trade{}}
        assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality}}
      end
    end

    test "a book ticker's last trade of zero is no Quote; a zero side is no resting order (MD6)" do
      ticker = %{
        "s" => "btcusd",
        "b" => "0",
        "B" => "3",
        "a" => "3611.00",
        "A" => "2",
        "c" => "0"
      }

      assert {:ok, _state} = Socket.handle_frame(frame(ticker), state())

      refute_received {:dp_exchange, :gemini, %Types.Quote{}}

      assert_received {:dp_exchange, :gemini, %Types.TopOfBook{} = top}
      assert top.bid == nil
      assert top.bid_size == nil
      assert Decimal.equal?(top.ask, Decimal.new("3611.00"))
      assert Decimal.equal?(top.ask_size, Decimal.new("2"))

      assert {:ok, _state} = Socket.handle_frame(frame(%{ticker | "b" => "-1"}), state())
      refute_received {:dp_exchange, :gemini, %Types.TopOfBook{}}
      assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality}}
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
      # `last_depth_update` is per-SYMBOL now — websocket.yaml:1269-1270 states the gap
      # rule per book, and a single node-wide integer (this override used to be a bare
      # `10`) let one symbol's traffic mask or fabricate a gap on another's.
      assert {:ok, new_state} =
               Socket.handle_frame(frame(@diff), state(%{last_depth_update: %{"BTC-USD" => 10}}))

      assert new_state.last_depth_update == %{"BTC-USD" => 15}
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    test "a sequence GAP is announced, because the local book is already wrong" do
      # The vendor's rule: discard the book and resubscribe. A consumer that keeps applying
      # holds a book that is silently wrong from here on, with every price real.
      assert {:ok, _state} =
               Socket.handle_frame(frame(@diff), state(%{last_depth_update: %{"BTC-USD" => 5}}))

      assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
      assert details.reason == "depth sequence gap"
      assert details.symbol == "BTC-USD"
    end

    test "a gap on one symbol does not mask or fabricate one on another" do
      # The exact bug a single node-wide counter had: ETH-USD's own history must not decide
      # whether BTC-USD's frame is a gap.
      # ETH-USD's own last-applied (10) makes THIS frame's U (20) a real gap (20 > 11);
      # BTC-USD's is contiguous.
      eth_diff = %{@diff | "s" => "ethusd", "U" => 20, "u" => 25}

      state =
        state(%{last_depth_update: %{"BTC-USD" => 10, "ETH-USD" => 10}})

      assert {:ok, new_state} = Socket.handle_frame(frame(@diff), state)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
      assert new_state.last_depth_update["BTC-USD"] == 15
      assert new_state.last_depth_update["ETH-USD"] == 10

      assert {:ok, _state} = Socket.handle_frame(frame(eth_diff), new_state)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
      assert details.symbol == "ETH-USD"
    end

    test "the first frame is never a gap" do
      assert {:ok, _state} = Socket.handle_frame(frame(@diff), state())
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    test "a stale or duplicate frame (u <= the last applied) is dropped, not applied (MD9)" do
      start = state(%{last_depth_update: %{"BTC-USD" => 15}})

      # Within one frame's span (2 here) of the last applied: a replay, not a restart.
      for u <- [15, 14] do
        stale = %{@diff | "U" => u - 1, "u" => u}

        assert {:ok, kept} = Socket.handle_frame(frame(stale), start)
        assert kept.last_depth_update == %{"BTC-USD" => 15}
        refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
        refute_received {:dp_exchange, :gemini, %Notice{}}
      end
    end

    @key {"BTC-USD", :depth}
    @later %{@diff | "U" => 40, "u" => 45}

    defp resync_start(overrides \\ %{}) do
      state(
        Map.merge(
          %{
            depth_snapshot?: true,
            depth_anchored: MapSet.new(["BTC-USD"]),
            last_depth_update: %{"BTC-USD" => 5},
            depth_streams: MapSet.new([@key])
          },
          overrides
        )
      )
    end

    # Drives a gap through the unsubscribe and its answer, to the point the subscribe is out.
    defp resync_to_awaiting(start) do
      assert {:ok, pending} = Socket.handle_frame(frame(@diff), start)
      assert %{@key => {:pending, ref}} = pending.depth_resync
      assert_received {:resync_depth, @key, ^ref}

      assert {:reply, {:text, unsubscribe}, unsubscribing} =
               Socket.handle_info({:resync_depth, @key, ref}, pending)

      assert %{"method" => "unsubscribe", "params" => ["btcusd@depth"], "id" => id} =
               Jason.decode!(unsubscribe)

      # Its own id, unique to this unsubscribe and recorded against the key.
      assert is_integer(id)
      assert %{@key => {:unsubscribing, ^ref, ^id}} = unsubscribing.depth_resync

      # An answer with any other id (a late one from a timed-out resync) releases nothing.
      assert {:ok, still} =
               Socket.handle_frame(frame(%{"id" => id + 1, "status" => 200}), unsubscribing)

      assert still.depth_resync == unsubscribing.depth_resync
      refute_received {:resubscribe_depth, @key, _ref}

      assert {:ok, subscribing} =
               Socket.handle_frame(frame(%{"id" => id, "status" => 200}), unsubscribing)

      assert_received {:resubscribe_depth, @key, ^ref}

      assert {:reply, {:text, subscribe}, awaiting} =
               Socket.handle_info({:resubscribe_depth, @key, ref}, subscribing)

      assert %{"method" => "subscribe", "params" => ["btcusd@depth"], "id" => sub_id} =
               Jason.decode!(subscribe)

      # Its own id too: the key's ack deadline, and the id its answer echoes.
      assert %{@key => {:awaiting, ^ref, ^sub_id}} = awaiting.depth_resync
      assert sub_id != id
      assert [{^sub_id, _timer}] = awaiting.ack_requests

      {ref, unsubscribing, awaiting}
    end

    defp resync_subscribe_id(awaiting) do
      %{@key => {:awaiting, _ref, id}} = awaiting.depth_resync
      id
    end

    test "a gap resyncs the symbol for a fresh snapshot, and drops every frame until it" do
      {ref, unsubscribing, awaiting} = resync_to_awaiting(resync_start())

      assert_received {:dp_exchange, :gemini, %Notice{details: %{reason: "depth sequence gap"}}}
      refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}

      assert %{@key => {:unsubscribing, ^ref, _seq}} = unsubscribing.depth_resync
      assert %{@key => {:awaiting, ^ref, _deadline}} = awaiting.depth_resync
      assert awaiting.unanswered_subscribes == 1

      # Old frames still arriving while the unsubscribe is unanswered are dropped, quietly.
      assert {:ok, dropped} = Socket.handle_frame(frame(@later), unsubscribing)
      assert dropped.depth_resync == unsubscribing.depth_resync
      assert dropped.last_depth_update == unsubscribing.last_depth_update
      refute_received {:dp_exchange, :gemini, _anything}

      # The first frame after the subscribe went out IS the snapshot, whether or not the
      # subscribe's own answer has come yet: a full book, not a gap against the old sequence.
      assert {:ok, taken} = Socket.handle_frame(frame(@later), awaiting)
      assert_received {:dp_exchange, :gemini, %Types.OrderBook{sequence: 45}}
      refute_received {:dp_exchange, :gemini, %Notice{}}
      assert taken.depth_resync == %{}
      assert taken.last_depth_update == %{"BTC-USD" => 45}

      # The answer arriving afterwards changes nothing and retires the ack request.
      sub_id = resync_subscribe_id(awaiting)

      assert {:ok, answered} =
               Socket.handle_frame(frame(%{"id" => sub_id, "status" => 200}), taken)

      assert answered.unanswered_subscribes == 0
      assert answered.depth_resync == %{}
    end

    test "the snapshot is taken after the subscribe's answer too" do
      {_ref, _unsubscribing, awaiting} = resync_to_awaiting(resync_start())

      sub_id = resync_subscribe_id(awaiting)

      assert {:ok, answered} =
               Socket.handle_frame(frame(%{"id" => sub_id, "status" => 200}), awaiting)

      assert Map.has_key?(answered.depth_resync, @key)

      assert {:ok, taken} = Socket.handle_frame(frame(@later), answered)
      assert_received {:dp_exchange, :gemini, %Types.OrderBook{sequence: 45}}
      assert taken.depth_resync == %{}
    end

    test "a refused resubscribe leaves depth_streams, says not delivering, and retries later" do
      {_ref, _unsubscribing, awaiting} = resync_to_awaiting(resync_start())

      sub_id = resync_subscribe_id(awaiting)

      assert {:ok, refused} =
               Socket.handle_frame(frame(%{"id" => sub_id, "status" => 400}), awaiting)

      refute MapSet.member?(refused.depth_streams, @key)
      assert refused.depth_resync == %{}
      assert refused.depth_resync_failures == %{@key => 1}
      assert %{@key => retry_ref} = refused.depth_retry

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :coverage_change,
                         details: %{delivering: false, symbol: "BTC-USD", status: 400}
                       }}

      # The retry is a delayed message (backoff), not an immediate one.
      refute_received {:retry_depth, _key, _ref}

      assert {:reply, {:text, subscribe}, retrying} =
               Socket.handle_info({:retry_depth, @key, retry_ref}, refused)

      assert %{"method" => "subscribe", "params" => ["btcusd@depth"]} = Jason.decode!(subscribe)
      assert MapSet.member?(retrying.depth_streams, @key)
      assert %{@key => {:awaiting, ^retry_ref, _deadline}} = retrying.depth_resync
      assert retrying.depth_retry == %{}

      # A retry nobody wants any more (unsubscribed: depth_retry forgotten) is not sent.
      assert {:ok, ^refused} =
               Socket.handle_info({:retry_depth, @key, make_ref()}, refused)
    end

    test "an unsubscribe that is never answered is retried with a backoff and a notice" do
      {ref, unsubscribing, _awaiting} = resync_to_awaiting(resync_start())

      assert {:ok, restarted} = Socket.handle_info({:resync_timeout, @key, ref}, unsubscribing)

      assert %{@key => {:pending, new_ref}} = restarted.depth_resync
      assert new_ref != ref
      assert restarted.depth_resync_failures == %{@key => 1}

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :coverage_change, details: %{delivering: false}}}

      # The old timer firing again, after the key moved on, does nothing.
      assert {:ok, ^restarted} = Socket.handle_info({:resync_timeout, @key, ref}, restarted)
    end

    test "resyncs are throttled: a gap inside the window waits, it does not resubscribe" do
      just_now = System.monotonic_time(:millisecond)
      start = resync_start(%{depth_resync_at: %{@key => just_now}})

      assert {:ok, waiting} = Socket.handle_frame(frame(@diff), start)
      assert %{@key => {:pending, ref}} = waiting.depth_resync

      # Not immediate: the message is due after the rest of the 5s window.
      refute_received {:resync_depth, @key, ^ref}
      assert_received {:dp_exchange, :gemini, %Notice{details: %{reason: "depth sequence gap"}}}

      # Meanwhile the symbol is not delivering and says nothing more.
      assert {:ok, still_waiting} = Socket.handle_frame(frame(@later), waiting)
      assert still_waiting.depth_resync == waiting.depth_resync
      refute_received {:dp_exchange, :gemini, _anything}

      # A window long past does not delay the resync.
      long_ago = System.monotonic_time(:millisecond) - 60_000
      idle = resync_start(%{depth_resync_at: %{@key => long_ago}})
      assert {:ok, started} = Socket.handle_frame(frame(@diff), idle)
      assert %{@key => {:pending, now_ref}} = started.depth_resync
      assert_received {:resync_depth, @key, ^now_ref}
    end

    test "a restart in the sequence is a gap in effect; a replay is still just dropped" do
      start = resync_start(%{last_depth_update: %{"BTC-USD" => 15_000}})
      restarted = %{@diff | "U" => 1, "u" => 5}

      assert {:ok, pending} = Socket.handle_frame(frame(restarted), start)
      assert %{@key => {:pending, _ref}} = pending.depth_resync

      assert_received {:dp_exchange, :gemini,
                       %Notice{details: %{reason: "depth sequence restart"}}}

      refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}

      # A duplicate of the last frame is not a restart: dropped, no notice, no resync.
      duplicate = %{@diff | "U" => 14_999, "u" => 15_000}
      assert {:ok, kept} = Socket.handle_frame(frame(duplicate), start)
      assert Map.get(kept, :depth_resync, %{}) == %{}
      assert kept.last_depth_update == %{"BTC-USD" => 15_000}
      refute_received {:dp_exchange, :gemini, _anything}
    end

    test "depth and depth_fast on one symbol are resynced as two keys" do
      fast = {"BTC-USD", :depth_fast}
      start = resync_start(%{depth_streams: MapSet.new([@key, fast])})

      assert {:ok, pending} = Socket.handle_frame(frame(@diff), start)
      assert %{@key => {:pending, _ref}, ^fast => {:pending, _fast_ref}} = pending.depth_resync

      # Not every channel of the symbol is awaiting, so a frame is not yet the snapshot.
      {:pending, ref} = pending.depth_resync[@key]

      assert {:reply, {:text, _unsubscribe}, half} =
               Socket.handle_info({:resync_depth, @key, ref}, pending)

      assert {:ok, kept} = Socket.handle_frame(frame(@later), half)
      assert kept.depth_resync == half.depth_resync
      refute_received {:dp_exchange, :gemini, %Types.OrderBook{}}
    end

    test "a resync for a symbol unsubscribed meanwhile is not sent" do
      ref = make_ref()
      key = {"BTC-USD", :depth}
      resyncing = state(%{depth_resync: %{key => {:pending, ref}}, depth_streams: MapSet.new()})

      assert {:ok, cleared} = Socket.handle_info({:resync_depth, key, ref}, resyncing)
      assert cleared.depth_resync == %{}

      # A stale ref (the resync was restarted or reset) does nothing at all.
      assert {:ok, ^resyncing} = Socket.handle_info({:resync_depth, key, make_ref()}, resyncing)
    end

    test "an unsubscribe answer releases only the key that sent it" do
      first = {"BTC-USD", :depth}
      second = {"ETH-USD", :depth}
      first_ref = make_ref()
      second_ref = make_ref()

      waiting =
        state(%{
          depth_streams: MapSet.new([first, second]),
          depth_resync: %{
            first => {:unsubscribing, first_ref, 10},
            second => {:unsubscribing, second_ref, 11}
          }
        })

      # The first key was forgotten or timed out: its answer (id 10) arrives late, and the
      # second key, which is NOT the one it belongs to, must not be released by it.
      forgotten = %{waiting | depth_resync: Map.delete(waiting.depth_resync, first)}

      assert {:ok, late} =
               Socket.handle_frame(frame(%{"id" => 10, "status" => 200}), forgotten)

      assert late.depth_resync == forgotten.depth_resync
      refute_received {:resubscribe_depth, _key, _ref}

      assert {:ok, released} =
               Socket.handle_frame(frame(%{"id" => 11, "status" => 200}), forgotten)

      assert_received {:resubscribe_depth, ^second, ^second_ref}
      assert %{^second => {:subscribing, ^second_ref}} = released.depth_resync
    end

    test "interleaved caller and resync subscribes are matched by id, not announce order" do
      {_ref, _unsubscribing, awaiting} = resync_to_awaiting(resync_start())
      sub_id = resync_subscribe_id(awaiting)

      # The caller's subscribe is announced AFTER the resync's, and the venue answers it first.
      caller_id = sub_id + 1_000
      {:ok, both} = Socket.handle_info({:awaiting_ack, caller_id}, awaiting)
      assert [{^sub_id, _t1}, {^caller_id, _t2}] = both.ack_requests

      assert {:ok, caller_answered} =
               Socket.handle_frame(frame(%{"id" => caller_id, "status" => 200}), both)

      # Oldest-first matching would have retired the resync's request here.
      assert [{^sub_id, _timer}] = caller_answered.ack_requests
      assert Map.has_key?(caller_answered.depth_resync, @key)

      assert {:ok, refused} =
               Socket.handle_frame(frame(%{"id" => sub_id, "status" => 400}), caller_answered)

      assert refused.ack_requests == []
      assert refused.depth_resync == %{}
      refute MapSet.member?(refused.depth_streams, @key)

      # And the other order: the resync's refusal does not retire the caller's request.
      assert {:ok, resync_first} =
               Socket.handle_frame(frame(%{"id" => sub_id, "status" => 400}), both)

      assert [{^caller_id, _timer}] = resync_first.ack_requests
      refute MapSet.member?(resync_first.depth_streams, @key)
    end

    test "a gap on a connection without the snapshot parameter stops the symbol" do
      start = %{
        depth_snapshot?: false,
        last_depth_update: %{"BTC-USD" => 5},
        depth_streams: MapSet.new([@key])
      }

      assert {:ok, stopped} = Socket.handle_frame(frame(@diff), state(start))

      assert MapSet.member?(stopped.depth_stopped, "BTC-USD")
      assert Map.get(stopped, :depth_resync, %{}) == %{}
      refute_received {:resync_depth, _key, _ref}
      refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}

      assert_received {:dp_exchange, :gemini, %Notice{details: %{reason: "depth sequence gap"}}}

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :coverage_change,
                         details: %{
                           delivering: false,
                           symbol: "BTC-USD",
                           reason: "depth book cannot be rebuilt" <> _rest
                         }
                       }}

      # Every later frame for it is dropped, quietly, even one that would continue the book.
      assert {:ok, still} = Socket.handle_frame(frame(@later), stopped)
      assert MapSet.member?(still.depth_stopped, "BTC-USD")
      refute_received {:dp_exchange, :gemini, _anything}

      # Another symbol is untouched.
      other = %{@later | "s" => "ethusd"}
      assert {:ok, _state} = Socket.handle_frame(frame(other), still)
      assert_received {:dp_exchange, :gemini, %Types.OrderBookDelta{symbol: "ETH-USD"}}
    end

    test "a stopped symbol is released by a reconnect" do
      stopped =
        state(%{depth_stopped: MapSet.new(["BTC-USD"]), depth_streams: MapSet.new([@key])})

      assert {:ok, reconnected} = Socket.handle_connect(:conn, stopped)
      assert reconnected.depth_stopped == MapSet.new()
      assert reconnected.depth_streams == MapSet.new()
    end

    test "an undated diff delivers nothing, but still advances the sequence" do
      # A delta whose place in the sequence cannot be stated must not reach a consumer —
      # same rule as an undated trade or a book ticker with no event time. The sequence
      # bookkeeping is unaffected: `depth_gap?/2` reads `u`, not the decoded delta.
      undated = Map.delete(@diff, "E")

      assert {:ok, new_state} = Socket.handle_frame(frame(undated), state())

      refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
      assert new_state.last_depth_update == %{"BTC-USD" => 15}
      # The book is now missing this frame's changes and the next frame will show no gap,
      # so the subscriber is told, as it is for a gap. It used to be silence.
      assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
      assert details.reason == "undecodable depth update"
    end

    test "a diff whose u is unreadable keeps the last good sequence, so the gap still shows" do
      # `u` used to be stored as it came, so a frame with no `u` set the symbol's last-applied
      # id to `nil`, which `depth_gap?/2` reads as "nothing applied yet". The frame after it
      # was then judged against nothing and a real gap behind it was never announced.
      start = state(%{last_depth_update: %{"BTC-USD" => 10}})

      for unreadable <- [Map.delete(@diff, "u"), %{@diff | "u" => "15"}] do
        assert {:ok, kept} = Socket.handle_frame(frame(unreadable), start)

        assert kept.last_depth_update == %{"BTC-USD" => 10}
        refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
        assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
        assert details.reason == "undecodable depth update"

        # The next frame continues from the unreadable one, so it skips ahead of 10: a gap.
        later = %{@diff | "U" => 16, "u" => 17}
        assert {:ok, _state} = Socket.handle_frame(frame(later), kept)
        assert_received {:dp_exchange, :gemini, %Notice{details: %{reason: "depth sequence gap"}}}
        # The later frame itself is still delivered; take it so the next pass starts clean.
        assert_received {:dp_exchange, :gemini, %Types.OrderBookDelta{sequence: 17}}
      end
    end

    test "an unreadable-u frame that is the anchor still marks the symbol anchored" do
      anchored = state(%{depth_snapshot?: true})

      assert {:ok, new_state} = Socket.handle_frame(frame(Map.delete(@diff, "u")), anchored)

      refute_received {:dp_exchange, :gemini, %Types.OrderBook{}}
      assert MapSet.member?(new_state.depth_anchored, "BTC-USD")
    end

    test "the anchor frame after a resubscribe is a full OrderBook, not a diff" do
      # See the moduledoc's "A depth diff stream needs its own anchor" (websocket.yaml:
      # 1263-1270): with the `snapshot` connection parameter set, the FIRST depthUpdate per
      # symbol carries absolute levels. `depth_snapshot?: true` is what `start_link/1` sets
      # from `:channels` when it includes `:depth`/`:depth_fast`.
      anchored_state = state(%{depth_snapshot?: true})

      assert {:ok, new_state} = Socket.handle_frame(frame(@diff), anchored_state)

      assert_received {:dp_exchange, :gemini, %Types.OrderBook{} = book}
      refute_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
      assert book.symbol == "BTC-USD"
      assert book.sequence == 15
      # Absolute levels, sorted per `OrderBook`'s own contract, not the venue's row order.
      assert [{price, quantity}] = book.bids
      assert Decimal.equal?(price, Decimal.new("3610.00"))
      assert Decimal.equal?(quantity, Decimal.new("1.5"))
      assert MapSet.member?(new_state.depth_anchored, "BTC-USD")

      # The SECOND frame for the same symbol is an ordinary diff. It continues the sequence:
      # the same frame again would be a replay, which is now dropped.
      next = %{@diff | "U" => 16, "u" => 17}
      assert {:ok, _state} = Socket.handle_frame(frame(next), new_state)
      assert_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
    end

    test "without the snapshot parameter, every depthUpdate is still a diff" do
      # `depth_snapshot?` unset (the default) is this socket's behaviour before the AsyncAPI
      # anchor was read at all.
      assert {:ok, _state} = Socket.handle_frame(frame(@diff), state())
      assert_received {:dp_exchange, :gemini, %Types.OrderBookDelta{}}
      refute_received {:dp_exchange, :gemini, %Types.OrderBook{}}
    end
  end

  describe "a partial-depth snapshot cannot name its own symbol" do
    # `OrderBookSnapshot` (websocket.yaml:1217-1233) requires only `[lastUpdateId, bids,
    # asks]` — no `s` — and no combined-stream wrapper names one either. This module used to
    # embed `"s"` in these fixtures anyway, pinning a shape the venue's own AsyncAPI document
    # never promises; corrected below to the genuine shape, attributed instead through
    # `partial_depth_claims`, which mirrors what `subscribe/3` records.
    test "it carries absolute levels and the venue's lastUpdateId as the sequence, attributed by the connection's one claimed symbol" do
      snapshot = %{
        "lastUpdateId" => 4242,
        "bids" => [["3610.00", "1.5"]],
        "asks" => [["3611.00", "0.5"]]
      }

      claimed = state(%{partial_depth_claims: MapSet.new([{:depth5, "BTC-USD"}])})
      assert {:ok, _state} = Socket.handle_frame(frame(snapshot), claimed)

      assert_received {:dp_exchange, :gemini, %Types.OrderBook{} = book}
      assert book.symbol == "BTC-USD"
      assert book.sequence == 4242
      assert length(book.bids) == 1
    end

    test "a snapshot with an unreadable side is not delivered as a book" do
      snapshot = %{"lastUpdateId" => 7, "bids" => nil, "asks" => []}
      claimed = state(%{partial_depth_claims: MapSet.new([{:depth5, "BTC-USD"}])})

      assert {:ok, _state} = Socket.handle_frame(frame(snapshot), claimed)
      refute_received {:dp_exchange, :gemini, %Types.OrderBook{}}

      assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
      assert details.reason == "unreadable partial-depth snapshot"
    end

    test "a snapshot on a connection with no claim raises a notice rather than vanishing" do
      # The `with` this replaced had no `else`: an unattributable snapshot silently
      # disappeared. A snapshot that cannot be attributed must raise a notice instead.
      snapshot = %{"lastUpdateId" => 1, "bids" => [], "asks" => []}

      assert {:ok, _state} = Socket.handle_frame(frame(snapshot), state())
      refute_received {:dp_exchange, :gemini, %Types.OrderBook{}}

      assert_received {:dp_exchange, :gemini, %Notice{kind: :degraded, details: details}}
      assert details.reason == "unattributable partial-depth snapshot"
    end
  end

  describe "subscribe/3 refuses a second, distinct partial-depth symbol on the same connection" do
    defmodule SocketStub do
      @moduledoc false
      use GenServer

      @spec start_link(map()) :: GenServer.on_start()
      def start_link(state), do: GenServer.start_link(__MODULE__, state)

      @impl true
      def init(state), do: {:ok, state}

      # Answers the raw `:gen.call(socket, :"$websockex_send", frame, timeout)` protocol
      # `VendoredWebSockex.send_frame/2` uses, so `send_rpc/3` gets an ordinary `:ok`
      # rather than timing out against a stub that only understands `:sys`.
      @impl true
      def handle_info({:"$websockex_send", from, _frame}, state) do
        :gen.reply(from, :ok)
        {:noreply, state}
      end

      # `subscribe/3` announces each request before sending it, so the real socket can
      # time out an unanswered one. This stub has no deadline to arm.
      def handle_info({:awaiting_ack, _id}, state), do: {:noreply, state}

      def handle_info({:ack_withdrawn, _id}, state), do: {:noreply, state}
    end

    setup do
      {:ok, socket} = SocketStub.start_link(state())
      %{socket: socket}
    end

    test "the same symbol on a second partial-depth channel is fine", %{socket: socket} do
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth5)
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth10)
    end

    test "a different symbol is refused, named, before any frame is sent", %{socket: socket} do
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth5)

      assert Socket.subscribe(socket, ["ETH-USD"], :depth10) ==
               {:error, {:partial_depth_symbol_conflict, "BTC-USD"}}
    end

    test "one call naming two distinct symbols is refused outright", %{socket: socket} do
      assert Socket.subscribe(socket, ["BTC-USD", "ETH-USD"], :depth5) ==
               {:error, {:partial_depth_symbol_conflict, ["BTC-USD", "ETH-USD"]}}
    end

    test "unsubscribing releases the claim, so a different symbol can be claimed next", %{
      socket: socket
    } do
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth5)
      assert :ok = Socket.unsubscribe(socket, ["BTC-USD"], :depth5)
      assert :ok = Socket.subscribe(socket, ["ETH-USD"], :depth5)
    end

    test "a symbol on one diff channel is refused on the other, before any frame is sent", %{
      socket: socket
    } do
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth)

      assert Socket.subscribe(socket, ["BTC-USD"], :depth_fast) ==
               {:error, {:conflicting_depth_channel, "BTC-USD"}}

      assert :sys.get_state(socket).depth_streams == MapSet.new([{"BTC-USD", :depth}])

      # A call naming one conflicting symbol records none of its symbols.
      assert Socket.subscribe(socket, ["ETH-USD", "BTC-USD"], :depth_fast) ==
               {:error, {:conflicting_depth_channel, "BTC-USD"}}

      assert :sys.get_state(socket).depth_streams == MapSet.new([{"BTC-USD", :depth}])

      # The same channel again, and another symbol on the other channel, are fine.
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth)
      assert :ok = Socket.subscribe(socket, ["ETH-USD"], :depth_fast)

      # Unsubscribing frees the symbol to switch channels.
      assert :ok = Socket.unsubscribe(socket, ["BTC-USD"], :depth)
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :depth_fast)

      assert :sys.get_state(socket).depth_streams ==
               MapSet.new([{"BTC-USD", :depth_fast}, {"ETH-USD", :depth_fast}])
    end

    test "subscribing a stopped symbol again releases it and forgets its sequence" do
      {:ok, stopped} =
        SocketStub.start_link(
          state(%{
            depth_stopped: MapSet.new(["BTC-USD"]),
            last_depth_update: %{"BTC-USD" => 5, "ETH-USD" => 9}
          })
        )

      assert :ok = Socket.subscribe(stopped, ["BTC-USD"], :depth)

      released = :sys.get_state(stopped)
      assert released.depth_stopped == MapSet.new()
      assert released.last_depth_update == %{"ETH-USD" => 9}
      assert MapSet.member?(released.depth_streams, {"BTC-USD", :depth})

      # Unsubscribing a stopped symbol clears the mark too.
      {:ok, other} = SocketStub.start_link(state(%{depth_stopped: MapSet.new(["BTC-USD"])}))
      assert :ok = Socket.unsubscribe(other, ["BTC-USD"], :depth)
      assert :sys.get_state(other).depth_stopped == MapSet.new()
    end

    test "non-partial-depth channels never touch the claim", %{socket: socket} do
      assert :ok = Socket.subscribe(socket, ["BTC-USD"], :book_ticker)
      assert :ok = Socket.subscribe(socket, ["ETH-USD"], :trade)
    end
  end
end
