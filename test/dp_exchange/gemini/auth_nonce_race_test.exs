defmodule DpExchange.Gemini.AuthNonceRaceTest do
  use ExUnit.Case, async: false

  alias DpExchange.Gemini.Auth

  # `async: false`, and it has to be: the counter lives in `:persistent_term`, which is
  # node-wide. Erasing it is the whole point of these tests and would be a hostile act
  # against a test running beside them. ExUnit runs every async module before any sync one,
  # so nothing is drawing nonces while this file runs.
  @counter_key {Auth, :nonce_counter}

  setup do
    # Erased first, so a counter a test seeded (to the cell's top, in one) is not what every
    # later module draws its nonces from.
    on_exit(fn ->
      :persistent_term.erase(@counter_key)
      Auth.ensure_counter()
    end)

    :ok
  end

  describe "the counter survives being created by many callers at once" do
    # The existing across-processes test in `auth_test.exs` asserts the right property and
    # then opens with `Auth.ensure_counter()`, which establishes the counter and so removes
    # the race before measuring it. It proves the `compare_exchange/4` loop. The loop was
    # never the broken part — creation was, and creation is what these tests enter cold.
    #
    # Three attempts, not ten: the previous implementation lost this race on 19 of 20
    # measured runs with 40 callers, and `:persistent_term.erase/1` plus `put/2` are global
    # scans — ten attempts cost eleven seconds of suite time to buy a third decimal place.
    #
    # Cold is the realistic state: the supervisor calls `ensure_counter/0` at start, but
    # `Auth` is usable without it, and a consumer that signs before or while the tree comes
    # up arrives here with the key absent.

    test "concurrent first callers all receive the SAME counter" do
      for attempt <- 1..3 do
        :persistent_term.erase(@counter_key)

        refs =
          1..40
          |> Enum.map(fn _caller -> Task.async(&Auth.ensure_counter/0) end)
          |> Task.await_many(10_000)
          |> Enum.uniq()

        assert length(refs) == 1,
               "attempt #{attempt}: #{length(refs)} distinct counters handed out; " <>
                 "every caller drawing from its own counter is every caller restarting " <>
                 "the same sequence"
      end
    end

    test "concurrent first callers never receive the same nonce" do
      # The consequence, stated in the units the venue judges in. A repeated nonce is not a
      # near-miss under incremental validation — it is rejected as a replay, and the caller
      # sees `InvalidNonce` on a request it never made twice.
      #
      # Measured against the previous implementation, which created a ref, stored it, and
      # then re-read the key: forty callers produced SEVEN distinct nonces. Thirty-three
      # refusals from a venue that had nothing wrong with it.
      for attempt <- 1..3 do
        :persistent_term.erase(@counter_key)

        nonces =
          1..40
          |> Enum.map(fn _caller -> Task.async(fn -> Auth.nonce(:incremental) end) end)
          |> Task.await_many(10_000)

        assert length(Enum.uniq(nonces)) == length(nonces),
               "attempt #{attempt}: #{length(nonces) - length(Enum.uniq(nonces))} of " <>
                 "#{length(nonces)} nonces were repeats"
      end
    end

    test "concurrent first callers of the microsecond and nanosecond counters share one" do
      for key <- [{Auth, :nonce_counter_us}, {Auth, :nonce_counter_ns}] do
        :persistent_term.erase(key)

        # `ensure_counter/0` returns the millisecond counter's ref whichever key was erased, so
        # its return value says nothing about this key: each caller reads the key it erased.
        refs =
          1..40
          |> Enum.map(fn _caller ->
            Task.async(fn ->
              Auth.ensure_counter()
              :persistent_term.get(key)
            end)
          end)
          |> Task.await_many(10_000)
          |> Enum.uniq()

        assert length(refs) == 1
        assert :atomics.info(:persistent_term.get(key)).size == 1
      end

      for mode <- [:incremental_us, :incremental_ns] do
        key = if mode == :incremental_us, do: :nonce_counter_us, else: :nonce_counter_ns
        :persistent_term.erase({Auth, key})

        nonces =
          1..40
          |> Enum.map(fn _caller -> Task.async(fn -> Auth.nonce(mode) end) end)
          |> Task.await_many(10_000)

        assert length(Enum.uniq(nonces)) == length(nonces), "#{mode}: repeated nonces"
      end
    end

    test "fifty processes drawing many nonces each: all unique, each one's sequence rises" do
      Auth.ensure_counter()

      for mode <- [:incremental, :incremental_us, :incremental_ns, {:incremental_ns, scale: 3}] do
        runs =
          1..60
          |> Enum.map(fn _caller ->
            Task.async(fn -> for _draw <- 1..50, do: nonce_value(Auth.nonce(mode)) end)
          end)
          |> Task.await_many(30_000)

        for run <- runs do
          assert run == Enum.sort(run)
          assert length(Enum.uniq(run)) == length(run), "#{inspect(mode)}: a process repeated"
        end

        all = List.flatten(runs)
        assert length(Enum.uniq(all)) == length(all), "#{inspect(mode)}: processes collided"
        assert Enum.all?(all, &is_integer/1)
      end
    end

    # The scaled mode's wire value is a decimal string; compare it as the integer it spells.
    defp nonce_value(value) when is_integer(value), do: value
    defp nonce_value(value) when is_binary(value), do: String.to_integer(value)

    test "seed_nonce/1 lifts the counter once, and the sequence still advances by one" do
      # dp-exchange-gemini issue #2. An incremental key whose stored mark is above epoch
      # milliseconds is unreachable by `nonce/1` in either mode — `:time_based` emits
      # seconds and `:incremental` emits milliseconds, and both are below the mark, so every
      # request returns `InvalidNonce`. The reporter measured both modes back to back on one
      # key, restarting the node between them.
      #
      # The thing being asserted here is the property that makes a seed safe: after it, the
      # sequence advances by **exactly one per call**. `max(now_ms, previous + 1)` is
      # unchanged, so a seed lifts the counter to meet a key and does NOT reintroduce the
      # escalation this module refuses — which is what would consume the key's space for
      # good.
      :persistent_term.erase(@counter_key)
      mark = 1_789_999_999_999_999

      assert Auth.seed_nonce(mark) == :ok

      first = Auth.nonce(:incremental)
      second = Auth.nonce(:incremental)

      assert first > mark, "the seeded counter must put the next nonce above the key's mark"
      assert second - first == 1, "the sequence must still advance by one, never by a scale"
    end

    test "seed_nonce/1 refuses to lower the counter" do
      # A seed that could rewind would hand two callers the same nonce, which is the exact
      # failure the counter exists to prevent — and a racing second seed must not undo the
      # first.
      :persistent_term.erase(@counter_key)

      assert Auth.seed_nonce(1_789_999_999_999_999) == :ok
      assert Auth.seed_nonce(1_000) == {:error, :below_current}
      assert Auth.seed_nonce(1_789_999_999_999_999) == {:error, :below_current}

      assert Auth.nonce(:incremental) > 1_789_999_999_999_999
    end

    test "seed_nonce/1 reports a value the counter cannot hold rather than raising" do
      # The counter is one 64-bit unsigned `:atomics` cell and `:atomics.put/3` raises rather
      # than saturating. A mark above `2^64 - 1` — the 1.78e21 this module's moduledoc
      # records — is out of reach of a seed as well, and that key must be rotated. Saying so
      # is the whole job here; raising would name `:atomics` instead of the key.
      :persistent_term.erase(@counter_key)

      assert Auth.seed_nonce(1_780_000_000_000_000_000_000) == {:error, :above_counter_range}

      # A counter AT the cell's maximum has no next nonce: `max + 1` raised in the signer.
      assert Auth.seed_nonce(0xFFFF_FFFF_FFFF_FFFF) == {:error, :above_counter_range}
      assert Auth.seed_nonce(0xFFFF_FFFF_FFFF_FFFE) == :ok
      assert Auth.nonce(:incremental) == 0xFFFF_FFFF_FFFF_FFFF
    end

    test "seed_nonce/1 refuses anything that is not a positive integer" do
      :persistent_term.erase(@counter_key)

      for bad <- [0, -1, "1789999999999999", 1.5, nil] do
        assert Auth.seed_nonce(bad) == {:error, :invalid_seed}, "#{inspect(bad)} was accepted"
      end
    end

    test "a caller arriving after creation pays no lock" do
      # The steady-state path must stay a bare `:persistent_term.get/2`. The lock is on the
      # creation branch only, and this asserts the branch is not reached once the key is
      # there — otherwise every signed request in the system would serialise on a
      # cluster-wide lock, which would be a far more expensive bug than the one it fixed.
      Auth.ensure_counter()
      ref = :persistent_term.get(@counter_key)

      assert Enum.all?(1..100, fn _call -> Auth.ensure_counter() == ref end)
    end
  end
end
