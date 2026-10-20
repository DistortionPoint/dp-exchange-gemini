defmodule DpExchange.Gemini.Ledger do
  @moduledoc """
  What a `DpExchange.Gemini.Feed` was asked to carry, kept outside the feed — internal.

  A supervisor restarts a crashed feed from the options it was started with, and those never
  hold a consumer's later `subscribe/3`: the wanted symbols, the data subscribers and the
  notice subscribers were lost with the process, and no consumer was told. This is a small
  `Agent`, started by `DpExchange.Gemini.Supervisor` **before** the feed under `:rest_for_one`,
  so a feed restart leaves it standing and a ledger restart restarts the feed after it.

  The feed writes the accepted intent after every change (never a refused one: a refused call
  leaves the intent as it was, so nothing differs and nothing is written) and reads it back,
  in `handle_continue/2`, when it starts. It holds pids and symbols only: no credential and no
  option of the feed's. The channels a feed carries are its start options, which a restart
  has again.
  """

  use Agent

  @typedoc "The intent the feed keeps: sets of symbols and of subscribers."
  @type snapshot :: %{
          wanted: MapSet.t(String.t()),
          subscribers: MapSet.t(),
          notice_subscribers: MapSet.t()
        }

  @doc "Starts the ledger under `opts[:name]`, empty."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    Agent.start_link(fn -> nil end, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Records `snapshot` as the intent, without waiting. A ledger that is not running drops it:
  a feed must never be held, or crashed, by its own bookkeeping.
  """
  @spec put(GenServer.name(), snapshot()) :: :ok
  def put(ledger, snapshot), do: Agent.cast(ledger, fn _previous -> snapshot end)

  @doc """
  The last recorded intent, or `nil` when none was recorded or the ledger is not running.
  """
  @spec fetch(GenServer.name()) :: snapshot() | nil
  def fetch(ledger) do
    Agent.get(ledger, & &1, 5_000)
  catch
    :exit, _not_running -> nil
  end
end
