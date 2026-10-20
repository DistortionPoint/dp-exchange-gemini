
# Using `dp_exchange_gemini`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Gemini**.

## Times on quotes and books: what is `nil`, and what is sorted

**REST `Quote.venue_time` and `TopOfBook.venue_time` are always `nil` (BREAKING, tick R).**
They used to be the HTTP `Date` response header. That is when the reply was served, not when
the last trade happened or the quote was true, so it was a different event's time (family
rule MD7). `/v1/pubticker` states no trade time (its only `timestamp` stamps the 24-hour
volume window). **Write a `nil` branch for this venue's quotes;** `observed_at` states
freshness. Nothing is ever substituted into that field: it is the venue's own instant or it
is `nil`, never this package's clock and never a header.

`get_order_book/2`'s `venue_time` is **always `nil`.** Until checked against the vendor's
own OpenAPI spec (2026-09-29), this section said `venue_time` was derived from the
per-level `timestamp` fields the venue puts on every book level, and that a book in which
not one level's timestamp could be read failed with `{:error, :missing_venue_timestamp}`.
Neither claim was true: `OrderBookEntry.timestamp`'s own schema
(`docs/reference/gemini/openapi/rest.yaml:8065`) says **"DO NOT USE — this field is
included for compatibility reasons only and is just populated with a dummy value."**
`/v1/book` publishes no time of its own anywhere else in the response, so there was never
anything to derive, and never anything to refuse over.

On the **stream**, a partial-depth snapshot (`@depth5`/`@depth10`/`@depth20`) carries
`venue_time: nil`, because the vendor's own AsyncAPI requires only
`[lastUpdateId, bids, asks]` for `OrderBookSnapshot`. A `bookTicker` frame may carry `nil`
too, since 0.2.27 — the frame captured in this repository's reference has no `E` at all, and
the book and last trade in it are delivered rather than dropped. Deltas do carry a real
nanosecond event time and are refused without one, because `OrderBookDelta` enforces
`:timestamp`.

**The streamed last-trade `Quote`'s `venue_time` is `nil` unconditionally — not "unless `E`
is missing".** This corrects an earlier version of this file, and of the code: `bookTicker`'s
`c` field is, in the vendor's own words, "Last trade price, present once the book has
traded" (its AsyncAPI document names no trade TIME at all). The frame's `E` is the
**book-ticker update's** own event time, not the trade's — a book can tick with no trade at
all — so stamping `E` onto that `Quote` attached a real timestamp to the wrong event. The
`TopOfBook` delivered alongside it is unaffected: its `venue_time` is still read from `E`
exactly as described above.

**The same `Quote` is also no longer emitted on every `bookTicker` tick that repeats the
same `c`.** This channel is not itself trade-triggered — the venue re-sends the same last
trade price on every quote change until the next execution — so a subscriber now sees one
`Quote` the first time a symbol's `c` is seen on a connection and one more each time it
genuinely **changes**, never once per tick. The "last seen" price is forgotten on a reconnect
and when you unsubscribe the symbol, so a reconnect or a resubscribe reports the current last
trade once more. A `c` that is zero, negative or unreadable produces no `Quote` and does not
reset that memory. A consumer counting on "one `Quote` per `bookTicker` frame that carries
`c`" will now see fewer of them; a consumer wanting the raw tick cadence should read
`TopOfBook`, which still arrives on every frame.

A `bookTicker` frame this package cannot read is not dropped in silence: a bid or ask the
venue stated but that is unreadable (or negative) raises a `:data_quality` `Core.Notice`
(`details.reason` `:unreadable_book_ticker_level`, with the symbol) and no `TopOfBook` is
delivered; a frame whose symbol is absent, blank or not text raises `:data_quality` with
`details.reason` `:undecodable_book_ticker`. Every notice's `details.reason` is an atom;
the words are in `details.message`. A side priced `0` is no resting order (`nil`),
with its size.

## An order book is sorted, so `hd(bids)` is the best bid

Both arms guarantee it as of 0.2.32 — `get_order_book/2` and the streamed snapshot alike —
and it is `Core.Types.OrderBook`'s contract rather than this package's convenience: **bids
descending, asks ascending**. You do not need to sort what you receive, and you should not
assume the venue's own row order means anything.

Two consequences:

* **A snapshot with a row this package cannot read is refused whole**, not delivered with
  the row dropped or kept as `{price, nil}`. `get_order_book/2` answers
  `{:error, :unexpected_response_shape}`; a streamed snapshot raises a `:data_quality` notice
  and is not delivered. A damaged book that looks complete is worse than no book, and
  diffs already refused the same way. A side the venue states as absent is still empty.
* **A streamed DELTA is the exception and is deliberately unsorted.** `OrderBookDelta` is
  passed through in the venue's own order, because its entries are changes to apply in
  sequence and re-ordering them would invent an order the venue never sent. The struct name
  tells you which one you are holding.

**`get_order_book/2`'s `:depth`** is levels per side. Absent, it is the venue's own default,
50 (never a guess); `0` is passed through (the vendor's prose: the full side). Anything that
is not a whole number of at least `0` is `{:error, {:invalid_option, :depth, value}}`, checked
before a request is made.

## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. `dp_exchange_core 0.2.1` introduced the fields; this
package requires `~> 0.3.114` (its floor is in `mix.exs`; `0.3.95` is where this change landed).

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
`{:error, {:exchange_error, :gemini, "Rate limiter unavailable"}}` to everything. The
authenticated calls meter against their own bucket, keyed `:gemini_private`; that name
appears as `provider` in their telemetry, but their errors are still tagged `:gemini`.

Running two — two credentials, two scopes — needs distinct `name:`s, and nothing else:

```elixir
[{DpExchange.Gemini, name: :gem_a}, {DpExchange.Gemini, name: :gem_b}]
```

A tree started with a non-default atom `name:` and no `:feed` or `:limiter` names its feed
`Module.concat(name, "Feed")` and its limiter `Module.concat(name, "RateLimiter")`, and a facade
call carrying the same `name:` addresses that tree: `DpExchange.Gemini.subscribe(symbols, name:
:gem_a)`, `get_balances(creds, name: :gem_a)`. Pass `:feed` and `:limiter` yourself to choose
other names; an explicit one wins. With no name, a `nil` one or a non-atom one the names are the
environment defaults, as before.

## A connect that never finishes ends at a deadline, and a malformed close frame is a reconnect

Three things this package's socket does that the `websockex` library it is built on does not.
All come from a private, patched fork of websockex 0.5.1's process loop,
``DpExchange.Gemini.Vendor.WebSockex``, carried from `dp_exchange_webull` on 2026-09-27.

- **The opening handshake has a deadline**: `socket_connect_timeout` plus
  `socket_recv_timeout`. Upstream bounds each read of the upgrade response separately, so
  a peer that trickled the response held a connect open indefinitely. A connect that
  misses the deadline now fails with `%WebSockex.ConnError{original: :timeout}`, the same
  error a plain read timeout gives. On a reconnect, that means backoff and another try, not
  a socket stuck connecting.
- **A close frame with an invalid status code disconnects.** Upstream raised on it and
  crashed the socket before its reconnect logic ran. It now produces an ordinary
  `:link_down` and reconnect.
- **A frame that never finishes is closed.** A frame header may declare a length up to 2^63
  and upstream buffered whatever arrived, without limit. An unfinished frame, or a fragmented
  message reassembled, past 16 MiB (the size of Core's HTTP body cap; Gemini's frames are a
  few kilobytes) is closed with status 1009 and surfaces as an ordinary `:link_down` and
  reconnect.

**This package depends on `{:websockex, "== 0.5.1"}` exactly.** The fork calls that
release's internals. If your application pins a different websockex version, dependency
resolution will fail, so resolve to 0.5.1.

**The WebSocket verifies the venue's TLS certificate** (2026-09-27). websockex's own
default is not to (`verify: :verify_none`), and until then this package connected with
that default, accepting any certificate. It now uses the operating system's trust store and
HTTPS hostname rules. On a host with no system CA bundle (`:public_key.cacerts_get/0` raises
there) the subscribe call answers `{:error, {:tls_trust_store_unavailable, reason}}` rather
than connecting unverified; it used to raise inside the shared `Feed`. (A plain `ws://` URL,
the `:websocket_url` proxy seam, does no TLS handshake and does not read the trust store.) Pass your own
`:ssl_options` where you start the tree to replace the defaults —
`{DpExchange.Gemini, ssl_options: [...]}`. `nil`, `[]` and anything that is not a keyword list
mean "not given" and keep verification; a list that does not mention `:verify` has
`verify: :verify_peer` added beneath your keys (your `:cacerts`/`:cacertfile` replaces the OS
trust store); only an explicit `verify: :verify_none` turns it off. The option is forwarded
to every socket `Feed` dials (it
did not before; the option was dropped). `Feed` shows that option as `:redacted` in a crash
report and in `:sys.get_status/1`, because a `:cacerts` list, a `:key` or a `:password` lives
there; `:sys.get_state/1` still returns it. The option is also wrapped where the tree is
started, so your supervisor's stored child spec and its child reports print
`#DpExchange.Gemini.Credentials.SslOptions<...>` and not the list (a non-empty list is
wrapped by `{DpExchange.Gemini, ...}` and `DpExchange.Gemini.Supervisor.start_link/1`).
Stopping the feed (`GenServer.stop/1`, a supervisor's shutdown) also ends the socket it dialled.

## A socket crash costs one reconnect, never your whole subscription

The one socket this venue uses is a **linked** child of `Feed` — not a supervised
sibling you can restart independently. As of this version `Feed` traps exits, so the
socket dying abnormally no longer takes `Feed` down with it: `coverage/1` and
`coverage_by_kind/1` clear (this venue has one socket carrying every kind you configured
via `:channels` — see below — so a crash costs all of them at once, not a partial set),
you get a `:link_down` `Core.Notice`, and this
package reconnects and resends your `wanted` symbols on its own, without you calling
`subscribe/3` again. The first crash in a run is redialled at once; a crash within 30 s of the
previous one waits first, 1 s doubling to 30 s, so a socket that dies on connect is not
redialled in a loop. Only one such wait is ever pending: a newer crash replaces it rather
than stacking beside it.

**An ordinary dropped connection (not a crash) backs off too.** The socket reconnects inside
itself: the first attempt waits nothing, each later consecutive failure waits 1 s doubling
to a 30 s ceiling, **shortened by a random amount of up to a quarter** (`Socket.jittered_delay_ms/1`)
so that every `Feed` and node the venue dropped together does not retry on one schedule. A
session that lasts under 5 s counts as a failed connect, not a healthy session that dropped.
The `delay_ms` metadata on the `[:dp_exchange, :link, :reconnect_attempt]` telemetry event is
the delay actually waited, after the shortening. The wait ends if `Feed` stops the socket. A connection that goes 90 s
without a frame or a pong, or that answers pings but not a subscribe for 15 s, raises a
`:degraded` notice (`details.reason` `:silent_connection` or `:subscribe_unanswered`) and is
closed and reconnected. Silence is judged on the socket's 30 s ping tick, so a silent
connection is closed between 90 s and just under 120 s after it was last heard. The liveness
check is the WebSocket protocol's own ping and pong: the venue's AsyncAPI lists a `ping` request
method but does not enumerate its reply, so none is sent, and the venue pushes no heartbeat or
stream sequence number of its own. These timers run on the monotonic clock.

**Notice floods are throttled.** For `:data_quality`, `:refusal` and `:degraded`, the first
notice per `{kind, reason, symbol}` reaches you at once, repeats within 30 s are counted, and
the next one after the window carries the count in `details.suppressed`. `:link_up`,
`:link_down` and `:coverage_change` are not throttled.

**`Feed` itself crashing no longer costs the subscription** — a bug outside the socket-crash
path, or anything that kills the `Feed` pid directly. `DpExchange.Gemini.Supervisor` is
`:rest_for_one` over a ledger, the limiter and the feed. The feed records what it was asked to
carry (wanted symbols, data subscribers, notice subscribers) in the ledger after every accepted
change, and the restarted feed reads it back: your subscribers are re-monitored, the wanted set
is resubscribed, and your `subscribe_notices/1` subscribers receive a `:coverage_change` notice
with `details.reason: :feed_restarted` (only when something was wanted; a data-only subscriber
has no notice channel and simply receives data again). `coverage/1` reads empty until frames
arrive again, as after any reconnect. What is not kept: a subscription whose subscriber pid died
meanwhile, and anything the ledger was not told because the feed died between a change and its
write (the write is not waited for).

## `channels: [:quotes, :top_of_book, :trades]` — opt into the trade tape

`DpExchange.Gemini.Supervisor.start_link/1` — so `{DpExchange.Gemini, opts}` in your own
supervision tree, since its `opts` pass straight through to `Feed` — takes `:channels`, a
non-empty list drawn from `capabilities().streamable`. The default — what you get if you
never pass it — is `[:quotes, :top_of_book]`: exactly this package's behaviour before
`:trades` existed, so an existing consumer that says nothing sees no change at all.

**`:quotes` is the last-trade PRICE CHANGING, not every trade.** It comes off the same
`@bookTicker` frame as `:top_of_book`, and since 0.2.85 it is sent only when that price
actually moves — a run of prints at an unchanged price produces one `Quote`, not one per
print. That is correct for what it is, and it is also why a thin pair can go quiet for
minutes even while it is trading (dp-exchange-core issue #39).

**`:trades` is the real tape — every executed print**, delivered as
`Core.Types.Trade`, from Gemini's own `{symbol}@trade` channel. Add it and this package
also subscribes `@trade` for every symbol you subscribe, alongside `@bookTicker`, kept
current through every path that already keeps `@bookTicker` current — `subscribe/2`,
`unsubscribe/2`, `update_symbols/2`, the periodic resubscribe, and a reconnect.
**`:channels` is a supervision-tree option, not a `subscribe/2` option** — it configures
the one connection this venue's `Feed` holds, so it is passed where you start the tree.
A `channels:` given to `subscribe/2` is refused, `{:error, {:invalid_option, :channels,
value}}`, never ignored. `DpExchange.Gemini.Fake` refuses it too, and takes its channels where
a test can set them (`DpExchange.Core.Config.put_override(:channels, kinds)`, default
`[:quotes, :top_of_book]`), validated as a feed validates them at start:

```elixir
children = [
  {DpExchange.Gemini, channels: [:quotes, :top_of_book, :trades]}
]

:ok = DpExchange.Gemini.subscribe(["BTC-USD"], to: self())
```

An unrecognised kind in `:channels` — anything outside `[:quotes, :top_of_book,
:trades]` — raises `ArgumentError` at start, not a feed that silently never carries what
you asked for. An empty list raises too.

`coverage_by_kind/1`'s keys always include `:trades`, even for a feed started without it
in `:channels` — absence there reads as `:not_covered`, not "this feed doesn't know the
kind". No per-connection stream limit is documented for `wss://ws.gemini.com`; adding
`:trades` doubles the streams this one socket carries per symbol, not the number of
sockets — this package still shards nothing.

**`max_queue_len:`** (a start option, default 10_000) bounds each subscriber's mailbox. Past
it events to that subscriber are dropped and a `:degraded` notice is sent; a value that is
not a positive integer raises `ArgumentError` at start.

**What the streaming calls answer.** None of `subscribe/2`, `unsubscribe/2`,
`update_symbols/2` and `subscribe_notices/1` exits in your process. With no feed running,
`subscribe/2`, `update_symbols/2` and `subscribe_notices/1` answer `{:error,
:feed_not_started}`, `unsubscribe/2` answers `:ok` (nothing to stop) and `coverage/1` and
`coverage_by_kind/1` answer `%{}` ("not observed"). A busy feed is `{:error, :feed_timeout}`
and one that died mid-call `{:error, {:feed_exited, reason}}`. `{:error, {:invalid_symbols,
argument}}` is a `symbols` that is not a list of non-blank strings, and `{:error,
{:invalid_subscriber, term}}` a `:to` that is neither a pid nor a registered name; both are
refused before the shared feed sees them. Symbols are upper-cased on the way in and held in
canonical form (`"btcusd"` and `"BTC-USD"` are the same subscription). An `{:error, _}` from
`subscribe/2` or `update_symbols/2` means nothing was recorded, so retry.

**The first `subscribe/2` dials, and a dial never stalls the feed.** The connection is made by
the socket process itself, not inside the feed. While it is being made `coverage/1`,
`coverage_by_kind/1` and `subscribe_notices/1` answer at once. `subscribe/2`, `unsubscribe/2`
and `update_symbols/2` wait for the connection, in arrival order, and then answer as they
always did: `:ok` once the subscribe frame has gone out, or `{:error, reason}` (the connect's
own reason, such as a `%WebSockex.ConnError{}`) with nothing recorded. The wait is bounded by
the connect and receive timeouts (3 s and 2 s unless you pass `:socket_connect_timeout` /
`:socket_recv_timeout`). At most 1_000 such calls are held at once; one more is refused with
`{:error, :dial_backlog_full}`. A held call is replayed only if it can still finish before its
own 25 s call budget runs out (one 5 s send window per frame it sends, so a slow dial leaves
less room); one that cannot is answered `{:error, :dial_deadline_exceeded}` with nothing sent
or recorded, and a `subscribe/2` that gets it registered nothing, so retry it. A first connect
that fails raises no `:link_down` notice,
since there was no link to lose; the next periodic resubscribe (60 s) dials again, and a
failed attempt there is the usual one-shot `:coverage_change` notice.

Callbacks with no credentials argument (`get_positions/1` and its kin) read the credential
from `opts[:credentials]`.

## Nine candle widths, and the venue's own documentation names three of them wrong

Canonical widths this package serves: **`1m 5m 15m 30m 1h 6h 1d 1w 1M`** (`1w` and `1M`, the
venue's own `1mo`, joined 2026-09-08 and are not window-checked: a `:start` older than their
window is NOT refused with `{:error, {:range_unavailable, …}}`; you get only the bars the window
holds, so compare the first bar's `opened_at` with your `:start`). The shared vocabulary
also models `2h`, `4h` and `12h`; Gemini serves none of them, and asking is
`{:error, {:unsupported_timeframe, width}}` rather than the nearest width. A **perpetual**
symbol routes to the venue's derivatives candles endpoint, which serves `1m` only: any other
width for a perpetual is the same `{:unsupported_timeframe, width}` error, never a spot
series for a different instrument.

You will find Gemini's documentation listing `1h`, `6h` and `1d` as the literals to send.
**All three are rejected by the API.** The real literals are `1hr`, `6hr` and `1day`, and
this package sends those — you pass the canonical form and never see this. Measured
2026-08-28; the venue names its own accepted set in the 400 body:

```
time_frame expects one of the following: [1m, 5m, 15m, 30m, 1hr, 6hr, 1day]   (as of 2026-08-28;
it named `1w` and `1mo` as well by 2026-09-08)
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
call is the whole history the venue offers at that width. Do not build a paging loop. For
the same reason `opts[:limit]` is `{:error, {:unsupported_option, :limit}}`, never accepted
and ignored (BREAKING, tick R).

**The range and the bar still forming (BREAKING, tick R).** `:start` is inclusive and `:end`
exclusive, on `opened_at`; an absent `:end` is now (except with `include_partial: true`,
which applies no upper bound, so a bar the venue just opened is kept even if your clock runs
behind its). The bar that is still forming
(`opened_at + width > now`) is **not returned** unless you pass `include_partial: true` in
`opts`; with it the last bar comes back as the venue sent it and **may change on the next
call** (`Core.Types.Candle` has no flag for it). Before, the forming bar was always returned,
indistinguishable from a closed one. `include_partial` must be a boolean
(`{:error, {:invalid_option, :include_partial, value}}`). `range` must be a keyword list whose
`:start`/`:end` are `DateTime`s: a non-keyword `range`, or a bound that is not a `DateTime`,
is `{:error, {:invalid_range, range}}` (the whole range; it was
`{:invalid_range, :start | :end, value}` for a bad bound, BREAKING). A blank or non-string
symbol is `{:error, {:invalid_symbol, symbol}}`, decided before anything is sent. Bars come
back oldest first.

**`opened_at` must sit on the bar's width boundary, or the whole reply is refused**
`{:error, {:unaligned_candle, time}}`, and two bars with one timestamp in a reply refuse it
`{:error, {:duplicate_candle, opened_at}}`. The vendor does not say whether its candle
timestamp is a bar's open or its close, and its own example repeats a timestamp, so this
package fails closed rather than guess. **Both are UNMEASURED against the live venue.** `1w`
and `1M` have no modelled width and are not alignment-checked. An open, high, low or close
of zero or less refuses the reply (`{:error, {:non_positive_price, field, value}}`).

## `Quote.venue_time` is `nil`

Neither Gemini ticker publishes a quote time. `/v1/pubticker` has one, but it sits
**inside the `volume` object** — it stamps the 24-hour volume window and lags about a
minute. `/v2/ticker` has none at all.

`venue_time` is therefore `nil` on `get_price/2` and `get_top_of_book/2`, and the quote is
still returned: the traded price is real, and `observed_at` states freshness. The HTTP `Date`
header, which this package used until tick R, is when the reply was served and is no longer
used. It never substitutes the local clock, which is what makes a stale quote
indistinguishable from a live one. Write a `nil` branch.

A `last` of zero or less is not a price and refuses the reply
(`{:error, {:non_positive_price, :price, value}}`). In `get_top_of_book/2` a side priced `0`
is no resting order (`nil`); a negative or unreadable side refuses the reply
(`{:error, :unexpected_response_shape}`).

`Quote.volume` from `get_price/2` is the rolling 24-hour base volume (`volume_window:
:rolling_24h`), not any interval's volume, and no interval volume can be derived from it; the
streamed `Quote` has `volume: nil`. REST `TopOfBook` has `bid_size` and `ask_size` of `nil`
(the ticker publishes no sizes); the streamed one carries them.

If you need sub-second freshness, use `subscribe/2` — the `TopOfBook` it delivers carries a
real nanosecond event time per update. The `Quote` `subscribe/2` also delivers, on a frame
that carries a last trade, does not — see the correction below the `venue_time` heading near
the top of this file: the vendor documents no trade time for it, so it is `nil`
unconditionally, on this transport as much as any other.

`get_order_book/2`'s `venue_time` and the stream's partial-depth snapshot are covered at the
top of this file.

## Numbers keep every digit, on public reads as well as private ones

Gemini types some money fields as JSON numbers, not strings: a symbol's `tick_size` and
`quote_increment`, a perpetual's `fundingAmount`, staking `ratePct`, every price in a candle
row. A float holds about 17 significant digits, so a longer amount was rounded before this
package saw it. Public REST bodies are now decoded as `Decimal`s exactly (`floats:
:decimals`), as private ones have been since 0.2.108; the WebSocket channels send decimal
**strings** (`DecimalString` in the AsyncAPI document) and are unaffected. This needs
`dp_exchange_core ~> 0.3.65`, the first release that lets a venue decode its own bodies.

**A number of more than 34 significant digits is unreadable, under decimal 2 and 3 alike.**
This package accepts `decimal ~> 2.0 or ~> 3.0`, and the two differ here: decimal 3 refuses to
parse 35 digits and decimal 2 (down to its 2.0.0 floor) parses any length, so the same venue
string used to be a number under one and `nil` under the other. Every decoder here now refuses a
coefficient of 35 digits or more (a price, size or amount never has them), as it already refused
NaN, Infinity and an exponent past 100 either way. As a string that is the usual refusal of
that field (`{:invalid_decimal, field, value}`, or `nil` where the field is optional). As a bare
JSON number the refusal differs by version, and both are refusals: decimal 3 will not build the
number, so the whole reply is `{:error, {:undecodable_response, :gemini}}`; decimal 2 builds it
and the field is refused as above. An amount you pass in (`Decimal` or integer) is held to the
same bound: `{:error, {:invalid_quantity, value}}` and its kin, never a raise.

**A fractional JSON number where an object belongs is a shape error.** `floats: :decimals` makes
`1.5` a `%Decimal{}`, which is a struct and so also a map. A body such as `[1.5]` or `1.5` where
rows or an object belong used to reach `row["field"]` and raise in the calling process (on
`withdraw/5`, after the money moved). It is `{:error, :unexpected_response_shape}` now, or, for
the once-only writes, `{:error, {:write_unconfirmed, key, :unexpected_response_shape}}`;
`withdraw/5` keeps its documented answer for a 2xx it cannot read, `{:ok, %Withdrawal{}}` with
the `clientTransferId` it sent.

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

**The reason is the family's, never the venue's text** (BREAKING, a changed returned reason):

* `{:refused, :not_listed}` — the venue does not list the symbol. This is what a JSON
  `InvalidSymbol` (`get_order_book/2`, `quantization/1`, `list_instruments/1`'s
  `{:instrument_detail_failed, symbol, {:refused, :not_listed}}`, `place_order/3`), the
  plain-text 400 of `/v2/candles` (`Supplied value 'X' is not a valid symbol`), `get_trades/2`'s
  `BadRequest` and an empty 404 (`/v1/fundingamount`) all become. It replaces
  `{:refused, :invalid_symbol}`, `{:refused, {:invalid_symbol, text}}`, a bare
  `{:refused, :refused}` and `{:refused, {:unknown_reason, "Supplied value …"}}`. It is not
  `{:error, {:invalid_symbol, value}}`, which stays the local, before-any-request answer for
  a symbol that is not a non-blank string.
* `'X' does not have available data yet`, `/v1/pubticker`'s 404 (`get_price/2`,
  `get_top_of_book/2`), is `{:refused, :not_listed}` too: it was measured live (2026-09-06)
  for a symbol that does not exist. It replaces
  `{:refused, {:unknown_reason, "'X' does not have available data yet"}}`. This venue never
  answers the family's `{:refused, :no_quote}`: no listed-but-unquoted answer has been
  observed on it.

`Fake` answers the same reasons for the same inputs.

**Private (authenticated) calls refuse on every 4xx but a 429** (BREAKING, tick R: a 405,
409, 413, 415 or 422 was a bare `{:error, {:exchange_error, :gemini, "HTTP 4xx: …"}}`, which
a placement read as "nothing happened"). `rest.yaml` documents `404 NotFound` on the order
and account endpoints, so an unknown order or account is `{:refused, reason}`, permanent for
the request as sent, never the retryable `{:error, {:exchange_error, …}}` shape. An order
call's 404 whose JSON body names a reason other than `EndpointNotFound` is
`{:refused, :not_found}` (what the venue's body is for a truly unknown order is UNMEASURED; a
retired path or wrong host stays an ordinary refusal carrying the venue's words). A refusal
with an empty body is a bare `{:refused, :refused}`. A 429
and a 5xx stay plain errors (an order write answers `:order_unconfirmed` for the 5xx).

`get_historical_prices/4` and `get_trades/2` return the **canonical** symbol (`"BTC-USD"`)
whatever spelling you passed, as `get_order_book/2` and `get_price/2` always did.

**`get_trades/2` (BREAKING, tick R).** `:limit` is at most 500 (the vendor: "at most 500
records"); more is `{:error, {:invalid_option, :limit, value}}`. With `:since` or
`:since_tid`, the venue answers the most recent `limit` trades after the cursor, so a reply
of exactly `limit` rows (50 when you gave none) may have dropped older ones and is
`{:error, :history_truncated}`: narrow the cursor or raise the limit (UNMEASURED beyond the
vendor's text). A print priced at zero or less refuses the reply
(`{:error, {:non_positive_price, :price, value}}`); on the stream it is not delivered and a
`:data_quality` notice says so, and a book ticker's last trade `c` of zero or less is no
`Quote`. Other options: `:since` (a `DateTime` or non-negative integer), `:since_tid` (a
non-negative integer; it wins where both are given) and `:include_broken` (busted trades are
excluded unless you ask). Anything malformed is `{:error, {:invalid_option, key, value}}`
before a request is made. `Trade.side` is the taker's: `:buy` means a buyer lifted the offer.
The tape reaches seven days back, 90 with a timestamp.

### A refusal carries the venue's sentence, not only its category

Three shapes, and each means something different:

```elixir
{:refused, {:invalid_nonce, "Nonce '1757…' has not increased since your last call"}}
{:refused, :invalid_api_key}
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

**Under an incremental `nonce_mode:`, an `InvalidNonce` is re-signed once before you see it.**
Two of your processes draw ordered nonces, but the smaller can still reach the venue second,
and the venue refuses it without acting on it. Every signed private call answered that way is
signed again with a fresh nonce and sent once more, which is safe for a write because the
refused request did nothing. A `:invalid_nonce` that reaches you has therefore been refused
twice and is worth reading the sentence of. Under `:time_based` (the default) nothing is
re-sent: there the refusal means clock skew.



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

{:ok, last_trade} = DpExchange.Gemini.get_price("BTC-USD", environment: :sandbox)
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

Address a specific tree by naming it, or by the environment — the streaming calls
(`subscribe/2`, `unsubscribe/2`, `update_symbols/2`, `coverage/1`, `subscribe_notices/1`)
default to the feed the environment names, exactly as REST and the limiter do:

```elixir
:ok = DpExchange.Gemini.subscribe(["BTC-USD"], feed: DpExchange.Gemini.SandboxFeed, to: self())
:ok = DpExchange.Gemini.subscribe(["BTC-USD"], environment: :sandbox, to: self())
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

It **signs** a request when you hand it credentials. It never obtains, stores or refreshes
one. The scheme is read from which values you supplied (an `api_key`/`api_secret` pair is
`:api_key`; an `access_token` is `:oauth`), or named outright with `auth_scheme:` in `opts`.
Credentials carrying both families are refused as `{:error, {:unsupported_auth_scheme,
:ambiguous}}`, and none at all as `{:error, {:missing_credentials, :gemini}}`. An
`:auth_scheme` this package has no handler for is `{:unsupported_auth_scheme, scheme}`.

**Some writes are sent once and are not retried, on purpose.** `Core.HttpClient` retries a
timeout or a 5xx three times by default, which is safe only where the venue can tell the
second attempt from the first. Orders, conversions and staking are sent once;
`add_payment_method/2` and `create_account/1` are too, because a duplicate bank account or
subaccount is an artifact you would have to clean up by hand. `withdraw/5` **is** retried,
because it always sends a `clientTransferId` — generated if you give none — and the venue
answers a repeat with the original transfer. An accepted withdrawal is always `{:ok, _}` with an
id: the venue's `withdrawalId` where it sends a readable one, otherwise the `clientTransferId`
that went out. So an unreadable success body never reads as a failure you might retry under a
new key. `request_approved_address/4`, `remove_approved_address/3` and `cancel_all_orders/2` are
sent once too (they used to be retried; a repeat of one that took effect is answered as a
refusal or as empty lists, which read as "nothing happened"), as are `cancel_order/3`,
`get_deposit_address/3` (every call generates a NEW address), `confirm_clearing_order/3`,
`cancel_clearing_order/2`, `rename_account/3` and a token revoke. If one
of the once-only calls fails after the send it is `{:error, {:write_unconfirmed, key, reason}}`
-- see "A write that may have been acted on" below -- so check before you re-issue it. A
`place_order/3` that may have reached the venue is instead `{:error, {:order_unconfirmed,
client_order_id_or_nil, reason}}`: reconcile by listing orders, never by placing again. A
refusal decided before anything is sent (validation, credentials, our own limiter) stays a
plain `{:error, reason}`.

**A master-scoped API key names its subaccount with `account:` on every private call.** The
venue requires the account name on account-level endpoints for a master key and answers
`MissingAccounts` without it (dp-exchange-core issue #38). Pass `account: "primary"`, or the
subaccount's name from `list_accounts/1`, and it is added to every account-level payload.
Calls that act on the key or the group (`create_account/1`, `list_accounts/1`, `get_roles/1`)
never carry it. An account-scoped key needs nothing. In tests, a `Fake` credential with
`key_scope: :master` refuses an account-level call without `account:` exactly as the venue
does.


**An incremental key whose mark is above epoch milliseconds: use `nonce_mode:
:incremental_us`.** Both older nonce modes emit numbers below such a mark — `:time_based`
seconds, `:incremental` milliseconds — so every request comes back `InvalidNonce` and
switching between those two does not help. The venue's own sentence tells you which case you
are in: "has not increased since your last call" is the incremental validator, and a bad key
or signature would answer `InvalidApiKey` / `InvalidSignature` instead.

`:incremental_us` sends `max(now_us, previous + 1)`: microseconds, above any
millisecond-scale mark, re-anchored on every boot, so nothing has to be persisted or seeded
by you. It is a separate mode rather than a change to `:incremental` because moving a key
onto it is one-way: once the venue accepts a microsecond nonce, anything still counting in
milliseconds against that key is locked out. Choose it per key.

If the venue answers "has not increased" to `:incremental_us`, the call refuses with
`{:nonce_mark_out_of_reach, message}` rather than `{:invalid_nonce, message}`: the key's mark
is above epoch microseconds. Try **`nonce_mode: :incremental_ns`**, `max(now_ns, previous + 1)`
from its own counter, which reaches any mark below `2^64` (it stays below that until about
2554). Like `:incremental_us` it needs no seed and is one-way per key.

Under `:incremental_ns` the same `{:nonce_mark_out_of_reach, message}` means no nonce that
fits in 64 bits is above the mark. That is **not** proof the key is dead. If anything signed
for this key before this package did (your own earlier client, a script), and it sent larger
integers, the venue accepted them: it compares nonces as arbitrary-precision integers. The
mark is then above 64 bits, and the key is still valid (dp-exchange-core issue #37).

For that key, declare a scale: **`nonce_mode: {:incremental_ns, scale: k}`**, with `k` from 1
to 12, sends `max(now_ns, previous + 1) * 10^k` as a decimal string. It is fixed, it advances
with the clock, it needs no seed, and a restart keeps it working.

**Start at the smallest `k` that could work and go up one at a time.** A refused nonce does
not move the key's mark, so trying `k = 4`, then `5`, then `6` costs nothing. An accepted
nonce does: the first one accepted at `k = 9` sets the mark near `1e27`, and every smaller
scale is locked out of that key permanently. Record the `k` that works as part of that key's
configuration.

Under a scaled mode, `{:nonce_mark_out_of_reach, message}` means "declare the next scale".
Refused at `k = 12`, the mark is above ~`1.8e30`: **that key must be rotated**, so stop
retrying and have a person do it.

`seed_nonce/1` remains for the millisecond counter: call it once with a value above the mark
and the sequence advances by one per call from there. It refuses to lower the counter, a mark
at or beyond `2^64 - 1` cannot be reached at all (the next nonce would not fit), and a seed does not survive a restart.

**Fee promotions moved off the public path.** `GET /v1/feepromos`, which
`Rest.list_fee_promos/1` calls, is no longer in the vendor's specification as of 2026-09-21;
this venue announces removals by absence. Ask `get_fees/2` with `symbol:` instead — the
vendor moved the parameter onto the authenticated `/v1/notionalvolume`. `list_fee_promos/1`
is still declared `:experimental` rather than `:unsupported`, because a path missing from a
document is not a refusal the venue made and this repository cannot probe it to find out.

**A credential wrapped with `DpExchange.Gemini.Credentials.wrap/1` is the scheme of the values
it holds.** The struct always carries `api_key`, `api_secret` and `access_token`; only a
non-`nil` value counts, so a wrapped API-key pair is `:api_key` and not "both". (It used to be
refused as `{:unsupported_auth_scheme, :ambiguous}`.) `DpExchange.Gemini.Fake` refuses a blank
credential the same way the real call does.

**A blank credential counts as a missing one.** An `:api_key`, `:api_secret` or OAuth
`:access_token` that is `""`, or only whitespace, is refused with
`{:error, {:missing_credentials, :gemini}}` — the venue atom, as every venue in the family
answers (it used to be the scheme, `:api_key` or `:oauth`). A value with surrounding
whitespace (a trailing newline from a `.env` file) is refused as
`{:error, {:invalid_credentials, :gemini}}`, never trimmed and sent. Neither is ever signed
with. This matters because
the usual way a credential goes missing is not a `nil`: it is a `.env` line reading `NAME=`
with nothing after it, and `System.get_env/1` hands that back as `""`. HMAC over an empty key
is a perfectly good HMAC, so signing with it produced a well-formed request the venue refused
for a reason naming signatures — which points at the signing code rather than at the
credential.

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
this package credentials and — where `auth_scheme:` is needed to say it — the scheme: it **signs**,
it does not **authenticate**. What genuinely returns `{:error, :not_supported}` is the
venue's own absence (options, watchlists, financials — see `venue_does_not_serve/0`) and
the small remainder of this package's own backlog (
`list_portfolios/1`, `get_conversion/2`), not the authenticated surface as a whole. The
demo environment is what makes exercising any of this safely, before you point it at a
real account.

`DpExchange.Gemini.Auth` is internal (not the public API; the facade signs for you). Called
directly, its signing helper takes the scheme as an argument and refuses to guess:

```elixir
alias DpExchange.Gemini.Auth

{:ok, headers} = Auth.headers(:api_key, "/v1/balances", %{}, credentials)
{:ok, headers} = Auth.headers(:oauth, "/v1/balances", %{}, %{access_token: token})
```

Picking a scheme when both are present would be actively harmful: Gemini returns `AmbiguousAuthentication` (400) when V1
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

Where the nonce comes from, so you can reason about two callers using one key. Every
incremental mode draws from a node-wide counter shared by every process on the node and every
key (`max(now, previous + 1)`, a compare-and-exchange, so two processes never draw equal or
decreasing values, and a clock that steps backwards never lowers it). **Every attempt is signed
afresh**, so a retry after a transport error never re-sends a used nonce. Nothing coordinates
two nodes, or another client, using one key: that is the case `seed_nonce/1` and the finer
modes below exist for. A refusal the venue makes of a nonce is `{:refused, {:invalid_nonce,
message}}` (or `{:nonce_mark_out_of_reach, message}` under the finer modes), as above.

Three refusals are made here, before anything is signed or sent, and are never retried:
`{:error, {:unsupported_nonce_mode, mode}}` for a `nonce_mode:` this package has no nonce for (a
typo such as `:incremental_ms`, a scale outside 1 to 12, anything that is not a mode; judged
under an API key only, because an OAuth call carries no nonce), which `DpExchange.Gemini.Fake`
answers too; `{:error, :nonce_exhausted}` when the counter has reached `2^64 - 1` (rotate the
key); and `{:error, :unencodable_payload}` for a payload the JSON encoder cannot write (a pid or
a tuple inside `add_payment_method/2`'s details).

Note that a seconds-granularity nonce on an *incremental* key caps that key at **one
request per second**, a tenth of the private ceiling (600 per minute, ten a second). That is why the mode is
not something this package can paper over.

## Symbols are lowercase and separatorless, and the split is not obvious

Native form is `btcusd`, `aavegusd`, `jitosolsol`. Canonical is `BASE-QUOTE`. Pass
canonical; this package converts both ways.

Worth knowing if you do any symbol handling of your own: **157 of the 346 symbols live on
2026-08-28 end in a quote currency that is a suffix of another quote currency** — `GUSD` and `RLUSD` both
end in `USD`. A naive split on `USD` turns `aavegusd` into `AAVEG`/`USD`, and `AAVEG` is
not an asset. It matches no catalogue entry and collects nothing, silently.

The quote list, longest-first: `RLUSD USDC USDT GUSD USD EUR GBP SGD DAI BTC ETH SOL FIL`.

**Longest-first is not always right either.** `paxgusd` is PAXG/USD and `usdgusd` is
USDG/USD, but a longest-quote split reads both as `GUSD` pairs. This package maps both
correctly. They were the only two wrong splits among the 335 spot symbols live on
2026-09-27; see `DpExchange.Gemini.SymbolFormat`'s moduledoc for how that was checked. If
you split symbols yourself, use the venue's catalogue, not a suffix rule alone.

**Perpetuals are excluded** from `get_symbols/1`. Thirteen symbols carry a `perp` suffix;
they are real instruments, but `get_symbols/1` is the *spot* catalogue and does not list
them. `capabilities/0` declares `supported_instrument_types: [:spot, :perp]` — the
perpetuals surface has its own endpoints (`get_positions/1`, `get_contract_stats/2`,
`get_funding/2`, among others), not a place in this list.

**Unreadable is a refusal, never a `nil`.** A figure the venue left out (or sent as `null`) is
`nil`; one it sent and this package cannot read makes the call
`{:error, :unexpected_response_shape}`. This covers `get_balances/2` (`amount`, `available`),
`get_staking_rates/1` (`ratePct`, `rate`, `apyPct`, `depositUsdLimit`), `get_funding/2` (both
timestamps), the conversion calls (`price`, `fee`, `totalSpend`, `quantity`), and
`get_market_overview/1` (a row with no string `pair` refuses the whole overview). So a `nil`
in these structs always means "the venue stated none". It also covers `get_price/2` (`volume`)
and `list_approved_addresses/2` (`createdAt`). A money write whose 2xx reply is unreadable
(`withdraw/6` `fee`, `stake/4` / `unstake/4`) is `:write_unconfirmed` with the key sent: check
the account, do not resend. `place_order/3` is the exception: a reply naming a readable
`order_id` is returned as the placed `%Order{}` with any unreadable figure `nil` (you need the
id to cancel it); only a missing or unreadable `order_id` is `:order_unconfirmed`.

A `/v1/symbols` array holding an entry that is not a string is
`{:error, :unexpected_response_shape}`, not a shorter list.

An order read back has `order_type: nil` when the venue sent a `type` this package has no
atom for (it never reads as `:limit` by default). Match on `nil` as "not mappable".

## `:since` narrows a window as a `DateTime`, everywhere it appears — except the two staking reads

`get_orders/2` (with `history: true`), `get_trade_history/2`, `list_custody_fees/2` and
`list_accounts/1` accept `since: ~U[...]` and convert it to the venue's own unit
(milliseconds) before it goes on the wire — pass a `DateTime`, not a raw integer.
`get_trade_history/2`'s `:limit` and `:since` used to reach the venue as `to_string(value)`
instead — a `DateTime` became a string like `"2026-08-28 17:00:01Z"`, a shape
`/v1/mytrades`'s `timestamp` field does not parse, so the filter silently failed to narrow
anything. Fixed to match every other `:since`-accepting call in this module.

**`get_staking_history/1` and `get_staking_rewards/1` are the exception, not another
member of the rule above.** This section used to list them alongside the millisecond
converters; measured against the vendor's own OpenAPI spec (2026-09-29), both endpoints
document `since`/`until` as ISO datetime with timezone (`rest.yaml:6729,6733` and `:6896`;
both endpoints' own request examples give `"2022-11-01T00:00:00.000Z"`-shaped strings, not
a number). A `DateTime` given to either is formatted to ISO 8601, not converted to
milliseconds. `get_staking_rewards/1` additionally **requires** `:since` — the venue lists
it in the request schema's `required` fields (`rest.yaml:6885`) — and this package refuses
its absence locally as `{:error, {:missing_option, :since}}` rather than send the request
without it.

`get_staking_history/1`'s reply is nested, not a flat list of rows: an array of
`{providerId, transactions: [...]}` (`rest.yaml:6770-6794`), one entry per provider the
account has staked with. `provider_id` on each `StakingTransaction` this call returns comes
from the parent entry; the transaction itself carries none. A transaction's `dateTime` is read
as seconds or milliseconds, because the vendor's `TimestampType` (`rest.yaml:7900-7920`) allows
both and the payload names neither: only a value that dates 2015 to 2099 in one of the two units
is read, and anything plausible in neither (`10^11`, which is 1973 as milliseconds and the year
5138 as seconds) refuses the reply.

`get_transfers/2` is one exception: its filters (`currency:`, `timestamp:`,
`limit_transfers:`) are the venue's own field names and units unchanged, not translated —
see `Private.get_transfers/2`'s moduledoc. The venue pages it at 10 by default and 50 at
most, with no cursor, so with no `limit_transfers:` this asks for 50 and a full page is
`{:error, :history_truncated}` (exactly that, no payload; BREAKING, it carried the page size)
— narrow with `timestamp:`, or pass `limit_transfers:` to take one page on purpose.
`list_custody_fees/2` follows the same rule with `limit:`.

`get_transactions/2` is the other. `POST /v1/transactions` names its window parameter
`timestamp_nanos` and takes nanoseconds, but this call's `:since` is **milliseconds** (or a
`DateTime`) like every other `:since` above, and is converted (x 1_000_000) before it is
sent; only the clearing reads' explicitly named `:since_nanos` is nanoseconds. Because this one
call multiplies your number, its unit has to hold: a `:since` integer (or digit string) before
2015 in milliseconds, a seconds epoch for instance, is `{:error, {:invalid_option, :since,
value}}` instead of a 1970 window, and `:since_nanos` is refused the same way below 2015 in
nanoseconds. Every other window bound goes to the venue as given, and the venue reads it as
seconds or milliseconds. Without `opts[:limit]` this call also follows
the venue's own `continuationToken` across pages itself, at the documented maximum page of
300, and refuses (`{:error, {:too_many_pages, 50}}` or `{:error, :repeated_continuation_token}`)
rather than truncate or loop forever — `Core.Venue` types the result `[map()]`, so there is
nowhere to hand a page cursor back to the caller. Passing `opts[:limit]` returns exactly one
page of at most that many rows.

**Every one of these reads checks its paging and window options before anything is signed.**
`:limit` (`:limit_transfers` on `get_transfers/2`) is a whole number from 1 to the vendor's
maximum for that endpoint — 500 for closed orders, trade history, accounts and staking
history, 50 for transfers and custody fees, 300 for clearing trades and `get_transactions/2` —
and a window bound is a `DateTime`, a non-negative integer or a string of digits (the staking
windows: a `DateTime` or an ISO 8601 string). Anything else — `limit: 0`, `limit: "ten"`,
`since: ~D[2026-01-01]` — is `{:error, {:invalid_option, key, value}}`. A larger limit is
refused rather than clamped, because the vendor does not say what it does with one.
`DpExchange.Gemini.Fake` refuses the same values, and narrows its answers by the same options.

**`/v1/orders` (resting orders) takes no filter.** `get_orders/2` without `history: true`
sends none, so `symbol:` narrows nothing there; filter the result yourself.

**Other option values are checked the same way, before anything is signed**, each
`{:error, {:invalid_option, key, value}}` unless noted: `get_fees/2`'s `symbol:` (a non-blank
string), `get_order_book/2`'s `depth:` (a whole number, `0` included), `stake/3` and `unstake/3`'s
`provider_id:` (a non-blank string), the funding reports' `rows:` (a positive integer), `from:`
and `to:` (a `Date`, a `DateTime` or an ISO 8601 date string) and `funding_amount_report/2`'s
symbol (a non-blank string), and `withdraw/5` and `transfer_internal/4`'s `client_transfer_id:`
(a string; a blank one is none). A `memo:` that is not a string or a non-negative whole number is
`{:error, {:invalid_memo, memo}}`; a `get_deposit_address/3` asset that is blank or not a string
is `{:error, {:invalid_asset, asset}}`; a clearing id that is not a non-blank string is
`{:error, {:invalid_clearing_id, id}}`. The fake answers the same for each. The two payment
reports (`funding_payment_report/1`, `funding_payment_report_file/1`) take no symbol, so one in a
shared options list is not sent to them.

## A slow subscriber gets dropped, and told — it does not get an unbounded mailbox

If your process falls far enough behind that its mailbox reaches **10,000 queued
messages**, this package stops sending it events and emits a `Core.Notice`:

```elixir
%Core.Notice{
  kind: :degraded,
  severity: :warning,
  message: "subscriber #PID<0.123.0> is 10000 messages behind, past the 10000 bound — ...",
  details: %{subscriber: "#PID<0.123.0>", queue_len: 10_000, bound: 10_000, dropping: :newest}
}
```

and a second one, `severity: :info`, once you have drained below **half** the bound (5,000 by
default). Not merely back under it: a mailbox hovering at the bound used to flip on every
message, with a notice each time, into the same full mailbox. Now one stall costs one pair.
**Those two notices bracket exactly
the window you have to reconcile** from the pull endpoints — that is what the pair is for,
and why the recovery notice exists at all rather than just the alarm.

Three things are worth knowing about the shape of this:

- **The newest is dropped, not the oldest.** A sender cannot remove a message from your
  mailbox; only you can. So what happens is that nothing further is added while you are over
  the bound. It is also the better trade: a quote that arrives while you are ten thousand
  messages behind is stale by the time you would read it, and the frames it would have
  displaced are no fresher.
- **Only you are affected.** Another subscriber keeping up keeps receiving everything. One
  slow consumer is never allowed to become an outage for the others.
- **`coverage/1` does not change.** It reports what the *venue* delivered to this package,
  not what this package forwarded to you. A symbol whose frames are being dropped for your
  backlog is still arriving, and reporting it as `:not_covered` would point you at the venue
  when the backlog is yours.

Notices themselves are never dropped, whatever your queue looks like — the notice telling
you that you are being dropped must not be the first casualty of it.

Raise or lower the bound at start:

```elixir
{DpExchange.Gemini, max_queue_len: 50_000}
```

Any positive integer. It must be an integer — a string or a float raises at `init/1` rather
than quietly falling back to the default, because a back-pressure setting you believe you
configured and did not is worse than not having configured one.

**If you are seeing these notices, the fix is on your side.** Consume in a process that does
nothing else, or hand the payload straight to a queue or an ETS table and do the work
elsewhere. The bound is not a tuning knob for throughput; it is the line past which this
package stops writing into memory you are not reading.

## Telemetry: attach one handler, see every venue

This package emits the `:telemetry` events `DpExchange.Core.Telemetry` documents. Attach to
the names, not to anything venue-specific:

```elixir
:telemetry.attach_many(
  "dp-exchange-metrics",
  DpExchange.Core.Telemetry.event_prefixes(),
  &MyApp.Metrics.handle/4,
  nil
)
```

`:provider` in the metadata is how you tell venues apart — one handler covers the whole
family.

**These names were documented long before anything emitted them.** If you attached a handler
before this version and saw nothing, that was not your venue being quiet:
`:telemetry.attach/4` against a name nobody emits succeeds, so an empty panel was
indistinguishable from no traffic. Every one of them fires now.

Four things to know before you build on them:

- **Telemetry is the metrics channel; `Core.Notice` is the action channel.** Telemetry is
  aggregate and lossy by design. Alarm on notices. Graph telemetry. Alarming on a gauge
  documented as droppable is how a missed sample becomes a page at 3am.
- **`:stop` fires for every outcome**, success or error. That is deliberate: a latency panel
  built on successes alone shows a venue getting *faster* exactly as it starts failing,
  because the slow calls are the ones dropping out of the sample. `:exception` is a separate
  event from a `:stop` carrying an error — an error result is the venue answering badly, an
  exception is this package failing to ask.
- **`retry_after_ms` is always milliseconds**, including where the venue's own header is in
  seconds. A panel summing a mixture of the two is wrong by a factor of a thousand without
  ever looking wrong.
- **`:bytes` may be absent from `[:dp_exchange, :link, :event]`**, and absent is not zero. A
  polling route has no frame, so there is no byte count that means what a socket's does.
  Treat a missing `:bytes` as "this route cannot measure that", not as no data. This
  package's socket does report it, per frame.
- **Every `[:dp_exchange, :link, :up]` is closed by a `[:dp_exchange, :link, :down]`**,
  including when the socket process crashes rather than disconnecting (the feed emits it
  from the crash, once, with the bounded reason text). A link gauge built on the pair does
  not stay "up" for a connection that is gone.
- **Reconnect delay is the delay actually waited.** The `delay_ms` of the reconnect-attempt
  event is the jittered wait (up to a quarter shorter than the 1s-doubling-to-30s ladder),
  not the ladder's rung, so two sockets retrying together report different values.

`:endpoint` metadata is the request URL with the query string removed. Deliberate: telemetry
metadata reaches logs, aggregators and third-party exporters, and the query string is the one
part of a URL that can carry a token.

## Every capability claim is dated, and says what it was measured against

`capabilities/0` carries two provenance fields, and they are there to be read:

```elixir
caps = DpExchange.Gemini.capabilities()
caps.measured_at       # ~D[...] — when someone last checked
caps.measured_against  # what they checked: which documents, which endpoints, live or not
```

**`measured_against` is the one that matters when you are deciding how much to trust a
claim.** It distinguishes a figure measured live against the venue's API from one read off a
documentation page and never probed — and this package's own declarations contain both
kinds, stated per claim rather than as one blanket sentence.

A claim read from documentation is not worse, it is *different*: it is what the vendor says
it will do, which is the right basis for a ceiling you must not exceed and a weaker basis for
behaviour you are about to depend on. If your decision turns on the difference, read the
field rather than assuming.

`measured_at` going stale is a real thing that happens — venues change, and a declaration is
a claim about a real venue. `script/check_doc_sources.sh` runs weekly in this package's CI and
reports how long since each vendor page it cites was last read (STALE past 180 days) so the
sources do not quietly get old, but it does not re-measure a capability, and nothing forces
that: if you are relying on a capability in
a way you cannot afford to have wrong, check the date and, where it matters, verify against
the venue yourself.

## What this package does not do

Authenticated endpoints are **not** on this list — see "This package does not handle
authentication — you do", above: balances, orders, fees, transfers, trade history and the
rest of the account surface are implemented and signed on request; only obtaining,
storing, refreshing or choosing between credentials is the host's job.

## `get_symbols/1` includes closed pairs; `list_instruments/1` says which are trading

`/v1/symbols` keeps **closed** symbols, and so does `/v1/pricefeed`. On 2026-10-08,
`efilfil` was in both, and only its details said `"status":"closed"`. So `get_symbols/1`
can hand you a pair the venue does not trade, and nothing in it says so.

`list_instruments/1` reads each symbol's details and answers `Core.Instrument`s with a
`status`: `open` → `:tradable`; `closed` → `:delisted`; `post_only`/`limit_only` →
`:tradable`; `cancel_only` and anything unrecognised → `:unknown`. **It costs one request
per symbol**, because the venue has no bulk details endpoint:

```elixir
# Cheap: just the pairs you are deciding about.
{:ok, instruments} = DpExchange.Gemini.list_instruments(symbols: ["EFIL-FIL", "BTC-USD"])

# The whole catalogue: ~347 paced requests. Run it rarely, not on a poll.
{:ok, all} = DpExchange.Gemini.list_instruments()
```

Each request waits for its rate-limiter slot, so the venue's ceiling holds, but the full
listing spends minutes of the public budget. A symbol whose details cannot be read fails the
whole call (`{:error, {:instrument_detail_failed, symbol, reason}}`), so the answer never has
a silent hole in it.

`symbols:` is read by the pair, not by what you typed: `["BTC-USD", "btcusd"]` is one request
and one instrument. A value that is not a list of strings (`symbols: "BTC-USD"`, `[nil]`) is
`{:error, {:invalid_option, :symbols, value}}`.

## A symbol list that is not a list of strings is refused, not sent to the feed

`subscribe/2`, `unsubscribe/2` and `update_symbols/2` answer
`{:error, {:invalid_symbols, offenders}}` for a list holding anything but non-blank strings,
and for a value that is not a list at all (`subscribe("BTC-USD")`). Spellings are
canonicalised and de-duplicated first, so `["btcusd", "BTC-USD"]` is one symbol. Nothing is
subscribed on an error. This used to raise inside the shared feed process, which crashed it
and, on its restart from the static options, dropped every other consumer's subscription.
`DpExchange.Gemini.Fake` answers the same.

`subscribe([])` registers your subscriber and opens nothing: no socket is dialled until a
`subscribe/2` names a symbol. `coverage/1` and `coverage_by_kind/1` answer `%{}` for a feed
addressed by a pid on another node (it cannot be checked from here).

## A single-symbol read refuses a symbol that is not a non-blank string

`get_price/2`, `get_top_of_book/2`, `get_order_book/2`, `get_historical_prices/4`,
`get_trades/2`, `quantization/1`, `get_funding/2`, `get_contract_stats/2` and
`next_funding_timestamp/2` answer `{:error, {:invalid_symbol, value}}` for `nil`, an atom, an
integer, `""` or whitespace, before any request. They used to raise `FunctionClauseError`
(and `""` sent `GET /v1/pubticker/` with an empty path). `get_historical_prices/4` likewise
answers `{:error, {:invalid_range, range}}` for a `range` that is not a keyword list or whose
bound is not a `DateTime`.
`DpExchange.Gemini.Fake` answers the same.

## An option a call does not read is refused, not ignored (BREAKING)

A misspelt `limt:` or `sinse:` used to be dropped, and the call answered a different question
from the one you asked. Every facade function that takes `opts` now answers
`{:error, {:unknown_option, key}}` for the first key it does not read, and
`{:error, {:invalid_options, opts}}` for options that are not a keyword list, **before
anything is sent** and before the credential is read. A key holding `nil` counts (`limt: nil`
is refused too). `DpExchange.Gemini.Fake` answers the same, from the same table. A call this
venue does not serve (`{:error, :not_supported}`) keeps answering that, whatever the options.
`coverage/1`, `coverage_by_kind/1`, `wanted/1` and `live?/1` return a plain value with no
room for an error, so they raise `ArgumentError` instead. Requires `dp_exchange_core
~> 0.3.101`.

Order of checks: a market-data symbol first (`{:invalid_symbol, _}`), then the options, then
the credential. `subscribe/2`, `unsubscribe/2` and `update_symbols/2` check the symbols
first. `transfer_internal/4` checks its `[from:, to:, client_transfer_id:]` terms (and
`:credentials`, which every call may be handed), then `opts`, then the asset and amount
(`{:invalid_amount, value}`) before the account names inside the terms.

**A call that sends an HTTP request accepts** the transport keys `:credentials :environment
:base_url :plug :adapter :req_adapter :limiter :rate_limit_blocking :weight :timeout
:retry_attempts :retry_delay :max_retry_after_s :max_body_bytes :log_requests`, and every one
of them is forwarded to `Core.HttpClient` (a `weight: 7` is what the limiter is asked for; a
`max_body_bytes:` smaller than the reply is `{:exchange_error, :gemini,
{:response_too_large, limit}}`). Three exceptions, each refused as `{:unknown_option, key}`
because the call can never honour it: the writes that are **sent exactly once** (`place_order`,
`cancel_order`, `cancel_all_orders`, `commit_conversion`, `convert`, `get_deposit_address`,
`add_payment_method`, `transfer_internal`, `request_approved_address`,
`remove_approved_address`, `stake`, `unstake`, `create_account`, `rename_account`,
`revoke_access_token` and the four clearing writes) never read `:retry_attempts` or
`:retry_delay` (there is no retry to wait before), since the venue has no idempotency key and a
retry could do the money movement twice; and `refresh_access_token/3` (a single-use refresh
token, sent once) reads neither `:environment` nor `:base_url`, since it posts to `:auth_url`,
nor `:retry_attempts` or `:retry_delay`.

**A call that sends no request accepts no transport key** but `:credentials` (every call may
be handed one credential set), and `:environment` where it picks the feed or the environment:
`market_status/1` (answers `:open` from nothing) takes `:credentials` only; `subscribe/2`,
`unsubscribe/2`, `update_symbols/2`, `subscribe_notices/1`, `coverage/1`,
`coverage_by_kind/1`, `wanted/1` and `live?/1` take `:credentials`, `:environment` and the keys
in the table below. A `timeout: 5_000` there is `{:error, {:unknown_option, :timeout}}` (a
raised `ArgumentError` on the plain-value reads), on the facade and on the Fake: nothing would
read it. A signed call also accepts
`:nonce_mode :auth_scheme :account`; `create_account/1`, `rename_account/3`,
`list_accounts/1` and `get_roles/1` act on the key or the group and do not accept `:account`.
**`:account` with OAuth credentials is `{:error, {:unsupported_option, :account}}`**, on every
signed call, before anything is sent: an OAuth call signs nothing and carries no body, so the
named subaccount could not reach the venue and the token's own account would answer instead.
`:account` is for API-key (master key) calls. `rename_account/3` included: its `:account`
(the account to rename) cannot be sent under OAuth either.

**The rest, per function** (the single source is `DpExchange.Gemini.OptionKeys`, which
`allowed/1` answers from):

| Function | Its own keys |
|---|---|
| `get_price/2`, `get_top_of_book/2`, `get_symbols/1`, `get_market_overview/1`, `list_fee_promos/1`, `get_staking_rates/1`, `get_funding/2`, `get_contract_stats/2`, `next_funding_timestamp/2`, `market_status/1` | none |
| `get_historical_prices/4` | `:include_partial`, `:limit` (`:limit` is `{:unsupported_option, :limit}`) |
| `get_order_book/2` | `:depth`; `:limit` is answered `{:unsupported_option, :limit}` (depth is `:depth`) |
| `get_trades/2` | `:since`, `:since_tid`, `:limit`, `:include_broken` |
| `list_instruments/1` | `:symbols` |
| `subscribe/2` | `:to`, `:feed`, `:name`, `:channels` (`:channels` is `{:invalid_option, :channels, _}`) |
| `unsubscribe/2`, `update_symbols/2`, `coverage/1`, `coverage_by_kind/1`, `wanted/1` | `:feed`, `:name` |
| `subscribe_notices/1` | `:to`, `:feed`, `:name` |
| `live?/1` | none (and only `:credentials` and `:environment` beyond them) |
| every call that sends a request, except `rename_account/3` and `create_account/1` | also `:name` (the tree whose limiter meters it; see "Running two") |
| `get_balances/2`, `get_accounts/2`, `place_order/3`, `cancel_order/3`, `get_order/3`, `test_connection/2`, `get_notional_balances/3`, `get_trade_volume/2`, `get_fx_rate/3`, `list_payment_methods/2`, `transfer_internal/4`, `remove_approved_address/3`, `get_staking_balances/1`, `get_positions/1`, `get_margin_rates/1`, `preview_margin_order/2`, `get_clearing_order/2`, `cancel_clearing_order/2`, `confirm_clearing_order/3`, `get_roles/1` | none |
| `get_fees/2` | `:symbol` |
| `get_transfers/2` | `:limit_transfers`, `:currency`, `:network`, `:timestamp`, `:show_completed_deposit_advances` (boolean) |
| `get_orders/2` | `:history`, `:symbol`, `:limit`, `:since` |
| `get_trade_history/2` | `:symbol`, `:limit`, `:since` |
| `cancel_all_orders/2` | `:scope` |
| `get_transactions/2`, `list_custody_fees/2` | `:since`, `:limit` |
| `list_networks/2`, `list_approved_addresses/1` | `:network` |
| `get_deposit_address/3` | `:label`, `:legacy` |
| `estimate_withdrawal_fee/4` | `:address` |
| `withdraw/5` | `:memo`, `:memo_required`, `:client_transfer_id` |
| `add_payment_method/2` | `:country` |
| `request_approved_address/4` | `:memo` |
| `get_staking_rewards/1` | `:since`, `:until`, `:provider_id`, `:currency` |
| `get_staking_history/1` | `:limit`, `:since`, `:until`, `:provider_id`, `:currency`, `:interest_only` (boolean), `:sort_asc` (boolean) |
| `stake/3`, `unstake/3` | `:provider_id` |
| `quote_conversion/4`, `convert/4` | `:symbol`, `:side` |
| `commit_conversion/2` | `:symbol`, `:side`, `:amount`, `:price`, `:fee` |
| `get_account_margin/1`, `get_margin_account/1` | `:symbol` |
| `list_funding_payments/1` | `:since`, `:to` |
| `funding_payment_report/1`, `funding_payment_report_file/1`, `funding_amount_report/2` | `:from`, `:to`, `:rows` (no `:symbol`: a payment report takes none and a stray one used to be dropped; the amount report's symbol is its argument) |
| `create_clearing_order/2` | `:counterparty_id`, `:expires_in_hrs` |
| `create_broker_clearing_order/2` | `:source_counterparty_id`, `:target_counterparty_id`, `:expires_in_hrs` |
| `list_clearing_orders/1` | `:symbol`, `:counterparty`, `:side`, `:expiration_start`, `:expiration_end`, `:submission_start`, `:submission_end`, `:funded` (boolean), `:status`, `:timestamp`, `:limit_orders` (whole number >= 1) |
| `list_clearing_brokers/1` | `:symbol`, `:expiration_start`, `:expiration_end`, `:submission_start`, `:submission_end`, `:funded`, `:status`, `:timestamp`, `:limit_orders` |
| `list_clearing_trades/1` | `:symbol`, `:limit`, `:since_nanos`, `:timestamp`, `:limit_trades` (`:since_nanos` with `:timestamp`, or `:limit` with `:limit_trades`, is `{:error, {:conflicting_options, [first, second]}}`) |
| `create_account/1` | `:name`, `:type` |
| `rename_account/3` | `:shortname` (`id` and `name` are arguments) |
| `list_accounts/1` | `:limit`, `:since` |
| `refresh_access_token/3` | `:client_secret`, `:auth_url` (no `:environment`, `:base_url`, `:retry_attempts` or `:retry_delay`) |
| `revoke_access_token/1` | none (the token names the account; a stray `:account` is refused; no `:retry_attempts` or `:retry_delay`) |

## An error from `subscribe/2` or `update_symbols/2` means nothing was recorded

If `subscribe/2` answers `{:error, _}` (the connection could not be dialled, or the frame
could not be sent) the symbols and your subscriber are not registered, and a frame that may
have landed is unsubscribed on the next resubscribe tick. Retry if you still want them. A
failed `update_symbols/2` leaves the previous symbol set in force. Before this, the error was
returned but the symbols stayed registered and were dialled and sent on the next tick, so a
caller that gave up on them received them anyway.

`unsubscribe/2` is the other way round on purpose: it stops delivery at once even when the
wire send fails, answers the error, and retries the wire unsubscribe on the tick.

**The feed keeps one wanted set, not one per subscriber.** When the last subscriber that is a
pid dies, everything wanted is released as an `unsubscribe/2` of all of it would (the wire
unsubscribe is retried on the tick if it fails). A subscriber registered by name is never
monitored, so one of those keeps the set alive. While at least one subscriber remains, a
subscriber's death releases nothing: the symbols are shared, so unsubscribe them yourself.

`to:` must be a pid or a registered name. Anything else (`to: "consumer"`, `to: true`) is
`{:error, {:invalid_subscriber, value}}` from `subscribe/2` and `subscribe_notices/1`, before
the shared feed process sees it. `DpExchange.Gemini.Fake` answers the same.

## A repeating notice is forwarded once per 30 seconds

`:data_quality`, `:refusal` and `:degraded` notices that arrive per frame (an unreadable
bookTicker level, a refused subscribe, a depth gap) are forwarded once per
`{kind, reason, symbol}` per 30 seconds (a refused subscribe's reason is the one atom
`:subscribe_refused`, so the venue's status stands in for it: a 400 and a 429 are separate
keys). The first one after the window carries `details.suppressed`, the number it covers.
Lifecycle notices (`:link_up`, `:link_down`, `:coverage_change`) are never throttled.

## Notice shapes: kinds, `details.reason`, `details.symbols`

* **`:data_quality`** is a sequence gap (`:sequence_gap`, `:sequence_restart`) or data this
  package cannot decode (`:undecodable_depth_update`, `:unreadable_partial_depth_snapshot`,
  `:unattributable_partial_depth_snapshot`, `:undecodable_book_ticker`,
  `:unreadable_book_ticker_level`, `:undecodable_trade`, and `:undecodable_frame` for a text
  frame that is not a JSON object: `details.bytes` is its size, never its text).
  **`:degraded`** stays for "a slower
  path is in use or the link is not serving" (`:silent_connection`, `:subscribe_unanswered`,
  a dropped slow subscriber). This moved: a gap and an undecodable depth update were
  `:degraded` (BREAKING for a consumer matching the kind).
* **`:refusal`** is the venue declining a subscription. It carries `details.symbols` (a list
  of canonical symbols of the request it answers, `[]` when the request is not one this
  package tracked), `details.subscribe_status` and `details.reason: :subscribe_refused`.
* **`details.reason` is always an atom.** Free text, where there is any, is in
  `details.message`. A `:link_down` from the socket is `reason: :disconnected` and a socket
  crash `:socket_crashed`; a failed periodic resubscribe `:resubscribe_failed`; each carries
  the bounded text of the underlying reason in `details.message`. They were strings
  (BREAKING).
* **`:credentials_rejected` is never emitted, because no Gemini feed authenticates.** The
  streams are public (`bookTicker`, `trade`, depth), and a private channel is refused at
  `Socket.subscribe/3` with `{:error, {:credential_required, channel}}` before anything is
  sent. A rejected key surfaces on the private REST calls, as `{:refused, reason}`.
* **`wanted/1`** answers the symbols you asked the feed to stream, sorted and canonical, as
  opposed to `coverage/1`, which is what has arrived. `[]` with no feed running.
  `DpExchange.Gemini.Fake.wanted/1` answers the same.
* **A plaintext `:base_url` or `:auth_url` is `{:error, {:insecure_url, :gemini}}`** (the
  venue, not the option name; it was `{:insecure_url, :base_url | :auth_url}`, BREAKING),
  refused before anything is signed. Loopback over `http` stays allowed.

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

**A flat row is not returned at all, as of 0.2.31.** A position of exactly zero used to come
back with `side: nil`; it is now dropped. `Core.Types.Position` types `:side` as
`:long | :short` with no `nil` in it, so the old value had no meaning in the contract, and
`Position.from_signed_quantity/1` says why dropping is the answer: "a zero-quantity position
should generally not be built at all: a closed position is not an open one". The venue agrees
— the field is called `openPositions`.

So **do not read an absent symbol as "no longer traded"**; read it as "nothing open". A
quantity this package could not READ is a different case and still fails the whole call,
because that is a decode failure rather than a fact about the account.

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

`provider_id` is **required** on `stake/3` and `unstake/3`, as a non-blank string: absent is
`{:error, :missing_provider_id}`, anything else is `{:error, {:invalid_option, :provider_id,
value}}`. The same asset stakes with several providers at different rates, and this package
will not pick one for you.

**`get_staking_rewards/1` returns one `StakingReward` per rate period, not per currency.**
`POST /v1/staking/rewards` answers an object keyed by provider, then by currency, each
holding a `ratePeriods` list — the asset earned at more than one rate over the window, if
the rate changed, and each period gets its own row with its own `apy_pct`. `period_start`
and `period_end` are that period's own `firstAccrualAt`/`lastAccrualAt`; where the venue
reports neither, both stay `nil` rather than the window that was asked for, which the
venue is free to clamp.

## Clearing is not the order book

A clearing order is one half of a trade agreed with a named counterparty and **does nothing
until that counterparty confirms**. Read `is_confirmed`, not `status`.

`confirm_clearing_order/3` **re-states every term** — symbol, amount, price, side — and this
package fills none of them in from the order being confirmed. That is the whole point of the
check: reading them back from the venue would confirm whatever the venue had.

A confirm or cancel the venue declines is still HTTP 200 with a `result` other than the
success word; it comes back `{:refused, body}`, not `{:ok, body}`, and a 200 naming no
`result` is `{:error, :unexpected_response_shape}`. On a confirm, `side` is the confirming
party's own side — the opposite of the side the order was created with.

The broker form names **both** counterparties and `side` belongs to the *source*. Passing the
two the wrong way round produces a valid order in which each side trades the direction the
other meant.

## Administration: the name you send is not the name you address by

`create_account/1` takes a display name and the venue answers with a kebab-cased
**shortname** — and that shortname is what every other endpoint's `account` parameter takes.
Keep what came back, not what you sent.

`list_accounts/1` **caps at 500 and does not paginate.** A larger group comes back truncated
with nothing to say it was; there is no cursor to follow. With no `:limit`, a page that full is
`{:error, :history_truncated}` rather than a list that reads as complete; pass `:limit`
to take one page on purpose. Every history read that can fill its page answers this one
shape (`get_orders/2`, `get_trade_history/2`, `get_transfers/2`, `list_custody_fees/2`,
`get_staking_history/1`, `funding_payment_report/1`, `list_clearing_trades/1`).

`get_roles/1` answers with three booleans rather than one role, because `Fund Manager` and
`Trader` combine and `Auditor` combines with nothing.

## OAuth: refreshing rotates the refresh token

`refresh_access_token/3` posts a **form** to `exchange.gemini.com/auth/token` — a different
host from every other call here, and the same URL your own initial code exchange posts to,
separated only by `grant_type`.

**The response carries a new refresh token and the old one stops working.** Store both. A
caller that keeps only the access token has a session that ends at the next refresh.

The refresh is sent **once**, never retried by this package: a retry after a timeout would
present the already-rotated token and lose the new pair. If it returns `{:error, _}`, the
outcome is unknown — try the refresh token you hold, and if the venue refuses it, the
session needs a new consent. Only a 400, 401 or 403 is `{:refused, body}` (the OAuth error
map, e.g. `%{"error" => "invalid_grant"}`); any other status is
`{:error, {:exchange_error, :gemini, _}}`. `client_secret:` is sent only when given (a
confidential client); one that is not a string is
`{:error, {:invalid_option, :client_secret, :redacted}}`, the value kept out of the result.

A blank client id or refresh token, or one that is not a string at all (a `nil` from an unset
variable), is refused before anything is sent
(`{:error, :client_id_required}`, `{:error, :refresh_token_required}`). The shape of a
successful reply is **unmeasured**: the vendor's OpenAPI document does not describe
`/auth/token`, so the decoded body is returned as the venue sent it and is not checked for an
`access_token`. Check it yourself before replacing the token you hold. It must be a JSON
object: a `2xx` whose body is a list, a string, `null` or a number is
`{:error, :unexpected_response_shape}`, and the outcome is as unknown as any other error here.

`revoke_access_token/1` needs an OAuth token and refuses an API key
(`{:error, :oauth_token_required}`): an API-key-signed call there would revoke nothing and
come back shaped like success.

## The spreadsheet reports are bytes

`funding_amount_report/2` and `funding_payment_report_file/1` return the venue's file
unparsed. This package ships no spreadsheet reader and will not grow one: a parsed cell is a
number this package chose from a layout the venue can change without notice.

`from` and `to` must be given **together or not at all** — the venue makes each mandatory if
the other is present, and one alone comes back bounded by `numRows` instead, which is a real
report over the wrong window. One alone is `{:error, :from_and_to_together}`.

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

## A write the venue cannot deduplicate is sent exactly once, and never retried

`Core.HttpClient` retries any failure that is not a 4xx — a timeout, a connection reset, a
503. For a read that is right: asking the same question twice costs a request and nothing
else. For a write it is not, because those are precisely the failures where the venue may
have **received and acted on** the request before the connection broke. A retried order is a
second order, and you see one call and one answer either way.

So order-creating and order-changing calls here are sent once, and so are
`transfer_internal/4`, `create_clearing_order/2` and `create_broker_clearing_order/2`.
Every attempt is signed with a fresh nonce, so a retry is a new request under API-key auth
as well as under OAuth (which has no nonce): it takes effect again, or is refused because the
first already did. Before 0.2.54 those three were retried.
`commit_conversion/2`, `confirm_clearing_order/3`, `cancel_clearing_order/2`,
`rename_account/3` and `revoke_access_token/1` are sent once too: a repeat of any of them is
answered as a refusal ("quote spent", "already confirmed", "no such account", 401) for
something that worked. A transport failure comes back
to you as an error, and **the outcome of that attempt is genuinely unknown** — the order may
or may not exist at the venue. Read your open orders before placing again; do not treat the
error as "it did not happen".

This is not a blanket ban on retrying. It is a ban on repeating an action the venue cannot
tell apart from the first one. Reads still retry, and so does any write carrying an
idempotency key the venue honours.

## A write that may have been acted on: `{:error, {:write_unconfirmed, key, reason}}`

Applies to every state-changing call that is not an order: `withdraw/5`, `transfer_internal/4`,
`convert/4`, `commit_conversion/2`, `stake/3`, `unstake/3`, `create_clearing_order/2`,
`create_broker_clearing_order/2`, `confirm_clearing_order/3`, `cancel_clearing_order/2`,
`add_payment_method/2`, `request_approved_address/4`, `remove_approved_address/3`,
`cancel_all_orders/2`, `revoke_access_token/1`, and (since tick AN; each used to answer a bare
`{:error, _}` after a send) `get_deposit_address/3`, `create_account/1` and `rename_account/3`.
For `create_account/1` and `rename_account/3` a `2xx` that is not an object is unconfirmed
too; `get_deposit_address/3` keeps `{:error, :unexpected_response_shape}` for one (a new
address is the venue's to mint again, and none was handed back to lose).

A failure after the request may have reached the venue -- a timeout or connection failure, a
5xx, a `2xx` that is not JSON or whose body cannot show what was done -- is never a bare
`{:error, _}` (which reads as "nothing happened" and invites a duplicate). It is
`{:error, {:write_unconfirmed, key, reason}}`, `reason` bounded to 256 characters, and `key` the
handle to reconcile with:

| Call | `key` |
|---|---|
| `withdraw/5` | the `clientTransferId` sent, **generated ones included**; re-send with `client_transfer_id: key` and the venue deduplicates |
| `transfer_internal/4` | the `clientTransferId` sent (generated or yours); the venue does not promise to deduplicate it, so look the transfer up rather than re-sending |
| `commit_conversion/2` | the quote id |
| `confirm_clearing_order/3`, `cancel_clearing_order/2` | the clearing id; read it with `get_clearing_order/2` and trust `is_confirmed` |
| `stake/3`, `unstake/3` | the `transactionId` when the reply carried one, else `nil` |
| every other call above | `nil` (the venue gives it no key): look at the account first |

`withdraw/5` is the one write retried internally (it carries a key the venue honours), so it also
answers unconfirmed when the venue **refuses a retry** (a 4xx or an `error` body to the second
attempt, e.g. a duplicate `clientTransferId`: that is the venue answering a repeat of a request
it may have taken, not a verdict on the first) and when our own limiter turns a retry away after
an earlier attempt went out. A refusal to the only attempt made, a refusal decided before the
send (validation, missing credentials) and our own limiter refusing before anything was sent
stay what they were. A `2xx` object that is missing fields is still a success: `withdraw/5` is
`{:ok, %Withdrawal{}}` with the id, and `stake/3` is `{:ok, %StakingTransaction{}}` with an
unreadable optional field `nil`.

Amounts for `withdraw/5`, `transfer_internal/4`, `stake/3`, `unstake/3`, `quote_conversion/4`,
`convert/4`, `commit_conversion/2` (amount, price and fee) and the clearing calls are `Decimal`s,
integers or numeric strings. **A float is `{:error, {:invalid_amount, value}}`**: it has already
lost digits. `transfer_internal/4`'s `from:` and `to:` are non-blank strings
(`{:error, {:invalid_option, key, value}}`) and must differ
(`{:error, {:invalid_transfer, :same_account}}`); so are a broker clearing order's
`source_counterparty_id:` and `target_counterparty_id:`.

`DpExchange.Gemini.Fake` refuses the same inputs in the same order. `commit_conversion/2`
returns the pair, rate, fee and quantity that were committed (a buy gives up the quote asset
for the base, a sell the reverse; the other amount is `nil` because the venue reports none),
`withdraw/5` with no key returns a unique generated id, and `transfer_internal/4` returns the
venue's own reply fields (`fromAccount`, `toAccount`, `amount`, `uuid`, `message`) and no
echo of the request's `asset`.

## `place_order/3`: an order says what it is, and an unknown outcome names the id to look for

**Nothing is defaulted.** A request is a plain map of `:symbol`, `:side`, `:order_type`,
`:quantity` and `:price`, plus `:time_in_force` on a `:limit` order, `:stop_price` on a
`:stop_limit` order, and optionally `:client_order_id`. Every answer below is decided before
anything is signed, in this order:

| Request | Answer |
|---|---|
| not a plain map | `{:error, {:invalid_order_request, request}}` |
| a key outside the list above (`post_only: true`, `"symbol"`) | `{:error, {:unsupported_order_field, key}}` |
| `:symbol` nil, not a string, or blank | `{:error, {:invalid_symbol, value}}` |
| `:side` absent / not `buy` or `sell` (atoms, or strings in any case) | `{:error, {:missing_field, :side}}` / `{:error, {:invalid_side, value}}` |
| `:order_type` absent | `{:error, {:missing_field, :order_type}}` |
| `:market`, `:stop`, `:maker_or_cancel`, anything else | `{:error, {:unsupported_order_type, type}}` |
| `:limit` with no `:time_in_force` | `{:error, {:missing_field, :time_in_force}}` |
| `:limit` with a tif other than `:gtc`, `:ioc`, `:fok` | `{:error, {:unsupported_order_combination, :limit, tif}}` |
| a `:time_in_force` on `:stop_limit`, `:post_only`, `:ioc`, `:fok` | `{:error, {:unexpected_field, :time_in_force}}` |
| `:quantity`, `:price` (and `:stop_price`) absent | `{:error, {:missing_field, key}}` |
| `:quantity` / `:price` / `:stop_price` that is `<= 0`, NaN, Infinity, unparseable or a float | `{:error, {:invalid_quantity, v}}` / `{:invalid_price, v}` / `{:invalid_stop_price, v}` |
| `:stop_price` on any type but `:stop_limit` | `{:error, {:unexpected_field, :stop_price}}` |
| `:client_order_id` blank or neither a string nor an integer | `{:error, {:invalid_client_order_id, v}}` |
| `opts[:account]` set but not a non-blank string | `{:error, {:invalid_option, :account, v}}` |

Pass amounts as `Decimal`, integers or numeric strings; a float has already lost digits.
The accepted `:order_type`s are `:limit`, `:stop_limit`, `:post_only`, `:ioc` and `:fok`.
`:post_only` is the one atom for maker-or-cancel. `:maker_or_cancel`, which this package used to
accept as an alias, is not a Core order type and is refused.

**An outcome that may have reached the venue is `{:error, {:order_unconfirmed, client_order_id,
reason}}`**: a timeout or connection failure after the send, a 5xx, a `2xx` that is not JSON or
names no `order_id`. `client_order_id` is the one you sent, as a string, or `nil` when you sent
none (this package generates none, because nothing here shows the venue dedupes on it).
**Do not place again.** Look for the order with `get_orders/2` (resting, then `history: true`)
by that id, or by symbol, side, price and time when it is `nil`. A refusal from the venue
(`{:refused, _}`), an error decided before sending (validation, missing credentials) and our
own rate limiter refusing (`"Throttled by our own rate limiter"`) are what they were before and
are not wrapped: nothing was sent. A `2xx` that names an `order_id` stays `{:ok, %Order{}}`
even if some field of it is unreadable.

`get_order/3` and `cancel_order/3` take the id as a **string of digits**. An integer, `nil` or
a blank string is `{:error, {:invalid_order_id, v}}`; an order the venue does not know is
`{:refused, :not_found}` (a 404 whose JSON body names a reason other than `EndpointNotFound`,
or the `OrderNotFound` reason; neither word is in the committed spec and the live body has not
been probed, and a 404 that is the endpoint or host missing stays an ordinary refusal). Do not
read `:not_found` from a cancel as "never existed": an order that already filled may answer the
same, so check `get_order/3` before placing again. `cancel_order/3` is sent once.
`DpExchange.Gemini.Fake` answers the same for all of this: each placement gets its own numeric id,
an id it did not issue in the calling process is `{:refused, :not_found}`, and the order carries
the side as `:buy` / `:sell` whatever case you passed. `Fake.cancel_all_orders/2` (either scope)
cancels the orders that process placed and answers their ids in `cancelled`; with none open both
lists are empty.

## Error shapes that mean "do not act on this answer"

Returned by calls that previously answered `{:ok, _}` carrying a value you could not act on.
A consumer matching only `{:ok, _}` needs no change; one that enumerates error reasons
should know them.

`{:error, {:undecodable_response, :gemini}}` — the venue answered `2xx` with a body this
package could not decode. The realistic cause is not malformed JSON from the venue; it is a
`2xx` that never reached the venue, such as a captive portal or a CDN maintenance page
answering `200 text/html`. **Worth retrying**: nothing about the request was wrong. This
package used to substitute an empty object for such a body, which then decoded into a
well-formed value with every field `nil` and was returned as success.

`{:error, :unexpected_response_shape}` is also what a `2xx` JSON body of the wrong kind answers
on every call that returns the venue's own object or rows (tick AN; each used to hand back
`{:ok, garbage}`): `get_roles/1`, `get_account_margin/1`, `get_margin_account/1`,
`preview_margin_order/2`, `get_clearing_order/2`, `get_fees/2` and `test_connection/2` need an
object (`test_connection/2` used to report `reachable: true` for a reply that proved nothing),
and `get_transfers/2`, `get_transactions/2`, `list_custody_fees/2`, `get_notional_balances/3`,
`get_trade_volume/2`, `list_funding_payments/1`, `funding_payment_report/1`,
`list_accounts/1`, `get_margin_rates/1`, `list_clearing_orders/1`, `list_clearing_brokers/1`
and `list_clearing_trades/1` need a list whose every row is one.

`{:error, :unexpected_response_shape}` from `get_balances/2` — a balance row the venue did
not attribute to an asset refuses the whole reply. An amount you cannot name an asset for
cannot be sized, booked or reconciled against, and dropping the row silently would read as
"you hold none of that asset", a different and more dangerous claim than "this response could
not be read". **Not retryable on its own.**

A `Balance`'s own `balance` field may still be `nil`, and that is a different statement: the
venue named the asset and did not state a quantity for it. Read that as unknown, never as
zero.

## Every negative here is audited

`docs/reference/gemini/negative-claims.md` lists each one with the source and date consulted.
This venue is also where the family learned that **positives go stale too** — a socket URL
the vendor still published had stopped working, and only a live check said so.

## An ordinary reconnect resubscribes at once; you never call `subscribe/3` again

A dropped connection (no crash, just the venue or the network closing it) reconnects
inside the same socket, and a reconnected socket carries no subscriptions. This package
resends your `wanted` set the moment the socket reports it is back. A 60-second
unconditional resend also runs, as a safety net. Both are sent from a worker process, so the
feed keeps handling frames and calls while a send waits on a busy socket (it used to wait
itself, and every frame queued behind it); one is in flight at a time and a request made
meanwhile runs once more when it settles.

**The first reconnect after a live session drops is immediate; every failed attempt after it
waits longer.** The wait doubles from 1s to a 30s ceiling, each wait shortened by a random
amount of up to a quarter so a fleet of sockets dropped together does not redial together,
and a session that dies within 5s of connecting counts as a failed attempt, not a healthy one.
The wait ends at once if `Feed` stops the socket.

**A socket that crashes (rather than being closed) is redialled by `Feed`** and announced as a
`:link_down` notice (`severity: :warning`, `details.reason` the bounded crash reason). The
first crash in a run redials at once; a crash within 30s of the last waits 1s, doubling to
30s. One redial timer is pending at a time, so a later crash replaces an earlier one's.

**While the socket is reconnecting, `Feed.subscribe/3`, `unsubscribe/2` and
`update_symbols/2` answer `:ok` without touching the socket.** Your change is recorded
in `wanted` and goes out with everything else when the socket is back. A reconnecting
socket answers no frame, and sending to it used to block the feed for five seconds per
call and come back `{:error, :send_timeout}` for a socket that was only reconnecting.
`:link_down` / `:link_up` from `subscribe_notices/1` bracket that window if you need to
know about it.

## A dead socket is not a slow one

`subscribe/2` and `unsubscribe/2` answer `{:error, :send_timeout}` when the socket did not
acknowledge a frame in time, and **`{:error, {:send_exit, reason}}` when the socket is gone**.
The two used to be flattened into the first, and they call for opposite responses.

`:send_timeout` is worth retrying: the frame may well have been delivered — the call only
stopped waiting for the acknowledgement — and subscriptions are idempotent on this venue, so
a duplicate costs nothing.

`{:send_exit, :noproc}` is not. No number of retries makes a process that no longer exists
accept the batch; the thing that needs doing is getting a new socket. If you drive the feed
through `DpExchange.Gemini.Feed` this is already handled for you — the distinction matters if
you hold a `Socket` pid yourself.

## Streaming calls answer; they never exit your process

`subscribe/2`, `unsubscribe/2`, `update_symbols/2` and `subscribe_notices/1` return
`{:error, :feed_not_started}` when this venue's feed is not running (`unsubscribe/2`
answers `:ok`: there is nothing to stop). They return `{:error, :feed_timeout}` when the
feed is too busy to answer within its call budget, and `{:error, {:feed_exited, reason}}`
when it dies while answering. `coverage/1` and `coverage_by_kind/1` answer an empty map in
all three cases, which means "not observed". Treat `:feed_timeout` as transient and retry.
Treat the other two as a feed your supervision tree has to bring back.

**`:feed_timeout` means "no answer", not "not applied".** The request is already in the
feed's mailbox and is applied when the feed reaches it. Retrying is safe because each of
these calls is idempotent (add, remove or replace a symbol set, applied in order), and
`coverage/1` shows what is being delivered once the feed answers.

## `:websocket_url` in application config replaces the default socket endpoint

`config :dp_exchange_gemini, websocket_url: "wss://your-proxy.example/..."` sends every socket
this package opens, unless a call passes its own `:url`, to that address instead of the
venue. Unset, the venue is the default. It exists so a test suite never dials the live venue
by accident, and it is equally usable for a proxy.

## A depth sequence gap raises one notice, and it will not repeat

When a `depthUpdate` frame skips ahead of the last applied update, the socket raises a
single `:data_quality` notice (`details.reason: :sequence_gap`, with the `symbol`; the words
are in `details.message`). `:degraded` is kept for "a slower path is in use".
**Act on that notice**: discard your local book for that symbol. Waiting for a repeat leaves
you applying diffs to a book that is wrong from the gap onward, with every price real.

**A symbol is on one diff channel at a time.** `Socket.subscribe/3` refuses `:depth` for a
symbol that is on `:depth_fast`, and the reverse, with `{:error, {:conflicting_depth_channel,
symbol}}`: the two streams' frames carry nothing that tells them apart. Unsubscribe first to
switch.

**On a connection started with `:depth`/`:depth_fast` in `:channels` (the `snapshot`
parameter), the socket resubscribes the symbol itself (BREAKING, tick R).** It knows which
channel the symbol is on (recorded by `Socket.subscribe/3`), unsubscribes, waits for the
venue's answer to that unsubscribe, subscribes again, and takes the **first frame after the
subscribe as the fresh snapshot** (a full `OrderBook`), whether it arrives before or after the
subscribe's own answer. It does NOT deliver the gapped frame and drops every other frame for
that symbol, without more notices, until that snapshot. So the snapshot is also your signal
that the book is whole again. Where no channel is recorded (a bare socket state), the notice
is all you get and the gapped frame is delivered as before.

**On a connection started without that parameter, a gap stops the symbol instead.** The
parameter is per connection (it cannot be asked for per subscribe), so a resubscribe there
brings diffs only and no book can be rebuilt from it. The socket raises a `:coverage_change`
notice (`details.delivering: false`, `details.reason: :book_not_rebuildable`, the words in
`details.message`) and drops every frame for that symbol until you
subscribe it again, when you rebuild from `get_order_book/2` or move to a connection started
with the depth channels in `:channels`. Unsubscribing or a reconnect clears the stop.

- **At most one resync per `{symbol, channel}` per 5 seconds.** A gap inside that window waits
  out the rest of it; the symbol delivers nothing meanwhile.
- **A resync that fails is announced and retried.** A subscribe the venue refuses, or an
  unsubscribe it never answers (15s), raises a `:coverage_change` notice with
  `details.delivering: false` (plus `symbol`, `channel`, and `status` for a refusal) and is
  retried after 5s, doubling to 60s. A refused subscribe also removes the key from the
  socket's `depth_streams`. Depth is not a `coverage/1` kind, so this notice is the
  not-delivering signal.
- **A sequence that goes backwards** by more than one frame's span (`u + (u - U + 1) <` the
  last applied) is a counter restart: `details.reason: :sequence_restart`, resynced like a
  gap. A
  duplicate or a frame only just behind (`u` at or before the last applied, within a span)
  is dropped silently, never applied.
- **Answers are matched by id.** Every subscribe and unsubscribe this socket sends carries
  an id of its own and its answer is matched by that id, so a late answer of one request is
  never taken for another's.
- **UNMEASURED:** that the venue answers an unsubscribe and writes no frame of the old
  subscription after that answer, and that it echoes an integer id other than 1 and 2 (the
  spec says it echoes the client's id). If it does not answer the unsubscribe, only the
  retries recover the book; if it did not echo the subscribe's id, the 15s unanswered-subscribe
  deadline would close the connection, loudly.

A `depthUpdate` whose `u` is missing or not an integer is the exception: its sequence cannot
be stated, so the socket does **not** advance past it. It raises a `:data_quality` notice,
`details.reason: :undecodable_depth_update`, and keeps the last good `u`, so the frame after it is judged against that and the missing
changes are announced as the gap they are (previously the unreadable frame reset the symbol
to "nothing applied yet", which can never be a gap).

Likewise an undecodable trade frame raises a `:data_quality` notice
(`details.reason: :undecodable_trade`) instead of vanishing, as does a bookTicker frame
whose symbol is absent, blank or not text (`:undecodable_book_ticker`) and a level that
cannot be read (`:unreadable_book_ticker_level`). The socket raises one per frame; `Feed`
forwards one per `{kind, reason, symbol}` per 30 seconds (see above).

Two more `:degraded` notices close the connection and reconnect it: `details.reason:
:silent_connection` (nothing heard, not even a pong) and `:subscribe_unanswered` (subscribes
unanswered for 15s while pings are). A symbol's last reported trade is forgotten when its
bookTicker is unsubscribed, so subscribing it again reports the current last trade once.
