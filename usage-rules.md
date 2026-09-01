# Using `dp_exchange_gemini`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Gemini**.

## Start it, and it brings its own rate limiter

```elixir
children = [{DpExchange.Gemini, []}]
```

The venue supervises a limiter configured from the ceilings it declares. That is not a
convenience: `Core.HttpClient` fails closed when no limiter is reachable, so a venue
package that expected someone else to start one answers `{:error, "Rate limiter
unavailable"}` to everything.

Running two — two credentials, two scopes — needs distinct names:

```elixir
[{DpExchange.Gemini, name: :gem_a, feed: :gem_a_feed, limiter: :gem_a_limiter},
 {DpExchange.Gemini, name: :gem_b, feed: :gem_b_feed, limiter: :gem_b_limiter}]
```

## Seven candle widths, and the venue's own documentation names three of them wrong

Canonical widths this package serves: **`1m 5m 15m 30m 1h 6h 1d`**. The shared vocabulary
also models `2h`, `4h` and `12h`; Gemini serves none of them, and asking is an error
rather than the nearest width.

You will find Gemini's documentation listing `1h`, `6h` and `1d` as the literals to send.
**All three are rejected by the API.** The real literals are `1hr`, `6hr` and `1day`, and
this package sends those — you pass the canonical form and never see this. Measured
2026-08-28; the venue names its own accepted set in the 400 body:

```
time_frame expects one of the following: [1m, 5m, 15m, 30m, 1hr, 6hr, 1day]
```

## The candle window is fixed, and your range bounds do not reach the venue

Gemini's candles endpoint **ignores `start`, `end` and `limit` entirely** — three requests
differing only in those returned byte-identical responses. Each width serves a fixed
window:

| Width | Bars | ≈ span |
|---|---|---|
| `1m` | 1440 | 1 day |
| `5m` | 2015 | 7 days |
| `15m` | 1343 | 14 days |
| `30m` | 1439 | 30 days |
| `1h` | 1463 | 61 days |
| `6h` | 367 | 92 days |
| `1d` | 364 | 1 year |

This package filters to your range client-side, and **refuses a range that starts before
the window can reach**:

```elixir
{:error, {:range_unavailable, "1d", earliest: ~U[...], requested: ~U[...]}}
```

Rather than handing back the 364 bars it happens to hold, which would read as a complete
answer for a period the venue does not serve.

**There is nothing to paginate.** `max_candles_per_request` is `nil`, not a number — one
call is the whole history the venue offers at that width. Do not build a paging loop.

## A quote's timestamp is the venue's HTTP `Date`, and without it the call fails

Neither Gemini ticker publishes a quote timestamp. `/v1/pubticker` has one, but it sits
**inside the `volume` object** — it stamps the 24-hour volume window and lags about a
minute. `/v2/ticker` has none at all.

This package uses the venue's `Date` response header, and returns
`{:error, :missing_venue_timestamp}` when it is absent. It never substitutes the local
clock, which is what makes a stale quote indistinguishable from a live one.

If you need sub-second freshness, use `subscribe/2` — the stream carries a real
nanosecond event time per update.

## The demo environment is one option, on both transports

Gemini runs a full exchange with test funds — bots make the order book, and a new account
is credited $100,000 USD, 1,000 BTC and 20,000 each of ETH, BCH, ZEC and LTC.

```elixir
children = [{DpExchange.Gemini, environment: :sandbox}]

{:ok, quote} = DpExchange.Gemini.get_price("BTC-USD", environment: :sandbox)
```

REST and the WebSocket both follow it. To set it once for a process tree instead of per
call, use `DpExchange.Core.Config` — it resolves per **process**, so one async test can
point at demo without redirecting the tests beside it.

| | Production | Demo |
|---|---|---|
| REST | `api.gemini.com` | `api.sandbox.gemini.com` |
| WebSocket | `ws.gemini.com` | `ws.sandbox.gemini.com` |

**Note if you read Gemini's market-data page**: it names `exchange.sandbox.gemini.com` as
the sandbox base URL. That is the website — API calls there 404. `api.sandbox` is correct.

**`:production` is the default and a typo raises.** `environment: :sandox` is an
`ArgumentError`, not a quiet fallback, because the failure is asymmetric: meaning demo and
getting production sends a real order to a real exchange.

**The demo book is frequently crossed.** A frame captured 2026-08-28 carried bid
`68169.88` against ask `64886.32`. Spreads computed against demo data go negative. Use the
demo environment to exercise code paths, not to validate anything price-dependent.

## Run both at once — that is the expected case, not a workaround

Live trading against production while strategies are tested against demo, in one node:

```elixir
children = [
  {DpExchange.Gemini, environment: :production},
  {DpExchange.Gemini, environment: :sandbox}
]
```

**Nothing needs naming.** The supervisor, feed and limiter all derive default names from
the environment, so the two trees neither collide nor share anything:

| | Production | Demo |
|---|---|---|
| Supervisor | `DpExchange.Gemini.Supervisor` | `DpExchange.Gemini.SandboxSupervisor` |
| Feed | `DpExchange.Gemini.Feed` | `DpExchange.Gemini.SandboxFeed` |
| Limiter | `DpExchange.Gemini.RateLimiter` | `DpExchange.Gemini.SandboxRateLimiter` |

**The separate limiters matter more than the separate names.** They are two venues with
two budgets. Sharing one bucket means demo strategy testing spends the budget live trading
depends on — and you find out when a real order gets a 429, at an arbitrary later moment,
with nothing pointing back at the demo traffic that caused it.

Address a specific tree by naming it:

```elixir
:ok = DpExchange.Gemini.subscribe(["BTC-USD"], feed: DpExchange.Gemini.SandboxFeed, to: self())
{:ok, q} = DpExchange.Gemini.get_price("BTC-USD", environment: :sandbox)
```

Explicit `:name` / `:feed` / `:limiter` still win, for running two of the *same*
environment with different credentials or scopes.

### Per-process selection, for mixed workloads

If a whole process tree should be on demo — a strategy runner, say — set it once instead
of threading the option through every call:

```elixir
DpExchange.Core.Config.put_override(:environment, :sandbox)
```

This resolves **per process** and walks `$callers`, so the strategy runner and everything
it spawns go to demo while the trading path beside it stays on production. It is not a
global switch, and it will not redirect your live path.

## This package does not handle authentication — you do

It **signs** a request when you hand it credentials and tell it which scheme you chose. It
never obtains, stores, refreshes, or infers one, and it has no default scheme.

That is a boundary, not a gap. Gemini offers two authentication types and they are not two
spellings of one thing:

- **API key** — a pair you provision in Settings. Signing is a pure function, so this
  package can do it on request.
- **OAuth 2.0** — an authorization-code flow: register an application, fix its client type
  permanently, redirect *users* to approve scopes, handle the callback, do PKCE for public
  clients, and refresh a 24-hour access token forever after.

Which one your application uses is a decision about your users and your deployment. A
market-data package is not entitled to make it for you, and could not implement the second
one anyway — it has no browser, no redirect URI and nowhere safe to keep a refresh token.

**Every authenticated endpoint here returns `{:error, :not_supported}`.** Balances,
orders, fees, transfers and trade history are yours to implement against your own auth.
The demo environment is what makes doing that safe.

If you do use the signing helper, name the scheme; it refuses to guess:

```elixir
{:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, credentials)
{:ok, headers} = Auth.headers(:oauth, "/v1/balances", %{}, %{access_token: token})
```

Guessing would be actively harmful: Gemini returns `AmbiguousAuthentication` (400) when V1
key headers and OAuth headers arrive on the same request.

## Your API key's nonce mode is something only you know

Gemini provisions keys in one of two validation modes, and they need differently-shaped
nonces:

| Mode | Nonce | Ordering |
|---|---|---|
| **Time-based** (venue's recommendation) | Unix **seconds**, within ±30 s of server time | none required |
| **Incremental** | monotonically increasing (ms or a sequential integer) | strictly higher each request |

**No single value satisfies both**, and the venue exposes no way to ask how a key was
made. The default here is `:time_based`; pass `nonce_mode: :incremental` if that is your
key:

```elixir
DpExchange.Gemini.get_balances(credentials, nonce_mode: :incremental)
```

A mismatch fails loudly on the first request with `InvalidNonce` — a 400, not a wrong
answer.

Note that a seconds-granularity nonce on an *incremental* key caps that key at **one
request per second**, which is 1/600th of the private ceiling. That is why the mode is
not something this package can paper over.

## Symbols are lowercase and separatorless, and the split is not obvious

Native form is `btcusd`, `aavegusd`, `jitosolsol`. Canonical is `BASE-QUOTE`. Pass
canonical; this package converts both ways.

Worth knowing if you do any symbol handling of your own: **157 of the 346 live symbols end
in a quote currency that is a suffix of another quote currency** — `GUSD` and `RLUSD` both
end in `USD`. A naive split on `USD` turns `aavegusd` into `AAVEG`/`USD`, and `AAVEG` is
not an asset. It matches no catalogue entry and collects nothing, silently.

The quote list, longest-first: `RLUSD USDC USDT GUSD USD EUR GBP SGD DAI BTC ETH SOL FIL`.

**Perpetuals are excluded** from `get_symbols/1`. Thirteen symbols carry a `perp` suffix;
they are real instruments but not spot pairs, and this package declares
`supported_instrument_types: [:spot]`.

## What this package does not do

Authenticated endpoints — covered above: the host authenticates, so balances, orders,
fees, transfers and trade history all return `{:error, :not_supported}`.

`list_instruments/1` is also `:unsupported`, for a different reason: 346 symbols and no
bulk detail endpoint means one request per symbol, which is not a listing, it is a
rate-limit incident. Use `get_symbols/1` for the catalogue and `quantization/1` for one
symbol's increments.

## Two session behaviours this package deliberately leaves to you

- **Requires Heartbeat** is a per-key setting. If enabled and no authenticated request or
  heartbeat arrives for 30 seconds, Gemini **cancels every open order for that session**.
- The WebSocket API offers `cancelOnDisconnect=true` with the same effect on socket loss.

Neither is enabled here. Both are risk decisions about your money, and a package that
switched one on for you would be making them on your behalf.

## Rate limits come from the venue, including the burst

| | Limit | Burst |
|---|---|---|
| Public | 120 / minute | 5 |
| Private | 600 / minute | 5 |

Read from Gemini's own rate-limit page, not inferred. Separate buckets, because they
differ 5×. Gemini also publishes a *recommended* rate of half each ceiling; this package
declares the enforced ceilings and does not silently apply the recommendation — if you
want to be politer than required, say so.

**Gemini publishes no rate-limit headers.** Measured: no `x-ratelimit-*`, no `cb-*`, no
`retry-after`. `get_rate_limit_status/2` is `:unsupported` rather than returning a
constant that never moves.

## Perpetuals: a short is a positive size with a side

`get_positions/1` reads `/v1/positions`. **Gemini sends a negative quantity for a short and
this package will not pass it through**: `:quantity` is the size and `:side` says which way.
A sign convention is a fact about one venue's JSON, not about the market, and a caller
handed a raw negative has a position that is exactly backwards while every number in it
stays plausible.

`notional_value` **keeps** its sign — that one is a value, not a magnitude with a direction
beside it.

**`liquidation_price` is `nil` here, and that is not safety.** `/v1/positions` publishes
none; `get_account_margin/1` carries `estimated_liquidation_price` for the account, and that
is where a caller judging room reads.

**Settled and estimated funding are different facts.** A real response carries `-1.50991`
beside `-2.10595` — 40% apart — so `get_funding/2` keeps `:amount` and `:estimated_amount`
separate, and the sign is carried through unchanged because it means direction between longs
and shorts.

**Mark, index and last trade are three prices.** `get_contract_stats/2` gives the first two;
`get_price/2` gives the third. A position can be liquidated at a mark the market never
printed, which is why they are not one field.

## Staking: read the unit before you read the number

Gemini publishes `rate` in **basis points**, `ratePct` as a percentage and `apyPct`
annualised — three numbers for one position, differing by 100× and by compounding.
`get_staking_rates/1` returns **percentages only**, both named, and **never derives
`:apy_pct` from `:rate_pct`**: that needs a compounding frequency the venue did not state.

**A staked position is three amounts.** The real shape is `balance: 10`, `available: 0`,
`availableForWithdrawal: 10` — redeemable in full, tradable not at all. Read one "available"
and you will size an order against ten and place it against zero.

**An unstake returns before it completes.** `:amount_remaining` is non-zero for as long as
the asset is unbonding; treating the return value as settled spends an asset you do not have
yet.

`provider_id` is **required** on `stake/3` and `unstake/3`. The same asset stakes with
several providers at different rates, and this package will not pick one for you.

## Clearing is not the order book

A clearing order is one half of a trade agreed with a named counterparty and **does nothing
until that counterparty confirms**. Read `is_confirmed`, not `status`.

`confirm_clearing_order/3` **re-states every term** — symbol, amount, price, side — and this
package fills none of them in from the order being confirmed. That is the whole point of the
check: reading them back from the venue would confirm whatever the venue had.

The broker form names **both** counterparties and `side` belongs to the *source*. Passing the
two the wrong way round produces a valid order in which each side trades the direction the
other meant.

## Administration: the name you send is not the name you address by

`create_account/1` takes a display name and the venue answers with a kebab-cased
**shortname** — and that shortname is what every other endpoint's `account` parameter takes.
Keep what came back, not what you sent.

`list_accounts/1` **caps at 500 and does not paginate.** A larger group comes back truncated
with nothing to say it was; there is no cursor to follow.

`get_roles/1` answers with three booleans rather than one role, because `Fund Manager` and
`Trader` combine and `Auditor` combines with nothing.

## OAuth: refreshing rotates the refresh token

`refresh_access_token/3` posts a **form** to `exchange.gemini.com/auth/token` — a different
host from every other call here, and the same URL your own initial code exchange posts to,
separated only by `grant_type`.

**The response carries a new refresh token and the old one stops working.** Store both. A
caller that keeps only the access token has a session that ends at the next refresh.

`revoke_access_token/1` needs an OAuth token and refuses an API key: an API-key-signed call
there would revoke nothing and come back shaped like success.

## The spreadsheet reports are bytes

`funding_amount_report/2` and `funding_payment_report_file/1` return the venue's file
unparsed. This package ships no spreadsheet reader and will not grow one: a parsed cell is a
number this package chose from a layout the venue can change without notice.

`from` and `to` must be given **together or not at all** — the venue makes each mandatory if
the other is present, and one alone comes back bounded by `numRows` instead, which is a real
report over the wrong window.

## Every negative here is audited

`docs/reference/gemini/negative-claims.md` lists each one with the source and date consulted.
This venue is also where the family learned that **positives go stale too** — a socket URL
the vendor still published had stopped working, and only a live check said so.
