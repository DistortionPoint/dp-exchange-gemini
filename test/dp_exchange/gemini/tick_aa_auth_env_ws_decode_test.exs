defmodule DpExchange.Gemini.TickAAAuthEnvWsDecodeTest do
  @moduledoc """
  Tick AA: the lines of `Auth`, `Environment` and `WsDecode` the full suite never ran.

  Not `async`: the `Auth` tests erase the node-wide millisecond nonce counter, hold its
  creation lock, and suspend `:global_name_server` for the moment it takes to place a
  counter under a caller that is queued for that lock. ExUnit runs every async module
  before any sync one, so nothing else is drawing nonces while this file runs. The counter
  is erased and re-established after each `Auth` test, as `AuthNonceRaceTest` does.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Auth, Environment, WsDecode}

  @counter_key {Auth, :nonce_counter}
  @ns 1_787_936_147_000_000_000

  describe "Auth: creating the counter" do
    setup do
      Auth.ensure_counter()

      on_exit(fn ->
        :persistent_term.erase(@counter_key)
        Auth.ensure_counter()
      end)

      :ok
    end

    test "a caller that got the lock after the winner stored a counter takes the winner's" do
      # `create_counter/1` re-checks the key INSIDE the lock: a caller that read `nil` before
      # the lock and acquires it after the winner stored a ref must return that ref, not
      # create a second one (the original bug: two counters, one restarted sequence, repeated
      # nonces). The caller is held between its read and its lock by suspending the server
      # that grants the lock, and the winner's ref is stored while it waits there.
      :persistent_term.erase(@counter_key)
      server = Process.whereis(:global_name_server)
      winner = :atomics.new(1, signed: false)

      :ok = :sys.suspend(server)

      task =
        try do
          task = Task.async(&Auth.ensure_counter/0)
          await_lock_request(server, task.pid, 0)
          :persistent_term.put(@counter_key, winner)
          task
        after
          :sys.resume(server)
        end

      assert Task.await(task, 10_000) == winner
      assert :persistent_term.get(@counter_key) == winner
    end

    test "a caller that waited out a lock nobody filled creates the counter itself" do
      # The holder of the creation lock went away without storing a counter. A caller that
      # found the lock taken polls for `@counter_wait_ms` (5 s) and then creates the counter
      # itself, rather than waiting forever on a ref that is never coming.
      :persistent_term.erase(@counter_key)
      lock = {@counter_key, self()}

      assert :global.set_lock(lock, [node()], 0)

      task = Task.async(&Auth.ensure_counter/0)
      await_polling(task.pid, 0)

      assert :global.del_lock(lock, [node()])

      ref = Task.await(task, 30_000)

      assert :persistent_term.get(@counter_key) == ref
      assert is_integer(Auth.nonce(:incremental))
    end

    test "concurrent seeds settle on the highest; a loser re-reads, never overwrites" do
      # `raise_counter/2` is a compare-and-exchange loop: a seed that loses the exchange to
      # another re-reads and tries again (or reports `:below_current`), never overwriting a
      # higher value with its own. Forty processes seeding interleaved values must leave the
      # counter at the highest of them, and the next nonce one above it.
      :persistent_term.erase(@counter_key)
      Auth.ensure_counter()

      base = 1_789_999_999_999_999
      writers = 40
      per_writer = 100

      results =
        1..writers
        |> Enum.map(fn writer ->
          Task.async(fn ->
            for step <- 0..(per_writer - 1), do: Auth.seed_nonce(base + step * writers + writer)
          end)
        end)
        |> Task.await_many(30_000)
        |> List.flatten()

      assert Enum.all?(results, &(&1 in [:ok, {:error, :below_current}]))
      assert :ok in results

      highest = base + writers * per_writer
      assert :atomics.get(:persistent_term.get(@counter_key), 1) == highest
      assert Auth.nonce(:incremental) == highest + 1
    end
  end

  describe "Environment.resolve/0" do
    test "is resolve([]): production by default, the process-scoped setting otherwise" do
      assert Environment.resolve() == :production

      Config.put_override(:environment, :sandbox)

      assert Environment.resolve() == :sandbox
    end
  end

  describe "WsDecode: the id and decimal shapes a frame can carry" do
    @trade %{"E" => @ns, "p" => "3610.85", "q" => "0.27413495", "m" => true}

    test "a trade id sent as a string is kept as that string" do
      assert {:ok, trade} = WsDecode.to_trade(Map.put(@trade, "t", "5335307668"), "BTC-USD")
      assert trade.id == "5335307668"
    end

    test "a price or size present as JSON null is a missing field, not an invalid one" do
      assert WsDecode.to_trade(%{@trade | "q" => nil}, "BTC-USD") ==
               {:error, {:missing_required_field, :quantity}}

      assert WsDecode.to_trade(%{@trade | "p" => nil}, "BTC-USD") ==
               {:error, {:missing_required_field, :price}}

      assert WsDecode.traded_price(nil) == :error
    end

    test "an integer size or price reads as that integer" do
      assert {:ok, trade} = WsDecode.to_trade(%{@trade | "q" => 2, "p" => 3610}, "BTC-USD")
      assert Decimal.equal?(trade.quantity, 2)
      assert Decimal.equal?(trade.price, 3610)

      assert {:ok, price} = WsDecode.traded_price(42)
      assert Decimal.equal?(price, 42)

      # Zero is not a traded price (family rule MD6), as an integer as much as a string.
      assert WsDecode.traded_price(0) == :error
    end

    test "a Decimal is accepted, and bounded like every other shape" do
      assert {:ok, price} = WsDecode.traded_price(Decimal.new("3610.85"))
      assert Decimal.equal?(price, Decimal.new("3610.85"))

      assert WsDecode.traded_price(Decimal.new("1E+999")) == :error
      assert WsDecode.traded_price(Decimal.new("NaN")) == :error
      assert WsDecode.traded_price(Decimal.new("Infinity")) == :error
    end

    test "a boolean, object or array where a number belongs is refused, never read" do
      for bad <- [true, %{"v" => "1"}, ["1"]] do
        assert WsDecode.traded_price(bad) == :error, "#{inspect(bad)} was read as a price"

        assert WsDecode.to_trade(%{@trade | "q" => bad}, "BTC-USD") ==
                 {:error, {:invalid_decimal, :quantity, bad}}
      end
    end
  end

  # Polls the suspended lock server's queue until `caller`'s `set_lock` request is in it,
  # which is the point at which `caller` has read the key absent and is waiting for the lock.
  defp await_lock_request(_server, caller, waited) when waited >= 5_000 do
    flunk("#{inspect(caller)} never queued its lock request")
  end

  defp await_lock_request(server, caller, waited) do
    {:messages, messages} = Process.info(server, :messages)

    if Enum.any?(messages, &lock_request_from?(&1, caller)) do
      :ok
    else
      Process.sleep(1)
      await_lock_request(server, caller, waited + 1)
    end
  end

  defp lock_request_from?({:"$gen_call", {from, _tag}, {:set_lock, _id}}, caller),
    do: from == caller

  defp lock_request_from?(_message, _caller), do: false

  # Polls until `pid` is inside `await_counter/2`'s one-millisecond sleep: it has found the
  # lock taken and is waiting for a counter to appear.
  defp await_polling(pid, waited) when waited >= 5_000 do
    flunk("#{inspect(pid)} never started waiting for the counter")
  end

  defp await_polling(pid, waited) do
    case Process.info(pid, :current_function) do
      {:current_function, {Process, :sleep, 1}} ->
        :ok

      _other ->
        Process.sleep(1)
        await_polling(pid, waited + 1)
    end
  end
end
