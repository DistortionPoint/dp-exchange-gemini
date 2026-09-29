# Gemini WebSocket AsyncAPI spec — committed copy

`websocket.yaml` in this directory is a verbatim copy of Gemini's own AsyncAPI document for
the production WebSocket API (`wss://ws.gemini.com`), fetched from
`https://developer.gemini.com/specs/asyncapi/websocket.yaml` on **2026-09-29**.

AsyncAPI **3.0.0**, `info.version` **0.10.7** (this document's own version field — the
production API version, not a version of this copy).

It is committed so line citations in code comments (`websocket.yaml:LINE`) stay pinned to a
specific revision instead of a moving URL — the vendor can and does change this document
without a changelog entry (see `../doc-sources.tsv`'s row for the same URL, and
`../negative-claims.md` for how little Gemini's changelog covers; the sibling REST copy's
own `../openapi/README.md` records the same pattern for that document).

`../doc-sources.tsv` tracks the *URL* (status, redirects, staleness). This file records the
*content pin*: which fetch this checked-in copy is. Re-fetch and replace both this file's
date/version and `../doc-sources.tsv`'s `observed_on` for this URL together — a copy that is
newer than the row that vouches for it is exactly the kind of silent drift this manifest
exists to prevent.

When updating `websocket.yaml`, re-check every `websocket.yaml:LINE` citation in `lib/` and
`test/` still points at the right line, since line numbers shift on any edit upstream.
