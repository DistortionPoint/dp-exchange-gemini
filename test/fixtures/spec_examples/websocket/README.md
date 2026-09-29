# WebSocket spec-example fixtures

Source: `docs/reference/gemini/asyncapi/websocket.yaml`.

**None of these are vendor-documented examples.** The whole AsyncAPI document was checked
(`grep -c example docs/reference/gemini/asyncapi/websocket.yaml` → 1, and that one hit is
an unrelated `RfqClientId` field example at line 1551, nothing to do with any message this
package decodes) — Gemini's WebSocket spec publishes schemas with no message examples
anywhere. Every fixture here is therefore built **strictly from the named schema's
`required` properties**, per this suite's rule for that case. No optional field is
invented; where a fixture includes an optional field anyway (the two `bookTicker`
variants, below) it is because the field's *presence vs. absence* is itself part of the
decode logic under test, and both shapes are real per the schema's own description, not a
guess at a value.

Only channels/message shapes this package's `Socket`/`WsDecode` actually decodes are
covered here (`Socket.handle_message/2`'s own clauses) — not the full channel list in
`WsChannels`, most of which (`orders@account`, the `requestForQuote` family, etc.) this
package addresses but never decodes a payload for.

| Fixture | Schema | `websocket.yaml` line | Required properties used |
|---|---|---|---|
| `book_ticker.json` | `BookTicker` | 1234 | `u, E, s, b, B, a, A` only — `c`/`C` (last trade) are optional per the schema and omitted here to exercise the no-last-trade path |
| `book_ticker_with_last_trade.json` | `BookTicker` | 1234 | same required set, **plus** the optional `c`/`C` — the schema documents them as "present once the book has traded", a real and separately-tested shape (`Socket`'s `deliver_last_trade/4`) |
| `order_book_snapshot.json` | `OrderBookSnapshot` | 1217 | `lastUpdateId, bids, asks` — the partial-depth (`@depth5`/`@depth10`/`@depth20`) snapshot shape |
| `depth_update.json` | `DepthUpdate` | 1261 | `e, E, s, U, u, b, a` — one ordinary differential frame, including a zero-quantity ask level (schema: "A quantity of zero removes that price level") |
| `trade.json` | `Trade` | 1295 | `E, s, t, p, q, m` — `m: true`, i.e. the documented "buyer is the maker" shape, so the decoded aggressor must be `:sell` |
| `subscribe_ack_refused.json` | `ResponseBase` | 1072 | `id, status` — a non-200 status, the venue's own documented refusal shape for a subscription |

All price/quantity fields use `PriceLevel` (websocket.yaml:867, a `[price, quantity]`
decimal-string tuple) or `DecimalString` (websocket.yaml:864) exactly as the schema
requires — never a bare number, since the vendor's own type is a string.
