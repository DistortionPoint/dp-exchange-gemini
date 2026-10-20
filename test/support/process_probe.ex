defmodule DpExchange.Gemini.ProcessProbe do
  @moduledoc """
  Starts this package's long-lived processes for Core's conformance group 51 — test support.

  Given a credentials map holding a canary, it starts a `DpExchange.Gemini.Supervisor` tree
  with the canary in `:credentials` and in `:ssl_options` (a `:password` and a `:key`), aimed at
  a stub on a loopback port that upgrades one WebSocket connection and holds it: no venue is
  reached. A subscribe makes the feed dial that stub, so the socket exists too. It answers the
  supervisor, the ledger, the feed and the socket, which are the processes that hold either
  option, for the suite to render with `:sys.get_status/2`.
  """

  alias DpExchange.Gemini.Feed
  alias DpExchange.Gemini.Supervisor, as: GeminiSupervisor

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @doc """
  Starts the tree against the stub and answers `{:ok, [supervisor, ledger, feed, socket]}`.
  """
  @spec start(map()) :: {:ok, [pid()]} | {:error, term()}
  def start(secrets) do
    canary = secrets |> Map.values() |> List.first()
    port = serve_one()
    name = :"gemini_process_probe_#{System.unique_integer([:positive])}"
    feed_name = Module.concat(name, "Feed")

    {:ok, tree} =
      GeminiSupervisor.start_link(
        name: name,
        url: "ws://127.0.0.1:#{port}/",
        credentials: secrets,
        ssl_options: [verify: :verify_peer, password: canary, key: {:rsa, canary}]
      )

    case Feed.subscribe(feed_name, ["BTC-USD"], to: self()) do
      :ok ->
        feed = Process.whereis(feed_name)
        %{socket: socket} = :sys.get_state(feed)
        ledger = Process.whereis(Module.concat(feed_name, "Ledger"))
        {:ok, [tree, ledger, feed, socket]}

      {:error, _reason} = error ->
        Process.unlink(tree)
        Process.exit(tree, :kill)
        error
    end
  end

  # A loopback stub that accepts one connection, upgrades it and holds it until the client goes.
  defp serve_one do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      send(parent, {ref, port})
      {:ok, client} = :gen_tcp.accept(listen, 10_000)
      upgrade(client)
      hold(client)
    end)

    receive do
      {^ref, port} -> port
    after
      5_000 -> raise "the probe stub did not start"
    end
  end

  defp hold(socket) do
    case :gen_tcp.recv(socket, 0, 60_000) do
      {:ok, _data} -> hold(socket)
      {:error, _closed} -> :ok
    end
  end

  defp upgrade(socket) do
    {:ok, request} = recv_headers(socket, "")

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_headers(socket, acc <> data)
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
