# Spec-example fixtures — balances, orders, trades, volume

Every fixture here is the vendor's own documented example, copied byte-for-byte from
`docs/reference/gemini/openapi/rest.yaml` (verified against the same content pre-parsed to
JSON). Nothing is renamed, rounded, or invented — where a fixture is NOT a real vendor
example, that is called out explicitly below.

| Fixture | Endpoint | `rest.yaml` example | Vendor's own label |
|---|---|---|---|
| `get_balances.json` | `POST /v1/balances` | `:1925` block, `examples.multipleBalances` (~`:1997`) | "Multiple Balances" |
| `get_balances_request.json` | `POST /v1/balances` | `:1925` block, request `example` (~`:1948`) | (unnamed single example) |
| `get_accounts.json` | `POST /v1/account` | `:5470` block, response `example` | (unnamed single example) |
| `get_accounts_request.json` | `POST /v1/account` | `:5470` block, request `example` | (unnamed single example) |
| `get_fees.json` | `POST /v1/notionalvolume` | `:2070` block, `examples.withFeeTier` | "With Fee Tier" |
| `get_fees_request.json` | `POST /v1/notionalvolume` | `:2070` block, `examples.withSymbol` | "With Symbol Parameter" — this is the request shape `Private.get_fees/2` builds when `opts[:symbol]` is given; see that function's own moduledoc on why `/v1/feepromos`' capability moved here. |
| `get_transfers.json` | `POST /v2/transfers` | `:3196` block, `examples.multiNetworkTransfers` | "Multi-Network Transfers" |
| `get_transfers_request.json` | `POST /v2/transfers` | `:3196` block, `examples.withFilters` | "With Multiple Filters" |
| `place_order.json` | `POST /v1/order/new` | `:686` block, response `examples.limitOrder` | "Limit Order" |
| `place_order_request.json` | `POST /v1/order/new` | `:686` block, request `examples.limitOrder` | "Limit Order" |
| `place_order_stop_limit.json` | `POST /v1/order/new` | `:686` block, response `examples.stopLimitOrder` | "Stop-Limit Order" — exercises `order_type_of/1`'s `"exchange stop limit"` clause and the `stop_price` field. |
| `cancel_order.json` | `POST /v1/order/cancel` | `:874` block, response `examples.cancelledOrder` | "Cancelled Order" — see the code-fix note below: this is a cancelled order that DID partially fill. |
| `cancel_order_request.json` | `POST /v1/order/cancel` | `:874` block, request `examples.cancelOrder` | "Cancel Order Example" |
| `get_order.json` | `POST /v1/order/status` | `:1142` block, response `examples.limitBuyResponse` | "Limit Buy Response" |
| `get_order_request.json` | `POST /v1/order/status` | `:1142` block, request `examples.orderStatusRequest` | (unnamed) |
| `get_orders.json` | `POST /v1/orders` | `:1274` block, response `examples.multipleOrders` | "Multiple Active Orders" |
| `get_orders_request.json` | `POST /v1/orders` | `:1274` block, request `examples.basic` | "Basic Request" |
| `get_orders_history.json` | `POST /v1/orders/history` | `:1418` block, response `examples.completedOrder` | "Completed Order" |
| `get_orders_history_request.json` | `POST /v1/orders/history` | `:1418` block, request `examples.withSymbolAndTimestamp` | "With Symbol and Timestamp" |
| `cancel_all_orders_account.json` | `POST /v1/order/cancel/all` | `:987` block, response `example` | (unnamed) |
| `cancel_all_orders_account_request.json` | `POST /v1/order/cancel/all` | `:987` block, request `examples.cancelAllOrders` | "Cancel All Orders" |
| `cancel_all_orders_session.json` | `POST /v1/order/cancel/session` | `:1075` block, response `example` | (unnamed) |
| `cancel_all_orders_session_request.json` | `POST /v1/order/cancel/session` | `:1075` block, request `examples.cancelAllSessionOrders` | "Cancel All Session Orders" |
| `get_trade_history.json` | `POST /v1/mytrades` | `:1608` block, response `examples.multipleTrades` | "Multiple Trades" — note the vendor's own `"type"` value is `"Buy"` (capitalised); `Private.required_side/1` downcases before matching. |
| `get_trade_history_request.json` | `POST /v1/mytrades` | `:1608` block, request `examples.withLimitAndTimestamp` | "With Limit and Timestamp" |
| `test_connection.json` | `POST /v1/heartbeat` | `:2619` block, response `example` | (unnamed) |
| `test_connection_request.json` | `POST /v1/heartbeat` | `:2619` block, request `example` | (unnamed) |

All line numbers above are the start of that path's block in `rest.yaml`; each block is
short enough (< 150 lines) that the named `examples` key or bare `example` key is the only
one of its kind inside it.

## A real bug found via `cancel_order.json`, and fixed

The vendor's own `cancelledOrder` example for `POST /v1/order/cancel` is `original_amount:
"5"`, `executed_amount: "3.7610296649"`, `is_cancelled: true` — a cancel that landed after a
**partial** fill (75.2%), not a full one. `Private.status_of/1`
(`lib/dp_exchange/gemini/private.ex`) used to map ANY `is_cancelled: true` with a positive
`executed_amount` to `:filled`, with no distinction from a full fill. Driven through the
real code, this vendor-documented cancel decoded as `%Order{status: :filled, quantity:
~M[5], filled_quantity: ~M[3.7610296649]}` — a status that said "filled" beside a quantity
that said it was not. `test/dp_exchange/gemini/private_test.exs:301`'s existing test for
this branch ("a cancelled order that did fill is `:filled`, not `:cancelled`") uses a
fixture where `executed_amount == original_amount` (fully filled), so it never exercised
the partial case the vendor's own example actually documents — a fixture written to agree
with the code's binary framing rather than with the vendor.

**Fixed**: `status_of/1` now has a third branch — `Core.Types.Order` already carries
`:partially_filled` in its status enum, and `status_of/1`'s sibling clause (a still-`is_live`
order) already reached for it under the identical condition. A cancelled order is now
`:cancelled` (nothing filled), `:partially_filled` (some but not all filled), or `:filled`
(the full `original_amount` filled) — see `status_of/1` and `fully_filled?/2`'s own
comments in `lib/dp_exchange/gemini/private.ex`, and the corresponding test in
`spec_examples_test.exs`, which now asserts `:partially_filled` against this exact fixture.
