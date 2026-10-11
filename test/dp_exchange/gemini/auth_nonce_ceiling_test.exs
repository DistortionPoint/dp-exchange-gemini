defmodule DpExchange.Gemini.AuthNonceCeilingTest do
  @moduledoc """
  A nonce counter at the top of its 64-bit cell has no next value. It used to surface as a
  raw `:atomics` `ArgumentError` out of the signing caller.

  Not `async`: the counters are node-wide, and this test parks one at the ceiling. The
  microsecond counter is the one used, and its value is put back afterwards.
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

  test "headers/5 returns :nonce_exhausted instead of raising", %{counter: counter} do
    :atomics.put(counter, 1, @ceiling)

    result =
      Auth.headers(:api_key, "/v1/balances", %{}, @credentials, nonce_mode: :incremental_us)

    assert result == {:error, :nonce_exhausted}
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
end
