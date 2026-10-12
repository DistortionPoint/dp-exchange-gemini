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

  # Makes `symbols` wanted without a `subscribe/3`, for tests of the periodic path against a
  # socket on which `subscribe/3` itself would fail and (rightly) record nothing.
  defp want(feed, symbols) do
    :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(symbols)})
  end

  # Answers a subscribe `:ok` and an unsubscribe `{:error, :send_timeout}`, forwarding every
  # frame as `{:frame_sent, _}`.
  defp unsubscribe_fails_socket(report_to) do
    spawn_link(fn -> unsubscribe_fails_frames(report_to) end)
  end

  defp unsubscribe_fails_frames(report_to) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        decoded = Jason.decode!(frame)
        send(report_to, {:frame_sent, decoded})

        reply = if decoded["method"] == "unsubscribe", do: {:error, :send_timeout}, else: :ok
        :gen.reply(from, reply)
        unsubscribe_fails_frames(report_to)
    end
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
      # No window needed: the feed sends any notice before it answers the call above, and
      # signals from one sender arrive in order, so a notice would already be in the mailbox.
      refute_received {:dp_exchange, :gemini, %Notice{kind: :degraded}}
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

      for _each <- 1..6 do
        assert_receive {:forwarded, {:dp_exchange, :gemini, %Quote{}}}, 5_000
      end
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

  describe "a dead subscriber is dropped, not walked forever" do
    # `Core.Fanout.resolve/1` already skipped a dead subscriber at send time, so no EVENTS
    # accumulated for one — but nothing removed the pid, so a supervised consumer that
    # restarts left one behind on every restart, for the life of this feed. `deliver/4` walks
    # the whole set calling `Process.alive?/1` once per message, so the cost was linear in
    # uptime: 0.095 us per fan-out against a clean set, 22.8 us against one carrying a
    # thousand dead pids.
    test "a subscriber that dies is removed from the subscriber set" do
      feed = start_feed()
      subscriber = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)
      assert MapSet.member?(:sys.get_state(feed).subscribers, subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}, 5_000

      # A call is answered only after the feed's own `:DOWN` has been handled.
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.subscribers, subscriber)
      refute Map.has_key?(state.monitors, subscriber)
    end

    test "a notice subscriber that dies is removed too" do
      feed = start_feed()
      watcher = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe_notices(feed, to: watcher)
      assert MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)

      ref = Process.monitor(watcher)
      Process.exit(watcher, :kill)
      assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}, 5_000
      _settled = Feed.coverage(feed)

      refute MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)
    end

    test "a REGISTERED NAME is never monitored, and survives its holder dying" do
      # The half that must not be pruned. A name is not a process: `subscribe/2` accepts one
      # precisely so a consumer can restart under it, and pruning when the current holder
      # dies would silently unsubscribe a consumer whose supervisor is about to bring it
      # straight back — data loss with nothing to notice it by. A name cannot leak anyway:
      # the set holds one atom however many restarts happen.
      feed = start_feed()
      name = :"named_subscriber_#{System.unique_integer([:positive])}"
      holder = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(holder, name)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: name)
      assert :sys.get_state(feed).monitors == %{}

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 5_000
      _settled = Feed.coverage(feed)

      # Still subscribed under the name, ready for whatever registers next.
      assert MapSet.member?(:sys.get_state(feed).subscribers, name)
    end

    test "subscribing twice from one pid monitors it once" do
      # Each monitor delivers its own `:DOWN`, so stacking them means N-1 messages nothing
      # will match.
      feed = start_feed()
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(subscriber, :kill) end)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)
      first = :sys.get_state(feed).monitors

      :ok = Feed.subscribe(feed, ["ETH-USD"], to: subscriber)
      :ok = Feed.subscribe_notices(feed, to: subscriber)

      assert :sys.get_state(feed).monitors == first
      assert map_size(first) == 1
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
      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}, trades: %{}}

      # `wanted` is untouched: the host still asked for it, and the next frame after the
      # resubscribe puts it straight back. Only the evidence was scoped to the dead link.
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end
  end

  describe "coverage_by_kind/1" do
    test "with nothing delivered, every declared kind is present and empty" do
      # Every kind key always appears, even with no data yet — an absent key would read
      # as "this module does not know about that kind", where an empty map honestly
      # reads as "nothing of that kind has arrived". `:trades` appears here too even
      # though this feed was started without `:trades` in `:channels` — see the
      # moduledoc's "empty_delivery/0" comment: the keys match
      # `capabilities().streamable`, not what this instance happens to be configured for.
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}, trades: %{}}
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
      assert by_kind == %{quotes: %{}, top_of_book: %{"BTC-USD" => :stream}, trades: %{}}
    end

    test "a symbol delivering both kinds appears under both" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, top_of_book_for("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert Feed.coverage_by_kind(feed) == %{
               quotes: %{"BTC-USD" => :stream},
               top_of_book: %{"BTC-USD" => :stream},
               trades: %{}
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

      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}, trades: %{}}
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
               top_of_book: %{"BTC-USD" => :stream},
               trades: %{}
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
      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}, 5_000
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
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 5_000
    end

    test "a dead subscriber does not stop delivery to a live one" do
      # The venue must not accumulate events for a process that no longer exists.
      feed = start_feed()
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: dead)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})

      # See the timeout note on "a quote reaches the subscriber", above.
      assert_receive {:dp_exchange, :gemini, %Quote{}}, 5_000
    end

    test "a subscriber registered by name (not a pid) is delivered to, not a feed crash" do
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
      assert_receive {:dp_exchange, :gemini, %Quote{}}, 5_000
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

      # `subscribe/3` is a call: any frame it sent was reported by the stand-in socket before
      # the call returned, so it is already in the mailbox if it exists.
      refute_received {:frame_sent, _frame}
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
    test "nothing is sent to a socket whose link is down, and nothing is lost by it" do
      # A reconnecting socket answers no `send_frame/2`, so each send blocked the feed for
      # 5s — see the moduledoc's "A socket that is reconnecting is not sent to".
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})
      send(feed, :resubscribe)
      assert :ok = Feed.subscribe(feed, ["ETH-USD"], to: self())

      # Settled, not waited for: the `:resubscribe` and the call above are handled in order.
      _settled = Feed.coverage(feed)
      refute_received {:frame_sent, _frame}

      socket = :sys.get_state(feed).socket
      send(feed, {:dp_exchange, :gemini, :reconnected, socket})

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => params}}, 5_000
      assert Enum.sort(params) == ["btcusd@bookTicker", "ethusd@bookTicker"]
    end

    test "resends the current subscription on the wire, unprompted by any reconnect signal" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, frame}, 5_000
      assert frame["method"] == "subscribe"
      assert Enum.sort(frame["params"]) == ["btcusd@bookTicker", "ethusd@bookTicker"]
    end

    test "a reconnect report resubscribes at once, without waiting for the timer" do
      # On the timer alone, a reconnected socket carried nothing for up to 60s — see the
      # moduledoc's "A reconnect resubscribes at once; the timer is the net".
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      socket = :sys.get_state(feed).socket
      send(feed, {:dp_exchange, :gemini, :reconnected, socket})

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["btcusd@bookTicker"]}},
                     5_000
    end

    test "a reconnect report from a socket this feed no longer holds is ignored" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, {:dp_exchange, :gemini, :reconnected, spawn(fn -> :ok end)})

      # The call queues behind the message above, so the feed has handled it (and sent
      # whatever it was going to send) before this reads the mailbox.
      _settled = Feed.coverage(feed)
      refute_received {:frame_sent, _frame}
      assert Process.alive?(feed)
    end

    test "drops what was unsubscribed rather than re-asking for it" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      :ok = Feed.unsubscribe(feed, ["ETH-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, frame}, 5_000
      assert frame["params"] == ["btcusd@bookTicker"]
    end

    test "sends nothing when nothing is wanted" do
      feed = start_feed()

      send(feed, :resubscribe)

      # The call queues behind the message above, so the feed has handled it (and sent
      # whatever it was going to send) before this reads the mailbox.
      _settled = Feed.coverage(feed)
      refute_received {:frame_sent, _frame}
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

    test "a failing resubscribe emits one warning coverage_change notice, not one per tick" do
      socket = always_fails_socket(self())
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())

      # A failed `subscribe/3` records nothing, so the wanted set the periodic path re-issues
      # is seeded directly. The resubscribe latch is only ever touched by the periodic path,
      # not by `subscribe/3`.
      want(feed, ["BTC-USD"])

      send(feed, :resubscribe)

      # A generous explicit timeout, not ExUnit's 100ms default: this notice is the last
      # hop of test -> Feed -> the stand-in socket's blocking `:gen.call` -> back to Feed
      # -> `fan_out/2`, and under this suite's own concurrency (734 tests, `async: true`)
      # that chain can occasionally take longer than 100ms without anything being wrong.
      # A tight default here was an intermittent, load-dependent CI failure waiting to
      # happen — found by running the full suite repeatedly, not any one test alone.
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change} = notice}, 5_000
      assert notice.severity == :warning
      assert notice.details.reason =~ "send_timeout"

      # Two more failing cycles with the same socket must not re-emit — the notice fires
      # once on the transition INTO failure, never once per tick while it continues.
      send(feed, :resubscribe)
      send(feed, :resubscribe)
      # A call queues behind both `:resubscribe` messages, so by the time it answers the feed
      # has processed them and any notice they would emit is already in this mailbox.
      _settled = Feed.coverage(feed)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}
    end

    test "a resubscribe that recovers after a latched failure emits an info notice, once" do
      # Fails the first resubscribe, then succeeds forever after — the shape a real
      # busy-then-recovered socket takes. The wanted set is seeded: a failed `subscribe/3`
      # records nothing.
      socket = flaky_socket(self(), 1)
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())

      want(feed, ["BTC-USD"])

      send(feed, :resubscribe)

      # See the timeout note in the previous test — the same multi-hop chain to a
      # `Notice` applies here.
      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change, severity: :warning}},
                     5_000

      send(feed, :resubscribe)

      assert_receive {:dp_exchange, :gemini,
                      %Notice{kind: :coverage_change, severity: :info} = notice},
                     5_000

      assert notice.message =~ "resumed"

      # A further successful resubscribe must not re-emit the recovery notice — it
      # already fired on the transition back out, and the latch reads `:ok` again.
      send(feed, :resubscribe)
      _settled = Feed.coverage(feed)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}
    end

    test "an ordinary successful resubscribe, never having failed, emits no notice at all" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, %{"method" => "subscribe"}}, 5_000
      _settled = Feed.coverage(feed)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}
    end

    test "a resubscribe with nothing wanted touches neither the wire nor the failure latch" do
      socket = always_fails_socket(self())
      feed = start_feed(socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, :resubscribe)

      _settled = Feed.coverage(feed)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}
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
      #
      # Not decided by a refute window: the feed reports the crash it handled as a
      # `:link_down` notice, so waiting for that proves the exit signal reached a feed that
      # was still there to trap it. A feed killed by the link could never send it.
      :ok = Feed.subscribe_notices(feed, to: self())
      ref = Process.monitor(feed)
      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 5_000
      refute_received {:DOWN, ^ref, :process, ^feed, _reason}
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

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 5_000
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
                     5_000
    end

    test "a crash hard on the heels of another waits before redialling" do
      # A socket that crashed on connect was redialled at once, crashed, and was redialled
      # again: a connect storm with no delay in it. The second crash of a run waits 1s.
      feed = start_feed(url: "ws://127.0.0.1:1/nowhere")
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      :ok = Feed.subscribe_notices(feed, to: self())

      socket = :sys.get_state(feed).socket
      Process.unlink(socket)
      link_socket_into_feed(feed, socket)

      # As if the previous socket had crashed a moment ago.
      :sys.replace_state(feed, fn state ->
        Map.put(state, :crash_run, {1, System.monotonic_time(:millisecond)})
      end)

      killed_at = System.monotonic_time(:millisecond)
      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 5_000

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change, severity: :warning}},
                     5_000

      # A LOWER bound on the wait, which load can only lengthen: the redial that produces this
      # notice is held back about a second (the previous crash was "a moment ago"). A refute
      # window here failed whenever the test process was slow to reach it.
      assert System.monotonic_time(:millisecond) - killed_at >= 900
    end

    test "the redial delay doubles through a run and is capped" do
      assert Feed.crash_redial_delay(1) == 0
      assert Feed.crash_redial_delay(2) == 1_000
      assert Feed.crash_redial_delay(3) == 2_000
      assert Feed.crash_redial_delay(50) == 30_000
    end
  end

  describe "subscribe_notices/2 survives a busy feed" do
    @describetag timeout: 60_000

    test "it waits @call_timeout, not GenServer.call/2's five-second default" do
      # `subscribe_notices` was the one public call in `Feed` left on the default timeout.
      # Every sibling call is given `@call_timeout` — 25 seconds, the authors' own statement
      # of how long this feed may legitimately take to answer — and this one had five.
      #
      # The blocker runs INSIDE the feed process: `:sys.replace_state/2` applies its function
      # there, so the sleep occupies the feed exactly as a slow callback would, and the call
      # under test queues behind it on the real mailbox. Eight seconds is chosen to sit
      # between the two timeouts: past the five-second default that used to fire, with three
      # seconds of margin for a loaded scheduler, and well short of the twenty-five the call
      # is now allowed.
      #
      # A `GenServer.call/3` timeout exits in the CALLER, so before the fix this test would
      # not have failed an assertion — it would have killed the test process with
      # `{:timeout, ...}`, which is the same thing that happened to a host registering for
      # notices while the feed was starting up.
      feed = start_feed()

      blocked = make_ref()
      test_pid = self()

      # `spawn`, not `spawn_link`, and `:sys.replace_state/3` rather than `/2`: the two-arity
      # form carries its own five-second timeout, which the six-second block deliberately
      # outlasts, and a linked blocker would then have killed the test with that exit before
      # the assertion below could run.
      spawn(fn ->
        :sys.replace_state(
          feed,
          fn state ->
            send(test_pid, blocked)
            Process.sleep(8_000)
            state
          end,
          30_000
        )
      end)

      assert_receive ^blocked, 5_000

      started = System.monotonic_time(:millisecond)
      assert :ok = Feed.subscribe_notices(feed, to: self())
      waited = System.monotonic_time(:millisecond) - started

      # Proves the call actually queued behind the block rather than being answered before
      # it started — without which this would pass on the unfixed code too.
      assert waited > 5_000
    end
  end

  describe "channels: — opting into the trade tape (dp-exchange-core issue #39)" do
    alias DpExchange.Core.Types.Trade

    defp trade_for(symbol) do
      %Trade{
        id: "123",
        symbol: symbol,
        side: :sell,
        price: Decimal.new("77845.79"),
        quantity: Decimal.new("0.01"),
        timestamp: ~U[2026-08-28 12:00:00Z],
        provider: :gemini
      }
    end

    test "the default carries no :trades — an existing consumer sees no change at all" do
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["btcusd@bookTicker"]}}
      # The call has returned, so a second frame would already be in the mailbox.
      refute_received {:frame_sent, _second_frame}
    end

    test "an explicit channels: [:quotes, :top_of_book] is identical to the default" do
      feed = start_feed(channels: [:quotes, :top_of_book])

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert_receive {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
      refute_received {:frame_sent, _second_frame}
    end

    test ":trades in channels: subscribes @trade alongside @bookTicker, for every wanted " <>
           "symbol" do
      feed = start_feed(channels: [:quotes, :top_of_book, :trades])

      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())

      assert_receive {:frame_sent,
                      %{
                        "method" => "subscribe",
                        "params" => ["btcusd@bookTicker", "ethusd@bookTicker"]
                      }}

      assert_receive {:frame_sent,
                      %{
                        "method" => "subscribe",
                        "params" => ["btcusd@trade", "ethusd@trade"]
                      }}
    end

    test "unsubscribe drops both channels when :trades is active" do
      feed = start_feed(channels: [:quotes, :top_of_book, :trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
      assert_receive {:frame_sent, %{"params" => ["btcusd@trade"]}}

      :ok = Feed.unsubscribe(feed, ["BTC-USD"])

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}}

      assert_receive {:frame_sent, %{"method" => "unsubscribe", "params" => ["btcusd@trade"]}}
    end

    test "update_symbols/2 adds and drops @trade the same way it does @bookTicker" do
      feed = start_feed(channels: [:quotes, :top_of_book, :trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
      assert_receive {:frame_sent, %{"params" => ["btcusd@trade"]}}

      :ok = Feed.update_symbols(feed, ["ETH-USD"])

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}}

      assert_receive {:frame_sent, %{"method" => "unsubscribe", "params" => ["btcusd@trade"]}}

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["ethusd@bookTicker"]}}

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["ethusd@trade"]}}
    end

    test "the periodic resubscribe re-issues @trade too, unprompted" do
      feed = start_feed(channels: [:quotes, :top_of_book, :trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
      assert_receive {:frame_sent, %{"params" => ["btcusd@trade"]}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["btcusd@bookTicker"]}},
                     5_000

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["btcusd@trade"]}},
                     5_000
    end

    test "a reconnect resubscribes @trade at once, same as @bookTicker" do
      feed = start_feed(channels: [:quotes, :top_of_book, :trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
      assert_receive {:frame_sent, %{"params" => ["btcusd@trade"]}}

      socket = :sys.get_state(feed).socket
      send(feed, {:dp_exchange, :gemini, :reconnected, socket})

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["btcusd@bookTicker"]}},
                     5_000

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["btcusd@trade"]}},
                     5_000
    end

    test "a Trade reaches the subscriber like any other event" do
      feed = start_feed(channels: [:trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, trade_for("BTC-USD")})

      assert_receive {:dp_exchange, :gemini, %Trade{symbol: "BTC-USD", side: :sell}}, 5_000
    end

    test "a delivered Trade is tracked under :trades, never under :quotes or :top_of_book" do
      feed = start_feed(channels: [:trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      send(feed, {:dp_exchange, :gemini, trade_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert Feed.coverage_by_kind(feed) == %{
               quotes: %{},
               top_of_book: %{},
               trades: %{"BTC-USD" => :stream}
             }

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "a socket crash resets :trades coverage the same way it resets the others" do
      # `fake_socket/1` is injected via `socket:` and is not itself linked to `feed` —
      # see the "a crashed socket is isolated, not fatal" describe block's own
      # `link_socket_into_feed/2`, reused here for the same reason. `url:` points the
      # replacement dial `isolate_crashed_socket/2` attempts at a local address that
      # refuses fast, matching that describe block's own reconnect test — without it
      # this would try a real network connect.
      feed =
        start_feed(channels: [:quotes, :top_of_book, :trades], url: "ws://127.0.0.1:1/nowhere")

      socket = :sys.get_state(feed).socket
      Process.unlink(socket)
      link_socket_into_feed(feed, socket)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      send(feed, {:dp_exchange, :gemini, trade_for("BTC-USD")})
      _settled = Feed.coverage(feed)
      assert Feed.coverage_by_kind(feed).trades == %{"BTC-USD" => :stream}

      Process.exit(socket, :kill)

      # Polled, not synchronised on one `Feed.coverage/1` call. The linked EXIT reaches the
      # feed from the dying socket while the call comes from this process, and Erlang does
      # not order signals from different senders. The single call used to win that race
      # under full-suite load (2026-10-03), reading coverage before the EXIT had landed.
      # 250 tries of 20 ms: a 5 s margin, as every wait on another process has.
      assert trades_coverage_clears?(feed, 250)
    end

    defp trades_coverage_clears?(_feed, 0), do: false

    defp trades_coverage_clears?(feed, tries) do
      Feed.coverage_by_kind(feed).trades == %{} or
        (Process.sleep(20) && trades_coverage_clears?(feed, tries - 1))
    end

    test "an unknown kind in :channels raises at start_link, loudly, rather than starting " <>
           "a feed that silently never carries it" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: :"bad_channels_#{System.unique_integer([:positive])}",
                 socket: fake_socket(self()),
                 channels: [:quotes, :depth]
               )

      assert message =~ ":channels"
      assert message =~ ":depth"
    end

    test "an empty :channels list raises at start_link" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: :"empty_channels_#{System.unique_integer([:positive])}",
                 socket: fake_socket(self()),
                 channels: []
               )

      assert message =~ ":channels"
    end
  end

  describe "a wire unsubscribe that failed is remembered, not forgotten" do
    test "a wire unsubscribe that failed is retried on the next tick" do
      # It was forgotten: `wanted` narrowed, and the venue kept streaming the symbol to this
      # connection until it next reconnected.
      socket = unsubscribe_fails_socket(self())
      feed = start_feed(socket: socket)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      assert {:error, :send_timeout} = Feed.unsubscribe(feed, ["BTC-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}

      send(feed, :resubscribe)

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}},
                     5_000

      # Settled by a call that queues behind the `:resubscribe`, not by a refute window.
      _settled = Feed.coverage(feed)
      refute_received {:frame_sent, %{"method" => "subscribe"}}
    end

    test "a symbol wanted again is not unsubscribed by an old retry" do
      socket = unsubscribe_fails_socket(self())
      feed = start_feed(socket: socket)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      {:error, :send_timeout} = Feed.unsubscribe(feed, ["BTC-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      send(feed, :resubscribe)
      assert_receive {:frame_sent, %{"method" => "subscribe"}}, 5_000
      _settled = Feed.coverage(feed)
      refute_received {:frame_sent, %{"method" => "unsubscribe"}}
    end
  end

  describe "a symbol list the feed cannot hold" do
    # `Feed` is one shared, named process. A raise inside it (`MapSet.new/1` on a string,
    # `Socket.streams/2` on an atom) crashed it, and its supervisor restarted it from the
    # static options it started with: every other consumer's subscription gone for one
    # caller's typo.
    test "is refused in the caller and leaves the feed, and what it holds, alone" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      monitor = Process.monitor(feed)

      assert {:error, {:invalid_symbols, "BTC-USD"}} = Feed.subscribe(feed, "BTC-USD", to: self())

      # The caller's whole argument comes back, not only the bad elements.
      assert {:error, {:invalid_symbols, ["ETH-USD", :btc_usd, nil]}} =
               Feed.subscribe(feed, ["ETH-USD", :btc_usd, nil], to: self())

      assert {:error, {:invalid_symbols, ["BTC-USD" | "tail"]}} =
               Feed.subscribe(feed, ["BTC-USD" | "tail"], to: self())

      assert {:error, {:invalid_symbols, [""]}} = Feed.update_symbols(feed, [""])
      assert {:error, {:invalid_symbols, [1]}} = Feed.unsubscribe(feed, [1])

      refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, 50
      assert :sys.get_state(feed).wanted == MapSet.new(["BTC-USD"])
    end

    test "canonical_symbols/1 spells every pair one way, once" do
      assert {:ok, ["BTC-USD", "SOL-RLUSD"]} =
               Feed.canonical_symbols(["btcusd", "BTC-USD", "SOLRLUSD"])
    end
  end

  describe "an {:error, _} from subscribe or update_symbols means nothing was recorded" do
    # The intent used to be recorded first and kept on failure, to be dialled and sent on the
    # next resubscribe tick. A caller told "error" gave up on the symbols and then received
    # them from a connection and a registration it had been told did not exist.
    test "a connect that fails leaves no subscriber, no wanted symbol and no monitor" do
      {:ok, feed} =
        Feed.start_link(
          name: :"badsock_#{System.unique_integer([:positive])}",
          url: "wss://127.0.0.1:1/nowhere"
        )

      assert {:error, _reason} = Feed.subscribe(feed, ["BTC-USD"], to: self())

      state = :sys.get_state(feed)
      assert state.wanted == MapSet.new()
      assert state.subscribers == MapSet.new()
      assert state.monitors == %{}
    end

    test "a failed send takes back the new symbols, keeps the old, and queues an unsubscribe" do
      feed = start_feed(socket: always_fails_socket(self()))
      me = self()
      seed = &%{&1 | wanted: MapSet.new(["ETH-USD"]), subscribers: MapSet.new([me])}
      :sys.replace_state(feed, seed)

      assert {:error, :send_timeout} = Feed.subscribe(feed, ["ETH-USD", "BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      state = :sys.get_state(feed)
      assert state.wanted == MapSet.new(["ETH-USD"])
      assert state.subscribers == MapSet.new([self()])
      assert state.unsubscribe_pending == MapSet.new(["BTC-USD"])
    end

    test "a failed subscribe's frame is unsubscribed on the next tick, not left streaming" do
      feed = start_feed(socket: always_fails_socket(self()))

      assert {:error, :send_timeout} = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      assert :sys.get_state(feed).subscribers == MapSet.new()

      send(feed, :resubscribe)

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}},
                     5_000

      _settled = Feed.coverage(feed)
      refute_received {:frame_sent, %{"method" => "subscribe"}}
    end

    test "a failed subscribe leaves a notice subscriber's monitor alone" do
      feed = start_feed(socket: always_fails_socket(self()))
      :ok = Feed.subscribe_notices(feed, to: self())
      monitors = :sys.get_state(feed).monitors
      assert Map.has_key?(monitors, self())

      assert {:error, :send_timeout} = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      assert :sys.get_state(feed).monitors == monitors
    end

    test "a failed update_symbols restores the wanted set it replaced" do
      feed = start_feed(socket: always_fails_socket(self()))
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["ETH-USD"])})

      assert {:error, :send_timeout} = Feed.update_symbols(feed, ["BTC-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}

      state = :sys.get_state(feed)
      assert state.wanted == MapSet.new(["ETH-USD"])
      assert state.unsubscribe_pending == MapSet.new(["BTC-USD"])
    end

    test "a successful subscribe and update_symbols still record" do
      feed = start_feed()
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      assert :ok = Feed.update_symbols(feed, ["ETH-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      assert :sys.get_state(feed).wanted == MapSet.new(["ETH-USD"])
    end
  end

  describe "a subscriber that cannot be sent to is refused in the caller" do
    test "subscribe/3 and subscribe_notices/2 answer an error and leave the feed alone" do
      feed = start_feed()
      monitor = Process.monitor(feed)

      for bad <- ["consumer", {:via, Registry, :x}, true, false, make_ref(), 1] do
        assert {:error, {:invalid_subscriber, ^bad}} =
                 Feed.subscribe(feed, ["BTC-USD"], to: bad)

        assert {:error, {:invalid_subscriber, ^bad}} = Feed.subscribe_notices(feed, to: bad)
      end

      refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, 50

      state = :sys.get_state(feed)
      assert state.subscribers == MapSet.new()
      assert state.notice_subscribers == MapSet.new()
      assert state.wanted == MapSet.new()
    end

    test "a registered name is a subscriber" do
      feed = start_feed()
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], to: :some_registered_consumer)
      assert_receive {:frame_sent, %{"method" => "subscribe"}}
      assert :ok = Feed.subscribe_notices(feed, to: :some_registered_consumer)
    end
  end

  describe "a notice flood is throttled" do
    defp bad_frame_notice(symbol) do
      Notice.new(:data_quality, :gemini,
        details: %{reason: "unreadable bookTicker level", symbol: symbol}
      )
    end

    test "a repeated per-frame notice is forwarded once, and the next window carries the count" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      notice = bad_frame_notice("BTC-USD")

      for _each <- 1..5, do: send(feed, {:dp_exchange, :gemini, notice})
      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality} = first}
      refute Map.has_key?(first.details, :suppressed)
      refute_received {:dp_exchange, :gemini, %Notice{kind: :data_quality}}

      # Age the window rather than wait it out.
      :sys.replace_state(feed, fn state ->
        aged = Map.new(state.notice_seen, fn {key, {start, n}} -> {key, {start - 31_000, n}} end)
        %{state | notice_seen: aged}
      end)

      send(feed, {:dp_exchange, :gemini, notice})
      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :data_quality, details: %{suppressed: 4}}}

      refute_received {:dp_exchange, :gemini, %Notice{}}
    end

    test "a wanted symbol and a different reason are keys of their own" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD", "ETH-USD"])})

      send(feed, {:dp_exchange, :gemini, bad_frame_notice("BTC-USD")})
      send(feed, {:dp_exchange, :gemini, bad_frame_notice("ETH-USD")})

      send(
        feed,
        {:dp_exchange, :gemini,
         Notice.new(:data_quality, :gemini, details: %{reason: "undecodable trade"})}
      )

      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :gemini, %Notice{details: %{symbol: "BTC-USD"}}}
      assert_received {:dp_exchange, :gemini, %Notice{details: %{symbol: "ETH-USD"}}}
      assert_received {:dp_exchange, :gemini, %Notice{details: %{reason: "undecodable trade"}}}
    end

    test "refusals with different venue statuses are keys of their own" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      refusal = fn status ->
        Notice.new(:refusal, :gemini, details: %{subscribe_status: status})
      end

      send(feed, {:dp_exchange, :gemini, refusal.(400)})
      send(feed, {:dp_exchange, :gemini, refusal.(429)})
      send(feed, {:dp_exchange, :gemini, refusal.(429)})
      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :refusal, details: %{subscribe_status: 400}}}

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :refusal, details: %{subscribe_status: 429}}}

      refute_received {:dp_exchange, :gemini, %Notice{kind: :refusal}}
    end

    test "a status outside the HTTP range shares one key, so the table cannot be grown by it" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      for status <- [1, 99, 600, 70_000, -5] do
        send(
          feed,
          {:dp_exchange, :gemini,
           Notice.new(:refusal, :gemini, details: %{subscribe_status: status})}
        )
      end

      _settled = Feed.coverage(feed)

      assert map_size(:sys.get_state(feed).notice_seen) == 1
    end

    test "a symbol this feed does not want shares one key, so the table cannot be grown by it" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      for n <- 1..20, do: send(feed, {:dp_exchange, :gemini, bad_frame_notice("junk#{n}")})
      _settled = Feed.coverage(feed)

      assert map_size(:sys.get_state(feed).notice_seen) == 1
      assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality}}
      refute_received {:dp_exchange, :gemini, %Notice{kind: :data_quality}}
    end

    test "the table is capped, expired windows first" do
      feed = start_feed()
      long_ago = System.monotonic_time(:millisecond) - 120_000

      :sys.replace_state(feed, fn state ->
        seen = Map.new(1..5_000, fn n -> {{:data_quality, "reason #{n}", nil}, {long_ago, 0}} end)
        %{state | notice_seen: seen}
      end)

      send(feed, {:dp_exchange, :gemini, bad_frame_notice("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert map_size(:sys.get_state(feed).notice_seen) == 1
    end

    test "lifecycle notices are never throttled" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      for _each <- 1..3, do: send(feed, {:dp_exchange, :gemini, Notice.new(:link_up, :gemini)})
      _settled = Feed.coverage(feed)

      for _each <- 1..3 do
        assert_received {:dp_exchange, :gemini, %Notice{kind: :link_up}}
      end
    end
  end
end
