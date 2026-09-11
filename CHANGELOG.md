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

## [0.2.16] - 2026-09-11

### Fixed

- **A balance the venue did not attribute to an asset was returned as success.**
  `Core.Types.Balance`'s `new/1` refuses a `nil` in `:currency`, and this decoder never
  called `new/1` — it builds the struct literally, as all five venue packages do, 85 call
  sites between them — so the check never ran and the field came straight out of the venue's
  JSON by key. A renamed or absent key produced `%Balance{currency: nil}`: an amount
  attributable to no asset, inside `{:ok, balances}`, which a consumer cannot size, book or
  reconcile against. It is precisely the renamed-field scenario `Core.Types.Validate`'s
  moduledoc was written for, arriving through the one path that bypassed the constructor
  written to catch it.

  Such a row now refuses the whole reply rather than being emitted or silently dropped —
  dropping it would read as "you hold none of that asset", a different and more dangerous
  claim than "this response could not be read".

  **`:balance` is deliberately not guarded the same way.** `Core.Types.Balance` now states
  that it may honestly be `nil` while `:currency` may not, and the two are not the same kind
  of required: an unknown quantity is still a balance, an unattributable one is not.

## [0.2.15] - 2026-09-11

### Fixed

- **`subscribe_notices/2` could kill the caller for asking during trouble.** It was the one
  public call in `Feed` left on `GenServer.call/2`'s five-second default timeout. Every
  sibling call — `subscribe/3`, `unsubscribe/2`, `update_symbols/2`, `coverage/1` — is given
  `@call_timeout`, which is this package's own statement of how long the feed may
  legitimately take to answer on a busy mailbox.

  A consumer registers for notices at start-up, which is precisely when that mailbox is
  deepest: the transport is coming up, symbols are being resolved, and the handler itself may
  replay a notice to the newly-registered subscriber. A `GenServer.call/3` timeout exits in
  the **caller**, not in the feed — so the channel a host uses to hear that something is
  wrong was the one call that could take the host's calling process down for asking under
  exactly the conditions it exists to report.

  Now uses `@call_timeout` like every other call. The test blocks the feed's own process for
  six seconds — past the old default, nowhere near the new timeout — and asserts both that
  the call succeeds and that it genuinely queued behind the block, so it fails on the
  unfixed code rather than passing for free.

## [0.2.13] - 2026-09-11

### Fixed

- **A `200` this package could not decode became an empty object, and then an empty
  everything.** `decode/1` collapsed any unparseable body to `%{}` on the success path of
  both `Rest` and `Private`. `%{}` is a map, so it passed straight through the readers and
  came out as a well-formed struct with every field `nil`, returned as `{:ok, value}`.

  There was already a test for this on the public path — "a 200 whose body is not JSON at
  all" — and it passed, which is why the defect survived: `get_price/2`'s reader happened to
  reject `%{}` for carrying no ticker fields. The authenticated readers do not reject it.
  `to_order/1` accepted `%{}` and built an order with no id and no status; the balance reader
  built an empty portfolio. Each was returned as success. Two substitutions in sequence,
  where catching either one alone would have been enough.

  The realistic source is not malformed JSON from Gemini. It is a `200` that never reached
  Gemini: an interstitial, a captive portal or a CDN maintenance page, each of which answers
  `200 text/html`. "You hold nothing" and "I could not read the answer" demand opposite
  responses from a caller.

  Success bodies now refuse with `{:error, {:undecodable_response, :gemini}}`. Refusal bodies
  are unchanged — they were already passed raw to `refusal_reason/1`, for the reason recorded
  there: a plain-text `4xx` body is the venue's own words, and routing it through a decoder
  discards them.

- **`"NaN"` and `"Inf"` from a venue became real `Decimal` prices and flowed through
  untouched.** Every numeric field in this package funnels through a `decimal/1` helper whose
  binary clause uses `Decimal.parse/1` and requires the whole string be consumed — the
  family's established idiom, and the fix for a venue sending the literal `"null"` in a price
  field. **That guard is not sufficient on its own.** `"NaN"`, `"Inf"` and `"-Inf"` all parse
  *fully*, and case-insensitively: `"-nan"`, `"inf"` and `"Infinity"` too. Each one arrived as
  a well-formed `Decimal` and was admitted as a price.

  That is worse than the raise the parse replaced, because it fails a long way from the
  cause. Measured:

  - `Decimal.add(nan, 1)` is `NaN` — it poisons a consumer's arithmetic **silently**.
  - `Decimal.compare(nan, _)` **raises** `invalid_operation: operation on NaN` — in the
    consumer's own process, with a message naming `Decimal` rather than the venue that sent
    it, and a stacktrace pointing nowhere near this package.
  - An `Infinity` is quieter still: it never raises and compares greater than everything, so
    it silently wins every "is this the best price" test a consumer makes.

  **Found where it was fixed, not where it applied.** `dp_exchange_webull` hit this and
  guarded both of its own copies; the other four venues guarded **none at all — this one had 4**. Every
  copy in the family now rejects a non-finite value the same way it rejects an unparsable
  one — as absent, which is what a price that is not a number actually is.

  Tested per venue at the decode seam, and the tests were verified against the *unguarded*
  helper first: eight of ten fail without the check. They cover the lowercase and mixed
  spellings too, since a guard matching only the canonical `"NaN"` would let `"inf"` straight
  through.

## [0.2.12] - 2026-09-11

### Added

- **`script/check_doc_sources.sh` now reports the age and provenance of this package's own
  capability claims.** `capabilities/0` carries `measured_at` and `measured_against` because
  CLAUDE.md is explicit — *"Declare what you measured, not what you assume. If it was
  measured, say when and against what."* Both were populated and **nothing read them**: not
  the weekly checker, not a test, not a line of consumer documentation.

  That is the same shape as the `MANUAL` documentation rows before they were aged — a claim
  that quietly gets old while still reading as current. The check reports the age against the
  same `STALE_DAYS` threshold, and reports a missing `measured_against` as its own finding,
  because half the rule is not the rule.

  Reported, never enforced. A stale measurement is not a build failure; it is a venue nobody
  has re-checked, and only a person re-measuring can fix it.

- **`usage-rules.md` tells consumers those fields exist and what to do with them.** They ship
  inside the Hex tarball and are what a consuming agent reads, and none of the five mentioned
  provenance at all. The distinction worth acting on is not the date but
  `measured_against`: a figure measured live against the venue's API and one read off a
  documentation page and never probed are different kinds of claim, and this package's
  declarations contain both.

### Fixed

- **The first version of that check would have reported `MISSING` on every venue, forever.**
  It grepped for `measured_against: "…"` on one line. Every venue in this family states the
  field as a multi-line `<>` concatenation, because the honest answer is a paragraph — which
  documents, which endpoints, measured live or read from a page. A single-line grep matches
  none of them.

  Recorded rather than quietly corrected, because the same mistake was made twice in the same
  hour: the reading that produced the check also concluded `measured_against` was unset
  across the whole family, and came within one commit of replacing five accurate provenance
  statements — including this one's — with a flat "not probed against the live API". For
  `dp_exchange_gemini` that would have been **false**: its statement records timeframes and
  candle windows measured *live* against `api.gemini.com`. A checker that cannot see a value
  is not evidence the value is absent.

  The field is now detected by presence and reported as a `file:line` pointer rather than
  quoted. These statements run to a paragraph each and the clause that matters is rarely the
  first one, so an excerpt in a weekly notice would mislead more than it informs.

## [0.2.11] - 2026-09-11

### Fixed

- **A dead subscriber's pid was never removed, and the fan-out walked it on every message
  for the life of the feed.** `Core.Fanout.resolve/1` skipped a dead subscriber at send
  time, so no *events* accumulated for one — which is what the contract asks for, and it was
  true. What accumulated was the **pid**. Nothing monitored a subscriber or pruned one, so a
  supervised consumer that restarts left its old pid behind on every restart.

  That is linear cost on the hot path: `deliver/4` walks the whole set and calls
  `Process.alive?/1` per entry, per message. Measured in `dp_exchange_core` 0.3.3 —

  | dead pids in set | µs per fan-out |
  |---|---|
  | 0 | 0.095 |
  | 200 | 4.301 |
  | 1000 | 22.842 |

  — roughly **240×** at a thousand accumulated pids, inside the one process every
  subscriber's data flows through.

  Subscribers are now monitored, and a `:DOWN` drops the pid from every set it was in.

  **A registered name is deliberately not pruned.** A pid that has died is gone permanently,
  so removing it is always right. A name is not a process: `subscribe/2` accepts one
  precisely so a consumer can restart under it, and a monitor fires when the *current holder*
  dies. Pruning on that would silently unsubscribe a consumer whose supervisor is about to
  bring it straight back under the same name — data loss with nothing to notice it by, which
  is worse than the leak. A name cannot leak anyway: the set holds one atom however many
  restarts happen.

## [0.2.10] - 2026-09-11

### Added

- **`check_doc_sources.sh` now checks whether its own manifest is COMPLETE.** Everything it
  did before verified the sources that were listed; nothing verified that the list covered
  what this package's `docs/reference/` actually cites. A checker whose coverage nobody
  audits reports "all sources resolve" while saying nothing about the sources it was never
  told about.

  The gap was real: `dp_exchange_gemini` cited 22 distinct URLs and listed 12, leaving two
  genuine vendor documentation pages — the WebSocket streams introduction that
  `websocket-api-replacement.md` names as its source, and one of the four API specifications
  `endpoint-inventory.md` diffs — unchecked by anything.

  Two classes, reported separately, because only one can be judged mechanically:

  **UNLISTED** — cited on a host the manifest already names as documentation. Same vendor,
  same docs site, different page: near-certainly a source that belongs in the manifest.

  **UNKNOWN** — cited on a host the manifest does not name at all. Deliberately **not**
  assumed to be documentation, because most are not: `api.gemini.com`,
  `api.sandbox.webull.com` and `api.schwabapi.com` are venue APIs, and adding one here would
  put a live venue into a **weekly scheduled fetch**. D7 is explicit that a venue seeing a
  package poll it on a timer will rate-limit or block. These are listed for a person to
  classify and never auto-added.

  Non-blocking, like the rest of the script: it prints and does not change the exit code. An
  unlisted page is a gap in evidence, not a broken build.

- **Two vendor documentation sources this package cites were never being checked**, found by
  the coverage check above on its first run: `developer.gemini.com/websocket/introduction` —
  the streams document `websocket-api-replacement.md` names as its source, which is the page
  whose *absence* of the old `marketdata` API was the only notice this venue ever gave that
  it had replaced the API this family's price feed ran on — and
  `specs/openapi/prediction-markets.yaml`, one of the four specification documents
  `endpoint-inventory.md` diffs. The other three were listed; that one was not. Both read,

- **All three of this package's scheduled checkers were run by hand for the first time, and
  they pass.** Every one of them had never executed: they are scheduled weekly for Monday
  and landed on a Tuesday, so no cron had come around. A checker nobody has watched run is a
  checker nobody has proved works — and running these found the manifest-coverage gap above,
  which is not the defect any of them was written to catch.

  No vendor drift: every cited documentation source resolves exactly as recorded, and the
  committed endpoint inventories match the vendors' current indexes.
## [0.2.9] - 2026-09-11

### Changed

- **CI runs `mix test --cover --warnings-as-errors`.** `mix compile --warnings-as-errors`
  already covered `lib/`, but test files are compiled by `mix test`, which had no such flag
  — so a compile warning in a test file was permanent and green. Together the two now mean
  no warning survives anywhere in the build.

  The argument is not tidiness. A handful of permanent warnings is exactly the noise a
  genuinely wrong one hides behind. The gap was found by running
  `script/check_dependency_floor.sh` by hand — a checker scheduled weekly that had never
  once executed, because it landed on a Tuesday and its cron is Monday — and reading what
  scrolled past. `dp_exchange_core` 0.3.2 fixes five such warnings in the shared conformance
  suite, two of which were real defects that made every venue package noisy.

  Verified by injecting an unused function into a test file and confirming the run aborts: a
  gate nobody has watched fail is a gate nobody has proved.

## [0.2.8] - 2026-09-11

### Changed

- **`dp_exchange_core` floor raised to `~> 0.3.1`.** Core 0.3.0 deleted
  `Core.DataProvider` and `Core.FeedBehaviour` — two contracts with zero implementers, one
  of which was a **second, competing definition of the venue interface** carrying every
  shape this family has since fixed (prices as strings, providers as strings, balances with
  no timestamp, a single quote timestamp, `{:error, String.t()}` flattening the
  refusal/error distinction). A venue author who found it first would have built all of
  those, plausibly, and every one would have compiled.

  **No code changes here**: this package referenced neither module. The floor moves because
  a pin of `~> 0.2.8` would not resolve 0.3.x — the pin doing its job, not a problem to
  route around — and because staying behind would leave this package on a Core that still
  ships the contradicting contract.

  Resolved and compiled against before the pin was written, per the rule this file's own
  dependency comment already records: a floor is only correct once it has been *resolved*,
  never once it has been reasoned about.

## [0.2.7] - 2026-09-11

### Added

- **This package now emits the `[:dp_exchange, :link, …]` telemetry the contract has
  documented since it was written.** `Core.Telemetry` said these are the events "every venue
  package emits"; there was not one `:telemetry.execute/3` call anywhere in the family for
  as long as the spec existed. `:telemetry.attach/4` against a name nobody emits **succeeds**
  — so a consumer wired a dashboard to it, got no error, and saw an empty panel, which reads
  as a venue with no traffic rather than as an unimplemented spec.

  `:link, :up` and `:link, :down` on the connection transitions, and `:link, :event` per
  frame with its wire size. The request and rate-limit events come free with
  `dp_exchange_core` 0.2.8, since every venue's REST goes through `Core.HttpClient` and every
  metered call through `Core.DefaultRateLimiter`.

  **The metrics channel is alongside the notice channel, never instead of it.** A
  `Core.Notice` is a condition a consumer must ACT on; telemetry is aggregate and lossy by
  design. A consumer that alarmed on a telemetry gauge would be acting on a channel
  documented as droppable, and one that graphed notices would be graphing something it is
  meant to handle.

  Two details worth stating, because both are places a plausible-looking number would have
  been wrong:

  A frame is counted **whether or not it parses**. The question the event answers is "is the
  venue sending", and a frame this package could not read is still a frame the venue sent —
  counting only what parsed would make a decoder bug here look like a silent venue.

  There is **no `:link, :reconnect_attempt`** from this package. It reconnects immediately
  and keeps no attempt counter, so the only number it could report is `attempt: 1`, every
  time — which renders a reconnect loop as an endless series of first attempts. That is
  worse than no event. `dp_exchange_schwab` tracks `login_failures` and does emit it.

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.8`**, which is where `Core.Telemetry`'s
  emitter functions live. A venue calling `:telemetry.execute/3` directly would be naming
  events by hand in five places — five chances to write `:link_up` instead of
  `[:dp_exchange, :link, :up]`, with the drift invisible, since a wrong name emits
  successfully and simply never reaches a handler — and would be using a transitive
  dependency it never declared.

## [0.2.6] - 2026-09-11

### Added

- **Back-pressure: a slow subscriber no longer gets an unbounded mailbox.** `Core.Venue`'s
  `subscribe/2` doc promised this from the day the contract was written, and no venue in
  this family implemented any of it — every one fanned out with a bare `send/2` and had
  never looked at a subscriber's mailbox. A consumer that stalled accumulated a mailbox
  until the node died, with no notice, no log line, and `coverage/1` reporting perfect
  health throughout, because the feed genuinely was delivering.

  Past a bound (default 10,000 queued messages, `:max_queue_len` at start) this feed stops
  sending to that subscriber and emits a `:degraded` notice naming it, the queue length and
  the bound — and a second `severity: :info` notice when it catches up. The pair brackets
  exactly the window a consumer has to reconcile from the pull endpoints.

  Implemented in `dp_exchange_core` 0.2.6 as `Core.Fanout`, shared rather than written five
  times. Three properties worth stating, because they are what make dropping acceptable at
  all: another subscriber that is keeping up is unaffected; `coverage/1` does not change,
  because it reports what the *venue* delivered to this package and not what this package
  forwarded; and **notices are never subject to the bound**, since the notice saying a
  subscriber is being dropped must not be the first casualty of that same subscriber being
  dropped.

  See `usage-rules.md`, "A slow subscriber gets dropped, and told".

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.6`, and this one is hard.** `Feed` calls
  `Core.Fanout.max_queue_len!/2` at `init/1` and `Core.Fanout.deliver/4` on every payload.
  Against a lower Core this package does not misbehave, it fails to compile — which is the
  good outcome.

- **The pid-or-registered-name subscriber resolution moved to `Core.Fanout.resolve/1`.** All
  five venues had written it identically since DpCryptoManagement's issue #15; the data path
  and the notice path now share one definition, so they cannot drift into disagreeing about
  what counts as a reachable subscriber.

## [0.2.5] - 2026-09-10

## [0.2.4] - 2026-09-10

### Fixed

- **`coverage/1` kept answering `:stream` for symbols the dropped connection had been
  delivering.** `Socket.handle_disconnect/2` returns `{:reconnect, state}`, so a transport
  drop leaves the socket *process* alive — no `EXIT` fires, and this feed's only delivery
  reset was keyed on `isolate_crashed_socket/2`, a process death that never happened. So
  between a drop and a successful resubscribe, `coverage/1` reported symbols arriving from
  nowhere; and where a reconnect restored the socket while the venue silently failed to
  restore some symbols, those symbols reported `:stream` indefinitely, on frames observed
  before the disconnect. That is the 325-subscribed/174-delivering incident `coverage/1`
  was written for, reappearing one level down.

  A `:link_down` notice now clears the delivery records the way the crash path already did.
  `wanted` is untouched, the resubscribe timer is untouched, and symbols return as frames
  arrive after the resubscribe — seconds, in a live market. The dip is real and is already
  bracketed by the `:link_down`/`:link_up` pair.

  `dp_exchange_core` 0.2.5 writes the rule into `Core.Venue`'s `coverage/1` doc — observation
  is scoped to the current transport session — and records why it cannot be carried by a
  conformance assertion. All four streaming venues in the family had this wrong in the same
  way and are fixed in the same batch.

- **No published version was attributable to a changelog entry (dp-exchange-core issue
  #32).** Every entry in this repository's `CHANGELOG.md` sat under `## [Unreleased]` — in
  the **published tarball**, since `CHANGELOG.md` ships inside it — so a consumer could not
  tell which version introduced a breaking change, or whether they had already taken one.

  That mapping is load-bearing here rather than cosmetic. This family signals a breaking
  change with a **minor bump**, and those changes are repeatedly a refusal tuple or struct
  gaining a field: invisible to the compiler, and invisible to a test that pins the old
  shape. The reporting consumer's written upgrade procedure is *"read `CHANGELOG.md` for a
  `### Changed — BREAKING` section, then grep for every clause matching the old shape"* —
  which needs version → change. Without it, `### Changed — BREAKING` says *that* the shape
  changed and never whether they already have it.

  They gave two incidents from the same three days, and the difference between them is the
  whole argument: `dp_exchange_gemini` 0.1.42's refusal-shape change was found **after
  shipping**, by reading a fix comment, while `dp_exchange_webull` 0.4.0's was caught
  **before** — because that entry happened to name the version in its prose.

  **Two halves, because fixing only one would have let it recur immediately:**

  - **Going forward**, the release pipeline cuts a `## [x.y.z] - YYYY-MM-DD` heading itself,
    in the publish job and **before `mix hex.publish`** — a heading added after the upload
    would describe a tarball nobody can read.
  - **Retroactively**, the accumulated block now sits under a `## [<version>] and earlier`
    heading. Attributing each of ~1,600 lines to the exact release that carried it is
    archaeology; this restores the one fact a consumer needs from it — that none of it is
    pending — which is what the reporter suggested.

  The issue measured five packages, from their `deps/`. `dp_exchange_schwab` has the same
  defect and is not one of their dependencies, so it could not appear in their table: six
  instances, all fixed here.


## [0.2.3] and earlier - 2026-09-10

**Everything below this line is published.** Entries were accumulated under
`[Unreleased]` from the first release to `0.2.3`, so no reader could tell shipped work
from pending — dp-exchange-core issue #32. Attributing each entry to the exact version
that carried it would be archaeology across hundreds of releases; this heading restores
the one fact a consumer actually needs from it, which is that none of it is pending.

Releases from here on cut their own `## [x.y.z]` heading at publish time, so this is
the last block that will ever need a range.

### Documentation

- **`usage-rules.md` now answers the question a consumer actually has after 0.2.0: when is
  `venue_time` `nil` here?** The migration note said what the fields mean; it did not say
  what this venue does with them, which is the part a caller writes a branch for.

  **Never on a REST `Quote` or `OrderBook`** — a response with no `Date` header fails the
  call outright, so the field is always populated. `nil` appears only on a **streamed**
  partial-depth snapshot, where the vendor's own AsyncAPI requires no event time. The
  moduledocs that still described this as a "quote timestamp" were updated to name the
  field, since after a rename prose pointing at the old name sends a reader looking for
  something that no longer exists.

### Changed — BREAKING

- **`Core.Types.Quote` and `Core.Types.OrderBook` no longer carry `:timestamp`.** They carry
  **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
  **`:observed_at`** (when this package read it, always present). Requires
  `dp_exchange_core ~> 0.2.1`; this package's own version takes a minor bump to signal it.

  `:timestamp` was documented as the venue's own and "never invented", and two packages in
  this family could not keep that promise, because the frames they decode carry no venue time
  at all. With one field their only options were to lie or drop real data, and they lied.

  **One path in this package was the reason.** `WsDecode.to_order_book/3` — partial-depth
  snapshots — put the local clock in `:timestamp` because the vendor's own AsyncAPI requires
  only `[lastUpdateId, bids, asks]` there, where `BookTicker` requires an `E`. It now reports
  `venue_time: nil`, which is the truth it could not previously express. Every other
  `Quote`/`OrderBook` this package builds has a real venue time and carries it unchanged.

  The full reasoning, the three options weighed and the consumer's own argument for this one
  are in `dp_exchange_core`'s
  `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`, announced and answered as
  dp-exchange-core issue #31. `Trade`, `Fill`, `Balance` and `OrderBookDelta` are unchanged.

### Documentation

- **Three things the consumer learned by using the restored `InvalidNonce` message
  (issue #1), written down so nobody re-learns them.** No code changed; they confirmed the
  package's shape was already right and the gap was in their own host.

  **The diagnosis neither of us predicted.** Their nonces were rising normally — exactly
  epoch seconds — and the venue still said *"has not increased"*. A time-based key validates
  against a ±30 s window, not a previous value; *"has not increased"* is the **incremental**
  validator's sentence. The key was provisioned incremental, the caller was sending the
  `:time_based` default, and that is precisely the mismatch `Auth`'s moduledoc says fails
  loudly on the first request. `usage-rules.md` now names the symptom and the fix, because
  the venue exposes no way to ask how a key was provisioned — the error sentence is the only
  signal, and it now reaches the caller.

  **Raising the mark is a one-way door.** Every accepted nonce becomes the key's stored
  high-water mark, and Gemini compares them as arbitrary-precision integers. Clearing a
  stuck mark by emitting something enormous — a real host used `counter × 1_000` ≈ `1.78e21`
  — works once and permanently sets the mark there. No mode this package offers can ever
  satisfy that key afterwards (`:incremental` tops out near `1.789e12`; even nanoseconds
  reach only ~`1.789e18`, under `2^64`). Rotation is the only remedy, and it is a human
  action.

  **This package cannot walk through that door**, and `Auth`'s moduledoc now records that as
  a property to preserve rather than an accident: `nonce(:incremental)` is
  `max(now_ms, previous + 1)`, anchored to the wall clock and advancing past it by one only
  within a single millisecond — reaching `1e21` would take `1e21` calls. It also records why
  there is deliberately **no runtime guard** against a nonce far ahead of the clock: a guard
  would turn ordinary NTP corrections into a dead feed, which is a worse and much more
  frequent failure than the one it would prevent.

- **A caution for anyone else upgrading past 0.1.42.** The same consumer found that their
  `normalize_error/1` matched a bare refusal atom, so the new `{reason, message}` 2-tuple
  fell through to a passthrough clause and skipped their canonical mapping — silently.
  Nothing raised. If you pattern-match refusal reasons as atoms, add the two-tuple clause
  deliberately rather than discovering it through a mapping that quietly stopped happening.

### Fixed

- **A known refusal dropped the venue's `message`, which for `InvalidNonce` is the whole
  diagnosis (issue #1).** `refusal_reason/1` answered a reason it recognised with a bare
  atom and discarded `body["message"]`, while a reason it did *not* recognise kept the
  venue's words. That asymmetry contradicted the rationale written directly above the
  function — "the venue's wording is the only thing that says what actually happened" — and
  it left a real failure undiagnosable.

  `:invalid_nonce` names the category; the message is the entire diagnosis, because the two
  situations it separates have **opposite remedies**. A stored high-water nonce above what
  we send means send larger ones (a key poisoned near `2^64` needs values above it, since
  Gemini compares nonces as arbitrary-precision integers). A mark that has climbed past
  anything we can emit means rotating the key, which only a person can do. The consumer who
  filed this had **164 log lines** reading `refused: :invalid_nonce` and no way to tell
  which they were looking at.

  A known reason now carries the sentence: `{:refused, {:invalid_nonce, "Nonce '…' has not
  increased since your last call"}}`.

  **Two shapes, deliberately.** `{reason, message}` means the venue named a category *and
  said more*; a bare `reason` means it named a category and stopped. Flattening them would
  either invent a `nil` message for refusals that never had one or throw away the sentence
  that made this worth filing — and it would break `Fake` parity, since the fake builds
  refusals literally and must stay shape-identical to the real venue (assertion 9). Every
  message-less refusal matches exactly as it did; only callers that were being under-informed
  need a new clause. `{:unknown_reason, word}` is unchanged.

  The property, in the filer's words: **a known reason is never less informative than an
  unknown one.**

### Documentation

- **A read time sits in a field the contract documents as the venue's own, and it is now
  labelled where it happens.** `Core.Types.Quote` says `:timestamp` is "the venue's own…
  never invented: a quote whose freshness we cannot state is a quote we must not return."
  This package's decoder does not keep that rule on the path noted at the code, because the
  venue publishes no time for those frames and the struct has a single `:timestamp` — unlike
  `Core.Types.TopOfBook`, which carries `:venue_time` and `:observed_at` separately and can
  therefore say "the venue did not date this".

  **No behaviour changed.** The gap is in the shared contract, not only here, and closing it
  means altering a published type that a live consumer decodes at every call site — 19 lib
  files and 27 test files across six repositories. That is a written-plan decision by this
  project's own rules, so it is
  `dp_exchange_core`'s `docs/design/2026-09-09_venue-time-and-observed-time.md`, with three
  options costed. What changed here is that a reader of the code is now told, rather than
  finding out by trusting the type's documentation.

### Added

- **`script/check_endpoint_inventory.sh`** — diffs this venue's committed endpoint
  inventory against Gemini's own **machine-readable specifications** (OpenAPI for REST and
  prediction markets, AsyncAPI for the socket) and reports anything that appeared or
  vanished. Weekly and non-blocking, via `.github/workflows/inventory-check.yml`.

  This is the deeper half of an idea `dp_exchange_core`'s vendor-change design doc already
  settled: across five vendors a *changelog* diff caught nothing, and an **index diff** was
  the only mechanism that ever fired — on this venue, which withdrew the entire WebSocket
  market-data API this family's price feed ran on and announced it by nothing but its
  absence. `check_doc_sources.sh` watches whether cited pages still resolve; this compares
  what the vendor says it serves. **Gemini is the venue where that is possible at all**,
  because it publishes specifications rather than only prose.

  It is a **spec** diff, not a content diff, and that distinction is why it is not noise: an
  operation list is structured and every entry means something, where the rendered pages
  around it carry build hashes and rotating banners.

### Fixed

- **The vendor stopped publishing the `settlementsAccount` WebSocket channel, and the
  checker caught it on its first run.** It was in Gemini's AsyncAPI on 2026-08-31 and is
  absent as of 2026-09-09, with no changelog entry — this venue's documented habit, and now
  the **third** time a *positive* claim about it has gone stale (the withdrawn socket URL,
  the seven candle widths that became nine, and now this).

  **No consumer-facing claim broke**: nothing in `lib/` subscribes to it and
  `capabilities/0` declares `streamable: [:quotes, :top_of_book]`, which does not rest on
  it. The address stays in `WsChannels`, **labelled rather than deleted** — removing it
  would assert "this venue has no settlements channel", and nobody here has established
  that. The channel is private, so probing it needs a credential this repository must never
  hold, and this venue has diverged from its own documentation in *both* directions before.
  **Absent from the spec is not the same fact as absent from the venue.**

  REST (75 operations) and prediction markets (31) were re-diffed in the same pass and are
  unchanged, so the inventory-derived negative claims in
  `docs/reference/gemini/negative-claims.md` still hold. That file now carries the new
  instance and its audit date.

### Fixed

- **Reads now carry `@call_timeout` explicitly, exactly as writes already did.**
  `coverage/1`, `coverage_by_kind/1`, `status/1` and `wanted/1` took `GenServer.call/2`'s
  implicit **five seconds** while every write named a generous one, and that asymmetry is
  what turned a bounded delay into a dead caller in dp-exchange-core issue #28: `coverage/1`
  is the call a consumer's health check makes, so any moment the Feed was legitimately busy
  for longer than five seconds turned a health check into an **exit** — and into a dead
  consumer process, when the read happened inside the consumer's own `handle_call/3`. The
  blocking is fixed at its sources rather than papered over here; this is the second line of
  defence. A read that has to queue behind something should wait for it, not die of it.

### Documentation

- **`Credentials`' moduledoc now says that the redaction wrap lives in `child_spec/1`, and
  that bypassing `child_spec/1` bypasses it.** Requested by the consumer who verified the
  dp-exchange-core #29 fix and then went looking for their canary in their own supervisor's
  state — and found it. Their supervision code builds the child spec itself
  (`start: {__MODULE__, :start_feed, [module, opts, pairs]}`) for a legitimate reason: a
  `Core.PollingFeed`-shaped facade defaults `subscriber` to `self()`, which resolves to the
  *supervisor* when `start_link/1` is called from `init/1`, so a different delivery target
  can only be set at `start_link` time. On that path `child_spec/1` never runs, their
  supervisor stores the raw map, and OTP renders the live key on the next crash exactly as
  before. **Upgrading does not fix it, because nothing from this package is on that path.**

  No code change: `wrap/1` and `wrap_opt/1` were already public, which was all that path
  needed. What was missing was anyone saying so — the natural assumption, "upgraded,
  therefore redacted", is wrong there, and assertion 22 cannot see it because it asks about
  `child_spec/1`'s own rendering. `dp_exchange_core`'s `usage-rules/auth.md` carries the
  full version, including the reshaping case that bit them: a host mapping its own key
  names into a venue's and returning a bare map re-introduces the leak in its own code,
  downstream of anything a package can reach.

### Fixed

- **Credentials were written to the log in cleartext by any crash — dp-exchange-core issue
  #29.** A supervisor stores the `{module, :start_link, [opts]}` MFA its child spec names,
  and OTP writes that argument list through `inspect/1` into the `Start Call:` line of the
  report it logs on **any** child termination. `:credentials` arrived as a plain map, so
  every crash printed the live secret in full. It needs no unusual conditions, it lands in
  ordinary application logs — the artifact most likely to be shipped to an aggregator or
  attached to a bug report — and it defeats credential hygiene upstream of it: a consumer
  can hold the key encrypted at rest and still have it written out in the clear. The
  reporting consumer found live keys this way and nearly pasted them into a GitHub issue
  while reporting a different bug.

  `child_spec/1` now wraps `:credentials` with `DpExchange.Gemini.Credentials.wrap_opt/1`, and
  **the placement is the fix**: wrapping in `start_link/1` or `init/1` does nothing,
  because by then the supervisor above has already captured the raw list. This venue had **no** credentials struct at all, so `DpExchange.Gemini.Credentials` is new — one struct covering both the `:api_key` pair and the `:oauth` access token, because `Kernel.struct/2` ignores keys it does not declare and splitting them would mean inferring a scheme from an untagged map. Redacting the
  value rather than setting the `:sensitive` process flag is deliberate — that flag
  suppresses the whole report, including the stack trace that made the unrelated bug
  diagnosable. This keeps the report and removes only the secret. `dp_exchange_core`'s
  conformance suite gains **assertion 22** for exactly this, so it cannot come back here or
  arrive in a new venue.

### Documentation

- **`Rest.get_order_book/2`'s `depth` default of `50` had no citation — the value was
  correct but unlabelled.** Found by a family-wide sweep for the
  `@pairs_per_socket`/`@shard_spacing_ms` defect class (`dp_exchange_coinbase`): a venue
  fact sitting where a cited one belongs. Gemini's own market-data reference
  (`developer.gemini.com/rest/market-data`, read 2026-09-08) states `limit_bids` and
  `limit_asks` both "Default is 50" — now `docs/reference/gemini/order-book.md`, quoted
  verbatim, and cited from the function's own `@doc` and an inline comment. No value
  changed.

### Added

- **`script/check_doc_sources.sh` and `docs/reference/gemini/doc-sources.tsv`** — a weekly,
  non-blocking check that every vendor documentation page this package cites still resolves
  the way it did when a person read it. It records status and redirect destination and does
  **not** follow redirects or diff content: a permanent redirect is itself the change notice
  (this family lost a streaming API to one, announced by nothing else), while content
  diffing a rendered docs site would be red every week for reasons that are never the reason
  we care about. Built after auditing what would have caught each way five vendors'
  documentation turned out to be wrong — across that whole sample a *changelog* diff caught
  nothing, and an *index* diff was the only mechanism that ever fired. It earned itself
  immediately: on its first run in `dp_exchange_webull` it caught a cited page that 404s, and
  pulling that thread found a rate ceiling five times too permissive against that venue's own
  per-endpoint table. Scheduled Mondays 09:20 UTC via
  `.github/workflows/doc-sources-check.yml`, never on push, never in the publish chain.
  Documentation sites only — never a venue API, which tier 2's never-on-a-schedule rule
  still forbids.

  Twelve pages are tracked here, and two are watched **because they are wrong rather than
  despite it**: `docs.gemini.com/rest-api/`, whose `301` to a different host was the entire
  notice given that Gemini replaced the WebSocket market-data API this family's price feed
  ran on; and the candles page, which lists three `time_frame` values the live API rejects
  and contradicts itself on a fourth. A change to either is news.

- **`1w` and `1M` (the venue's own `1mo`) candle widths.** Re-verifying
  `docs/reference/gemini/candles.md` against the live venue on 2026-09-08 found the
  `/v2/candles` endpoint's own self-describing 400 body had grown from seven accepted
  widths to nine since the 2026-08-28 capture this package shipped with — `1w` and `1mo`
  both now answer `200` with real bars (240 weekly, 115 monthly, measured). Consumers
  reading `historical_timeframes` (via `capabilities/0`) or calling
  `get_historical_prices/4` with `"1w"` or `"1M"` now reach real venue data where they
  previously received `{:error, {:unsupported_timeframe, …}}`. Neither width gets the
  pre-flight `{:error, {:range_unavailable, …}}` the other seven do — see
  `DpExchange.Gemini.Rest`'s moduledoc for why, and what a caller sees instead (a real,
  filtered, possibly-empty result rather than a named refusal).

### Fixed

- **`dp_exchange_core` was pinned to `~> 0.1.48`, but `WsDecode.to_order_book_delta/2`
  calls `Types.OrderBookDelta.new/1`, which Core has only defined since `0.1.53`.**
  `OrderBookDelta.new/1` is a plain function call, not a struct literal, so a resolution
  below 0.1.53 compiles with a warning rather than an error and only raises
  `UndefinedFunctionError` the first time a `depth`/`depthFast` frame decodes — the same
  failure shape already found and fixed in `websockex`'s `~> 0.4` pin across this family
  (`dp_exchange_webull` 0.2.20). `~> 0.1.48` passed every test here because CI always
  resolves the newest allowed Core (0.1.68, per `mix.lock`); a consumer whose own
  dependency graph forced 0.1.48–0.1.52 would not. Raised to `~> 0.1.53`. Found in a
  family-wide audit of declared-vs-actual dependency floors.

  A prior commit ("Move to dp_exchange_core 0.1.68") bumped only `mix.lock`'s resolved
  version, not this floor — it correctly noted `no_venue_contact` and the
  `market_status/1` exemption did not apply here, but the `mix.exs` constraint itself
  was never audited against what this package's own code already required.

  A new test in `ws_channels_test.exs` asserts the resolved Core defines
  `Types.OrderBookDelta.new/1`, so a future loosening of this pin without a matching
  code change fails here first, not only for a consumer.

- **This corrects a mislabel introduced by the "`Fake` was not equivalent to the real
  path…" entry below: `{:error, {:unsupported_auth_scheme, nil}}` for genuinely absent
  credentials was the wrong label, even though moving that case out of `:refused` was
  correct.** That entry fixed a real defect — `Fake` answering the venue's own permanent
  `:refused` for a credential that never left this package — but the replacement label
  claimed the wrong thing: `nil` here is not a SCHEME the venue rejected, it is the
  absence of one, because nothing credential-shaped was supplied and no `:auth_scheme`
  was named. `Auth.headers/5`'s catch-all could not tell "you asked for an unsupported
  scheme" apart from "you asked for nothing at all", so both fell through to the same
  `:unsupported_auth_scheme` tuple. A caller keying off the label — as
  `dp_crypto_management` does — read this as "Gemini does not support this
  authentication method" when the true condition was "no credential was given to sign
  with", the same shape every other venue in this family reports as
  `{:missing_credentials, venue}`.

  `Auth.headers/5` now answers `{:error, {:missing_credentials, :gemini}}` when `scheme`
  is `nil`, before falling through to the catch-all — `:unsupported_auth_scheme` is now
  reserved for a scheme actually named (a caller's own `:auth_scheme`, since
  auto-detection never produces one this module does not implement) and for `:ambiguous`
  (both header families present), which really is a scheme this module declines to
  resolve. `Fake`'s `authenticated_venue_faithful/2` mirrors the same split, so the fake
  still matches the real path exactly rather than re-diverging. Every test pinned to the
  old `{:unsupported_auth_scheme, nil}` shape (`auth_test.exs`, `fake_parity_test.exs`,
  `fake_test.exs`, `fake_injection_test.exs`, `private_test.exs`, `clearing_test.exs`,
  `edge_cases_test.exs`, `gemini_delegation_test.exs`) now asserts
  `{:missing_credentials, :gemini}` instead.

- **The socket's own crash took the whole `Feed` down with it, silently discarding every
  subscription this feed had ever been given.** `ensure_socket/1` calls `Socket.
  start_link/1` from inside `Feed`'s own callback, which links the socket to `Feed` the
  way `start_link` always does. `Feed` never called `Process.flag(:trap_exit, true)`, so
  a socket that exited abnormally — an exception inside a WebSockex callback, or
  anything that killed the socket pid directly — sent an untrappable `EXIT` signal along
  that link and crashed `Feed` too. `DpExchange.Gemini.Supervisor` then restarted `Feed`
  from the *static* `opts` it was given at tree-start, which never carry a consumer's
  later `subscribe/3` calls: a single socket crash cost every symbol this feed was ever
  asked for. Found by a 2026-09-07 supervision audit — proven by linking a real process
  into a running `Feed` the way `ensure_socket/1` does and killing it with
  `Process.exit(pid, :kill)` (not `:normal`, which a non-trapping process ignores),
  which crashed `Feed` before this fix and does not after.

  `Feed` now traps exits. A crashed socket clears `state.socket` and resets
  `delivering_by_kind` (this venue has one socket carrying both streamable kinds, so a
  crash costs both), reports a `:link_down` `Core.Notice`, and immediately calls the same
  `resubscribe/1` the periodic timer already uses — reconnecting and resending `wanted`
  right away rather than waiting out the next 60-second tick. The periodic resubscribe
  itself also gained a matching fix: previously it did nothing at all when `state.socket`
  was `nil`, even with symbols still `wanted` — now it dials a fresh socket first when
  that happens, which is what actually lets a crashed connection recover if the immediate
  reconnect above did not succeed on the first try.

- **A refused subscription reported `:coverage_change` instead of `:refusal`.** A non-200
  subscribe acknowledgement is the venue's own word about a subscription it received and
  declined — `Core.Notice`'s own moduledoc defines `:refusal` as "a symbol the venue will
  not carry", exactly this case, and `dp_exchange_webull`'s `Feed` already reports the
  identical condition (`INVALID_SYMBOL`) as `:refusal`. `:coverage_change` is the generic,
  unexplained resubscribe-failure shape this venue does not have here. Found by a
  cross-package audit comparing notice-kind usage for equivalent conditions across all
  five venues.

- **`child_spec/1` did not declare `type: :supervisor`, so OTP defaulted it to `:worker`**
  — which also defaults `:shutdown` to `5_000`ms instead of `:infinity`. A consumer
  terminating this child gave the whole nested tree (socket, rate limiter, and everything
  under them) only five seconds to shut down gracefully before `:kill`, rather than
  letting it unwind on its own terms. Invisible to any single-package review, and found
  only by diffing `child_spec/1` across all five venue packages against each other;
  `dp_exchange_schwab` was the only one that already declared it.

### Added

- **`coverage_by_kind/1` implemented — `dp_exchange_core` 0.1.48's optional callback.**
  `coverage/1` answers one boolean per symbol regardless of which of this venue's two
  streamable kinds produced it, which is the same collapse that hid Coinbase's
  `level2`/`ticker` split behind a truthful `:stream` (DpCryptoManagement's issue #22).
  Gemini's `@bookTicker` stream carries both `:quotes` and `:top_of_book` on one wire, but
  the two remain independent facts: a frame always yields a `Core.Types.TopOfBook` when it
  parses, and yields an accompanying `Core.Types.Quote` only when that same frame also
  carries a last-traded price — so a symbol can quote continuously while never once
  trading, and `coverage/1` alone cannot tell that apart from full health.

  `Feed` now derives kind strictly from the delivered struct's own type — never from a
  channel name or the `wanted` subscription set — and `coverage/1`'s own map is derived
  from the same per-kind state, so the two cannot drift apart by construction. `Fake`
  reports `:quotes` honestly (the only kind its in-memory `subscribe/2` ever pushes) and
  `:top_of_book` as a declared-but-empty key, matching the real adapter's key set without
  claiming delivery it does not simulate. Verified against this venue's actual delivery
  mechanics: a symbol delivering only a top-of-book update is realistic and is tested; the
  reverse (`:quotes` with no `:top_of_book`) does not occur through the real socket, since
  a `Quote` is only ever built alongside a `TopOfBook` from the same frame.

- **`Fake` wired to `Core.FakeInjection` — DpCryptoManagement's issue #14.** Every
  function with a real success path (not an unconditional `Venue.not_supported()`) now
  checks a queued or always-set outcome first: `get_price/2`, `get_top_of_book/2`,
  `get_order_book/2`, `get_trades/2`, `quantization/1`, `get_funding/2` and
  `get_contract_stats/2` support per-symbol targeting; the remaining 34 functions with
  real logic — balances, orders, staking, conversion, transfers, withdrawal, custody and
  account management among them — support whole-call injection. `authenticated/1` also
  honours `FakeInjection.credentials_bypassed?/1`, letting a wiring-only test skip the
  venue-faithful `{:refused, :missing_credentials}` default without changing it for
  anyone who doesn't opt in. `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are
  deliberately not wired — each takes a symbol list in one call, which whole-call
  injection cannot express partial failure for. Follows the reference implementation
  shipped in `dp_exchange_robinhood`.

- **`DpExchange.Gemini.live?/1`** — whether the environment `opts` resolves to moves real
  money, resolved through the same precedence every call here uses. Meant as a check a
  caller makes of itself before a money-moving call: `live?(environment: :sandbox)` is
  `false`; `live?([])` is `true`, since `:production` is the default. Surfaces
  `DpExchange.Gemini.Environment.live?/1`, which existed already but had no caller
  anywhere in this package's own `lib/` — found by `Core.AdapterContract`'s "16. internal
  wiring" assertion, checked against a local `dp_exchange_core` checkout ahead of its next
  release (this package's own dependency pin stays at `~> 0.1.48` for this change). This
  is the case that assertion's own moduledoc calls out as legitimate public surface the
  facade never offered, not dead code.

### Removed

- **`WsChannels`'s `all/0`, removed.** Returned every channel name the venue's
  AsyncAPI document defines; nothing in this package's own `lib/` ever called it —
  `address/2` and `per_symbol/0` both read the underlying `@channels` attribute directly,
  and the conformance suite this package's tests do not run against itself. Found by
  `Core.AdapterContract`'s "16. internal wiring" assertion. **Breaking** for anyone who
  called it directly; it was never reachable through the facade. `WsChannelsTest` now
  checks the same twenty-two-channel-catalogue facts through `requires_credential?/1`,
  which every known channel answers and no test-only accessor was needed for.

### Fixed

- **`capabilities/0` declared `has_staking: false` and `supports_margin: false` while six
  staking endpoints and three margin endpoints were already `:experimental` in the SAME
  declaration's endpoint map** — a declaration contradicting itself, found in the
  2026-09-06 documentation-accuracy sweep. **This is a behaviour change for a consumer
  routing on either flag**: `has_staking` and `supports_margin` are now `true`, and
  `max_leverage` is `Decimal.new("5")`, the venue's own published ceiling. The endpoints
  genuinely work: `get_staking_rates/1` — the one public endpoint in this set — was
  reprobed live against `api.gemini.com` and returned real provider rates; the other five
  staking endpoints and all three margin endpoints are authenticated and this repo holds
  no credentials to probe them with, so their inclusion rests on Gemini's own OpenAPI
  paths and response shapes, not a live call, and `capabilities/0`'s `measured_against`
  says so explicitly rather than implying otherwise. Gemini gates both features by account
  eligibility (Eligible Contract Participant status for margin, jurisdiction for staking
  assets) the same way it gates order placement by KYC tier — an account entitlement, not
  a statement that the venue or this package lacks the feature, so it does not belong in
  this declaration. See `usage-rules.md`'s new section for the full account-eligibility
  caveat.

- **`Fake` was not equivalent to the real path on several classes of refusal — the "less
  capable is allowed, differently capable is not" rule was broken, not just the one
  reported instance.** Found and fixed in the 2026-09-06 real/fake parity sweep, with
  pinned tests in the new `fake_parity_test.exs` so none of these can drift back silently:

    * `get_historical_prices/4`'s `{:error, {:range_unavailable, tf, …}}` omitted
      `requested:`, which `Rest.get_historical_prices/4` always carries — a consumer's
      tier-1 test asserting the documented shape passed here and would have failed
      against the real venue.
    * **The credential gate answered `{:refused, :missing_credentials}` for every missing
      or malformed credential, everywhere in `Fake` — around three dozen functions.** The
      real path (`Auth.headers/5`, called from `Private.post/4`) answers `{:error,
      {:unsupported_auth_scheme, nil}}` with no credentials at all and no scheme named,
      `{:error, {:missing_credentials, scheme}}` when a scheme is known but its fields are
      incomplete, and `{:error, {:unsupported_auth_scheme, :ambiguous}}` when both header
      families are present — never `:refused`, which the real adapter reserves for the
      venue's own 401/403 body. `authenticated/2` now mirrors `Auth.headers/5`'s exact
      decision tree, including a caller-named `auth_scheme` opt overriding
      auto-detection, and every call site threads `opts` through to it.
    * **Every "symbol not carried" refusal used the same invented `:not_listed` atom**,
      which appears nowhere in the real vocabulary. Each now matches the specific
      endpoint behind it: `:invalid_symbol` for `get_order_book/2`, `quantization/1` and
      `place_order/3` (Gemini's JSON `InvalidSymbol` reason, live-confirmed for
      `quantization/1`); `{:unknown_reason, text}` for `get_price/2`, `get_top_of_book/2`
      and `get_historical_prices/4` (measured live, plain-text 4xx bodies, not JSON).
    * **`get_trades/2` never refused an unlisted symbol at all** — more capable than
      `Rest.get_trades/2`, the forbidden direction. It now refuses, measured live against
      `GET /v1/trades/{symbol}`.
    * **`place_order/3` validated `order_type` and `time_in_force` independently**, so it
      accepted combinations the venue's own "at most one execution option" rule refuses —
      `order_type: :post_only, time_in_force: :fok`, or any option on a `:stop_limit`
      order. `Private.order_wire/2` is now a shared, exposed (`@doc false`) function both
      `Private.place_order/3` and `Fake.place_order/3` validate against, the same pattern
      `Rest.refusal_reason/1` already uses for the refusal vocabulary shared between
      `Rest` and `Private` — one implementation rather than two copies that can drift.

- **A differential depth frame (`@depth`/`@depthFast`) was delivered as the raw, undecoded
  venue JSON — `{:depth_update, message}` — instead of a value in the contract's own
  shape.** `WsDecode.depth_changes/1` decodes exactly this frame into `{price, quantity}`
  levels and has done since the channel was added, but `Socket`'s `depthUpdate` handler
  never called it: it forwarded the raw map straight to subscribers. `Core.
  AdapterContract`'s new "16. internal wiring" assertion — checked against a local
  `dp_exchange_core` checkout ahead of its next release, since this package's own
  dependency pin stays at `~> 0.1.48` for this change — is what found the disconnect:
  `depth_changes/1` had no caller anywhere in this package's own `lib/`. This channel is
  not requested by default (`Feed` only ever asks for `@bookTicker`), so no consumer using
  this package as documented was affected today, but
  the handler was live and reachable the moment anything called `Socket.subscribe/3` with
  `:depth` or `:depth_fast` directly, and would have handed that caller unparsed strings
  under an undocumented tuple shape rather than `Decimal` values under a contract type.
  Now decoded through a new `WsDecode.to_order_book_delta/2`, built on `depth_changes/1`,
  into `dp_exchange_core`'s `Core.Types.OrderBookDelta` — a type added to Core specifically
  so a venue streaming deltas has a non-accumulated shape to hand back, after
  `dp_exchange_coinbase`'s `Socket` was found rebuilding a full book in-process for exactly
  this reason (~22,800 bid levels for one symbol, measured on a consumer's live node).

- **`Socket`'s `bookTicker` handler duplicated `WsDecode.to_top_of_book/3`'s construction
  of `Core.Types.TopOfBook` inline**, rather than calling the decoder — a second
  implementation of the same decode, free to drift from the one `WsDecode`'s own tests
  actually exercise. Found the same way as the depth defect above: `to_top_of_book/3` had
  no caller in `lib/`, despite being fully written, documented and tested in isolation.
  Now called directly; no behavioural change, since both implementations decoded the same
  fields the same way.

- **A per-account channel given a non-empty symbol list subscribed to nothing, silently,
  and reported success.** `WsChannels.address/2` already refuses this shape —
  `{:error, {:channel_takes_no_symbol, channel}}` — but `Socket.streams/2`'s
  comprehension silently drops any address that fails to build, so `Socket.subscribe(pid,
  ["BTC-USD"], :orders_account)` built zero frames and `send_rpc/3`'s `[]` clause answered
  plain `:ok`. `WsChannels.per_symbol/0` had a matching defect: written, documented, and
  never called from anywhere in `lib/`. `subscribe/3` and `unsubscribe/3` now check
  `per_symbol/0` before reaching `streams/2` at all, answering
  `{:error, {:channel_takes_no_symbol, channel}}` up front. A channel `WsChannels.
  requires_credential?/1` marks private is refused the same way, with `{:error,
  {:credential_required, channel}}` — this socket never authenticates a connection, so a
  private channel could previously only ever fail at the venue, one round trip later, and
  `requires_credential?/1` had exactly the same "no caller in `lib/`" defect as
  `per_symbol/0`. Neither of these channel shapes is reachable through the public facade
  today (`Feed` only ever requests `:book_ticker`), so no consumer was affected.

- **`Environment.validate!/1` carried its own literal `[:production, :sandbox]` guard — a
  second, hand-copied statement of exactly what `Environment.known/0` already declares.**
  `known/0` had no caller in `lib/` and could have drifted from the guard silently if
  either were updated alone; `validate!/1` now checks membership in `known()` instead, so
  there is one place this package's set of recognised environments is written down.

- **`SymbolFormat.to_canonical_symbol/1` and `to_exchange_symbol/1` read the `@mapping`
  module attribute directly, bypassing `mapping/0`** — the same accessor `quotes/0` and
  `capabilities/0`'s `supported_quotes` already read through. No behavioural change
  (`mapping/0` returns the same attribute), but `mapping/0` had no caller in `lib/` before
  this — its own moduledoc's claim that it exists "so the conformance suite can drive
  `CanonicalPair` with it" was the whole reason, and a test is not a caller `Core.
  AdapterContract`'s "16. internal wiring" assertion counts.

- **A 404 on a symbol-scoped market-data GET was reported as a retryable error, not the
  permanent refusal it is.** Measured live 2026-09-06: `GET /v1/pubticker/{symbol}` and
  `GET /v1/fundingamount/{symbol}` both answer 404 for a symbol the venue does not carry
  — `/v1/pubticker` names the condition in plain text (`'X' does not have available data
  yet`) — while every other status this module's `get_with_headers/2` did not recognise
  fell to the generic `{:error, {:exchange_error, …}}` clause. That clause is the shape
  this family reserves for a failure worth retrying; a permanently unlisted symbol read
  as one forever. 404 now takes the same `{:refused, reason}` path as 400 on every
  symbol-scoped read (`get_price/2`, `get_top_of_book/2`, `get_historical_prices/4`,
  `get_order_book/2`, `get_trades/2`, `get_funding/2`, `next_funding_timestamp/2`,
  `get_contract_stats/2`, `quantization/1`).

- **A refusal body that was not JSON collapsed to a bare `{:refused, :refused}`, discarding
  the venue's only stated reason.** Measured live 2026-09-06: `/v2/candles/{symbol}/{width}`'s
  400 body is plain text (`"Supplied value 'X' is not a valid symbol"`), not the
  `{"reason": …}` shape every other refusal in this package carries. `Rest.refusal/1` and
  `Private.refusal/1` both pre-decoded the body through the same helper their 2xx success
  path uses, whose fallback for unparseable JSON is `%{}` — losing the text before
  `Rest.refusal_reason/1` ever saw it, even though that function's own moduledoc states the
  opposite intent ("a reason NOT in that set keeps the venue's own words as data"). Both now
  pass the raw body to `refusal_reason/1`, which decodes it itself and keeps the text as
  `{:unknown_reason, text}` when it is not JSON; a genuinely empty body still degrades to
  the plain `:refused` atom, since there is nothing in it worth keeping.

- **`get_trade_history/2`'s `:since` and `:limit` reached the venue as `to_string/1` output
  instead of the venue's own units.** Every other filtered read in `Private` (`get_orders/2`
  with `history: true`, `get_transactions/2`, `list_custody_fees/2`, `list_accounts/2`, the
  staking history/reward reads) converts a `since:` `DateTime` to Unix milliseconds before
  it goes on the wire — `/v1/mytrades`'s own request examples confirm the unit
  (`timestamp: 1591084414000`). `get_trade_history/2` alone reached `maybe_put/3` instead,
  which stringifies whatever it is handed: a `DateTime` became `"2026-08-28 17:00:01Z"` on
  the wire, a shape the venue's `timestamp` field does not parse, so the filter silently
  narrowed nothing rather than erroring or filtering correctly. `:limit` had the matching
  defect for `limit_trades`, sent as `"100"` instead of the documented integer `100`. No
  test in this package's suite ever passed a `DateTime` to `get_trade_history/2`'s `:since`,
  which is how this shipped unnoticed. Now uses `put_present/3` and `timestamp_param/1`,
  matching `get_orders/2`'s `history_params/1`.

- **`get_positions/2` carried a position's `symbol` in whatever case the venue's response
  happened to use, instead of the canonical uppercase form every other reader in this
  package produces.** The venue's own `/v1/positions` example sends `"btcgusdperp"`
  (lowercase, the same case `/v1/symbols` uses); `to_position/2` passed `row["symbol"]`
  straight onto the struct unchanged, so a real position arrived as `symbol: "btcgusdperp"`
  beside `to_order/1`'s uppercase form for the identical family of endpoints. Every test
  fixture in this package wrote `"BTCGUSDPERP"` by hand and none of them ever asserted on
  `position.symbol`, so the venue's actual casing was never exercised. Now reads the symbol
  through `SymbolFormat.to_canonical_symbol/1`, the same conversion `to_order/1` already
  applies — a perpetual takes the `:nomatch` path through `CanonicalPair.to_canonical/2`
  and comes back uppercased and unsplit, matching `Fake`'s `"BTCGUSDPERP"`.

- **The periodic resubscribe's own failure path was silent — the same shape of defect the
  resubscribe timer itself was built to close (G5, above).** `resubscribe/1`'s `{:error,
  reason}` branch reached only a `Logger.warning`; `grep -n "Notice.new(" lib/dp_exchange/gemini/feed.ex`
  matched nothing in this file before this fix. A consumer whose reconnect kept failing to
  resubscribe — a venue outage, a stale socket the venue silently stopped honouring — had
  no facade-level way to learn it, the same "recovered from a quiet chart, or not at all"
  gap G5 exists to close for the reconnect itself.

  The discovery route is DpCryptoManagement's issue #21, the poll-feed sibling case:
  `dp_exchange_core`'s `Core.PollingFeed` answered nothing for hours while its own
  "delivered NOTHING" log line sat ungrepped, and its fix established the
  `notice_state: :ok | :dead` latch this package now borrows — a `Core.Notice` fires on
  the transition INTO failure and a recovery notice fires on the transition back OUT,
  never once per tick for as long as an outage lasts. `dp_exchange_coinbase`'s `Feed`
  established `:coverage_change` as the kind for this family's sibling shape — a channel
  subscribe that exhausted its retries without ever becoming delivery — but its own notice
  there is one-shot, with no recovery counterpart, because that retry chain either
  succeeds silently or is left for the next unconditional cycle. This module's resubscribe
  runs forever on a fixed timer rather than a bounded retry chain, so the stricter,
  `PollingFeed`-shaped latch applies: a new `resubscribe_notice_state` field tracks the
  last attempt's outcome, a `:warning` notice fires once on the first failure after a
  success (or after boot), and an `:info` recovery notice fires once on the first success
  after a failure. The `Logger.warning` is unchanged and still fires on every failing
  tick — only a consumer-visible `Notice` is new, and it is deliberately quieter than the
  log beside it. A dead socket or an empty `wanted` set (nothing attempted) touches neither
  the log nor the latch, matching the pre-fix behaviour for that branch exactly.

- **`:rate_limit_blocking` was unreachable on every REST call this package makes —
  family-wide gap, DpCryptoManagement's issue #23.** `Core.HttpClient.check_rate_limits/1`
  reads this option to choose `acquire/3` (wait for capacity) over fail-fast `check/3`,
  and its own error message on a self-inflicted throttle tells a caller to set it — but no
  caller could, on this venue: `Rest.request_opts/1` and `Private.request_opts/1` both
  stripped it from their forwarded-options allowlist before it ever reached
  `Core.HttpClient`. The same defect (`dp_exchange_webull`'s issue #23,
  `dp_exchange_robinhood`'s issue #16) audited across the rest of the family; this venue
  was one of four still carrying it.

  Both allowlists now forward `:rate_limit_blocking`, proven with a recording rate limiter
  that records which of `acquire/3` / `check/3` was actually called — not merely that the
  keyword survives the allowlist. **Not defaulted anywhere in this package**, unlike
  `dp_exchange_webull`'s `Feed` and `dp_exchange_robinhood`'s `Feed`: this venue's own
  periodic resubscribe (`DpExchange.Gemini.Feed`'s unconditional 60s re-issue) sends
  WebSocket frames, not HTTP, so there is no rate-limited background replay here to
  justify choosing a default on a caller's behalf. A caller that wants blocking opts in
  explicitly.

- **Decoding a venue refusal could exhaust the VM's atom table and kill the whole BEAM —
  family-wide defect sweep, G7.** `refusal/1` in both `Rest` and `Private` built its result
  with `String.to_atom(Macro.underscore(reason))`, where `reason` comes straight out of
  Gemini's own JSON error body. Atoms are **never garbage collected** and the table is
  finite (default ~1,048,576): a venue emitting unbounded distinct reasons — through error
  variety, a changed error format, anything this package does not control — mints a
  permanent atom every time and eventually takes down the entire node. These packages run
  *inside* a consumer's application, so that is the consumer's whole system, not just this
  venue.

  `mix sobelow` had been reporting it as `DOS.StringToAtom` all along, and it was waved
  through twice in one day as a "pre-existing, unrelated, low-confidence warning". It was
  none of those three.

  Fixed by writing the recognised refusal vocabulary down at compile time
  (`@refusal_reasons`) and mapping against it, so an atom can only ever come from a fixed
  set — the same discipline `Core.FakeInjection` already adopted deliberately for this
  exact class. Every reason callers already match on keeps its existing atom, unchanged.
  An **unrecognised** reason now returns `{:unknown_reason, reason}`, keeping the venue's
  own wording rather than being flattened to a bare `:refused`: the list is deliberately
  not exhaustive (Gemini adds reasons without notice), so it has to degrade legibly rather
  than silently. The duplicate copy in `Private` now delegates to the one implementation —
  it had to be found and fixed twice, and could as easily have been fixed in only one.

  Regression test asserts `:erlang.system_info(:atom_count)` is unchanged across fifty
  novel reasons, because the old return value looked perfectly reasonable the entire time
  the bug was live.

  `@refusal_reasons` itself was reviewed once more before landing: it had picked up three
  plausible-sounding entries (`RateLimit`, `EndpointNotFound`, `InsufficientFunds`) with no
  vendor documentation and no live measurement behind any of them, while missing four codes
  Gemini's own error table actually documents (`MissingApikeyHeader`, `MissingPayloadHeader`,
  `MissingSignatureHeader`, `AmbiguousAuthentication`). The guessed three were removed and
  the documented four added — every entry in the map now traces to either
  `docs/reference/gemini/rate-limits-and-auth.md` or a live measurement recorded elsewhere
  in this module's own docs, nothing asserted from how a reason *sounds*.

- **`get_staking_rates/1` had `asset` and `provider_id` swapped, and read a field that does
  not exist — family-wide defect sweep, G1+G2.** Re-verified live 2026-09-05:
  `GET https://api.gemini.com/v1/staking/rates` returns
  `{"<provider-uuid>": {"ETH": {...}, "SOL": {...}}}` — the outer key is a **provider
  UUID**, the inner key is the **asset**. This package assumed the reverse, so every
  `StakingRate` it built carried an upcased UUID as `:asset` and a real asset symbol as
  `:provider_id`. Gemini's own OpenAPI names the nesting the same way — `StakingRateResponse`
  nests a `StakingRateProvider` under "Provider UUID Keys", which itself nests "Currency
  Symbol Keys" — so the swap was checkable without a live call and wasn't: the test fixture
  was keyed the same wrong way the code assumed, which is exactly why it passed. The same
  live payload also showed `:deposit_limit_usd` reading `depositLimitUsd`, a field the venue
  does not send — the real field is `depositUsdLimit`, and every row's cap was silently
  `nil`. Both fixed together; the fixture is rewritten to the captured shape rather than to
  either assumption.

- **`networks_for_asset/2` was documented "Public" and could not succeed for any consumer;
  `list_networks/2`'s network direction `POST`ed to a route the venue only serves as
  `GET` — family-wide defect sweep, G3+G4.** Re-verified live 2026-09-05:
  `GET /v2/network/BTC` with no credentials returns `401 MissingSecurityHeaders`, and the
  vendor's OpenAPI requires `apiKeyAuth`, `signatureAuth` and `payloadAuth` on it — `Rest`
  never aliases `Auth` and sends no credentials anywhere, by design, so this direction was
  dead from the day it shipped. Independently, `list_networks(nil, network: …)` sent
  `POST /v2/networks/{network}/assets`; the vendor documents that route as `GET`
  (`operationId: getAssetsForNetwork`) — there is no POST form. Together the two bugs meant
  **both directions of network discovery were dead**, on the one call whose own docstring
  warns that a wrong network produces an address on a chain this venue does not credit.
  Both now go through `Private.list_networks/2`'s `signed_get/3` — the asset direction moved
  out of `Rest` entirely, since it was never really public and `Rest` has no way to sign a
  request; the network direction now asks `GET` instead of `POST`.

- **No resubscribe after a WebSocket reconnect — a silent coverage collapse with no
  error — family-wide defect sweep, G5.** WebSockex reconnects a dropped socket on its
  own; `Socket.handle_connect/2` only emitted a `:link_up` notice, and `Socket`'s own state
  (`%{subscriber:, request_id:}`) carried no memory of what had been subscribed — there was
  nothing to resend even if it tried. `Feed`'s `wanted` `MapSet` was written on every
  `subscribe/3` and read by nothing (confirmed by grep). The sequence a consumer actually
  saw was `:link_down` then `:link_up` — which reads as "recovered" — followed by silence
  until someone noticed a quiet chart. Same incident class the sibling
  `dp_exchange_coinbase` package already carries a fix for; adapted here rather than
  reinvented. `Feed` now re-issues its `wanted` set on a 60-second timer, unconditionally —
  not gated on detecting a reconnect, because a reconnect this process never learns about
  (a supervisor restart of `Socket`, for instance) is indistinguishable from one it does.

  Also fixed alongside it: `ensure_socket/1` calls `Socket.start_link/1` synchronously
  inside `handle_call`, and `Feed`/`SandboxFeed` are named, shared processes — the whole
  blocking window that connect can take is borne by every other consumer's `subscribe/3`,
  `unsubscribe/2` and `coverage/1` queued behind it. The connect was never actually
  unbounded, which was the first, wrong diagnosis of this: `Socket.start_link/1` passed no
  opts to `WebSockex.start_link/4` at all, so it silently inherited `websockex`'s own
  general-purpose defaults — measured from the vendored dependency,
  `socket_connect_timeout: 6_000`ms and `socket_recv_timeout: 5_000`ms
  (`deps/websockex/lib/websockex/conn.ex:10-11`) — rather than choosing them. 6s + 5s of
  connect, plus one `send_frame` for the subscribe that follows (up to 5s), is 16s against
  `Feed`'s own 15s `@call_timeout`: already over budget before any other overhead in that
  call. `Socket.start_link/1` now sets `:socket_connect_timeout` (3s) and
  `:socket_recv_timeout` (2s) explicitly, chosen against that same budget — 3s + 2s + 5s is
  10s, leaving 5s of headroom — and both remain overridable through `opts`, threaded from
  `Feed.start_link/1` through to `Socket.start_link/1` alongside `:url` and `:environment`.

- **`Feed.fan_out/2` crashed on a subscriber registered by name — DpCryptoManagement's
  issue #15, same defect found on the sibling `dp_exchange_coinbase` package.**
  `subscribe/2`'s `to:` option accepts any value, and `fan_out/2` called
  `Process.alive?/1` on it directly — which only accepts a pid and raises on anything
  else. A consumer registering itself under a name (ordinary OTP practice) and handing
  that name to `to:` crash-looped the whole `Feed` GenServer on every delivery. Fixed by
  resolving a subscriber (pid or name) to a pid first, treating an unregistered name the
  same as a dead pid: silently skipped, never a crash.

- **`Decimal.new/1` raised on a malformed venue field, and it was reproducible in
  production.** `dp_crypto_management` filed the same defect against `dp_exchange_webull`
  (issue #3); auditing every copy of the pattern in this package found it live and
  triggerable here too. A 347-symbol subscribe against production `wss://ws.gemini.com` —
  this package's own venue socket, at the scale a real consumer runs — crashed the
  connection within seconds on a `bookTicker` frame carrying `""` for a bid.

  Every `decimal/1` helper (`rest.ex`, `socket.ex`, `private.ex`) now parses with
  `Decimal.parse/1`, requiring the whole string be consumed, matching the idiom
  `ws_decode.ex` already used. Re-ran the same 347-symbol live subscribe after the fix:
  **347 of 347 delivered, zero crashes, in 20 seconds.**

- **A second, quieter defect the first fix would otherwise have introduced**: the lenient
  parse turning a malformed price into `nil` instead of raising would have let a `Quote`
  with `price: nil` reach a subscriber — `@enforce_keys` does not check that a value is
  non-nil, only that the key was given. `get_price/2`, `get_trades/2`, `get_fx_rate/3` and
  the socket's own last-trade delivery now refuse the record instead
  (`{:error, {:invalid_decimal, field, value}}`), rather than silently delivering a Quote,
  Trade or FxRate with a fabricated-looking `nil` in a field the type promises is real.

### Documentation

- **`usage-rules.md` twice told a consuming agent that every authenticated endpoint here
  returns `{:error, :not_supported}`** — "Balances, orders, fees, transfers and trade
  history are yours to implement against your own auth" and, in "What this package does
  not do", "the host authenticates, so balances, orders, fees, transfers and trade
  history all return `{:error, :not_supported}`." Both were false the day they were
  written: `Private` (~2,400 lines) implements all of them, and `capabilities/0` has
  declared `get_balances/2`, `get_orders/2`, `place_order/3`, `get_fees/2`,
  `get_transfers/2`, `get_trade_history/2`, `get_staking_balances/1` and the rest of the
  account surface `:experimental` since 2026-08-28 — verified again here with
  `mix run -e` against the live module, not read off the source. The document
  contradicted itself in the same breath: its own sections on `stake/3`, `unstake/3` and
  clearing orders correctly walk through using that same authenticated surface. The
  detailed how-to-use sections were right; the two blanket "not_supported" claims were
  wrong, and are now corrected to say what this package actually does — signs a request
  you hand it credentials and a scheme for, obtains and stores neither. Left unfixed,
  a consuming agent reading this would have concluded Gemini has no authenticated surface
  and rebuilt an already-implemented API against its own auth layer, the inverse of the
  Robinhood defect. Family-wide defect sweep, G6.

  Also found and fixed in the same pass: `usage-rules.md` still said
  `supported_instrument_types: [:spot]` under "Perpetuals are excluded", stale since
  perpetuals landed above in this same file — `capabilities/0` has declared
  `[:spot, :perp]` since 2026-09-01. Corrected to name the perpetuals endpoints instead of
  a capability list the venue section had already outgrown.

- **The `:unsupported` list is now split.** `venue_does_not_serve/0` names the 22 endpoints
  that are Gemini's own absence — options, watchlists, replace/preview, position closing —
  each with the source and date behind it; three stay under `@not_ported` because they are
  the venue's surface and this package's backlog.
- **`README.md` states what the contract covers** — 62 of 87 callbacks `:experimental`, the
  best-covered venue in the family.
- **`docs/reference/gemini/endpoint-inventory.md`'s counts refreshed.** It read "18%" until
  this release; the vendor-side page counts had not moved, this package's coverage had.

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
