# REST spec-example fixtures — public market data

Every fixture in this directory is a byte-faithful transcription of the vendor's own
documented example, taken from `docs/reference/gemini/openapi/rest.yaml`. Nothing here is
"fixed" to agree with the code — a fixture that disagrees with the code is a bug report,
not a fixture bug. Where a fixture required a judgment call (the schema says one shape and
the vendor's own example is written as another), that is called out below rather than
silently reconciled.

| Fixture | Endpoint | `rest.yaml` line(s) | Note |
|---|---|---|---|
| `pubticker.json` | `GET /v1/pubticker/{symbol}` | 310 | vendor's own 200 `example` |
| `book.json` | `GET /v1/book/{symbol}` | 372 | vendor's own 200 `example` |
| `trades.json` | `GET /v1/trades/{symbol}` | 471 | **Wrapped.** The schema is `type: array` of `Trade` (rest.yaml:466-469), but the vendor's own `example` at line 471 is written as a single bare object, not an array — a spec-authoring inconsistency in the vendor's own document. Transcribed faithfully as a one-element array (`[<their object>]`) since that is what the declared response shape requires; the object's field values are untouched. |
| `pricefeed.json` | `GET /v1/pricefeed` | 502 | vendor's own 200 `example`, 4 rows |
| `symbols.json` | `GET /v1/symbols` | 37 | vendor's own 200 `example`, full 218-symbol list |
| `symbols_details_spot.json` | `GET /v1/symbols/details/{symbol}` | 64 (`examples.spot.value`) | named example `spot` |
| `symbols_details_perpetual.json` | `GET /v1/symbols/details/{symbol}` | 64 (`examples.perpetual.value`) | named example `perpetual` |
| `staking_rates.json` | `GET /v1/staking/rates` | 6823 | vendor's own 200 `example` — outer key is a provider UUID, inner keys are asset symbols (see `Rest.get_staking_rates/1`'s moduledoc for the historical bug this shape exists to catch) |
| `fundingamount.json` | `GET /v1/fundingamount/{symbol}` | 557 | vendor's own 200 `example`. Uses `fundingAmount`, not `amount` — the same schema/example field-name contradiction `Rest.get_funding/2`'s moduledoc documents (schema at rest.yaml:9420 names `amount`; this example names `fundingAmount`) |
| `nextfundingtimestamp.json` | `GET /v1/nextfundingtimestamp/{symbol}` | 599 | vendor's own 200 `example` — a bare integer, not an object |
| `riskstats.json` | `GET /v1/riskstats/{symbol}` | 7624 | vendor's own 200 `example` |
| `candles.json` | `GET /v2/candles/{symbol}/{time_frame}` | 7735 | vendor's own 200 `example`, 2 bars |
| `derivatives_candles.json` | `GET /v2/derivatives/candles/{symbol}/{time_frame}` | 7792 | vendor's own 200 `example`, 2 bars |

`GET /v1/feepromos` (`Rest.list_fee_promos/1`) has **no fixture here**: it is absent from
the vendor's current OpenAPI document entirely (see `Rest.list_fee_promos/1`'s own
moduledoc — found gone by `script/check_endpoint_inventory.sh` on 2026-09-21). There is no
vendor example left to be faithful to, so no fixture is invented here rather than building
one from memory of a since-removed schema.
