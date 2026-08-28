defmodule DpExchange.GeminiContractTest do
  @moduledoc """
  Core's conformance suite, run against this package. Shipped by `dp_exchange_core` and
  identical across every venue in the family — which is what stops six CLAUDE.md files
  drifting apart.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Gemini,
    fake: DpExchange.Gemini.Fake,
    symbol_format: DpExchange.Gemini.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD BTC-GUSD SOL-RLUSD),
    credentials: %{api_key: "account-test-key", api_secret: "test-secret-not-a-real-key"}
end
