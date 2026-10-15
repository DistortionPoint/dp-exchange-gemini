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
         {:ok, price} <- required_price(price, :price),
         {:ok, quantity} <- required_quantity(quantity, :quantity) do
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
  states `venue_time: nil` (the venue gives that reply no time), rather than refusing. Same
  venue, same type, two answers — and the transport was deciding which.

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
  #
  # **A price or size that is present and unreadable refuses the book.** `decimal/1` turned
  # it into `nil`, and `TopOfBook` reads a `nil` level as "no resting order", which is a claim
  # about the book the venue never made. An ABSENT field is still `nil`, as the type defines.
  @spec to_top_of_book(term(), String.t(), DateTime.t()) ::
          {:ok, TopOfBook.t()} | {:error, :unexpected_frame_shape}
  # A frame that is not an object (a decoded JSON list or scalar handed straight in) is not a
  # book ticker; `Access` on a list or a string raised.
  def to_top_of_book(frame, _symbol, _observed_at) when not is_map(frame),
    do: {:error, :unexpected_frame_shape}

  def to_top_of_book(frame, symbol, observed_at) do
    with {:ok, bid} <- stated_price(frame["b"]),
         {:ok, ask} <- stated_price(frame["a"]),
         {:ok, bid_size} <- stated_size(frame["B"]),
         {:ok, ask_size} <- stated_size(frame["A"]) do
      {:ok,
       %TopOfBook{
         symbol: symbol,
         bid: bid,
         ask: ask,
         # A side priced 0 is no resting order (MD6): its size goes with it.
         bid_size: if(bid, do: bid_size),
         ask_size: if(ask, do: ask_size),
         venue_time: venue_time_or_nil(frame["E"]),
         observed_at: observed_at,
         provider: :gemini
       }}
    end
  end

  # `""` is the venue's own empty side (reproduced live 2026-09-04), the same as absent.
  defp stated_decimal(empty) when empty in [nil, ""], do: {:ok, nil}

  defp stated_decimal(value) do
    case decimal(value) do
      nil -> {:error, :unexpected_frame_shape}
      parsed -> {:ok, parsed}
    end
  end

  # A size the venue stated is zero or more. A negative one is not a quantity resting on a book,
  # and carried through it reads as a real size.
  defp stated_size(value) do
    with {:ok, parsed} <- stated_decimal(value) do
      if parsed && Decimal.compare(parsed, 0) == :lt,
        do: {:error, :unexpected_frame_shape},
        else: {:ok, parsed}
    end
  end

  # A price of zero means no resting order on that side (`nil`); a negative or unreadable one
  # refuses the frame (family rule MD6).
  defp stated_price(value) do
    with {:ok, parsed} <- stated_decimal(value) do
      case parsed && Decimal.compare(parsed, 0) do
        nil -> {:ok, nil}
        :gt -> {:ok, parsed}
        :eq -> {:ok, nil}
        :lt -> {:error, :unexpected_frame_shape}
      end
    end
  end

  # Absent and present-but-unreadable answer the same way here, deliberately: both mean this
  # package cannot state the venue's time, and `nil` says that.
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
  @spec to_order_book(map(), String.t(), DateTime.t()) ::
          {:ok, OrderBook.t()} | {:error, :unexpected_response_shape}
  def to_order_book(%{"bids" => bids, "asks" => asks} = frame, symbol, observed_at)
      when is_list(bids) and is_list(asks) do
    # All-or-error. Found 2026-10-10 by reading `parsed_levels/1`: a snapshot row with an
    # unreadable price was dropped and one with an unreadable quantity kept as `{price, nil}`,
    # so a damaged frame was delivered as a complete book with every other value real. Diffs
    # already refuse through `fully_read?/2`; a snapshot holds itself to the same rule, and
    # `Socket` reports the refusal as a `:data_quality` notice.
    with {:ok, bids} <- read_sorted(bids, :desc),
         {:ok, asks} <- read_sorted(asks, :asc) do
      build_snapshot(frame, bids, asks, symbol, observed_at)
    end
  end

  # **Both sides are required.** The venue's AsyncAPI requires `bids` and `asks` on
  # `OrderBookSnapshot`, so a side that is `null` or not a list is not an empty side. It used
  # to become one: `levels/2` answered `[]` for it, and the frame was delivered as a whole
  # book in which nobody was bidding, with every other value real.
  def to_order_book(_frame, _symbol, _observed_at), do: {:error, :unexpected_response_shape}

  defp build_snapshot(frame, bids, asks, symbol, observed_at) do
    with {:ok, sequence} <- read_sequence(frame["lastUpdateId"]) do
      {:ok, snapshot_book(bids, asks, symbol, observed_at, sequence)}
    end
  end

  # The update id this snapshot stands at: absent is `nil` (nothing to order it against), a
  # whole number of zero or more is itself, and anything else is a frame this package cannot
  # place in the stream. A string or an object in an integer-typed field was carried onto the
  # book as it came, and `depth_gap?/2` compared the next diff against it.
  defp read_sequence(nil), do: {:ok, nil}
  defp read_sequence(sequence) when is_integer(sequence) and sequence >= 0, do: {:ok, sequence}
  defp read_sequence(_unreadable), do: {:error, :unexpected_response_shape}

  defp snapshot_book(bids, asks, symbol, observed_at, sequence) do
    %OrderBook{
      symbol: symbol,
      bids: bids,
      asks: asks,
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
      sequence: sequence,
      provider: :gemini
    }
  end

  @doc """
  Whether applying `frame` to a book last updated at `last_applied` would skip updates.

  The vendor's rule: a frame's `U` must not skip ahead of the last applied `u`. **`true`
  means discard the book and resubscribe** — not "retry", because the missing updates are
  gone and the local book is already wrong.

  `nil` for `last_applied` means nothing has been applied yet, which is never a gap.

  A stale or duplicate frame (`u <= last_applied`) is not a gap either; `stale_depth?/2` says
  so, and the socket drops such a frame before it asks whether there is a gap.
  """
  @spec depth_gap?(map(), integer() | nil) :: boolean()
  def depth_gap?(_frame, nil), do: false

  def depth_gap?(%{"U" => first_update}, last_applied)
      when is_integer(first_update) and is_integer(last_applied),
      do: first_update > last_applied + 1

  # A diff frame with no `U`, or a `last_applied` that is not an integer (it raised
  # `ArithmeticError` here), cannot be checked, and an unverifiable frame is treated as a
  # gap: continuing would apply it blind.
  def depth_gap?(_frame, _last_applied), do: true

  @doc """
  Whether a depth frame ending at `u` is a replay: `u` is at or before the last applied
  update id. Applied, it would re-apply old changes and move the sequence backwards, so
  the socket drops it (family rule MD9). Anything unreadable is not a replay; the caller
  refuses an unsequenced frame separately.
  """
  @spec stale_depth?(term(), term()) :: boolean()
  def stale_depth?(u, last_applied) when is_integer(u) and is_integer(last_applied),
    do: u <= last_applied

  def stale_depth?(_u, _last_applied), do: false

  @doc """
  Whether a depth frame's sequence went BACKWARDS by more than the frame's own span: the
  venue restarted the book's counter, which is a gap in effect (family rule MD9), not a
  replay to drop.

  The span is `u - U + 1` (1 when `U` is unreadable). A frame ending at or before the last
  applied `u`, but no further behind it than that span, is a duplicate or a frame only just
  late, and `stale_depth?/2` has it dropped. Anything unreadable is not a restart.
  """
  @spec depth_restart?(map(), term()) :: boolean()
  def depth_restart?(%{"u" => u} = frame, last_applied)
      when is_integer(u) and is_integer(last_applied) do
    span =
      case frame["U"] do
        first when is_integer(first) and first <= u -> u - first + 1
        _unreadable -> 1
      end

    u + span < last_applied
  end

  def depth_restart?(_frame, _last_applied), do: false

  @doc """
  An anchor `OrderBook` from the FIRST `{symbol}@depth`/`@depthFast` frame after
  (re)subscribing on a connection that requested the `snapshot` connection parameter
  (websocket.yaml:1263-1270).

  That frame carries the same envelope as every other `depthUpdate` — `e`, `E`, `s`, `U`,
  `u`, `b`, `a` — but `b`/`a` hold **absolute levels**, not a diff, and there is "no separate
  snapshot message and no lastUpdateId field": `u` is this book's sequence instead, the same
  value the next real diff's `U` is checked against. Every frame after this one, for the same
  symbol, is an ordinary diff — see `to_order_book_delta/2`.

  Sorted the same way `to_order_book/3` sorts a partial-depth snapshot — best price first,
  per `Core.Types.OrderBook`'s own contract — because this is the same shape of value
  (absolute levels), arriving on a different channel.

  `venue_time` is read from `E` when readable and `nil` otherwise, matching
  `to_top_of_book/3`'s own split: `depthUpdate` requires `E`, but a value this package
  cannot read is not one it invents a replacement for.
  """
  @spec to_order_book_from_depth_update(map(), String.t(), DateTime.t()) ::
          {:ok, OrderBook.t()} | {:error, :unexpected_response_shape}
  def to_order_book_from_depth_update(%{"b" => bids, "a" => asks} = frame, symbol, observed_at)
      when is_list(bids) and is_list(asks) do
    # All-or-error, as `to_order_book/3`: an unreadable row refuses the frame (2026-10-10).
    with {:ok, bids} <- read_sorted(bids, :desc),
         {:ok, asks} <- read_sorted(asks, :asc) do
      build_depth_anchor(frame, bids, asks, symbol, observed_at)
    end
  end

  # Same rule as `to_order_book/3`: both sides are required, and one that is `null` or not a
  # list is not an empty side.
  def to_order_book_from_depth_update(_frame, _symbol, _observed_at),
    do: {:error, :unexpected_response_shape}

  defp build_depth_anchor(frame, bids, asks, symbol, observed_at) do
    with {:ok, sequence} <- read_sequence(frame["u"]) do
      {:ok,
       %OrderBook{
         symbol: symbol,
         bids: bids,
         asks: asks,
         venue_time: venue_time_or_nil(frame["E"]),
         observed_at: observed_at,
         sequence: sequence,
         provider: :gemini
       }}
    end
  end

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
  @spec to_order_book_delta(term(), String.t()) ::
          {:ok, OrderBookDelta.t()} | {:error, term()}
  def to_order_book_delta(frame, _symbol) when not is_map(frame),
    do: {:error, :unexpected_response_shape}

  def to_order_book_delta(frame, symbol) do
    # Each side is decoded ONCE: `depth_changes/1` reads the rows, and `fully_read?/2` then
    # compares them with what the venue sent without parsing a second time. This used to run a
    # `readable_side/1` pass (every price and quantity through `Decimal.parse/1`) and then
    # `depth_changes/1` (the same parse again), twice per frame on the socket's hot path.
    with {:ok, timestamp} <- nanosecond_time(frame["E"]),
         %{bids: bids, asks: asks} <- depth_changes(frame),
         :ok <- fully_read?(frame["b"], bids),
         :ok <- fully_read?(frame["a"], asks),
         {:ok, sequence} <- read_sequence(frame["u"]) do
      levels =
        Enum.map(bids, fn {price, quantity} -> {:bid, price, quantity} end) ++
          Enum.map(asks, fn {price, quantity} -> {:ask, price, quantity} end)

      {:ok,
       OrderBookDelta.new(
         symbol: symbol,
         levels: levels,
         timestamp: timestamp,
         sequence: sequence,
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
  #
  # Read ONCE and refused whole: a row the venue sent and this package cannot read refuses the
  # side (`fully_read?/2`), and only a fully read side is sorted.
  defp read_sorted(rows, direction) when is_list(rows) do
    parsed = parsed_levels(rows)

    with :ok <- fully_read?(rows, parsed),
         :ok <- distinct_prices(parsed) do
      {:ok, Enum.sort_by(parsed, fn {price, _qty} -> price end, {direction, Decimal})}
    end
  end

  # **A price listed twice on one side of an absolute book is refused.** One size per price is
  # the shape of a snapshot; two rows at one price leave no way to say which size rests there,
  # and both were carried into the book as separate levels, every value real. `1.0` and `1.00`
  # are one price. (A DELTA is not checked: its rows are applied in order, so a repeated price
  # has a defined meaning there.)
  defp distinct_prices(levels) do
    prices = Enum.map(levels, fn {price, _qty} -> Decimal.normalize(price) end)

    if length(prices) == length(Enum.uniq(prices)),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  # A DELTA side: read, and left in the venue's order. `Core.Types.OrderBookDelta` requires
  # exactly that — its entries "arrive in the venue's own order", and sorting them "would
  # either drop the venue's ordering or invent one that was never sent". The two types want
  # opposite things here and the contract says so, which is why these are separate.
  defp levels(rows) when is_list(rows), do: parsed_levels(rows)
  defp levels(_absent), do: []

  # A diff side that is absent changed nothing, and reads as `[]`. One that is present and not
  # a list is unreadable, and applying the rest of that frame would advance the book's
  # sequence past changes this package could not read — the silent version of a gap, which
  # `depth_gap?/2` exists to make loud.
  #
  # **Every row, too.** A side that was a list was enough, and `parsed_levels/1` then dropped
  # a row whose price did not parse and kept one whose quantity did not as `nil`. On a delta
  # that is the same silent gap: a dropped row is a change the consumer never applies, and a
  # `nil` quantity is neither the venue's `"0"` (remove) nor a size. So the frame is
  # unreadable, and `Socket` reports it as one: discard and resubscribe.
  #
  # `parsed` is what `parsed_levels/1` made of `raw`. A row it dropped (not a pair, or an
  # unreadable price) makes the counts differ, and one it kept with an unreadable quantity
  # carries `nil`; either way the side is refused. That is exactly the old per-row rule
  # ("a pair of two readable decimals") decided from the one parse instead of a second.
  defp fully_read?(nil, []), do: :ok

  defp fully_read?(raw, parsed) when is_list(raw) do
    if length(raw) == length(parsed) and Enum.all?(parsed, fn {_price, qty} -> qty != nil end),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  defp fully_read?(_unreadable, _parsed), do: {:error, :unexpected_response_shape}

  # Found 2026-10-10: every caller checks the result with `fully_read?/2`, so a frame that
  # reaches a consumer never carries the drop or the nil below; `depth_changes/1`, which is
  # public, is the one caller that sees them.
  #
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
  #
  # **A price of zero or less is unreadable, and so is a negative quantity.** A level priced at
  # or below zero is not a price on a book, and a negative size is not a quantity resting at
  # one; both were carried through as real `Decimal`s, and a price of `-5` sorted to the worst
  # end and sat in the book looking like a level. They are dropped (price) or `nil` (quantity)
  # exactly as an unparseable one is, so `fully_read?/2` refuses the side. A quantity of zero
  # stays: on a diff it is the venue's removal.
  defp parsed_levels(rows) do
    Enum.flat_map(rows, fn
      [price, quantity] ->
        case positive_price(price) do
          nil -> []
          parsed -> [{parsed, level_quantity(quantity)}]
        end

      _unreadable_row ->
        []
    end)
  end

  defp positive_price(value) do
    case decimal(value) do
      nil -> nil
      parsed -> if Decimal.compare(parsed, 0) == :gt, do: parsed
    end
  end

  defp level_quantity(value) do
    case decimal(value) do
      nil -> nil
      parsed -> if Decimal.compare(parsed, 0) != :lt, do: parsed
    end
  end

  # Nanoseconds. Reading one as milliseconds puts the event ~50,000 years out; as seconds,
  # worse, because the result still looks like a date.
  #
  # Positive and in range, or refused. Both branches used `from_unix!/2`, which RAISES on a
  # value outside `DateTime`'s range, in the socket process, so one such frame dropped the
  # connection. Zero and negatives dated the event to 1970.
  #
  # **And only a nanosecond-scale one.** Any positive integer was accepted, so a venue (or a
  # proxy) sending milliseconds or microseconds in `E` produced a perfectly valid `DateTime` in
  # January 1970: 1787936147000 ms read as nanoseconds is 00:29:47 on 1 January 1970. The
  # window is 10^17 ns (March 1973) to 5 * 10^18 ns (2128); a value outside it is in another
  # unit, or not a time, and is refused like any other unreadable `E`.
  @min_epoch_ns 100_000_000_000_000_000
  @max_epoch_ns 5_000_000_000_000_000_000

  defp nanosecond_time(ns) when is_integer(ns) and ns >= @min_epoch_ns and ns <= @max_epoch_ns do
    case DateTime.from_unix(ns, :nanosecond) do
      {:ok, at} -> {:ok, at}
      {:error, _out_of_range} -> {:error, :missing_venue_timestamp}
    end
  end

  defp nanosecond_time(ns) when is_integer(ns), do: {:error, :missing_venue_timestamp}

  defp nanosecond_time(ns) when is_binary(ns) do
    case Integer.parse(ns) do
      {parsed, ""} -> nanosecond_time(parsed)
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp nanosecond_time(_absent), do: {:error, :missing_venue_timestamp}

  # Only a string or an integer is an id. `to_string/1` raised on a map or a list, in the
  # socket process.
  #
  # A string id is copied: it is a sub-binary of the whole decoded frame, and a `Trade` is the
  # one payload a consumer keeps for as long as it keeps a tape, so each id would otherwise
  # hold its frame alive with it.
  defp to_string_or_nil(value) when is_binary(value), do: :binary.copy(value)
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_absent_or_unreadable), do: nil

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

  # A traded size of zero or less is not a print: nothing changed hands. A negative one, carried
  # through, reads as a real quantity on the tape.
  defp required_quantity(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.compare(parsed, 0) == :gt,
        do: {:ok, parsed},
        else: {:error, {:non_positive_quantity, field, value}}
    end
  end

  # A traded price of zero or less is not a price (family rule MD6).
  defp required_price(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.compare(parsed, 0) == :gt,
        do: {:ok, parsed},
        else: {:error, {:non_positive_price, field, value}}
    end
  end

  @doc """
  The traded price in `value` (the book ticker's last-trade `c`), or `:error` when it is not
  a readable number greater than zero (family rule MD6).
  """
  @spec traded_price(term()) :: {:ok, Decimal.t()} | :error
  def traded_price(value) do
    case required_price(value, :price) do
      {:ok, price} -> {:ok, price}
      {:error, _reason} -> :error
    end
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: bounded(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  # Bounded like every other branch: `1.0e300` is a float the socket's `Jason.decode/1` can
  # hand over, and `Decimal.from_float/1` keeps its exponent (`1E+300`).
  defp decimal(value) when is_float(value), do: value |> Decimal.from_float() |> bounded()

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
        bounded(parsed)

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

  # A finite `Decimal` whose exponent is one a price or size can have, or `nil`. `"1e999999999"`
  # parses, and sorting or comparing it aligns exponents by building an integer of that many
  # digits: one frame stalls the socket process. NaN and Infinity carry no integer coefficient
  # and are refused here too.
  defp bounded(%Decimal{coef: coef, exp: exp} = value)
       when is_integer(coef) and exp >= -100 and exp <= 100,
       do: value

  defp bounded(_nan_infinite_or_unbounded), do: nil
end
