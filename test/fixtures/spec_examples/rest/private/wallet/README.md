# Spec-example fixtures — wallet / conversion / custody group

Every file here is a byte-faithful transcription of a `value`/`example` object from
Gemini's own OpenAPI document, `docs/reference/gemini/openapi/rest.yaml`. Nothing is
"fixed" to agree with this package's code — where the code and the vendor's own example
disagree, that is reported as a bug against `lib/`, not corrected here.

| Fixture | Function (`DpExchange.Gemini.Private`) | Endpoint | `rest.yaml` example | Line |
|---|---|---|---|---|
| `quote_conversion_buy_request.json` | `quote_conversion/4` (buy) | `POST /v1/instant/quote` | `requestBody.examples.buyQuote` | 4874 |
| `quote_conversion_sell_request.json` | `quote_conversion/4` (sell) | `POST /v1/instant/quote` | `requestBody.examples.sellQuote` | 4874 |
| `quote_conversion_buy_response.json` | `quote_conversion/4` (buy) | `POST /v1/instant/quote` | `responses.200.examples.btcBuyResponse` | 4874 |
| `quote_conversion_sell_response.json` | `quote_conversion/4` (sell) | `POST /v1/instant/quote` | `responses.200.examples.ethSellResponse` | 4874 |
| `commit_conversion_buy_request.json` | `commit_conversion/2` | `POST /v1/instant/execute` | `requestBody.examples.executeBuyOrder` | 5011 |
| `commit_conversion_response.json` | `commit_conversion/2` | `POST /v1/instant/execute` | `responses.200.examples.btcusdBuy` | 5011 |
| `convert_request.json` | `convert/4` | `POST /v1/wrap/{symbol}` | `requestBody.example` | 2676 |
| `convert_response.json` | `convert/4` | `POST /v1/wrap/{symbol}` | `responses.200.example` | 2676 |
| `get_trade_volume_request.json` | `get_trade_volume/2` | `POST /v1/tradevolume` | `requestBody.examples.basic` | 1776 |
| `get_trade_volume_response.json` | `get_trade_volume/2` | `POST /v1/tradevolume` | `responses.200.examples.singleSymbol` (one symbol, nested list per the venue's own shape) | 1776 |
| `list_networks_asset_response.json` | `list_networks/2` (asset direction) | `GET /v2/network/{token}` | `responses.200.examples.single-network` | 185 |
| `list_networks_network_response.json` | `list_networks/2` (network direction) | `GET /v2/networks/{network}/assets` | `responses.200.examples.multi-asset-network` | 105 |
| `get_fx_rate_response.json` | `get_fx_rate/3` | `GET /v2/fxrate/{symbol}/{timestamp}` | `responses.200.example` | 7819 |
| `get_deposit_address_request.json` | `get_deposit_address/4` | `POST /v1/deposit/{network}/newAddress` | `requestBody.examples.basicBitcoin` | 3072 |
| `get_deposit_address_response.json` | `get_deposit_address/4` | `POST /v1/deposit/{network}/newAddress` | `responses.200.examples.bitcoinAddress` | 3072 |
| `list_approved_addresses_request.json` | `list_approved_addresses/2` | `POST /v1/approvedAddresses/account/{network}` | `requestBody.example` | 5599 |
| `list_approved_addresses_response.json` | `list_approved_addresses/2` | `POST /v1/approvedAddresses/account/{network}` | `responses.200.example` (4-row array, mixed `status`/`scope`) | 5599 |
| `estimate_withdrawal_fee_request.json` | `estimate_withdrawal_fee/5` | `POST /v2/withdraw/{network}/{ticker}/feeEstimate` | `requestBody.examples.ethOnEthereum` | 3519 |
| `estimate_withdrawal_fee_response.json` | `estimate_withdrawal_fee/5` | `POST /v2/withdraw/{network}/{ticker}/feeEstimate` | `responses.200.examples.ethResponse` (note: `fee` is a JSON number, not a string, here) | 3519 |
| `withdraw_request.json` | `withdraw/6` | `POST /v2/withdraw/{network}/{ticker}` | `requestBody.examples.ethWithdrawal` (carries `clientTransferId`) | 3645 |
| `withdraw_response.json` | `withdraw/6` | `POST /v2/withdraw/{network}/{ticker}` | `responses.200.examples.ethWithdrawalResponse` | 3645 |
| `list_payment_methods_request.json` | `list_payment_methods/2` | `POST /v1/payments/methods` | `requestBody.example` | 5392 |
| `list_payment_methods_response.json` | `list_payment_methods/2` | `POST /v1/payments/methods` | `responses.200.example` (`{balances: [...], banks: [...]}`, no `"methods"` key) | 5392 |
| `add_payment_method_us_request.json` | `add_payment_method/3` (`country: "US"`, default) | `POST /v1/payments/addbank` | `requestBody.example` | 5199 |
| `add_payment_method_us_response.json` | `add_payment_method/3` (US) | `POST /v1/payments/addbank` | `responses.200.example` | 5199 |
| `add_payment_method_ca_request.json` | `add_payment_method/3` (`country: "CA"`) | `POST /v1/payments/addbank/cad` | `requestBody.example` | 5289 |
| `add_payment_method_ca_response.json` | `add_payment_method/3` (CA) | `POST /v1/payments/addbank/cad` | `responses.200.example` | 5289 |
| `transfer_internal_request.json` | `transfer_internal/5` | `POST /v1/account/transfer/{currency}` | `requestBody.examples.withClientId` | 6149 |
| `transfer_internal_response.json` | `transfer_internal/5` | `POST /v1/account/transfer/{currency}` | `responses.200.example` | 6149 |
| `request_approved_address_request.json` | `request_approved_address/5` | `POST /v1/approvedAddresses/{network}/request` | `requestBody.example` | 5702 |
| `request_approved_address_response.json` | `request_approved_address/5` | `POST /v1/approvedAddresses/{network}/request` | `responses.200.example` | 5702 |
| `remove_approved_address_request.json` | `remove_approved_address/4` | `POST /v1/approvedAddresses/{network}/remove` | `requestBody.example` | 5790 |
| `remove_approved_address_response.json` | `remove_approved_address/4` | `POST /v1/approvedAddresses/{network}/remove` | `responses.200.example` | 5790 |
| `get_transactions_request.json` | `get_transactions/2` | `POST /v1/transactions` | `requestBody.example` | 6291 |
| `get_transactions_response.json` | `get_transactions/2` | `POST /v1/transactions` | `responses.200.examples.tradeResponse` (`{results: [...], continuationToken: ...}`) | 6291 |

## Notes on fidelity, not correction

- `get_transactions_response.json` carries a real `continuationToken`. The test drives it
  through `get_transactions/2` with `opts[:limit]` set (any value), which takes the
  single-page branch (`transactions_page/3` directly) rather than `walk_transactions/5`,
  so the fixture's own token does not need a second stubbed page to terminate. This is a
  test-harness choice, not a fixture edit — `get_transactions_response.json` is untouched.
- `list_networks_asset_response.json` and `list_networks_network_response.json` are both
  vendor examples of a **single object**, not an array — `list_networks/2` wraps either
  with `List.wrap/1`, so the decoded result is `[that object]`.
- `estimate_withdrawal_fee_response.json`'s `fee` field is a bare JSON number (`0.001`),
  not a string like every other decimal-bearing example in this group. Sent through
  unmodified; the test asserts `Decimal.equal?/2` against `Decimal.new("0.001")` to prove
  the code's `decimal/1` helper accepts a JSON number, not just a numeric string.
