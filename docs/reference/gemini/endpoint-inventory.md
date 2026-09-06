# Gemini API — endpoint inventory (REST + WebSocket)

**Source**: `developer.gemini.com/sitemap.xml`, enumerated 2026-08-31; each of the 76
`trading/rest-api` pages fetched and its method and path read from the page itself. Eight
are category index pages, so the endpoint count is **68**. **Primary vendor documentation
only.**

## Counts

**Re-checked 2026-09-03.** This section read "18%" until this release, from a capture that
was accurate at the time and stopped being accurate as this package grew. The vendor-side
counts below have not moved; what changed is this package's coverage of them, and that is
recorded through `capabilities/0` rather than re-derived here from a page count.

**Current, from `capabilities/0`, checked 2026-09-06**: 63 of 88 contract callbacks
`:experimental`, 25 `:unsupported`, of which 22 are the venue's own absence — see
`negative-claims.md` — and 3 remain not yet ported (`get_conversion/2`,
`list_portfolios/1`, `list_instruments/1`).

| group | endpoints (vendor) | in this package |
|---|---|---|
| fund management | 16 | most — deposit address, networks, allowlist, withdraw, payment methods, internal transfer; see `usage-rules.md` |
| orders | 12 | most — place, cancel, get, list, cancel-all, active orders |
| market data | 12 | quotes, top of book, candles, trades, order book |
| derivatives | 9 | perpetuals surface — funding, positions, contract stats |
| clearing | 8 | confirm/reject/list |
| staking | 6 | rates, balances, rewards, history, stake, unstake |
| margin | 3 | all three — `get_margin_account/1`, `get_margin_rates/1`, `preview_margin_order/2` |
| instant orders | 2 | both — `quote_conversion/4` and `commit_conversion/2`, plus the wrap endpoint behind `convert/4` |
| **total** | **68** | **63 declared `:experimental`, per `capabilities/0`** |

Plus `rest-api/common`: 5 admin + 2 package-side OAuth, all implemented — see
`usage-rules.md` for the refresh and revoke pair.

**Best-covered crypto venue in the family**, and no longer close: 63 of the contract's 88
callbacks against Coinbase's 49 and Webull's 47 (all three counted from their own
`capabilities/0` on 2026-09-06).

## Endpoints

`✓` marks what this package implements today.

```
  POST   ?                                          clearing
  POST   /v1/clearing/cancel                        clearing_cancel-clearing-order
  POST   /v1/clearing/confirm                       clearing_confirm-clearing-order
  POST   /v1/clearing/broker/new                    clearing_create-new-broker-order
  POST   /v1/clearing/new                           clearing_create-new-clearing-order
  POST   /v1/clearing/status                        clearing_get-clearing-order
  POST   /v1/clearing/broker/list                   clearing_list-clearing-brokers
  POST   /v1/clearing/list                          clearing_list-clearing-orders
  POST   /v1/clearing/trades                        clearing_list-clearing-trades
  ?      ?                                          derivatives
  POST   /v1/margin                                 derivatives_get-account-margin
  GET    /v1/fundingamountreport/records.xlsx       derivatives_get-funding-amount-report-file
  GET    /v1/fundingamount/BTCGUSDPERP              derivatives_get-funding-amount
  GET    /v1/perpetuals/fundingpaymentreport/records.xlsx derivatives_get-funding-payment-report-file
  POST   /v1/perpetuals/fundingpaymentreport/records.json derivatives_get-funding-payment-report-json
  GET    /v1/nextfundingtimestamp/BTCGUSDPERP       derivatives_get-next-funding-timestamp
  POST   /v1/positions                              derivatives_get-open-positions
  GET    /v1/riskstats/BTCGUSDPERP                  derivatives_get-risk-stats
  POST   /v1/perpetuals/fundingPayment              derivatives_list-funding-payments
  ?      ?                                          fund-management
  POST   /v1/payments/addbank/cad                   fund-management_add-bank-cad
  POST   /v1/payments/addbank                       fund-management_add-bank
  POST   /v1/approvedAddresses/ethereum/request     fund-management_create-new-approved-address
  POST   /v1/deposit/bitcoin/newAddress             fund-management_create-new-deposit-address
✓ POST   /v1/balances                               fund-management_get-available-balances
  POST   /v2/withdraw/ethereum/eth/feeEstimate      fund-management_get-gas-fee-estimation
  POST   /v1/notionalbalances/usd                   fund-management_get-notional-balances
  POST   /v1/transactions                           fund-management_get-transaction-history
  POST   /v1/approvedAddresses/account/ethereum     fund-management_list-approved-addresses
  POST   /v1/custodyaccountfees                     fund-management_list-custody-fee-transfers
  POST   /v1/addresses/bitcoin                      fund-management_list-deposit-addresses
  POST   /v2/transfers                              fund-management_list-past-transfers
  POST   /v1/payments/methods                       fund-management_list-payment-methods
  POST   /v1/approvedAddresses/ethereum/remove      fund-management_remove-approved-address
  POST   /v1/account/transfer/btc                   fund-management_transfer-between-accounts
  POST   /v2/withdraw/ethereum/eth                  fund-management_withdraw-crypto-funds
  ?      ?                                          instant-orders
  POST   /v1/instant/execute                        instant-orders_execute-instant-order
  POST   /v1/instant/quote                          instant-orders_get-instant-quote
  ?      ?                                          margin
  POST   /v1/margin/account                         margin_get-margin-account-summary
  POST   /v1/margin/rates                           margin_get-margin-interest-rates
  POST   /v1/margin/order/preview                   margin_preview-margin-order
  GET    ?                                          market-data
  GET    /v2/fxrate/AUDUSD/1594651859000            market-data_fx-rate
  GET    /v2/networks/                              market-data_get-assets-for-network
  GET    /v1/book/BTCUSD                            market-data_get-current-order-book
  GET    /v2/network/USDC                           market-data_get-network
  GET    /v1/wrap/:symbol                           market-data_get-symbol-details
  GET    /v1/pubticker/BTCUSD                       market-data_get-ticker
  GET    /v2/candles/BTCUSD/15m                     market-data_list-candles
  GET    /v2/derivatives/candles/BTCGUSDPERP/1m     market-data_list-derivative-candles
  GET    /v1/feepromos                              market-data_list-fee-promos
✓ GET    /v1/pricefeed                              market-data_list-prices
✓ GET    /v1/symbols                                market-data_list-symbols
  POST   /v1/trades/BTCUSD                          market-data_list-trades
  POST   ?                                          orders
  POST   /v1/order/cancel/all                       orders_cancel-all-active-orders
  POST   /v1/order/cancel/session                   orders_cancel-all-session-orders
✓ POST   /v1/order/cancel                           orders_cancel-order
✓ POST   /v1/order/new                              orders_create-new-order
✓ POST   /v1/notionalvolume                         orders_get-notional-trading-volume
✓ POST   /v1/order/status                           orders_get-order-status
  POST   /v1/tradevolume                            orders_get-trading-volume
✓ POST   /v1/heartbeat                              orders_heartbeat
✓ POST   /v1/orders                                 orders_list-active-orders
  POST   /v1/orders/history                         orders_list-past-orders
✓ POST   /v1/mytrades                               orders_list-past-trades
  POST   /v1/wrap/GUSDUSD                           orders_wrap-order
  POST   ?                                          staking
  POST   /v1/balances/staking                       staking_list-staking-balances
  POST   /v1/staking/history                        staking_list-staking-event-history
  GET    /v1/staking/rates                          staking_list-staking-rates
  POST   /v1/staking/rewards                        staking_list-staking-rewards
  POST   /v1/staking/stake                          staking_stake-crypto-funds
  POST   /v1/staking/unstake                        staking_unstake-crypto-funds
```

## Notes

**The OAuth token lifecycle is in scope, and it is not in the 68.** Gemini documents it
under `rest-api/common/oauth`, outside `trading/rest-api`:

| endpoint | side |
|---|---|
| `authorization-request` | **host** — consent redirect |
| `authorization-token-request` | **host** — the initial code exchange |
| **`refresh-access-token`** | **package** — credential *use*, the same category as Schwab's `Auth.refresh/2` |
| **`revoke-access-token`** | **package** — same |

Only the consent leg is a pre-approved skip. Sweeping the whole of "OAuth" into one would
leave this venue unable to keep a session alive while Schwab does it in-package.


**`rest-api/common` — read 2026-08-31, paths from the vendor's own pages.** The tree holds
13 pages: `admin` (6 pages, **5 endpoints**), `oauth` (4), and 3 index pages.

| page | method | path | side |
|---|---|---|---|
| `admin/get-account-detail` | POST | `/v1/account` | — **this package already calls it** |
| `admin/create-new-account` | POST | `/v1/account/create` | |
| `admin/rename-account` | POST | `/v1/account/rename` | |
| `admin/list-accounts-in-group` | POST | `/v1/account/list` | |
| `admin/roles-endpoint` | POST | `/v1/roles` | |
| `admin/subaccounts` | — | — | **guide page, not an endpoint** |
| `oauth/refresh-access-token` | POST | `exchange.gemini.com/auth/token` | **package** |
| `oauth/revoke-access-token` | POST | `api.gemini.com/v1/oauth/revokeByToken` | **package** |
| `oauth/authorization-request` | GET | `exchange.gemini.com/auth` | host — consent |
| `oauth/authorization-token-request` | POST | `exchange.gemini.com/auth/token` | host — code exchange |

**`refresh-access-token` and `authorization-token-request` are the same URL**, separated
only by `grant_type`. The §6.0 split is therefore drawn at credential *use*, not at the
endpoint — the path alone cannot tell you which side owns a call.

Gemini's private API is uniformly `POST` with a signed `{request, nonce}` payload; each
page states its own path in that `request` field, which is where these were read.

**In-scope total: 68 + 5 admin + 2 oauth = 75.**

## Gemini publishes machine-readable specifications — use those, not this file's hand counts

**Found 2026-08-31 at `developer.gemini.com/api-specifications`.** The vendor publishes
OpenAPI and AsyncAPI documents and describes them as "machine-readable source
specifications … for giving agents a stable contract to inspect". **They supersede every
count taken by reading pages**, including the ones this file previously carried.

```
/specs/index.json                          the catalogue
/specs/openapi/rest.yaml                   REST            (alias /api/openapi.yaml)
/specs/openapi/prediction-markets.yaml     prediction markets
/specs/asyncapi/websocket.yaml             WebSocket
```

| surface | operations | previously recorded here |
|---|---|---|
| REST | **75** | 68 + 7 = 75 — **agrees** |
| prediction markets | **31** | 38 *pages*, never counted as operations |
| WebSocket channels | **22** | **11** — the Stream Matrix was not the whole surface |
| **total** | **128** | |

Every operation is listed in `operations-from-specs.txt` beside this file.

### The REST spec settles two things this file had been unsure about

**`/v1/account` and `/v1/roles` are both in the spec.** The `rest-api/common/admin`
endpoints are part of the REST API proper, not a separate tree — which independently
confirms the correction below, that `/v1/account` was never undocumented.

**`/v2/transfers` is in the spec and `/v1/transfers` is not.** The path this package calls
is absent from the vendor's own machine-readable contract, and its replacement is present.
That is the strongest form the D6 finding could take: not "the docs moved" but "the
contract does not contain it".

### The WebSocket surface is 22 channels, not 11

The `trading/websocket/streams` page presents a **Stream Matrix** that reads as the whole
socket surface. It is not. The AsyncAPI document carries **22 channels**, and ten never
appear in that matrix:

- `requestForQuote`, `requestForQuoteAccount`, `requestForQuoteSession` — an entire RFQ
  surface, absent from the matrix
- `connection` — the session channel itself
- `balancesAccountSnapshot`, `positionsAccountSnapshot` — the periodic snapshots, which the
  matrix folds into their real-time siblings as an `@1s` suffix
- `depthFast`, `depth5Fast`, `depth10Fast`, `depth20Fast` — the low-latency depth variants

**A rendered summary table is a slice of a specification, and this is the fourth time in
this family that a slice was mistaken for the whole.** The AsyncAPI document is the source;
the Stream Matrix is a reading aid.
## Re-capturing

**Fetch the specifications. Do not re-read the pages.**

```
curl -s https://developer.gemini.com/specs/index.json
curl -s https://developer.gemini.com/specs/openapi/rest.yaml
curl -s https://developer.gemini.com/specs/openapi/prediction-markets.yaml
curl -s https://developer.gemini.com/specs/asyncapi/websocket.yaml
```

The YAML uses **CRLF** line endings. Strip carriage returns before parsing or every path
match silently fails — that cost a wrong count once already.

### The sitemap route, kept for the page-level view

```
curl -s https://developer.gemini.com/sitemap.xml | grep -oE '<loc>[^<]+' | sed 's|<loc>||' \
  | grep '/trading/rest-api/'
```

Each page carries its own method and path; there is no shared navigation to shortcut with,
so all 76 must be fetched.
