# Current Order Book — reference

**Source**: Gemini's own API documentation.
`https://developer.gemini.com/rest/market-data` (Current Order Book section).
**Read and measured 2026-09-08.**

`GET https://api.gemini.com/v1/book/:symbol`

Committed rather than linked, per D13.

## The documented `limit_bids`/`limit_asks` default, verbatim

> **`limit_bids`**: "Limit the number of bid (offers to buy) price levels returned.
> Default is 50. May be 0 to return the full order book on this side."
>
> **`limit_asks`**: "Limit the number of ask (offers to sell) price levels returned.
> Default is 50. May be 0 to return the full order book on this side."

`Rest.get_order_book/2`'s `depth = Keyword.get(opts, :depth, 50)` is this figure — a
correct, previously uncited default. Found by a family-wide sweep for the
`@pairs_per_socket`/`@shard_spacing_ms` defect class (`dp_exchange_coinbase`): a value
that happened to be right, sitting with no citation where one belonged.

Note this package does not currently expose `0` as "the full book" to a caller passing
`depth: 0` — `Keyword.get/3` only supplies the default when the key is absent, so a
caller who explicitly asks for `depth: 0` already gets the venue's own full-book
behaviour; this is stated here for a future reader confirming that, not because anything
needed to change.
