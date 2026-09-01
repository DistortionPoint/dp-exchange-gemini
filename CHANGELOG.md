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

### Documentation

- **Every negative this package makes is audited** —
  `docs/reference/gemini/negative-claims.md`, thirteen claims with the source and date
  consulted for each. All hold, including the two that are the venue's own words: no market
  orders ("they provide you with no price protection") and no plain stops.

  **This venue is where the family learned the rule's other half.** Every other package
  learned to check negatives; Gemini is where a *documented, positive* claim — a socket URL
  the vendor still published — turned out to be false. A claim about a venue is only as
  current as the last time someone looked, whichever way it points.

  The audit also records a divergence worth keeping: Gemini's own error table lists
  `MissingApikeyHeader` at **400**, and the live environment returns **401**
  `MissingSecurityHeaders` (measured 2026-08-28).

- **`supported_instrument_types` gains `:perp`.** The venue's perpetuals surface was always
  there; the package's claim of `[:spot]` was a statement about the package that had stopped
  being true.

- **`usage-rules.md` gains everything this release added** — the sign convention on a short,
  the three staking numbers and which two survive, clearing's confirm-restates-everything
  rule, the shortname that is not the name you sent, the refresh token that rotates, and why
  the spreadsheet reports come back as bytes.

- **`AGENTS.md` gains a pointer** to this package's own `usage-rules.md`.

### Changed

- **Core dependency moves to `~> 0.1.36`**, and `place_orders/3` is declared **absent with
  the reason**: this venue places one order per request. A batch is one request the venue
  accepts or rejects as a unit, and a caller placing several here calls `place_order/3`
  several times and reconciles the outcomes itself.

### Added

- **Account administration and the OAuth token lifecycle** — `create_account/1`,
  `rename_account/3`, `list_accounts/1`, `get_roles/1`, `refresh_access_token/3` and
  `revoke_access_token/1`.

  **The name you send is not the name you address by.** `/v1/account/create` takes a display
  name and answers with a kebab-cased *shortname*, and that shortname is what every other
  endpoint's `account` parameter takes. A caller that kept what it sent would address the
  wrong subaccount, or nothing.

  **`rename_account` touches two different things.** `opts[:name]` is the display name;
  `opts[:shortname]` is the string other endpoints address by, and changing it changes how
  the account is reached. Neither given is `{:error, :nothing_to_rename}` rather than a call
  that changes nothing and reports success.

  **`list_accounts/1` caps at 500 and does not paginate** — the venue's `limit_accounts` is
  both maximum and default, and a larger group comes back truncated with nothing to say it
  was. There is no cursor to follow, so it is stated rather than worked around.

  **`get_roles/1` answers with three booleans, not one role**, because `Fund Manager` and
  `Trader` combine and `Auditor` combines with nothing.

  **`refresh_access_token/3` is credential use, not consent.** The browser redirect that
  obtains the first code belongs to the host; refreshing a token the host already holds is
  the same category as Schwab's `Auth.refresh/2`. It posts a **form** to
  `exchange.gemini.com/auth/token` — a different host from every other endpoint, and the same
  URL the host's initial exchange posts to, separated only by `grant_type`. That is the
  concrete case for why the package/host split cannot be read off a path.

  **The response rotates the refresh token**: a new one comes back and the old stops working,
  so a caller that stores only the access token has a session that ends at the next refresh.

  `revoke_access_token/1` **requires an OAuth token** and refuses an API key — an
  API-key-signed call there would revoke nothing and come back shaped like success.


- **Clearing, all eight endpoints**: `create_clearing_order/2`,
  `create_broker_clearing_order/2`, `get_clearing_order/2`, `cancel_clearing_order/2`,
  `confirm_clearing_order/3`, `list_clearing_orders/1`, `list_clearing_brokers/1` and
  `list_clearing_trades/1`.

  **A clearing order is not an order on the book.** It is one half of a trade agreed with a
  named counterparty and it does nothing until that counterparty confirms. `is_confirmed` on
  the response is the field that matters — a caller reading a successful create as a fill
  holds a position it does not have.

  **`confirm_clearing_order/3` re-states every term and this package fills none of them in.**
  The venue re-asks for the symbol, amount, price and side alongside the clearing id;
  reading them back from the order being confirmed would confirm whatever the venue had,
  which is the one thing re-stating them exists to prevent. The `side` there is the
  confirming party's own — the opposite of the creator's.

  **The broker form names both counterparties, and `side` belongs to the source.** Passing
  the two the wrong way round produces a valid order in which each side trades the direction
  the other meant, so both ids are required and refused by name when missing. `expires_in_hrs`
  is required here and optional on the bilateral form — the venue's own asymmetry.

  **Three listings, three row shapes, and none of them merged.** A bilateral order names one
  counterparty and a `side`; a broker order names a source and a target and a `source_side`;
  a trade comes back camelCase under `results` where the orders come back snake_case under
  `orders`. The venue's own keys are kept in each, because one normalised shape would match
  none of the three.

  `list_clearing_trades/1`'s `since_nanos` is **nanoseconds** — the one Gemini timestamp that
  is not milliseconds.


- **Perpetuals and margin, twelve endpoints.** `get_positions/1`, `get_funding/2`,
  `get_contract_stats/2` and `next_funding_timestamp/2`; `get_account_margin/1`,
  `list_funding_payments/1` and the three funding reports; and the spot-margin trio
  `get_margin_account/1`, `get_margin_rates/1` and `preview_margin_order/2`.

  **Gemini sends a negative quantity for a short**, and `Types.Position` refuses to carry
  one: `:quantity` is a positive size and `:side` says which way. A sign convention is a fact
  about one venue's JSON, not about the market, and passing it through hands a caller a
  position that is exactly backwards while every number in it stays plausible.
  `notional_value` **keeps** its sign, because that one is a value rather than a magnitude
  with a direction beside it.

  **Settled funding and estimated funding stay in different fields.** A real response carries
  `-1.50991` beside `-2.10595` — 40% apart — which is how wrong a caller reading "the
  funding" would be. The sign is carried through unchanged: it means direction between longs
  and shorts, and normalising it would assert a convention Gemini did not state.

  **Mark, index and last trade are three prices and none is the other.** A position can be
  liquidated at a mark the market never printed, which is why `get_contract_stats/2` carries
  mark and index separately and neither is `get_price/2`.

  **`get_positions/1` publishes no liquidation price, and `nil` there does not mean safe** —
  `get_account_margin/1` carries `estimated_liquidation_price` for the account.

  **A private GET signs the full path including its query string.** Gemini's report
  endpoints put the query in the signed `request` field; signing the bare path yields a valid
  signature over the wrong string, which the venue reports as a credential problem rather
  than a parameter one. One string is built and used in both places.

  **The spreadsheet reports return the venue's bytes, unparsed.** This package ships no
  spreadsheet reader and will not grow one: a parsed cell is a number this package chose from
  a layout the venue can change without notice. `fromDate` and `toDate` must be given
  together or not at all — the venue makes each mandatory if the other is present, and one
  alone comes back bounded by `numRows`, which is a real report over the wrong window.

  **`preview_margin_order/2` enforces the venue's sizing rule up front**: `totalSpend` for a
  market buy, `amount` for everything else, and a price for a limit order. Sending the wrong
  one previews a different order than the caller described.

  **Margin rates arrive three ways per currency** — hourly, daily and annual — and all three
  travel. Taking the hourly rate for the annual one is an error of four orders of magnitude
  that still looks like a rate.

  `supported_instrument_types` gains `:perp`. The venue's perpetuals surface was always
  there; the package's claim of `[:spot]` was a statement about the package that had stopped
  being true.


- **Custodial staking, all six endpoints**: `get_staking_rates/1` (public,
  `GET /v1/staking/rates`), `get_staking_balances/1`, `get_staking_rewards/1`,
  `get_staking_history/1`, `stake/3` and `unstake/3`.

  **The rate's unit is the whole risk.** Gemini publishes three numbers for one position —
  `rate` in basis points, `ratePct` as a percentage and `apyPct` annualised. The first two
  differ by a factor of a hundred and the third by compounding. `Types.StakingRate` carries
  percentages only, both named: basis points are converted on the way in, and **`:apy_pct`
  is never derived from `:rate_pct`** — that needs a compounding frequency the venue did not
  state.

  **A staked position is three amounts and stays three.** The real shape is `balance: 10`,
  `available: 0`, `availableForWithdrawal: 10` — redeemable in full, tradable not at all. A
  state the venue does not report is `nil`, never zero. **Zero-balance rows are kept**: the
  host adapter this replaces dropped them, which makes "no position reported" and "no
  position" the same answer.

  **An unstake returns before it completes.** `:amount`, `:amount_paid_so_far` and
  `:amount_remaining` all travel, because a redemption unbonds on the chain's schedule and
  the three differ for most of its life. `nil` on the last two is "not reported", not
  "complete".

  **`opts[:provider_id]` is required on both writes and is not defaulted.** The same asset
  stakes with several providers at different rates; picking one here would stake or redeem
  at a rate the caller never chose. Missing it is `{:error, :missing_provider_id}` before a
  request is made.

  A transaction type this package does not know maps to `:other`, with the venue's own word
  kept in `:venue_type` — a normalisation that loses the original cannot be audited when it
  turns out to be wrong.


- **Notional balances and custody fees**, closing this venue's fund-management surface:
  `get_notional_balances/3` (`/v1/notionalbalances/{currency}`) and `list_custody_fees/2`
  (`/v1/custodyaccountfees`).

  **A notional balance is not a balance in another unit.** The `amount` is Gemini's ledger;
  the `amountNotional` beside it is Gemini's *valuation* of that quantity, at a rate it
  chose and does not publish here. Rows are returned as the venue sends them so the two
  numbers cannot be read as one. Reconcile a position with `get_balances/2`.

  **A custody fee is a balance reduction with no trade behind it**, which is the gap a
  consumer reconciling against fills alone cannot otherwise account for. An empty list means
  nothing was charged in the window asked for — never that the venue does not charge.

  `get_payment_method/3` is declared **absent**: `/v1/payments/methods` returns the whole
  set and there is no path taking a method identifier. Filtering the listing here would
  answer with a snapshot while looking like a read, which is the distinction that callback
  exists to draw.


- **The rest of money movement: payment methods, internal transfers, the allowlist writes
  and the transaction ledger.** `list_payment_methods/2`, `add_payment_method/2`,
  `transfer_internal/4`, `request_approved_address/4`, `remove_approved_address/3` and
  `get_transactions/2`.

  **`add_payment_method/2` has two endpoints because the details differ by country** —
  `/v1/payments/addbank` and `/v1/payments/addbank/cad`. A country this venue has no
  endpoint for is refused rather than sent to the wrong one, where the fields would be read
  as the other country's and the account registered wrong.

  **`transfer_internal/4` sends no address and no network** — nothing leaves the venue.
  Both ends are required: a transfer with one missing is not a transfer, and defaulting
  either would move funds between accounts the caller did not name.

  **`request_approved_address/4` returns the venue's `pending-time`.** A successful response
  is not permission to withdraw; the entry sits under a time lock and a withdrawal to it
  before the lock lifts is refused.

  `get_transactions/2` returns every kind the venue records — fees and adjustments alongside
  fills and deposits.


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
