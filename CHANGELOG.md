# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific version
needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version. Coverage is uneven by design: fakes and live public endpoints are well
covered, order placement and authenticated flows are not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
what was run against the live venue, and when. "Marked proven" with no evidence is not an
acceptable changelog line.

## [Unreleased]

### Added

- **Money movement: `get_deposit_address/3`, `list_approved_addresses/1`,
  `estimate_withdrawal_fee/4` and `withdraw/5`.** All four were `:unsupported`. This is the
  group where a defect moves funds and the one that can never be tested against the live
  venue here, so the rules matter more than the code.

  **`withdraw/5` always sends an idempotency key.** The venue accepts `clientTransferId` and
  treats it as optional; this does not. A withdrawal request that times out has an unknown
  outcome — the funds may already be moving — and without a key the safe-looking response,
  a retry, **sends the money again**. `opts[:client_transfer_id]` lets a caller supply its
  own so a retry across a process restart is still the same request.

  **The memo requirement is documented and not guessed.** The vendor says a memo is
  *"required for certain networks that use memos (e.g., Solana, XRP, Cosmos)"* and publishes
  no machine-readable list, so this package does not invent one. `opts[:memo_required]` is a
  **caller's assertion**: passing it with no memo is refused here, where nothing has moved,
  rather than at the venue after the transfer is accepted.

  **A withdrawal comes back `:pending` unless the venue says otherwise.** The venue
  accepting one is not the chain confirming it, and a status this package does not recognise
  is pending rather than completed — a withdrawal the venue has not described has not
  arrived.

  **An approved address can be on the list and still unusable.** The venue reports
  `pending-time` for one inside its time lock and publishes no activation time, so
  `ApprovedAddress.usable?/2` answers `nil` — unknown, not "ready". A status the venue
  invents later maps to `:pending`, because treating an unknown status as usable is the
  direction that loses money.

  **A deposit address's `memo_required` is `nil`, not `false`.** This endpoint does not say,
  and `false` would be a claim that no memo is needed — which on Solana or XRP loses the
  deposit.

  The fee estimate carries the destination, because fees differ by address on some networks
  and an estimate for one does not hold for another.


- **`list_networks/2` and `list_fee_promos/1`.**

  **`list_networks/2` is the call that has to happen before `get_deposit_address/3`.** That
  endpoint takes a network and a wrong one produces an address on a chain this venue does
  not credit — funds sent there are gone.

  Two directions, two endpoints, **and they are not symmetric**: `GET /v2/network/{token}`
  is public, while `/v2/networks/{network}/assets` needs the Fund Manager or Auditor role
  and returns *"only the assets where your account has deposit and withdraw access
  enabled"*. **Its answer is scoped to the credential**, so an empty result means this
  account cannot move anything on that network — not that the network carries nothing. A
  caller reading it as a description of the network would draw the wrong conclusion from a
  true response.

  Rows stay the venue's own: its network names are its own, and translating them would
  invent a vocabulary it does not accept back.

  **`list_fee_promos/1` is not `get_fees/2`.** That is the schedule applying to this
  credential; this is the public list of symbols where the venue charges something else, and
  a caller computing cost from the schedule alone is wrong for exactly these symbols. An
  empty list means no promotions are running, which is a real state.


- **`get_historical_prices/4` routes perpetuals to `/v2/derivatives/candles`, which serves
  `1m` and nothing else.**

  **Sending a perpetual to the spot path is the failure this prevents, and it does not
  error.** The symbol is well-formed and the spot endpoint answers, so a caller asking for
  5m bars on `BTCGUSDPERP` would get bars back with no way to tell they were not the
  instrument it asked about.

  A width the derivatives endpoint does not serve is `{:unsupported_timeframe, width}`:
  falling back to the spot path would answer about a different instrument, and falling back
  to `1m` would relabel someone else's bars. Routing is on `SymbolFormat.perpetual?/1`,
  measured against the venue's own catalogue rather than guessed from the name.


- **`get_fx_rate/3` — `/v2/fxrate/{pair}/{timestamp}`.**

  **This is not a rate the venue trades at.** The vendor: *"Gemini does not offer foreign
  exchange services. This endpoint is for historical reference only."* The number comes
  from a third party the venue names under `provider`, which this package carries as
  `Types.FxRate`'s **`:source`** — `:provider` stays `:gemini`, the venue relaying it.
  Collapsing the two would make a relayed BCB rate indistinguishable from one Gemini
  computed itself.

  **Fourteen pairs are served and a pair outside them is refused before the request**,
  because the venue's 404 for an unsupported pair reads the same as one for a bad timestamp
  — a caller sent there cannot tell which it got wrong.

  The venue's own `asOf` wins over the instant asked for: it may answer for a nearby moment,
  and its word is what happened. Requires the Auditor role, which the vendor states.


- **The socket delivers the whole channel surface, not just `bookTicker`.** `subscribe/3`
  and `unsubscribe/3` take a channel and build the address through `WsChannels` — **the
  interval is part of the address** for the `…Fast` and `…Snapshot` channels, and a
  hand-assembled `"{symbol}@depthFast"` subscribes to nothing and produces silence rather
  than an error. A per-account channel takes `[]` for symbols and yields one address.

  **A `@trade` frame's side is inverted from `m`**, which the socket delegates to
  `WsDecode.to_trade/2` rather than repeating — doing it in both places would undo it.

  **A depth diff is delivered as a diff, not as an `OrderBook`.** Handing a subscriber the
  changed levels under a type that means "the whole book" is the substitution this family
  refuses. **A sequence gap emits a `:degraded` notice**, because the vendor's rule is
  discard-and-resubscribe and a consumer that keeps applying holds a book that is silently
  wrong from that frame onward with every price in it real. A partial-depth *snapshot* does
  become an `OrderBook`, carrying `lastUpdateId` as the sequence.

  **The new clauses are ordered before `bookTicker`'s**, which is load-bearing: a depth diff
  carries `s`, `b` and `a` too, so the older clause matched it and tried to read an array of
  levels as a price.


- **The WebSocket surface: all twenty-two channels, their addresses, and decoders for the
  market-data frames.** From the vendor's **AsyncAPI document**, read 2026-09-01 — not the
  rendered Stream Matrix, which shows eleven families and **omits ten of these channels**:
  the whole `requestForQuote` family, `connection`, both `…Snapshot` channels and the four
  `…Fast` depth variants.

  **Three rules in that document produce a plausible wrong answer if missed, and each is now
  guarded by a test.**

  **`m` is "whether the buyer is the maker" — the opposite of the REST tape's `type`.** The
  same venue reports the trade side two different ways on two transports: `/v1/trades`
  gives the *taker's* side directly, while `@trade` gives the maker flag. `m: true` means
  the buyer was resting and the **seller** aggressed. Carrying it through as a buy would
  invert every trade on the socket while agreeing with the REST field name, which is exactly
  how such a bug survives review.

  **Timestamps are nanoseconds.** `E` is documented as nanoseconds and the vendor notes the
  values exceed JavaScript's safe integer range. Read as milliseconds an event lands about
  fifty thousand years out; read as seconds it still looks like a date, which is worse.

  **`depth` and `depthFast` are differential, and `U..u` is the only way to know none were
  missed.** The vendor: *"if a frame's `U` skips ahead of the last applied `u`, discard the
  book and resubscribe to resync."* `depth_gap?/2` is that check, and a frame with no `U` is
  treated as a gap because continuing would apply it blind. **A quantity of zero deletes the
  level** rather than setting it to zero, so `depth_changes/1` returns it rather than
  filtering — filtering would drop the deletion and leave a level nobody quotes standing.

  Addresses are built rather than guessed: **the interval is part of the address**
  (`{symbol}@depth@100ms`, `balances@account@1s`), a per-symbol channel with no symbol is an
  error, and a per-account channel given one is too — `orders@account` with a symbol
  appended is not a channel the venue has, and subscribing to it produces silence rather
  than a refusal.


- **`get_trades/2` — the public tape**, `/v1/trades/{symbol}`. Not `get_trade_history/2`,
  which is the credential's own fills.

  **`type` is the taker's side**, and the venue says so explicitly: *"`buy` means that an
  ask was removed from the book by an incoming buy order"*. That is the opposite of the
  resting order's side, and a package reading it the other way inverts every entry on the
  tape while every number stays real.

  **Broken trades are excluded unless `opts[:include_broken]` asks for them.** A busted
  print did not stand, and its price in a series becomes a phantom high or low in every
  range and volatility figure built on it. The venue's own `include_breaks` is sent as well
  as the filter being applied here — asking the venue is cheaper than filtering a page.

  `opts[:since]` goes as the venue's `timestamp` in milliseconds and `since_tid` is passed
  through alongside it: the venue states `since_tid` wins, and **that precedence is left to
  the venue** rather than resolved here.


- **`quote_conversion/4`, `commit_conversion/2` and `convert/4` — the Instant pair and the
  wrap endpoint.**

  `/v1/instant/quote` then `/v1/instant/execute` is the two-step form: the venue states a
  price, a quantity, a fee and a `maxAgeMs`, and nothing moves until the commit.
  `/v1/wrap/{symbol}` is `convert/4`, the one-step form — no rate is held and the caller
  learns the price from the result.

  **The expiry is anchored to the venue's own `Date` header, not the local clock.** A
  window computed against a drifted client expires at the wrong moment, and a conversion
  committed a second late fills at a rate the caller was never shown.

  **The direction refuses more often than you would expect, and that is deliberate.** The
  venue takes a symbol and a side, not a from/to pair, and `totalSpend` is `CCY2` on a buy
  and `CCY1` on a sell. Deriving that needs to know which asset is the quote side — and
  **this venue quotes in crypto as well as fiat**, so for `USD -> BTC` both are quote
  currencies, both orientations parse, and only the catalogue says which pair exists. It
  returns `{:ambiguous_conversion, from, to}` rather than picking one; choosing wrongly
  spends the wrong asset, which is a real loss and not a wrong-looking number. Pass
  `opts[:symbol]` and `opts[:side]`.

  `commit_conversion/2` needs the terms the venue quoted against, not the id alone — the
  execute call takes symbol, side, quantity and price, and a missing one is an error rather
  than a value invented here.

  `get_conversion/2` stays unsupported: the venue quotes and executes and does not answer
  "what became of quote N". A caller that lost a quote re-quotes.

- **`get_trade_volume/2` — `/v1/tradevolume`.** One row per symbol per day with the maker
  and taker breakdown, under the venue's own field names. Not `get_trade_history/2` summed:
  this venue requires a symbol on every fills request, so reproducing it is one request per
  symbol per period and the answer would still be this package's arithmetic against the
  venue's ledger.

- **`cancel_all_orders/2`, covering both of the venue's bulk cancels.**

      :session  ->  POST /v1/order/cancel/session
      :account  ->  POST /v1/order/cancel/all

  **`opts[:scope]` is required and there is no default.** The account scope reaches orders
  no API key placed — the venue says so explicitly, including ones a person entered through
  its web interface — so choosing it for a caller who meant the session would cancel work
  nobody asked about, and choosing the session for a caller who meant the account would
  leave orders running. Gemini's own documentation recommends the session scope; that is
  guidance for the caller, not licence to pick here.

  Returns `%{cancelled: [id], rejected: [id]}`, ids as strings like every other order id in
  this package. **A non-empty `rejected` is not a failed call** — the venue answered, and
  some of those orders were already gone.

- **`get_orders/2` reaches `/v1/orders/history`.** Resting and closed orders are two
  endpoints, not one with a filter, and only the resting half was implemented. `history:
  true` asks for the other; a caller who does not say gets the resting ones, the set that
  can still change. `symbol:`, `limit:` and `since:` are passed through in the venue's own
  names, and **no default page size is substituted** — one chosen here would silently
  become the caller's answer.

### Fixed
- **BREAKING: `get_historical_prices/4` returns `Core.Types.Candle` with `:opened_at`.** It
  returned bare maps keyed on `:timestamp`, a name that does not say which end of the
  interval it is. A caller reading it as the close is off by exactly one interval, in a
  value that looks entirely reasonable. The fake carried the same shape.

- **The `@unsupported` note claimed `preview_order/3` "has no endpoint at all".** Gemini
  publishes `POST /v1/margin/order/preview` — a *margin impact* preview returning pre- and
  post-order risk statistics. That is not what `preview_order/3` asks, which is what the
  order would cost, so it is still not implemented as one; answering the cost question with
  margin statistics is exactly the nearby substitute this family refuses. But the endpoint
  is real, it is a real capability, and the note now says so instead of denying it.


### Changed
- **`get_transfers/2` calls `/v2/transfers`** (D6). The v1 path is absent from Gemini's
  published OpenAPI document, and v2's own description states *"The v1 transfers endpoint is
  being retired."* The three parameters are unchanged, so this is a path change only.

### Added
- `ArchivedSocketsTest` — fails the build if any code path speaks one of Gemini's four
  archived WebSocket APIs, or points a socket at `api.gemini.com` rather than
  `ws.gemini.com`. This is the venue where that failure already happened once.

### Added
- First release. Market data, order book, catalogue, quantization and streaming behind
  `DpExchange.Core.Venue`. Every authenticated endpoint is declared `:unsupported`:
  signing is implemented and tested, but nothing here has run against real credentials,
  and declaring it `:experimental` would claim more than that deserves.
- Streaming speaks **`wss://ws.gemini.com`**, the API Gemini's current documentation
  describes — *not* the `api.gemini.com/v2/marketdata` endpoint the prior adapter uses.
  Both answer today; only one is documented. See
  `docs/reference/gemini/websocket-api-replacement.md`.
- Repo scaffold from the DpExchange standard; extraction pinned to the host's
  `553fa787` with its working-tree state recorded, since the Gemini subtree was dirty
  at extraction time.

### Measured against the live venue, 2026-08-28

Recorded with the evidence, because each contradicts something written down and "fixed
the timeframes" with no evidence is not worth reading.

- **The candle timeframe enum in Gemini's own documentation is wrong three ways out of
  seven.** The page lists `1h`, `6h` and `1d`; the API rejects all three, and its 400 body
  names the real set: `[1m, 5m, 15m, 30m, 1hr, 6hr, 1day]`. The page also contradicts
  itself — prose says `1day`, its enum block says `1d`, and only the prose is right.
- **The candle window is fixed and `start`/`end`/`limit` are ignored.** Seven widths, 1440
  one-minute bars down to 364 daily ones, reproducing the prior adapter's independent
  2026-08-06 measurement exactly on all seven. Ranges are filtered client-side, and one
  reaching before the window is `{:error, {:range_unavailable, …}}` rather than a short
  answer that reads as a complete one.
- **No rate-limit headers exist.** Only `date`, `x-request-id` and
  `x-envoy-upstream-service-time`. `get_rate_limit_status/2` is `:unsupported` rather than
  a constant that never moves.
- **No ticker publishes a quote timestamp.** `/v1/pubticker`'s only timestamp stamps its
  24-hour volume window; `/v2/ticker` has none. Quotes carry the venue's HTTP `Date`
  header, and a response without one is `{:error, :missing_venue_timestamp}` — never the
  local clock.
- **The venue publishes its burst depth**, which no other venue in this family does, so
  all three GCRA parameters are declared rather than guessed: 120/min public, 600/min
  private, burst 5.
- **Gemini now offers two nonce modes and they need differently-shaped values** — seconds
  for time-based, monotonic for incremental — so the mode is a caller option rather than
  something this package can paper over.

### The demo environment, and the boundary it does not move

- **`environment: :sandbox` points both transports at Gemini's demo exchange** —
  `api.sandbox.gemini.com` and `ws.sandbox.gemini.com`. Verified live: 391 symbols, the
  same REST shapes as production, and a WebSocket that acks and streams `bookTicker`
  frames field-for-field like production. `:production` is the default and an unrecognised
  value **raises** rather than falling back, because the failure is asymmetric — meaning
  demo and getting production sends a real order to a real exchange.
- **A third documentation defect, found the same way as the first two.** Gemini's
  market-data page names `exchange.sandbox.gemini.com` as the sandbox base URL. That is
  the website: `/v1/symbols` there returns **404 and an HTML page**, while `api.sandbox`
  returns 391 symbols. The get-started page is right and the market-data page is wrong.
- **The demo book is frequently crossed** — a captured frame carried bid `68169.88`
  against ask `64886.32`. Not corrected, reordered or filtered: the venue said it, and
  inventing a plausible book on top of an implausible one is the substitution this family
  refuses. Recorded so a consumer computing spreads against demo data knows why they go
  negative.
- **Production and demo run side by side with nothing named.** The supervisor, feed and
  limiter derive default names from the environment, so a consumer trading live while
  testing strategies against demo starts two trees and neither collides. Per-process
  selection through `Core.Config` covers the finer case — one strategy runner on demo
  while the trading path beside it stays on production.
  Two bugs were found by taking that case seriously rather than assuming it worked:
  a **name collision** that made the arrangement impossible, and — the dangerous one —
  a **shared rate-limit bucket**, where a call carrying `environment: :sandbox` but no
  `:limiter` metered against the *production* budget. Demo strategy testing would have
  spent the budget live trading depends on, surfacing as a 429 on a real order at an
  arbitrary later moment with nothing pointing back at the cause.

- **`Auth` no longer decides which authentication is in use, and never did handle it.**
  The scheme is now named by the caller — `Auth.headers(:api_key | :oauth, …)` — and an
  unknown scheme or mismatched credentials are refused rather than guessed at or
  partially signed. This package **signs**; the host **authenticates** and chooses which
  kind. Gemini offers an API key pair and a full OAuth 2.0 authorization-code flow with
  app registration, PKCE and 24-hour token refresh; the second needs a browser, a
  redirect URI and somewhere safe to keep a refresh token, none of which a venue package
  has. Guessing is also actively harmful: the venue returns `AmbiguousAuthentication`
  (400) when V1 key headers and OAuth headers arrive together.
- **`.env.sample` carries no venue credential**, because there is nothing here for one to
  do. An unused credential in a public repo is a liability with no upside.

### Found in `dp_exchange_core` while writing this, and fixed there in `0.1.8`

- `Capabilities` ceilings had nowhere to carry a **burst depth**, so a venue that publishes
  one had to hardcode it beside the declaration it was supposed to configure.
- `HttpClient` flattened a 4xx into a message string, leaving `{:refused, reason}`
  reachable only by string-matching. `raw_status: true` returns the response intact.
- `HttpClient.request/5`'s spec advertised a rate-limit return shape it never produces.
