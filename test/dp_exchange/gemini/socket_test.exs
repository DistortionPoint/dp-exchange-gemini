defmodule DpExchange.Gemini.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Gemini.{Socket, WsDecode}

  @moduletag :capture_log

  # The frame handlers are pure given a state, so they are driven directly. No socket is
  # opened and no venue is reached — a tier-1 test that dials a venue is a tier-2 test
  # wearing the wrong tag, and it will fail in CI on a bad day rather than a bad commit.
  defp state,
    do: %{
      subscriber: self(),
      request_id: 0,
      connected_once?: false,
      last_heard_at: nil,
      liveness: nil
    }

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
      assert quote_struct.symbol == "BTC-USD"
    end

    test "event time is read as NANOseconds" do
      # A factor of a million. Read as milliseconds this timestamp lands in the year
      # 58,000 and every staleness check passes forever.
      #
      # This used to assert the same thing of the `Quote`'s `venue_time` — read from the
      # frame's own `E`, the book UPDATE time. `c` (websocket.yaml:1254-1256) is "Last
      # trade price, present once the book has traded", with no trade time documented, so a
      # `Quote`'s `venue_time` is `nil` now (see `deliver_last_trade/3`) and this assertion
      # belongs to `TopOfBook`, which genuinely is dated from `E`.
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{venue_time: timestamp}}
      assert timestamp.year == 2026

      assert_receive {:dp_exchange, :gemini, %Quote{venue_time: nil}}
    end

    test "an empty-string bid/ask does not crash the socket — reproduced live 2026-09-04" do
      # A 347-symbol subscribe against production wss://ws.gemini.com crashed this socket
      # within seconds: one frame carried "" for a bid, and Decimal.new/1 raised, taking
      # the whole connection down. A single-symbol test never sends enough traffic to hit
      # this — that is exactly why it shipped. `Decimal.parse/1` is nil-safe instead.
      frame = %{@book_ticker | "b" => "", "a" => "", "B" => "", "A" => ""}

      assert {:ok, _state} = deliver(frame)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{} = top}
      assert top.bid == nil
      assert top.ask == nil
      assert top.bid_size == nil
      assert top.ask_size == nil
    end

    test "\"null\" in place of a price does not crash the socket" do
      frame = %{@book_ticker | "c" => "null"}

      assert {:ok, _state} = deliver(frame)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{}}
      # `deliver/1` is a direct call: everything it sends is already in the mailbox.
      refute_received {:dp_exchange, :gemini, %Quote{}}
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
      assert Decimal.equal?(ask, Decimal.new("77846.48000"))

      refute_received {:dp_exchange, :gemini, %Quote{}}
    end

    test "a frame with NO event time still delivers the book and the last trade" do
      # This asserted the opposite until 2026-09-13 — "delivers nothing at all" — defended
      # as "refusing to substitute means dropping the frame. A quote whose freshness cannot
      # be stated must not reach a consumer."
      #
      # Refusing to substitute IS right. This was not that. A substitution would be writing
      # our own clock into `venue_time`; emitting `nil` there is the opposite of a
      # substitution, and `Core.Types.TopOfBook` is explicit about both halves: `venue_time`
      # "is `nil` where the venue publishes none", and `observed_at` — always present — is
      # "a different, honest fact, and giving it its own field is what keeps it from being
      # mistaken for one". Freshness WAS stateable. It just was not stated in the venue's
      # field, which is the one thing nobody was proposing to do.
      #
      # Two things show the rule was a local anomaly rather than a principle. This package's
      # own REST arm states `venue_time: nil` — same venue, same type, opposite answer,
      # decided by transport.
      # And `Core.Types.TopOfBook`'s moduledoc names another venue in this family whose BBO
      # publishes no time at all, which this rule would have made unrepresentable.
      #
      # It mattered more than a nil field: `Socket` swallowed the error silently and
      # `deliver_last_trade/4` sat inside the success branch, so one absent optional field
      # dropped BOTH kinds this channel carries. This repository's own captured frame
      # (docs/reference/gemini/demo-environment.md, 2026-08-28) is `{"s","b","a","c"}` with
      # no `E`.
      #
      # Note also what the old assertion actually checked: only that no `Quote` arrived. Its
      # name claimed "nothing at all" and it never looked for the `TopOfBook`.
      assert {:ok, _state} = deliver(Map.delete(@book_ticker, "E"))

      assert_receive {:dp_exchange, :gemini, %TopOfBook{} = top}
      assert Decimal.equal?(top.bid, Decimal.new("77845.79000"))
      assert top.venue_time == nil, "the venue stated no time, and nil says exactly that"

      assert %DateTime{} = top.observed_at,
             "freshness is still stated, by the field that says what it is"

      assert_receive {:dp_exchange, :gemini, %Quote{} = quoted}
      assert Decimal.equal?(quoted.price, Decimal.new("77834.11000"))
      assert quoted.venue_time == nil
    end

    test "a Trade still requires the event time, because its contract does" do
      # Not an inconsistency with the test above — a different type with a different rule.
      # `Core.Types.Trade` lists `:timestamp` in `@enforce_keys` and types it non-nullable,
      # so a print this package cannot place in time is genuinely not one it can report.
      # `TopOfBook` does not enforce `venue_time`. The answers differ because the contracts
      # differ, which is the only reason they are allowed to.
      assert {:error, :missing_venue_timestamp} =
               WsDecode.to_trade(
                 %{"p" => "1", "q" => "1", "m" => false},
                 "BTC-USD"
               )
    end

    test "a native symbol whose quote currency is GUSD splits correctly off the wire" do
      assert {:ok, _state} = deliver(%{@book_ticker | "s" => "aavegusd"})

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "AAVE-GUSD"}}
      assert_receive {:dp_exchange, :gemini, %TopOfBook{symbol: "AAVE-GUSD"}}
    end

    test "the SAME last trade price is reported only once per connection" do
      # `bookTicker` re-sends the same `c` on every top-of-book change until the NEXT trade
      # — this channel is not itself trade-triggered. Delivering a `Quote` on every re-send
      # would report one execution as a fresh trade each time the bid or ask merely moved.
      assert {:ok, state_after_first} = deliver(@book_ticker)
      assert_receive {:dp_exchange, :gemini, %Quote{}}

      assert {:ok, _state} =
               Socket.handle_frame({:text, Jason.encode!(@book_ticker)}, state_after_first)

      refute_received {:dp_exchange, :gemini, %Quote{}}
    end

    test "a CHANGED last trade price delivers a new Quote" do
      assert {:ok, state_after_first} = deliver(@book_ticker)
      assert_receive {:dp_exchange, :gemini, %Quote{}}

      changed = %{@book_ticker | "c" => "77900.00000"}

      assert {:ok, _state} =
               Socket.handle_frame({:text, Jason.encode!(changed)}, state_after_first)

      assert_receive {:dp_exchange, :gemini, %Quote{price: price}}
      assert Decimal.equal?(price, Decimal.new("77900.00000"))
    end

    test "a reconnect resets the dedupe, so the same price is reported again" do
      # A reconnected socket has forgotten what it last reported, the same way it has
      # forgotten what it last subscribed — see `handle_connect/2`.
      assert {:ok, state_after_first} = deliver(@book_ticker)
      assert_receive {:dp_exchange, :gemini, %Quote{}}

      assert {:ok, reconnected_state} = Socket.handle_connect(:conn, state_after_first)

      assert {:ok, _state} =
               Socket.handle_frame({:text, Jason.encode!(@book_ticker)}, reconnected_state)

      assert_receive {:dp_exchange, :gemini, %Quote{}}
    end
  end

  describe "control frames" do
    test "a failed subscribe raises a notice rather than passing silently" do
      # Continuing quietly is how a feed reports healthy while delivering nothing.
      # `:refusal`, not `:coverage_change`: this is the venue's own word about a
      # subscription it received and declined — `Core.Notice`'s own moduledoc defines
      # `:refusal` as "a symbol the venue will not carry".
      assert {:ok, _state} = deliver(%{"id" => 1, "status" => 400})

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :refusal} = notice}
      assert notice.details.subscribe_status == 400
      # An untracked request names no symbols; the reason is an atom (family decision D4).
      assert notice.details.symbols == []
      assert notice.details.reason == :subscribe_refused
    end

    test "a refusal names the symbols of the subscribe it answers (details.symbols)" do
      {:ok, armed} = Socket.handle_info({:awaiting_ack, 41, ["BTC-USD", "ETH-USD"]}, state())

      assert {:ok, answered} =
               Socket.handle_frame({:text, Jason.encode!(%{"id" => 41, "status" => 400})}, armed)

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :refusal} = notice}
      assert notice.details.symbols == ["BTC-USD", "ETH-USD"]
      assert notice.details.subscribe_status == 400
      assert notice.details.reason == :subscribe_refused
      # Retired with the request: a later untracked refusal does not inherit them.
      assert answered.ack_streams == %{}

      untracked = {:text, Jason.encode!(%{"id" => 99, "status" => 400})}
      assert {:ok, _state} = Socket.handle_frame(untracked, answered)

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :refusal} = later}
      assert later.details.symbols == []
    end

    test "an accepted subscribe retires its symbols without a notice" do
      {:ok, armed} = Socket.handle_info({:awaiting_ack, 41, ["BTC-USD"]}, state())

      assert {:ok, answered} =
               Socket.handle_frame({:text, Jason.encode!(%{"id" => 41, "status" => 200})}, armed)

      assert answered.ack_streams == %{}
      refute_received {:dp_exchange, :gemini, %Notice{}}
    end

    test "a successful subscribe ack is not noise" do
      assert {:ok, _state} = deliver(%{"id" => 1, "status" => 200})

      refute_received {:dp_exchange, :gemini, %Notice{}}
    end
  end

  describe "frames this package does not model" do
    test "unrecognised JSON is ignored, not crashed on" do
      assert {:ok, _state} = deliver(%{"e" => "kline", "s" => "btcusd"})
      refute_received {:dp_exchange, :gemini, _anything}
    end

    test "malformed JSON does not crash, and is reported rather than dropped in silence" do
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :data_quality, details: %{reason: :undecodable_frame}}}

      refute_received {:dp_exchange, :gemini, _anything}
    end

    test "a binary frame is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:binary, <<1, 2, 3>>}, state())
      refute_received {:dp_exchange, :gemini, _anything}
    end
  end

  describe "a malformed frame does not take the connection down, or invent a symbol" do
    # Found by mutating real frames, 2026-09-26.
    @trade_frame %{
      "e" => "trade",
      "E" => 1_787_936_147_000_000_000,
      "s" => "btcusd",
      "t" => 5_335_307_668,
      "p" => "3610.85",
      "q" => "0.27413495",
      "m" => true
    }

    test "a trade with no symbol is dropped, not delivered for the symbol \"\"" do
      assert {:ok, _state} = deliver(Map.delete(@trade_frame, "s"))
      refute_received {:dp_exchange, :gemini, %DpExchange.Core.Types.Trade{}}

      # Found 2026-10-10: the drop used to be silent.
      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :data_quality, details: %{reason: :undecodable_trade}}}
    end

    test "a trade whose price or time cannot be read raises a notice instead of vanishing" do
      for bad <- [%{@trade_frame | "p" => "garbage"}, Map.delete(@trade_frame, "E")] do
        assert {:ok, _state} = deliver(bad)
        refute_received {:dp_exchange, :gemini, %DpExchange.Core.Types.Trade{}}

        assert_received {:dp_exchange, :gemini,
                         %Notice{
                           kind: :data_quality,
                           details: %{reason: :undecodable_trade, symbol: "BTC-USD"}
                         }}
      end
    end

    test "a non-string symbol does not raise, and nothing is delivered for it" do
      for bad <- [0, %{}, []] do
        assert {:ok, _state} = deliver(%{@trade_frame | "s" => bad})

        assert_received {:dp_exchange, :gemini,
                         %Notice{kind: :data_quality, details: %{reason: :undecodable_trade}}}

        assert {:ok, _state} = deliver(%{@book_ticker | "s" => bad})

        assert_received {:dp_exchange, :gemini,
                         %Notice{
                           kind: :data_quality,
                           details: %{reason: :undecodable_book_ticker}
                         }}

        refute_received {:dp_exchange, :gemini, %DpExchange.Core.Types.Trade{}}
        refute_received {:dp_exchange, :gemini, %TopOfBook{}}
        refute_received {:dp_exchange, :gemini, %Quote{}}
      end
    end

    test "a trade id that is not a string or integer is nil, not a raise" do
      for bad <- [%{}, [%{}]] do
        assert {:ok, _state} = deliver(%{@trade_frame | "t" => bad})
        assert_received {:dp_exchange, :gemini, %DpExchange.Core.Types.Trade{id: nil}}
      end
    end

    test "an event time outside the calendar is refused, not raised on" do
      assert {:ok, _state} = deliver(%{@trade_frame | "E" => 999_999_999_999_999_999_999_999_999})
      refute_received {:dp_exchange, :gemini, %DpExchange.Core.Types.Trade{}}
    end
  end

  describe "liveness — a dead connection is found by pinging it" do
    # See the moduledoc's "A dead connection is found by pinging it".
    defp checked(heard_ms_ago) do
      check = make_ref()
      heard = System.monotonic_time(:millisecond) - heard_ms_ago
      {check, %{state() | liveness: check, last_heard_at: heard}}
    end

    test "nothing heard past the limit: say so and close, so it reconnects" do
      {check, silent} = checked(100_000)

      assert {:close, _state} = Socket.handle_info({:liveness, check}, silent)

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :degraded, details: %{reason: :silent_connection}}}
    end

    test "heard recently: ping, and look again later" do
      {check, live} = checked(0)

      assert {:reply, :ping, pinged} = Socket.handle_info({:liveness, check}, live)
      # The only change is the re-armed check, which is now kept so it can be cancelled.
      assert Map.delete(pinged, :liveness_timer) == live
      assert is_reference(pinged.liveness_timer)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    # The limit is `@silence_ms` (90 s). The clock only moves forward between `checked/1`
    # and the call, so 89 s of silence stays under it and 90 s can only be at or past it.
    test "89 seconds of silence pings and does not close" do
      {check, quiet} = checked(89_000)

      assert {:reply, :ping, _state} = Socket.handle_info({:liveness, check}, quiet)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    test "90 seconds of silence closes" do
      {check, silent} = checked(90_000)

      assert {:close, closed} = Socket.handle_info({:liveness, check}, silent)
      assert closed.liveness == nil

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :degraded,
                         details: %{reason: :silent_connection, silent_for_ms: silent_for}
                       }}

      assert silent_for >= 90_000
    end

    test "a pong counts as being heard from" do
      {_check, stale} = checked(100_000)
      assert {:ok, heard} = Socket.handle_pong(:pong, stale)
      assert heard.last_heard_at > stale.last_heard_at
    end

    test "a check left over from an earlier connection does nothing" do
      {_check, current} = checked(100_000)
      assert {:ok, ^current} = Socket.handle_info({:liveness, make_ref()}, current)
    end
  end

  describe "an unanswered subscribe — a connection that pongs but is not serving" do
    # See the moduledoc's "A connection that answers pings but not subscribes is not
    # serving". 2026-10-02: after a `1012 "Server shutting down"` the reconnected socket
    # answered pings for three minutes while delivering nothing.
    # Every request carries an id of its own, and its answer is matched by that id.
    @first_id 41
    @second_id 42
    @ack %{"id" => @first_id, "status" => 200}

    defp awaiting(state, id \\ @first_id) do
      {:ok, state} = Socket.handle_info({:awaiting_ack, id}, state)
      state
    end

    test "a deadline that finds a request unanswered says so and closes, so it reconnects" do
      state = awaiting(state())
      deadline = state.ack_deadline

      assert {:close, closed} = Socket.handle_info({:ack_deadline, deadline}, state)
      assert closed.ack_deadline == nil

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :degraded,
                         details: %{reason: :subscribe_unanswered, unanswered: 1}
                       }}
    end

    test "an answer disarms the deadline, so it does nothing when it fires" do
      armed = awaiting(state())
      deadline = armed.ack_deadline

      {:ok, answered} = Socket.handle_frame({:text, Jason.encode!(@ack)}, armed)
      assert answered.ack_deadline == nil

      assert {:ok, _state} = Socket.handle_info({:ack_deadline, deadline}, answered)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
    end

    test "a refusal is an answer too — it is reported as a refusal, not as silence" do
      armed = awaiting(state())

      {:ok, answered} =
        Socket.handle_frame(
          {:text, Jason.encode!(%{"id" => @first_id, "status" => 400})},
          armed
        )

      assert answered.ack_deadline == nil
      assert_received {:dp_exchange, :gemini, %Notice{kind: :refusal}}
    end

    test "an answer retires the request whose id it echoes, whatever order they come in" do
      # Answers used to be matched oldest first. A request announced first but answered
      # second must not lose its deadline to the other one's answer.
      first = awaiting(state(), @first_id)
      second = awaiting(first, @second_id)

      second_ack = %{"id" => @second_id, "status" => 200}
      {:ok, half} = Socket.handle_frame({:text, Jason.encode!(second_ack)}, second)

      assert [{@first_id, _timer}] = half.ack_requests
      assert half.ack_deadline == @first_id
      assert half.unanswered_subscribes == 1

      {:ok, done} = Socket.handle_frame({:text, Jason.encode!(@ack)}, half)
      assert done.ack_requests == []
    end

    test "each request has its own deadline, so an answer to the first does not leave the " <>
           "second on the first's clock" do
      # One deadline used to cover every request outstanding when it was armed. A request sent
      # 14s into it was closed 1s after it was sent.
      first = awaiting(state(), @first_id)
      second = awaiting(first, @second_id)
      first_deadline = first.ack_deadline
      assert second.ack_deadline == first_deadline

      assert [{^first_deadline, _first_timer}, {second_deadline, _second_timer}] =
               second.ack_requests

      assert second_deadline != first_deadline

      {:ok, half} = Socket.handle_frame({:text, Jason.encode!(@ack)}, second)
      assert half.unanswered_subscribes == 1
      assert half.ack_deadline == second_deadline

      # The first request's clock running out is not about the second request.
      assert {:ok, ^half} = Socket.handle_info({:ack_deadline, first_deadline}, half)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}

      assert {:close, closed} = Socket.handle_info({:ack_deadline, second_deadline}, half)
      assert closed.ack_requests == []

      assert_received {:dp_exchange, :gemini,
                       %Notice{details: %{reason: :subscribe_unanswered, unanswered: 1}}}
    end

    test "a request whose frame never went out is withdrawn by its id, not by position" do
      first = awaiting(state(), @first_id)
      second = awaiting(first, @second_id)
      first_deadline = first.ack_deadline
      [_oldest, {second_deadline, _second_timer}] = second.ack_requests

      {:ok, withdrawn} = Socket.handle_info({:ack_withdrawn, @second_id}, second)

      assert withdrawn.unanswered_subscribes == 1
      assert withdrawn.ack_deadline == first_deadline
      assert {:ok, ^withdrawn} = Socket.handle_info({:ack_deadline, second_deadline}, withdrawn)
      assert {:close, _state} = Socket.handle_info({:ack_deadline, first_deadline}, withdrawn)

      # The OLDER one withdrawn leaves the newer: an interleaved send can fail out of order.
      {:ok, older_gone} = Socket.handle_info({:ack_withdrawn, @first_id}, second)
      assert [{@second_id, _timer}] = older_gone.ack_requests

      # An id nobody is waiting on is not found, and nothing else is withdrawn.
      assert {:ok, ^second} = Socket.handle_info({:ack_withdrawn, 999}, second)
    end

    test "an answer with nothing outstanding changes nothing" do
      idle = state()
      assert {:ok, answered} = Socket.handle_frame({:text, Jason.encode!(@ack)}, idle)
      assert Map.get(answered, :unanswered_subscribes, 0) == 0
    end

    test "a reconnect forgets what the old connection was owed" do
      armed = awaiting(state())
      {:ok, reconnected} = Socket.handle_connect(:conn, armed)

      assert reconnected.unanswered_subscribes == 0
      assert reconnected.ack_deadline == nil
      assert {:ok, _state} = Socket.handle_info({:ack_deadline, armed.ack_deadline}, reconnected)
    end
  end

  describe "connection lifecycle" do
    test "only a RE-connect is reported to the feed, so it can resubscribe at once" do
      # The first connect is followed by `Feed`'s own subscribe; reporting it too would
      # send the same subscription twice.
      assert {:ok, first} = Socket.handle_connect(:conn, state())
      refute_received {:dp_exchange, :gemini, :reconnected, _pid}

      assert {:ok, _again} = Socket.handle_connect(:conn, first)
      me = self()
      assert_received {:dp_exchange, :gemini, :reconnected, ^me}
    end

    test "the FIRST connect is reported only by a socket that dialled asynchronously" do
      # `Feed` dials with `async: true` and has no other way to learn the connect finished.
      assert {:ok, _first} = Socket.handle_connect(:conn, state())
      refute_received {:dp_exchange, :gemini, :connected, _pid}

      asynchronous = Map.put(state(), :report_connect?, true)
      assert {:ok, again} = Socket.handle_connect(:conn, asynchronous)
      me = self()
      assert_received {:dp_exchange, :gemini, :connected, ^me}

      # Only the first: a re-connect is `:reconnected`, never `:connected` again.
      assert {:ok, _third} = Socket.handle_connect(:conn, again)
      refute_received {:dp_exchange, :gemini, :connected, _pid}
      assert_received {:dp_exchange, :gemini, :reconnected, ^me}
    end

    test "the dial budget is the connect timeout plus the recv timeout, and overridable" do
      assert Socket.dial_budget_ms([]) == 5_000

      assert Socket.dial_budget_ms(socket_connect_timeout: 7_000, socket_recv_timeout: 1_000) ==
               8_000
    end

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
      assert Map.keys(details) == [:message, :reason]
      assert details.reason == :disconnected
    end

    test "a disconnect reason carrying a large venue body is bounded in the notice" do
      body = String.duplicate("x", 50_000)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: {:remote, 1006, body}}, state())

      assert_receive {:dp_exchange, :gemini,
                      %Notice{kind: :link_down, details: %{reason: :disconnected, message: text}}}

      assert is_binary(text)
      assert byte_size(text) < 2_048
      assert text =~ "remote"
    end
  end

  describe "connect_opts/1 — the connect timeout budget start_link/1 actually uses" do
    # `start_link/1` itself dials a real socket and can't be exercised here (see the
    # module note at the top of this file), so this pins the keyword list it builds and
    # passes to `WebSockex.start_link/4` instead — the one thing that actually determines
    # the connect budget. Before this existed, `start_link/1` passed no opts to
    # `WebSockex.start_link/4` at all, silently inheriting websockex's own 6s/5s defaults
    # rather than the 3s/2s this package chose against its own `@call_timeout` budget; a
    # regression back to that would not show up as a compile error or a crash, only as a
    # slow venue eventually wedging every consumer sharing one `Feed`.
    test "defaults to this package's own chosen budget, not websockex's" do
      assert [socket_connect_timeout: 3_000, socket_recv_timeout: 2_000, ssl_options: tls] =
               Socket.connect_opts([])

      # Verified TLS by default; websockex's own default is `verify: :verify_none`.
      assert tls[:verify] == :verify_peer
      assert is_list(tls[:cacerts]) and tls[:cacerts] != []
    end

    test "an explicit ssl_options of nil or [] keeps certificate verification" do
      for absent <- [nil, [], :none, "x", [:not_a_keyword]] do
        tls = Socket.connect_opts(ssl_options: absent)[:ssl_options]

        assert tls[:verify] == :verify_peer
        assert is_list(tls[:cacerts]) and tls[:cacerts] != []
        assert Keyword.has_key?(tls, :customize_hostname_check)
      end
    end

    test "a caller's ssl_options that say nothing about :verify get verification added" do
      tls = Socket.connect_opts(ssl_options: [depth: 3])[:ssl_options]

      assert tls[:depth] == 3
      assert tls[:verify] == :verify_peer
      assert is_list(tls[:cacerts]) and tls[:cacerts] != []
    end

    test "a caller's own :cacerts is used, and the OS trust store is not read for it" do
      tls = Socket.connect_opts(ssl_options: [cacerts: [:mine]])[:ssl_options]

      assert tls[:cacerts] == [:mine]
      assert tls[:verify] == :verify_peer
    end

    test "a caller's explicit :verify override is respected untouched" do
      opts = [verify: :verify_peer, cacerts: [:mine], password: "x"]

      assert Socket.connect_opts(ssl_options: opts)[:ssl_options] == opts
    end

    test "a caller's :socket_connect_timeout wins over the default" do
      assert Socket.connect_opts(socket_connect_timeout: 9_000)[:socket_connect_timeout] ==
               9_000
    end

    test "a caller's :socket_recv_timeout wins over the default" do
      assert Socket.connect_opts(socket_recv_timeout: 9_000)[:socket_recv_timeout] == 9_000
    end

    test "unrelated opts (subscriber, url, ...) are not carried into the connect opts" do
      # `start_link/1`'s own `opts` carry `:subscriber` always, and `:url` on ordinary use
      # — neither is a `websockex` connection option, and `WebSockex.Conn` would ignore an
      # unknown key rather than reject it, so a leak here would be silent.
      opts = [subscriber: self(), url: "wss://example.invalid", socket_connect_timeout: 1_000]

      assert [socket_connect_timeout: 1_000, socket_recv_timeout: 2_000, ssl_options: _tls] =
               Socket.connect_opts(opts)
    end
  end

  describe "the link reports itself on the metrics channel too" do
    # `Core.Telemetry` documented `[:dp_exchange, :link, …]` as events "every venue package
    # emits" and nothing in the family emitted any of them, for as long as the spec existed.
    # `:telemetry.attach/4` against a name nobody emits SUCCEEDS, so a consumer's dashboard
    # showed an empty panel — which reads as a venue with no traffic, not as an unimplemented
    # spec. These tests attach real handlers: one that only called an emitter and checked it
    # returned `:ok` would pass just as happily against the version that emitted nothing.
    setup do
      test_pid = self()
      handler_id = "link-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:dp_exchange, :link, :up],
          [:dp_exchange, :link, :down],
          [:dp_exchange, :link, :event]
        ],
        fn event, measurements, metadata, _config ->
          # Scoped to this test: `:telemetry` handlers are global to the VM, but they run in
          # the EMITTING process, and these tests call the socket callbacks directly. Another
          # async test's `:gemini` event (same provider, same counts) would otherwise satisfy
          # an `assert_receive` here while this test's own emit was broken.
          if self() == test_pid and metadata.provider == :gemini do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "connecting emits link up" do
      assert {:ok, _state} = Socket.handle_connect(:conn, state())
      assert_receive {:telemetry, [:dp_exchange, :link, :up], %{count: 1}, _metadata}
    end

    test "disconnecting emits link down with an already-inspected reason" do
      # Aggregators group by value; a raw reason carrying a pid or a socket ref would make
      # every occurrence a distinct series.
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:telemetry, [:dp_exchange, :link, :down], %{count: 1}, metadata}
      assert is_binary(metadata.reason)
      assert metadata.reason =~ "closed"
    end

    test "every frame is a link event, counted with its wire size" do
      payload = Jason.encode!(%{"e" => "bookTicker"})
      assert {:ok, _state} = Socket.handle_frame({:text, payload}, state())

      assert_receive {:telemetry, [:dp_exchange, :link, :event], measurements, metadata}
      assert measurements.bytes == byte_size(payload)
      assert measurements.count == 1
      assert metadata.type == :frame
    end

    test "a frame that does NOT parse is still counted — the venue still sent it" do
      # Counting only what parsed would make a decoder bug here look like a silent venue.
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
      assert_receive {:telemetry, [:dp_exchange, :link, :event], %{bytes: 9}, _metadata}
    end
  end

  describe "reconnect backoff — the storm websockex has no delay of its own against" do
    test "attempt 1 waits nothing: a healthy session that dropped reconnects at once" do
      assert Socket.reconnect_delay_ms(1) == 0
    end

    test "each consecutive failure doubles, capped at 30 seconds" do
      # `on_disconnect/5` in the transport calls `open_connection/3` and, on failure, calls
      # ITSELF with `attempt + 1` — nothing between the turns. Without this the socket
      # retries at full connect speed forever against whatever is refusing it, and the
      # causes are the ones that do not fix themselves by being retried sooner: a credential
      # the venue stopped honouring, an IP it started refusing, a maintenance window.
      assert Socket.reconnect_delay_ms(2) == 1_000
      assert Socket.reconnect_delay_ms(3) == 2_000
      assert Socket.reconnect_delay_ms(4) == 4_000
      assert Socket.reconnect_delay_ms(5) == 8_000
      assert Socket.reconnect_delay_ms(6) == 16_000
      assert Socket.reconnect_delay_ms(7) == 30_000
      assert Socket.reconnect_delay_ms(50) == 30_000
    end

    test "the cap holds against an attempt number large enough to overflow a naive shift" do
      # `:math.pow(2, attempt - 2)` on a long-lived storm produces a float far beyond any
      # integer anyone wants to multiply. `min/2` is applied to the result, so the only
      # thing that matters is that it stays pinned and stays an integer.
      delay = Socket.reconnect_delay_ms(2_000)

      assert delay == 30_000
      assert is_integer(delay)
    end

    test "handle_disconnect/2 reconnects immediately when the transport reports attempt 1" do
      # The healthy-blip path, and the one every other test in this file exercises by
      # calling the callback with a bare `%{reason: ...}`. Timed rather than assumed: a
      # regression that slept here would stall a socket on every ordinary drop.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, state())

      # Against the smallest possible BACKOFF (1s at attempt 2), not an arbitrary budget.
      # This asserted `< 500`, which is stricter than the claim needs — the claim is "no
      # backoff was applied", and any wait under a second proves that. Under a loaded
      # full-suite run the 500ms version failed while the behaviour was correct, which is the
      # same timing-assertion-holds-when-quiet shape as the rate-limiter bucket race and
      # `Core.PollingFeed`'s poll-interval waits.
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "handle_disconnect/2 actually waits once reconnects are failing" do
      # Attempt 3 is `@base_reconnect_delay_ms * 2` = 2000ms. Asserting the elapsed time
      # rather than only the pure function is what proves the delay is WIRED IN — the
      # function existed in `dp_exchange_schwab` all along, and the bug in the other three
      # packages was never that the arithmetic was wrong, it was that nothing called it.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 3}, state())

      # Jittered downward by up to a quarter (`Socket.jittered_delay_ms/1`): 1500..2000.
      assert System.monotonic_time(:millisecond) - started >= 1_500
    end

    test "jittered_delay_ms/1 only ever shortens, by at most a quarter, and varies" do
      # The reconnect ladder was a pure function of the attempt number, so every socket
      # dropped together by one venue restart retried on identical schedules: a connect burst
      # on every rung.
      draws = for _draw <- 1..200, do: Socket.jittered_delay_ms(30_000)

      assert Enum.all?(draws, &(&1 >= 22_500 and &1 < 30_000))
      assert length(Enum.uniq(draws)) > 1
    end

    test "jittered_delay_ms/1 leaves an immediate reconnect immediate" do
      assert Socket.jittered_delay_ms(0) == 0
    end

    test "handle_disconnect/2 reports a jittered delay, not the ladder's rung" do
      # Attempt 2 is the 1_000ms rung. Without the jitter the telemetry event reports exactly
      # 1_000 every time; with it the value is strictly below the rung and within a quarter.
      test_pid = self()
      handler_id = "reconnect-jitter-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :link, :reconnect_attempt],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == :gemini and self() == test_pid,
            do: send(test_pid, {:reconnect_attempt, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 2}, state())

      assert_receive {:reconnect_attempt, %{attempt: 2, delay_ms: delay_ms}}, 5_000
      assert delay_ms >= 750
      assert delay_ms < 1_000
    end
  end

  describe "a send to a socket that is gone" do
    test "answers with the reason alone, never the frame" do
      # `send_frame/3`'s exit carries the frame; it must not reach a log or the caller.
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)

      # ExUnit's default `assert_receive` window is 100ms. This process is trivial and its
      # `:DOWN` normally lands in well under that, but this file is `async: true` alongside
      # up to 20 other cases — the same "the default window holds when quiet, not when the
      # scheduler is loaded" shape `handle_disconnect/2 reconnects immediately`'s own comment
      # above records, and observed the same way: one failure in a full, loaded run. Widening
      # the window costs nothing when the message is already there; a `sleep` would not,
      # since the whole point is not knowing in advance how long a loaded scheduler needs.
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:send_exit, :noproc}} = Socket.subscribe(dead, ["BTC-USD"])
        end)

      # `capture_log/1` collects every process's log for the window, so with other async
      # cases running it can hold an unrelated `HTTP Request: GET .../btcusd` line (CI,
      # 2026-10-11). Only this module's own entries are judged, whole: split on each
      # entry's leading timestamp, so a frame inspected across several lines stays inside
      # the entry that logged it.
      own_lines =
        log
        |> String.split(~r/\n(?=\d{2}:\d{2}:\d{2}\.\d{3} \[)/)
        |> Enum.filter(&String.contains?(&1, "[Gemini Socket]"))

      assert Enum.any?(own_lines, &String.contains?(&1, "send exited"))
      refute Enum.any?(own_lines, &String.contains?(&1, "btcusd"))
    end
  end

  describe "fail-closed edges found in review (2026-10-10)" do
    defp depth_frame(overrides) do
      Map.merge(
        %{
          "e" => "depthUpdate",
          "E" => 1_787_936_147_810_330_084,
          "s" => "btcusd",
          "U" => 11,
          "u" => 12,
          "b" => [["77845.79", "0.5"]],
          "a" => []
        },
        overrides
      )
    end

    test "a depth frame ending at or before what was applied is a replay and is dropped" do
      applied = Map.put(state(), :last_depth_update, %{"BTC-USD" => 12})

      assert {:ok, after_replay} =
               Socket.handle_frame({:text, Jason.encode!(depth_frame(%{"U" => 9}))}, applied)

      refute_received {:dp_exchange, :gemini, _payload}
      assert after_replay.last_depth_update == %{"BTC-USD" => 12}
    end

    test "a delta row this package cannot read makes the frame unreadable, not a dropped row" do
      frame = depth_frame(%{"b" => [["77845.79", "not-a-size"]]})

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())

      refute_received {:dp_exchange, :gemini, %DpExchange.Core.Types.OrderBookDelta{}}

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :data_quality,
                         details: %{reason: :undecodable_depth_update}
                       }}
    end

    test "a depth frame missing its U is never read as a bookTicker" do
      frame = depth_frame(%{}) |> Map.delete("U")

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())
      refute_received {:dp_exchange, :gemini, %TopOfBook{}}

      # ...and it is not dropped in silence either: the book is missing this diff.
      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :data_quality,
                         details: %{reason: :undecodable_depth_update}
                       }}
    end

    test "a bookTicker level that is present and unreadable is not published as nil" do
      assert {:ok, _state} = deliver(%{@book_ticker | "b" => "garbage"})

      refute_received {:dp_exchange, :gemini, %TopOfBook{}}

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :data_quality,
                         details: %{reason: :unreadable_book_ticker_level}
                       }}
    end

    test "a subscribe whose frame never went out withdraws its ack expectation" do
      {:ok, armed} = Socket.handle_info({:awaiting_ack, 7}, state())
      assert {:ok, withdrawn} = Socket.handle_info({:ack_withdrawn, 7}, armed)

      assert withdrawn.unanswered_subscribes == 0
      assert withdrawn.ack_deadline == nil
    end

    test "an answer to an id nobody is waiting on (an unsubscribe's) is not a subscribe's" do
      {:ok, armed} = Socket.handle_info({:awaiting_ack, 7}, state())

      {:ok, after_unsubscribe_ack} =
        Socket.handle_frame({:text, Jason.encode!(%{"id" => 8, "status" => 200})}, armed)

      assert after_unsubscribe_ack.unanswered_subscribes == 1
      assert after_unsubscribe_ack.ack_deadline == armed.ack_deadline
    end

    test "a session that drops right after connecting backs off instead of reconnecting at once" do
      just_connected = Map.put(state(), :connected_at, System.monotonic_time(:millisecond))

      {elapsed_us, {:reconnect, after_drop}} =
        :timer.tc(fn -> Socket.handle_disconnect(%{reason: :closed}, just_connected) end)

      # The 1_000ms rung, jittered down by up to a quarter.
      assert elapsed_us >= 750_000
      assert after_drop.short_sessions == 1
    end
  end
end
