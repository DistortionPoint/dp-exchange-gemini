defmodule DpExchange.Gemini.AuthNonceCeilingTest do
  @moduledoc """
  A nonce counter at the top of its 64-bit cell has no next value. It used to surface as a
  raw `:atomics` `ArgumentError` out of the signing caller.

  Not `async`: the counters are node-wide, and these tests park one at the ceiling. Every
  counter used is put back afterwards.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Gemini.Auth

  @ceiling 0xFFFF_FFFF_FFFF_FFFF
  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}

  setup do
    Auth.ensure_counter()
    counter = :persistent_term.get({Auth, :nonce_counter_us})
    previous = :atomics.get(counter, 1)

    on_exit(fn -> :atomics.put(counter, 1, previous) end)

    {:ok, counter: counter}
  end

  # Parks the named counter at `value` for the rest of the test and restores it afterwards.
  defp park(key, value) do
    Auth.ensure_counter()
    counter = :persistent_term.get({Auth, key})
    previous = :atomics.get(counter, 1)
    on_exit(fn -> :atomics.put(counter, 1, previous) end)
    :atomics.put(counter, 1, value)
  end

  defp sign(mode) do
    Auth.headers(:api_key, "/v1/balances", %{}, @credentials, nonce_mode: mode)
  end

  test "headers/5 returns :nonce_exhausted instead of raising", %{counter: counter} do
    :atomics.put(counter, 1, @ceiling)

    assert sign(:incremental_us) == {:error, :nonce_exhausted}
  end

  test "nonce/1 raises an ArgumentError that names the ceiling", %{counter: counter} do
    :atomics.put(counter, 1, @ceiling)

    error = assert_raise ArgumentError, fn -> Auth.nonce(:incremental_us) end

    assert error.message =~ "64-bit ceiling"
    assert error.message =~ Integer.to_string(@ceiling)
  end

  test "the last value below the ceiling is still issued", %{counter: counter} do
    :atomics.put(counter, 1, @ceiling - 2)

    assert Auth.nonce(:incremental_us) == @ceiling - 1
    assert Auth.nonce(:incremental_us) == @ceiling

    assert_raise ArgumentError, fn -> Auth.nonce(:incremental_us) end
  end

  test "the millisecond counter has the same ceiling" do
    park(:nonce_counter, @ceiling)

    assert sign(:incremental) == {:error, :nonce_exhausted}
    error = assert_raise ArgumentError, fn -> Auth.nonce(:incremental) end
    assert error.message =~ "64-bit ceiling"
  end

  test "the millisecond counter issues the last value below its ceiling" do
    park(:nonce_counter, @ceiling - 2)

    assert Auth.nonce(:incremental) == @ceiling - 1
    assert Auth.nonce(:incremental) == @ceiling
    assert_raise ArgumentError, fn -> Auth.nonce(:incremental) end
  end

  test "the nanosecond counter has the same ceiling" do
    park(:nonce_counter_ns, @ceiling)

    assert sign(:incremental_ns) == {:error, :nonce_exhausted}
    assert_raise ArgumentError, fn -> Auth.nonce(:incremental_ns) end
  end

  test "the nanosecond counter issues the last value below its ceiling" do
    park(:nonce_counter_ns, @ceiling - 2)

    assert Auth.nonce(:incremental_ns) == @ceiling - 1
    assert Auth.nonce(:incremental_ns) == @ceiling
    assert_raise ArgumentError, fn -> Auth.nonce(:incremental_ns) end
  end

  test "the scaled mode draws from the nanosecond counter and shares its ceiling" do
    mode = {:incremental_ns, scale: 5}
    park(:nonce_counter_ns, @ceiling - 1)

    assert Auth.nonce(mode) == Integer.to_string(@ceiling * 100_000)
    assert sign(mode) == {:error, :nonce_exhausted}
  end
end
