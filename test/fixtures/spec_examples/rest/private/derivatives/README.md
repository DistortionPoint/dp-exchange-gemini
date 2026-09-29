# Spec-example fixtures — derivatives, margin, staking, positions

Every fixture here is a byte-faithful transcription of an example already committed to
`docs/reference/gemini/openapi/rest.yaml` (via its JSON-parsed form) — nothing is
"fixed" to make a test pass. Citations are `rest.yaml:<path block>` / `rest.yaml:<example
block>`.

| Fixture | Function | Endpoint | Spec citation | Note |
|---|---|---|---|---|
| `get_notional_balances.json` / `_request.json` | `get_notional_balances/3` | `POST /v1/notionalbalances/{currency}` | rest.yaml:2811 (path), :2915 (response example), request `basic` example | — |
| `list_custody_fees.json` | `list_custody_fees/2` | `POST /v1/custodyaccountfees` | rest.yaml:3385 (path), :3481-3502 (`multipleFees` response example) | vendor names the response example, picked the multi-row one |
| `get_staking_balances.json` | `get_staking_balances/2` | `POST /v1/balances/staking` | rest.yaml:6504 (path), :6559 (response example) | amounts are raw JSON numbers in the vendor example, not strings — `decimal/1` accepts both |
| `get_staking_rewards.json` / `_request.json` | `get_staking_rewards/2` | `POST /v1/staking/rewards` | rest.yaml:6852 (path), :6921 (response example), :6885 (request, `since`/`nonce`/`request` required) | response is nested `{providerId: {currency: {..., ratePeriods: [...]}}}` per rest.yaml:6770-6794 area schema — one `StakingReward` built per rate period |
| `get_staking_history.json` / `_request.json` | `get_staking_history/2` | `POST /v1/staking/history` | rest.yaml:6677 (path), :6770 (response example) | response is `[{providerId, transactions: [...]}]`; `providerId` comes from the parent entry, not the transaction row |
| `stake.json` / `_request.json` | `stake/4` | `POST /v1/staking/stake` | rest.yaml:6589 (path), :6657 (response example) | `amount` is a bare JSON number in the example |
| `unstake.json` / `_request.json` | `unstake/4` | `POST /v1/staking/unstake` | rest.yaml:6970 (path), :7038 (response example) | `requestInitiated` is the venue's `venue_time` field, ISO-8601 |
| `get_positions_bare_array.json` | `get_positions/2` | `POST /v1/positions` | rest.yaml:7518 (path), :7576 (response example — a **bare array**) | **documented contradiction**: the response `schema` at this same location is `{type: object, properties: {openPositions: array}}`, but the vendor's own `example` is a bare array, not wrapped. The fixture is the vendor's example verbatim. |
| `get_positions_open_positions.json` | `get_positions/2` | `POST /v1/positions` | rest.yaml:7518 (path) — **schema-derived**, not a second vendor example | the SAME row data as `get_positions_bare_array.json`, wrapped as `{"openPositions": [...]}`, because that is the shape the response `schema` at this path actually documents (see above). Exercises the other branch `position_rows/1` in `private.ex` explicitly handles. |
| `get_account_margin.json` / `_request.json` | `get_account_margin/2` | `POST /v1/margin` (perpetuals margin account) | rest.yaml:7125 (path), :7186 (response example), :7158 (request schema — `symbol` required) | pass-through map, no decode transform |
| `list_funding_payments.json` | `list_funding_payments/2` | `POST /v1/perpetuals/fundingPayment` | rest.yaml:7201 (path), :7287 (response example) | rows keep the venue's `{eventType, hourlyFundingTransfer: {...}}` wrapper unchanged — `flattened_rows/1` does not unwrap it, only confirms/flattens the outer list |
| `funding_payment_report.json` / `_request.json` | `funding_payment_report/2` | `POST /v1/perpetuals/fundingpaymentreport/records.json` | rest.yaml:7412 (path), :7500 (response example) | request example's `request` field is the path **with its query string attached** (`?fromDate=...&toDate=...&numRows=...`) — see `report_path/2` in `private.ex`; asserted on the captured request path, not just the payload |
| `get_margin_account.json` / `_request.json` | `get_margin_account/2` | `POST /v1/margin/account` (spot margin account) | rest.yaml:2220 (path), :2288 (response example), request requires `symbol` (`rest.yaml`'s requestBody schema for this path lists `required: [request, nonce, symbol]`) | **code bug found here** — see spec_examples_test.exs and the accompanying code fix: `get_margin_account/2` sent an empty params map and never read `opts[:symbol]`, so every real request to this endpoint was missing a field the venue's own schema requires |
| `get_margin_rates.json` | `get_margin_rates/2` | `POST /v1/margin/rates` | rest.yaml:2335 (path), :2396 (response example) | `rates` wrapper unwrapped by `margin_rate_rows/1` |

## Not fixtured (binary/file endpoints — no JSON body to assert)

- `funding_amount_report/3` — `GET/POST /v1/fundingamountreport/records.xlsx` returns raw
  spreadsheet bytes (`{:ok, binary()}`); there is no JSON schema to build a decode
  assertion from, per the function's own moduledoc ("this package ships no spreadsheet
  reader"). Not fixtured — asserting on a `.xlsx` payload's bytes would mean depending on
  a binary vendor never published as a spec example.
- `funding_payment_report_file/2` — same as above, `/v1/perpetuals/fundingpaymentreport/records.xlsx`.
