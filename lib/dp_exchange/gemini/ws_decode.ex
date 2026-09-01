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

  alias DpExchange.Core.Types.{OrderBook, TopOfBook, Trade}

  @doc """
  A `Trade` from a `{symbol}@trade` frame.

  `aggressor` is **inverted from `m`**: see the moduledoc. `m: true` (buyer is maker) means
  the seller lifted, so the aggressor is `:sell`.
  """
  @spec to_trade(map(), String.t()) :: {:ok, Trade.t()} | {:error, term()}
  def to_trade(%{"p" => price, "q" => quantity} = frame, symbol) do
    with {:ok, timestamp} <- nanosecond_time(frame["E"]) do
      {:ok,
       %Trade{
         id: frame |> Map.get("t") |> to_string_or_nil(),
         symbol: symbol,
         side: aggressor(frame["m"]),
         price: decimal(price),
         quantity: decimal(quantity),
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
  nanosecond timestamp, so unlike some venues in this family `venue_time` is real here.
  """
  @spec to_top_of_book(map(), String.t(), DateTime.t()) ::
          {:ok, TopOfBook.t()} | {:error, term()}
  def to_top_of_book(frame, symbol, observed_at) do
    with {:ok, venue_time} <- nanosecond_time(frame["E"]) do
      {:ok,
       %TopOfBook{
         symbol: symbol,
         bid: decimal(frame["b"]),
         ask: decimal(frame["a"]),
         bid_size: decimal(frame["B"]),
         ask_size: decimal(frame["A"]),
         venue_time: venue_time,
         observed_at: observed_at,
         provider: :gemini
       }}
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
       bids: levels(frame["bids"]),
       asks: levels(frame["asks"]),
       timestamp: observed_at,
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

  defp levels(rows) when is_list(rows) do
    for [price, quantity] <- rows, do: {decimal(price), decimal(quantity)}
  end

  defp levels(_absent), do: []

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

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil
end
