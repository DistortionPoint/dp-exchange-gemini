defmodule DpExchange.Gemini.Socket do
  @moduledoc """
  The venue's WebSocket connection — internal, and never named above the facade.

  Speaks `wss://ws.gemini.com`, the API Gemini's current documentation describes.
  **This is not the API the host adapter uses**, and the reasoning is in
  `docs/reference/gemini/websocket-api-replacement.md`. In one line: the host's
  `api.gemini.com/v2/marketdata` still answers, but it is absent from the vendor's current
  documentation and from four years of its changelog, so a package published for other
  people to depend on should not be built on it.

  ## Protocol

  Subscription is an RPC-shaped frame naming streams:

      {"method":"subscribe","params":["btcusd@bookTicker","ethusd@bookTicker"],"id":1}

  and the venue acknowledges with `{"id":1,"status":200}`.

  This package subscribes to **`@bookTicker`** and nothing else. That single stream carries
  best bid, best ask, and last trade price — everything a `Core.Types.Quote` needs, in one
  message per change.

  ### Which is why there is no order-book machinery here

  The host maintains a 182-line L2 book (`gemini/l2_book.ex`) whose entire purpose is to
  reconstruct a mid price from `l2_updates` deltas, because the endpoint it connects to
  offers no top-of-book message. This endpoint does. The book is not ported, and the
  moduledoc of the file that is not ported records why it existed — a mid computed from a
  single delta rather than the maintained book, which is the incident that created it.

  A caller wanting depth calls `get_order_book/2`, which is a REST snapshot with the
  venue's own per-level timestamps.

  ## Event time is nanoseconds

  The `E` field is **nanoseconds** since the epoch, not milliseconds. The difference is a
  factor of a million: read as milliseconds, a 2026 timestamp lands in the year 58,000 and
  every staleness check passes forever. Converted once, here.
  """

  use WebSockex

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Gemini.{Environment, SymbolFormat}

  require Logger

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    url =
      Keyword.get_lazy(opts, :url, fn ->
        opts |> Environment.resolve() |> Environment.websocket_url()
      end)

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      request_id: 0
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  @doc """
  Subscribes the connection to `@bookTicker` for each symbol.

  Returns `{:error, :send_timeout}` rather than exiting when the socket will not accept
  the frame — a caller can retry a batch, but it cannot recover from a linked exit it did
  not expect.
  """
  @spec subscribe(pid(), [String.t()]) :: :ok | {:error, term()}
  def subscribe(socket, symbols), do: send_rpc(socket, "subscribe", streams(symbols))

  @spec unsubscribe(pid(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(socket, symbols), do: send_rpc(socket, "unsubscribe", streams(symbols))

  defp streams(symbols) do
    Enum.map(symbols, fn symbol -> "#{SymbolFormat.to_exchange_symbol(symbol)}@bookTicker" end)
  end

  defp send_rpc(_socket, _method, []), do: :ok

  defp send_rpc(socket, method, params) do
    frame = Jason.encode!(%{"method" => method, "params" => params, "id" => 1})
    WebSockex.send_frame(socket, {:text, frame})
  catch
    :exit, _reason -> {:error, :send_timeout}
  end

  # --- callbacks ----------------------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    notify(state, Notice.new(:link_up, :gemini))
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify(state, Notice.new(:link_down, :gemini, details: %{reason: inspect(reason)}))
    {:reconnect, state}
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, message} -> handle_message(message, state)
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_frame(_other, state), do: {:ok, state}

  # A bookTicker frame. `s` is the symbol, `b`/`a` the best bid/ask, `c` the last trade
  # price — present only once the book has traded, which is why `price` falls back to the
  # bid rather than being invented.
  defp handle_message(%{"s" => native, "b" => bid, "a" => ask} = message, state) do
    with {:ok, timestamp} <- event_time(message) do
      quote_struct = %Quote{
        symbol: SymbolFormat.to_canonical_symbol(native),
        price: decimal(message["c"] || bid),
        bid: decimal(bid),
        ask: decimal(ask),
        volume: nil,
        timestamp: timestamp,
        provider: :gemini
      }

      send(state.subscriber, {:dp_exchange, :gemini, quote_struct})
    end

    {:ok, state}
  end

  # The subscribe acknowledgement. A non-200 is the venue refusing a subscription, which
  # a consumer needs to hear about — silently continuing is how a feed reports healthy
  # while delivering nothing.
  defp handle_message(%{"id" => _id, "status" => status}, state) when status != 200 do
    notify(state, Notice.new(:coverage_change, :gemini, details: %{subscribe_status: status}))
    {:ok, state}
  end

  defp handle_message(_other, state), do: {:ok, state}

  # Nanoseconds. Absent, and nothing is emitted — a quote whose freshness cannot be
  # stated must not be delivered, and on a stream that means dropping the frame rather
  # than stamping it with our own clock.
  defp event_time(%{"E" => nanoseconds}) when is_integer(nanoseconds) do
    DateTime.from_unix(div(nanoseconds, 1_000), :microsecond)
  end

  defp event_time(_other), do: {:error, :missing_venue_timestamp}

  defp notify(state, notice), do: send(state.subscriber, {:dp_exchange, :gemini, notice})

  defp decimal(nil), do: nil
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
end
