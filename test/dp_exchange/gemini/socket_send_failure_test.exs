defmodule DpExchange.Gemini.SocketSendFailureTest do
  @moduledoc """
  What `Socket.subscribe/3` and `Socket.unsubscribe/3` do to the socket's own bookkeeping
  when the frame does not go out.

  A stand-in process answers the vendored `send_frame/3` call with a fixed reply and speaks
  just enough of the `:sys` protocol for `:sys.replace_state/3` and `:sys.get_state/1`, so the
  send result is decided by the test and nothing depends on a connection's timing.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.Socket

  @moduletag :capture_log

  # A process standing in for the socket. `reply` is what a send gets back.
  defp start_stub(reply, state) do
    spawn_link(fn -> stub_loop(reply, state) end)
  end

  defp stub_loop(reply, state) do
    receive do
      {:"$websockex_send", from, _frame} ->
        :gen.reply(from, reply)
        stub_loop(reply, state)

      {:system, from, {:replace_state, fun}} ->
        new_state = fun.(state)
        :gen.reply(from, {:ok, new_state})
        stub_loop(reply, new_state)

      {:system, from, :get_state} ->
        :gen.reply(from, {:ok, state})
        stub_loop(reply, state)

      _ignored ->
        stub_loop(reply, state)
    end
  end

  defp anchored_state do
    %{
      depth_anchored: MapSet.new(["BTC-USD", "ETH-USD"]),
      last_depth_update: %{"BTC-USD" => 12, "ETH-USD" => 40},
      partial_depth_claims: MapSet.new([{:depth5, "BTC-USD"}])
    }
  end

  describe "unsubscribe/3 resets only after the frame went out" do
    test "a send that failed keeps the anchor, the sequence and the claim" do
      stub = start_stub({:error, :stub_refused}, anchored_state())

      assert {:error, :stub_refused} = Socket.unsubscribe(stub, ["BTC-USD"], :depth)
      assert {:error, :stub_refused} = Socket.unsubscribe(stub, ["BTC-USD"], :depth5)

      assert :sys.get_state(stub) == anchored_state()
    end

    test "a send that went out forgets the anchor, the sequence and the claim" do
      stub = start_stub(:ok, anchored_state())

      assert :ok = Socket.unsubscribe(stub, ["BTC-USD"], :depth)
      assert :ok = Socket.unsubscribe(stub, ["BTC-USD"], :depth5)

      state = :sys.get_state(stub)
      assert state.depth_anchored == MapSet.new(["ETH-USD"])
      assert state.last_depth_update == %{"ETH-USD" => 40}
      assert state.partial_depth_claims == MapSet.new()
    end
  end

  describe "subscribe/3 and the partial-depth claim" do
    test "a send that failed gives back the claim this call took" do
      stub = start_stub({:error, :stub_refused}, %{partial_depth_claims: MapSet.new()})

      assert {:error, :stub_refused} = Socket.subscribe(stub, ["BTC-USD"], :depth5)
      assert :sys.get_state(stub).partial_depth_claims == MapSet.new()

      # So a different symbol can be claimed afterwards, instead of being refused as a
      # conflict with a subscription that never happened.
      assert {:error, :stub_refused} = Socket.subscribe(stub, ["ETH-USD"], :depth5)
    end

    test "a send that failed keeps a claim that was already held" do
      stub = start_stub({:error, :stub_refused}, anchored_state())

      assert {:error, :stub_refused} = Socket.subscribe(stub, ["BTC-USD"], :depth5)

      assert :sys.get_state(stub).partial_depth_claims == MapSet.new([{:depth5, "BTC-USD"}])
    end

    test "a send that went out keeps the claim" do
      stub = start_stub(:ok, %{partial_depth_claims: MapSet.new()})

      assert :ok = Socket.subscribe(stub, ["BTC-USD"], :depth5)

      assert :sys.get_state(stub).partial_depth_claims == MapSet.new([{:depth5, "BTC-USD"}])
    end

    test "a refused claim leaves nothing in the caller's mailbox" do
      stub = start_stub(:ok, anchored_state())

      assert {:error, {:partial_depth_symbol_conflict, "BTC-USD"}} =
               Socket.subscribe(stub, ["ETH-USD"], :depth5)

      assert {:messages, []} = Process.info(self(), :messages)
    end
  end
end
