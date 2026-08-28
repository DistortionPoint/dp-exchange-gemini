# List Candles — reference

**Source**: Gemini's own API documentation.
`https://developer.gemini.com/trading/rest-api/market-data/list-candles`
**Read 2026-08-28**, and measured against the live endpoint the same day.

`GET https://api.gemini.com/v2/candles/{symbol}/{time_frame}`

Committed rather than linked: a link moves — this one already did, from
`https://docs.gemini.com/rest-api/` — and D13 makes this the ground truth the host's
adapter is checked *against*.

## The documented enum, verbatim

The page states the time frames twice, in prose and as an enum list, and **the two do not
agree with each other**:

> **Prose**: "Time range for each candle: 1m - 1 minute 5m - 5 minutes 15m - 15 minutes
> 30m - 30 minutes 1h - 1 hour 6h - 6 hours * 1day - 1 day"
>
> **Enum values**: `1m` `5m` `15m` `30m` `1h` `6h` `1d`

The prose ends `1day`; the enum list ends `1d`. Both offer `1h` and `6h`.

## What the venue actually accepts

Measured 2026-08-28 against the live endpoint. The venue names its own accepted set in
the error body, which makes it self-describing and settles the contradiction:

```
GET /v2/candles/BTCUSD/1h    → 400
{"result":"error","reason":"InvalidParameterValue",
 "message":"time_frame expects one of the following: [1m, 5m, 15m, 30m, 1hr, 6hr, 1day]"}
```

**The accepted set is `[1m, 5m, 15m, 30m, 1hr, 6hr, 1day]`.**

| Documented | Accepted live | |
|---|---|---|
| `1m` `5m` `15m` `30m` | ✅ 200 | agree |
| `1h` (prose + enum) | ❌ 400 | real value is `1hr` |
| `6h` (prose + enum) | ❌ 400 | real value is `6hr` |
| `1d` (enum only) | ❌ 400 | real value is `1day`, which the prose has right |
| `1day` (prose only) | ✅ 200 | |

**Three of the seven documented values are rejected by the venue that documents them.**
Every one of the three has a working near-neighbour differing by one or two characters,
which is the shape of error that gets "fixed" by a fallback rather than by reading.

### What this does to D13

D13 says the vendor's documentation is the source and the host adapter is a prior reading
of it, so on conflict the documentation wins. Here the documentation loses to the venue,
and it must: a `time_frame` is not an interpretation, it is a string the venue either
accepts or rejects. The rule this package follows is narrower than D13 and does not
contradict it — **where a documented claim is directly measurable, the measurement is the
source and the divergence is recorded here.** Documentation stays authoritative for
everything not measurable without credentials or money.

### The host got this right

`gemini/provider.ex:361` maps `1h → 1hr`, `6h → 6hr`, `1d → 1day` and returns
`{:error, {:unsupported_timeframe, other}}` for anything else, with a comment recording a
2026-08-06 measurement. It was written against documentation that has since been replaced,
and it is *more* correct than the documentation that replaced it. Carried forward as-is.

## Gemini refuses cleanly

Unlike Coinbase — where an unrecognised granularity returns an empty array — Gemini
returns `400 InvalidParameterValue` **and names the accepted set**. There is nothing for
this package to guess at, and no way for a wrong width to be mistaken for "no data".

`4h` and `12h` are absent. The shared `DpExchange.Core.Timeframe` vocabulary models both,
so this package's `historical_timeframes` is a subset of that vocabulary and asking for a
missing width is an error, never a substitution.

## The window is fixed, and every parameter is ignored

Measured 2026-08-28. Each width returns a **fixed number of bars**, and `limit`, `start`
and `end` change nothing — the three responses below were byte-identical at 23,227 bytes:

```
/v2/candles/BTCUSD/1day                                   → 23227 bytes
/v2/candles/BTCUSD/1day?limit=10                          → 23227 bytes
/v2/candles/BTCUSD/1day?start=1700000000000&end=170060... → 23227 bytes
```

| Width | Bars | ≈ span |
|---|---|---|
| `1m` | 1440 | 1 day |
| `5m` | 2015 | 7 days |
| `15m` | 1343 | 14 days |
| `30m` | 1439 | 30 days |
| `1hr` | 1463 | 61 days |
| `6hr` | 367 | 92 days |
| `1day` | 364 | 1 year |

**These reproduce the host's 2026-08-06 numbers exactly, all seven, 22 days later.** Two
independent measurements three weeks apart agreeing to the bar is strong evidence these
are fixed windows rather than a rolling count of whatever exists.

Consequences for `get_historical_prices/4`, which takes a start and an end:

- The range must be **filtered client-side**; the venue will not do it.
- There is nothing to paginate. `max_candles_per_request` is `nil`, not a number — one
  call is the whole history the venue offers at that width.
- A request reaching back **beyond** the window must be an error, not a short answer.
  Silently returning 364 daily bars to a caller who asked for five years is the family's
  named failure mode wearing a different hat: every value real, only the meaning wrong.
