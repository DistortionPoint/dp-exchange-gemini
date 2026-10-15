defmodule DpExchange.Gemini.SocketTimersTest do
  @moduledoc """
  The depth resync's three timers (`:pending`, `:timeout`, `:retry`) and the liveness check
  are kept in state and CANCELLED when their subject goes away, not left to fire and be
  ref-checked into nothing. Every assertion is `Process.read_timer/1` returning `false`:
  no live timer remains.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.Socket

  @key {"BTC-USD", :depth}

  @diff %{
    "e" => "depthUpdate",
    "E" => 1_787_936_147_000_000_000,
    "s" => "btcusd",
    "U" => 11,
    "u" => 15,
    "b" => [["3610.00", "1.5"]],
    "a" => [["3611.00", "0"]]
  }

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        subscriber: self(),
        request_id: 0,
        connected_once?: false,
        last_heard_at: nil,
        liveness: nil,
        depth_snapshot?: true,
        depth_anchored: MapSet.new(["BTC-USD"]),
        last_depth_update: %{"BTC-USD" => 5},
        depth_streams: MapSet.new([@key]),
        # A resync began a moment ago, so the next one waits out the throttle window and is
        # armed as a real timer rather than sent at once.
        depth_resync_at: %{@key => System.monotonic_time(:millisecond)}
      },
      overrides
    )
  end

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  defp live?(timer), do: is_integer(Process.read_timer(timer))

  defp timer_of(state, kind), do: state.depth_timers |> Map.fetch!({kind, @key}) |> elem(1)

  defp pending_state do
    assert {:ok, pending} = Socket.handle_frame(frame(@diff), state())
    pending
  end

  defp unsubscribing_state do
    pending = pending_state()
    assert %{@key => {:pending, ref}} = pending.depth_resync

    assert {:reply, {:text, _frame}, unsubscribing} =
             Socket.handle_info({:resync_depth, @key, ref}, pending)

    {ref, pending, unsubscribing}
  end

  defp refused_state do
    {ref, _pending, unsubscribing} = unsubscribing_state()
    assert %{@key => {:unsubscribing, ^ref, id}} = unsubscribing.depth_resync

    assert {:ok, subscribing} =
             Socket.handle_frame(frame(%{"id" => id, "status" => 200}), unsubscribing)

    assert {:reply, {:text, _frame}, awaiting} =
             Socket.handle_info({:resubscribe_depth, @key, ref}, subscribing)

    %{@key => {:awaiting, ^ref, sub_id}} = awaiting.depth_resync

    assert {:ok, refused} =
             Socket.handle_frame(frame(%{"id" => sub_id, "status" => 400}), awaiting)

    refused
  end

  test "a throttled resync holds a live pending timer, and terminate cancels it" do
    pending = pending_state()
    timer = timer_of(pending, :pending)
    assert live?(timer)

    assert :ok = Socket.terminate(:normal, pending)
    refute live?(timer)
  end

  test "the unsubscribe-answer deadline is cancelled when the unsubscribe is answered" do
    {ref, _pending, unsubscribing} = unsubscribing_state()
    # The pending timer fired (the test sent its message by hand) and is forgotten.
    refute Map.has_key?(unsubscribing.depth_timers, {:pending, @key})

    timeout = timer_of(unsubscribing, :timeout)
    assert live?(timeout)
    assert %{@key => {:unsubscribing, ^ref, id}} = unsubscribing.depth_resync

    assert {:ok, answered} =
             Socket.handle_frame(frame(%{"id" => id, "status" => 200}), unsubscribing)

    refute live?(timeout)
    refute Map.has_key?(answered.depth_timers, {:timeout, @key})
  end

  test "an unanswered unsubscribe forgets its deadline and arms the next pending wait" do
    {ref, _pending, unsubscribing} = unsubscribing_state()
    timeout = timer_of(unsubscribing, :timeout)

    assert {:ok, restarted} = Socket.handle_info({:resync_timeout, @key, ref}, unsubscribing)

    refute Map.has_key?(restarted.depth_timers, {:timeout, @key})
    assert %{@key => {:pending, new_ref}} = restarted.depth_resync
    assert new_ref != ref
    assert {^new_ref, next} = restarted.depth_timers[{:pending, @key}]
    assert live?(next)

    # A stale deadline message must not drop the newer timer's handle.
    assert {:ok, still} = Socket.handle_info({:resync_timeout, @key, ref}, restarted)
    assert still.depth_timers == restarted.depth_timers

    assert :ok = Socket.terminate(:normal, still)
    refute live?(next)
    # The original deadline timer was never cancelled by the hand-delivered message; it is
    # the real one a socket would already have consumed, so clean it up here.
    Process.cancel_timer(timeout)
  end

  test "a refused resubscribe arms a retry timer; a reconnect cancels it" do
    refused = refused_state()
    retry = timer_of(refused, :retry)
    assert live?(retry)

    assert {:ok, reconnected} = Socket.handle_connect(:conn, refused)
    refute live?(retry)
    assert reconnected.depth_timers == %{}
  end

  test "a reconnect cancels the pending wait and the previous connection's liveness check" do
    pending = pending_state()
    pending_timer = timer_of(pending, :pending)

    assert {:ok, first} = Socket.handle_connect(:conn, pending)
    refute live?(pending_timer)
    assert live?(first.liveness_timer)

    assert {:ok, second} = Socket.handle_connect(:conn, first)
    refute live?(first.liveness_timer)
    assert live?(second.liveness_timer)

    assert :ok = Socket.terminate(:normal, second)
    refute live?(second.liveness_timer)
  end

  test "a liveness check that re-arms keeps the new timer and spends the old" do
    {:ok, connected} = Socket.handle_connect(:conn, state())
    liveness = connected.liveness
    connected = %{connected | last_heard_at: System.monotonic_time(:millisecond)}

    assert {:reply, :ping, rearmed} = Socket.handle_info({:liveness, liveness}, connected)
    assert rearmed.liveness_timer != connected.liveness_timer
    assert live?(rearmed.liveness_timer)

    assert :ok = Socket.terminate(:normal, rearmed)
    refute live?(rearmed.liveness_timer)
    Process.cancel_timer(connected.liveness_timer)
  end

  test "a resync for a symbol unsubscribed meanwhile forgets its fired pending timer" do
    pending = pending_state()
    timer = timer_of(pending, :pending)
    assert %{@key => {:pending, ref}} = pending.depth_resync
    gone = %{pending | depth_streams: MapSet.new()}

    assert {:ok, cleared} = Socket.handle_info({:resync_depth, @key, ref}, gone)
    assert cleared.depth_resync == %{}
    refute Map.has_key?(cleared.depth_timers, {:pending, @key})
    Process.cancel_timer(timer)
  end

  test "terminate is safe on a state that never armed a timer" do
    assert :ok = Socket.terminate(:normal, state())
  end
end
