# The demo environment (sandbox) — reference

**Source**: `https://developer.gemini.com/get-started/sandbox`. **Read and measured
2026-08-28.**

Gemini runs a full parallel exchange with test funds. It matters more here than a sandbox
usually does, because it is the difference between a consumer testing its trading
integration and a consumer hoping.

> Gemini's demo environment (sandbox) provides full exchange functionality with test
> funds. Automated bots simulate order book activity and trading.

## The URLs

| Service | Production | Demo |
|---|---|---|
| REST | `https://api.gemini.com` | `https://api.sandbox.gemini.com` |
| WebSocket | `wss://ws.gemini.com` | `wss://ws.sandbox.gemini.com` |
| Website | `https://exchange.gemini.com` | `https://exchange.sandbox.gemini.com` |

### A third documentation defect, in the same shape as the other two

Gemini's **market-data** page names the sandbox base URL as
`exchange.sandbox.gemini.com`. That is the **website**. Measured the same day:

```
GET https://exchange.sandbox.gemini.com/v1/symbols  → 404   (an HTML page)
GET https://api.sandbox.gemini.com/v1/symbols       → 200   (391 symbols)
```

The get-started page is right and the market-data page is wrong. A consumer following the
market-data page gets 404s that read like a broken endpoint rather than a wrong host —
and would plausibly conclude the sandbox does not serve market data at all.

Three documentation defects on this venue in one day, all of the same kind: **the page is
close, and close is indistinguishable from correct until something is measured.** That is
why every URL and enum in this package is measured rather than copied.

## What the demo environment gives an account

Automatically credited on registration:

| Asset | Balance |
|---|---|
| USD | 100,000 |
| BTC | 1,000 |
| ETH | 20,000 |
| BCH | 20,000 |
| ZEC | 20,000 |
| LTC | 20,000 |

Only **Bitcoin Testnet** deposits and withdrawals are supported; nothing else moves in or
out. No email notifications are sent. 2FA is on by default and can be bypassed for
automated testing by setting `GEMINI-SANDBOX-2FA=true` as a cookie or header and entering
`9999999` as the code — a venue instruction, recorded for completeness, and nothing this
package does.

## What this package does with it

One option, on both transports:

```elixir
children = [{DpExchange.Gemini, environment: :sandbox}]

{:ok, quote} = DpExchange.Gemini.get_price("BTC-USD", environment: :sandbox)
```

Or once per process tree via `DpExchange.Core.Config`, which resolves per **process** — so
one async test can point at demo without redirecting the tests running beside it.

**`:production` is the default and an unknown value raises.** A typo like
`environment: :sandox` must not quietly resolve to production, because the failure is
asymmetric: meaning demo and getting production sends a real order to a real exchange,
while meaning production and getting demo gives obviously-wrong prices. One is silent and
expensive; the other is loud and free.

## Verified against the live demo environment, 2026-08-28

| What | Result |
|---|---|
| `/v1/symbols` | 200, **391 symbols** — more than production's 346 |
| `/v1/pubticker/btcusd` | 200, same shape as production |
| `/v1/book/btcusd` | 200, same shape |
| `/v2/candles/BTCUSD/1day` | 200, same shape |
| `wss://ws.sandbox.gemini.com` | 101, `{"id":1,"status":200}` ack, `bookTicker` frames field-for-field identical to production |

The tier-2 suite asserts all of these, including that production and demo return
**different prices** — because if they ever matched, the environment option would be doing
nothing and every other demo test would be passing for the wrong reason.

## The demo book is crossed, and that is not a bug to fix

A `bookTicker` frame captured 2026-08-28:

```json
{"s":"btcusd","b":"68169.88000","a":"64886.32000","c":"68169.88000"}
```

**Bid 68,169.88 against ask 64,886.32** — the bid is 3,283 above the ask. A real venue
never shows this; it is what bots making a synthetic book look like.

Recorded because a consumer computing a spread against demo data will get negatives, and
this is the cheapest possible place to discover that. This package does not correct it,
reorder it, or filter it: the venue said it, and inventing a plausible book on top of an
implausible one is the substitution this family exists to refuse. What the demo
environment is good for is **exercising code paths** — parsing, sequencing, ordering,
error handling — not for anything that depends on prices being sane.

## What this package still does not do there

**It does not authenticate**, in demo or production. It **signs**: credentials arrive as
arguments, are used for one request, and are not kept. Obtaining a credential, storing it,
refreshing it, and choosing between the API-key and OAuth schemes remain the host's, in
either environment.

This section read "every endpoint requiring a credential is declared `:unsupported` here
regardless of environment" until 2026-09-06, and that had stopped being true: balances,
orders, transfers, trade history, staking, clearing, the perpetuals surface and account
administration are all implemented and declared `:experimental`. What is `:unsupported` is
the venue's own absence (see `negative-claims.md`) plus three not-yet-ported endpoints —
never the authenticated surface as a whole.

So what the demo environment changes is that a consumer can exercise its **whole** trading
integration — placing, cancelling and reconciling orders against real venue machinery with
fake money — before a single real order, using this package for the calls as well as for
market data and streaming.

## Running both at once

A consumer trading live while testing strategies against demo is running **two of this
venue in one node**. That is the expected arrangement, so every default name derives from
the environment:

| | Production | Demo |
|---|---|---|
| Supervisor | `DpExchange.Gemini.Supervisor` | `DpExchange.Gemini.SandboxSupervisor` |
| Feed | `DpExchange.Gemini.Feed` | `DpExchange.Gemini.SandboxFeed` |
| Limiter | `DpExchange.Gemini.RateLimiter` | `DpExchange.Gemini.SandboxRateLimiter` |

```elixir
children = [
  {DpExchange.Gemini, environment: :production},
  {DpExchange.Gemini, environment: :sandbox}
]
```

Taking this case seriously found two defects that a "sandbox works" test would have
missed entirely, because each needs *both* environments live at once to appear:

**A name collision**, which is loud. One shared set of defaults means the second tree
fails to start, so the arrangement is simply unavailable.

**A shared rate-limit bucket**, which is silent and is the one that matters. A REST call
carrying `environment: :sandbox` but no `:limiter` metered against the **production**
bucket, because the default limiter name was environment-blind. Strategy testing against
demo would spend the budget live trading depends on — and the symptom is a 429 on a real
order at an arbitrary later moment, with nothing connecting it to the demo traffic that
caused it. Production and demo are two venues with two budgets, and the limiter names now
say so.

Finer-grained mixing goes through `DpExchange.Core.Config`, which resolves per **process**
and walks `$callers`: a strategy runner and everything it spawns can be on demo while the
trading path beside it stays on production. It is not a global switch.
