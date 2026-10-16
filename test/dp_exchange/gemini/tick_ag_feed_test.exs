defmodule DpExchange.Gemini.TickAGFeedTest do
  @moduledoc """
  Tick AG: what the feed holds once the consumers that wanted it are gone.

  `wanted` is one set for the whole feed. A symbol used to outlive every subscriber that asked
  for it: still streamed to the connection, resent on every tick and reconnect, and fanned out
  to nobody. The `:DOWN` is driven by hand here (the monitor reference is read from the feed's
  state), so each sequence is deterministic.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Fanout
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Gemini.Feed

  @moduletag :capture_log

  # A stand-in socket speaking the `:gen.call` protocol `WebSockex.send_frame/2` uses. It
  # forwards each frame to the test and answers `reply_for.(method)`.
  defp socket(report_to, reply_for) do
    spawn_link(fn -> frames(report_to, reply_for) end)
  end

  defp frames(report_to, reply_for) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        decoded = Jason.decode!(frame)
        send(report_to, {:frame_sent, decoded})
        :gen.reply(from, reply_for.(decoded["method"]))
        frames(report_to, reply_for)
    end
  end

  defp start_feed(socket) do
    name = :"tick_ag_feed_#{System.unique_integer([:positive])}"
    {:ok, feed} = Feed.start_link(name: name, socket: socket)
    feed
  end

  defp sleeper do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # Delivers the `:DOWN` the feed's own monitor of `pid` would, then waits for it to be handled.
  defp pid_down(feed, pid) do
    ref = Map.fetch!(:sys.get_state(feed).monitors, pid)
    send(feed, {:DOWN, ref, :process, pid, :killed})
    # A successful wire unsubscribe pokes the stand-in socket with `:sys`, which it does not
    # answer, so the feed waits out that call's own 2s bound before it can reply here.
    :sys.get_state(feed, 20_000)
  end

  describe "the last data subscriber dying" do
    test "releases what was wanted, and the venue is told to stop" do
      feed = start_feed(socket(self(), fn _method -> :ok end))
      subscriber = sleeper()

      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: subscriber)
      assert_receive {:frame_sent, %{"method" => "subscribe"}}, 5_000

      state = pid_down(feed, subscriber)

      assert state.wanted == MapSet.new()
      assert Feed.wanted(feed) == []

      assert_receive {:frame_sent, %{"method" => "unsubscribe", "params" => params}}, 5_000
      assert Enum.sort(params) == ["btcusd@bookTicker", "ethusd@bookTicker"]
    end

    test "a payload for a released symbol is not counted as coverage" do
      feed = start_feed(socket(self(), fn _method -> :ok end))
      subscriber = sleeper()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)
      _state = pid_down(feed, subscriber)

      quote_struct = %Quote{
        symbol: "BTC-USD",
        price: Decimal.new("1"),
        venue_time: ~U[2026-08-28 12:00:00Z],
        observed_at: ~U[2026-08-28 12:00:00Z],
        provider: :gemini
      }

      send(feed, {:dp_exchange, :gemini, quote_struct})

      assert Feed.coverage(feed) == %{}
    end

    test "a wire unsubscribe that fails is queued for the tick, with the symbols released" do
      reply = fn
        "unsubscribe" -> {:error, :send_timeout}
        _method -> :ok
      end

      feed = start_feed(socket(self(), reply))
      subscriber = sleeper()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)

      state = pid_down(feed, subscriber)

      assert state.wanted == MapSet.new()
      assert state.unsubscribe_pending == MapSet.new(["BTC-USD"])
    end

    test "with no socket there is nothing to send, and the symbols are still released" do
      feed = start_feed(nil)
      subscriber = sleeper()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | subscribers: MapSet.new([subscriber]),
            monitors: Fanout.watch(subscriber, state.monitors),
            wanted: MapSet.new(["BTC-USD"])
        }
      end)

      state = pid_down(feed, subscriber)

      assert state.wanted == MapSet.new()
      assert state.unsubscribe_pending == MapSet.new()
    end

    test "a dial in progress is not sent to" do
      feed = start_feed(nil)
      subscriber = sleeper()
      dialling = sleeper()

      :sys.replace_state(feed, fn state ->
        dial = %{
          socket: dialling,
          ref: make_ref(),
          timer: Process.send_after(self(), :never_delivered, 600_000),
          waiters: [],
          waiting: 0,
          resubscribe?: false
        }

        %{
          state
          | socket: dialling,
            dial: dial,
            subscribers: MapSet.new([subscriber]),
            monitors: Fanout.watch(subscriber, state.monitors),
            wanted: MapSet.new(["BTC-USD"])
        }
      end)

      state = pid_down(feed, subscriber)

      assert state.wanted == MapSet.new()
      assert state.unsubscribe_pending == MapSet.new()
      refute_receive {:frame_sent, _frame}, 50
    end
  end

  describe "update_symbols/2 whose subscribe half fails" do
    test "drops the symbols its unsubscribe half removed, and queues the ones it added" do
      reply = fn
        "subscribe" -> {:error, :send_timeout}
        _method -> :ok
      end

      feed = start_feed(socket(self(), reply))
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["ETH-USD", "SOL-USD"])})

      assert {:error, :send_timeout} = Feed.update_symbols(feed, ["SOL-USD", "BTC-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe", "params" => params}}, 5_000
      assert params == ["ethusd@bookTicker"]

      state = :sys.get_state(feed, 20_000)
      assert state.wanted == MapSet.new(["SOL-USD"])
      assert state.unsubscribe_pending == MapSet.new(["BTC-USD"])
    end
  end

  describe "a subscriber dying while another is left" do
    test "keeps what is wanted and sends nothing" do
      feed = start_feed(socket(self(), fn _method -> :ok end))
      leaving = sleeper()
      staying = sleeper()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: leaving)
      :ok = Feed.subscribe(feed, ["ETH-USD"], to: staying)
      assert_receive {:frame_sent, %{"method" => "subscribe"}}, 5_000
      assert_receive {:frame_sent, %{"method" => "subscribe"}}, 5_000

      _state = pid_down(feed, leaving)

      assert Feed.wanted(feed) == ["BTC-USD", "ETH-USD"]
      refute_receive {:frame_sent, %{"method" => "unsubscribe"}}, 50
    end

    test "a registered-name subscriber, never monitored, keeps the set alive" do
      feed = start_feed(socket(self(), fn _method -> :ok end))
      name = :"tick_ag_named_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      pid = sleeper()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: name)
      :ok = Feed.subscribe(feed, ["ETH-USD"], to: pid)

      _state = pid_down(feed, pid)

      assert Feed.wanted(feed) == ["BTC-USD", "ETH-USD"]
    end

    test "a notice-only subscriber dying releases nothing" do
      feed = start_feed(socket(self(), fn _method -> :ok end))
      watcher = sleeper()
      subscriber = sleeper()

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)
      :ok = Feed.subscribe_notices(feed, to: watcher)

      _state = pid_down(feed, watcher)

      assert Feed.wanted(feed) == ["BTC-USD"]
    end
  end
end
