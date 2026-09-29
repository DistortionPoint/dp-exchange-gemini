# Gemini REST OpenAPI spec — committed copy

`rest.yaml` in this directory is a verbatim copy of Gemini's own REST OpenAPI document,
fetched from `https://developer.gemini.com/specs/openapi/rest.yaml` on **2026-09-29**.
It is committed so line citations in code comments (`rest.yaml:LINE`) and in design docs
stay pinned to a specific revision instead of a moving URL — the vendor can and does
change this document without a changelog entry (see `doc-sources.tsv`'s row for the same
URL, and `negative-claims.md` for how little Gemini's changelog covers).

`doc-sources.tsv` tracks the *URL* (status, redirects, staleness). This file records the
*content pin*: which fetch this checked-in copy is. Re-fetch and replace both this file's
date and `doc-sources.tsv`'s `observed_on` together — a copy that is newer than the row
that vouches for it is exactly the kind of silent drift this manifest exists to prevent.

When updating `rest.yaml`, re-check every `rest.yaml:LINE` citation in `lib/` and
`test/` still points at the right line, since line numbers shift on any edit upstream.
