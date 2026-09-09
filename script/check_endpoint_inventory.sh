#!/usr/bin/env bash
# Diffs this venue's committed endpoint inventory against the vendor's CURRENT published
# specifications, and reports anything that appeared or vanished.
#
# Why this exists, and why it is the one venue that gets it:
#
# `dp_exchange_core`'s vendor-change design doc audited what would have caught each way
# five vendors' documentation turned out to be wrong. A CHANGELOG diff caught nothing
# across the whole sample. An INDEX diff was the only mechanism that ever fired — and the
# instance it fired on was this venue, which removed the WebSocket market-data API this
# family's price feed ran on and announced it by nothing except its absence from the docs.
#
# `script/check_doc_sources.sh` is the cheap half of that idea: it watches whether the
# pages we cite still resolve. This is the deeper half, and it is only possible where a
# vendor publishes MACHINE-READABLE specifications. Gemini does — OpenAPI for REST and for
# prediction markets, AsyncAPI for the socket — so "what does this venue serve" is a list
# that can be compared rather than prose that has to be re-read.
#
# **This is a spec diff, not a content diff.** The distinction is the whole reason it is
# not noise: an operation list is structured, stable, and every entry means something. The
# rendered documentation pages around it carry build hashes and rotating banners and would
# be red every week for reasons nobody cares about, which is why `check_doc_sources.sh`
# deliberately does not diff content.
#
# It earned itself on its first run: `settlementsAccount`, a WebSocket channel this venue
# published on 2026-08-31, is absent from the current AsyncAPI — removed with no changelog
# entry, exactly the pattern above.
#
# A difference is a NOTICE, not a build failure. Something appearing may mean an
# `:unsupported` declaration in `capabilities/0` is now false; something vanishing may mean
# a claim this package makes has gone stale. Both need a person, and neither should block a
# merge — the result depends entirely on a third party's web server.
#
# It touches documentation and specification URLs only. Never a venue API: tier-2 tests hit
# live endpoints and must never run on a schedule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMITTED="$ROOT/docs/reference/gemini/operations-from-specs.txt"
WORK="$ROOT/tmp/inventory_check"

REST_SPEC="https://developer.gemini.com/specs/openapi/rest.yaml"
PREDICTION_SPEC="https://developer.gemini.com/specs/openapi/prediction-markets.yaml"
WEBSOCKET_SPEC="https://developer.gemini.com/specs/asyncapi/websocket.yaml"

rm -rf "$WORK"
mkdir -p "$WORK"

# `tr -d '\r'` before anything else: these specs are served with CRLF line endings, and
# without this every extracted name keeps a trailing carriage return, so `sort`/`comm`
# report a total mismatch — every entry "added" and every entry "removed" at once. That is
# a checker that cries wolf, which is worse than no checker.
fetch() {
  curl -sL --max-time 40 "$1" | tr -d '\r'
}

# OpenAPI: a path is a two-space-indented key under `paths:`, and its verbs are the
# four-space-indented keys under it.
openapi_operations() {
  awk '
    /^  \/[^ ]*:[[:space:]]*$/ { path=$1; sub(/:$/,"",path); next }
    /^    (get|post|put|delete|patch):[[:space:]]*$/ { v=$1; sub(/:$/,"",v); print toupper(v) " " path }
  ' | sort -u
}

# AsyncAPI 3.0: channel names are the two-space-indented keys between `channels:` and the
# next top-level key. Deliberately NOT every two-space key in the file — `operations:`
# further down has its own, and counting those reported 47 channels where there are 21.
asyncapi_channels() {
  awk '
    /^channels:[[:space:]]*$/ { inside=1; next }
    /^[a-zA-Z]/ { inside=0 }
    inside && /^  [a-zA-Z]/ { c=$1; sub(/:$/,"",c); print c }
  ' | sort -u
}

section() {
  awk -v want="$1" '
    $0 ~ ("^## " want) { f=1; next }
    /^## / { f=0 }
    f && NF && $0 !~ /^#/ { sub(/^ +/, "", $0); print }
  ' "$COMMITTED" | sort -u
}

failures=0

compare() {
  local label="$1" committed="$2" current="$3"
  local added removed

  added=$(comm -13 "$committed" "$current")
  removed=$(comm -23 "$committed" "$current")

  if [ -z "$added" ] && [ -z "$removed" ]; then
    echo "  OK       $label — $(wc -l < "$current" | tr -d ' ') entries, unchanged"
    return
  fi

  echo "  CHANGED  $label"
  if [ -n "$added" ]; then
    echo "    APPEARED since the committed inventory was taken:"
    printf '      %s\n' $added
    echo "      -> a capabilities/0 :unsupported declaration may now be FALSE."
  fi
  if [ -n "$removed" ]; then
    echo "    VANISHED since the committed inventory was taken:"
    printf '      %s\n' $removed
    echo "      -> a claim this package makes may now rest on nothing. This venue removes"
    echo "         things with no changelog entry; absence IS the announcement."
  fi
  failures=$((failures + 1))
}

echo "== gemini endpoint inventory vs. the vendor's current specifications"

fetch "$REST_SPEC" | openapi_operations > "$WORK/rest.now"
fetch "$PREDICTION_SPEC" | openapi_operations > "$WORK/prediction.now"
fetch "$WEBSOCKET_SPEC" | asyncapi_channels > "$WORK/websocket.now"

for f in rest prediction websocket; do
  if [ ! -s "$WORK/$f.now" ]; then
    echo "  UNREACHABLE  $f specification returned nothing — not treating that as a change."
    echo "               A vendor being down is not a vendor changing something."
    exit 0
  fi
done

section "REST" > "$WORK/rest.committed"
section "Prediction markets" > "$WORK/prediction.committed"
section "WebSocket channels" > "$WORK/websocket.committed"

compare "REST operations" "$WORK/rest.committed" "$WORK/rest.now"
compare "Prediction-market operations" "$WORK/prediction.committed" "$WORK/prediction.now"
compare "WebSocket channels" "$WORK/websocket.committed" "$WORK/websocket.now"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures section(s) differ from the committed inventory."
  echo
  echo "This is a NOTICE, not a build failure. Read the vendor's specification, decide what"
  echo "the change means for what this package CLAIMS, fix the claim if it is now wrong, and"
  echo "only then update docs/reference/gemini/operations-from-specs.txt with today's date."
  echo "Updating the inventory first turns this check into a rubber stamp."
  exit 1
fi

echo "The committed inventory matches the vendor's current specifications."
