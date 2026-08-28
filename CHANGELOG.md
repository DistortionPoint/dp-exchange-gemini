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
