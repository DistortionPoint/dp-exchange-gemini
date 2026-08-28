# Extraction pin — what was read, and in what state

**Host**: `dp_crypto_management`, branch `master`,
`553fa787ad36d7b962d51e90ae965bfa0e801b64`. Read 2026-08-28.

**The working tree was DIRTY at extraction time.** Three of the five Gemini source files
carried uncommitted modifications, so the commit SHA alone does not identify what was
read. The SHA-256 of each file as it was actually read is below. A reader reconstructing
this extraction from `553fa787` alone will get different bytes for the three marked `M`.

| SHA-256 (first 16) | Lines | File | Tree state |
|---|---|---|---|
| `2b33f5ae7f504f67` | 139 | `gemini/feed.ex` | clean |
| `02e2bcaf151edc3f` | 182 | `gemini/l2_book.ex` | **M — uncommitted** |
| `0b7838e40c7fafee` | 1574 | `gemini/provider.ex` | **M — uncommitted** |
| `b9b242ee7a9fd6db` | 86 | `gemini/symbol_format.ex` | clean |
| `53cb00d0ac15796a` | 1212 | `gemini/websocket_provider.ex` | **M — uncommitted** |
| `d476bac2b0a94b90` | 166 | `gemini/feed/coordinator.ex` | clean |

3,359 lines of adapter. The test corpus read alongside it is 5,874 lines across 18 files
(`test/**/*gemini*`), of which one, `gemini_websocket_provider_extra_test.exs`, was also
uncommitted.

Anything that landed in that subtree after this read is not reflected here.

## Why the pin matters more than usual for this venue

The host adapter is a **prior reading of documentation that no longer exists**. Gemini
replaced its developer documentation site between the host's readings (dated 2026-08-05
through 2026-08-07 in the adapter's own comments) and this extraction: `docs.gemini.com`
now 301s to `developer.gemini.com`, and the single-page reference the adapter's moduledoc
cites — `https://docs.gemini.com/rest-api/` — is gone.

That makes the host's measured comments the only surviving record of several venue facts,
and it is why they are carried into this package verbatim rather than re-derived. Where
this package could re-measure, it did, and the results are in the sibling documents.
