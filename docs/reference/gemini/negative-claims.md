# Every negative this package makes, and what was checked

**Audited 2026-09-01.** A negative is any statement that the venue *lacks* something: a
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

## What this venue teaches that the others do not

**Positives go stale too.** Every other package in this family learned to check negatives.
Gemini is where a *documented, positive* claim — a socket URL the vendor still published —
turned out to be false. The rule that follows is symmetric: **a claim about a venue is only
as current as the last time someone looked**, whichever way it points.
