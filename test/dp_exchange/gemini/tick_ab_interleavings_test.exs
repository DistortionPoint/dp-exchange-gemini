defmodule DpExchange.Gemini.TickABInterleavingsTest do
  @moduledoc """
  Tick AB: message orderings a real node can produce, forced by hand.

  Nothing here depends on timing. Every ordering is built by sending the late message
  ourselves, and every wait is on a message that has already been sent, with a margin far
  above what delivery needs.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.{Feed, FeedSync}

  @moduletag :capture_log

  # A stand-in socket speaking the `:gen.call` protocol `send_frame/2` uses. It answers
  # `{:error, :send_timeout}` for every frame naming a stream in `failing` (the answer a
  # caller gets when the real socket, asleep in its reconnect backoff, does not read the
  # frame within 5s) and `:ok` for the rest, and forwards each frame to the test.
  defp scripted_socket(report_to, failing) do
    spawn_link(fn -> scripted_frames(report_to, failing) end)
  end

  defp scripted_frames(report_to, failing) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        decoded = Jason.decode!(frame)
        send(report_to, {:frame_sent, decoded})

        if Enum.any?(decoded["params"], &(&1 in failing)),
          do: :gen.reply(from, {:error, :send_timeout}),
          else: :gen.reply(from, :ok)

        scripted_frames(report_to, failing)
    end
  end

  defp start_feed(socket) do
    name = :"tick_ab_feed_#{System.unique_integer([:positive])}"
    {:ok, pid} = Feed.start_link(name: name, socket: socket)
    pid
  end

  defp flush_frames do
    receive do
      {:frame_sent, _frame} -> flush_frames()
    after
      0 -> :ok
    end
  end

  # Puts the feed in the state a failed subscribe leaves behind: `symbols` owed a wire
  # unsubscribe, flagged as symbols whose subscribe frame may still land, link down.
  defp owe_late_unsubscribe(feed, symbols, extra \\ %{}) do
    :sys.replace_state(feed, fn state ->
      owed = %{
        unsubscribe_pending: MapSet.new(symbols),
        late_subscribes: MapSet.new(symbols),
        link_down?: true
      }

      Map.merge(state, Map.merge(owed, extra))
    end)
  end

  describe "a subscribe that failed on the old connection can land on the new one" do
    test "a reconnect unsubscribes the symbols a failed subscribe queued, and only those" do
      # ETH-USD's subscribe fails: the send timed out, but its frame is still in the socket's
      # mailbox and will be written to the NEW connection. BTC-USD's unsubscribe fails: the
      # old connection's subscription dies with it, so nothing is owed on the new one.
      socket = scripted_socket(self(), ["ethusd@bookTicker", "btcusd@bookTicker"])
      feed = start_feed(socket)

      # BTC-USD is made wanted directly: its subscribe frame would fail on this script.
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      assert {:error, :send_timeout} = Feed.subscribe(feed, ["ETH-USD"], to: self())
      assert {:error, :send_timeout} = Feed.unsubscribe(feed, ["BTC-USD"])

      state = :sys.get_state(feed)
      assert state.wanted == MapSet.new()
      assert state.unsubscribe_pending == MapSet.new(["ETH-USD", "BTC-USD"])
      assert state.late_subscribes == MapSet.new(["ETH-USD"])

      # The ordering: the link went down, then came back.
      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})
      flush_frames()
      send(feed, {:dp_exchange, :gemini, :reconnected, socket})

      # The resubscribe runs in a worker; its answer is applied when it arrives, so wait for it.
      # Its frames were forwarded to this process before the fake socket answered the worker.
      FeedSync.await_resubscribe(feed)
      state = :sys.get_state(feed)

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["ethusd@bookTicker"]}},
                     5_000

      refute_received {:frame_sent,
                       %{"method" => "unsubscribe", "params" => ["btcusd@bookTicker"]}}

      # The ETH-USD unsubscribe failed on this script too (every ETH frame does), so it is
      # still owed; BTC-USD's was dropped with the old connection.
      assert state.unsubscribe_pending == MapSet.new(["ETH-USD"])
      assert state.link_down? == false
    end

    test "a reconnect that unsubscribes them leaves nothing owed" do
      socket = scripted_socket(self(), [])
      feed = start_feed(socket)
      owe_late_unsubscribe(feed, ["SOL-USD"])

      send(feed, {:dp_exchange, :gemini, :reconnected, socket})
      FeedSync.await_resubscribe(feed)
      state = :sys.get_state(feed)

      assert_receive {:frame_sent,
                      %{"method" => "unsubscribe", "params" => ["solusd@bookTicker"]}},
                     5_000

      assert state.unsubscribe_pending == MapSet.new()
      assert state.late_subscribes == MapSet.new()
    end

    test "a reconnect with a symbol wanted again sends no unsubscribe for it" do
      socket = scripted_socket(self(), [])
      feed = start_feed(socket)
      owe_late_unsubscribe(feed, ["SOL-USD"], %{wanted: MapSet.new(["SOL-USD"])})

      send(feed, {:dp_exchange, :gemini, :reconnected, socket})
      FeedSync.await_resubscribe(feed)
      state = :sys.get_state(feed)

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["solusd@bookTicker"]}},
                     5_000

      refute_received {:frame_sent, %{"method" => "unsubscribe"}}
      assert state.unsubscribe_pending == MapSet.new()
    end

    test "a symbol queued by a failed unsubscribe alone is not unsubscribed again" do
      socket = scripted_socket(self(), [])
      feed = start_feed(socket)

      :sys.replace_state(feed, fn state ->
        %{state | unsubscribe_pending: MapSet.new(["ETH-USD"]), link_down?: true}
      end)

      send(feed, {:dp_exchange, :gemini, :reconnected, socket})
      state = :sys.get_state(feed)

      refute_received {:frame_sent, _frame}
      assert state.unsubscribe_pending == MapSet.new()
    end
  end
end
