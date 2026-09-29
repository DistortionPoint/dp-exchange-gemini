# Spec-example fixtures

Every JSON file under this directory is driven through `DpExchange.Gemini`'s real code by
`test/dp_exchange/gemini/spec_examples_test.exs`. Each is either a byte-faithful
transcription of a documented example from the vendor's own specs (never hand-written,
never adjusted to make an assertion pass), or — where the vendor publishes no example for a
schema this package reads — an instance built strictly from that schema's `required`
properties, always labelled as such rather than left to look like a real example.

Sources:

- `rest/` — `docs/reference/gemini/openapi/rest.yaml`
- `websocket/` — `docs/reference/gemini/asyncapi/websocket.yaml`

Each subdirectory below has its own `README.md` citing the exact spec file and line number
each of its fixtures came from:

- [`rest/public/`](rest/public/README.md) — unauthenticated REST market data
- [`rest/private/orders/`](rest/private/orders/README.md) — balances, orders, trades, volume
- [`rest/private/wallet/`](rest/private/wallet/README.md) — conversions, deposits,
  withdrawals, approved addresses, transactions, payment methods
- [`rest/private/derivatives/`](rest/private/derivatives/README.md) — perpetuals, margin,
  staking, positions
- [`rest/private/clearing/`](rest/private/clearing/README.md) — clearing orders, account
  administration, roles, OAuth revoke, margin order preview
- [`websocket/`](websocket/README.md) — the socket frame shapes `Socket`/`WsDecode` decode

A failure driving one of these through the real code is a real vendor/code mismatch, not a
fixture to adjust — see `spec_examples_test.exs`'s own moduledoc and, where a mismatch was
found and fixed while this suite was built, the comment on the code change itself
(`lib/dp_exchange/gemini/private.ex`'s `status_of/1`, `order_type_of/1` and
`get_margin_account/2`).
