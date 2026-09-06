# Rate limits and authentication — reference

**Source**: `https://developer.gemini.com/rate-limit` and
`https://developer.gemini.com/authentication/api-key`. **Read 2026-08-28.**

## Rate limits, verbatim

> For public API entry points, we limit requests to **120 requests per minute**, and
> recommend that you do not exceed **1 request per second**.
>
> For private API entry points, we limit requests to **600 requests per minute**, and
> recommend that you not exceed **5 requests per second**.
>
> When requests are received at a rate exceeding X requests per minute, we offer a
> **"burst" rate of five additional requests** that are queued but their processing is
> delayed until the request rate falls below the defined rate.
>
> When you exceed the rate limit for a group of endpoints, you will receive a
> **429 Too Many Requests** HTTP status response until your request rate drops back under
> the required limit.

### This maps onto Core's limiter without interpretation

`DpExchange.Core.DefaultRateLimiter` is a GCRA limiter taking exactly three parameters,
and the documentation supplies all three as stated numbers:

| Core parameter | Public | Private |
|---|---|---|
| `limit` | 120 | 600 |
| `per_ms` | 60_000 | 60_000 |
| `burst` | 5 | 5 |

**`burst: 5` is a venue fact here, not a tuning choice.** That is worth saying because
Core's limiter had a defect where a declared burst of *n* granted *n − 1*, found during
the Coinbase extraction and fixed in `0.1.4`. A venue that publishes its burst depth
turns that class of bug from invisible into assertable, and the conformance suite asserts
it against these numbers.

Note the two limits differ by 5×, so a single shared bucket would either throttle private
calls to public speed or let public calls run 5× over. They are separate providers to the
limiter, which is what "rate limit for a **group** of endpoints" in the quote above
describes.

The "recommended" rates (1/s public, 5/s private) are half the enforced ceilings
(2/s, 10/s). This package declares the **enforced** ceilings and does not silently apply
the recommendation — a consumer who wants to be polite can say so; a package that quietly
halves the budget is deciding something that is not its to decide.

## Authentication, verbatim

Private REST requests carry an **empty body** and encode the JSON payload into a header:

> Private REST endpoints do not submit JSON payloads in the HTTP POST body. Instead, the
> JSON object is Base64-encoded and passed in the `X-GEMINI-PAYLOAD` header, with an empty
> request body (`Content-Length: 0`).

| Header | Value |
|---|---|
| `Content-Length` | `0` |
| `Content-Type` | `text/plain` |
| `X-GEMINI-APIKEY` | the API key identifier |
| `X-GEMINI-PAYLOAD` | Base64-encoded JSON payload containing `request`, `nonce`, and parameters |
| `X-GEMINI-SIGNATURE` | `hex(HMAC_SHA384(base64(payload), key=api_secret))` |
| `Cache-Control` | `no-cache` |

Key identifiers are prefixed: `account-` for a standard key, `master-` for a key that can
target subaccounts via an `"account"` field in the payload.

## The nonce — and a mode the host does not know about

The host's adapter (`provider.ex:1021–1060`) carries its most complex machinery for the
nonce: a **global lock per API key** spanning nonce generation *and* send, so that arrival
order matches nonce order, plus an escalation retry that doubles the nonce up to six times
when the venue reports a higher high-water mark. Its comment explains why:

> Gemini requires strictly-INCREASING nonces … a nonce is rejected with `InvalidNonce`.
> That silent failure is why Gemini …

**That is now only true for one of two modes.** The documentation, read 2026-08-28:

> When provisioning an API key, you can select one of two nonce validation modes:
>
> **Time-Based Nonce (Recommended)**: Nonces must be Unix epoch timestamps in seconds.
> The server validates that the nonce timestamp is within **± 30 seconds of server time**.
> Ideal for distributed or stateless trading clients.
>
> **Incremental Nonce**: Nonces must be monotonically increasing numbers. Each request on
> a given session key must present a higher nonce than the previous request.

Under time-based validation there is no ordering requirement at all, so the lock and the
escalation retry have nothing to protect. The host serialises every private request per
key — a real throughput ceiling — to satisfy a constraint its key may no longer be under.

This package does not choose the mode; the key's provisioning does, and the package cannot
see which was selected. **There is no single value that satisfies both** — time-based
validation wants Unix *seconds*, and a seconds-granularity value on an incremental key
caps that key at one request per second — so the mode is named by the caller, as
`nonce_mode: :time_based | :incremental`, defaulting to `:time_based` because that is the
venue's own recommendation. `Auth.nonce/1` returns `System.system_time(:second)` for the
first and a strictly increasing millisecond value from a node-wide `:atomics` counter for
the second. A mismatch fails loudly with `InvalidNonce` on the first request rather than
producing a wrong answer.

What it does *not* carry over is the global lock spanning generation and send. Ordering is
preserved per connection, and a caller who needs a stronger guarantee than that is
describing a sequencing requirement, not a rate limit.

**Both nonce modes are tier-3 territory** — proving either needs credentials this repo must
never hold. The mode's existence is documented and the behaviour is not measured here;
`capabilities/0` carries no field for it, so the record is this document and `Auth`'s own
moduledoc rather than the declaration.

## Session behaviour worth knowing before placing an order

- **Requires Heartbeat** is a per-key setting. If enabled and no authenticated request or
  explicit heartbeat arrives for **30 seconds**, the exchange **cancels all outstanding
  open orders for that session**. Recommended heartbeat interval is 15 s; any valid
  authenticated request resets the timer.
- The WebSocket API offers `cancelOnDisconnect=true` as a connection parameter with the
  same effect on socket loss.

Neither is enabled by this package. Both are consumer policy: a package that silently
turned on cancel-on-disconnect would be making a risk decision for someone else's money.
`capabilities/0` has no field for either, so this document and `usage-rules.md` are where
their existence is recorded; acting on them is the consumer's call.

## Authentication error codes

| Code | HTTP | Cause |
|---|---|---|
| `MissingApikeyHeader` | 400 | `X-GEMINI-APIKEY` omitted |
| `MissingPayloadHeader` | 400 | `X-GEMINI-PAYLOAD` omitted |
| `MissingSignatureHeader` | 400 | `X-GEMINI-SIGNATURE` omitted |
| `InvalidNonce` | 400 | nonce outside the 30 s window, or did not strictly increase |
| `InvalidSignature` | 400 | HMAC-SHA384 did not match the payload |
| `AmbiguousAuthentication` | 400 | V1 key headers and OAuth/V2 headers both supplied |
| `InvalidApiKey` | 403 | key does not exist or is disabled |

`InvalidNonce` and `InvalidApiKey` are **permanent** for the request as sent — retrying
the identical request cannot succeed. They map to `{:refused, reason}`, not to a
transient error, and that distinction is the whole point of the two shapes: a caller
retries an error and stops on a refusal.
