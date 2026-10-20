defmodule DpExchange.Gemini.TickAEFeedDialTest do
  @moduledoc """
  Tick AE: a dial never blocks the feed process.

  `Feed` used to dial inside `handle_call`, up to about 25s in the worst case, and every other
  call queued behind it (and exited in its caller at the 25s `@call_timeout`). The socket now
  dials in its own process; these tests hold a dial open against a gated local server and prove
  the feed keeps answering while it is, that the calls which need the wire wait their turn in
  order, and that a dial that fails refuses them without registering anything.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.Feed

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # Long enough that the gated server, not a timeout, decides when the dial ends.
  @dial_opts [socket_connect_timeout: 20_000, socket_recv_timeout: 20_000]

  defp start_feed(port) do
    name = :"tick_ae_feed_#{System.unique_integer([:positive])}"
    {:ok, feed} = Feed.start_link([name: name, url: "ws://127.0.0.1:#{port}/"] ++ @dial_opts)
    feed
  end

  defp start_idle_feed do
    name = :"tick_ae_idle_#{System.unique_integer([:positive])}"
    {:ok, feed} = Feed.start_link(name: name)
    feed
  end

  # Polls the feed (itself a proof that it is answering) until `fun` is true of its state. It
  # returns the moment the state matches, so the 30 s ceiling (3_000 x 10 ms, before each
  # `:sys.get_state` round trip) costs nothing on a passing run and survives a loaded gate.
  defp await_state(feed, fun, tries \\ 3_000) do
    cond do
      fun.(:sys.get_state(feed)) ->
        :ok

      tries == 0 ->
        flunk("the feed never reached the awaited state: #{inspect(:sys.get_state(feed).dial)}")

      true ->
        Process.sleep(10)
        await_state(feed, fun, tries - 1)
    end
  end

  # A dial in progress that no socket will ever finish, installed from inside the feed.
  defp install_dial(feed, opts \\ []) do
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    ref = make_ref()

    :sys.replace_state(feed, fn state ->
      timer = Process.send_after(self(), {:never_delivered, ref}, 600_000)

      dial = %{
        socket: socket,
        ref: ref,
        timer: timer,
        waiters: [],
        waiting: Keyword.get(opts, :waiting, 0),
        resubscribe?: Keyword.get(opts, :resubscribe?, false)
      }

      %{state | socket: socket, dial: dial}
    end)

    {socket, ref}
  end

  describe "a dial in progress" do
    test "does not stop the feed answering other calls, and holds the wire calls in order" do
      {port, server} = gated_server(:upgrade)
      feed = start_feed(port)
      me = self()

      subscribe = Task.async(fn -> Feed.subscribe(feed, ["BTC-USD"], to: me) end)
      await_state(feed, &match?(%{dial: %{waiting: 1}}, &1))

      # Queued behind the subscribe. Answered at once, it would have run first and the
      # subscribe would then have put the symbol back.
      unsubscribe = Task.async(fn -> Feed.unsubscribe(feed, ["BTC-USD"]) end)
      await_state(feed, &match?(%{dial: %{waiting: 2}}, &1))

      started = System.monotonic_time(:millisecond)
      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}, trades: %{}}
      assert Feed.wanted(feed) == []
      assert :ok = Feed.subscribe_notices(feed, to: me)
      assert :ok = Feed.subscribe(feed, [], to: me)
      assert System.monotonic_time(:millisecond) - started < 4_000

      # The dial is still open, and neither held call has been answered.
      assert Task.yield(subscribe, 0) == nil
      assert Task.yield(unsubscribe, 0) == nil
      assert Feed.wanted(feed) == []

      send(server, :go)

      assert :ok = Task.await(subscribe, 30_000)
      assert :ok = Task.await(unsubscribe, 30_000)

      assert_receive {:client_text, %{"method" => "subscribe"} = subscribed}, 5_000
      assert subscribed["params"] == ["btcusd@bookTicker"]

      assert_receive {:client_text, %{"method" => "unsubscribe"} = unsubscribed}, 5_000
      assert unsubscribed["params"] == ["btcusd@bookTicker"]

      state = :sys.get_state(feed)
      assert state.dial == nil
      assert is_pid(state.socket)
      assert state.wanted == MapSet.new()
    end

    test "a dial that fails refuses every held subscribe and registers nothing" do
      {port, server} = gated_server(:close)
      feed = start_feed(port)
      me = self()
      :ok = Feed.subscribe_notices(feed, to: me)

      first = Task.async(fn -> Feed.subscribe(feed, ["BTC-USD"], to: me) end)
      await_state(feed, &match?(%{dial: %{waiting: 1}}, &1))
      second = Task.async(fn -> Feed.subscribe(feed, ["ETH-USD"], to: me) end)
      await_state(feed, &match?(%{dial: %{waiting: 2}}, &1))
      held_unsubscribe = Task.async(fn -> Feed.unsubscribe(feed, ["SOL-USD"]) end)
      await_state(feed, &match?(%{dial: %{waiting: 3}}, &1))

      send(server, :go)

      assert {:error, _reason} = Task.await(first, 30_000)
      assert {:error, _reason} = Task.await(second, 30_000)
      # What an unsubscribe with no socket answers: nothing to stop.
      assert :ok = Task.await(held_unsubscribe, 30_000)

      state = :sys.get_state(feed)
      assert state.dial == nil
      assert state.socket == nil
      assert state.wanted == MapSet.new()
      assert state.subscribers == MapSet.new()
      # Only this process's notice subscription is watched; the refused subscribes added none.
      assert Map.keys(state.monitors) == [me]

      # A connect that never happened is not a socket crash: no link_down notice, no crash run.
      refute_received {:dp_exchange, :gemini, %Notice{kind: :link_down}}
      refute Map.has_key?(state, :crash_run)
      assert Process.alive?(feed)
    end

    test "the calls queued while it was open keep their order against a later one" do
      {port, server} = gated_server(:upgrade)
      feed = start_feed(port)
      me = self()

      held = Task.async(fn -> Feed.subscribe(feed, ["BTC-USD"], to: me) end)
      await_state(feed, &match?(%{dial: %{waiting: 1}}, &1))
      update = Task.async(fn -> Feed.update_symbols(feed, ["ETH-USD"]) end)
      await_state(feed, &match?(%{dial: %{waiting: 2}}, &1))

      send(server, :go)

      assert :ok = Task.await(held, 30_000)
      assert :ok = Task.await(update, 30_000)
      # The update came second, so it is the whole wanted set.
      assert Feed.wanted(feed) == ["ETH-USD"]
    end

    test "a tick during the dial folds into it and resubscribes the wanted set on connect" do
      {port, server} = gated_server(:upgrade)
      feed = start_feed(port)
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      await_state(feed, &match?(%{dial: %{resubscribe?: true}}, &1))

      # A second tick while the first dial is open dials nothing further.
      %{dial: %{socket: dialling}} = :sys.get_state(feed)
      send(feed, :resubscribe)
      assert %{dial: %{socket: ^dialling}} = :sys.get_state(feed)

      send(server, :go)

      assert_receive {:client_text, %{"method" => "subscribe"} = frame}, 30_000
      assert frame["params"] == ["btcusd@bookTicker"]

      assert %{dial: nil, socket: ^dialling} = :sys.get_state(feed)
    end

    test "a held call beyond the cap is refused, not queued" do
      feed = start_idle_feed()
      install_dial(feed, waiting: 1_000)

      assert {:error, :dial_backlog_full} = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert {:error, :dial_backlog_full} = Feed.update_symbols(feed, ["BTC-USD"])
      assert {:error, :dial_backlog_full} = Feed.unsubscribe(feed, ["BTC-USD"])
      assert Feed.wanted(feed) == []
    end

    test "the dial timeout is a net: it kills the socket and reports the failed reconnect" do
      feed = start_idle_feed()
      me = self()
      :ok = Feed.subscribe_notices(feed, to: me)
      {socket, ref} = install_dial(feed, resubscribe?: true)
      monitor = Process.monitor(socket)

      # A timeout that is not this dial's is stale and does nothing.
      send(feed, {:dial_timeout, make_ref()})
      assert %{dial: %{ref: ^ref}} = :sys.get_state(feed)

      send(feed, {:dial_timeout, ref})

      assert_receive {:DOWN, ^monitor, :process, ^socket, :killed}, 5_000

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change, severity: :warning}},
                     5_000

      state = :sys.get_state(feed)
      assert state.dial == nil
      assert state.socket == nil
    end

    test "a connected report from a socket that is not the dial's is ignored" do
      feed = start_idle_feed()
      {socket, ref} = install_dial(feed)

      send(feed, {:dp_exchange, :gemini, :connected, self()})

      assert %{dial: %{ref: ^ref, socket: ^socket}} = :sys.get_state(feed)
    end
  end

  describe "the periodic resubscribe timer" do
    test "only the tick the state names is honoured, and each re-arms exactly one successor" do
      feed = start_idle_feed()
      {ref, _timer} = :sys.get_state(feed).resubscribe_timer

      # A hand-sent resubscribe and a stale tick start no second chain.
      send(feed, :resubscribe)
      send(feed, {:resubscribe_tick, make_ref()})
      assert {^ref, _timer} = :sys.get_state(feed).resubscribe_timer

      send(feed, {:resubscribe_tick, ref})
      {next, _timer} = :sys.get_state(feed).resubscribe_timer
      assert next != ref

      # The old ref is stale now.
      send(feed, {:resubscribe_tick, ref})
      assert {^next, _timer} = :sys.get_state(feed).resubscribe_timer
    end
  end

  # A WebSocket-shaped server for one connection that holds the handshake until the test sends
  # it `:go`, then either completes the upgrade and forwards the client's text frames to the
  # test as `{:client_text, json}`, or closes the connection. Returns `{port, server_pid}`.
  defp gated_server(mode) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    test_pid = self()

    server =
      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen_socket, 30_000)
        serve(mode, client, test_pid)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
    {port, server}
  end

  defp serve(mode, client, test_pid) do
    receive do
      :go -> finish(mode, client, test_pid)
    after
      60_000 -> :gen_tcp.close(client)
    end
  end

  defp finish(:close, client, _test_pid), do: :gen_tcp.close(client)

  defp finish(:upgrade, client, test_pid) do
    upgrade(client)
    forward_text_frames(client, test_pid, "")
  end

  defp forward_text_frames(socket, test_pid, buffer) do
    case take_frame(buffer) do
      {:ok, 1, text, rest} ->
        send(test_pid, {:client_text, Jason.decode!(text)})
        forward_text_frames(socket, test_pid, rest)

      {:ok, _other_opcode, _payload, rest} ->
        forward_text_frames(socket, test_pid, rest)

      :more ->
        case :gen_tcp.recv(socket, 0, 60_000) do
          {:ok, data} -> forward_text_frames(socket, test_pid, buffer <> data)
          {:error, _closed} -> :ok
        end
    end
  end

  # A client frame is always masked: header, length (7 bits, or 126 then 16 bits), a 4-byte
  # mask, then the payload.
  defp take_frame(<<_head::4, opcode::4, 1::1, 126::7, size::16, rest::binary>>),
    do: take_payload(opcode, size, rest)

  defp take_frame(<<_head::4, opcode::4, 1::1, size::7, rest::binary>>) when size < 126,
    do: take_payload(opcode, size, rest)

  defp take_frame(_incomplete), do: :more

  defp take_payload(opcode, size, buffer) when byte_size(buffer) >= size + 4 do
    <<mask::binary-size(4), data::binary-size(size), rest::binary>> = buffer
    {:ok, opcode, unmask(data, mask), rest}
  end

  defp take_payload(_opcode, _size, _incomplete), do: :more

  defp unmask(data, mask) do
    key = mask |> :binary.copy(div(byte_size(data), 4) + 1) |> binary_part(0, byte_size(data))
    :crypto.exor(data, key)
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
      case :gen_tcp.recv(socket, 0, 30_000) do
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
