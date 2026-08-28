defmodule DpExchange.Gemini.SymbolFormat do
  @moduledoc """
  Gemini's symbol mapping — the family's first genuinely lossy one.

  Gemini's native symbol is **lowercase and separatorless**: `btcusd`, `aavegusd`,
  `jitosolsol`. Canonical is `BASE-QUOTE`. So unlike Coinbase, where the conversion is
  effectively identity, here both directions do real work and one of them can be wrong.

  ## Why the quote list is ordered longest-first, and why here it bites

  With `sep: ""` there is no separator to split on, so `CanonicalPair` recovers the base
  by matching a known quote **suffix**. The list is consulted in order, so a shorter quote
  that is also the tail of a longer one will win if it is checked first — and Gemini has
  three overlapping pairs of exactly that shape:

  | Native | Correct split | What `USD`-before-`GUSD` would give |
  |---|---|---|
  | `aavegusd` | `AAVE` / `GUSD` | `AAVEG` / `USD` |
  | `solrlusd` | `SOL` / `RLUSD` | `SOLRL` / `USD` |
  | `aaveusdc` | `AAVE` / `USDC` | — (`USDC` is longer, so safe either way) |

  `AAVEG` is not an asset. A symbol split that way matches no catalogue entry and collects
  nothing, silently — the same shape of failure as a wrong timeframe, one layer down.

  Of the 346 symbols live on 2026-08-28, **157 end in a quote that is a suffix of another
  quote** (80 `GUSD` + 77 `RLUSD`). This is not a precaution on this venue; it is 45% of
  the catalogue.

  ## The quote list was derived, not assumed

  Taken from the live `/v1/symbols` list on 2026-08-28 by tallying suffixes and then
  chasing what did not match. Two symbols were left over — `jitosolsol` and `efilfil` —
  which is how `SOL` and `FIL` got here. Guessing the list from the well-known quotes
  would have produced exactly those two silent mis-splits.

  ## Perpetuals are not spot pairs and do not round-trip

  Thirteen symbols carry a `perp` suffix (`avaxgusdperp`). They end in no quote, so they
  take the `:nomatch` path and are returned uppercased and unsplit. That is deliberate:
  this package declares `supported_instrument_types: [:spot]`, and inventing a canonical
  spot pair for a perpetual would be a substitution. `Rest.get_symbols/1` filters them out
  rather than emitting a symbol the rest of the family cannot interpret.

  ## Downcase on the way out

  `CanonicalPair.to_exchange/2` returns uppercase (`BTCUSD`). Gemini's REST accepts either
  case, but `/v1/symbols` returns lowercase and **the WebSocket stream names are
  lowercase** — `btcusd@bookTicker`. So the exchange form is downcased here, once, rather
  than at each of the several call sites that would otherwise have to remember.
  """

  @behaviour DpExchange.Core.SymbolNormalizer

  alias DpExchange.Core.CanonicalPair

  # Longest-first, and within a length the order is arbitrary. RLUSD (5) precedes the
  # four-letter quotes, which precede the three-letter ones — GUSD before USD is the
  # ordering that 80 of 346 live symbols depend on.
  @mapping %{sep: "", quotes: ~w(RLUSD USDC USDT GUSD USD EUR GBP SGD DAI BTC ETH SOL FIL)}

  @doc "The mapping, exposed so the conformance suite can drive `CanonicalPair` with it."
  @spec mapping() :: CanonicalPair.mapping()
  def mapping, do: @mapping

  @doc """
  The quote currencies this venue settles in, canonical and uppercase.

  Exposed because `capabilities/0` declares the same list, and a declaration that can
  disagree with the mapping it describes is a declaration worth nothing.
  """
  @spec quotes() :: [String.t()]
  def quotes, do: @mapping.quotes

  @doc """
  Whether a native symbol names a perpetual rather than a spot pair.

  Measured, not documented: 13 of the 346 symbols live on 2026-08-28 carry the suffix.
  """
  @spec perpetual?(String.t()) :: boolean()
  def perpetual?(native) when is_binary(native),
    do: native |> String.downcase() |> String.ends_with?("perp")

  @impl true
  @spec to_canonical_symbol(String.t()) :: String.t()
  def to_canonical_symbol(native) when is_binary(native),
    do: CanonicalPair.to_canonical(@mapping, native)

  @impl true
  @spec to_exchange_symbol(String.t()) :: String.t()
  def to_exchange_symbol(canonical) when is_binary(canonical) do
    @mapping
    |> CanonicalPair.to_exchange(canonical)
    |> String.downcase()
  end
end
