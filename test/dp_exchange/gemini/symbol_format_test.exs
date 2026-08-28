defmodule DpExchange.Gemini.SymbolFormatTest do
  use ExUnit.Case, async: true

  alias DpExchange.Gemini.SymbolFormat

  doctest DpExchange.Gemini.SymbolFormat

  describe "the overlapping-quote splits, which are 45% of this venue's catalogue" do
    # These are the tests that justify the quote list's ordering. With `USD` checked
    # before `GUSD`, every one of them yields a base asset that does not exist — and
    # nothing fails, it just matches no catalogue entry and collects nothing.
    test "GUSD wins over USD" do
      assert SymbolFormat.to_canonical_symbol("aavegusd") == "AAVE-GUSD"
      assert SymbolFormat.to_canonical_symbol("btcgusd") == "BTC-GUSD"
      assert SymbolFormat.to_canonical_symbol("ampgusd") == "AMP-GUSD"
    end

    test "RLUSD wins over USD" do
      assert SymbolFormat.to_canonical_symbol("solrlusd") == "SOL-RLUSD"
      assert SymbolFormat.to_canonical_symbol("aaverlusd") == "AAVE-RLUSD"
    end

    test "USDC and USDT win over USD" do
      assert SymbolFormat.to_canonical_symbol("aaveusdc") == "AAVE-USDC"
      assert SymbolFormat.to_canonical_symbol("btcusdt") == "BTC-USDT"
    end

    test "plain USD still splits correctly" do
      assert SymbolFormat.to_canonical_symbol("btcusd") == "BTC-USD"
      assert SymbolFormat.to_canonical_symbol("2zusd") == "2Z-USD"
    end
  end

  describe "the two symbols that revealed quote currencies nobody would have guessed" do
    # Found by tallying every live symbol's suffix on 2026-08-28 and chasing the leftovers.
    # Without SOL and FIL in the list these take the `:nomatch` path and come back
    # unsplit — a symbol the rest of the family cannot interpret.
    test "jitosolsol is JITOSOL over SOL" do
      assert SymbolFormat.to_canonical_symbol("jitosolsol") == "JITOSOL-SOL"
    end

    test "efilfil is EFIL over FIL" do
      assert SymbolFormat.to_canonical_symbol("efilfil") == "EFIL-FIL"
    end
  end

  describe "round-tripping" do
    test "every sample pair survives both directions" do
      for canonical <- ~w(BTC-USD AAVE-GUSD SOL-RLUSD ETH-USDC JITOSOL-SOL EFIL-FIL) do
        native = SymbolFormat.to_exchange_symbol(canonical)

        assert SymbolFormat.to_canonical_symbol(native) == canonical,
               "#{canonical} -> #{native} -> #{SymbolFormat.to_canonical_symbol(native)}"
      end
    end

    test "the exchange form is lowercase, because the stream names are" do
      # `btcusd@bookTicker`, not `BTCUSD@bookTicker`. Downcased once here rather than at
      # each call site that would otherwise have to remember.
      assert SymbolFormat.to_exchange_symbol("BTC-USD") == "btcusd"
      assert SymbolFormat.to_exchange_symbol("AAVE-GUSD") == "aavegusd"
    end

    test "an already-canonical string is not re-split" do
      assert SymbolFormat.to_canonical_symbol("BTC-USD") == "BTC-USD"
    end
  end

  describe "perpetuals" do
    test "are recognised" do
      assert SymbolFormat.perpetual?("avaxgusdperp")
      assert SymbolFormat.perpetual?("AVAXGUSDPERP")
      refute SymbolFormat.perpetual?("avaxgusd")
    end

    test "do not get an invented canonical spot pair" do
      # It ends in no quote, so it takes the `:nomatch` path and comes back uppercased and
      # unsplit. Inventing `AVAXGUSD-PERP` or `AVAX-GUSD` would be a substitution: one is
      # not a pair, the other is a different instrument that also exists.
      canonical = SymbolFormat.to_canonical_symbol("avaxgusdperp")

      assert canonical == "AVAXGUSDPERP"
      refute String.contains?(canonical, "-")
    end
  end

  describe "the declaration and the mapping cannot disagree" do
    test "capabilities' supported_quotes IS the mapping's quote list" do
      assert DpExchange.Gemini.capabilities().supported_quotes == SymbolFormat.quotes()
    end

    test "the quote list is ordered longest-first" do
      # Not cosmetic on this venue: 157 of 346 live symbols end in a quote that is a
      # suffix of another quote, and the list is consulted in order.
      lengths = Enum.map(SymbolFormat.quotes(), &String.length/1)

      assert lengths == Enum.sort(lengths, :desc)
    end
  end
end
