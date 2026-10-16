defmodule DpExchange.GeminiContractTest do
  @moduledoc """
  Core's conformance suite, run against this package. Shipped by `dp_exchange_core` and
  identical across every venue in the family — which is what stops six CLAUDE.md files
  drifting apart.
  """

  # Group 42 drives the real `Private.place_order/3`, which asks the rate limiter before
  # sending; no limiter runs under the contract, so a process-scoped permissive one stands in.
  defmodule ContractLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Gemini,
    fake: DpExchange.Gemini.Fake,
    symbol_format: DpExchange.Gemini.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD BTC-GUSD SOL-RLUSD),
    # Conformance group 41 (family reasons, 2026-10-14): a well-formed symbol the fake does
    # not list, and a credentials map whose first value carries a trailing newline.
    unlisted_symbol: "NOPE-USD",
    padded_credentials: %{api_key: "account-test-key\n", api_secret: "test-secret-not-a-real-key"},
    # `lib/vendor/` is third-party code, a patched websockex fork (see
    # `DpExchange.Gemini.Vendor.WebSockex`). The scanning assertions are written for this
    # family's own conventions, so they read `lib/dp_exchange` only, as Webull's do.
    package_root: "lib/dp_exchange",
    # Conformance group 42: the REAL `Private.place_order/3` (not the fake) against a plug that
    # answers 503 after the request is sent, so the answer must be `:order_unconfirmed`. The
    # contract's default request (`BTC-USD`, `:limit`, `:gtc`, Decimal amounts) is accepted
    # as-is, so no mapping is needed. With `:order_type` deleted the request is refused before
    # signing and never reaches the plug. `retry_attempts: 0` keeps it to one fast attempt.
    ambiguous_place_order: fn request ->
      DpExchange.Core.Config.put_override(
        :rate_limit_module,
        DpExchange.GeminiContractTest.ContractLimiter
      )

      DpExchange.Gemini.Private.place_order(
        %{api_key: "account-test-key", api_secret: "test-secret-not-a-real-key"},
        request,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(503, ~s({"result":"error"}))
        end,
        retry_attempts: 0,
        retry_delay: 1
      )
    end,
    credentials: %{api_key: "account-test-key", api_secret: "test-secret-not-a-real-key"}
end
