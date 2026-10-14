defmodule DpExchange.Gemini.RestTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Types}
  alias DpExchange.Gemini.Rest

  @moduletag :capture_log

  # A real limiter answering from configuration, injected through the same process-scoped
  # seam a consumer would use. Not a mock: nothing is stubbed and no call is verified.
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

  defp responding(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    date = Keyword.get(opts, :date, @date)

    fn conn ->
      conn = if date, do: Plug.Conn.put_resp_header(conn, "date", date), else: conn
      Req.Test.json(%{conn | status: status}, body)
    end
  end

  @ticker %{
    "bid" => "77791.77000",
    "ask" => "77791.92000",
    "last" => "77829.80000",
    "volume" => %{
      "BTC" => "183.72081422",
      "USD" => "14298954.22",
      "timestamp" => 1_787_936_340_000
    }
  }

  describe "get_price/2" do
    test "returns a Quote with Decimal numerics" do
      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("77829.80000"))
      assert quote_struct.provider == :gemini
      assert quote_struct.symbol == "BTC-USD"
    end

    test "a perpetual reports the symbol asked, not a mangled canonical (found 2026-10-10)" do
      # `to_canonical_symbol("btcgusd-perp")` is "BTCGUSD-PERP", which maps back to
      # "btcgusdperp". A perpetual has no canonical form, so the symbol asked is the answer.
      assert {:ok, %Types.Quote{symbol: "BTC-GUSD-PERP"}} =
               Rest.get_price("btc-gusd-perp", plug: responding(@ticker), retry_attempts: 0)
    end

    test "the book side comes back from get_top_of_book/2, not on the Quote" do
      # One payload, two facts. `Core.Types.Quote` has no bid or ask to put them on, which
      # is what stops a caller reading a resting order as a traded price.
      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(top.bid, Decimal.new("77791.77000"))
      assert Decimal.equal?(top.ask, Decimal.new("77791.92000"))
      assert top.symbol == "BTC-USD"
      assert top.observed_at
      refute Map.has_key?(top, :price)
    end

    test "venue_time is nil even when the reply carries a Date header (MD7)" do
      # The `Date` header is when the reply was served, not when the last trade happened.
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert quote_struct.venue_time == nil
      assert quote_struct.observed_at
    end

    test "a last price of zero or less is not a price (MD6)" do
      for last <- ["0", "0.00000", "-1.5"] do
        body = %{@ticker | "last" => last}

        assert {:error, {:non_positive_price, :price, ^last}} =
                 Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
      end
    end

    test "volume is the BASE asset's, recovered from the symbol" do
      # `/v1/pubticker` keys volume by currency code and reports both sides. Taking the
      # first key would give USD volume for a BTC-USD quote — a number 78,000 times too
      # large that still looks like a volume.
      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.volume, Decimal.new("183.72081422"))
      # "The 24 hour volume on the exchange": a rolling total (dp-exchange-core issue #42).
      assert quote_struct.volume_window == :rolling_24h
    end

    test "a non-numeric last price refuses the quote rather than delivering price: nil" do
      # Decimal.new/1 used to raise here; the fix must not trade a crash for a Quote whose
      # required :price is silently nil, which is the same substitution wearing a
      # different shape.
      body = %{@ticker | "last" => "null"}

      assert {:error, {:invalid_decimal, :price, "null"}} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "an empty-string last price refuses the quote" do
      body = %{@ticker | "last" => ""}

      assert {:error, {:invalid_decimal, :price, ""}} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "a response with NO Date header is nil, and never our clock" do
      # `observed_at` states freshness; `venue_time` is nil whatever the headers say.
      assert {:ok, quoted} =
               Rest.get_price("BTC-USD",
                 plug: responding(@ticker, date: nil),
                 retry_attempts: 0
               )

      assert quoted.venue_time == nil
      assert quoted.observed_at
      refute quoted.venue_time == quoted.observed_at
    end

    test "top of book venue_time is nil too, and a zero side is no resting order (MD6, MD7)" do
      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert top.venue_time == nil

      zero_bid = %{@ticker | "bid" => "0.00"}

      assert {:ok, %{bid: nil, ask: ask, venue_time: nil}} =
               Rest.get_top_of_book("BTC-USD", plug: responding(zero_bid), retry_attempts: 0)

      assert Decimal.equal?(ask, Decimal.new("77791.92000"))

      assert {:error, :unexpected_response_shape} =
               Rest.get_top_of_book("BTC-USD",
                 plug: responding(%{@ticker | "ask" => "-1"}),
                 retry_attempts: 0
               )

      assert {:error, :unexpected_response_shape} =
               Rest.get_top_of_book("BTC-USD",
                 plug: responding(%{@ticker | "ask" => "abc"}),
                 retry_attempts: 0
               )
    end

    test "the volume timestamp is NOT used as the quote time" do
      # `volume.timestamp` stamps the 24-hour volume window and lags about a minute. It is
      # the only timestamp in the payload, which makes it the obvious thing to reach for
      # and the wrong thing to reach for.
      volume_time = DateTime.from_unix!(1_787_936_340_000, :millisecond)

      assert {:ok, quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      refute quote_struct.venue_time == volume_time
      # The stronger statement, which the line above follows from: no trade time is stated.
      assert quote_struct.venue_time == nil
    end

    test "a 400 InvalidSymbol is :not_listed, and the venue's sentence does not ride in it" do
      # Permanent versus transient is what a caller acts on. The family reason for a symbol
      # the venue does not list is `:not_listed` with no venue text (decision D1): the
      # sentence is not stable across venues. It was `{:invalid_symbol, "no such symbol"}`.
      body = %{"result" => "error", "reason" => "InvalidSymbol", "message" => "no such symbol"}

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: responding(body, status: 400), retry_attempts: 0)
    end

    test "a known reason is never less informative than an unknown one (issue #1)" do
      # The property the fix exists for, in the words of the consumer who filed it. A reason
      # this package RECOGNISES used to answer with a bare atom and drop the venue's
      # `message`, while a reason it did not recognise kept the venue's words — the exact
      # opposite of useful, and a contradiction of the rationale written above
      # `refusal_reason/1` itself.
      #
      # `InvalidNonce` is where it bit. The atom names the category; the message is the
      # entire diagnosis, because "the stored nonce is above what we send" (bump the scale)
      # and "this key's mark is past anything we can emit" (a human must rotate it) are the
      # same atom and opposite remedies. 164 log lines reading `refused: :invalid_nonce`
      # told their reader nothing.
      message = "Nonce '1757000000' has not increased since your last call to /v1/balances"
      body = %{"result" => "error", "reason" => "InvalidNonce", "message" => message}

      # The comparison the consumer's own diagnostic procedure needs is reachable: the nonce is
      # in the text, so a caller can weigh it against 2^64.
      assert {:refused, {:invalid_nonce, text}} =
               Rest.get_price("BTC-USD", plug: responding(body, status: 400), retry_attempts: 0)

      assert text == message
      assert text =~ "1757000000"
    end

    test "a known reason the venue said nothing more about stays a bare atom" do
      # The other half of the shape, and why it is two shapes rather than one. A tuple means
      # *the venue said more*; a bare atom means *the venue named a category and stopped*.
      # Inventing a `nil` message for the second case would make every caller test for
      # something that never existed — and it would break the `Fake`, which builds refusals
      # literally and must stay shape-identical to the real venue.
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: responding(body, status: 400), retry_attempts: 0)
    end

    test "a blank message counts as no message, not as an empty one" do
      body = %{"result" => "error", "reason" => "InvalidSymbol", "message" => "   "}

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: responding(body, status: 400), retry_attempts: 0)
    end

    test "an UNRECOGNISED reason still keeps the venue's own word, unchanged" do
      # This path was already right and must stay right: the word IS the diagnosis when
      # nothing here recognises it.
      body = %{"result" => "error", "reason" => "SomethingNewGeminiAdded", "message" => "hi"}

      assert {:refused, {:unknown_reason, "SomethingNewGeminiAdded"}} =
               Rest.get_price("NOPE-USD", plug: responding(body, status: 400), retry_attempts: 0)
    end

    test "a 500 stays an error" do
      assert {:error, _reason} =
               Rest.get_price("BTC-USD", plug: responding(%{}, status: 500), retry_attempts: 0)
    end

    test "an UNRECOGNISED reason keeps the venue's words and creates NO atom" do
      # This decoded with `String.to_atom(Macro.underscore(reason))`, on text the venue
      # supplies. Atoms are never garbage collected and the table is finite, so a venue
      # emitting novel reasons could exhaust it and kill the whole BEAM — the consumer's
      # entire node, not just this package. `mix sobelow` flagged it as DOS.StringToAtom
      # and it was waved through twice as a "pre-existing low-confidence warning".
      #
      # Asserted per-reason via `String.to_existing_atom/1` rather than by watching
      # `:erlang.system_info(:atom_count)`. The count is process-global and this suite is
      # `async: true`, so unrelated tests running concurrently move it — that first draft
      # was itself a flaky test, which is its own kind of bug. This form is deterministic:
      # it asks the only question that actually matters, of the exact string in question.
      reasons =
        for index <- 1..50,
            do: "NoSuchReasonInvented#{index}#{System.unique_integer([:positive])}"

      results =
        for reason <- reasons do
          body = %{"result" => "error", "reason" => reason}

          Rest.get_price("BTC-USD", plug: responding(body, status: 400), retry_attempts: 0)
        end

      # The atom the OLD code would have minted is the underscored form. If decoding ever
      # creates it again, this raise stops happening and the test fails.
      for reason <- reasons do
        assert_raise ArgumentError, fn ->
          String.to_existing_atom(Macro.underscore(reason))
        end
      end

      # And the venue's own wording survives — an unrecognised reason must degrade
      # legibly, not collapse to a bare `:refused` that says nothing about what happened.
      for {result, reason} <- Enum.zip(results, reasons) do
        assert {:refused, {:unknown_reason, ^reason}} = result
      end
    end

    test "every RECOGNISED reason still maps to the atom callers already match on" do
      # The fix must not quietly change the vocabulary consumers pattern-match against.
      # Every pair here is the whole `@refusal_reasons` map — each one either in Gemini's
      # own documented error-code table (`docs/reference/gemini/rate-limits-and-auth.md`)
      # or measured live and recorded in this module's own docs. An earlier version of
      # this map also carried `RateLimit`, `EndpointNotFound` and `InsufficientFunds` —
      # plausible-looking reasons with no vendor documentation or live measurement behind
      # any of them, found and removed during review: a guessed entry in this table is
      # exactly the "nearby substitute" this family's own conventions rule out, even
      # though the practical risk here is a dead map entry rather than a wrong live value.
      for {sent, expected} <- [
            {"MissingApikeyHeader", :missing_apikey_header},
            {"MissingPayloadHeader", :missing_payload_header},
            {"MissingSignatureHeader", :missing_signature_header},
            {"InvalidNonce", :invalid_nonce},
            {"InvalidSignature", :invalid_signature},
            {"AmbiguousAuthentication", :ambiguous_authentication},
            {"InvalidApiKey", :invalid_api_key},
            {"MissingSecurityHeaders", :missing_security_headers},
            {"InvalidSymbol", :not_listed},
            {"InvalidParameterValue", :invalid_parameter_value}
          ] do
        body = %{"result" => "error", "reason" => sent}

        assert {:refused, ^expected} =
                 Rest.get_price("BTC-USD", plug: responding(body, status: 400), retry_attempts: 0)
      end
    end

    test "a 400 with no reason at all is still a plain refusal" do
      assert {:refused, :refused} =
               Rest.get_price("BTC-USD",
                 plug: responding(%{"result" => "error"}, status: 400),
                 retry_attempts: 0
               )
    end
  end

  describe "get_historical_prices/4 — the fixed window" do
    @candles [
      [1_787_935_740_000, 77_986.74, 77_995.93, 77_908.94, 77_941.47, 0.0],
      [1_787_935_680_000, 77_950.54, 77_981.02, 77_923.57, 77_934.41, 0.04]
    ]

    test "maps canonical widths to the literals the venue actually accepts" do
      # The venue rejects `1h`, `6h` and `1d` — all three of which its own documentation
      # lists. What goes on the wire is `1hr`, `6hr`, `1day`. `1w` and `1mo` (Core's `1M`)
      # joined the venue's accepted set 2026-09-08 — see `Rest`'s moduledoc.
      for {canonical, native} <- [
            {"1h", "1hr"},
            {"6h", "6hr"},
            {"1d", "1day"},
            {"1w", "1w"},
            {"1M", "1mo"}
          ] do
        plug = fn conn ->
          assert String.ends_with?(conn.request_path, "/#{native}")
          # 2026-08-24 00:00:00Z: on a boundary of every width up to a day.
          Req.Test.json(conn, [[1_787_270_400_000, 1.5, 2.5, 1.0, 2.0, 3.0]])
        end

        assert {:ok, _candles} =
                 Rest.get_historical_prices("BTC-USD", canonical, [],
                   plug: plug,
                   retry_attempts: 0
                 )
      end
    end

    test "1w and 1M skip the pre-flight window refusal, but still filter what comes back" do
      # Neither has a `Timeframe.seconds/1` width, so `range_within_window/2` cannot
      # compute an "earliest reachable" instant for them — see `Rest`'s moduledoc. No
      # `{:error, {:range_unavailable, …}}` fires here the way it would for `1d`; the two
      # fixture rows above are both older than `after_the_fixture`, so the ordinary
      # post-response filter (`within?/2`, the same one every width goes through) drops
      # them, proving the venue's answer is still checked against the range, just not
      # pre-emptively.
      after_the_fixture = DateTime.from_unix!(1_787_935_740_000 + 1, :millisecond)

      for canonical <- ~w(1w 1M) do
        assert {:ok, []} =
                 Rest.get_historical_prices("BTC-USD", canonical, [start: after_the_fixture],
                   plug: responding(@candles),
                   retry_attempts: 0
                 )
      end
    end

    test "a width the venue does not serve is an error, never the nearest one" do
      for width <- ~w(2h 4h 12h) do
        assert {:error, {:unsupported_timeframe, ^width}} =
                 Rest.get_historical_prices("BTC-USD", width, [], retry_attempts: 0)
      end
    end

    test "a range starting before the fixed window is REFUSED, not truncated" do
      # The venue ignores bounds and serves a fixed window. Returning what it happens to
      # hold would read as a complete answer for a period it does not serve.
      long_ago = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)

      assert {:error, {:range_unavailable, "1d", _details}} =
               Rest.get_historical_prices("BTC-USD", "1d", [start: long_ago],
                 plug: responding(@candles),
                 retry_attempts: 0
               )
    end

    test "a range inside the window is filtered here, because the venue will not" do
      # Built relative to now, not from a fixed epoch. The `1m` window is 1,440 bars —
      # twenty-four hours — so a hardcoded fixture stops being "inside the window" the
      # day after it is written, and this test failed for exactly that reason three days
      # after it was added. A time-relative fixture cannot rot that way.
      # On a minute boundary, and a whole minute closed, so neither bar is still forming.
      newest = (div(DateTime.to_unix(DateTime.utc_now()), 60) - 1) * 60_000
      older = newest - 60_000

      candles = [
        [newest, 77_986.74, 77_995.93, 77_908.94, 77_941.47, 0.0],
        [older, 77_950.54, 77_981.02, 77_923.57, 77_934.41, 0.04]
      ]

      start = DateTime.from_unix!(newest - 40_000, :millisecond)

      assert {:ok, [candle]} =
               Rest.get_historical_prices("BTC-USD", "1m", [start: start],
                 plug: responding(candles),
                 retry_attempts: 0
               )

      assert candle.opened_at == DateTime.from_unix!(newest, :millisecond)
    end

    test "candles come back oldest-first with Decimal numerics" do
      assert {:ok, [first, second]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], plug: responding(@candles))

      assert DateTime.compare(first.opened_at, second.opened_at) == :lt
      assert Decimal.equal?(first.open, Decimal.from_float(77_950.54))
      assert first.provider == :gemini
    end

    # A closed day and the day still forming, both on a boundary. A day, not a minute: the
    # forming bar stays forming for the whole of the test unless it straddles 00:00 UTC, where
    # a minute bar would turn closed if the test crossed a minute boundary between building the
    # fixture and the call.
    defp closed_and_forming do
      current = div(DateTime.to_unix(DateTime.utc_now()), 86_400) * 86_400_000
      closed = current - 86_400_000

      {closed, current,
       [
         [closed, 10.0, 11.0, 9.0, 10.5, 1.0],
         [current, 10.5, 12.0, 10.0, 11.0, 0.5]
       ]}
    end

    test "the bar still forming is dropped unless include_partial: true (MD1)" do
      {closed, current, rows} = closed_and_forming()

      assert {:ok, [only]} =
               Rest.get_historical_prices("BTC-USD", "1d", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert DateTime.to_unix(only.opened_at, :millisecond) == closed

      assert {:ok, [_closed, forming]} =
               Rest.get_historical_prices("BTC-USD", "1d", [],
                 plug: responding(rows),
                 retry_attempts: 0,
                 include_partial: true
               )

      assert DateTime.to_unix(forming.opened_at, :millisecond) == current

      assert {:error, {:invalid_option, :include_partial, "yes"}} =
               Rest.get_historical_prices("BTC-USD", "1d", [],
                 plug: responding(rows),
                 retry_attempts: 0,
                 include_partial: "yes"
               )
    end

    test "include_partial: true keeps a bar that opened ahead of this clock (skew)" do
      # A venue clock a little ahead of ours: its newest bar opens "in the future" to us.
      ahead = (div(DateTime.to_unix(DateTime.utc_now()), 60) + 1) * 60_000
      rows = [[ahead, 10.5, 12.0, 10.0, 11.0, 0.5]]

      assert {:ok, []} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert {:ok, [bar]} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(rows),
                 retry_attempts: 0,
                 include_partial: true
               )

      assert DateTime.to_unix(bar.opened_at, :millisecond) == ahead

      # An explicit :end is still honoured, exclusive.
      assert {:ok, []} =
               Rest.get_historical_prices("BTC-USD", "1m", [end: bar.opened_at],
                 plug: responding(rows),
                 retry_attempts: 0,
                 include_partial: true
               )
    end

    test "start is inclusive and end is exclusive on opened_at (MD2)" do
      # Inside the 1m window, on minute boundaries, both closed.
      newer = (div(DateTime.to_unix(DateTime.utc_now()), 60) - 2) * 60_000
      older = newer - 60_000

      rows = [
        [older, 10.0, 11.0, 9.0, 10.5, 1.0],
        [newer, 10.5, 12.0, 10.0, 11.0, 0.5]
      ]

      at = &DateTime.from_unix!(&1, :millisecond)

      assert {:ok, [only]} =
               Rest.get_historical_prices("BTC-USD", "1m", [end: at.(newer)],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert only.opened_at == at.(older)

      assert {:ok, [only]} =
               Rest.get_historical_prices("BTC-USD", "1m", [start: at.(newer)],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert only.opened_at == at.(newer)
    end

    test "a bar not aligned to its width refuses the reply, with the venue's value (MD3)" do
      # 1_559_755_800 s is on a half-hour but not an hour: the vendor's own example time.
      rows = [[1_559_755_800_000, 1.0, 2.0, 0.5, 1.5, 1.0]]

      assert {:error, {:unaligned_candle, 1_559_755_800_000}} =
               Rest.get_historical_prices("BTC-USD", "1h", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )

      assert {:ok, [_aligned]} =
               Rest.get_historical_prices("BTC-USD", "30m", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end

    test "two bars with one timestamp refuse the reply (MD3, the vendor's own example)" do
      rows = [
        [1_559_755_800_000, 7781.6, 7820.23, 7776.56, 7819.39, 34.76],
        [1_559_755_800_000, 7781.6, 7829.46, 7776.56, 7817.28, 43.42]
      ]

      assert {:error, {:duplicate_candle, ~U[2019-06-05 17:30:00.000Z]}} =
               Rest.get_historical_prices("BTC-USD", "30m", [],
                 plug: responding(rows),
                 retry_attempts: 0
               )
    end

    test "a candle price of zero or less refuses the reply (MD6)" do
      for {row, field} <- [
            {[1_787_935_740_000, 0, 2.0, 0.5, 1.5, 1.0], :open},
            {[1_787_935_740_000, 1.0, 2.0, 0.5, -1.5, 1.0], :close}
          ] do
        assert {:error, {:non_positive_price, ^field, _value}} =
                 Rest.get_historical_prices("BTC-USD", "1m", [],
                   plug: responding([row]),
                   retry_attempts: 0
                 )
      end
    end

    test "a limit is refused, never ignored (MD4)" do
      assert {:error, {:unsupported_option, :limit}} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: fn _conn -> raise "must not request" end,
                 retry_attempts: 0,
                 limit: 10
               )
    end
  end

  describe "get_symbols/1" do
    test "returns canonical symbols, sorted" do
      assert {:ok, symbols} =
               Rest.get_symbols(plug: responding(~w(btcusd aavegusd solrlusd)), retry_attempts: 0)

      assert symbols == ["AAVE-GUSD", "BTC-USD", "SOL-RLUSD"]
    end

    test "perpetuals are excluded rather than given an invented spot pair" do
      assert {:ok, symbols} =
               Rest.get_symbols(
                 plug: responding(~w(btcusd avaxgusdperp avaxusdcperp)),
                 retry_attempts: 0
               )

      assert symbols == ["BTC-USD"]
    end
  end

  describe "get_order_book/2" do
    @book %{
      "bids" => [%{"price" => "77792.91", "amount" => "0.0031", "timestamp" => "1787936377"}],
      "asks" => [%{"price" => "77792.92", "amount" => "0.0182", "timestamp" => "1787936377"}]
    }

    test "levels are Decimal tuples; venue_time is nil, because the venue reports none" do
      # Each level's `timestamp` field is documented "DO NOT USE ... just populated with a
      # dummy value" (`rest.yaml:8065`) — kept in the fixture to prove it is read for
      # nothing, not carried into `venue_time`. `/v1/book` publishes no time of its own
      # elsewhere in the response.
      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("BTC-USD", plug: responding(@book), retry_attempts: 0)

      assert [{bid_price, bid_size}] = book.bids
      assert Decimal.equal?(bid_price, Decimal.new("77792.91"))
      assert Decimal.equal?(bid_size, Decimal.new("0.0031"))
      assert book.venue_time == nil
      assert book.provider == :gemini
    end

    test "bids come back highest first and asks lowest first, whatever the venue sent" do
      # The REST arm of the fix `WsDecode.to_order_book/3` got the same day. Fixing the
      # streamed book and leaving this one is the "fix applied where it was found rather
      # than where it applies" this family keeps paying for — same package, same type, a
      # different module.
      #
      # `Core.Types.OrderBook`: "a caller reading `hd(bids)` as the best bid is reading it
      # correctly, and a venue package that returns venue-order without re-sorting has
      # broken the contract even though every value in it is true."
      body = %{
        "bids" => [
          %{"price" => "77792.50", "amount" => "1", "timestamp" => "1787936377"},
          %{"price" => "77792.91", "amount" => "2", "timestamp" => "1787936377"},
          %{"price" => "77792.10", "amount" => "3", "timestamp" => "1787936377"}
        ],
        "asks" => [
          %{"price" => "77793.40", "amount" => "1", "timestamp" => "1787936377"},
          %{"price" => "77792.92", "amount" => "2", "timestamp" => "1787936377"}
        ]
      }

      assert {:ok, book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert Enum.map(book.bids, fn {price, _size} -> Decimal.to_string(price) end) ==
               ["77792.91", "77792.50", "77792.10"]

      assert Enum.map(book.asks, fn {price, _size} -> Decimal.to_string(price) end) ==
               ["77792.92", "77793.40"]
    end

    test "a book with an unreadable level is refused whole, not returned with a gap" do
      # Found 2026-10-10: an unreadable price used to be dropped and an unreadable amount
      # kept as `{price, nil}`, so a damaged reply looked like a complete book.
      good = %{"price" => "77792.91", "amount" => "1", "timestamp" => "1787936377"}

      for bad <- [
            %{"price" => "NaN", "amount" => "2"},
            %{"price" => "77792.50", "amount" => "garbage"},
            "not-a-row"
          ] do
        body = %{"bids" => [good, bad], "asks" => []}

        assert {:error, :unexpected_response_shape} =
                 Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)
      end
    end

    test "get_historical_prices and get_trades answer with the canonical symbol" do
      # Found 2026-10-10: both echoed the caller's spelling while `get_order_book/2` and
      # `get_price/2` canonicalised.
      candles = [[1_787_935_740_000, 77_986.74, 77_995.93, 77_908.94, 77_941.47, 0.0]]

      assert {:ok, [candle]} =
               Rest.get_historical_prices("btcusd", "1m", [],
                 plug: responding(candles),
                 retry_attempts: 0
               )

      assert candle.symbol == "BTC-USD"

      trade = %{
        "timestamp" => 1_547_146_811,
        "timestampms" => 1_547_146_811_357,
        "tid" => 1,
        "price" => "3610.85",
        "amount" => "0.27",
        "type" => "buy"
      }

      assert {:ok, [%{symbol: "BTC-USD"}]} =
               Rest.get_trades("btcusd", plug: responding([trade]), retry_attempts: 0)
    end

    test "a book with no level timestamps still succeeds, with venue_time nil" do
      # There was never anything to guess: `OrderBookEntry.timestamp` (`rest.yaml:8065`) is
      # a dummy value whether present or absent.
      body = %{"bids" => [%{"price" => "1", "amount" => "1"}], "asks" => []}

      assert {:ok, book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert book.venue_time == nil
    end
  end

  describe "list_instruments/1 — status from each symbol's details (issue #4)" do
    # `/v1/symbols` keeps closed symbols; measured 2026-10-08, `efilfil` is listed there and in
    # `/v1/pricefeed`, and only its details say `"status":"closed"`.
    @details %{
      "btcusd" => %{"base_currency" => "BTC", "quote_currency" => "USD", "status" => "open"},
      "efilfil" => %{"base_currency" => "EFIL", "quote_currency" => "FIL", "status" => "closed"},
      "ethusd" => %{
        "base_currency" => "ETH",
        "quote_currency" => "USD",
        "status" => "cancel_only"
      },
      "solusd" => %{"base_currency" => "SOL", "quote_currency" => "USD", "status" => "limit_only"}
    }

    defp catalogue(me) do
      fn conn ->
        send(me, {:path, conn.request_path})

        case conn.request_path do
          "/v1/symbols" ->
            Req.Test.json(conn, ["btcusd", "efilfil", "ethusd", "solusd", "btcgusdperp"])

          "/v1/symbols/details/" <> native ->
            case Map.fetch(@details, native) do
              {:ok, body} ->
                Req.Test.json(
                  conn,
                  Map.merge(body, %{"symbol" => native, "product_type" => "spot"})
                )

              :error ->
                Req.Test.json(%{conn | status: 400}, %{"reason" => "InvalidSymbol"})
            end
        end
      end
    end

    test "every non-perpetual symbol, with the venue's own status mapped honestly" do
      assert {:ok, instruments} =
               Rest.list_instruments(plug: catalogue(self()), retry_attempts: 1)

      by_symbol = Map.new(instruments, &{&1.symbol, &1})

      assert by_symbol["BTC-USD"].status == :tradable
      assert by_symbol["EFIL-FIL"].status == :delisted
      assert by_symbol["ETH-USD"].status == :unknown
      assert by_symbol["SOL-USD"].status == :tradable
      assert by_symbol["EFIL-FIL"].base == "EFIL" and by_symbol["EFIL-FIL"].quote == "FIL"
      assert by_symbol["BTC-USD"].instrument == :spot
      refute Enum.any?(instruments, &String.contains?(&1.symbol, "PERP"))
    end

    test "symbols: details only the pairs asked for — the cheap call" do
      assert {:ok, [instrument]} =
               Rest.list_instruments(
                 symbols: ["EFIL-FIL"],
                 plug: catalogue(self()),
                 retry_attempts: 1
               )

      assert instrument.status == :delisted
      assert_received {:path, "/v1/symbols/details/efilfil"}
      refute_received {:path, "/v1/symbols"}
    end

    test "a symbol whose details cannot be read fails the whole call — no silent hole" do
      assert {:error, {:instrument_detail_failed, "NOPE-USD", _reason}} =
               Rest.list_instruments(
                 symbols: ["BTC-USD", "NOPE-USD"],
                 plug: catalogue(self()),
                 retry_attempts: 1
               )
    end

    test "symbols: two spellings of one pair are detailed once, not twice" do
      # De-duplicating the raw strings detailed `EFIL-FIL` and `efilfil` separately: two
      # requests against the public budget, and two identical instruments back.
      assert {:ok, [instrument]} =
               Rest.list_instruments(
                 symbols: ["EFIL-FIL", "efilfil", "EFILFIL"],
                 plug: catalogue(self()),
                 retry_attempts: 1
               )

      assert instrument.symbol == "EFIL-FIL"
      assert_received {:path, "/v1/symbols/details/efilfil"}
      refute_received {:path, "/v1/symbols/details/efilfil"}
    end

    test "symbols: that is not a list of strings is refused, not a crash in the caller" do
      assert {:error, {:invalid_option, :symbols, "BTC-USD"}} =
               Rest.list_instruments(symbols: "BTC-USD", plug: catalogue(self()))

      assert {:error, {:invalid_option, :symbols, [nil]}} =
               Rest.list_instruments(symbols: [nil], plug: catalogue(self()))
    end
  end

  describe "quantization/1" do
    test "keeps the price and quantity increments apart" do
      # `tick_size` is the BASE increment and `quote_increment` the PRICE increment. The
      # names do not say so, and for btcusd they differ by six orders of magnitude.
      body = %{
        "symbol" => "BTCUSD",
        "tick_size" => 1.0e-8,
        "quote_increment" => 0.01,
        "min_order_size" => "0.00001",
        "status" => "open"
      }

      assert {:ok, quantization} =
               Rest.quantization("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quantization.price_increment, Decimal.from_float(0.01))
      assert Decimal.equal?(quantization.quantity_increment, Decimal.from_float(1.0e-8))
      assert Decimal.equal?(quantization.min_quantity, Decimal.new("0.00001"))
      assert quantization.status == "open"
    end
  end

  describe "get_market_overview/1" do
    test "keys the whole catalogue by canonical symbol in one call" do
      body = [
        %{"pair" => "BTCUSD", "price" => "77845.79", "percentChange24h" => "-0.0424"},
        %{"pair" => "AAVEGUSD", "price" => "141.20", "percentChange24h" => "0.0258"}
      ]

      assert {:ok, overview} = Rest.get_market_overview(plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(overview["BTC-USD"].price, Decimal.new("77845.79"))
      assert Decimal.equal?(overview["AAVE-GUSD"].change_24h, Decimal.new("0.0258"))
    end
  end

  describe "timeframes/0" do
    test "is the nine the venue serves, shortest first" do
      # `1w` and `1M` joined 2026-09-08 — measured live, the venue's 400 body grew from
      # seven accepted widths to nine. See `Rest`'s moduledoc.
      assert Rest.timeframes() == ~w(1m 5m 15m 30m 1h 6h 1d 1w 1M)
    end

    test "excludes every width the venue rejects" do
      for absent <- ~w(2h 4h 12h), do: refute(absent in Rest.timeframes())
    end
  end

  describe "refusals on the remaining endpoints" do
    test "quantization refuses an unlisted symbol rather than erroring" do
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :not_listed} =
               Rest.quantization("NOPE-USD",
                 plug: responding(body, status: 400),
                 retry_attempts: 0
               )
    end

    test "get_symbols surfaces a venue error rather than an empty catalogue" do
      # An empty list would read as "this venue lists nothing", which is a very different
      # claim from "the request failed".
      assert {:error, _reason} =
               Rest.get_symbols(plug: responding(%{}, status: 503), retry_attempts: 0)
    end

    test "get_market_overview surfaces a venue error the same way" do
      assert {:error, _reason} =
               Rest.get_market_overview(plug: responding(%{}, status: 503), retry_attempts: 0)
    end

    test "a candle request for an unlisted symbol is refused" do
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :not_listed} =
               Rest.get_historical_prices("NOPE-USD", "1d", [],
                 plug: responding(body, status: 400),
                 retry_attempts: 0
               )
    end

    test "an order book request for an unlisted symbol is refused" do
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:refused, :not_listed} =
               Rest.get_order_book("NOPE-USD",
                 plug: responding(body, status: 400),
                 retry_attempts: 0
               )
    end
  end

  describe "a 404 is the venue speaking, not a routing failure" do
    # Measured live 2026-09-06: `GET /v1/pubticker/nonexistentsymbolxyz` returns 404 with
    # a plain-text body, `'nonexistentsymbolxyz' does not have available data yet` — the
    # venue naming exactly the condition a symbol-scoped GET refuses on, not a transient
    # failure. Before this fix a 404 fell through to the generic `{:error, …}` clause, so
    # a permanently unlisted symbol looked retryable forever.
    defp responding_text(body, status) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(status, body)
      end
    end

    test "get_price on a 404 'does not have available data yet' is {:refused, :no_quote}" do
      body = "'nonexistentsymbolxyz' does not have available data yet"

      assert {:refused, :no_quote} =
               Rest.get_price("NOPE-USD", plug: responding_text(body, 404), retry_attempts: 0)
    end

    test "get_top_of_book refuses on a 404 the same way" do
      body = "'nonexistentsymbolxyz' does not have available data yet"

      assert {:refused, :no_quote} =
               Rest.get_top_of_book("NOPE-USD",
                 plug: responding_text(body, 404),
                 retry_attempts: 0
               )
    end

    test "an empty 404 body (measured on /v1/fundingamount) is {:refused, :not_listed}" do
      assert {:refused, :not_listed} =
               Rest.get_funding("PERP-USD", plug: responding_text("", 404), retry_attempts: 0)

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: responding_text("", 404), retry_attempts: 0)
    end

    test "a collection read's empty 404 is not read as an unlisted symbol" do
      assert {:refused, :refused} =
               Rest.get_symbols(plug: responding_text("", 404), retry_attempts: 0)
    end

    test "get_trades' BadRequest refusal is :not_listed" do
      body = %{"result" => "error", "reason" => "BadRequest", "message" => "bad"}

      assert {:refused, :not_listed} =
               Rest.get_trades("NOPE-USD", plug: responding(body, status: 400), retry_attempts: 0)
    end
  end

  describe "a refusal body that is not JSON at all keeps the venue's own text" do
    # Measured live 2026-09-06: `/v2/candles/{symbol}/{width}`'s 400 body is plain text,
    # `"Supplied value 'X' is not a valid symbol"`, not the `{"result":…,"reason":…}`
    # shape every other refusal in this module carries. `decode/1`'s own fallback
    # collapses unparseable JSON to `%{}` — right for a 2xx body, wrong for a refusal one,
    # where it used to discard the venue's only stated reason before `refusal_reason/1`
    # ever saw it.
    test "a plain-text 400 naming an invalid symbol is :not_listed, not a bare :refused" do
      body = "Supplied value 'NOPE-USD' is not a valid symbol"

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(400, body)
      end

      assert {:refused, :not_listed} =
               Rest.get_historical_prices("NOPE-USD", "1m", [], plug: plug, retry_attempts: 0)
    end

    test "any other plain-text refusal keeps the venue's text as {:unknown_reason, text}" do
      body = "Something the venue made up"

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(400, body)
      end

      assert {:refused, {:unknown_reason, ^body}} =
               Rest.get_price("NOPE-USD", plug: plug, retry_attempts: 0)
    end

    test "a body that arrives as a raw string but IS valid JSON with a reason still reads it" do
      # Req only auto-decodes a body it recognises as JSON from the content type; a venue
      # (or a proxy in front of it) answering `application/json`-shaped bytes under a
      # different content type reaches `refusal_reason/1` as a raw string that happens to
      # parse. The reason inside it must not be lost just because it arrived unparsed.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(400, ~s({"result":"error","reason":"InvalidSymbol"}))
      end

      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: plug, retry_attempts: 0)
    end

    test "a raw-string body that IS JSON but not the {reason: ...} shape is a plain refusal" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("date", @date)
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(400, ~s(["unexpected", "array"]))
      end

      assert {:refused, :refused} = Rest.get_price("NOPE-USD", plug: plug, retry_attempts: 0)
    end
  end

  # `get_fx_rate/3`'s own describe block, including "refuses a non-numeric rate rather than
  # delivering rate: nil", moved to `private_test.exs` with the rest of that endpoint's
  # tests when it moved from `Rest` to `Private` — it is a signed call now, not a public GET.

  describe "rate_limit_blocking — family-wide gap, DpCryptoManagement issue #23" do
    # A real limiter module, recording which entry point it was actually called through —
    # the only way to prove `:rate_limit_blocking` reached `Core.HttpClient` rather than
    # merely appearing in `request_opts/1`'s own allowlist.
    defmodule RecordingLimiter do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      # dp_exchange_core 0.3.52: a non-blocking request reserves with `acquire/3` and a zero
      # timeout (it never waits), where it used to `check/3` first and race other callers.
      def acquire(_provider, _weight, opts) do
        call = if Keyword.get(opts, :timeout) == 0, do: :acquire_without_waiting, else: :acquire
        Process.put(:rate_limiter_call, call)
        :ok
      end

      @impl true
      def check(_provider, _weight, _opts) do
        Process.put(:rate_limiter_call, :check)
        :ok
      end

      @impl true
      def record(_provider, _weight, _opts), do: :ok
    end

    test "rate_limit_blocking: true reaches Core.HttpClient as acquire/3, not check/3" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, %Types.Quote{}} =
               Rest.get_price("BTC-USD",
                 plug: responding(@ticker),
                 retry_attempts: 0,
                 rate_limit_blocking: true
               )

      assert Process.get(:rate_limiter_call) == :acquire
    end

    test "rate_limit_blocking: false (or omitted) reaches Core.HttpClient as acquire/3 with no wait" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, %Types.Quote{}} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Process.get(:rate_limiter_call) == :acquire_without_waiting
    end
  end
end
