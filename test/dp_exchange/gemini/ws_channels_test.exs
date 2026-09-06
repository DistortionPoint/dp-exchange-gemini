defmodule DpExchange.Gemini.WsChannelsTest do
  @moduledoc """
  The socket surface, from the vendor's AsyncAPI document rather than its Stream Matrix.

  Three assertions carry the weight, and each guards a bug that produces a plausible wrong
  answer rather than a failure:

  * **`m` is "buyer is the maker"**, which is the *opposite* of the REST tape's `type`. The
    same venue reports the side two different ways on two transports.
  * **Timestamps are nanoseconds.** Read as milliseconds, an event lands fifty thousand
    years out; read as seconds, it still looks like a date.
  * **A depth frame is a diff**, and `U..u` is the only way to know none were missed.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Gemini.{WsChannels, WsDecode}

  describe "the surface the Stream Matrix does not show" do
    # `WsChannels` exposes no "list every channel" accessor — nothing in this package's own
    # `lib/` ever needed one, and `Core.AdapterContract`'s "16. internal wiring" assertion
    # refuses an accessor whose only caller is a test. Existence is checked here through
    # `requires_credential?/1` instead, which every known channel answers with a boolean and
    # every unknown one answers with `{:error, {:unknown_channel, _}}` — a real accessor this
    # package's own `Socket.subscribe/3` depends on, not one kept alive for this test alone.
    @known_channels [
      :connection,
      :book_ticker,
      :trade,
      :contract_status,
      :depth,
      :depth_fast,
      :depth5,
      :depth5_fast,
      :depth10,
      :depth10_fast,
      :depth20,
      :depth20_fast,
      :orders_account,
      :orders_session,
      :balances_account,
      :balances_account_snapshot,
      :positions_account,
      :positions_account_snapshot,
      :settlements_account,
      :request_for_quote,
      :request_for_quote_account,
      :request_for_quote_session
    ]

    test "the AsyncAPI document defines twenty-two channels" do
      # The rendered matrix shows eleven families. Reading it as the surface is what hid the
      # other ten — the whole requestForQuote family, connection, both snapshots and the
      # four Fast variants.
      assert length(@known_channels) == 22

      for channel <- @known_channels do
        assert is_boolean(WsChannels.requires_credential?(channel)), "#{channel} is missing"
      end
    end

    test "the ten the matrix omits are all present" do
      for channel <- [
            :connection,
            :balances_account_snapshot,
            :positions_account_snapshot,
            :depth_fast,
            :depth5_fast,
            :depth10_fast,
            :depth20_fast,
            :request_for_quote,
            :request_for_quote_account,
            :request_for_quote_session
          ] do
        assert is_boolean(WsChannels.requires_credential?(channel)), "#{channel} is missing"
      end
    end
  end

  describe "addresses are built, not guessed" do
    test "a per-symbol channel fills the symbol in" do
      assert {:ok, "btcusd@bookTicker"} = WsChannels.address(:book_ticker, "btcusd")
      assert {:ok, "btcusd@trade"} = WsChannels.address(:trade, "btcusd")
      assert {:ok, "btcusd@depth5"} = WsChannels.address(:depth5, "btcusd")
    end

    test "the interval is part of the address, not the channel name" do
      # A package assembling "{symbol}@depthFast" from the channel's own name subscribes to
      # nothing and sees silence rather than an error.
      assert {:ok, "btcusd@depth@100ms"} = WsChannels.address(:depth_fast, "btcusd")
      assert {:ok, "balances@account@1s"} = WsChannels.address(:balances_account_snapshot)
      assert {:ok, "positions@account@1s"} = WsChannels.address(:positions_account_snapshot)
    end

    test "a per-account channel takes no symbol" do
      # orders@account with a symbol appended is not a channel the venue has, and
      # subscribing to it produces silence rather than a refusal.
      assert {:ok, "orders@account"} = WsChannels.address(:orders_account)

      assert {:error, {:channel_takes_no_symbol, :orders_account}} =
               WsChannels.address(:orders_account, "btcusd")
    end

    test "a per-symbol channel with no symbol is an error" do
      assert {:error, {:channel_requires_symbol, :trade}} = WsChannels.address(:trade)
    end

    test "an unknown channel is an error, not a guessed address" do
      assert {:error, {:unknown_channel, :candles}} = WsChannels.address(:candles, "btcusd")
    end
  end

  describe "public and private are not interchangeable" do
    test "the account channels need a credential" do
      for channel <- [
            :orders_account,
            :orders_session,
            :balances_account,
            :positions_account,
            :settlements_account,
            :request_for_quote_account,
            :request_for_quote_session
          ] do
        assert WsChannels.requires_credential?(channel), "#{channel} should require auth"
      end
    end

    test "the market-data channels do not" do
      for channel <- [:book_ticker, :trade, :depth, :depth5, :contract_status] do
        refute WsChannels.requires_credential?(channel), "#{channel} should not require auth"
      end
    end

    test "the public requestForQuote channel is public and its two siblings are not" do
      refute WsChannels.requires_credential?(:request_for_quote)
      assert WsChannels.requires_credential?(:request_for_quote_account)
    end
  end

  describe "`m` is the maker flag, and it is the opposite of the REST tape's side" do
    @trade %{
      "E" => 1_787_936_147_000_000_000,
      "s" => "btcusd",
      "t" => 5_335_307_668,
      "p" => "3610.85",
      "q" => "0.27413495",
      "m" => true
    }

    test "buyer-is-maker means the SELLER aggressed" do
      # REST /v1/trades `type` is the taker's side. WS `m` is whether the buyer was the
      # maker. Carrying m straight through as a buy inverts every trade on the socket while
      # agreeing with the REST field name.
      assert {:ok, trade} = WsDecode.to_trade(@trade, "BTC-USD")

      assert trade.side == :sell
      refute trade.side == :buy
    end

    test "buyer-is-taker means the buyer aggressed" do
      assert {:ok, trade} = WsDecode.to_trade(%{@trade | "m" => false}, "BTC-USD")
      assert trade.side == :buy
    end

    test "a frame that does not say leaves the side nil" do
      assert {:ok, trade} = WsDecode.to_trade(Map.delete(@trade, "m"), "BTC-USD")
      assert trade.side == nil
    end

    test "the rest of the trade is the venue's own" do
      assert {:ok, %Types.Trade{} = trade} = WsDecode.to_trade(@trade, "BTC-USD")

      assert trade.id == "5335307668"
      assert Decimal.equal?(trade.price, Decimal.new("3610.85"))
      assert Decimal.equal?(trade.quantity, Decimal.new("0.27413495"))
      refute trade.broken
      assert trade.provider == :gemini
    end
  end

  describe "timestamps are nanoseconds" do
    test "a trade's time is read at nanosecond scale" do
      # Read as milliseconds this lands ~50,000 years out. Read as seconds it still looks
      # like a date, which is worse.
      assert {:ok, trade} =
               WsDecode.to_trade(
                 %{"E" => 1_787_936_147_000_000_000, "p" => "1", "q" => "1", "m" => false},
                 "BTC-USD"
               )

      assert trade.timestamp.year == 2026
    end

    test "an undated frame is refused rather than stamped locally" do
      assert {:error, :missing_venue_timestamp} =
               WsDecode.to_trade(%{"p" => "1", "q" => "1", "m" => false}, "BTC-USD")
    end

    test "a book ticker carries a real venue_time, distinct from observed_at" do
      observed = ~U[2026-08-28 12:00:00Z]

      frame = %{
        "u" => 1,
        "E" => 1_787_936_147_000_000_000,
        "s" => "btcusd",
        "b" => "3610.00",
        "B" => "1.5",
        "a" => "3611.00",
        "A" => "2.0"
      }

      assert {:ok, %Types.TopOfBook{} = top} =
               WsDecode.to_top_of_book(frame, "BTC-USD", observed)

      assert Decimal.equal?(top.bid, Decimal.new("3610.00"))
      assert Decimal.equal?(top.bid_size, Decimal.new("1.5"))
      assert top.venue_time
      assert top.observed_at == observed
      refute top.venue_time == top.observed_at
    end
  end

  describe "depth frames are diffs, and the sequence range is the safety check" do
    test "a contiguous frame is not a gap" do
      assert WsDecode.depth_gap?(%{"U" => 11, "u" => 15}, 10) == false
    end

    test "a frame whose U skips ahead IS a gap — discard and resubscribe" do
      # A package applying diffs without this builds a book that is silently wrong from the
      # first dropped frame onward, and every price in it stays real.
      assert WsDecode.depth_gap?(%{"U" => 20, "u" => 25}, 10) == true
    end

    test "an overlapping frame is not a gap" do
      assert WsDecode.depth_gap?(%{"U" => 8, "u" => 15}, 10) == false
    end

    test "nothing applied yet is never a gap" do
      assert WsDecode.depth_gap?(%{"U" => 500, "u" => 505}, nil) == false
    end

    test "a frame with no U is treated as a gap, because it cannot be checked" do
      # Continuing would apply it blind.
      assert WsDecode.depth_gap?(%{"u" => 15}, 10) == true
    end

    test "a zero quantity is returned, not filtered — it is a DELETE" do
      # The vendor: "A quantity of zero removes that price level in differential depth
      # updates." Filtering here would drop the deletion and leave a level nobody quotes
      # standing forever.
      changes = WsDecode.depth_changes(%{"b" => [["3610.00", "0"]], "a" => []})

      assert [{price, quantity}] = changes.bids
      assert Decimal.equal?(price, Decimal.new("3610.00"))
      assert Decimal.equal?(quantity, Decimal.new("0"))
    end
  end

  describe "to_order_book_delta/2 side-tags depth_changes/1's levels into one flat list" do
    @depth_frame %{
      "E" => 1_787_936_147_000_000_000,
      "s" => "btcusd",
      "U" => 11,
      "u" => 15,
      "b" => [["3610.00", "1.5"], ["3609.50", "0"]],
      "a" => [["3611.00", "0.5"]]
    }

    test "bids and asks land in one levels list, each tagged with its side" do
      assert {:ok, %Types.OrderBookDelta{} = delta} =
               WsDecode.to_order_book_delta(@depth_frame, "BTC-USD")

      assert delta.symbol == "BTC-USD"
      assert delta.provider == :gemini

      assert {:bid, price, quantity} =
               Enum.find(delta.levels, fn {side, price, _qty} ->
                 side == :bid and Decimal.equal?(price, Decimal.new("3610.00"))
               end)

      assert Decimal.equal?(price, Decimal.new("3610.00"))
      assert Decimal.equal?(quantity, Decimal.new("1.5"))

      # A zero quantity is a DELETE and is carried through unresolved — same rule as
      # `depth_changes/1` itself.
      assert Enum.any?(delta.levels, fn {side, price, qty} ->
               side == :bid and Decimal.equal?(price, Decimal.new("3609.50")) and
                 Decimal.equal?(qty, Decimal.new("0"))
             end)

      assert Enum.any?(delta.levels, fn {side, price, qty} ->
               side == :ask and Decimal.equal?(price, Decimal.new("3611.00")) and
                 Decimal.equal?(qty, Decimal.new("0.5"))
             end)
    end

    test "`u` becomes the delta's sequence — the same value depth_gap?/2 compares next" do
      assert {:ok, delta} = WsDecode.to_order_book_delta(@depth_frame, "BTC-USD")
      assert delta.sequence == 15
    end

    test "an undated diff is refused rather than stamped locally" do
      assert {:error, :missing_venue_timestamp} =
               WsDecode.to_order_book_delta(Map.delete(@depth_frame, "E"), "BTC-USD")
    end
  end

  describe "partial depth snapshots" do
    test "lastUpdateId becomes the book's sequence" do
      # A snapshot with no sequence cannot be ordered against a later one.
      frame = %{
        "lastUpdateId" => 4242,
        "bids" => [["3610.00", "1.5"], ["3609.50", "2.0"]],
        "asks" => [["3611.00", "0.5"]]
      }

      assert {:ok, %Types.OrderBook{} = book} =
               WsDecode.to_order_book(frame, "BTC-USD", ~U[2026-08-28 12:00:00Z])

      assert book.sequence == 4242
      assert length(book.bids) == 2
      assert length(book.asks) == 1
    end

    test "the snapshot carries no time of its own, so observed_at is used" do
      observed = ~U[2026-08-28 12:00:00Z]

      assert {:ok, book} =
               WsDecode.to_order_book(
                 %{"lastUpdateId" => 1, "bids" => [], "asks" => []},
                 "BTC-USD",
                 observed
               )

      assert book.timestamp == observed
    end
  end
end
