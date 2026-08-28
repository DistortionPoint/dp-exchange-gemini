# Gemini replaced its WebSocket API — and never said so

**Source**: `https://developer.gemini.com/websocket/introduction`,
`https://developer.gemini.com/websocket/streams`,
`https://developer.gemini.com/changelog/revision-history`.
**Read and measured 2026-08-28.**

This is the largest divergence found in the Gemini extraction, and it is not a divergence
between the host and the documentation. It is a divergence between the venue's
documentation and the venue's own past.

## What the host runs on

`gemini/websocket_provider.ex:695` connects to **`wss://api.gemini.com/v2/marketdata`**
and subscribes to the `l2_updates` and `trade` channels, dispatching on
`l2_updates` / `trade` / `heartbeat` / `subscription_ack`. `feed.ex` shards nine sockets
across that endpoint. `l2_book.ex` exists to rebuild a book from `l2_updates` deltas
because that endpoint offers no top-of-book message.

The adapter's own comment at line 680 records the correction that got it there:

> `2026-08-07: /v2/marketdata, not /v1/marketdata/{symbol}.`

## What the documentation now describes

A different API at a different host: **`wss://ws.gemini.com`**, "Version: 0.10.7 •
Status: Production", with Binance-shaped stream names and an RPC-style control channel.

| | Host's API | Documented API |
|---|---|---|
| Host | `api.gemini.com/v2/marketdata` | `ws.gemini.com` |
| Subscribe | `{"type":"subscribe","subscriptions":[…]}` | `{"method":"subscribe","params":["btcusd@bookTicker"],"id":1}` |
| Book deltas | `l2_updates` events | `{symbol}@depth`, `{symbol}@depth@100ms` |
| Book snapshots | initial `l2_updates` payload | `{symbol}@depth5/10/20`, or `?snapshot=-1` |
| Top of book | **not offered** — must be derived | `{symbol}@bookTicker` |
| Trades | `trade` events | `{symbol}@trade` |
| Order events | `wss://api.gemini.com/v1/order/events` | `orders@account`, `orders@session` |
| Trading | REST only | `order.place`, `order.cancel`, `order.cancel_session` |

## Neither is dead. Both answer right now

Measured 2026-08-28 with a WebSocket upgrade against each host:

```
api.gemini.com/v2/marketdata      → HTTP/1.1 101 Switching Protocols
api.gemini.com/v1/marketdata/BTCUSD → HTTP/1.1 101, and immediately streams {"type":"change"}
ws.gemini.com                     → HTTP/1.1 101 Switching Protocols
```

So the legacy endpoints are live and serving. The host is not broken and nothing is on
fire. What has happened is quieter: **the endpoint the host depends on is no longer
documented anywhere on the venue's current site.**

## The changelog is the damning part

Gemini publishes a dated revision history going back to **2022-06**. Searched in full,
2026-08-28:

| Term | Occurrences |
|---|---|
| `marketdata` | **0** |
| `l2_updates` | **0** |
| `v2/marketdata` | **0** |
| `ws.gemini.com` | 3 |
| `deprecat*` | 2 — both about prediction-market ticker formats, neither about this |
| `sunset` / `end-of-life` / `EOL` / `breaking` | 0 |

Four years of release notes that mention the endpoint the host's price feed runs on
**zero times**. It was not deprecated, not announced, not scheduled for removal. It was
dropped from the documentation, and that is the entire notice anyone got.

**A consumer watching the changelog for breaking changes would have seen nothing.** This
is the most useful thing this extraction learned about noticing vendor change, and it is
a negative result: the venue's changelog is well maintained, dated to the day, updated
yesterday — and it would not have told you.

## What this package does

**It speaks the documented API, `wss://ws.gemini.com`.** Reasons, in order:

1. D13 makes the vendor's current documentation the source. The legacy endpoint is not in
   it. A package published to hexpm for other people to depend on should not be built on
   an endpoint the vendor has stopped acknowledging — that is an expiry date nobody can
   see.
2. It was verified working, not assumed. Subscribing to `btcusd@bookTicker`,
   `btcusd@trade` and `btcusd@depth10@100ms` returned an ack (`{"id":1,"status":200}`) and
   live frames matching the documented field-for-field shape.
3. `@bookTicker` publishes best bid, best ask and last trade price directly. The host
   maintains an entire L2 book (`l2_book.ex`, 182 lines) to derive a mid the old endpoint
   would not give it. That machinery is not needed here, and machinery that is not needed
   cannot be wrong.

**The risk, stated plainly**: this API is version `0.10.7`. It is pre-1.0 and the host has
no production hours on it, where the legacy endpoint has years. That is a real trade and
it is why every streaming endpoint in `capabilities/0` is `:experimental`, not `:proven`.

### The facade is what makes this choice affordable

The host cannot switch WebSocket APIs without a migration, because its socket, its shards
and its book-building are spread across the application. This package can, because none of
that crosses the facade. A consumer subscribes and receives `%Core.Types.Quote{}`; which
socket produced it, against which host, in which protocol version, is not expressible in
anything they can see.

If `0.10.7` turns out to be a mistake, reverting to `v2/marketdata` is a change to this
package's internals and a patch release. **That is the argument for D12, demonstrated
rather than asserted** — and it was found, not predicted: the plan expected the facade's
value to show up as consumer simplicity, not as freedom to pick a different protocol than
the incumbent.

## One documented shape was already wrong

The partial-depth example on the streams page shows `{lastUpdateId, bids, asks}`. Live,
the frame also carries `symbol`:

```json
{"lastUpdateId":1764553979098119,"symbol":"btcusd","bids":[["77845.79000","0.0457361300"], …]}
```

Additive, so harmless — a parser written to the documentation still works. Recorded
because it is the second documentation defect on this venue in one afternoon, and the
pattern matters more than the field: **this venue's documentation is close but not exact,
and anything cheap to measure should be measured.**
