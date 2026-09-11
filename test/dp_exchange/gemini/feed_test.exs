defmodule DpExchange.Gemini.FeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Gemini.Feed

  @moduletag :capture_log

  # A stand-in socket. Not a mock: it is a real process speaking the same `:gen.call`
  # protocol `WebSockex.send_frame/2` uses, so the feed cannot tell the difference — and
  # because it answers, the socket-bearing branches run at full speed without reaching a
  # venue. It forwards each frame to the test, which is how the wire format gets asserted.
  defp fake_socket(report_to) do
    spawn_link(fn -> accept_frames(report_to) end)
  end

  defp accept_frames(report_to) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        send(report_to, {:frame_sent, Jason.decode!(frame)})
        :gen.reply(from, :ok)
        accept_frames(report_to)
    end
  end

  defp start_feed(opts \\ []) do
    name = :"feed_#{System.unique_integer([:positive])}"
    {:ok, pid} = Feed.start_link(Keyword.merge([name: name, socket: fake_socket(self())], opts))
    pid
  end

  # A stand-in socket whose `Socket.subscribe/2` result is controlled from the test —
  # `fake_socket/1` above always answers `:ok`, which cannot exercise the resubscribe
  # failure-latch path. Every send is still forwarded to `report_to` as `{:frame_sent,
  # _}`, matching `fake_socket/1`'s contract, so a test can synchronize on the wire
  # traffic exactly as the existing tests do.
  #
  # Never recovers — every send answers `{:error, :send_timeout}`. Used to prove the
  # failure notice latches: it must fire once on the first failing resubscribe and never
  # again while the failure continues.
  defp always_fails_socket(report_to) do
    spawn_link(fn -> always_fails_frames(report_to) end)
  end

  defp always_fails_frames(report_to) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        send(report_to, {:frame_sent, Jason.decode!(frame)})
        :gen.reply(from, {:error, :send_timeout})
        always_fails_frames(report_to)
    end
  end

  # Fails the first `fail_times` sends with `{:error, :send_timeout}`, then answers `:ok`
  # forever after — used to drive the latch from `:ok` to `:dead` and back to `:ok` inside
  # one test, proving the recovery notice fires on the transition back out.
  defp flaky_socket(report_to, fail_times) do
    spawn_link(fn -> flaky_frames(report_to, fail_times) end)
  end

  defp flaky_frames(report_to, remaining) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        send(report_to, {:frame_sent, Jason.decode!(frame)})

        if remaining > 0 do
          :gen.reply(from, {:error, :send_timeout})
          flaky_frames(report_to, remaining - 1)
        else
          :gen.reply(from, :ok)
          flaky_frames(report_to, 0)
        end
    end
  end

  defp quote_for(symbol) do
    %Quote{
      symbol: symbol,
      price: Decimal.new("77845.79"),
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :gemini
    }
  end

  defp top_of_book_for(symbol) do
    %TopOfBook{
      symbol: symbol,
      bid: Decimal.new("77800.00"),
      ask: Decimal.new("77900.00"),
      bid_size: Decimal.new("0.5"),
      ask_size: Decimal.new("0.4"),
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :gemini
    }
  end

  describe "back-pressure — a slow subscriber does not get an unbounded mailbox" do
    # `Core.Venue`'s `subscribe/2` doc promised this from the day the contract was written
    # and no venue in this family implemented any of it: every one fanned out with a bare
    # `send/2` and had never looked at a subscriber's mailbox. A consumer that stalls against
    # a live book stream accumulated a mailbox until the node died, with no notice, no log
    # line, and `coverage/1` reporting perfect health the whole time — because the feed
    # genuinely was delivering.

    # A subscriber that never consumes, so everything sent to it stays queued. That is what
    # a stalled consumer looks like from the sender's side, and the only way to build a real
    # backlog without guessing at timing.
    defp stalled_subscriber do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp queue_len(pid) do
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      len
    end

    test "past its bound, a subscriber stops being sent to and its mailbox stops growing" do
      slow = stalled_subscriber()
      feed = start_feed(max_queue_len: 3)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)

      for _each <- 1..10 do
        send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      end

      # Synchronise: a call is answered only after every send above has been handled.
      _settled = Feed.coverage(feed)

      # Three got through, then the bound stopped it. Not ten, and — the point — not
      # unbounded.
      assert queue_len(slow) == 3
    end

    test "a stalled subscriber is reported once, and again when it catches up" do
      slow = stalled_subscriber()
      feed = start_feed(max_queue_len: 1)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert_receive {:dp_exchange, :gemini,
                      %Notice{kind: :degraded, severity: :warning, details: details}}

      assert details.bound == 1
      assert details.dropping == :newest
      assert details.subscriber == inspect(slow)

      # Not once per dropped message: that would arrive at the rate of the stream the
      # consumer already cannot keep up with, into the same fan-out that is overloaded.
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)
      refute_receive {:dp_exchange, :gemini, %Notice{kind: :degraded}}, 100
    end

    test "one stalled subscriber does not cost a healthy one its data" do
      # The property that makes dropping acceptable at all. A fan-out that stalled or
      # dropped for everyone because one consumer fell behind would turn one misbehaving
      # consumer into an outage for every other.
      #
      # The healthy subscriber is a forwarder rather than the test process itself: this test
      # process is also `fake_socket/1`'s report target and never drains, so subscribing it
      # would make it a second stalled consumer and prove the opposite of what is meant.
      # That is not a quirk of the test — it is what a real slow consumer looks like, and it
      # is why the first draft of this test failed.
      slow = stalled_subscriber()
      healthy = forwarding_subscriber(self())
      feed = start_feed(max_queue_len: 2)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: healthy)

      for _each <- 1..6 do
        send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      end

      _settled = Feed.coverage(feed)

      assert queue_len(slow) == 2
      for _each <- 1..6, do: assert_receive({:forwarded, {:dp_exchange, :gemini, %Quote{}}}, 500)
    end

    # Consumes immediately and hands everything to `to`, so its own mailbox stays empty and
    # it never trips the bound — a consumer keeping up, which is the case a stalled one has
    # to be told apart from.
    defp forwarding_subscriber(to) do
      pid = spawn(fn -> forward_loop(to) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp forward_loop(to) do
      receive do
        message ->
          send(to, {:forwarded, message})
          forward_loop(to)
      end
    end

    test "a symbol whose frames are dropped for a slow consumer is still covered" do
      # `coverage/1` reports what the VENUE delivered to this package, not what this package
      # forwarded. Reporting `:not_covered` here would blame the venue for a consumer's own
      # backlog — and send an operator looking at the wrong system entirely.
      slow = stalled_subscriber()
      feed = start_feed(max_queue_len: 1)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)

      for _each <- 1..5 do
        send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      end

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "an invalid bound fails at init, loudly, rather than falling back to the default" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: :"bad_bound_#{System.unique_integer([:positive])}",
                 socket: fake_socket(self()),
                 max_queue_len: "3"
               )

      assert message =~ ":gemini"
      assert message =~ ":max_queue_len"
    end
  end

  describe "coverage is observed, never intended" do
    test "a subscribed symbol that has delivered nothing is absent" do
      # The strongest guarantee in the contract. A venue once reported 325 symbols
      # subscribed and confirmed while 174 were delivering.
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert Feed.coverage(feed) == %{}
    end

    test "a symbol appears only once a payload for it arrives" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      # A call after the send forces the cast to be processed first.
      _settled = Feed.coverage(feed)

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "unsubscribing drops the symbol from coverage" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.unsubscribe(feed, ["BTC-USD"])

      assert Feed.coverage(feed) == %{}
    end

    test "a link drop clears what the dead connection had been delivering" do
      # `Socket.handle_disconnect/2` returns `{:reconnect, state}`, so a transport drop
      # leaves the socket PROCESS alive and no `EXIT` reaches `isolate_crashed_socket/2`.
      # Before this, the delivery records from the connection that just died kept answering
      # `:stream` — and a reconnect that restored the socket while silently failing to
      # restore a symbol left that symbol answering `:stream` forever, which is the exact
      # incident `coverage/1` exists to make visible. See `Core.Venue`'s `coverage/1` doc.
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}

      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})
      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}}

      # `wanted` is untouched: the host still asked for it, and the next frame after the
      # resubscribe puts it straight back. Only the evidence was scoped to the dead link.
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end
  end

  describe "coverage_by_kind/1" do
    test "with nothing delivered, both declared kinds are present and empty" do
      # Both kind keys always appear, even with no data yet — an absent key would read
      # as "this module does not know about that kind", where an empty map honestly
      # reads as "nothing of that kind has arrived".
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}}
    end

    test "a symbol delivering only a top-of-book update appears under :top_of_book and " <>
           "not under :quotes" do
      # This is the isolation this venue's own mechanics actually produce: a `bookTicker`
      # frame always yields a `TopOfBook` when it parses, and yields an accompanying
      # `Quote` only when that same frame also carries a last-traded price
      # (`DpExchange.Gemini.Socket`). A symbol that quotes continuously without ever
      # trading is real and exercises exactly this shape — top-of-book healthy, quotes
      # dark — which `coverage/1` alone cannot tell apart from "everything healthy".
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, top_of_book_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      by_kind = Feed.coverage_by_kind(feed)
      assert by_kind == %{quotes: %{}, top_of_book: %{"BTC-USD" => :stream}}
    end

    test "a symbol delivering both kinds appears under both" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, top_of_book_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert Feed.coverage_by_kind(feed) == %{
               quotes: %{"BTC-USD" => :stream},
               top_of_book: %{"BTC-USD" => :stream}
             }
    end

    test "the union of every kind's symbols matches coverage/1 exactly" do
      # The invariant `DpExchange.Core.Venue.coverage_by_kind/1` documents and Core's
      # conformance suite (assertion 15) checks whenever a venue exports this callback.
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD", "SOL-USD"], to: self())

      # BTC-USD quotes and books; ETH-USD books only; SOL-USD quotes only (unreachable
      # through the real Socket, but Feed tracks by struct type regardless of how the
      # message arrived, and the invariant must hold either way).
      send(feed, {:dp_exchange, :gemini, top_of_book_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, top_of_book_for("ETH-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("SOL-USD")})
      _settled = Feed.coverage(feed)

      union =
        feed
        |> Feed.coverage_by_kind()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert union == feed |> Feed.coverage() |> Map.keys() |> Enum.sort()
    end

    test "unsubscribing drops the symbol from every kind's bucket" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      send(feed, {:dp_exchange, :gemini, top_of_book_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.unsubscribe(feed, ["BTC-USD"])

      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}}
    end

    test "update_symbols/2 narrows every kind's bucket to the new set" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      send(feed, {:dp_exchange, :gemini, top_of_book_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, top_of_book_for("ETH-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.update_symbols(feed, ["BTC-USD"])

      assert Feed.coverage_by_kind(feed) == %{
               quotes: %{},
               top_of_book: %{"BTC-USD" => :stream}
             }
    end
  end

  describe "fan-out" do
    test "a quote reaches the subscriber" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})

      # A generous explicit timeout, not ExUnit's 100ms default — same reasoning as the
      # resubscribe-latch test below: test -> Feed -> `fan_out/2` -> back to test is a
      # real hop under this suite's own concurrency.
      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}, 1_000
    end

    test "notices go to notice subscribers, not quote subscribers" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})

      # A generous explicit timeout, not ExUnit's 100ms default — same reasoning as the
      # resubscribe-latch test below: test -> Feed -> `fan_out/2` -> back to test is a
      # real hop under this suite's own concurrency, and a tight default here is an
      # intermittent, load-dependent failure rather than a real one. Found the same way:
      # by running the full suite, not this test alone.
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 1_000
    end

    test "a dead subscriber does not stop delivery to a live one" do
      # The venue must not accumulate events for a process that no longer exists.
      feed = start_feed()
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: dead)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})

      # See the timeout note on "a quote reaches the subscriber", above.
      assert_receive {:dp_exchange, :gemini, %Quote{}}, 1_000
    end

    test "a subscriber registered by name (not a raw pid) is delivered to rather than crashing the feed" do
      # Filed as a live bug on the sibling Coinbase package: Process.alive?/1 only
      # accepts a pid and raises on anything else, so a consumer that registers itself
      # under a name and hands that name to `to:` — ordinary OTP practice — crashed the
      # whole feed on the very first delivery.
      name = :"gemini_feed_test_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: name)
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})

      # See the timeout note on "a quote reaches the subscriber", above.
      assert_receive {:dp_exchange, :gemini, %Quote{}}, 1_000
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash" do
      name = :"gemini_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: name)
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})

      # A synchronous call from this same process, not a sleep: Erlang orders messages
      # from one sender to one receiver, so this round trip only returns once the feed
      # has processed the `send/2` above — proving it did not crash rather than hoping
      # 20ms was enough.
      Feed.coverage(feed)

      assert Process.alive?(feed)
    end
  end

  describe "update_symbols/2" do
    test "narrows coverage to the new set" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("ETH-USD")})
      _settled = Feed.coverage(feed)

      :ok = Feed.update_symbols(feed, ["BTC-USD"])

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "is a no-op when no socket has been dialled" do
      {:ok, feed} = Feed.start_link(name: :"feed_#{System.unique_integer([:positive])}")

      assert Feed.update_symbols(feed, ["BTC-USD"]) == :ok
    end
  end

  describe "the frames that actually go on the wire" do
    test "subscribe names the bookTicker stream in the venue's own lowercase form" do
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD", "AAVE-GUSD"], to: self())

      assert_receive {:frame_sent, frame}
      assert frame["method"] == "subscribe"
      assert frame["params"] == ["btcusd@bookTicker", "aavegusd@bookTicker"]
    end

    test "unsubscribe uses the same stream names" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, _subscribe}

      :ok = Feed.unsubscribe(feed, ["BTC-USD"])

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}}
    end

    test "an empty symbol list sends nothing at all" do
      feed = start_feed()

      :ok = Feed.subscribe(feed, [], to: self())

      refute_receive {:frame_sent, _frame}, 50
    end
  end

  describe "the periodic resubscribe — a reconnect with no memory must not mean silence" do
    # `Socket` holds no record of what it was told to carry (`%{subscriber:, request_id:}`),
    # and WebSockex reconnects on its own without this package's involvement. Before this
    # fix, `handle_connect/2` emitted `:link_up` and nothing else — a reconnected socket
    # looked healthy and delivered nothing until a consumer noticed a quiet chart. `Feed`
    # now re-issues its `wanted` set on a timer, unconditionally, which is what actually
    # recovers coverage after a reconnect this process never even learns happened.
    #
    # `:resubscribe` is sent directly here rather than waiting out the real
    # `@resubscribe_interval_ms` — the handler doesn't care who sent the message, only that
    # it arrived, so this exercises the exact code path the timer drives without a 60-second
    # test.
    test "resends the current subscription on the wire, unprompted by any reconnect signal" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, frame}
      assert frame["method"] == "subscribe"
      assert Enum.sort(frame["params"]) == ["btcusd@bookTicker", "ethusd@bookTicker"]
    end

    test "drops what was unsubscribed rather than re-asking for it" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      :ok = Feed.unsubscribe(feed, ["ETH-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, frame}
      assert frame["params"] == ["btcusd@bookTicker"]
    end

    test "sends nothing when nothing is wanted" do
      feed = start_feed()

      send(feed, :resubscribe)

      refute_receive {:frame_sent, _frame}, 50
      assert Process.alive?(feed)
    end

    test "sends nothing when no socket has ever been dialled" do
      {:ok, feed} = Feed.start_link(name: :"feed_#{System.unique_integer([:positive])}")

      send(feed, :resubscribe)

      # No socket, nothing to crash and nothing to send to. A synchronous call from this
      # same process — not a sleep — only returns once the feed has processed the
      # `:resubscribe` message above, since Erlang orders messages from one sender to one
      # receiver.
      Feed.coverage(feed)
      assert Process.alive?(feed)
    end
  end

  describe "the periodic resubscribe's own failure path was silent — until now" do
    # Before this fix, a resubscribe that kept failing every cycle only ever reached a
    # `Logger.warning` — `grep -n "Notice.new(" lib/dp_exchange/gemini/feed.ex` matched
    # nothing in this file. `resubscribe_notice_state` now latches to `:dead` on the first
    # failure and back to `:ok` on the first success after one, matching
    # `Core.PollingFeed`'s `notice_state` shape, so a consumer hears about the outage once
    # rather than once a minute for as long as it lasts.

    test "a failing resubscribe emits a warning coverage_change notice, once, not on every tick" do
      socket = always_fails_socket(self())
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())

      # The initial subscribe also fails against this socket — irrelevant here, since the
      # resubscribe latch is only ever touched by the periodic path, not by `subscribe/3`.
      Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)

      # A generous explicit timeout, not ExUnit's 100ms default: this notice is the last
      # hop of test -> Feed -> the stand-in socket's blocking `:gen.call` -> back to Feed
      # -> `fan_out/2`, and under this suite's own concurrency (734 tests, `async: true`)
      # that chain can occasionally take longer than 100ms without anything being wrong.
      # A tight default here was an intermittent, load-dependent CI failure waiting to
      # happen — found by running the full suite repeatedly, not any one test alone.
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change} = notice}, 1_000
      assert notice.severity == :warning
      assert notice.details.reason =~ "send_timeout"

      # Two more failing cycles with the same socket must not re-emit — the notice fires
      # once on the transition INTO failure, never once per tick while it continues.
      send(feed, :resubscribe)
      send(feed, :resubscribe)
      refute_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}, 100
    end

    test "a resubscribe that recovers after a latched failure emits an info notice, once" do
      # Fails the initial subscribe and the first resubscribe, then succeeds forever
      # after — the shape a real busy-then-recovered socket takes.
      socket = flaky_socket(self(), 2)
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())

      Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)

      # See the timeout note in the previous test — the same multi-hop chain to a
      # `Notice` applies here.
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change, severity: :warning}},
                     1_000

      send(feed, :resubscribe)

      assert_receive {:dp_exchange, :gemini,
                      %Notice{kind: :coverage_change, severity: :info} = notice},
                     1_000

      assert notice.message =~ "resumed"

      # A further successful resubscribe must not re-emit the recovery notice — it
      # already fired on the transition back out, and the latch reads `:ok` again.
      send(feed, :resubscribe)
      refute_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}, 100
    end

    test "an ordinary successful resubscribe, never having failed, emits no notice at all" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      refute_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}, 100
    end

    test "a resubscribe with nothing wanted touches neither the wire nor the failure latch" do
      socket = always_fails_socket(self())
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, :resubscribe)

      refute_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}, 100
    end
  end

  describe "unknown messages" do
    test "an unexpected call is refused rather than crashing the feed" do
      feed = start_feed()

      assert GenServer.call(feed, :nonsense) == {:error, :unknown_call}
      assert Process.alive?(feed)
    end

    test "an unexpected info is ignored" do
      feed = start_feed()

      send(feed, :something_else)

      assert Feed.coverage(feed) == %{}
      assert Process.alive?(feed)
    end
  end

  describe "a crashed socket is isolated, not fatal" do
    # `fake_socket/1` is `spawn_link`ed by the TEST process, then injected via `socket:`
    # — it is not linked to `feed`, so it cannot prove what a REAL socket crash does
    # (`ensure_socket/1` links a socket to `Feed` because `Socket.start_link/1` runs
    # inside a `Feed` callback). `:sys.replace_state/2` runs the given function INSIDE
    # the target process — the same mechanism `:sys.get_state/1` uses — so `Process.
    # link/1` inside it creates a link owned by `feed`, matching what `ensure_socket/1`
    # does in production, from a place this test controls.
    defp link_socket_into_feed(feed, socket) do
      :sys.replace_state(feed, fn state ->
        Process.link(socket)
        state
      end)
    end

    test "the feed survives a linked socket being killed" do
      feed = start_feed()
      socket = :sys.get_state(feed).socket
      # `fake_socket/1` is `spawn_link`ed by THIS test process too — unlinked here so
      # the `:kill` below only tests what happens to `feed` (the link this test just
      # created), not the test process itself.
      Process.unlink(socket)
      link_socket_into_feed(feed, socket)

      # `:kill`, not `:normal` — a non-trapping process ignores a peer's normal exit,
      # which would prove nothing about the trap_exit flag this test exists to check.
      ref = Process.monitor(feed)
      Process.exit(socket, :kill)
      refute_receive {:DOWN, ^ref, :process, ^feed, _reason}, 500
      assert Process.alive?(feed)
    end

    test "coverage clears, a :link_down notice fires, and it retries the reconnect immediately" do
      # `url:` points the REPLACEMENT dial (after the crash, `ensure_socket/1` calls the
      # real `Socket.start_link/1` — `fake_socket/1` only ever stands in for the FIRST
      # socket, injected directly) at a local address that refuses fast, so the retry
      # this test is proving actually happens is observable without reaching a venue or
      # standing up a real local socket server.
      feed = start_feed(url: "ws://127.0.0.1:1/nowhere")
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}

      :ok = Feed.subscribe_notices(feed, to: self())
      socket = :sys.get_state(feed).socket
      Process.unlink(socket)
      link_socket_into_feed(feed, socket)

      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 500
      assert Process.alive?(feed)

      # Cleared immediately — not "eventually, once something else overwrites it" — the
      # coverage-truthfulness question the audit asked directly: does `coverage/1` still
      # say `:stream` right after the one socket carrying "BTC-USD" crashed? It must not.
      assert Feed.coverage(feed) == %{}

      # `isolate_crashed_socket/2` calls `resubscribe/1` immediately, not on the next 60s
      # `@resubscribe_interval_ms` tick — the reconnect it attempts fails fast against
      # the unreachable URL above, which is itself the proof an attempt was made right
      # away: `resubscribe_failed/2` only ever fires from an actual `ensure_socket/1` or
      # `Socket.subscribe/2` result, never from doing nothing.
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change, severity: :warning}},
                     2_000
    end
  end
end
