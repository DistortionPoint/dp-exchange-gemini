defmodule DpExchange.Gemini.TickAaSocketTest do
  @moduledoc """
  `DpExchange.Gemini.Socket` branches the rest of the suite never ran: how `start_link/1`
  resolves its URL, a subscribe against a socket that is gone or does not speak `:sys`, the
  depth-resync bookkeeping when an earlier resync already left entries behind, a session that
  lasted, and two malformed frames.

  Frame handlers and `handle_info/2` are driven directly against a hand-built state. The two
  `start_link/1` tests that connect do so to a TCP server on `127.0.0.1`; the rest fail
  before any connection is attempted. Tier 1: nothing here reaches a venue.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.{OrderBook, OrderBookDelta, Quote, TopOfBook}
  alias DpExchange.Gemini.Socket

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @key {"BTC-USD", :depth}
  @other {"ETH-USD", :depth}

  @diff %{
    "e" => "depthUpdate",
    "E" => 1_787_936_147_000_000_000,
    "s" => "btcusd",
    "U" => 40,
    "u" => 45,
    "b" => [["3610.00", "1.5"]],
    "a" => [["3611.00", "0"]]
  }

  defp state(overrides \\ %{}) do
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

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  defp no_trust_store, do: Config.put_override(:cacerts_loader, fn -> :erlang.error(:enoent) end)

  describe "start_link/1 resolves its URL" do
    test "a forwarded url: nil takes the default URL instead of raising" do
      # `Keyword.get_lazy/3` defaulted only an ABSENT `:url`, so `url: nil` (forwarded by
      # `Feed`'s `Keyword.take/2`) went on as the URL and `URI.parse/1` raised.
      port = serve_one_upgrade()
      Config.put_override(:websocket_url, "ws://127.0.0.1:#{port}/")

      assert {:ok, socket_pid} = Socket.start_link(url: nil, subscriber: self())
      on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

      assert_receive {:dialled, ^port}, 5_000
    end

    test "with no :url at all, the :websocket_url seam is what is dialled" do
      port = serve_one_upgrade()
      Config.put_override(:websocket_url, "ws://127.0.0.1:#{port}/")

      assert {:ok, socket_pid} = Socket.start_link(subscriber: self())
      on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

      assert_receive {:dialled, ^port}, 5_000
    end

    test "with no seam either, the venue's wss URL is built, so TLS is required" do
      # The venue's own URL is `wss://`. With no trust store it is refused before any dial,
      # which is also what keeps this test from reaching the venue.
      Config.put_override(:websocket_url, nil)
      no_trust_store()

      for opts <- [[], [channels: [:depth]], [channels: [:depth_fast]]] do
        assert {:error, {:tls_trust_store_unavailable, reason}} =
                 Socket.start_link([subscriber: self()] ++ opts)

        assert reason =~ "enoent"
      end
    end

    test "a URL with no scheme, or one that is not a string, takes the TLS options" do
      # Only a URL that is clearly `ws` skips TLS, so the failure is toward verification.
      no_trust_store()

      for url <- ["127.0.0.1", URI.parse("ws://127.0.0.1:1/")] do
        assert {:error, {:tls_trust_store_unavailable, _reason}} =
                 Socket.start_link(url: url, subscriber: self())
      end
    end
  end

  describe "subscribe/3 against a socket that cannot be reached" do
    test "a dead socket is reported as gone, on a diff and on a partial-depth channel" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000

      assert {:error, {:send_exit, :noproc}} = Socket.subscribe(dead, ["BTC-USD"], :depth)
      assert {:error, {:send_exit, :noproc}} = Socket.subscribe(dead, ["BTC-USD"], :depth5)
    end

    test "a name nothing is registered under is reported as gone, and nothing is sent to it" do
      # `send/2` to an unregistered name raises; the announce and the withdrawal both skip it.
      assert {:error, {:send_exit, :noproc}} =
               Socket.subscribe(:tick_aa_socket_never_registered, ["BTC-USD"], :depth)

      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "a failed send gives back the depth channel this call claimed, and only that" do
      stub = start_stub(%{depth_streams: MapSet.new([@other])})

      assert {:error, :stub_refused} = Socket.subscribe(stub, ["BTC-USD"], :depth)
      assert :sys.get_state(stub).depth_streams == MapSet.new([@other])

      # Already held before the call, so not this call's to give back.
      assert {:error, :stub_refused} = Socket.subscribe(stub, ["ETH-USD"], :depth)
      assert :sys.get_state(stub).depth_streams == MapSet.new([@other])
    end

    test "a process that acknowledges a replace without running it has nothing released" do
      # Not a real socket: any `:sys` process runs the claim before replying. Without the
      # claim's report nothing is known to be this call's, so nothing is given back.
      stub = start_acknowledging_stub()

      assert {:error, :stub_refused} = Socket.subscribe(stub, ["BTC-USD"], :depth)
      assert_received :replace_state_acknowledged
      refute_received :replace_state_acknowledged

      assert {:error, :stub_refused} = Socket.subscribe(stub, ["BTC-USD"], :depth5)
      assert_received :replace_state_acknowledged
      refute_received :replace_state_acknowledged
    end
  end

  describe "the depth resync keeps what earlier resyncs recorded" do
    test "starting a resync stamps its key beside another key's stamp" do
      ref = make_ref()

      pending =
        state(%{
          depth_resync: %{@key => {:pending, ref}},
          depth_streams: MapSet.new([@key]),
          depth_resync_at: %{@other => 1}
        })

      assert {:reply, {:text, unsubscribe}, unsubscribing} =
               Socket.handle_info({:resync_depth, @key, ref}, pending)

      assert %{"method" => "unsubscribe", "params" => ["btcusd@depth"]} =
               Jason.decode!(unsubscribe)

      assert %{@other => 1, @key => at} = unsubscribing.depth_resync_at
      assert is_integer(at)
    end

    test "a resubscribe whose ref is not the key's current one does nothing" do
      subscribing =
        state(%{
          depth_resync: %{@key => {:subscribing, make_ref()}},
          depth_streams: MapSet.new([@key])
        })

      assert {:ok, ^subscribing} =
               Socket.handle_info({:resubscribe_depth, @key, make_ref()}, subscribing)
    end

    test "an unanswered unsubscribe adds to the failures already counted" do
      ref = make_ref()

      unsubscribing =
        state(%{
          depth_resync: %{@key => {:unsubscribing, ref, 1}},
          depth_streams: MapSet.new([@key]),
          depth_resync_failures: %{@key => 1}
        })

      assert {:ok, restarted} = Socket.handle_info({:resync_timeout, @key, ref}, unsubscribing)

      assert restarted.depth_resync_failures == %{@key => 2}
      assert %{@key => {:pending, new_ref}} = restarted.depth_resync

      assert_received {:dp_exchange, :gemini,
                       %Notice{kind: :coverage_change, details: %{delivering: false}}}

      # Two failures earn a 10s backoff, so the restart is not immediate.
      refute_receive {:resync_depth, @key, ^new_ref}
    end

    test "a refused resubscribe adds to the failures and keeps another key's retry" do
      other_retry = make_ref()

      awaiting =
        state(%{
          depth_resync: %{@key => {:awaiting, make_ref(), 77}},
          depth_streams: MapSet.new([@key]),
          depth_resync_failures: %{@key => 1},
          depth_retry: %{@other => other_retry}
        })

      {:ok, armed} = Socket.handle_info({:awaiting_ack, 77}, awaiting)

      assert {:ok, refused} = Socket.handle_frame(frame(%{"id" => 77, "status" => 400}), armed)

      assert refused.depth_resync_failures == %{@key => 2}
      assert %{@other => ^other_retry, @key => retry_ref} = refused.depth_retry
      assert is_reference(retry_ref)
      assert refused.depth_resync == %{}
      refute MapSet.member?(refused.depth_streams, @key)

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :coverage_change,
                         details: %{delivering: false, symbol: "BTC-USD", status: 400}
                       }}
    end

    test "the snapshot forgives the resynced key's failures, and only that key's" do
      awaiting =
        state(%{
          depth_snapshot?: true,
          depth_resync: %{@key => {:awaiting, make_ref(), 5}},
          depth_streams: MapSet.new([@key]),
          depth_resync_failures: %{@key => 3, @other => 1},
          last_depth_update: %{"BTC-USD" => 5}
        })

      assert {:ok, taken} = Socket.handle_frame(frame(@diff), awaiting)

      assert_received {:dp_exchange, :gemini, %OrderBook{symbol: "BTC-USD", sequence: 45}}
      assert taken.depth_resync == %{}
      assert taken.depth_resync_failures == %{@other => 1}
    end
  end

  describe "connection lifecycle" do
    test "a session that lasted resets the short-session count and reconnects at once" do
      long_ago = System.monotonic_time(:millisecond) - 60_000
      lasted = state(%{connected_at: long_ago, short_sessions: 3})

      assert {:reconnect, after_drop} = Socket.handle_disconnect(%{reason: :closed}, lasted)

      assert after_drop.short_sessions == 0
      assert after_drop.connected_at == nil
    end

    test "a reconnect is reported to a subscriber registered by name too" do
      Process.register(self(), :tick_aa_named_subscriber)

      reconnected = state(%{subscriber: :tick_aa_named_subscriber, connected_once?: true})

      assert {:ok, _state} = Socket.handle_connect(:conn, reconnected)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :link_up}}
      test_pid = self()
      assert_received {:dp_exchange, :gemini, :reconnected, ^test_pid}
    end
  end

  describe "malformed frames" do
    test "a depth diff naming no symbol is not delivered, and says so" do
      assert {:ok, _state} = Socket.handle_frame(frame(Map.delete(@diff, "s")), state())

      assert_received {:dp_exchange, :gemini,
                       %Notice{
                         kind: :data_quality,
                         details: %{reason: :undecodable_depth_update, symbol: nil}
                       }}

      refute_received {:dp_exchange, :gemini, %OrderBookDelta{}}
    end

    test "an empty last trade delivers the book and no Quote" do
      book_ticker = %{
        "u" => 1_764_553_979_097_789,
        "E" => 1_787_936_147_810_330_084,
        "s" => "btcusd",
        "b" => "77845.79000",
        "B" => "0.0457361300",
        "a" => "77846.48000",
        "A" => "0.0143148700",
        "c" => ""
      }

      assert {:ok, after_frame} = Socket.handle_frame(frame(book_ticker), state())

      assert_received {:dp_exchange, :gemini, %TopOfBook{symbol: "BTC-USD"}}
      refute_received {:dp_exchange, :gemini, %Quote{}}
      assert Map.get(after_frame, :last_trade_price, %{}) == %{}
    end
  end

  # A stand-in socket that speaks `:sys` and refuses every send.
  defp start_stub(state) do
    spawn_link(fn -> stub_loop(state) end)
  end

  defp stub_loop(state) do
    receive do
      {:"$websockex_send", from, _frame} ->
        :gen.reply(from, {:error, :stub_refused})
        stub_loop(state)

      {:system, from, {:replace_state, fun}} ->
        new_state = fun.(state)
        :gen.reply(from, {:ok, new_state})
        stub_loop(new_state)

      {:system, from, :get_state} ->
        :gen.reply(from, {:ok, state})
        stub_loop(state)

      _ignored ->
        stub_loop(state)
    end
  end

  # Acknowledges `:sys.replace_state/3` without running the function, and says so.
  defp start_acknowledging_stub do
    test_pid = self()
    held = %{partial_depth_claims: MapSet.new([{:depth5, "BTC-USD"}])}
    spawn_link(fn -> acknowledging_loop(test_pid, held) end)
  end

  defp acknowledging_loop(test_pid, held) do
    receive do
      {:"$websockex_send", from, _frame} ->
        :gen.reply(from, {:error, :stub_refused})

      {:system, from, {:replace_state, _fun}} ->
        send(test_pid, :replace_state_acknowledged)
        :gen.reply(from, {:ok, held})

      _ignored ->
        :ok
    end

    acknowledging_loop(test_pid, held)
  end

  # Accepts one connection, reports it, completes the upgrade and holds it open.
  defp serve_one_upgrade do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    test_pid = self()

    server =
      spawn(fn ->
        {:ok, client_socket} = :gen_tcp.accept(listen_socket, 10_000)
        send(test_pid, {:dialled, port})
        upgrade(client_socket)
        hold(client_socket)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp hold(socket) do
    case :gen_tcp.recv(socket, 0, 60_000) do
      {:ok, _data} -> hold(socket)
      {:error, _closed} -> :ok
    end
  end

  defp upgrade(socket) do
    {:ok, request} = recv_until_headers_end(socket, "")

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )
  end

  defp recv_until_headers_end(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_until_headers_end(socket, acc <> data)
        {:error, _reason} = error -> error
      end
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end
