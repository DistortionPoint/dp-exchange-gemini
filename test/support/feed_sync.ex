defmodule DpExchange.Gemini.FeedSync do
  @moduledoc """
  Waits, without sleeping, for a `DpExchange.Gemini.Feed`'s in-flight resubscribe — test support.

  The feed resubscribes from a worker it monitors and judges the answer when the answer arrives
  (`Feed`'s moduledoc). A test that sends `:resubscribe`, or a reconnect report, and then reads
  the notices, the pending-unsubscribe set or the absence of a frame must wait for that answer
  first, or it reads the state before the outcome is applied.
  """

  alias DpExchange.Gemini.Feed

  @doc """
  Returns once the feed holds no resubscribe in flight, including one folded in behind it.

  The worker is awaited by monitor (it sends its answer before it exits, so the answer is in
  the feed's mailbox by then) and a call to the feed then queues behind that answer.
  """
  @spec await_resubscribe(GenServer.server()) :: :ok
  def await_resubscribe(feed) do
    case Map.get(:sys.get_state(feed), :resub) do
      nil ->
        :ok

      %{pid: pid} ->
        monitor = Process.monitor(pid)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          15_000 -> raise "the feed's resubscribe worker did not finish within 15s"
        end

        # Answered only after the worker's result message, which is already queued.
        _settled = Feed.wanted(feed)
        await_resubscribe(feed)
    end
  end
end
