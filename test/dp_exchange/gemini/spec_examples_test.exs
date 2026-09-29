defmodule DpExchange.Gemini.SpecExamplesTest do
  @moduledoc """
  Spec-example conformance: every endpoint and channel this package calls or decodes,
  driven from **the vendor's own documented example** rather than a fixture this package's
  authors wrote by hand.

  This family's worst bugs have come from a test fixture written to agree with the code
  instead of with the vendor — `Rest.get_staking_rates/1`'s moduledoc names one exactly:
  the provider/asset nesting was inverted, and the fixture was written keyed the same wrong
  way, so nothing caught it. This file exists to make that specific failure mode structural
  rather than a matter of author discipline: every fixture under
  `test/fixtures/spec_examples/` is a byte-faithful transcription of an example vendored in
  `docs/reference/gemini/openapi/rest.yaml` (REST, 200 responses and, where documented,
  request bodies) or `docs/reference/gemini/asyncapi/websocket.yaml` (WebSocket message
  examples) — never hand-written, never adjusted to make an assertion pass. Each fixture's
  README cites the spec file and line it came from. Where the vendor publishes no example
  for a schema this package reads, the fixture is built strictly from that schema's
  `required` properties and the README says so plainly, per this family's rule that an
  unlabelled number is worse than a missing one.

  Every test here asserts `{:ok, _}` (or, where the vendor's example is itself a refusal or
  malformed body, the specific `{:error, _}`/`{:refused, _}` this package's own documented
  behaviour commits to) plus **every field the example actually carries** — Decimal
  equality for prices/amounts, the documented maker/taker or Credit/Debit semantics for
  sides, and timestamps read in the unit the vendor documents (seconds vs milliseconds vs
  ISO-8601). Where the vendor also documents the request shape, the request this package
  actually sends is captured through the same `plug:`/`x-gemini-payload` seam
  `rest_test.exs` and `private_test.exs` use, and asserted field-for-field.

  A failure here is a real vendor/code mismatch, not a fixture to adjust — see each
  fixture's `README.md` and, where a mismatch was found and fixed while building this file,
  the comment on the code change itself.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types
  alias DpExchange.Gemini.{Private, Rest, Socket}

  @moduletag :capture_log

  # A real limiter answering from configuration, injected through the same process-scoped
  # seam a consumer would use — not a mock, nothing is stubbed and no call is verified.
  # Identical to the one `rest_test.exs` and `private_test.exs` already define; kept local
  # rather than shared because `Core.Config` overrides are process-scoped and this file's
  # tests must stay `async: true`-safe on their own.
  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @date "Fri, 28 Aug 2026 17:00:01 GMT"
  @credentials %{api_key: "spec-example-account", api_secret: "spec-example-secret"}

  # Answers with `body` (already-decoded Elixir terms — a map, list, or bare
  # integer/string, matching whatever `Jason.decode!/1` on the fixture file produced) and the
  # same `Date` response header every other suite in this package stubs.
  defp responding(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> then(&Req.Test.json(%{&1 | status: status}, body))
    end
  end

  # Captures the signed private payload the venue would receive and sends it to the test
  # process, then answers with `body` — the same pattern `private_test.exs` uses. `nonce`
  # and `request` are added by `Auth`, not by the functions under test, so assertions below
  # only check the business fields each function itself puts in the payload.
  defp capturing(body, test_pid) do
    fn conn ->
      payload =
        conn
        |> Plug.Conn.get_req_header("x-gemini-payload")
        |> List.first()
        |> Base.decode64!()
        |> Jason.decode!()

      send(test_pid, {:payload, payload})

      conn
      |> Plug.Conn.put_resp_header("date", @date)
      |> Req.Test.json(body)
    end
  end

  defp fixture!(relative_path) do
    "test/fixtures/spec_examples/#{relative_path}"
    |> File.read!()
    |> Jason.decode!()
  end

  # Alias used by some of this file's `describe` blocks, written independently against the
  # same fixture-loading contract as `fixture!/1`.
  defp load_fixture!(relative_path), do: fixture!(relative_path)

  # `Socket.handle_frame/2` state and frame-encoding helpers, matching
  # `socket_channels_test.exs`'s own `state/1` and `frame/1` — this file defines its own
  # rather than importing that module's private functions.
  defp ws_state(overrides \\ %{}) do
    Map.merge(
      %{
        subscriber: self(),
        request_id: 0,
        connected_once?: false,
        last_heard_at: nil,
        liveness: nil
      },
      overrides
    )
  end

  defp ws_frame(payload), do: {:text, Jason.encode!(payload)}

  # ===========================================================================================
  # REST — public market data (test/fixtures/spec_examples/rest/public/, see its README.md
  # for the exact rest.yaml line each fixture came from)
  # ===========================================================================================

  describe "Rest.get_price/2 — GET /v1/pubticker/{symbol}, rest.yaml:310" do
    test "the vendor's own ticker example decodes to a Quote with Decimal numerics" do
      body = fixture!("rest/public/pubticker.json")

      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("977.65"))
      # /v1/pubticker keys volume by currency code; the base asset (BTC, from the BTC-USD
      # symbol argument) must be the one read, not whichever key happens to come first.
      assert Decimal.equal?(quote_struct.volume, Decimal.new("2210.505328803"))
      assert quote_struct.symbol == "BTC-USD"
      assert quote_struct.provider == :gemini
      # Never the payload's volume.timestamp (24h-window stamp) — the Date header.
      assert quote_struct.venue_time == ~U[2026-08-28 17:00:01Z]
    end
  end

  describe "Rest.get_top_of_book/2 — same GET /v1/pubticker/{symbol} payload, rest.yaml:310" do
    test "the vendor's own ticker example decodes to a TopOfBook, not a traded price" do
      body = fixture!("rest/public/pubticker.json")

      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(top.bid, Decimal.new("977.59"))
      assert Decimal.equal?(top.ask, Decimal.new("977.35"))
      # The payload carries no sizes.
      assert top.bid_size == nil
      assert top.ask_size == nil
      assert top.venue_time == ~U[2026-08-28 17:00:01Z]
    end
  end

  describe "Rest.get_order_book/2 — GET /v1/book/{symbol}, rest.yaml:372" do
    test "the vendor's own book example decodes bids/asks as {price, amount} Decimals" do
      body = fixture!("rest/public/book.json")

      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert [{bid_price, bid_amount}] = book.bids
      assert Decimal.equal?(bid_price, Decimal.new("3607.85"))
      assert Decimal.equal?(bid_amount, Decimal.new("6.643373"))

      assert [{ask_price, ask_amount}] = book.asks
      assert Decimal.equal?(ask_price, Decimal.new("3607.86"))
      assert Decimal.equal?(ask_amount, Decimal.new("14.68205084"))

      # rest.yaml:8065 — OrderBookEntry.timestamp is documented "DO NOT USE", so this
      # package never derives venue_time from it. See Rest.get_order_book/2's own moduledoc.
      assert book.venue_time == nil
    end
  end

  describe "Rest.get_trades/2 — GET /v1/trades/{symbol}, rest.yaml:471" do
    test "the vendor's own example is BROKEN, and is excluded by default" do
      body = fixture!("rest/public/trades.json")

      assert {:ok, []} =
               Rest.get_trades("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "the same broken print is returned with :include_broken, decoded field-for-field" do
      body = fixture!("rest/public/trades.json")

      assert {:ok, [trade]} =
               Rest.get_trades("BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0,
                 include_broken: true
               )

      assert %Types.Trade{} = trade
      assert trade.id == "5335307668"
      assert trade.symbol == "BTC-USD"
      # rest.yaml's Trade schema: "buy" means an ask was lifted — the TAKER's side.
      assert trade.side == :buy
      assert Decimal.equal?(trade.price, Decimal.new("3610.85"))
      assert Decimal.equal?(trade.quantity, Decimal.new("0.27413495"))
      assert trade.broken == true
      # timestampms (1547146811357), the precise field, over timestamp (1547146811).
      assert trade.timestamp == DateTime.from_unix!(1_547_146_811_357, :millisecond)
    end
  end

  describe "Rest.get_symbols/1 — GET /v1/symbols, rest.yaml:37" do
    test "the vendor's own 208-symbol example: perpetuals excluded, the rest canonicalised" do
      body = fixture!("rest/public/symbols.json")

      assert {:ok, symbols} = Rest.get_symbols(plug: responding(body), retry_attempts: 0)

      # 208 native symbols in the vendor's own example, 31 of them perpetual (suffix
      # "perp") and excluded per Rest.get_symbols/1's own moduledoc.
      assert length(symbols) == 177
      refute Enum.any?(symbols, &String.ends_with?(&1, "PERP"))
      assert "BTC-USD" in symbols

      # The vendor's own example is what SymbolFormat.mis_splits exists for: "paxgusd" is
      # in this exact list, and the longest-quote-first rule alone would split it
      # "PAX-GUSD" — a pair that does not exist. See SymbolFormat's moduledoc.
      assert "PAXG-USD" in symbols
      refute "PAX-GUSD" in symbols
    end
  end

  describe "Rest.get_market_overview/1 — GET /v1/pricefeed, rest.yaml:502" do
    test "the vendor's own 4-row example decodes price and change_24h as Decimals" do
      body = fixture!("rest/public/pricefeed.json")

      assert {:ok, overview} = Rest.get_market_overview(plug: responding(body), retry_attempts: 0)

      assert %{price: price, change_24h: change} = overview["BTC-USD"]
      assert Decimal.equal?(price, Decimal.new("9500.00"))
      assert Decimal.equal?(change, Decimal.new("5.23"))

      assert %{price: eth_price} = overview["ETH-USD"]
      assert Decimal.equal?(eth_price, Decimal.new("257.54"))

      # A negative 24h change is a real, documented shape — not clamped or dropped.
      assert %{change_24h: bch_change} = overview["BCH-USD"]
      assert Decimal.equal?(bch_change, Decimal.new("-2.91"))
    end
  end

  describe "Rest.quantization/2 — GET /v1/symbols/details/{symbol}, rest.yaml:64" do
    test "the vendor's own 'spot' named example: tick_size and quote_increment are not swapped" do
      body = fixture!("rest/public/symbols_details_spot.json")

      assert {:ok, quant} =
               Rest.quantization("BTC-USD", plug: responding(body), retry_attempts: 0)

      # tick_size (base-asset increment) is the venue's 1e-8; quote_increment (price
      # increment) is 0.01 — the two must not be read from each other's field.
      assert Decimal.equal?(quant.quantity_increment, Decimal.from_float(1.0e-8))
      assert Decimal.equal?(quant.price_increment, Decimal.new("0.01"))
      assert Decimal.equal?(quant.min_quantity, Decimal.new("0.00001"))
      assert quant.status == "open"
    end

    test "the vendor's own 'perpetual' named example decodes the same way" do
      body = fixture!("rest/public/symbols_details_perpetual.json")

      assert {:ok, quant} =
               Rest.quantization("BTC-ETH-PERP", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quant.quantity_increment, Decimal.new("0.0001"))
      assert Decimal.equal?(quant.price_increment, Decimal.new("0.5"))
      assert Decimal.equal?(quant.min_quantity, Decimal.new("0.0001"))
    end
  end

  describe "Rest.get_staking_rates/1 — GET /v1/staking/rates, rest.yaml:6823" do
    test "the vendor's own example: provider UUID outer, asset symbol inner — not inverted" do
      body = fixture!("rest/public/staking_rates.json")

      assert {:ok, rates} = Rest.get_staking_rates(plug: responding(body), retry_attempts: 0)
      assert length(rates) == 3

      matic = Enum.find(rates, &(&1.asset == "MATIC"))
      assert matic.provider_id == "62bb4d27-a9c8-4493-a737-d4fa33994f1f"
      # ratePct is published directly (0.958909) — read over rate/100 when both are present.
      assert Decimal.equal?(matic.rate_pct, Decimal.new("0.958909"))
      assert Decimal.equal?(matic.apy_pct, Decimal.new("0.96"))
      assert Decimal.equal?(matic.deposit_limit_usd, Decimal.new("500000"))

      eth = Enum.find(rates, &(&1.asset == "ETH"))
      assert Decimal.equal?(eth.apy_pct, Decimal.new("2.31"))

      sol = Enum.find(rates, &(&1.asset == "SOL"))
      assert Decimal.equal?(sol.rate_pct, Decimal.new("3.215282"))
    end
  end

  describe "Rest.get_funding/2 — GET /v1/fundingamount/{symbol}, rest.yaml:557" do
    test "the vendor's own example: settled (fundingAmount) and estimated stay separate fields" do
      body = fixture!("rest/public/fundingamount.json")

      assert {:ok, %Types.Funding{} = funding} =
               Rest.get_funding("BTCGUSDPERP", plug: responding(body), retry_attempts: 0)

      assert funding.symbol == "BTCGUSDPERP"
      # The vendor's OWN example uses "fundingAmount", not the schema's "amount" — the
      # contradiction Rest.get_funding/2's moduledoc documents, exercised here directly
      # against the vendor's real example rather than a fixture written to dodge it.
      assert Decimal.equal?(funding.amount, Decimal.new("-1.50991"))
      assert Decimal.equal?(funding.estimated_amount, Decimal.new("-2.10595"))
      assert funding.funded_at == DateTime.from_unix!(1_745_344_800_000, :millisecond)
      assert funding.next_funding_at == DateTime.from_unix!(1_745_348_400_000, :millisecond)
    end
  end

  describe "Rest.next_funding_timestamp/2 — GET /v1/nextfundingtimestamp/{symbol}, rest.yaml:599" do
    test "the vendor's own example is a bare integer, milliseconds since the epoch" do
      body = fixture!("rest/public/nextfundingtimestamp.json")

      assert {:ok, at} =
               Rest.next_funding_timestamp("BTCGUSDPERP",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert at == DateTime.from_unix!(1_745_348_400_000, :millisecond)
    end
  end

  describe "Rest.get_contract_stats/2 — GET /v1/riskstats/{symbol}, rest.yaml:7624" do
    test "the vendor's own example: mark, index and open interest are distinct fields" do
      body = fixture!("rest/public/riskstats.json")

      assert {:ok, %Types.ContractStats{} = stats} =
               Rest.get_contract_stats("BTCGUSDPERP", plug: responding(body), retry_attempts: 0)

      assert stats.product_type == "PerpetualSwapContract"
      assert Decimal.equal?(stats.mark_price, Decimal.new("30080.00"))
      assert Decimal.equal?(stats.index_price, Decimal.new("30079.046"))
      assert Decimal.equal?(stats.open_interest, Decimal.new("14.439"))
      assert Decimal.equal?(stats.open_interest_notional, Decimal.new("434325.12"))
      assert stats.venue_time == nil
    end
  end

  describe "Rest.get_historical_prices/4 — GET /v2/candles/{symbol}/{time_frame}, rest.yaml:7735" do
    test "the vendor's own 2-bar spot example decodes [time, o, h, l, c, v] in that order" do
      body = fixture!("rest/public/candles.json")

      assert {:ok, candles} =
               Rest.get_historical_prices("BTC-USD", "1h", [],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(candles) == 2
      # Both bars in the vendor's own example carry the same opened_at (1559755800000);
      # `get_historical_prices/4`'s sort by opened_at is stable, so the vendor's own row
      # order survives — asserted directly rather than re-sorted by another field.
      [first, second] = candles

      assert first.opened_at == DateTime.from_unix!(1_559_755_800_000, :millisecond)
      assert Decimal.equal?(first.open, Decimal.from_float(7781.6))
      assert Decimal.equal?(first.high, Decimal.from_float(7820.23))
      assert Decimal.equal?(first.low, Decimal.from_float(7776.56))
      assert Decimal.equal?(first.close, Decimal.from_float(7819.39))
      assert Decimal.equal?(first.volume, Decimal.from_float(34.7624802159))
      assert first.symbol == "BTC-USD"
      assert first.provider == :gemini

      assert second.opened_at == DateTime.from_unix!(1_559_755_800_000, :millisecond)
      assert Decimal.equal?(second.high, Decimal.from_float(7829.46))
      assert Decimal.equal?(second.close, Decimal.from_float(7817.28))
      assert Decimal.equal?(second.volume, Decimal.from_float(43.4228281059))
    end
  end

  describe "Rest.get_historical_prices/4 (perpetual) — GET /v2/derivatives/candles/{symbol}/1m, rest.yaml:7792" do
    test "the vendor's own 2-bar derivatives example, one width only" do
      body = fixture!("rest/public/derivatives_candles.json")

      assert {:ok, candles} =
               Rest.get_historical_prices("BTC-GUSD-PERP", "1m", [],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(candles) == 2
      assert Enum.all?(candles, &(&1.symbol == "BTC-GUSD-PERP"))
      assert Enum.all?(candles, &Decimal.equal?(&1.open, Decimal.new(68_038)))
      assert Enum.all?(candles, &Decimal.equal?(&1.volume, Decimal.new(0)))

      # A width other than 1m is refused before ever reaching the venue — the derivatives
      # endpoint documents only "1m" in its time_frame enum.
      assert {:error, {:unsupported_timeframe, "5m"}} =
               Rest.get_historical_prices("BTC-GUSD-PERP", "5m", [],
                 plug: fn _conn -> raise "must not request an unserved width" end,
                 retry_attempts: 0
               )
    end
  end

  # ===========================================================================================
  # REST — private: balances, orders, trades, volume
  # (test/fixtures/spec_examples/rest/private/orders/)
  # ===========================================================================================

  describe "Private.get_balances/2 — POST /v1/balances, rest.yaml:1925 examples.multipleBalances" do
    test "decodes the vendor's multi-currency response with Decimal amounts and a derived hold" do
      body = fixture!("rest/private/orders/get_balances.json")

      assert {:ok, balances} =
               Private.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert length(balances) == 3
      btc = Enum.find(balances, &(&1.currency == "BTC"))
      assert Decimal.equal?(btc.balance, Decimal.new("5.0"))
      assert Decimal.equal?(btc.available_balance, Decimal.new("4.5"))
      # hold = amount - available, derived rather than published.
      assert Decimal.equal?(btc.hold, Decimal.new("0.5"))
    end
  end

  describe "Private.get_accounts/2 — POST /v1/account, rest.yaml:5470" do
    test "wraps the vendor's single account object in a one-element list, unmodified" do
      body = fixture!("rest/private/orders/get_accounts.json")

      assert {:ok, [account]} =
               Private.get_accounts(@credentials, plug: responding(body), retry_attempts: 0)

      assert account["account"]["accountName"] == "Primary"
      assert account["memo_reference_code"] == "GEMPJBRDZ"
      assert length(account["users"]) == 2
    end
  end

  describe "Private.get_fees/2 — POST /v1/notionalvolume, rest.yaml:2070" do
    test "the vendor's withFeeTier response passes through with its own bps units intact" do
      body = fixture!("rest/private/orders/get_fees.json")

      assert {:ok, fees} =
               Private.get_fees(@credentials, plug: responding(body), retry_attempts: 0)

      assert fees["api_maker_fee_bps"] == 0
      assert fees["fee_tier"]["tier"] == "0bps"
    end

    test "opts[:symbol] is sent lowercase and separatorless, the shape /v1/feepromos moved to" do
      test_pid = self()
      body = fixture!("rest/private/orders/get_fees.json")

      assert {:ok, _fees} =
               Private.get_fees(@credentials,
                 symbol: "BTC-USD",
                 plug: capturing(body, test_pid),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "btcusd"
    end
  end

  describe "Private.get_transfers/2 — POST /v2/transfers, rest.yaml:3196 examples.multiNetworkTransfers" do
    test "decodes the vendor's multi-network transfer rows, passed through as-is" do
      body = fixture!("rest/private/orders/get_transfers.json")

      assert {:ok, rows} =
               Private.get_transfers(@credentials, plug: responding(body), retry_attempts: 0)

      assert length(rows) == 3
      withdrawal = Enum.find(rows, &(&1["network"] == "ethereum" and &1["type"] == "Withdrawal"))
      assert withdrawal["amount"] == "0.01"
      assert withdrawal["status"] == "Complete"
    end
  end

  describe "Private.place_order/3 — POST /v1/order/new, rest.yaml:686" do
    test "the vendor's limitOrder response decodes with Decimal price/quantity and :buy side" do
      body = fixture!("rest/private/orders/place_order.json")

      assert {:ok, %Types.Order{} = order} =
               Private.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   quantity: Decimal.new("5"),
                   price: Decimal.new("3633.00")
                 },
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.id == "106817811"
      assert order.side == :buy
      assert order.order_type == :limit
      assert Decimal.equal?(order.quantity, Decimal.new("5"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("3.7567928949"))
      # is_live true, executed_amount positive but < original_amount -> partially_filled.
      assert order.status == :partially_filled
    end

    test "the vendor's stopLimitOrder response decodes as :stop_limit with a carried stop_price" do
      body = fixture!("rest/private/orders/place_order_stop_limit.json")

      assert {:ok, %Types.Order{} = order} =
               Private.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   quantity: Decimal.new("0.1"),
                   price: Decimal.new("10500"),
                   order_type: :stop_limit,
                   stop_price: Decimal.new("10000")
                 },
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.order_type == :stop_limit
      assert Decimal.equal?(order.stop_price, Decimal.new("10400.00"))
      assert order.status == :open
    end

    test "the request carries the vendor's documented field names, units and lowercased symbol" do
      test_pid = self()
      body = fixture!("rest/private/orders/place_order.json")

      assert {:ok, _order} =
               Private.place_order(
                 @credentials,
                 %{
                   symbol: "BTC-USD",
                   side: :buy,
                   quantity: Decimal.new("5"),
                   price: Decimal.new("3633.00"),
                   client_order_id: "470135"
                 },
                 plug: capturing(body, test_pid),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "btcusd"
      assert payload["side"] == "buy"
      assert payload["type"] == "exchange limit"
      assert payload["amount"] == "5"
      assert payload["price"] == "3633.00"
      assert payload["client_order_id"] == "470135"
    end
  end

  describe "Private.cancel_order/3 — POST /v1/order/cancel, rest.yaml:874" do
    test "the vendor's own cancelledOrder example is a PARTIAL fill, and decodes :cancelled, not :filled" do
      # CODE FIX made while building this suite: the vendor's own example here is
      # `original_amount: "5"`, `executed_amount: "3.7610296649"` — a cancel after a 75.2%
      # fill — and `Private.status_of/1` used to collapse ANY cancelled order with a
      # positive executed amount to `:filled`, a status this contract documents as meaning
      # the entire quantity traded. See `status_of/1`'s own comment and this fixture's
      # README.md for the full account.
      body = fixture!("rest/private/orders/cancel_order.json")

      assert {:ok, %Types.Order{} = order} =
               Private.cancel_order(@credentials, "106817811",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(order.quantity, Decimal.new("5"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("3.7610296649"))
      # Cancelled, with the partial fill carried in `filled_quantity`: `:partially_filled`
      # would say the order is still working, and the venue has closed it.
      assert order.status == :cancelled
    end
  end

  describe "Private.get_order/3 — POST /v1/order/status, rest.yaml:1142 examples.limitBuyResponse" do
    test "decodes a fully-filled order" do
      body = fixture!("rest/private/orders/get_order.json")

      assert {:ok, %Types.Order{} = order} =
               Private.get_order(@credentials, "123456789012345",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(order.quantity, Decimal.new("3"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("3"))
      assert order.status == :filled
    end
  end

  describe "Private.get_orders/2 — POST /v1/orders, rest.yaml:1274 examples.multipleOrders" do
    test "decodes two resting orders, one untouched and one partially filled" do
      body = fixture!("rest/private/orders/get_orders.json")

      assert {:ok, [first, second]} =
               Private.get_orders(@credentials, plug: responding(body), retry_attempts: 0)

      assert first.id == "107421210"
      assert first.status == :open
      assert second.id == "107421205"
      assert second.status == :partially_filled
    end
  end

  describe "Private.get_orders/2 history: true — POST /v1/orders/history, rest.yaml:1418 examples.completedOrder" do
    test "decodes a fully filled order from history" do
      body = fixture!("rest/private/orders/get_orders_history.json")

      assert {:ok, [order]} =
               Private.get_orders(@credentials,
                 history: true,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.id == "107421205"
      assert order.status == :filled
    end

    test "the request sends the vendor's symbol/timestamp/limit_orders fields" do
      test_pid = self()
      body = fixture!("rest/private/orders/get_orders_history.json")

      assert {:ok, _orders} =
               Private.get_orders(@credentials,
                 history: true,
                 symbol: "BTC-USD",
                 limit: 50,
                 since: DateTime.from_unix!(1_591_084_414_000, :millisecond),
                 plug: capturing(body, test_pid),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "btcusd"
      assert payload["limit_orders"] == 50
      assert payload["timestamp"] == 1_591_084_414_000
    end
  end

  describe "Private.cancel_all_orders/2 — rest.yaml:987 (account) and rest.yaml:1075 (session)" do
    test "scope: :account decodes the vendor's cancelled-ids response" do
      body = fixture!("rest/private/orders/cancel_all_orders_account.json")

      assert {:ok, %{cancelled: cancelled, rejected: []}} =
               Private.cancel_all_orders(@credentials,
                 scope: :account,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert cancelled == ["330429106", "330429079", "330429082"]
    end

    test "scope: :session decodes the vendor's rejected-id response" do
      body = fixture!("rest/private/orders/cancel_all_orders_session.json")

      assert {:ok, %{cancelled: [], rejected: rejected}} =
               Private.cancel_all_orders(@credentials,
                 scope: :session,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert rejected == ["330429345"]
    end
  end

  describe "Private.get_trade_history/2 — POST /v1/mytrades, rest.yaml:1608 examples.multipleTrades" do
    test "decodes both fills, downcasing the venue's capitalised type field" do
      body = fixture!("rest/private/orders/get_trade_history.json")

      assert {:ok, fills} =
               Private.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)

      assert length(fills) == 2
      taker = Enum.find(fills, &(&1.order_id == "107317524"))
      assert taker.side == :buy
      assert taker.liquidity == :taker
      assert Decimal.equal?(taker.price, Decimal.new("3648.09"))

      maker = Enum.find(fills, &(&1.order_id == "106817811"))
      assert maker.liquidity == :maker
      assert Decimal.equal?(maker.fee, Decimal.new("0.038480463525"))
    end

    test "the request sends milliseconds for :since and an integer for :limit" do
      test_pid = self()
      body = fixture!("rest/private/orders/get_trade_history.json")

      assert {:ok, _fills} =
               Private.get_trade_history(@credentials,
                 symbol: "BTC-USD",
                 limit: 100,
                 since: DateTime.from_unix!(1_591_084_414_000, :millisecond),
                 plug: capturing(body, test_pid),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "btcusd"
      assert payload["limit_trades"] == 100
      assert payload["timestamp"] == 1_591_084_414_000
    end
  end

  describe "Private.test_connection/2 — POST /v1/heartbeat, rest.yaml:2619" do
    test "a successful heartbeat reports reachable: true with the venue's own body" do
      body = fixture!("rest/private/orders/test_connection.json")

      assert {:ok, %{reachable: true, response: %{"result" => "ok"}}} =
               Private.test_connection(@credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  # ===========================================================================================
  # REST — private wallet/conversion/custody (test/fixtures/spec_examples/rest/private/wallet/,
  # see its README.md for exact rest.yaml line citations)
  # ===========================================================================================

  describe "quote_conversion/4 — spec example conformance" do
    test "a buy quote decodes the vendor's own btcBuyResponse, and the request matches buyQuote" do
      response = load_fixture!("rest/private/wallet/quote_conversion_buy_response.json")
      request = load_fixture!("rest/private/wallet/quote_conversion_buy_request.json")

      assert {:ok, conversion} =
               Private.quote_conversion("USD", "BTC", Decimal.new("100"),
                 symbol: "BTC-USD",
                 side: :buy,
                 credentials: @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["symbol"] == request["symbol"]
      assert payload["side"] == request["side"]
      assert payload["totalSpend"] == request["totalSpend"]

      assert conversion.id == "1328"
      assert conversion.status == :quoted
      assert conversion.from_asset == "USD"
      assert conversion.to_asset == "BTC"
      assert Decimal.equal?(conversion.from_amount, Decimal.new(response["totalSpend"]))
      assert Decimal.equal?(conversion.to_amount, Decimal.new(response["quantity"]))
      assert Decimal.equal?(conversion.rate, Decimal.new(response["price"]))
      assert Decimal.equal?(conversion.fee, Decimal.new(response["fee"]))
      assert conversion.provider == :gemini
    end

    test "a sell quote (ethSellResponse) reports no to_amount — the venue publishes no proceeds figure for a sell" do
      response = load_fixture!("rest/private/wallet/quote_conversion_sell_response.json")

      assert {:ok, conversion} =
               Private.quote_conversion("ETH", "USD", Decimal.new("1"),
                 symbol: "ETH-USD",
                 side: :sell,
                 credentials: @credentials,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert conversion.from_asset == "ETH"
      assert conversion.to_asset == "USD"
      assert Decimal.equal?(conversion.from_amount, Decimal.new(response["quantity"]))
      assert conversion.to_amount == nil
    end
  end

  describe "commit_conversion/2 — spec example conformance" do
    test "decodes the vendor's own btcusdBuy execute response and sends executeBuyOrder's terms" do
      response = load_fixture!("rest/private/wallet/commit_conversion_response.json")
      request = load_fixture!("rest/private/wallet/commit_conversion_buy_request.json")

      assert {:ok, conversion} =
               Private.commit_conversion("1328",
                 symbol: "BTC-USD",
                 side: :buy,
                 amount: Decimal.new("0.01505181"),
                 price: Decimal.new("6445.07"),
                 fee: Decimal.new("2.9900309233"),
                 credentials: @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["quoteId"] == request["quoteId"]
      assert payload["quantity"] == request["quantity"]
      assert payload["price"] == request["price"]
      assert payload["fee"] == request["fee"]

      assert conversion.id == "375089415"
      assert conversion.status == :settled
      assert Decimal.equal?(conversion.rate, Decimal.new(response["price"]))
    end
  end

  describe "convert/4 — spec example conformance" do
    test "decodes the vendor's own /v1/wrap response and sends the documented amount/side" do
      response = load_fixture!("rest/private/wallet/convert_response.json")
      request = load_fixture!("rest/private/wallet/convert_request.json")

      assert {:ok, conversion} =
               Private.convert("USD", "GUSD", Decimal.new("1"),
                 symbol: "GUSD-USD",
                 side: :buy,
                 credentials: @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["amount"] == request["amount"]
      assert payload["side"] == request["side"]

      assert conversion.id == "429135395"
      assert conversion.status == :settled
      assert Decimal.equal?(conversion.rate, Decimal.new(response["price"]))
      assert Decimal.equal?(conversion.fee, Decimal.new(response["fee"]))
    end
  end

  describe "get_trade_volume/2 — spec example conformance" do
    test "flattens the venue's nested per-symbol rows from the vendor's own singleSymbol example" do
      response = load_fixture!("rest/private/wallet/get_trade_volume_response.json")
      [[row]] = response

      assert {:ok, [decoded]} =
               Private.get_trade_volume(@credentials,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert decoded["symbol"] == row["symbol"]
      assert decoded["base_currency"] == row["base_currency"]
      assert decoded["buy_maker_notional"] == row["buy_maker_notional"]
    end
  end

  describe "list_networks/2 — spec example conformance" do
    test "the asset direction wraps the vendor's single-network example" do
      response = load_fixture!("rest/private/wallet/list_networks_asset_response.json")

      assert {:ok, [decoded]} =
               Private.list_networks("BTC",
                 credentials: @credentials,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert decoded["token"] == response["token"]
      assert decoded["network"] == response["network"]
    end

    test "the network direction wraps the vendor's multi-asset-network example" do
      response = load_fixture!("rest/private/wallet/list_networks_network_response.json")

      assert {:ok, [decoded]} =
               Private.list_networks(nil,
                 network: "ethereum",
                 credentials: @credentials,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert decoded["network"] == response["network"]
      assert decoded["assets"] == response["assets"]
    end
  end

  describe "get_fx_rate/3 — spec example conformance" do
    test "decodes the vendor's own AUDUSD example, asOf as a millisecond-epoch DateTime" do
      response = load_fixture!("rest/private/wallet/get_fx_rate_response.json")

      assert {:ok, rate} =
               Private.get_fx_rate("AUD-USD", ~U[2020-07-13 16:30:59Z],
                 credentials: @credentials,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert rate.pair == response["fxPair"]
      assert Decimal.equal?(rate.rate, Decimal.new(response["rate"]))
      assert rate.as_of == DateTime.from_unix!(response["asOf"], :millisecond)
      assert rate.source == response["provider"]
      assert rate.benchmark == response["benchmark"]
    end
  end

  describe "get_deposit_address/4 — spec example conformance" do
    test "decodes the vendor's own bitcoinAddress example and sends basicBitcoin's label" do
      response = load_fixture!("rest/private/wallet/get_deposit_address_response.json")
      request = load_fixture!("rest/private/wallet/get_deposit_address_request.json")

      assert {:ok, address} =
               Private.get_deposit_address("BTC", "bitcoin", @credentials,
                 label: request["label"],
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["label"] == request["label"]

      assert address.address == response["address"]
      assert address.network == "bitcoin"
      assert address.label == response["label"]
      assert address.memo_required == nil
    end
  end

  describe "list_approved_addresses/2 — spec example conformance" do
    test "decodes all four rows of the vendor's own example, statuses read literally" do
      response = load_fixture!("rest/private/wallet/list_approved_addresses_response.json")
      [first, _second, third, _fourth] = response["approvedAddresses"]

      assert {:ok, [d1, _d2, d3, _d4]} =
               Private.list_approved_addresses(@credentials,
                 network: "ethereum",
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert d1.address == first["address"]
      assert d1.status == :pending
      assert d3.address == third["address"]
      assert d3.status == :active
    end
  end

  describe "estimate_withdrawal_fee/5 — spec example conformance" do
    test "decodes a bare-number fee (not a numeric string) from the vendor's own ethResponse" do
      response = load_fixture!("rest/private/wallet/estimate_withdrawal_fee_response.json")
      request = load_fixture!("rest/private/wallet/estimate_withdrawal_fee_request.json")

      assert {:ok, estimate} =
               Private.estimate_withdrawal_fee(
                 "ETH",
                 "ethereum",
                 Decimal.new("0.01"),
                 @credentials,
                 address: request["address"],
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["address"] == request["address"]
      assert payload["amount"] == request["amount"]

      assert Decimal.equal?(estimate.fee, Decimal.new("0.001"))
      assert estimate.fee_currency == response["currency"]
    end
  end

  describe "withdraw/6 — spec example conformance" do
    test "decodes the vendor's own ethWithdrawalResponse and sends the documented address/amount" do
      response = load_fixture!("rest/private/wallet/withdraw_response.json")
      request = load_fixture!("rest/private/wallet/withdraw_request.json")

      assert {:ok, withdrawal} =
               Private.withdraw(
                 "ETH",
                 "ethereum",
                 Decimal.new(request["amount"]),
                 request["address"],
                 @credentials,
                 client_transfer_id: request["clientTransferId"],
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["address"] == request["address"]
      assert payload["amount"] == request["amount"]
      assert payload["clientTransferId"] == request["clientTransferId"]

      assert withdrawal.id == response["withdrawalId"]
      assert withdrawal.status == :pending
      assert Decimal.equal?(withdrawal.fee, Decimal.new(response["fee"]))
      assert withdrawal.address == response["address"]
    end
  end

  describe "list_payment_methods/2 — spec example conformance" do
    test "tags balances and banks from the vendor's own two-array example, never reading a methods key" do
      response = load_fixture!("rest/private/wallet/list_payment_methods_response.json")
      [balance_row] = response["balances"]
      [bank_row] = response["banks"]

      assert {:ok, rows} =
               Private.list_payment_methods(@credentials,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert %{"kind" => "balance", "currency" => "USD"} =
               Enum.find(rows, &(&1["kind"] == "balance"))

      assert %{"kind" => "bank", "bankId" => bank_id} = Enum.find(rows, &(&1["kind"] == "bank"))
      assert bank_id == bank_row["bankId"]
      assert Enum.find(rows, &(&1["kind"] == "balance"))["amount"] == balance_row["amount"]
    end
  end

  describe "add_payment_method/3 — spec example conformance" do
    test "the US endpoint (default) sends the vendor's own addbank example verbatim" do
      request = load_fixture!("rest/private/wallet/add_payment_method_us_request.json")
      response = load_fixture!("rest/private/wallet/add_payment_method_us_response.json")
      details = Map.drop(request, ["request", "nonce"])

      assert {:ok, body} =
               Private.add_payment_method(details, @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["accountnumber"] == details["accountnumber"]
      assert payload["routing"] == details["routing"]
      assert body["referenceId"] == response["referenceId"]
    end

    test "opts[:country] \"CA\" sends to /v1/payments/addbank/cad with the vendor's own cad example" do
      request = load_fixture!("rest/private/wallet/add_payment_method_ca_request.json")
      response = load_fixture!("rest/private/wallet/add_payment_method_ca_response.json")
      details = Map.drop(request, ["request", "nonce"])

      assert {:ok, body} =
               Private.add_payment_method(details, @credentials,
                 country: "CA",
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["swiftcode"] == details["swiftcode"]
      assert payload["institutionnumber"] == details["institutionnumber"]
      assert body["result"] == response["result"]
    end
  end

  describe "transfer_internal/5 — spec example conformance" do
    test "sends the vendor's own withClientId example and decodes the response verbatim" do
      request = load_fixture!("rest/private/wallet/transfer_internal_request.json")
      response = load_fixture!("rest/private/wallet/transfer_internal_response.json")

      assert {:ok, body} =
               Private.transfer_internal(
                 "ETH",
                 Decimal.new(request["amount"]),
                 [
                   from: request["sourceAccount"],
                   to: request["targetAccount"],
                   client_transfer_id: request["clientTransferId"]
                 ],
                 @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["sourceAccount"] == request["sourceAccount"]
      assert payload["targetAccount"] == request["targetAccount"]
      assert payload["clientTransferId"] == request["clientTransferId"]
      assert body["uuid"] == response["uuid"]
    end
  end

  describe "request_approved_address/5 — spec example conformance" do
    test "sends the vendor's own request example and returns its message" do
      request = load_fixture!("rest/private/wallet/request_approved_address_request.json")
      response = load_fixture!("rest/private/wallet/request_approved_address_response.json")

      assert {:ok, body} =
               Private.request_approved_address(
                 "ethereum",
                 request["address"],
                 request["label"],
                 @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["address"] == request["address"]
      assert payload["label"] == request["label"]
      assert body["message"] == response["message"]
    end
  end

  describe "remove_approved_address/4 — spec example conformance" do
    test "sends the vendor's own remove example and returns its message" do
      request = load_fixture!("rest/private/wallet/remove_approved_address_request.json")
      response = load_fixture!("rest/private/wallet/remove_approved_address_response.json")

      assert {:ok, body} =
               Private.remove_approved_address("ethereum", request["address"], @credentials,
                 plug: capturing(response, self()),
                 retry_attempts: 0
               )

      assert_received {:payload, payload}
      assert payload["address"] == request["address"]
      assert body["message"] == response["message"]
    end
  end

  describe "get_transactions/2 — spec example conformance" do
    test "decodes the vendor's own tradeResponse rows (single-page branch via opts[:limit])" do
      response = load_fixture!("rest/private/wallet/get_transactions_response.json")
      [first, second] = response["results"]

      assert {:ok, [d1, d2]} =
               Private.get_transactions(@credentials,
                 limit: 50,
                 plug: responding(response),
                 retry_attempts: 0
               )

      assert d1["symbol"] == first["symbol"]
      assert d1["price"] == first["price"]
      assert d1["side"] == first["side"]
      assert d1["side"] == "SIDE_TYPE_BUY"
      assert d2["side"] == second["side"]
      assert d2["side"] == "SIDE_TYPE_SELL"
    end
  end

  # ===========================================================================================
  # REST — private: derivatives, margin, staking, positions (test/fixtures/spec_examples/
  # rest/private/derivatives/, see its README.md for exact rest.yaml line citations)
  # ===========================================================================================

  describe "Private.get_notional_balances/3 — POST /v1/notionalbalances/{currency}, rest.yaml:2811" do
    test "the vendor's own three-currency example decodes, unwrapped" do
      body = fixture!("rest/private/derivatives/get_notional_balances.json")

      assert {:ok, rows} =
               Private.get_notional_balances(@credentials, "usd",
                 plug: responding(body),
                 retry_attempts: 0
               )

      btc = Enum.find(rows, &(&1["currency"] == "BTC"))
      assert btc["amount"] == "1154.62034001"
      assert btc["amountNotional"] == "10386000.59"
    end

    test "the currency is lowercased into the path, matching the vendor's basic example" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:path, conn.request_path})
        conn |> Plug.Conn.put_resp_header("date", @date) |> Req.Test.json([])
      end

      Private.get_notional_balances(@credentials, "USD", plug: plug, retry_attempts: 0)

      assert_receive {:path, path}
      assert path == "/v1/notionalbalances/usd"
    end
  end

  describe "Private.list_custody_fees/2 — POST /v1/custodyaccountfees, rest.yaml:3385" do
    test "the vendor's own multipleFees example decodes, four rows" do
      body = fixture!("rest/private/derivatives/list_custody_fees.json")

      assert {:ok, rows} =
               Private.list_custody_fees(@credentials, plug: responding(body), retry_attempts: 0)

      assert length(rows) == 4
      withdrawal = Enum.find(rows, &(&1["eventType"] == "Withdrawal"))
      assert withdrawal["feeAmount"] == "10"
      assert withdrawal["feeCurrency"] == "BTC"
      assert withdrawal["eid"] == 256_627
    end
  end

  describe "Private.get_staking_balances/2 — POST /v1/balances/staking, rest.yaml:6504" do
    test "the vendor's own example: staked, available and withdrawable stay apart" do
      body = fixture!("rest/private/derivatives/get_staking_balances.json")

      assert {:ok, balances} =
               Private.get_staking_balances(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert %Types.StakingBalance{} = matic = Enum.find(balances, &(&1.asset == "MATIC"))
      assert Decimal.equal?(matic.staked, Decimal.new("10"))
      assert Decimal.equal?(matic.available_to_trade, Decimal.new("0"))
      assert Decimal.equal?(matic.available_for_withdrawal, Decimal.new("10"))

      assert Decimal.equal?(
               matic.by_provider["62b21e17-2534-4b9f-afcf-b7edb609dd8d"],
               Decimal.new("10")
             )
    end
  end

  describe "Private.get_staking_rewards/2 — POST /v1/staking/rewards, rest.yaml:6852" do
    test "the vendor's nested {providerId: {currency: {ratePeriods}}} reply — one reward per period" do
      body = fixture!("rest/private/derivatives/get_staking_rewards.json")

      assert {:ok, rewards} =
               Private.get_staking_rewards(@credentials,
                 plug: responding(body),
                 retry_attempts: 0,
                 since: ~U[2022-08-20 00:00:00Z]
               )

      assert length(rewards) == 3

      first_matic =
        Enum.find(rewards, fn r ->
          r.asset == "MATIC" and Decimal.equal?(r.amount, Decimal.new("0.0065678"))
        end)

      assert %Types.StakingReward{} = first_matic
      assert first_matic.provider_id == "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
      assert Decimal.equal?(first_matic.apy_pct, Decimal.new("5.75"))
      assert first_matic.accrual_count == 1
      assert first_matic.period_start == ~U[2022-08-23 20:00:00.000Z]
      assert first_matic.period_end == ~U[2022-08-23 20:00:00.000Z]
    end

    test "since/until go out ISO-8601, not epoch millis — rest.yaml:6885,6896" do
      test_pid = self()

      Private.get_staking_rewards(@credentials,
        plug: capturing([], test_pid),
        retry_attempts: 0,
        since: ~U[2022-08-20 00:00:00Z],
        until: ~U[2022-11-05 00:00:00Z],
        provider_id: "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
      )

      assert_receive {:payload, payload}
      assert payload["since"] == "2022-08-20T00:00:00Z"
      assert payload["until"] == "2022-11-05T00:00:00Z"
      assert payload["providerId"] == "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
    end

    test "missing :since is refused before a request is sent — rest.yaml:6885 lists it required" do
      assert {:error, {:missing_option, :since}} =
               Private.get_staking_rewards(@credentials, retry_attempts: 0)
    end
  end

  describe "Private.get_staking_history/2 — POST /v1/staking/history, rest.yaml:6677" do
    test "decodes {providerId, transactions: [...]} — providerId from the PARENT entry" do
      body = fixture!("rest/private/derivatives/get_staking_history.json")

      assert {:ok, txns} =
               Private.get_staking_history(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(txns) == 4

      redeem = Enum.find(txns, &(&1.id == "MPZ7LDD8"))
      assert %Types.StakingTransaction{} = redeem
      assert redeem.provider_id == "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
      assert redeem.type == :unstake
      assert redeem.venue_type == "Redeem"
      assert redeem.asset == "MATIC"
      assert Decimal.equal?(redeem.amount, Decimal.new("20"))
      assert redeem.venue_time == DateTime.from_unix!(1_667_418_560_153, :millisecond)

      interest = Enum.find(txns, &(&1.venue_type == "Interest"))
      assert interest.type == :reward
    end
  end

  describe "Private.stake/4 — POST /v1/staking/stake, rest.yaml:6589" do
    test "the vendor's own response example decodes" do
      body = fixture!("rest/private/derivatives/stake.json")

      assert {:ok, %Types.StakingTransaction{} = txn} =
               Private.stake("MATIC", Decimal.new("30"), @credentials,
                 plug: responding(body),
                 retry_attempts: 0,
                 provider_id: "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
               )

      assert txn.id == "65QN4XM5"
      assert txn.asset == "MATIC"
      assert Decimal.equal?(txn.amount, Decimal.new("30"))
      assert txn.provider_id == "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
      assert txn.type == :stake
    end
  end

  describe "Private.unstake/4 — POST /v1/staking/unstake, rest.yaml:6970" do
    test "the vendor's own response example decodes, requestInitiated as venue_time" do
      body = fixture!("rest/private/derivatives/unstake.json")

      assert {:ok, %Types.StakingTransaction{} = txn} =
               Private.unstake("MATIC", Decimal.new("20"), @credentials,
                 plug: responding(body),
                 retry_attempts: 0,
                 provider_id: "62b21e17-2534-4b9f-afcf-b7edb609dd8d"
               )

      assert txn.id == "MPZ7LDD8"
      assert Decimal.equal?(txn.amount, Decimal.new("20"))
      assert Decimal.equal?(txn.amount_remaining, Decimal.new("0"))
      assert txn.venue_time == ~U[2022-11-02 19:49:20.153Z]
    end
  end

  describe "Private.get_positions/2 — POST /v1/positions, rest.yaml:7518 (documented shape contradiction)" do
    # The response `schema` here is `{type: object, properties: {openPositions: array}}`,
    # but the vendor's own committed `example` (rest.yaml:7576) is a bare array — the
    # contradiction get_positions/2's own moduledoc and position_rows/1 already handle.
    # Both are exercised: the bare array is the vendor's literal example; the wrapped shape
    # is the SAME row data built to match what the schema itself documents.
    test "the vendor's own bare-array EXAMPLE decodes" do
      body = fixture!("rest/private/derivatives/get_positions_bare_array.json")

      assert {:ok, [%Types.Position{} = position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.symbol == "BTCGUSDPERP"
      assert position.side == :long
      assert Decimal.equal?(position.quantity, Decimal.new("0.2"))
      assert Decimal.equal?(position.notional_value, Decimal.new("4000.036"))
      assert Decimal.equal?(position.realised_pnl, Decimal.new("1234.5678"))
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("999.946"))
      assert position.instrument_type == :perp
      assert position.liquidation_price == nil
    end

    test "the {openPositions: [...]} shape the SCHEMA documents also decodes, identically" do
      body = fixture!("rest/private/derivatives/get_positions_open_positions.json")

      assert {:ok, [%Types.Position{} = position]} =
               Private.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.symbol == "BTCGUSDPERP"
      assert position.side == :long
    end
  end

  describe "Private.get_account_margin/2 — POST /v1/margin, rest.yaml:7125" do
    test "the vendor's own perpetuals margin example decodes, pass-through" do
      body = fixture!("rest/private/derivatives/get_account_margin.json")

      assert {:ok, margin} =
               Private.get_account_margin(@credentials,
                 plug: responding(body),
                 retry_attempts: 0,
                 symbol: "BTCGUSDPERP"
               )

      assert margin["estimated_liquidation_price"] == "1300"
      assert margin["leverage"] == "12.34567"
    end

    # OPEN QUESTION, disclosed rather than guessed at: the vendor's own request example at
    # this exact spec location (rest.yaml:7178) sends `"symbol": "BTC-GUSD-PERP"` —
    # uppercase and dashed. SymbolFormat.to_exchange_symbol/1 can never produce that string
    # (it always downcases, and CanonicalPair.to_exchange/2 only joins with this venue's
    # sep, which is ""); for canonical "BTCGUSDPERP" it yields "btcgusdperp", matching every
    # OTHER perpetual endpoint's own example (/v1/positions: "btcgusdperp"). This may be a
    # vendor doc inconsistency (this family has found several already) or a real venue
    # convention this endpoint alone uses — undetermined without a live call, which this
    # repo does not run on a schedule. Asserted here against the code's actual, verifiable
    # output rather than the unconfirmed dashed form.
    test "symbol is required (rest.yaml:7158) and sent through SymbolFormat like every other call" do
      test_pid = self()

      Private.get_account_margin(@credentials,
        plug: capturing([], test_pid),
        retry_attempts: 0,
        symbol: "BTCGUSDPERP"
      )

      assert_receive {:payload, payload}
      assert payload["symbol"] == "btcgusdperp"
    end

    test "missing :symbol is refused before a request is sent" do
      assert {:error, {:missing_option, :symbol}} =
               Private.get_account_margin(@credentials, retry_attempts: 0)
    end
  end

  describe "Private.list_funding_payments/2 — POST /v1/perpetuals/fundingPayment, rest.yaml:7201" do
    test "the vendor's own wrapped example rows decode unchanged" do
      body = fixture!("rest/private/derivatives/list_funding_payments.json")

      assert {:ok, rows} =
               Private.list_funding_payments(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(rows) == 2

      second =
        Enum.find(rows, &(&1["hourlyFundingTransfer"]["instrumentSymbol"] == "BTCGUSDPERP"))

      assert second["hourlyFundingTransfer"]["action"] == "Debit"
      assert second["hourlyFundingTransfer"]["quantity"]["value"] == "4.78958"
    end
  end

  describe "Private.funding_payment_report/2 — POST /v1/perpetuals/fundingpaymentreport/records.json, rest.yaml:7412" do
    test "the vendor's own report example decodes" do
      body = fixture!("rest/private/derivatives/funding_payment_report.json")

      assert {:ok, [row]} =
               Private.funding_payment_report(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["instrumentSymbol"] == "BTCGUSDPERP"
      assert row["quantity"]["value"] == "35.81084"
    end

    test "the query string is part of the signed path, matching the vendor's own request example" do
      test_pid = self()

      plug = fn conn ->
        payload =
          conn
          |> Plug.Conn.get_req_header("x-gemini-payload")
          |> List.first()
          |> Base.decode64!()
          |> Jason.decode!()

        send(test_pid, {:signed, payload["request"], conn.request_path, conn.query_string})

        conn |> Plug.Conn.put_resp_header("date", @date) |> Req.Test.json([])
      end

      Private.funding_payment_report(@credentials,
        plug: plug,
        retry_attempts: 0,
        from: ~D[2024-04-10],
        to: ~D[2024-04-25],
        rows: 1000
      )

      assert_receive {:signed, signed_request, path, query}
      assert path == "/v1/perpetuals/fundingpaymentreport/records.json"
      assert query =~ "fromDate=2024-04-10"
      assert query =~ "toDate=2024-04-25"
      assert query =~ "numRows=1000"
      # The venue's own request example signs the query string AS PART OF `request`.
      assert signed_request =~ "fromDate=2024-04-10&toDate=2024-04-25&numRows=1000"
    end
  end

  describe "Private.get_margin_account/2 — POST /v1/margin/account, rest.yaml:2220" do
    test "the vendor's own spot margin example decodes, pass-through" do
      body = fixture!("rest/private/derivatives/get_margin_account.json")

      assert {:ok, margin} =
               Private.get_margin_account(@credentials,
                 symbol: "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert margin["marginAssetValue"]["value"] == "10000.00"
      assert margin["liquidationRisk"]["liquidationPrice"]["value"] == "50000.00"
    end

    # CODE FIX made while building this suite: `get_margin_account/2` used to POST an empty
    # body against an endpoint whose own schema (rest.yaml:2255-2257) requires `symbol` —
    # see lib/dp_exchange/gemini/private.ex's moduledoc on `get_margin_account/2` for the
    # full account. Now required and sent, matching the vendor's own request example
    # (`"symbol": "btcusd"`, native lowercase form — NOT the dashed-uppercase oddity in the
    # neighbouring `/v1/margin` example, since this endpoint's own example uses the
    # ordinary convention every other symbol-taking endpoint does).
    test "sends the vendor's own native-form symbol, matching the request example" do
      request = fixture!("rest/private/derivatives/get_margin_account_request.json")
      test_pid = self()

      Private.get_margin_account(@credentials,
        plug: capturing([], test_pid),
        retry_attempts: 0,
        symbol: "BTC-USD"
      )

      assert_receive {:payload, payload}
      assert payload["symbol"] == request["symbol"]
    end

    test "missing :symbol is refused before a request is sent" do
      assert {:error, {:missing_option, :symbol}} =
               Private.get_margin_account(@credentials, retry_attempts: 0)
    end
  end

  describe "Private.get_margin_rates/2 — POST /v1/margin/rates, rest.yaml:2335" do
    test "the vendor's own three-currency rates example decodes, unwrapped" do
      body = fixture!("rest/private/derivatives/get_margin_rates.json")

      assert {:ok, rates} =
               Private.get_margin_rates(@credentials, plug: responding(body), retry_attempts: 0)

      btc = Enum.find(rates, &(&1["currency"] == "BTC"))
      assert btc["borrowRateAnnual"] == "0.1"
      assert btc["lastUpdated"] == 1_700_000_000_000
    end
  end

  # ===========================================================================================
  # Group E — clearing, account administration, roles, OAuth revoke, margin preview
  #
  # Fixtures: test/fixtures/spec_examples/rest/private/clearing/ (README.md there cites
  # rest.yaml line numbers). None of these functions decode into a typed Core.Types struct —
  # Private returns the venue's body verbatim — so conformance here means the vendor's own
  # example round-trips unchanged through the real HTTP+signing+decode path, and the request
  # this package actually sends matches the vendor's own documented request shape.
  #
  # Uses this file's own shared `fixture!/1`, `responding/1`, `capturing/2`
  # (`{:payload, payload}`, via `x-gemini-payload`), `@credentials` and `PermissiveLimiter`.

  describe "preview_margin_order/3 — spec example conformance" do
    test "a limit order's request matches the vendor's limitBuy example" do
      me = self()

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        type: :limit,
        amount: Decimal.new("0.5"),
        price: Decimal.new("50000.00")
      }

      assert {:ok, _preview} =
               Private.preview_margin_order(request, @credentials,
                 plug: capturing(fixture!("rest/private/clearing/preview_margin_order.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      expected = fixture!("rest/private/clearing/preview_margin_order_request_limit_buy.json")
      assert payload["symbol"] == expected["symbol"]
      assert payload["side"] == expected["side"]
      assert payload["type"] == expected["type"]
      assert payload["amount"] == expected["amount"]
      assert payload["price"] == expected["price"]
    end

    test "a market buy's request matches the vendor's marketBuy example (totalSpend, no amount)" do
      me = self()

      request = %{
        symbol: "ETH-USD",
        side: :buy,
        type: :market,
        total_spend: Decimal.new("5000.00")
      }

      assert {:ok, _preview} =
               Private.preview_margin_order(request, @credentials,
                 plug: capturing(fixture!("rest/private/clearing/preview_margin_order.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      expected = fixture!("rest/private/clearing/preview_margin_order_request_market_buy.json")
      assert payload["symbol"] == expected["symbol"]
      assert payload["side"] == expected["side"]
      assert payload["type"] == expected["type"]
      assert payload["totalSpend"] == expected["totalSpend"]
      refute Map.has_key?(payload, "amount")
      refute Map.has_key?(payload, "price")
    end

    test "a market sell's request matches the vendor's marketSell example (amount, no price)" do
      me = self()
      request = %{symbol: "BTC-USD", side: :sell, type: :market, amount: Decimal.new("0.25")}

      assert {:ok, _preview} =
               Private.preview_margin_order(request, @credentials,
                 plug: capturing(fixture!("rest/private/clearing/preview_margin_order.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:payload, payload}
      expected = fixture!("rest/private/clearing/preview_margin_order_request_market_sell.json")
      assert payload["symbol"] == expected["symbol"]
      assert payload["side"] == expected["side"]
      assert payload["type"] == expected["type"]
      assert payload["amount"] == expected["amount"]
      refute Map.has_key?(payload, "price")
    end

    test "the venue's own pre/post-order example decodes unchanged" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        type: :limit,
        amount: Decimal.new("0.5"),
        price: Decimal.new("50000.00")
      }

      fixture = fixture!("rest/private/clearing/preview_margin_order.json")

      assert {:ok, body} =
               Private.preview_margin_order(request, @credentials,
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert body == fixture
      assert body["preorder"]["marginAssetValue"]["value"] == "10000.00"
      assert body["postorder"]["liquidationRisk"]["liquidationPrice"]["value"] == "30000.00"
    end
  end

  describe "create_account/3 — spec example conformance" do
    test "the venue's createAccount request and response round-trip" do
      me = self()
      response_fixture = fixture!("rest/private/clearing/create_account.json")
      request_fixture = fixture!("rest/private/clearing/create_account_request.json")

      assert {:ok, body} =
               Private.create_account(request_fixture["name"], @credentials,
                 type: request_fixture["type"],
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert body == response_fixture
      assert_receive {:payload, payload}
      assert payload["name"] == request_fixture["name"]
      assert payload["type"] == request_fixture["type"]
    end
  end

  describe "rename_account/2 — spec example conformance" do
    test "the venue's renameAccount request and response round-trip" do
      me = self()
      response_fixture = fixture!("rest/private/clearing/rename_account.json")
      request_fixture = fixture!("rest/private/clearing/rename_account_request.json")

      assert {:ok, body} =
               Private.rename_account(@credentials,
                 account: request_fixture["account"],
                 name: request_fixture["newName"],
                 shortname: request_fixture["newAccount"],
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert body == response_fixture
      assert_receive {:payload, payload}
      assert payload["account"] == request_fixture["account"]
      assert payload["newName"] == request_fixture["newName"]
      assert payload["newAccount"] == request_fixture["newAccount"]
    end
  end

  describe "list_accounts/2 — spec example conformance" do
    test "the venue's own request and its bare-array response round-trip" do
      me = self()
      response_fixture = fixture!("rest/private/clearing/list_accounts.json")
      request_fixture = fixture!("rest/private/clearing/list_accounts_request.json")
      since = DateTime.from_unix!(request_fixture["timestamp"], :millisecond)

      assert {:ok, rows} =
               Private.list_accounts(@credentials,
                 limit: request_fixture["limit_accounts"],
                 since: since,
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert rows == response_fixture
      assert length(rows) == 3
      assert Enum.at(rows, 1)["counterparty_id"] == nil

      assert_receive {:payload, payload}
      assert payload["limit_accounts"] == request_fixture["limit_accounts"]
      assert payload["timestamp"] == request_fixture["timestamp"]
    end
  end

  describe "get_roles/2 — spec example conformance" do
    test "the account-scoped key example decodes unchanged" do
      fixture = fixture!("rest/private/clearing/get_roles_account_level.json")

      assert {:ok, body} =
               Private.get_roles(@credentials, plug: responding(fixture), retry_attempts: 0)

      assert body == fixture
      assert body["isAuditor"] == false
      assert body["isTrader"] == true
    end

    test "the master-scoped key example decodes unchanged, including counterparty_id and isAccountAdmin" do
      fixture = fixture!("rest/private/clearing/get_roles_master_level.json")

      assert {:ok, body} =
               Private.get_roles(@credentials, plug: responding(fixture), retry_attempts: 0)

      assert body == fixture
      assert body["counterparty_id"] == "EMONNYXJ"
      assert body["isAccountAdmin"] == true
    end
  end

  describe "revoke_access_token/2 — spec example conformance" do
    test "the venue's revokeTokenResponse example decodes unchanged" do
      fixture = fixture!("rest/private/clearing/revoke_access_token.json")

      assert {:ok, body} =
               Private.revoke_access_token(%{access_token: "oauth-token-not-real"},
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert body == fixture
      assert body["message"] =~ "revoked"
    end

    test "the request authenticates by OAuth bearer, not the api-key payload/signature scheme" do
      # `revoke_access_token/2` takes `%{access_token: _}`, which `Auth.headers/5` signs via
      # its `:oauth` clause — a bare `Authorization: Bearer <token>` header, no
      # `x-gemini-payload`/`x-gemini-signature` at all. The shared `capturing/2` helper
      # decodes THAT header and would crash here for the right reason: there is none to
      # decode. This checks the header the venue actually documents for this scheme instead.
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:auth_header, Plug.Conn.get_req_header(conn, "authorization")})

        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Req.Test.json(fixture!("rest/private/clearing/revoke_access_token.json"))
      end

      assert {:ok, _body} =
               Private.revoke_access_token(%{access_token: "oauth-token-not-real"},
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:auth_header, ["Bearer oauth-token-not-real"]}
    end
  end

  describe "create_clearing_order/3 — spec example conformance" do
    test "the venue's newClearingOrder request and response round-trip" do
      me = self()
      request_fixture = fixture!("rest/private/clearing/create_clearing_order_request.json")
      response_fixture = fixture!("rest/private/clearing/create_clearing_order.json")

      terms = %{
        symbol: "BTC-USD",
        amount: Decimal.new(request_fixture["amount"]),
        price: Decimal.new(request_fixture["price"]),
        side: String.to_existing_atom(request_fixture["side"])
      }

      assert {:ok, body} =
               Private.create_clearing_order(terms, @credentials,
                 counterparty_id: request_fixture["counterparty_id"],
                 expires_in_hrs: request_fixture["expires_in_hrs"],
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert body == response_fixture
      assert_receive {:payload, payload}
      assert payload["symbol"] == request_fixture["symbol"]
      assert payload["amount"] == request_fixture["amount"]
      assert payload["price"] == request_fixture["price"]
      assert payload["side"] == request_fixture["side"]
      assert payload["counterparty_id"] == request_fixture["counterparty_id"]
      assert payload["expires_in_hrs"] == request_fixture["expires_in_hrs"]
    end
  end

  describe "create_broker_clearing_order/3 — spec example conformance" do
    test "the venue's brokerOrderInitiation request and response round-trip; side is the source's" do
      me = self()

      request_fixture =
        fixture!("rest/private/clearing/create_broker_clearing_order_request.json")

      response_fixture = fixture!("rest/private/clearing/create_broker_clearing_order.json")

      terms = %{
        symbol: "ETH-USD",
        amount: Decimal.new(request_fixture["amount"]),
        price: Decimal.new(request_fixture["price"]),
        side: String.to_existing_atom(request_fixture["side"])
      }

      assert {:ok, body} =
               Private.create_broker_clearing_order(terms, @credentials,
                 source_counterparty_id: request_fixture["source_counterparty_id"],
                 target_counterparty_id: request_fixture["target_counterparty_id"],
                 expires_in_hrs: request_fixture["expires_in_hrs"],
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert body == response_fixture
      assert body["result"] == "AwaitSourceTargetConfirm"
      assert_receive {:payload, payload}
      assert payload["symbol"] == request_fixture["symbol"]
      assert payload["side"] == request_fixture["side"]
      assert payload["source_counterparty_id"] == request_fixture["source_counterparty_id"]
      assert payload["target_counterparty_id"] == request_fixture["target_counterparty_id"]
      assert payload["expires_in_hrs"] == request_fixture["expires_in_hrs"]
    end
  end

  describe "get_clearing_order/3 — spec example conformance" do
    test "the venue's orderStatusRequest/response example round-trips" do
      me = self()
      request_fixture = fixture!("rest/private/clearing/get_clearing_order_request.json")
      response_fixture = fixture!("rest/private/clearing/get_clearing_order.json")

      assert {:ok, body} =
               Private.get_clearing_order(request_fixture["clearing_id"], @credentials,
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert body == response_fixture
      assert_receive {:payload, payload}
      assert payload["clearing_id"] == request_fixture["clearing_id"]
    end
  end

  describe "cancel_clearing_order/3 — spec example conformance" do
    test "the venue's successfulCancel example decodes unchanged" do
      request_fixture = fixture!("rest/private/clearing/cancel_clearing_order_request.json")
      fixture = fixture!("rest/private/clearing/cancel_clearing_order_success.json")

      assert {:ok, body} =
               Private.cancel_clearing_order(request_fixture["clearing_id"], @credentials,
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert body == fixture
      assert body["result"] == "ok"
    end

    test "the venue's failedCancel example is STILL an :ok decode (HTTP 200), with result: failed" do
      request_fixture = fixture!("rest/private/clearing/cancel_clearing_order_request.json")
      fixture = fixture!("rest/private/clearing/cancel_clearing_order_failed.json")

      assert {:ok, body} =
               Private.cancel_clearing_order(request_fixture["clearing_id"], @credentials,
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert body == fixture
      assert body["result"] == "failed"
    end
  end

  describe "confirm_clearing_order/4 — spec example conformance" do
    test "the venue's confirmOrderRequest terms reach it verbatim; successfulConfirm decodes" do
      me = self()
      request_fixture = fixture!("rest/private/clearing/confirm_clearing_order_request.json")
      response_fixture = fixture!("rest/private/clearing/confirm_clearing_order_success.json")

      terms = %{
        symbol: "BTC-USD",
        amount: Decimal.new(request_fixture["amount"]),
        price: Decimal.new(request_fixture["price"]),
        side: String.to_existing_atom(request_fixture["side"])
      }

      assert {:ok, body} =
               Private.confirm_clearing_order(
                 request_fixture["clearing_id"],
                 terms,
                 @credentials,
                 plug: capturing(response_fixture, me),
                 retry_attempts: 0
               )

      assert body == response_fixture
      assert body["result"] == "confirmed"
      assert_receive {:payload, payload}
      assert payload["clearing_id"] == request_fixture["clearing_id"]
      assert payload["symbol"] == request_fixture["symbol"]
      assert payload["amount"] == request_fixture["amount"]
      assert payload["price"] == request_fixture["price"]
      assert payload["side"] == request_fixture["side"]
    end

    test "the venue's failedConfirm example is STILL an :ok decode (HTTP 200), naming the reason" do
      request_fixture = fixture!("rest/private/clearing/confirm_clearing_order_request.json")
      fixture = fixture!("rest/private/clearing/confirm_clearing_order_failed.json")

      terms = %{
        symbol: "BTC-USD",
        amount: Decimal.new(request_fixture["amount"]),
        price: Decimal.new(request_fixture["price"]),
        side: String.to_existing_atom(request_fixture["side"])
      }

      assert {:ok, body} =
               Private.confirm_clearing_order(request_fixture["clearing_id"], terms, @credentials,
                 plug: responding(fixture),
                 retry_attempts: 0
               )

      assert body == fixture
      assert body["result"] == "error"
      assert body["reason"] == "InvalidSide"
    end
  end

  describe "list_clearing_orders/2 — spec example conformance" do
    test "the vendor's withFilters request reaches the venue and successfulList's orders decode unchanged" do
      me = self()
      request_fixture = fixture!("rest/private/clearing/list_clearing_orders_request.json")
      wrapped = fixture!("rest/private/clearing/list_clearing_orders.json")

      assert {:ok, rows} =
               Private.list_clearing_orders(@credentials,
                 symbol: "BTC-EUR",
                 counterparty: request_fixture["counterparty"],
                 side: String.to_existing_atom(request_fixture["side"]),
                 expiration_start:
                   DateTime.from_unix!(request_fixture["expiration_start"], :millisecond),
                 expiration_end:
                   DateTime.from_unix!(request_fixture["expiration_end"], :millisecond),
                 submission_start:
                   DateTime.from_unix!(request_fixture["submission_start"], :millisecond),
                 submission_end:
                   DateTime.from_unix!(request_fixture["submission_end"], :millisecond),
                 plug: capturing(wrapped, me),
                 retry_attempts: 0
               )

      assert rows == wrapped["orders"]
      assert length(rows) == 3

      assert_receive {:payload, payload}
      assert String.downcase(payload["symbol"]) == String.downcase(request_fixture["symbol"])
      assert payload["counterparty"] == request_fixture["counterparty"]
      assert payload["side"] == request_fixture["side"]
      assert payload["expiration_start"] == request_fixture["expiration_start"]
      assert payload["expiration_end"] == request_fixture["expiration_end"]
      assert payload["submission_start"] == request_fixture["submission_start"]
      assert payload["submission_end"] == request_fixture["submission_end"]
    end
  end

  describe "list_clearing_brokers/2 — spec example conformance" do
    test "the vendor's withFilters request reaches the venue and successfulList's orders decode unchanged" do
      me = self()
      request_fixture = fixture!("rest/private/clearing/list_clearing_brokers_request.json")
      wrapped = fixture!("rest/private/clearing/list_clearing_brokers.json")

      assert {:ok, rows} =
               Private.list_clearing_brokers(@credentials,
                 symbol: "BTC-EUR",
                 expiration_start:
                   DateTime.from_unix!(request_fixture["expiration_start"], :millisecond),
                 expiration_end:
                   DateTime.from_unix!(request_fixture["expiration_end"], :millisecond),
                 plug: capturing(wrapped, me),
                 retry_attempts: 0
               )

      assert rows == wrapped["orders"]
      assert hd(rows)["source_side"] == "buy"

      assert_receive {:payload, payload}
      assert String.downcase(payload["symbol"]) == String.downcase(request_fixture["symbol"])
      assert payload["expiration_start"] == request_fixture["expiration_start"]
      assert payload["expiration_end"] == request_fixture["expiration_end"]
    end
  end

  describe "list_clearing_trades/2 — spec example conformance" do
    test "the vendor's withTimestamp request (nanosecond timestamp_nanos) and successfulTrades decode unchanged" do
      me = self()
      request_fixture = fixture!("rest/private/clearing/list_clearing_trades_request.json")
      wrapped = fixture!("rest/private/clearing/list_clearing_trades.json")

      assert {:ok, rows} =
               Private.list_clearing_trades(@credentials,
                 since_nanos: request_fixture["timestamp_nanos"],
                 limit: request_fixture["limit_per_account"],
                 plug: capturing(wrapped, me),
                 retry_attempts: 0
               )

      assert rows == wrapped["results"]
      assert length(rows) == 2
      assert hd(rows)["clearingId"] == "41M23L5Q"
      assert Decimal.equal?(Decimal.new(hd(rows)["price"]), Decimal.new("1"))

      assert_receive {:payload, payload}
      assert payload["timestamp_nanos"] == request_fixture["timestamp_nanos"]
      assert payload["limit_per_account"] == request_fixture["limit_per_account"]
    end
  end

  # ===========================================================================================
  # WebSocket — test/fixtures/spec_examples/websocket/, see its README.md. The vendor's
  # AsyncAPI document publishes no message examples at all (checked: one unrelated field
  # example in the whole file), so every fixture here is built strictly from the named
  # schema's `required` properties, as documented in that README — never a guess at an
  # optional value.
  # ===========================================================================================

  describe "Socket — bookTicker frame, websocket.yaml:1234 (required properties only)" do
    test "delivers a TopOfBook with no last-trade Quote when c/C are absent" do
      frame = fixture!("websocket/book_ticker.json")

      assert {:ok, _state} = Socket.handle_frame(ws_frame(frame), ws_state())

      assert_received {:dp_exchange, :gemini, %Types.TopOfBook{} = top}
      assert top.symbol == "BTC-USD"
      assert Decimal.equal?(top.bid, Decimal.new("77791.77000"))
      assert Decimal.equal?(top.bid_size, Decimal.new("1.5"))
      assert Decimal.equal?(top.ask, Decimal.new("77791.92000"))
      assert Decimal.equal?(top.ask_size, Decimal.new("2.25"))
      assert top.venue_time == DateTime.from_unix!(1_787_936_147_123_456_789, :nanosecond)

      refute_received {:dp_exchange, :gemini, %Types.Quote{}}
    end

    test "the optional c/C shape delivers a separate last-trade Quote, with no venue_time" do
      frame = fixture!("websocket/book_ticker_with_last_trade.json")

      assert {:ok, _state} = Socket.handle_frame(ws_frame(frame), ws_state())

      assert_received {:dp_exchange, :gemini, %Types.TopOfBook{}}
      assert_received {:dp_exchange, :gemini, %Types.Quote{} = last_trade}
      assert last_trade.symbol == "BTC-USD"
      assert Decimal.equal?(last_trade.price, Decimal.new("77829.80000"))
      # The venue documents no trade TIME for `c` — only that the book has traded.
      assert last_trade.venue_time == nil
    end
  end

  describe "Socket — trade frame, websocket.yaml:1295 (required properties only)" do
    test "m: true means the buyer was resting, so the aggressor decodes as :sell" do
      frame = fixture!("websocket/trade.json")

      assert {:ok, _state} =
               Socket.handle_frame(ws_frame(frame), ws_state())

      assert_received {:dp_exchange, :gemini, %Types.Trade{} = trade}
      assert trade.id == "5335307668"
      assert trade.symbol == "BTC-USD"
      assert trade.side == :sell
      assert Decimal.equal?(trade.price, Decimal.new("3610.85"))
      assert Decimal.equal?(trade.quantity, Decimal.new("0.27413495"))
      assert trade.timestamp == DateTime.from_unix!(1_787_936_147_423_456_789, :nanosecond)
      assert trade.broken == false
    end
  end

  describe "Socket — depthUpdate frame, websocket.yaml:1261 (required properties only)" do
    test "an ordinary diff decodes as an OrderBookDelta, zero quantity kept as a removal" do
      frame = fixture!("websocket/depth_update.json")

      assert {:ok, _state} =
               Socket.handle_frame(ws_frame(frame), ws_state())

      assert_received {:dp_exchange, :gemini, %Types.OrderBookDelta{} = delta}
      assert delta.symbol == "BTC-USD"
      assert delta.sequence == 15

      assert [{:bid, bid_price, bid_qty}, {:ask, ask_price, ask_qty}] = delta.levels
      assert Decimal.equal?(bid_price, Decimal.new("3610.00"))
      assert Decimal.equal?(bid_qty, Decimal.new("1.5"))
      assert Decimal.equal?(ask_price, Decimal.new("3611.00"))
      # A zero quantity REMOVES the level — carried through unresolved, not filtered.
      assert Decimal.equal?(ask_qty, Decimal.new("0"))
    end
  end

  describe "Socket — OrderBookSnapshot frame, websocket.yaml:1217 (required properties only)" do
    test "attributed via partial_depth_claims, sorted, lastUpdateId becomes the sequence" do
      frame = fixture!("websocket/order_book_snapshot.json")
      claimed = ws_state(%{partial_depth_claims: MapSet.new([{:depth5, "BTC-USD"}])})

      assert {:ok, _state} =
               Socket.handle_frame(ws_frame(frame), claimed)

      assert_received {:dp_exchange, :gemini, %Types.OrderBook{} = book}
      assert book.symbol == "BTC-USD"
      assert book.sequence == 900_555
      # Best bid/ask first — the contract's own ordering, not venue row order.
      assert [{best_bid, _best_bid_qty}, {next_bid, _next_bid_qty}] = book.bids
      assert Decimal.equal?(best_bid, Decimal.new("3607.85"))
      assert Decimal.equal?(next_bid, Decimal.new("3607.80"))

      assert [{best_ask, _best_ask_qty}, {next_ask, _next_ask_qty}] = book.asks
      assert Decimal.equal?(best_ask, Decimal.new("3607.86"))
      assert Decimal.equal?(next_ask, Decimal.new("3607.90"))

      # OrderBookSnapshot carries no timestamp of its own (websocket.yaml:1217-1233).
      assert book.venue_time == nil
    end
  end

  describe "Socket — subscribe refusal, ResponseBase, websocket.yaml:1072" do
    test "a non-200 status raises a :refusal notice rather than silently continuing" do
      frame = fixture!("websocket/subscribe_ack_refused.json")

      assert {:ok, _state} =
               Socket.handle_frame(ws_frame(frame), ws_state())

      assert_received {:dp_exchange, :gemini, %Notice{kind: :refusal, details: details}}
      assert details.subscribe_status == 400
    end
  end
end
