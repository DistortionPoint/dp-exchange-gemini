defmodule DpExchange.Gemini.SocketBackoffParentExitTest do
  @moduledoc """
  A socket in its reconnect backoff still hears its parent stop it.

  `WebSockex` traps exits and learns that its parent has gone from an `{:EXIT, parent, reason}`
  message that only its own loops read. `Socket.handle_disconnect/2` waits out the backoff
  (up to 30s) inside the callback, and that wait was a bare `Process.sleep/1`: a socket
  stopped by `Feed` (or orphaned by a `Feed` restart) slept the whole delay, then dialled the
  venue once more before it noticed.

  The callback is driven directly, in a process of its own, with this test as the parent. Tier
  1: no socket is opened.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.Socket

  @moduletag :capture_log

  # Attempt 7 is the 30s cap (1s doubling, `@max_reconnect_delay_ms`); jitter only shortens it
  # to at least 22.5s. Far longer than any margin below, so only hearing the exit can end the
  # wait in time.
  @capped_attempt 7

  defp state(parent) do
    %{
      subscriber: self(),
      parent: parent,
      request_id: 0,
      connected_once?: false,
      last_heard_at: nil,
      liveness: nil
    }
  end

  # Runs `handle_disconnect/2` in its own process, trapping exits as `WebSockex` does, and
  # reports that it is about to wait. Returns the monitored pid once it says so, so the exit
  # this test sends next cannot arrive before the flag is set.
  defp start_waiting(state) do
    test_pid = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(test_pid, {:waiting, self()})
        Socket.handle_disconnect(%{reason: :closed, attempt_number: @capped_attempt}, state)
        send(test_pid, {:backoff_finished, self()})
      end)

    assert_receive {:waiting, ^pid}, 5_000
    {pid, ref}
  end

  test "an exit from the parent ends the backoff with the parent's reason" do
    {pid, ref} = start_waiting(state(self()))

    Process.exit(pid, :shutdown)

    # Without the fix the process sleeps the full 30s and finishes the callback.
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000
    refute_received {:backoff_finished, ^pid}
  end

  test "an exit from a process that is not the parent does not end the backoff" do
    {pid, ref} = start_waiting(state(self()))

    other = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(other, :kill) end)

    # Delivered as an `{:EXIT, other, _}` message to the trapping process, by a pid that is
    # not its parent. `send/2` stands in for the signal so the test needs no link.
    send(pid, {:EXIT, other, :shutdown})

    # A local `send/2` is enqueued before it returns, so the message is already in the
    # waiter's mailbox: still there, unread, and the waiter still alive, is the proof that
    # it was not taken for its parent's. No wait decides this.
    assert {:messages, [{:EXIT, ^other, :shutdown}]} = Process.info(pid, :messages)
    assert Process.alive?(pid)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end
end
