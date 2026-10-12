# DpExchangeGemini

> ## ⚠️ EXPERIMENTAL — read this before depending on it
>
> This package has **never run in production.** It is published early and openly so it
> can be used and reported on, not because it is finished.
>
> - **The API may change without a major version.** Pin three-part (`~> 0.2.106` or later).
> - **Verification is uneven, and the gaps are on the expensive side.** The conformance
>   suite passes against a fake, and against Gemini's live public endpoints.
>   **Order placement and authenticated flows are thinly covered.** No test in this repo
>   spends money.
> - **Maturity is declared per endpoint.** Read `capabilities/0`, not this banner.
>
> [Report a divergence](https://github.com/DistortionPoint/dp-exchange-gemini/issues).

Gemini for the **DpExchange** family: market data, trading and streaming behind the
same facade every venue in the family exposes.

## What this package covers

88 callbacks, of which **64 are declared `:experimental`** and 24 `:unsupported`. None is `:proven` — that requires a consumer trading live, and this package has never run in production (D15).

Placing an order: `place_order(credentials, %{symbol: "BTC-USD", side: :buy, order_type: :limit, time_in_force: :gtc, quantity: Decimal.new("1"), price: Decimal.new("100")}, opts)`. Nothing is defaulted, an unknown request key is refused, and a placement that may have reached the venue is `{:error, {:order_unconfirmed, client_order_id_or_nil, reason}}` - reconcile before placing again. See `usage-rules.md`.

Asset classes: **crypto**. Streamed kinds: **quotes, top of book, trades** (`:trades` is opt-in via `Feed`'s `channels:`) — everything else pulls only.

Of the 24 unsupported endpoints, **22 are the venue's own absence**, not this package's backlog — see `venue_does_not_serve/0` and `docs/reference/gemini/negative-claims.md`, which records the source and date behind every one.

## Installation

```elixir
def deps do
  [
    {:dp_exchange_gemini, "~> 0.2.106"}
  ]
end
```

## Usage

```elixir
# In your supervision tree. Nothing starts itself.
children = [{DpExchange.Gemini, []}]

{:ok, last_trade} = DpExchange.Gemini.get_price("BTC-USD", [])

:ok = DpExchange.Gemini.subscribe(["BTC-USD"], to: self())

# Credentials are an argument to the call that needs them. The child keeps none: they sign
# that one request and are not stored.
{:ok, balances} = DpExchange.Gemini.get_balances(my_credentials(), [])
```

Streamed data arrives in the subscriber's mailbox as `{:dp_exchange, :gemini, payload}`, where
`payload` is a `Quote`, `TopOfBook` or (with `channels: [..., :trades]`) a `Trade`. Link and
data-quality conditions arrive separately, as the same message shape carrying a
`DpExchange.Core.Notice`, to processes that called `DpExchange.Gemini.subscribe_notices/1`.
`Quote.venue_time` and `TopOfBook.venue_time` are `nil` from REST (the venue states no quote
time); `observed_at` states freshness.

`DpExchange.Gemini` is the **entire public API**. Everything else — transport, signing,
session handling, supervision — is internal, and the conformance suite asserts it.

See [`dp_exchange_core`](https://hex.pm/packages/dp_exchange_core) for the contract, and
this package's `usage-rules.md` for what is specific to Gemini.

## License

MIT. See [LICENSE](https://github.com/DistortionPoint/dp-exchange-gemini/blob/main/LICENSE).
