defmodule DpExchange.Gemini.TickADHotPathsTest do
  @moduledoc """
  Tick AD: what the per-frame and per-tick paths keep.

  Nothing here measures time. Each test states a structural property: a bookkeeping set stays
  inside the set it describes, and a value taken from a frame does not keep the frame alive.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Trade
  alias DpExchange.Gemini.{Feed, FeedSync, Socket}

  @moduletag :capture_log

  # Large enough that every frame is a reference-counted binary, so a string decoded out of it
  # is a sub-binary pointing at the whole frame.
  @padding String.duplicate("x", 4_096)

  defp socket_state do
    %{subscriber: self(), request_id: 0, connected_once?: false, last_heard_at: nil}
  end

  defp frame(payload), do: {:text, Jason.encode!(Map.put(payload, "pad", @padding))}

  # A stand-in socket speaking the `:gen.call` protocol `send_frame/2` uses; every frame is
  # answered `:ok`.
  defp scripted_socket do
    spawn_link(fn -> answer_frames() end)
  end

  defp answer_frames do
    receive do
      {:"$websockex_send", from, {:text, _frame}} ->
        :gen.reply(from, :ok)
        answer_frames()
    end
  end

  defp start_feed(socket) do
    name = :"tick_ad_feed_#{System.unique_integer([:positive])}"
    {:ok, pid} = Feed.start_link(name: name, socket: socket)
    pid
  end

  defp owe(feed, overrides) do
    :sys.replace_state(feed, fn state ->
      state
      |> Map.merge(%{unsubscribe_pending: MapSet.new(), late_subscribes: MapSet.new()})
      |> Map.merge(overrides)
    end)
  end

  describe "late_subscribes never outlives the pending set it describes" do
    test "a symbol wanted again is dropped from both sets on the next tick" do
      feed = start_feed(scripted_socket())

      owe(feed, %{
        wanted: MapSet.new(["SOL-USD"]),
        unsubscribe_pending: MapSet.new(["SOL-USD"]),
        late_subscribes: MapSet.new(["SOL-USD"])
      })

      send(feed, :resubscribe)
      FeedSync.await_resubscribe(feed)
      state = :sys.get_state(feed)

      assert state.unsubscribe_pending == MapSet.new()
      assert state.late_subscribes == MapSet.new()
    end

    test "a tick that cannot send keeps only the late symbols still owed" do
      feed = start_feed(scripted_socket())

      owe(feed, %{
        wanted: MapSet.new(["SOL-USD"]),
        link_down?: true,
        unsubscribe_pending: MapSet.new(["ETH-USD", "SOL-USD"]),
        late_subscribes: MapSet.new(["ETH-USD", "SOL-USD", "BTC-USD"])
      })

      send(feed, :resubscribe)
      FeedSync.await_resubscribe(feed)
      state = :sys.get_state(feed)

      assert state.unsubscribe_pending == MapSet.new(["ETH-USD"])
      assert state.late_subscribes == MapSet.new(["ETH-USD"])
      assert MapSet.subset?(state.late_subscribes, state.unsubscribe_pending)
    end
  end

  describe "a value taken from a frame does not keep the frame alive" do
    test "the symbol quoted in a notice is its own binary" do
      long_symbol = String.duplicate("q", 100)

      undecodable = %{"e" => "depthUpdate", "s" => long_symbol, "b" => [], "a" => []}
      assert {:ok, _state} = Socket.handle_frame(frame(undecodable), socket_state())

      assert_receive {:dp_exchange, :gemini, %Notice{details: %{symbol: quoted}}}, 5_000
      assert byte_size(quoted) == 64
      assert :binary.referenced_byte_size(quoted) == byte_size(quoted)
    end

    test "a trade's string id is its own binary" do
      trade = %{
        "e" => "trade",
        "s" => "btcusd",
        "t" => "trade-id-1",
        "p" => "100.5",
        "q" => "0.25",
        "m" => false,
        "E" => 1_787_936_147_000_000_000
      }

      assert {:ok, _state} = Socket.handle_frame(frame(trade), socket_state())

      assert_receive {:dp_exchange, :gemini, %Trade{id: "trade-id-1" = id}}, 5_000
      assert :binary.referenced_byte_size(id) == byte_size(id)
    end
  end
end
