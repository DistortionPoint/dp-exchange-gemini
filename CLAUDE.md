# CLAUDE.md

Guidance for Claude Code working in this repository.

**ABSOLUTE RULES**:
***THIS IS ELIXIR. It is Functional, Parallel, and Concurrent. You CAN NOT treat this like Python, Ruby, or Javascript.
1. ALL operations MUST be concurrent/parallel in a single message
2. Prefer Agents over MCPs
3. **NEVER save working files, text/mds and tests to the root folder**
4. ALWAYS organize files in appropriate subdirectories
5. ALWAYS do CI Checks before COMMIT
6. NEVER COMMIT OR PUSH without confirmation
7. MANAGE YOUR CONTEXT
8. ALL TESTS MUST PASS — 0 failures allowed
9. ALL Credo issues must pass. Not just some, not just critical, ALL
10. NEVER USE PERL or PYTHON
11. NEVER USE the SYSTEM TMP. NEVER MEANS NEVER. DO NOT EVER DO THIS
12. NEVER REWRITE SHARED GIT HISTORY — no force-push, no rewriting a branch that has
    been pushed, no `git reset --hard` over work you did not create. Ordinary git IS
    allowed and expected: `status`, `diff`, `log`, `add`, `commit`, `rebase` onto
    `origin`, `push`. Rule 6 is the gate on commit and push, and it is the only gate.
    This rule was previously written as "NEVER USE GIT", which was wrong: publishing is
    a merge to `main`, so that reading made the package pipeline unrunnable and turned a
    self-imposed rule into a fake blocker handed back to the architect.
13. NEVER USE KILL/PKILL UNSCOPED, only scoped to your specific things. NEVER MEANS NEVER. DO NOT EVER DO THIS

**THIS REPO IS PUBLIC.** Every commit is a public commit, and git history is not
retractable. Verify `.gitignore` covers `.env*` (except `.env.sample`) and `.mcp.json`
before anything is staged. A leaked credential is not fixed by a later commit.

## Project Overview

`dp_exchange_gemini` is the Gemini venue package for the **DpExchange** family. It
implements `DpExchange.Core.Venue` — the same facade every venue in the family exposes —
and nothing else in this package is public API.

**Status: EXPERIMENTAL.** It has not run in production. Maturity is declared per endpoint
through `capabilities/0`, not per package.

## The one rule everything else follows from

**The facade is the boundary, and nothing crosses it.** This package's transport, rate
limiting, signing, session handling and supervision are internal. A consumer cannot tell
from the facade how data arrives here, and must not be able to.

When a change would let a consumer learn *how* this venue works, that change is wrong.

Concretely, none of these may appear in a return value or an argument: socket handles,
connection pools, WebSockex state, rate-limit buckets, signing keys, retry timers,
supervisor pids.

## What this package owns that Core does not

- **Its transport.** `websockex` is declared here because this venue speaks WebSocket.
  Core ships no transport library at any strength.
- **Its authentication.** Gemini's scheme — a base64 payload signed with HMAC-SHA384 —
  lives here, in `Auth.headers/5`, and the headers it returns are handed straight to
  `Core.HttpClient.request/5`. Core keeps only the generic schemes and is never told
  Gemini's.
- **Its nonce discipline.** Gemini provisions a key in one of two nonce validation modes
  and exposes no way to ask which: time-based (Unix **seconds**, within ±30 s, no
  ordering requirement) or incremental (strictly *increasing*, or the request is rejected
  with `InvalidNonce`). No single value satisfies both, so the mode is the host's to name
  — `nonce_mode:`, defaulting to `:time_based`, the venue's own recommendation. The
  incremental path draws from a node-wide `:atomics` counter, and `Auth.ensure_counter/0`'s
  own doc records the incident behind it: a lazily-initialised counter could be *replaced*
  mid-flight, restarting the sequence and handing two processes the same nonce — the exact
  failure the counter exists to prevent, reintroduced by its own initialisation.
- **Its whole connection strategy** — how many sockets, which channels, how many pairs
  each carries, in what order, at what pace. A consumer never shards anything.

## This package does not maintain an order book, or any other market-data state

A venue package's job is to get the data and maintain the connection — decode a venue
frame into the contract type it names, and pass it on. **It is not the host's book, and
it is not this package's either.** The only state this package holds across calls is
state about what it is doing: which pairs are subscribed (this package runs one socket and
shards nothing — see `Feed`'s moduledoc), and delivery coverage backing `coverage/1` and
`coverage_by_kind/1`. Accumulating market data —
reconstructing a book from a diff stream, holding a running last price, aggregating
candles — is a different job, and `dp_exchange_coinbase` was caught doing it and is
having it removed.

Concretely here: `Socket` subscribes to `@bookTicker`, which carries top-of-book and the
last trade in one message, so there is no L2 diff stream to reconstruct in the first
place — see `Socket`'s own moduledoc for why that endpoint was chosen over one that would
have needed a book. Where a snapshot or diff frame does arrive (`get_order_book/2`'s REST
snapshot, or a future depth-channel subscription), it is decoded into the matching
contract type and forwarded once, per frame — never accumulated into package state. This
line used to claim the opposite — "the L2 book is rebuilt from the venue's own updates
inside this package" — which described no code that has ever shipped here and was
corrected once the discrepancy was found.

## Essential Commands

```bash
mix deps.get
mix compile
mix test                            # tier 1 — in-process fakes, every CI run
mix test --include tier2            # tier 2 — LIVE public endpoints, BY HAND ONLY
mix test --cover                    # threshold 90
mix quality                         # format + credo --strict + dialyzer + sobelow
```

**Never run tier-2 tests on a schedule.** They hit Gemini's live public API, and a
venue that sees a package polling it on a timer will rate-limit or block.

## Documentation is the source, not the host adapter

Every claim this package makes about Gemini comes from **Gemini's own API
documentation**, committed to `docs/reference/gemini/`. Not a GitHub SDK, not a
community write-up, not another client library.

The host's adapter is a *prior reading* of that documentation and is valuable for the
production behaviour it encodes, but on conflict the documentation wins and the
divergence gets recorded. `docs/reference/gemini/extraction-pin.md` records exactly
which host state was read, including that the working tree was dirty.

## Testing Strategy

Four tiers; only the first two ever run unattended:

1. **In-process fakes** — every CI run. The default.
2. **Live public endpoints** — by hand, tagged `:tier2`, excluded from CI.
3. **Authenticated, read-only** — needs credentials this repo must never hold.
4. **Money-moving** — never a test. Answered in production, which is what moves an
   endpoint to `:proven`.

Tests must be `async: true` safe. Any seam a consumer's tests need to vary resolves
through `DpExchange.Core.Config`, per process — a node-wide switch makes this package
unusable in a consumer's async suite.

**The fake satisfies the same conformance suite as the real adapter.** It may be less
capable than the real venue; it must never be *differently* capable. Where it cannot
answer, it errors — it never returns an empty success for something unsupported, and it
never rewrites a value the caller supplied.

## Code Quality Requirements

- Coverage threshold 90
- `mix credo --strict` clean — ALL issues
- `mix dialyzer` clean
- `@moduledoc` and `@doc` on everything public; `@spec` on every public function
- Formatted at `line_length: 98`

### When a moduledoc records an incident

Some code here exists because something failed in production. Where a moduledoc explains
*why* a guard is there, that explanation is the most valuable thing in the file. Carry it
when the code moves or is copied. Do not compress it away.

## Critical Development Principles

### Fail closed; never substitute

The recurring failure in this family is **a nearby substitute where there should be an
error**: a missing granularity becoming the closest one, a missing endpoint becoming
synthetic data, an unknown source counting as evidence. Every value stays plausible and
only the meaning is wrong, which is why it does not surface as a failure.

Return `:error`. Raise. Refuse. Do not guess a value that looks right.

### Declare what you measured, not what you assume

A capability declaration is a claim about a real venue. If it was measured, say when and
against what — `measured_at` and `measured_against` exist for this. If it was read from
documentation and never probed, say that too. An unlabelled number is worse than a
missing one.

### Definition of "Done"

- Tests passing, 0 failures
- `mix quality` clean AND `mix test --cover` green — neither implies the other
- Public functions documented with `@doc` and `@spec`
- CHANGELOG entry where behaviour changed
- The design doc's checklist item marked, with what was found

## Documentation Standards

```
docs/design/            # Active design documents
docs/design/closed/     # Completed, with a retrospective appended
docs/design/ideas/      # Non-blocking discoveries; no date prefix
docs/reference/gemini/# Gemini's own API documentation, committed verbatim
```

Design docs are `YYYY-MM-DD_design-topic-name.md`. Status is one of
`Draft → In Review → Approved → Implementing → Implemented`.

Point at `docs/design/` as a directory. Do not reference individual design documents or
work items from this file.

### Consumer documentation

`usage-rules.md` ships inside the Hex tarball and is what a consuming agent reads. It is
not optional and it is not the README.
