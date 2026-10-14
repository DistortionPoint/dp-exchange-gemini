defmodule DpExchange.Gemini.SocketVendoredWebSockexTest do
  @moduledoc """
  The two defects `DpExchange.Gemini.Vendor.WebSockex` exists to fix, each driven through
  a real `Socket.start_link/1` against a real TCP server on `127.0.0.1`. Tier 1, no network:
  a unit call to a callback cannot show that the library driving it does not stall or raise
  first.

    * **The opening handshake has a deadline**, `socket_connect_timeout` plus
      `socket_recv_timeout`. websockex 0.5.1 bounds each `recv` of the upgrade response
      separately and every chunk restarts that timer, so a peer that trickled the response
      held a start or a reconnect open indefinitely. Measured 2026-09-27 on Coinbase's
      `start_link/1` against a server sending one byte every 200 ms was still connecting
      at 12 s.
    * **A malformed close frame disconnects instead of crashing.** websockex 0.5.1's
      `websocket_loop/3` has no clause for `WebSockex.Frame.parse_frame/1`'s own error
      return, so a close frame with an invalid status code raised `CaseClauseError` before
      `handle_disconnect/2` could run. Measured live on Webull; the defect is websockex's.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.Socket

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # 200 + 300: the deadline under test is 500 ms.
  @timeouts [socket_connect_timeout: 200, socket_recv_timeout: 300]

  # FIN + close, length 10, "bye-bye!!!": the first two bytes are no valid close code.
  @malformed_close_frame <<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>

  test "a start whose upgrade response trickles in fails at the deadline" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&trickle/1])

    task = Task.async(fn -> Socket.start_link(socket_opts(port)) end)

    # Without the deadline this call does not return at all, so the yield is what fails.
    # No tighter wall-clock bound: under a loaded suite 500 ms of deadline measured 3.6 s
    # end to end, and returning at all is the property under test.
    assert {:ok, {:error, %WebSockex.ConnError{original: :timeout}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
  end

  test "a reconnect whose upgrade response trickles in fails at the deadline and retries" do
    test_pid = self()
    {listen_socket, port} = listen()

    serve(listen_socket, [
      &upgrade_then_close/1,
      &trickle/1,
      fn socket ->
        send(test_pid, :third_connection)
        :gen_tcp.close(socket)
      end
    ])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # The first reconnect trickles. Only a deadline ends it, and only then can the socket
    # make its next attempt: attempt 2 waits one second of backoff, so this lands at about
    # 1.5 s. Without the deadline it never arrives.
    assert_receive :third_connection, 10_000
  end

  test "a malformed close frame disconnects cleanly instead of crashing the socket" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_malformed_close/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # `handle_disconnect/2` ran: it is what sends `:link_down`. Upstream crashed first.
    assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.reason == :disconnected
    assert details.message =~ "invalid_close_code"
    assert Process.alive?(socket_pid)
  end

  test "a frame that never finishes is closed at the size bound instead of buffered forever" do
    # The header declares 4 GB and the server then sends 20 MiB of it. Upstream buffered all
    # of it (and would have waited for the rest); the bound is 16 MiB.
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_endless_frame/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.message =~ "message too big"
    assert Process.alive?(socket_pid)
  end

  test "a fragmented message that reassembles past the bound is closed, though no frame is" do
    # Two 9 MiB fragments: each frame alone is under 16 MiB, so only the reassembly check in
    # `handle_fragment/4` can end this.
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_oversized_fragments/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.message =~ "message too big"
    assert Process.alive?(socket_pid)
  end

  test "a legitimately large frame, inside the bound, is delivered and the link stays up" do
    # 3 MiB of valid JSON (a deep book snapshot is a fraction of it), then a ping. The pong
    # comes back only after the frame was read, and no close came before it.
    test_pid = self()
    {listen_socket, port} = listen()

    serve(listen_socket, [
      fn socket ->
        upgrade(socket)
        padding = :binary.copy("a", 3_145_728)
        body = ~s({"type":"heartbeat","pad":"#{padding}"})
        :ok = :gen_tcp.send(socket, [<<129, 127, byte_size(body)::64>>, body])
        :ok = :gen_tcp.send(socket, <<137, 0>>)
        send(test_pid, {:client_reply, :gen_tcp.recv(socket, 0, 5_000)})
        hold(socket)
      end
    ])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert_receive {:client_reply, {:ok, <<138, _rest::binary>>}}, 10_000
    # No window: a close would have been announced before the client could answer the ping
    # that produced the pong above, so the notice would already be in the mailbox.
    refute_received {:dp_exchange, :gemini, %Notice{kind: :link_down}}
    assert Process.alive?(socket_pid)
  end

  test "a large frame that arrives in many small TCP chunks is joined once and delivered" do
    # 2 MiB in 1 KiB writes with a pause every eighth, so it reaches the client in many
    # chunks. Upstream re-joined the whole buffer per chunk (quadratic); this joins once the
    # header's declared length has arrived. The last write also carries the start of a ping,
    # so the bytes left over after the frame must survive the single join: the pong only
    # comes back if they did. Correctness, not timing, is asserted.
    test_pid = self()
    {listen_socket, port} = listen()

    serve(listen_socket, [
      fn socket ->
        upgrade(socket)
        :ok = :inet.setopts(socket, nodelay: true)
        padding = :binary.copy("a", 2_097_152)
        body = ~s({"type":"heartbeat","pad":"#{padding}"})
        frame = IO.iodata_to_binary([<<129, 127, byte_size(body)::64>>, body, <<137, 0>>])
        :ok = send_in_chunks(socket, frame, 1_024, 1)
        send(test_pid, {:client_reply, :gen_tcp.recv(socket, 0, 10_000)})
        hold(socket)
      end
    ])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert_receive {:client_reply, {:ok, <<138, _rest::binary>>}}, 20_000
    refute_received {:dp_exchange, :gemini, %Notice{kind: :link_down}}
    assert Process.alive?(socket_pid)
  end

  test "a plain ws:// connection does not need a trust store" do
    # The trust store is read for TLS only. A `ws://` proxy or test server must not be refused
    # because the operating system has no CA list.
    DpExchange.Core.Config.put_override(:cacerts_loader, fn -> :erlang.error(:enoent) end)
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_and_hold/1])

    assert {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)
  end

  test "a trust store the operating system cannot supply is an error, not a raise" do
    # `:public_key.cacerts_get/0` raises where there is no CA list (a minimal image). It ran
    # inside `Feed`'s `handle_call`, so the feed died with every subscription in it.
    DpExchange.Core.Config.put_override(:cacerts_loader, fn -> :erlang.error(:enoent) end)

    assert {:error, {:tls_trust_store_unavailable, reason}} =
             Socket.start_link(url: "wss://localhost:1/", subscriber: self())

    assert reason =~ "enoent"
  end

  test "a wss peer whose certificate nothing trusts is refused" do
    # websockex's own default is `verify: :verify_none`. Against this server, the TLS
    # handshake used to complete and the upgrade request went out.
    key = [key: {:rsa, 2048, 65_537}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    {:ok, listen_socket} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ server)
    on_exit(fn -> :ssl.close(listen_socket) end)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    test_pid = self()

    spawn(fn ->
      {:ok, transport} = :ssl.transport_accept(listen_socket, 10_000)
      send(test_pid, {:server_handshake, elem(:ssl.handshake(transport, 5_000), 0)})
    end)

    # Generous timeouts: this asserts a TLS refusal, and a 2048-bit RSA handshake on a loaded
    # machine can outlast the 500 ms handshake deadline the other tests here use.
    opts =
      socket_opts(port)
      |> Keyword.merge(url: "wss://localhost:#{port}/", socket_connect_timeout: 10_000)
      |> Keyword.put(:socket_recv_timeout, 10_000)

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             Socket.start_link(opts)

    assert_receive {:server_handshake, :error}, 5_000
  end

  test "an explicit :url bypasses the snapshot query string — the test seam owns the URL" do
    # `start_link/1`'s `:channels` opt only feeds `default_url/1`, which never runs when a
    # caller supplies `:url` directly (`Keyword.get_lazy`). `state.depth_snapshot?` is set
    # independently of the URL, from `opts` directly, so it is still true here even though
    # the URL this socket actually dialled carries no query string at all.
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade/1])

    {:ok, socket_pid} =
      Socket.start_link(socket_opts(port) ++ [channels: [:depth]])

    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert :sys.get_state(socket_pid).depth_snapshot? == true
  end

  test "a depth unsubscribe forgets the symbol's anchor and sequence, so a resubscribe re-anchors" do
    # The vendor's answer to a gap is to resubscribe, and the venue then sends a fresh
    # absolute snapshot. Left anchored, that snapshot was decoded as a diff.
    {listen_socket, port} = listen()
    # The server holds the connection open after the upgrade, so the send succeeds: the reset
    # only follows a frame that went out.
    serve(listen_socket, [&upgrade_and_hold/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port) ++ [channels: [:depth]])
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    :sys.replace_state(socket_pid, fn state ->
      Map.merge(state, %{
        depth_anchored: MapSet.new(["BTC-USD", "ETH-USD"]),
        last_depth_update: %{"BTC-USD" => 12, "ETH-USD" => 40}
      })
    end)

    assert :ok = Socket.unsubscribe(socket_pid, ["BTC-USD"], :depth)
    state = :sys.get_state(socket_pid)

    assert state.depth_anchored == MapSet.new(["ETH-USD"])
    assert state.last_depth_update == %{"ETH-USD" => 40}
  end

  test "a depth subscribe records the channel per symbol, for the gap resubscribe (MD9)" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_and_hold/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port) ++ [channels: [:depth]])
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert :ok = Socket.subscribe(socket_pid, ["BTC-USD"], :depth)
    assert :ok = Socket.subscribe(socket_pid, ["ETH-USD"], :depth_fast)
    assert :ok = Socket.subscribe(socket_pid, ["SOL-USD"], :trade)

    assert :sys.get_state(socket_pid).depth_streams ==
             MapSet.new([{"BTC-USD", :depth}, {"ETH-USD", :depth_fast}])

    # The same symbol on the other diff channel is refused: their frames cannot be told apart.
    assert Socket.subscribe(socket_pid, ["BTC-USD"], :depth_fast) ==
             {:error, {:conflicting_depth_channel, "BTC-USD"}}

    assert :sys.get_state(socket_pid).depth_streams ==
             MapSet.new([{"BTC-USD", :depth}, {"ETH-USD", :depth_fast}])

    assert :ok = Socket.unsubscribe(socket_pid, ["BTC-USD"], :depth)

    assert :sys.get_state(socket_pid).depth_streams == MapSet.new([{"ETH-USD", :depth_fast}])

    # Freed, the symbol may take the other channel.
    assert :ok = Socket.subscribe(socket_pid, ["BTC-USD"], :depth_fast)

    assert :sys.get_state(socket_pid).depth_streams ==
             MapSet.new([{"BTC-USD", :depth_fast}, {"ETH-USD", :depth_fast}])
  end

  test "no :channels means no snapshot parameter and depth_snapshot? stays falsy" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    refute :sys.get_state(socket_pid).depth_snapshot?
  end

  # `default_url/1` — the branch that actually calls `Environment.websocket_url/2` with the
  # `:snapshot` opt — is not exercised here: `config/test.exs` points `:websocket_url` at a
  # closed local port precisely so no tier-1 test dials anywhere by accident, and that
  # Config seam wins before `default_url/1` ever reaches `Environment.websocket_url/2` (see
  # `default_url/1`'s own body). `Environment.websocket_url/2` itself — the part that turns
  # `snapshot: -1` into the query string — is a pure function, unit-tested directly in
  # `environment_test.exs`. The two tests above cover the other half: that `:channels`
  # actually reaches `state.depth_snapshot?`.

  defp socket_opts(port), do: [url: "ws://127.0.0.1:#{port}/", subscriber: self()] ++ @timeouts

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  # Each handler serves one accepted connection, in order.
  defp serve(listen_socket, handlers) do
    server =
      spawn(fn ->
        Enum.each(handlers, fn handler ->
          {:ok, client_socket} = :gen_tcp.accept(listen_socket, 10_000)
          handler.(client_socket)
        end)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
  end

  defp trickle(socket) do
    {:ok, _request} = recv_until_headers_end(socket, "")
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    drip(socket)
  end

  # One byte every 100 ms, which restarts a per-`recv` timer of 300 ms forever. Stops when
  # the client closes, which is what the deadline does.
  defp drip(socket) do
    case :gen_tcp.send(socket, "X") do
      :ok ->
        Process.sleep(100)
        drip(socket)

      {:error, _closed} ->
        :ok
    end
  end

  defp upgrade_then_close(socket) do
    upgrade(socket)
    :gen_tcp.close(socket)
  end

  defp upgrade_then_send_malformed_close(socket) do
    upgrade(socket)
    :ok = :gen_tcp.send(socket, @malformed_close_frame)
    # Waits for the client to tear down, so the close cannot race the frame.
    _client_closed = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end

  # A text frame whose header declares 4 GB, followed by 20 MiB of its payload. Waits for the
  # client's close frame before closing, so the close cannot race the data.
  defp upgrade_then_send_endless_frame(socket) do
    upgrade(socket)
    :ok = :gen_tcp.send(socket, <<129, 127, 4_000_000_000::64>>)
    stream_filler(socket, 20)
    _client_closed = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end

  # A text message in two fragments (FIN clear, then a FIN continuation), 9 MiB each. Waits
  # for the client's close frame before closing.
  defp upgrade_then_send_oversized_fragments(socket) do
    upgrade(socket)
    part = :binary.copy("a", 9_437_184)
    :ok = :gen_tcp.send(socket, [<<1, 127, byte_size(part)::64>>, part])
    _sent = :gen_tcp.send(socket, [<<128, 127, byte_size(part)::64>>, part])
    _client_closed = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end

  defp send_in_chunks(_socket, <<>>, _size, _count), do: :ok

  defp send_in_chunks(socket, data, size, count) do
    take = min(size, byte_size(data))
    <<chunk::binary-size(take), rest::binary>> = data
    :ok = :gen_tcp.send(socket, chunk)
    if rem(count, 8) == 0, do: Process.sleep(1)
    send_in_chunks(socket, rest, size, count + 1)
  end

  defp stream_filler(_socket, 0), do: :ok

  defp stream_filler(socket, remaining) do
    case :gen_tcp.send(socket, :binary.copy("a", 1_048_576)) do
      :ok -> stream_filler(socket, remaining - 1)
      {:error, _closed} -> :ok
    end
  end

  # Upgrades, then keeps the connection open (reading whatever the client sends) until the
  # client goes away or the test's `serve/2` process is killed on exit.
  defp upgrade_and_hold(socket) do
    upgrade(socket)
    hold(socket)
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
