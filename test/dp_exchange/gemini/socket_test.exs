defmodule DpExchange.Gemini.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.{Quote, TopOfBook}
  alias DpExchange.Gemini.Socket

  @moduletag :capture_log

  # The frame handlers are pure given a state, so they are driven directly. No socket is
  # opened and no venue is reached — a tier-1 test that dials a venue is a tier-2 test
  # wearing the wrong tag, and it will fail in CI on a bad day rather than a bad commit.
  defp state, do: %{subscriber: self(), request_id: 0}

  defp deliver(payload) do
    Socket.handle_frame({:text, Jason.encode!(payload)}, state())
  end

  # A real frame, captured from ws.gemini.com on 2026-08-28.
  @book_ticker %{
    "u" => 1_764_553_979_097_789,
    "E" => 1_787_936_147_810_330_084,
    "s" => "btcusd",
    "b" => "77845.79000",
    "B" => "0.0457361300",
    "a" => "77846.48000",
    "A" => "0.0143148700",
    "c" => "77834.11000",
    "C" => "0.0012854500"
  }

  describe "bookTicker frames" do
    test "deliver top-of-book with the canonical symbol and Decimal numerics" do
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{} = top}
      assert top.symbol == "BTC-USD"
      assert Decimal.equal?(top.bid, Decimal.new("77845.79000"))
      assert Decimal.equal?(top.ask, Decimal.new("77846.48000"))
      # The frame carries sizes, so they are carried too rather than dropped.
      assert Decimal.equal?(top.bid_size, Decimal.new("0.0457361300"))
      assert Decimal.equal?(top.ask_size, Decimal.new("0.0143148700"))
      assert top.provider == :gemini
    end

    test "a frame carrying a last trade also delivers it, as a separate Quote" do
      # Two facts on one frame, and each arrives in the type that says which it is: the
      # book in a TopOfBook, the execution in a Quote. Neither stands in for the other.
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{} = quote_struct}
      assert Decimal.equal?(quote_struct.price, Decimal.new("77834.11000"))
      refute Map.has_key?(quote_struct, :bid)
    end

    test "event time is read as NANOseconds" do
      # A factor of a million. Read as milliseconds this timestamp lands in the year
      # 58,000 and every staleness check passes forever.
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{venue_time: timestamp}}
      assert timestamp.year == 2026
    end

    test "an empty-string bid/ask does not crash the socket — reproduced live 2026-09-04" do
      # A 347-symbol subscribe against production wss://ws.gemini.com crashed this socket
      # within seconds: one frame carried "" for a bid, and Decimal.new/1 raised, taking
      # the whole connection down. A single-symbol test never sends enough traffic to hit
      # this — that is exactly why it shipped. `Decimal.parse/1` is nil-safe instead.
      frame = %{@book_ticker | "b" => "", "a" => "", "B" => "", "A" => ""}

      assert {:ok, _state} = deliver(frame)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{} = top}
      assert top.bid == nil
      assert top.ask == nil
      assert top.bid_size == nil
      assert top.ask_size == nil
    end

    test "\"null\" in place of a price does not crash the socket" do
      frame = %{@book_ticker | "c" => "null"}

      assert {:ok, _state} = deliver(frame)

      assert_receive {:dp_exchange, :gemini, %TopOfBook{}}
      refute_receive {:dp_exchange, :gemini, %Quote{}}
    end

    test "price is the last trade when the book has traded" do
      assert {:ok, _state} = deliver(@book_ticker)

      assert_receive {:dp_exchange, :gemini, %Quote{price: price}}
      assert Decimal.equal?(price, Decimal.new("77834.11000"))
    end

    test "a book that has never traded delivers top-of-book and NO quote" do
      # This test used to assert the opposite — that `price` falls back to the bid — and
      # its comment defended the bid as "a real quoted number". It is real, and it is not a
      # price: a bid is a resting order, a price is an execution. The fallback was the same
      # substitution this family shipped once already on another venue.
      #
      # An untraded book has a top and no last trade. That is what is delivered.
      assert {:ok, _state} = deliver(Map.drop(@book_ticker, ["c", "C"]))

      assert_receive {:dp_exchange, :gemini, %TopOfBook{bid: bid, ask: ask}}
      assert Decimal.equal?(bid, Decimal.new("77845.79000"))
      assert ask

      refute_receive {:dp_exchange, :gemini, %Quote{}}, 50
    end

    test "a frame with NO event time delivers nothing at all" do
      # On a stream, refusing to substitute means dropping the frame. A quote whose
      # freshness cannot be stated must not reach a consumer.
      assert {:ok, _state} = deliver(Map.delete(@book_ticker, "E"))

      refute_receive {:dp_exchange, :gemini, %Quote{}}, 50
    end

    test "a symbol with an overlapping quote still splits correctly off the wire" do
      assert {:ok, _state} = deliver(%{@book_ticker | "s" => "aavegusd"})

      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "AAVE-GUSD"}}
    end
  end

  describe "control frames" do
    test "a failed subscribe raises a notice rather than passing silently" do
      # Continuing quietly is how a feed reports healthy while delivering nothing.
      # `:refusal`, not `:coverage_change`: this is the venue's own word about a
      # subscription it received and declined — `Core.Notice`'s own moduledoc defines
      # `:refusal` as "a symbol the venue will not carry".
      assert {:ok, _state} = deliver(%{"id" => 1, "status" => 400})

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :refusal} = notice}
      assert notice.details.subscribe_status == 400
    end

    test "a successful subscribe ack is not noise" do
      assert {:ok, _state} = deliver(%{"id" => 1, "status" => 200})

      refute_receive {:dp_exchange, :gemini, %Notice{}}, 50
    end
  end

  describe "frames this package does not model" do
    test "unrecognised JSON is ignored, not crashed on" do
      assert {:ok, _state} = deliver(%{"e" => "depthUpdate", "s" => "btcusd"})
    end

    test "malformed JSON is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
    end

    test "a binary frame is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:binary, <<1, 2, 3>>}, state())
    end
  end

  describe "connection lifecycle" do
    test "connecting raises link_up" do
      assert {:ok, _state} = Socket.handle_connect(:conn, state())

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_up}}
    end

    test "disconnecting raises link_down and asks to reconnect" do
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}
    end

    test "the disconnect notice carries no credential-shaped keys" do
      # `Notice.new/3` refuses them, and these packages are public — notices get pasted
      # into issues.
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:dp_exchange, :gemini, %Notice{details: details}}
      assert Map.keys(details) == [:reason]
    end
  end

  describe "connect_opts/1 — the connect timeout budget start_link/1 actually uses" do
    # `start_link/1` itself dials a real socket and can't be exercised here (see the
    # module note at the top of this file), so this pins the keyword list it builds and
    # passes to `WebSockex.start_link/4` instead — the one thing that actually determines
    # the connect budget. Before this existed, `start_link/1` passed no opts to
    # `WebSockex.start_link/4` at all, silently inheriting websockex's own 6s/5s defaults
    # rather than the 3s/2s this package chose against its own `@call_timeout` budget; a
    # regression back to that would not show up as a compile error or a crash, only as a
    # slow venue eventually wedging every consumer sharing one `Feed`.
    test "defaults to this package's own chosen budget, not websockex's" do
      assert Socket.connect_opts([]) == [
               socket_connect_timeout: 3_000,
               socket_recv_timeout: 2_000
             ]
    end

    test "a caller's :socket_connect_timeout wins over the default" do
      assert Socket.connect_opts(socket_connect_timeout: 9_000)[:socket_connect_timeout] ==
               9_000
    end

    test "a caller's :socket_recv_timeout wins over the default" do
      assert Socket.connect_opts(socket_recv_timeout: 9_000)[:socket_recv_timeout] == 9_000
    end

    test "unrelated opts (subscriber, url, ...) are not carried into the connect opts" do
      # `start_link/1`'s own `opts` carry `:subscriber` always, and `:url` on ordinary use
      # — neither is a `websockex` connection option, and `WebSockex.Conn` would ignore an
      # unknown key rather than reject it, so a leak here would be silent.
      opts = [subscriber: self(), url: "wss://example.invalid", socket_connect_timeout: 1_000]

      assert Socket.connect_opts(opts) == [
               socket_connect_timeout: 1_000,
               socket_recv_timeout: 2_000
             ]
    end
  end

  describe "the link reports itself on the metrics channel too" do
    # `Core.Telemetry` documented `[:dp_exchange, :link, …]` as events "every venue package
    # emits" and nothing in the family emitted any of them, for as long as the spec existed.
    # `:telemetry.attach/4` against a name nobody emits SUCCEEDS, so a consumer's dashboard
    # showed an empty panel — which reads as a venue with no traffic, not as an unimplemented
    # spec. These tests attach real handlers: one that only called an emitter and checked it
    # returned `:ok` would pass just as happily against the version that emitted nothing.
    setup do
      test_pid = self()
      handler_id = "link-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:dp_exchange, :link, :up],
          [:dp_exchange, :link, :down],
          [:dp_exchange, :link, :event]
        ],
        fn event, measurements, metadata, _config ->
          # Scoped by provider: `:telemetry` handlers are global to the VM, so an unscoped
          # one also receives every other concurrently-running test's events.
          if metadata.provider == :gemini do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "connecting emits link up" do
      assert {:ok, _state} = Socket.handle_connect(:conn, state())
      assert_receive {:telemetry, [:dp_exchange, :link, :up], %{count: 1}, _metadata}
    end

    test "disconnecting emits link down with an already-inspected reason" do
      # Aggregators group by value; a raw reason carrying a pid or a socket ref would make
      # every occurrence a distinct series.
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:telemetry, [:dp_exchange, :link, :down], %{count: 1}, metadata}
      assert is_binary(metadata.reason)
      assert metadata.reason =~ "closed"
    end

    test "every frame is a link event, counted with its wire size" do
      payload = Jason.encode!(%{"e" => "bookTicker"})
      assert {:ok, _state} = Socket.handle_frame({:text, payload}, state())

      assert_receive {:telemetry, [:dp_exchange, :link, :event], measurements, metadata}
      assert measurements.bytes == byte_size(payload)
      assert measurements.count == 1
      assert metadata.type == :frame
    end

    test "a frame that does NOT parse is still counted — the venue still sent it" do
      # Counting only what parsed would make a decoder bug here look like a silent venue.
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
      assert_receive {:telemetry, [:dp_exchange, :link, :event], %{bytes: 9}, _metadata}
    end
  end

  describe "reconnect backoff — the storm websockex has no delay of its own against" do
    test "attempt 1 waits nothing: a healthy session that dropped reconnects at once" do
      assert Socket.reconnect_delay_ms(1) == 0
    end

    test "each consecutive failure doubles, capped at 30 seconds" do
      # `on_disconnect/5` in the transport calls `open_connection/3` and, on failure, calls
      # ITSELF with `attempt + 1` — nothing between the turns. Without this the socket
      # retries at full connect speed forever against whatever is refusing it, and the
      # causes are the ones that do not fix themselves by being retried sooner: a credential
      # the venue stopped honouring, an IP it started refusing, a maintenance window.
      assert Socket.reconnect_delay_ms(2) == 1_000
      assert Socket.reconnect_delay_ms(3) == 2_000
      assert Socket.reconnect_delay_ms(4) == 4_000
      assert Socket.reconnect_delay_ms(5) == 8_000
      assert Socket.reconnect_delay_ms(6) == 16_000
      assert Socket.reconnect_delay_ms(7) == 30_000
      assert Socket.reconnect_delay_ms(50) == 30_000
    end

    test "the cap holds against an attempt number large enough to overflow a naive shift" do
      # `:math.pow(2, attempt - 2)` on a long-lived storm produces a float far beyond any
      # integer anyone wants to multiply. `min/2` is applied to the result, so the only
      # thing that matters is that it stays pinned and stays an integer.
      delay = Socket.reconnect_delay_ms(2_000)

      assert delay == 30_000
      assert is_integer(delay)
    end

    test "handle_disconnect/2 reconnects immediately when the transport reports attempt 1" do
      # The healthy-blip path, and the one every other test in this file exercises by
      # calling the callback with a bare `%{reason: ...}`. Timed rather than assumed: a
      # regression that slept here would stall a socket on every ordinary drop.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, state())

      # Against the smallest possible BACKOFF (1s at attempt 2), not an arbitrary budget.
      # This asserted `< 500`, which is stricter than the claim needs — the claim is "no
      # backoff was applied", and any wait under a second proves that. Under a loaded
      # full-suite run the 500ms version failed while the behaviour was correct, which is the
      # same timing-assertion-holds-when-quiet shape as the rate-limiter bucket race and
      # `Core.PollingFeed`'s poll-interval waits.
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "handle_disconnect/2 actually waits once reconnects are failing" do
      # Attempt 3 is `@base_reconnect_delay_ms * 2` = 2000ms. Asserting the elapsed time
      # rather than only the pure function is what proves the delay is WIRED IN — the
      # function existed in `dp_exchange_schwab` all along, and the bug in the other three
      # packages was never that the arithmetic was wrong, it was that nothing called it.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 3}, state())

      assert System.monotonic_time(:millisecond) - started >= 2_000
    end
  end
end
