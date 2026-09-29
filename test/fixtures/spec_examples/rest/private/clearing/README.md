# Spec-example fixtures — clearing, account administration, roles, OAuth revoke, margin preview

Every fixture here is a byte-faithful transcription of an example from
`docs/reference/gemini/openapi/rest.yaml` (vendor's own OpenAPI document). Named vendor
examples (`examples.<name>.value`) are unwrapped to just the `value`; nothing in these files
was edited, rounded, or "fixed" to agree with the code — see this repo's spec-examples
conformance philosophy in `test/dp_exchange/gemini/spec_examples_test.exs`.

None of the functions in this group decode their response into a typed `Core.Types` struct —
`DpExchange.Gemini.Private` returns the venue's own JSON body verbatim (`{:ok, body}`) for
every endpoint below, so "conformance" here means: the vendor's own example round-trips
through the real HTTP + signing + decode path unchanged, and the real request this package
sends matches the vendor's own documented request shape.

| Function | Endpoint | Fixture(s) | rest.yaml line(s) |
|---|---|---|---|
| `preview_margin_order/3` | `POST /v1/margin/order/preview` | `preview_margin_order_request_limit_buy.json`, `preview_margin_order_request_market_buy.json`, `preview_margin_order_request_market_sell.json` (request examples, one per pricing branch the code takes: limit→`amount`+`price`, market buy→`totalSpend`, market sell→`amount` only), `preview_margin_order.json` (response) | request examples: 2508; response example: 2548 |
| `create_account/3` | `POST /v1/account/create` | `create_account_request.json`, `create_account.json` | request: 5910; response: 5933 |
| `rename_account/2` | `POST /v1/account/rename` | `rename_account_request.json`, `rename_account.json` | request: 5997; response: 6021 |
| `list_accounts/2` | `POST /v1/account/list` | `list_accounts_request.json`, `list_accounts.json` (bare array — response is NOT wrapped, matches `list_accounts/2`'s `flattened_rows/1`) | request: 6084; response: 6117 |
| `get_roles/2` | `POST /v1/roles` | `get_roles_request.json`, `get_roles_account_level.json`, `get_roles_master_level.json` (two named response variants — account-scoped key has no `counterparty_id`/`isAccountAdmin`, master-scoped key has both) | request: 7097; response examples: 7107 |
| `revoke_access_token/2` | `POST /v1/oauth/revokeByToken` | `revoke_access_token_request.json`, `revoke_access_token.json` | request examples: 6467; response examples: 6485 |
| `create_clearing_order/3` | `POST /v1/clearing/new` | `create_clearing_order_request.json`, `create_clearing_order.json` | request examples: 3865; response example: 3885 |
| `create_broker_clearing_order/3` | `POST /v1/clearing/broker/new` | `create_broker_clearing_order_request.json`, `create_broker_clearing_order.json` | request examples: 4655; response example: 4683 |
| `get_clearing_order/3` | `POST /v1/clearing/status` | `get_clearing_order_request.json`, `get_clearing_order.json` | request examples: 3947; response example: 3962 |
| `cancel_clearing_order/3` | `POST /v1/clearing/cancel` | `cancel_clearing_order_request.json`, `cancel_clearing_order_success.json`, `cancel_clearing_order_failed.json` (two named 200-response variants — a rejected cancel is still HTTP 200 with `result: "failed"`) | request examples: 4024; response examples: 4046 |
| `confirm_clearing_order/4` | `POST /v1/clearing/confirm` | `confirm_clearing_order_request.json`, `confirm_clearing_order_success.json`, `confirm_clearing_order_failed.json` (same pattern — a rejected confirm is HTTP 200 with `result: "error"`) | request examples: 4135; response examples: 4158 |
| `list_clearing_orders/2` | `POST /v1/clearing/list` | `list_clearing_orders_request.json` (the `withFilters` variant, exercising every filter param the code sends), `list_clearing_orders.json` (`successfulList` variant, unwrapped — `{"result": "success", "orders": [...]}`) | request examples: 4260; response examples: 4336 |
| `list_clearing_brokers/2` | `POST /v1/clearing/broker/list` | `list_clearing_brokers_request.json`, `list_clearing_brokers.json` | request examples: 4462; response examples: 4536 |
| `list_clearing_trades/2` | `POST /v1/clearing/trades` | `list_clearing_trades_request.json` (`withTimestamp` variant — exercises `timestamp_nanos`/`limit_per_account`), `list_clearing_trades.json` (`successfulTrades` variant, unwrapped — `{"results": [...]}`) | request examples: 4757; response examples: 4825 |

## Not fixtured, and why

- **`refresh_access_token/3`** (`POST https://exchange.gemini.com/auth/token`) — this call
  goes to a **different host** (`exchange.gemini.com`, not `api.gemini.com`) with a
  form-encoded OAuth token-exchange body, and that path is **not documented in
  `rest.yaml`** at all (`rest.yaml`'s `paths` only covers `api.gemini.com`'s signed REST
  surface). There is no vendor OpenAPI example to conform to, so no fixture was built rather
  than inventing a plausible-looking OAuth token response — the same "fail closed, never
  substitute" rule this family applies everywhere else.

## A spec self-inconsistency found while extracting these, not a code bug

`POST /v1/clearing/status`'s response schema (`ClearingOrder`, referenced at line 3958) names
`clearing_id`, `symbol`, `price`, `amount`, `side`, `status`, `timestamp`, `timestampms` and
`is_confirmed`. Its own worked example two lines later (line 3962) is `{"result": "ok",
"status": "Confirmed"}` — a `result` field the schema never declares, and none of
`clearing_id`/`is_confirmed`/`price`/`amount`/`side` the schema requires nothing of but the
example still omits. This is the same family of vendor self-contradiction already documented
elsewhere in this package (`Rest.get_funding/2`'s `amount`/`fundingAmount` moduledoc note).
It is **not** a code bug here: `get_clearing_order/3` returns the body verbatim
(`{:ok, body}`) with no field extraction, so there is nothing to get wrong — a caller reading
`is_confirmed` per this module's own `@doc` will find it `nil`/absent whenever the venue's
response matches its own example rather than its own schema. Recorded here rather than
silently worked around.
