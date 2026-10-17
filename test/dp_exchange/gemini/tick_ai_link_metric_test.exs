defmodule DpExchange.Gemini.TickAILinkMetricTest do
  @moduledoc """
  Tick AI: `[:dp_exchange, :link, :up]` is closed by a `link_down` however the connection ends.

  The socket emits `link_up` on connect and `link_down` from `handle_disconnect/2`, but a socket
  that crashes runs no `handle_disconnect/2`. The feed, which sees the `EXIT`, now emits the
  `link_down` for it, once, and not when the socket had already reported its own drop.

  The telemetry handler is global, so each test filters on a marker only its own crash reason
  carries; two async feeds' events never satisfy one another.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.Feed

  @moduletag :capture_log

  defp idle_socket, do: spawn_link(fn -> Process.sleep(:infinity) end)

  defp start_feed do
    name = :"tick_ai_feed_#{System.unique_integer([:positive])}"
    {:ok, feed} = Feed.start_link(name: name, socket: idle_socket())
    feed
  end

  defp attach(marker) do
    test = self()
    id = {__MODULE__, marker}

    :telemetry.attach(
      id,
      [:dp_exchange, :link, :down],
      fn _event, measurements, metadata, _config ->
        if String.contains?(metadata.reason, marker),
          do: send(test, {:link_down, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "a socket crash emits one link_down carrying the bounded reason" do
    marker = "crash_marker_#{System.unique_integer([:positive])}"
    attach(marker)
    feed = start_feed()
    socket = :sys.get_state(feed).socket

    send(feed, {:EXIT, socket, {:boom, marker}})
    _settled = :sys.get_state(feed)

    assert_receive {:link_down, %{count: 1}, %{provider: :gemini, reason: reason}}, 5_000
    assert is_binary(reason)
    refute_receive {:link_down, _measurements, _metadata}, 500
  end

  test "a crash after the socket reported its own drop does not emit a second link_down" do
    marker = "reported_marker_#{System.unique_integer([:positive])}"
    attach(marker)
    feed = start_feed()
    socket = :sys.get_state(feed).socket

    send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})
    send(feed, {:EXIT, socket, {:boom, marker}})
    _settled = :sys.get_state(feed)

    refute_receive {:link_down, _measurements, _metadata}, 500
  end
end
