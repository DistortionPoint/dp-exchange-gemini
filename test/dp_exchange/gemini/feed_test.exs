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

  defp quote_for(symbol) do
    %Quote{
      symbol: symbol,
      price: Decimal.new("77845.79"),
      timestamp: ~U[2026-08-28 12:00:00Z],
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

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}
    end

    test "notices go to notice subscribers, not quote subscribers" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}
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

      assert_receive {:dp_exchange, :gemini, %Quote{}}
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

      assert_receive {:dp_exchange, :gemini, %Quote{}}
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash" do
      name = :"gemini_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: name)
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      Process.sleep(20)

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

      # No socket, nothing to crash and nothing to send to.
      Process.sleep(10)
      assert Process.alive?(feed)
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
end
