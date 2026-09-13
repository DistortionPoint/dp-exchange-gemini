defmodule DpExchange.Gemini.WsDecode do
  @moduledoc """
  WebSocket frames into the contract's value types.

  Pure functions; no socket. Three rules here are not obvious from the field names, and each
  produces a wrong-but-plausible answer if missed.

  ## 1. `m` is *"whether the buyer is the maker"* — the opposite of the taker's side

  This venue reports the trade side **two different ways on two transports**:

      REST  /v1/trades   `type` = the TAKER's side. "buy" means an ask was lifted.
      WS    @trade       `m`    = whether the BUYER was the MAKER.

  So `m: true` means the buyer was resting and the **seller** was the aggressor —
  `aggressor: :sell`. Carrying `m` straight through as a buy would invert every trade on the
  socket while agreeing with the REST field name, which is exactly how such a bug survives
  review.

  ## 2. Timestamps are **nanoseconds**, not milliseconds

  `E` is documented as a nanosecond Unix timestamp, and the vendor notes the values exceed
  JavaScript's safe integer range. Reading one as milliseconds puts the event roughly fifty
  thousand years into the future; reading it as seconds is worse, because the result still
  looks like a date.

  ## 3. A depth frame is a *diff*, and the sequence range is how you know it is safe

  `depth` and `depthFast` carry `U..u` — the range of update ids the frame covers. The
  vendor: *"if a frame's U skips ahead of the last applied u, discard the book and
  resubscribe to resync."* A package applying diffs without checking that gap builds a book
  that is silently wrong from the first dropped frame onward, and every price in it stays
  real. `depth_gap?/2` is that check.

  A quantity of zero in a diff **removes** the level rather than setting it to zero — the
  vendor says so, and a package storing the zero would keep a level nobody is quoting.
  """

  alias DpExchange.Core.Types.{OrderBook, OrderBookDelta, TopOfBook, Trade}

  @doc """
  A `Trade` from a `{symbol}@trade` frame.

  `aggressor` is **inverted from `m`**: see the moduledoc. `m: true` (buyer is maker) means
  the seller lifted, so the aggressor is `:sell`.

  ## `price` and `quantity` are guarded, and were not

  `Core.Types.Trade` enforces both, and its `new/1` refuses a `nil` in either. This builds the
  struct literally, as everywhere in this family, so that check never ran here and both went
  through bare `decimal/1` — which answers `nil` for an absent, empty, unparseable, NaN or
  Infinity value. A trade reporting an unstated size at an unstated price still sits in the
  tape looking like a print that happened.

  `Rest.to_trade/2`, the REST arm of the same type, already guarded both. This module had the
  other half of the pair right — `to_string_or_nil/1` on the id rather than `to_string/1`,
  which is what keeps an absent id detectable instead of turning it into `""` — and REST had
  that half wrong. Each file held the fix the other needed.
  """
  @spec to_trade(map(), String.t()) :: {:ok, Trade.t()} | {:error, term()}
  def to_trade(%{"p" => price, "q" => quantity} = frame, symbol) do
    with {:ok, timestamp} <- nanosecond_time(frame["E"]),
         {:ok, price} <- required_decimal(price, :price),
         {:ok, quantity} <- required_decimal(quantity, :quantity) do
      {:ok,
       %Trade{
         id: frame |> Map.get("t") |> to_string_or_nil(),
         symbol: symbol,
         side: aggressor(frame["m"]),
         price: price,
         quantity: quantity,
         timestamp: timestamp,
         # The socket publishes no bust flag; a venue that says nothing has not said a
         # trade was busted.
         broken: false,
         provider: :gemini
       }}
    end
  end

  def to_trade(_frame, _symbol), do: {:error, :unexpected_frame_shape}

  # `m` is "whether the buyer is the maker". Buyer resting => seller aggressed.
  defp aggressor(true), do: :sell
  defp aggressor(false), do: :buy
  # Absent means the venue did not say which side lifted, and neither answer is honest.
  defp aggressor(_absent), do: nil

  @doc """
  A `TopOfBook` from a `{symbol}@bookTicker` frame.

  `b`/`B` are the bid and its size, `a`/`A` the ask and its size. `E` is the venue's own
  nanosecond timestamp where the frame carries one.

  ## A missing `E` does not discard the book

  This used to open `with {:ok, venue_time} <- nanosecond_time(frame["E"])`, so a frame
  without a readable `E` returned `{:error, :missing_venue_timestamp}` and no book at all.
  `Socket` then swallowed that error silently AND skipped the `c` last-trade `Quote` with
  it, because the delivery sat inside the success branch — so one absent optional field
  produced total silence on both kinds this channel carries.

  That was wrong against the contract regardless of what the venue sends.
  `Core.Types.TopOfBook` enforces `[:symbol, :observed_at, :provider]` and nothing else; its
  moduledoc says `venue_time` "is `nil` where the venue publishes none" and names another
  venue in this family whose BBO publishes none at all. `observed_at` is what states
  freshness, and it is always present. Refusing the whole book over an optional field threw
  away a real bid and a real ask.

  It is also the answer this package's own REST arm already gives: `Rest.get_top_of_book/2`
  reads the time through `header_time_or_nil/1` and emits `nil` when the header is absent or
  unreadable, rather than refusing. Same venue, same type, two answers — and the transport
  was deciding which.

  **`Trade` and `OrderBookDelta` keep requiring `E`, and that is not an inconsistency**:
  both enforce `:timestamp` in `@enforce_keys` and type it non-nullable, so a print or a
  diff this package cannot place in time is genuinely not one it can report. `TopOfBook`
  does not enforce it. The types differ, so the answers differ.

  The stakes, from this repository's own reference: the frame captured 2026-08-28 in
  `docs/reference/gemini/demo-environment.md` is `{"s","b","a","c"}` with no `E`, and
  `websocket-api-replacement.md` describes the channel as publishing "best bid, best ask and
  last trade price directly". If that is the production shape, this channel was emitting
  nothing at all.
  """
  @spec to_top_of_book(map(), String.t(), DateTime.t()) :: {:ok, TopOfBook.t()}
  def to_top_of_book(frame, symbol, observed_at) do
    {:ok,
     %TopOfBook{
       symbol: symbol,
       bid: decimal(frame["b"]),
       ask: decimal(frame["a"]),
       bid_size: decimal(frame["B"]),
       ask_size: decimal(frame["A"]),
       venue_time: venue_time_or_nil(frame["E"]),
       observed_at: observed_at,
       provider: :gemini
     }}
  end

  # Absent and present-but-unreadable answer the same way here, deliberately: both mean this
  # package cannot state the venue's time, and `nil` says that. The same split
  # `Rest.header_time_or_nil/1` makes on the REST arm of this type.
  defp venue_time_or_nil(raw) do
    case nanosecond_time(raw) do
      {:ok, at} -> at
      {:error, _unstated} -> nil
    end
  end

  @doc """
  An `OrderBook` from a partial-depth snapshot (`@depth5`, `@depth10`, `@depth20`).

  These frames carry `lastUpdateId` and absolute levels. **`lastUpdateId` becomes the book's
  `sequence`**, which is what lets a caller tell one snapshot from a later one — a snapshot
  with no sequence cannot be ordered against anything.

  The frame carries **no timestamp of its own**, so `observed_at` is passed in and used;
  that is when the snapshot was seen, and the type has nowhere to claim otherwise.
  """
  @spec to_order_book(map(), String.t(), DateTime.t()) :: {:ok, OrderBook.t()}
  def to_order_book(frame, symbol, observed_at) do
    {:ok,
     %OrderBook{
       symbol: symbol,
       bids: levels(frame["bids"], :desc),
       asks: levels(frame["asks"], :asc),
       # **`nil`, and that is the fix.** The venue publishes no time for this frame — its own
       # AsyncAPI requires `[lastUpdateId, bids, asks]` for `OrderBookSnapshot`, where
       # `BookTicker` requires an `E` event time — so there is nothing venue-stamped to put
       # here, and `nil` says exactly that.
       #
       # This used to be `timestamp: observed_at`: a read time in a field
       # `Core.Types.OrderBook` documented as the venue's own, because the single
       # `:timestamp` it had left no way to say "the venue did not date this". Core 0.2.0
       # split that field for this reason (dp-exchange-core issue #31); the consumer who
       # decided the design stores `venue_time` as their point time where it is present and
       # records the fallback where it is not, so a mis-bucketed candle is attributable
       # rather than invisible.
       venue_time: nil,
       observed_at: observed_at,
       sequence: frame["lastUpdateId"],
       provider: :gemini
     }}
  end

  @doc """
  Whether applying `frame` to a book last updated at `last_applied` would skip updates.

  The vendor's rule: a frame's `U` must not skip ahead of the last applied `u`. **`true`
  means discard the book and resubscribe** — not "retry", because the missing updates are
  gone and the local book is already wrong.

  `nil` for `last_applied` means nothing has been applied yet, which is never a gap.
  """
  @spec depth_gap?(map(), integer() | nil) :: boolean()
  def depth_gap?(_frame, nil), do: false

  def depth_gap?(%{"U" => first_update}, last_applied) when is_integer(first_update),
    do: first_update > last_applied + 1

  # A diff frame with no `U` cannot be checked, and an unverifiable frame is treated as a
  # gap: continuing would apply it blind.
  def depth_gap?(_frame, _last_applied), do: true

  @doc """
  The bid and ask changes in a differential depth frame, as `{price, quantity}` levels.

  **A quantity of zero removes the level** — the vendor says so — and is returned as-is
  rather than filtered, because the caller applying the diff is the one that must delete
  rather than store it. Filtering here would drop the deletion and leave a level nobody
  quotes standing forever.
  """
  @spec depth_changes(map()) :: %{bids: [{Decimal.t(), Decimal.t()}], asks: list()}
  def depth_changes(frame) do
    %{bids: levels(frame["b"]), asks: levels(frame["a"])}
  end

  @doc """
  An `OrderBookDelta` from a `{symbol}@depth` / `@depthFast` differential frame.

  Built on `depth_changes/1`, side-tagging each level the way `OrderBookDelta.level/0`
  requires — bids first, then asks. The venue does not interleave the two sides by time
  within one frame, so concatenating them in that order loses no ordering information the
  frame itself carried.

  `sequence` is the frame's `u` — the update id this diff advances the book to, the same
  value `depth_gap?/2` compares the *next* frame's `U` against. A quantity of zero is
  carried through unresolved, exactly as `depth_changes/1` and `OrderBookDelta`'s own
  moduledoc both require: it means the level ceased to exist, and deciding that is the
  consumer's job, not this package's.
  """
  @spec to_order_book_delta(map(), String.t()) ::
          {:ok, OrderBookDelta.t()} | {:error, term()}
  def to_order_book_delta(frame, symbol) do
    with {:ok, timestamp} <- nanosecond_time(frame["E"]) do
      %{bids: bids, asks: asks} = depth_changes(frame)

      levels =
        Enum.map(bids, fn {price, quantity} -> {:bid, price, quantity} end) ++
          Enum.map(asks, fn {price, quantity} -> {:ask, price, quantity} end)

      {:ok,
       OrderBookDelta.new(
         symbol: symbol,
         levels: levels,
         timestamp: timestamp,
         sequence: frame["u"],
         provider: :gemini
       )}
    end
  end

  # Sorted here, not passed through in the venue's row order. `Core.Types.OrderBook` makes
  # the ordering part of the contract in as many words — "a caller reading `hd(bids)` as the
  # best bid is reading it correctly, and a venue package that returns venue-order without
  # re-sorting has broken the contract even though every value in it is true" — and this
  # decoder returned whatever the venue happened to put first. A wrong best bid made
  # entirely of real numbers is the failure mode this family exists to refuse.
  #
  # `dp_exchange_coinbase` was the only package in the family already doing this; the sort
  # matches its `sorted/2`, including `{:desc, Decimal}` rather than term order, because
  # `Decimal` structs do not compare correctly as terms.
  #
  # A level whose PRICE cannot be read is dropped rather than carried as `{nil, _}`:
  # `@type level :: {Decimal.t(), Decimal.t()}` has no nil in it, `hd(bids)` landing on one
  # hands a consumer a best bid of `nil`, and a nil price cannot be sorted against a real
  # one anyway. `dp_exchange_schwab` and `dp_exchange_webull` both filter theirs the same
  # way; this copy was the one that did not.
  #
  # A nil QUANTITY is kept: `OrderBook` carries what the venue said about size, and a level
  # that states a price but no size is a real shape rather than an unreadable one.
  # A SNAPSHOT side: read, then sorted. `Core.Types.OrderBook` is "a full snapshot with
  # eager, sorted `bids`/`asks` lists", and makes the ordering part of the contract in as
  # many words — "a caller reading `hd(bids)` as the best bid is reading it correctly, and a
  # venue package that returns venue-order without re-sorting has broken the contract even
  # though every value in it is true". This returned whatever the venue put first, so
  # `hd(bids)` was a wrong best bid made entirely of real numbers.
  #
  # `{direction, Decimal}` rather than term order, matching `dp_exchange_coinbase`'s
  # `sorted/2` — the only package in the family that was already doing this — because
  # `Decimal` structs do not compare correctly as plain terms.
  defp levels(rows, direction) when is_list(rows),
    do:
      rows |> parsed_levels() |> Enum.sort_by(fn {price, _qty} -> price end, {direction, Decimal})

  defp levels(_absent, _direction), do: []

  # A DELTA side: read, and left in the venue's order. `Core.Types.OrderBookDelta` requires
  # exactly that — its entries "arrive in the venue's own order", and sorting them "would
  # either drop the venue's ordering or invent one that was never sent". The two types want
  # opposite things here and the contract says so, which is why these are separate.
  defp levels(rows) when is_list(rows), do: parsed_levels(rows)
  defp levels(_absent), do: []

  # A level whose PRICE cannot be read is dropped rather than carried as `{nil, _}`:
  # `@type level :: {Decimal.t(), Decimal.t()}` has no nil in it, `hd(bids)` landing on one
  # hands a consumer a best bid of `nil`, and a nil price cannot be sorted against a real one
  # anyway. `dp_exchange_schwab` and `dp_exchange_webull` both filter theirs the same way;
  # this copy was the one that did not.
  #
  # A nil QUANTITY is kept. `OrderBook` carries what the venue said about size, and a level
  # stating a price but no size is a real shape rather than an unreadable one — and on the
  # delta path a zero or absent quantity is load-bearing, since it is how the venue says a
  # level ceased to exist.
  defp parsed_levels(rows) do
    Enum.flat_map(rows, fn
      [price, quantity] ->
        case decimal(price) do
          nil -> []
          parsed -> [{parsed, decimal(quantity)}]
        end

      _unreadable_row ->
        []
    end)
  end

  # Nanoseconds. Reading one as milliseconds puts the event ~50,000 years out; as seconds,
  # worse, because the result still looks like a date.
  defp nanosecond_time(ns) when is_integer(ns), do: {:ok, DateTime.from_unix!(ns, :nanosecond)}

  defp nanosecond_time(ns) when is_binary(ns) do
    case Integer.parse(ns) do
      {parsed, ""} -> {:ok, DateTime.from_unix!(parsed, :nanosecond)}
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp nanosecond_time(_absent), do: {:error, :missing_venue_timestamp}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # The same shape as `Rest`'s own copy, including the split between an absent field and a
  # present but unreadable one. A `nil` out of `decimal/1` means "absent, empty, unparseable,
  # or a NaN/Infinity this package refuses"; this is how a field says it may not carry that
  # forward.
  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.parse/1` requiring the whole string be consumed is NOT a sufficient guard on
  # its own, which is the half this copy was missing. "NaN", "Inf" and "-Inf" all parse
  # fully and case-insensitively — `"-nan"` and `"inf"` too — so each arrived here as a
  # perfectly well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than the raise this parse replaced, and it fails a long way from the
  # cause. Measured: `Decimal.add(nan, 1)` is NaN, so it poisons a consumer's arithmetic
  # silently; `Decimal.compare(nan, _)` RAISES `invalid_operation: operation on NaN`, in
  # the consumer's own process, with a message naming Decimal rather than the venue that
  # sent it. An Infinity is quieter still — it compares greater than everything and never
  # raises at all.
  #
  # `dp_exchange_webull` found this and guarded both of its own copies; the other four
  # venues guarded none of their nine. Fixed where it was found, not where it applied —
  # which is why this comment is in each of them now rather than one of them.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        if Decimal.nan?(parsed) or Decimal.inf?(parsed), do: nil, else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil
end
