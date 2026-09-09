# Every negative this package makes, and what was checked

**Audited 2026-09-01; inventory re-diffed against the vendor's live specifications 2026-09-09.** A negative is any statement that the venue *lacks* something: a
`:unsupported` declaration, a "there is no…", a "does not support…". §0's rule says a value
must never be substituted for a missing one; this is the same rule pointed at documentation.
**An unverified negative is a substitution exactly like an invented value.**

## Sources

| source | what it is | read |
|---|---|---|
| **inventory** | `docs/reference/gemini/endpoint-inventory.md` — 68 REST operations from the vendor's published specifications, plus `rest-api/common` | 2026-08-31 |
| **pages** | `developer.gemini.com/…`, rendered and read | 2026-09-01 |
| **AsyncAPI** | the vendor's WebSocket specification, 22 channels | 2026-08-31 |
| **measured** | live observation against the demo environment, dated per row | — |

## The negatives

| claim | verified against | verdict |
|---|---|---|
| **No market orders** | pages | **holds, and it is the venue's own words.** "They provide you with no price protection"; its documented workaround is an IOC order "coupled with an aggressive limit price". A package cannot pick that price — the caller never said how aggressive, and the difference is money |
| No plain stop orders | pages | **holds.** Gemini serves stop-*limit* only, so a plain stop would have to become a stop-limit at a price this package chose |
| No good-til-date, no day orders | pages | **holds.** An order rests until it fills or is cancelled |
| No `replace_order/4` | inventory | **holds.** No amend endpoint appears in the specifications. Amending is cancel-then-place, which opens a window in which no order is live — stated rather than hidden |
| No `preview_order/3` | inventory, 2026-09-01 | **holds, but narrower than "it is absent from the specifications", which this row said before.** Gemini publishes `POST /v1/margin/order/preview` — a *margin impact* preview returning pre- and post-order risk statistics for a hypothetical spot order. `preview_order/3` asks what the order would **cost**, and answering that with margin statistics is the nearby substitute §0 refuses. The real endpoint is reached on its own terms, as `preview_margin_order/2` |
| No auctions on the crypto book, no volume-at-price | inventory | **holds, and it is the venue rather than the package.** A crypto book trades continuously; there is no opening or closing auction to have an imbalance in |
| No positions on spot | inventory | **was true of spot and is no longer the whole story.** Gemini's perpetuals publish `/v1/positions`, and this package reads it as of 2026-09-01 |
| No rate-limit headers at all | **measured 2026-08-28** | **holds.** The venue publishes none. Returning a constant that never moves as budget is spent would be worse than refusing |
| No bulk instrument detail | inventory | **holds.** 346 symbols and no bulk detail endpoint — one request per symbol is not a listing, it is a rate-limit incident |
| No per-method payment read | pages, 2026-09-01 | **holds.** `/v1/payments/methods` returns the whole set and there is no path taking a method identifier. Filtering the listing here would answer with a snapshot while looking like a read |
| No batch order placement | inventory, 2026-09-01 | **holds.** The multi-order surface is the cancel family, which destroys rather than creates |
| No options | inventory | **holds.** Gemini lists none |
| **A documented WebSocket endpoint that had vanished** | **measured** | **the inverse case, and worth keeping.** This package once pointed at a socket URL the documentation still named and the venue no longer served. A *positive* claim can go stale exactly as a negative can, and only a live check tells you |
| 401 on unauthenticated private calls, where the docs say 400 | **measured 2026-08-28** | **documented divergence.** Gemini's own error table lists `MissingApikeyHeader` at 400; the live environment returns 401 `MissingSecurityHeaders`. Recorded because the next reader will otherwise assume the table |
| **"The accepted candle set is `[1m, 5m, 15m, 30m, 1hr, 6hr, 1day]`"** | **measured 2026-08-28, re-measured 2026-09-08** | **was true, went stale.** A second instance of the row above, not a new pattern: the venue's own 400 body grew from seven accepted widths to nine — `1w` and `1mo` now answer `200` with real bars. See `docs/reference/gemini/candles.md`'s "Drift found 2026-09-08" section. Both are now implemented and declared |
| **`settlementsAccount`, a WebSocket channel the vendor stopped publishing** | **spec diff, 2026-09-09** | **the third instance of the row below, and the first found by a machine.** The channel was in Gemini's own AsyncAPI on 2026-08-31 and is absent from it now, with no changelog entry. Nothing in `lib/` subscribes to it and `capabilities/0` does not rest on it, so no consumer-facing claim broke — but `WsChannels` still offers the address. The row is **kept and labelled** rather than deleted: the channel is private, so confirming its absence needs a credential this repo must never hold, and *absent from the spec is not the same fact as absent from the venue*. Found by `script/check_endpoint_inventory.sh` on its first run |

## What this venue teaches that the others do not

**Positives go stale too.** Every other package in this family learned to check negatives.
Gemini is where a *documented, positive* claim — a socket URL the vendor still published —
turned out to be false, and it has now happened **three times**: the vanished socket URL,
the seven-width candle set that grew to nine, and `settlementsAccount` disappearing from
the AsyncAPI. The rule that follows is symmetric: **a claim about a venue is only as
current as the last time someone looked**, whichever way it points.

**The third instance is the one that changed how this is checked.** The first two were
found by a person re-reading. The third was found by `script/check_endpoint_inventory.sh`,
which diffs this venue's committed inventory against the vendor's own machine-readable
specifications — on its first run, within minutes of being written. This venue is where
that is possible at all: Gemini publishes OpenAPI and AsyncAPI documents, so "what does
this venue serve" is a list that can be compared rather than prose that has to be re-read.

It is deliberately a **spec** diff and not a content diff. An operation list is structured
and every entry means something; the rendered pages around it carry build hashes and
rotating banners and would be red every week for reasons nobody cares about. That is the
same line `script/check_doc_sources.sh` draws, one rung deeper.
