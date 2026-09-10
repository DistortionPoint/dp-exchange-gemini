# Using `dp_exchange_gemini`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Gemini**.


## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. Requires `dp_exchange_core ~> 0.2.1`.

```elixir
# before
quote.timestamp

# after
quote.venue_time  # may be nil — the venue did not date this
quote.observed_at # always present
```

**Why it had to break.** `:timestamp` was documented as the venue's own, "never invented",
and two packages in this family could not keep that promise: the frames they decode carry no
venue time at all. With one field their only options were to lie or to drop real data, and
they lied. Now they can say `nil` and mean it.

**What to do with `nil`.** Whatever you would have done with a wrong answer, but knowingly.
The consumer who decided this design stores `venue_time` as their time-series point time
where it is present, and where it is `nil` stores `observed_at` **and records that they
did** — so a mis-bucketed value is attributable rather than invisible. That decision was not
expressible before, because there was no way to see which kind of time you had.

`Trade`, `Fill`, `Balance` and `OrderBookDelta` are **unchanged** — they keep a single
`:timestamp`, because every one of them is built from a venue-supplied time and fails closed
without it.

Full reasoning and the options that were weighed:
[`dp_exchange_core` issue #31](https://github.com/DistortionPoint/dp-exchange-core/issues/31).

## Start it, and it brings its own rate limiter

```elixir
children = [{DpExchange.Gemini, []}]
```

The venue supervises a limiter configured from the ceilings it declares. That is not a
convenience: `Core.HttpClient` fails closed when no limiter is reachable, so a venue
package that expected someone else to start one answers
`{:error, {:exchange_error, :gemini, "Rate limiter unavailable"}}` to everything —
`:gemini_private` on the authenticated calls, which meter against their own bucket.

Running two — two credentials, two scopes — needs distinct names:

```elixir
[{DpExchange.Gemini, name: :gem_a, feed: :gem_a_feed, limiter: :gem_a_limiter},
 {DpExchange.Gemini, name: :gem_b, feed: :gem_b_feed, limiter: :gem_b_limiter}]
```

## A socket crash costs one reconnect, never your whole subscription

The one socket this venue uses is a **linked** child of `Feed` — not a supervised
sibling you can restart independently. As of this version `Feed` traps exits, so the
socket dying abnormally no longer takes `Feed` down with it: `coverage/1` and
`coverage_by_kind/1` clear (this venue has one socket carrying both streamable kinds, so
a crash costs both, not a partial set), you get a `:link_down` `Core.Notice`, and this
package reconnects and resends your `wanted` symbols on its own, immediately, without
you calling `subscribe/3` again.

**What still costs you your whole subscription: `Feed` itself crashing** — a bug outside
the socket-crash path, or anything that kills the `Feed` pid directly.
`DpExchange.Gemini.Supervisor` restarts `Feed` under `:one_for_one`, but from the
*static* `opts` your supervision tree started it with; every `subscribe/3`,
`update_symbols/2` and `subscribe_notices/1` call you made afterward is gone; `coverage/1`
reads empty until you call `subscribe/3` again. Nothing inside this package can replay
those calls — it never held onto the functions or the process that made them. If your
consumer needs to survive a `Feed` restart unattended, monitor the `Feed` pid (or the
`DpExchange.Gemini` pid it sits under) yourself and re-issue `subscribe/3` on `:DOWN`.

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

## A 404 on a market-data call is a refusal, not a retryable error

Measured live 2026-09-06: `GET /v1/pubticker/{symbol}` and `GET
/v1/fundingamount/{symbol}` both answer **404** for a symbol the venue does not carry —
`/v1/pubticker` names it in plain text (`'X' does not have available data yet`),
`/v1/fundingamount` with an empty body. Every symbol-scoped read in this package
(`get_price/2`, `get_top_of_book/2`, `get_historical_prices/4`, `get_order_book/2`,
`get_trades/2`, `get_funding/2`, `next_funding_timestamp/2`, `get_contract_stats/2`,
`quantization/1`) treats that 404 the same as the 400 the venue uses elsewhere for the
same fact: `{:refused, reason}`, permanent for the symbol as given, not
`{:error, {:exchange_error, …}}`, which this family reserves for a failure worth retrying.

Where the venue's refusal body is not JSON at all — measured on `/v2/candles`'s 400,
plain text rather than the usual `{"reason": …}` shape — the text itself is the reason:
`{:refused, {:unknown_reason, "Supplied value 'X' is not a valid symbol"}}`, not a bare
`{:refused, :refused}` that throws the venue's own words away.

### A refusal carries the venue's sentence, not only its category

Three shapes, and each means something different:

```elixir
{:refused, {:invalid_nonce, "Nonce '1757…' has not increased since your last call"}}
{:refused, :invalid_symbol}
{:refused, {:unknown_reason, "SomethingNewGeminiAdded"}}
```

- **`{reason, message}`** — the venue named a category *and said more*. Match on `reason`;
  log the `message`, because on some refusals it is the entire diagnosis.
- **`reason` alone** — the venue named a category and stopped. There is no `nil` message to
  test for.
- **`{:unknown_reason, word}`** — nothing here recognises the word, so the word is the
  diagnosis. Unchanged.

**`InvalidNonce` is the one to handle deliberately.** The atom tells you the category; the
message tells you which of two opposite remedies you need. If the venue's stored high-water
nonce is above what you send, send larger ones — Gemini compares nonces as arbitrary-
precision integers, so a key poisoned near `2^64` needs values above it. If the mark has
climbed past anything you can emit, only rotating the key fixes it, and that is a human
action. Both are `:invalid_nonce`; only the sentence separates them.

This changed in response to dp-exchange-gemini issue #1, where 164 log lines reading
`refused: :invalid_nonce` told their reader nothing at all. If you match on the bare atom
today, add the two-tuple clause: a reason this package recognises is no longer less
informative than one it does not.



#### "Has not increased" while you are sending epoch seconds means the key wants `:incremental`

The most useful diagnosis to come out of issue #1, and neither of the two the reporter
expected. Their nonces were rising normally — `1789013700` → `1789014601` → `1789015200`,
exactly epoch seconds — and the venue still answered *"has not increased"*.

A **time-based** key would have accepted those: it validates against a ±30 s window, not
against a previous value. *"Has not increased"* is the **incremental** validator's sentence.
So the key was provisioned for incremental validation, the caller was sending the
`:time_based` default, and the mismatch is exactly the one this package's `Auth` moduledoc
warns fails loudly on the first request.

The fix is to pass the mode the key was made with:

```elixir
DpExchange.Gemini.get_balances(credentials, nonce_mode: :incremental)
```

There is no way for this package to infer it — the venue exposes no way to ask how a key
was provisioned, which is why the option exists and has no default that could be right for
everyone. But the sentence in the error is diagnostic, and now that it reaches you, this is
what it means.

#### A nonce far above wall-clock time is a one-way door

Read this before "fixing" `InvalidNonce` by making the number bigger.

Gemini compares nonces as **arbitrary-precision integers**, and every accepted call
**raises the key's stored high-water mark to whatever you sent**. So a workaround that
emits, say, `counter × 1_000` ≈ `1.78e21` to clear a stuck mark does clear it — and
permanently sets the mark to `1.78e21`. Nothing can lower it again.

After that, no mode this package offers can ever satisfy that key. `:incremental` is
anchored to epoch **milliseconds** (~`1.789e12`); even nanosecond magnitudes only reach
~`1.789e18`, still far below `2^64` ≈ `1.844e19`, let alone `1.78e21`. **The key has to be
rotated**, which is a human action. A consumer learned this the expensive way and reported
it (issue #1); it is written down here so the next one does not have to.

**This package cannot put you through that door.** `Auth.nonce(:incremental)` is
`max(now_ms, previous + 1)` — anchored to the wall clock, advancing past it by one only
when calls land inside the same millisecond. Reaching `1e21` would take on the order of
`1e21` calls. The magnitudes that brick a key come from hand-rolled counters, not from here.

The one caveat worth naming rather than hiding: a **large forward jump of the system
clock** would anchor the counter high, and that value would set the venue's mark. There is
deliberately no runtime guard against it, because a guard that refused to emit a nonce
"too far ahead" would turn ordinary NTP corrections into a dead feed — a worse and far more
frequent failure than the one it would prevent. Keep your clocks sane; that is the whole
mitigation.

#### If you match on `{:refused, reason}`, check your clause before upgrading

Reported by the consumer who filed issue #1, and worth repeating because it fails
**silently**: their `normalize_error/1` matched a bare atom, so a `{reason, message}`
2-tuple fell through to a passthrough clause and skipped their canonical mapping entirely.
`order_not_found` would have quietly stopped becoming `:unknown_order` the moment the venue
attached a message. **Nothing would have raised.** If you pattern-match refusal reasons as
atoms, add the two-tuple clause deliberately rather than discovering it by a mapping that
stopped happening.
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

**`live?/1` answers "am I about to move real money" directly**, resolving `opts` the same
way every call here does:

```elixir
DpExchange.Gemini.live?([])                       # true — production is the default
DpExchange.Gemini.live?(environment: :sandbox)     # false
```

Worth a check of your own before a call that places, cancels, withdraws or converts — the
same asymmetry that makes `:production` the default (a wrong guess toward demo is loud and
free; a wrong guess toward production is silent and costs money) is worth confirming
explicitly at the one call site that actually risks it.

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

**Account and trading are implemented.** Balances, orders, fees, transfers, trade
history, staking, positions, clearing and account administration all work once you hand
this package credentials and — where it cannot be inferred — the scheme: it **signs**,
it does not **authenticate**. What genuinely returns `{:error, :not_supported}` is the
venue's own absence (options, watchlists, financials — see `venue_does_not_serve/0`) and
the small remainder of this package's own backlog (`list_instruments/1`,
`list_portfolios/1`, `get_conversion/2`), not the authenticated surface as a whole. The
demo environment is what makes exercising any of this safely, before you point it at a
real account.

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
they are real instruments, but `get_symbols/1` is the *spot* catalogue and does not list
them. `capabilities/0` declares `supported_instrument_types: [:spot, :perp]` — the
perpetuals surface has its own endpoints (`get_positions/1`, `get_contract_stats/2`,
`get_funding/2`, among others), not a place in this list.

## `:since` narrows a window as a `DateTime`, everywhere it appears

`get_orders/2` (with `history: true`), `get_trade_history/2`, `get_transactions/1`,
`list_custody_fees/1`, `list_accounts/1` and the staking history/reward reads all accept
`since: ~U[...]` and convert it to the venue's own unit (milliseconds) before it goes on
the wire — pass a `DateTime`, not a raw integer. `get_trade_history/2`'s `:limit` and
`:since` used to reach the venue as `to_string(value)` instead — a `DateTime` became a
string like `"2026-08-28 17:00:01Z"`, a shape `/v1/mytrades`'s `timestamp` field does not
parse, so the filter silently failed to narrow anything. Fixed to match every other
`:since`-accepting call in this module.

`get_transfers/2` is the one exception: its filters (`currency:`, `timestamp:`,
`limit_transfers:`) are the venue's own field names and units unchanged, not translated —
see `Private.get_transfers/2`'s moduledoc.

## What this package does not do

Authenticated endpoints are **not** on this list — see "This package does not handle
authentication — you do", above: balances, orders, fees, transfers, trade history and the
rest of the account surface are implemented and signed on request; only obtaining,
storing, refreshing or choosing between credentials is the host's job.

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

`symbol` comes back uppercase and unsplit (`"BTCGUSDPERP"`), matching every other reader
in this package — the venue's own example sends it lowercase, the same case `/v1/symbols`
uses, and this package normalises it rather than handing back whatever case the response
happened to arrive in.

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

## `has_staking` and `supports_margin` are `true` — an account entitlement, not a package one

Both flags were `false` while every staking and margin endpoint they should have gated was
already `:experimental` below them — a declaration contradicting its own endpoint map,
corrected 2026-09-06. `has_staking: true` covers all six staking endpoints; `supports_margin:
true` covers the spot-margin trio, `get_margin_account/1`, `get_margin_rates/1` and
`preview_margin_order/2`; `max_leverage` is `Decimal.new("5")`, the venue's own published
ceiling — some collateral assets cap lower, which is the account's detail to report, not a
second venue-wide number.

**Neither flag means every credential can use the feature today.** Gemini gates margin to US
(excluding NY) Eligible Contract Participants and gates staking assets by jurisdiction, the
same way it gates order placement by KYC tier — an entitlement on the account, not on the
package or the venue. A caller whose account lacks the entitlement gets the venue's own
refusal, same as an unapproved withdrawal address or an unverified payment method; it does
not mean the endpoint was never implemented.

`get_staking_rates/1` is the one endpoint in this set that is public and was reprobed live
against `api.gemini.com` on 2026-09-06. The other five staking endpoints and all three margin
endpoints are authenticated; this repo holds no credentials to probe them with, so their
inclusion here rests on Gemini's own OpenAPI paths and response shapes rather than a live
call — read `capabilities/0`'s own `measured_against` field for which is which, not this
paragraph, if that provenance ever changes.

## Every negative here is audited

`docs/reference/gemini/negative-claims.md` lists each one with the source and date consulted.
This venue is also where the family learned that **positives go stale too** — a socket URL
the vendor still published had stopped working, and only a live check said so.
