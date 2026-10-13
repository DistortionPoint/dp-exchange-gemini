defmodule DpExchange.Gemini.TickAAFeedTest do
  @moduledoc """
  Tick AA: the `Feed` lines no test ran — a crashed or never-dialled socket redialled by the
  resubscribe tick, an update during a link outage, a retried unsubscribe that lands, payloads
  and notices of a shape the feed does not recognise, and a notice subscriber whose name
  nobody holds.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Gemini.Feed

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defmodule UnrecognisedPayload do
    @moduledoc false
    defstruct [:symbol]
  end

  # The same stand-in `feed_test.exs` uses: a real process answering the `:gen.call`
  # `WebSockex.send_frame/2` makes, forwarding each frame to the test.
  defp fake_socket(report_to) do
    spawn_link(fn -> accept_frames(report_to) end)
  end

  defp accept_frames(report_to) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        send(report_to, {:frame_sent, Jason.decode!(frame)})
        :gen.reply(from, :ok)
        accept_frames(report_to)
    end
  end

  # Fails the first unsubscribe with `{:error, :send_timeout}` and answers every other frame,
  # and every later unsubscribe, `:ok`.
  defp unsubscribe_fails_once_socket(report_to) do
    spawn_link(fn -> unsubscribe_fails_once_frames(report_to, :fail_next_unsubscribe) end)
  end

  defp unsubscribe_fails_once_frames(report_to, mode) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        decoded = Jason.decode!(frame)
        send(report_to, {:frame_sent, decoded})

        if decoded["method"] == "unsubscribe" and mode == :fail_next_unsubscribe do
          :gen.reply(from, {:error, :send_timeout})
          unsubscribe_fails_once_frames(report_to, :accept_all)
        else
          :gen.reply(from, :ok)
          unsubscribe_fails_once_frames(report_to, mode)
        end
    end
  end

  defp start_feed(opts \\ []) do
    name = :"tick_aa_feed_#{System.unique_integer([:positive])}"
    {:ok, pid} = Feed.start_link(Keyword.merge([name: name, socket: fake_socket(self())], opts))
    pid
  end

  describe "the resubscribe tick dials a socket when it holds none" do
    test "a nil socket with symbols wanted is dialled and sent the whole wanted set" do
      port = websocket_server()

      name = :"tick_aa_feed_#{System.unique_integer([:positive])}"

      {:ok, feed} =
        Feed.start_link(
          name: name,
          url: "ws://127.0.0.1:#{port}/",
          socket_connect_timeout: 5_000,
          socket_recv_timeout: 5_000
        )

      assert :sys.get_state(feed).socket == nil
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)

      assert_receive {:client_text, %{"method" => "subscribe", "params" => params}}, 5_000
      assert params == ["btcusd@bookTicker"]

      state = :sys.get_state(feed)
      assert is_pid(state.socket)
      assert state.resubscribe_notice_state == :ok
    end
  end

  describe "update_symbols/2 while the link is down" do
    test "records the new wanted set, sends nothing, and the reconnect sends it" do
      feed = start_feed()

      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})
      assert :ok = Feed.update_symbols(feed, ["BTC-USD"])

      refute_received {:frame_sent, _frame}
      assert :sys.get_state(feed).wanted == MapSet.new(["BTC-USD"])

      socket = :sys.get_state(feed).socket
      send(feed, {:dp_exchange, :gemini, :reconnected, socket})

      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => params}}, 5_000
      assert params == ["btcusd@bookTicker"]
    end
  end

  describe "a failed wire unsubscribe is retried on the tick" do
    test "a retry that succeeds empties the queue" do
      feed = start_feed(socket: unsubscribe_fails_once_socket(self()))
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      assert {:error, :send_timeout} = Feed.unsubscribe(feed, ["ETH-USD"])
      assert_receive {:frame_sent, %{"method" => "unsubscribe"}}
      assert :sys.get_state(feed).unsubscribe_pending == MapSet.new(["ETH-USD"])

      send(feed, :resubscribe)

      assert_receive {:frame_sent, %{"method" => "unsubscribe", "params" => params}}, 5_000
      assert params == ["ethusd@bookTicker"]
      assert :sys.get_state(feed).unsubscribe_pending == MapSet.new()
    end
  end

  describe "payloads the feed does not recognise" do
    test "are delivered to subscribers but never counted toward coverage" do
      feed = start_feed()
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())
      assert_receive {:frame_sent, %{"method" => "subscribe"}}

      unrecognised = %UnrecognisedPayload{symbol: "BTC-USD"}
      symbolless = %{heartbeat: true}
      send(feed, {:dp_exchange, :gemini, unrecognised})
      send(feed, {:dp_exchange, :gemini, symbolless})

      assert_receive {:dp_exchange, :gemini, ^unrecognised}, 5_000
      assert_receive {:dp_exchange, :gemini, ^symbolless}, 5_000
      assert Feed.coverage(feed) == %{}
      assert Feed.coverage_by_kind(feed) == %{quotes: %{}, top_of_book: %{}, trades: %{}}
    end
  end

  describe "notices of a shape the feed does not expect" do
    test "a hand-built notice with non-map details is throttled and forwarded as it came" do
      feed = start_feed()
      :ok = Feed.subscribe_notices(feed, to: self())
      malformed = %{Notice.new(:data_quality, :gemini) | details: nil}

      for _each <- 1..3, do: send(feed, {:dp_exchange, :gemini, malformed})
      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality, details: nil}}
      refute_received {:dp_exchange, :gemini, %Notice{}}
      assert %{{:data_quality, nil, nil} => {_start, 2}} = :sys.get_state(feed).notice_seen

      # Age the window rather than wait it out.
      :sys.replace_state(feed, fn state ->
        aged = Map.new(state.notice_seen, fn {key, {start, n}} -> {key, {start - 31_000, n}} end)
        %{state | notice_seen: aged}
      end)

      send(feed, {:dp_exchange, :gemini, malformed})
      _settled = Feed.coverage(feed)

      assert_received {:dp_exchange, :gemini, %Notice{kind: :data_quality, details: nil}}
      assert Process.alive?(feed)
    end

    test "a notice subscriber registered by a name nobody holds is skipped, not crashed on" do
      feed = start_feed()
      absent = :"tick_aa_absent_#{System.unique_integer([:positive])}"
      :ok = Feed.subscribe_notices(feed, to: absent)
      :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :gemini, Notice.new(:link_down, :gemini)})

      assert_receive {:dp_exchange, :gemini, %Notice{kind: :link_down}}, 5_000
      assert Process.alive?(feed)
    end
  end

  describe "format_status/1" do
    test "passes a status whose state it does not recognise through unchanged" do
      status = %{state: %{socket: nil}, log: []}
      assert Feed.format_status(status) == status
      assert Feed.format_status(%{log: []}) == %{log: []}
    end
  end

  # A real WebSocket server on `127.0.0.1` for one connection: it upgrades, then reads the
  # client's masked frames and forwards each text frame to the test as `{:client_text, json}`.
  defp websocket_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    test_pid = self()

    server =
      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen_socket, 10_000)
        upgrade(client)
        forward_text_frames(client, test_pid, "")
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
    port
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
