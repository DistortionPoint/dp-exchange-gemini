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
    # `lib/vendor/` is third-party code, a patched websockex fork (see
    # `DpExchange.Gemini.Vendor.WebSockex`). The scanning assertions are written for this
    # family's own conventions, so they read `lib/dp_exchange` only, as Webull's do.
    package_root: "lib/dp_exchange",
    credentials: %{api_key: "account-test-key", api_secret: "test-secret-not-a-real-key"}
end
