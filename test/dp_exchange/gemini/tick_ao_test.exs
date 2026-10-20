defmodule DpExchange.Gemini.TickAoTest do
  @moduledoc """
  Tick AO: hot paths (L), process identity and shutdown (M), and secrets in logs, errors,
  telemetry and supervisor reports (N).

    * **L** - a depth frame is judged against the connection's subscriptions by membership,
      not by a scan of every subscription.
    * **M** - a feed that stops takes the socket it dialled with it; a socket that was handed
      in is left alone.
    * **N** - the argument passed where the options go is not echoed with its secrets; a
      caller's `:ssl_options` does not print in a supervisor's report; the vendored socket's
      telemetry does not carry them; and the signed headers reach no log and no error.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.{OrderBook, TopOfBook}
  alias DpExchange.Gemini.{Credentials, Fake, Feed, OptionKeys, Private, Socket}
  alias DpExchange.Gemini.Supervisor, as: GeminiSupervisor
  alias DpExchange.Gemini.Vendor.WebSockex, as: VendoredWebSockex

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @secret "gemini-secret-ao-canary"
  @ssl_canary "ssl-key-password-ao-canary"

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  defmodule Probe do
    @moduledoc false
    use VendoredWebSockex
  end

  defmodule TelemetryForwarder do
    @moduledoc false

    @doc false
    @spec handle_event(list(), map(), map(), map()) :: :ok
    def handle_event(_event, _measurements, metadata, %{pid: pid, module: module}) do
      if metadata.module == module, do: send(pid, {:websockex, metadata})
      :ok
    end
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  # --- L: a depth frame is judged by membership ------------------------------------------

  @diff %{
    "e" => "depthUpdate",
    "E" => 1_787_936_147_000_000_000,
    "s" => "btcusd",
    "U" => 11,
    "u" => 15,
    "b" => [["3610.00", "1.5"]],
    "a" => [["3611.00", "0"]]
  }

  defp depth_state(streams) do
    %{
      subscriber: self(),
      request_id: 0,
      connected_once?: false,
      last_heard_at: nil,
      depth_snapshot?: true,
      depth_streams: MapSet.new(streams),
      depth_anchored: MapSet.new(),
      last_depth_update: %{}
    }
  end

  defp frame(payload), do: {:text, Jason.encode!(payload)}

  defp crowd do
    for number <- 1..2_000, channel <- [:depth, :depth_fast] do
      {"SYM#{number}-USD", channel}
    end
  end

  describe "a depth frame is checked against the subscriptions by membership" do
    test "a symbol subscribed on :depth_fast is delivered" do
      state = depth_state([{"BTC-USD", :depth_fast}])

      assert {:ok, _state} = Socket.handle_frame(frame(@diff), state)
      assert_received {:dp_exchange, :gemini, %OrderBook{sequence: 15}}
    end

    test "a symbol subscribed on :depth is delivered" do
      state = depth_state([{"BTC-USD", :depth}])

      assert {:ok, _state} = Socket.handle_frame(frame(@diff), state)
      assert_received {:dp_exchange, :gemini, %OrderBook{sequence: 15}}
    end

    test "a symbol on neither channel is dropped, and nothing is recorded for it" do
      state = depth_state([{"ETH-USD", :depth}, {"ETH-USD", :depth_fast}])

      assert {:ok, after_frame} = Socket.handle_frame(frame(@diff), state)
      refute_received {:dp_exchange, :gemini, _anything}
      assert after_frame.depth_anchored == MapSet.new()
      assert after_frame.last_depth_update == %{}
    end

    test "the answer is the same with the whole catalogue subscribed on both channels" do
      assert {:ok, _state} = Socket.handle_frame(frame(@diff), depth_state(crowd()))
      refute_received {:dp_exchange, :gemini, _anything}

      listed = depth_state([{"BTC-USD", :depth_fast} | crowd()])
      assert {:ok, _state} = Socket.handle_frame(frame(@diff), listed)
      assert_received {:dp_exchange, :gemini, %OrderBook{sequence: 15}}
    end
  end

  # --- a local venue: accepts one connection, upgrades it, and holds it ------------------

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  defp serve_one(listen_socket) do
    server =
      spawn(fn ->
        {:ok, client_socket} = :gen_tcp.accept(listen_socket, 10_000)
        upgrade(client_socket)
        hold(client_socket)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
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

  defp feed_name, do: :"tick_ao_feed_#{System.unique_integer([:positive])}"

  # --- M: a feed that stops takes its socket with it -------------------------------------

  describe "stopping a feed stops the socket it dialled" do
    test "a :normal stop, which a linked socket that does not trap ignores, still ends it" do
      {listen_socket, port} = listen()
      serve_one(listen_socket)

      {:ok, feed} = Feed.start_link(name: feed_name(), url: "ws://127.0.0.1:#{port}/")

      # The first subscribe dials, and is answered once the socket is connected and the frame
      # has gone out.
      assert :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      %{socket: socket} = :sys.get_state(feed)
      assert is_pid(socket)
      ref = Process.monitor(socket)

      # `:normal`: before the fix this left the socket connected and reconnecting for good.
      assert :ok = GenServer.stop(feed)

      assert_receive {:DOWN, ^ref, :process, ^socket, :shutdown}, 5_000
    end

    test "a socket handed in through :socket was not dialled here and is left alone" do
      bystander = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(bystander, :kill) end)
      ref = Process.monitor(bystander)

      {:ok, feed} = Feed.start_link(name: feed_name(), socket: bystander)
      assert :ok = GenServer.stop(feed)

      # A negative, so a window of at least 500 ms.
      refute_receive {:DOWN, ^ref, :process, ^bystander, _reason}, 500
      assert Process.alive?(bystander)
    end
  end

  # --- N: the argument that was meant to be the credentials ------------------------------

  describe "options that are not a keyword list are not echoed with their secrets" do
    test "the credentials passed where the options go come back redacted, from the facade" do
      credentials = %{api_key: "account-ao", api_secret: @secret}

      assert {:error, {:invalid_options, shown}} =
               DpExchange.Gemini.get_balances(credentials, credentials)

      assert shown == %{api_key: :redacted, api_secret: :redacted}
      refute inspect(shown) =~ @secret
    end

    test "and from the fake, which refuses with the same function" do
      credentials = %{api_key: "account-ao", api_secret: @secret}

      assert {:error, {:invalid_options, %{api_key: :redacted, api_secret: :redacted}}} =
               Fake.get_balances(credentials, credentials)
    end

    test "a secret nested in a list that is not a keyword list is redacted, the rest kept" do
      nested = [{:credentials, %{api_secret: @secret}}, :oops]

      assert {:error, {:invalid_options, shown}} = OptionKeys.check(:get_balances, nested)
      assert shown == [{:credentials, :redacted}, :oops]
    end

    test "string keys, an improper list and a tuple are covered" do
      by_string = %{"api_secret" => @secret, "note" => "kept"}

      assert {:error, {:invalid_options, %{"api_secret" => :redacted, "note" => "kept"}}} =
               OptionKeys.check(:get_balances, by_string)

      assert {:error, {:invalid_options, [{:api_secret, :redacted} | :tail]}} =
               OptionKeys.check(:get_balances, [{:api_secret, @secret} | :tail])

      assert {:error, {:invalid_options, {:access_token, :redacted}}} =
               OptionKeys.check(:get_balances, {:access_token, @secret})
    end

    test "what is not a secret is returned as it was given" do
      assert {:error, {:invalid_options, [{:limit, 5}, :oops]}} =
               OptionKeys.check(:get_balances, [{:limit, 5}, :oops])

      assert {:error, {:invalid_options, "nope"}} = OptionKeys.check(:get_balances, "nope")
    end

    test "check!/2 raises without the secret in its message" do
      error =
        assert_raise ArgumentError, fn ->
          OptionKeys.check!(:coverage, %{api_secret: @secret})
        end

      refute Exception.message(error) =~ @secret
      assert Exception.message(error) =~ "redacted"
    end

    test "the keyword terms of a positional argument are scrubbed alike" do
      terms = %{credentials: %{api_secret: @secret}}

      assert {:error, {:invalid_options, %{credentials: :redacted}}} =
               OptionKeys.check_terms(:transfer_internal, terms)
    end
  end

  # --- N: a caller's :ssl_options in a supervisor's report -------------------------------

  describe "a caller's :ssl_options do not print" do
    test "the child spec holds it wrapped" do
      ssl = [verify: :verify_peer, password: @ssl_canary]
      spec = DpExchange.Gemini.child_spec(ssl_options: ssl)

      refute inspect(spec, limit: :infinity, printable_limit: :infinity) =~ @ssl_canary

      {DpExchange.Gemini, :start_link, [opts]} = spec.start
      assert Credentials.unwrap_ssl(opts[:ssl_options]) == ssl
    end

    test "a nil, an empty list and an absent value are left as they are" do
      assert Credentials.wrap_opt(ssl_options: nil) == [ssl_options: nil]
      assert Credentials.wrap_opt(ssl_options: []) == [ssl_options: []]
      assert Credentials.wrap_opt(environment: :sandbox) == [environment: :sandbox]
    end

    test "wrapping twice is wrapping once, and a raw value unwraps to itself" do
      once = Credentials.wrap_opt(ssl_options: [depth: 3])

      assert Credentials.wrap_opt(once) == once
      assert Credentials.unwrap_ssl(once[:ssl_options]) == [depth: 3]
      assert Credentials.unwrap_ssl(depth: 3) == [depth: 3]
      assert Credentials.unwrap_ssl(nil) == nil
    end

    test "the running tree prints neither its own nor its feed's, and the feed still has it" do
      unique = System.unique_integer([:positive])
      feed_name = :"tick_ao_tree_feed_#{unique}"
      ssl = [verify: :verify_peer, password: @ssl_canary]

      {:ok, tree} =
        GeminiSupervisor.start_link(
          name: :"tick_ao_sup_#{unique}",
          feed: feed_name,
          limiter: :"tick_ao_limiter_#{unique}",
          ssl_options: ssl
        )

      on_exit(fn -> if Process.alive?(tree), do: Process.exit(tree, :shutdown) end)

      tree_status = inspect(:sys.get_status(tree), limit: :infinity, printable_limit: :infinity)
      refute tree_status =~ @ssl_canary

      feed = Process.whereis(feed_name)
      feed_status = inspect(:sys.get_status(feed), limit: :infinity, printable_limit: :infinity)
      refute feed_status =~ @ssl_canary

      # What `Socket` is started with is the caller's list, whole.
      assert :sys.get_state(feed).socket_opts[:ssl_options] == ssl
    end

    test "Socket reads a wrapped value as the list it holds" do
      wrapped = Credentials.wrap_opt(ssl_options: [verify: :verify_none])

      assert Socket.connect_opts(wrapped)[:ssl_options] == [verify: :verify_none]
    end
  end

  # --- N: the vendored socket's telemetry ------------------------------------------------

  describe "the vendored socket's telemetry does not carry the ssl options" do
    test "a connected event names the connection with its ssl_options redacted" do
      {listen_socket, port} = listen()
      serve_one(listen_socket)

      handler = "tick-ao-#{System.unique_integer([:positive])}"
      config = %{pid: self(), module: Probe}

      :ok =
        :telemetry.attach(
          handler,
          [:websockex, :connected],
          &TelemetryForwarder.handle_event/4,
          config
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      connect = [
        ssl_options: [password: @ssl_canary],
        socket_connect_timeout: 5_000,
        socket_recv_timeout: 5_000
      ]

      {:ok, socket} =
        VendoredWebSockex.start_link("ws://127.0.0.1:#{port}/", Probe, :state, connect)

      on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)

      assert_receive {:websockex, %{conn: conn}}, 5_000
      assert conn.ssl_options == :redacted
      refute inspect(conn, limit: :infinity) =~ @ssl_canary
    end
  end

  # --- N: the signed headers reach no log and no error -----------------------------------

  @credentials %{api_key: "account-ao-key", api_secret: "ao-secret-not-real"}

  defp responder(:unavailable), do: &Plug.Conn.resp(&1, 503, "unavailable")
  defp responder(:timeout), do: &Req.Test.transport_error(&1, :timeout)

  defp recording(test_pid, respond) do
    fn conn ->
      [payload] = Plug.Conn.get_req_header(conn, "x-gemini-payload")
      [signature] = Plug.Conn.get_req_header(conn, "x-gemini-signature")
      send(test_pid, {:signed, payload, signature})
      respond.(conn)
    end
  end

  # The plug runs inside the call under test, so every request there will ever be is already
  # in the mailbox when the call returns: no window to wait out.
  defp signed_messages(acc \\ []) do
    receive do
      {:signed, payload, signature} -> signed_messages([{payload, signature} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the payload header and its signature never reach a log or an error" do
    for failure <- [:unavailable, :timeout] do
      test "after #{failure}, retried" do
        plug = recording(self(), responder(unquote(failure)))
        opts = [plug: plug, retry_attempts: 2, retry_delay: 0, nonce_mode: :incremental]

        {result, log} = with_log(fn -> Private.get_balances(@credentials, opts) end)

        assert {:error, _reason} = result

        signed = signed_messages()
        assert signed != []

        text = inspect(result, limit: :infinity, printable_limit: :infinity) <> log

        for {payload, signature} <- signed do
          refute text =~ payload
          refute text =~ signature
          refute text =~ Base.decode64!(payload)
        end

        refute text =~ @credentials.api_secret
        refute text =~ @credentials.api_key
      end
    end
  end

  # --- M: two trees that differ only in their name ---------------------------------------

  defp tree_name(label), do: :"tick_ao_#{label}_#{System.unique_integer([:positive])}"

  defp start_tree(opts) do
    {:ok, tree} = GeminiSupervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(tree), do: Process.exit(tree, :shutdown) end)
    tree
  end

  describe "a tree named only by :name names its own processes" do
    test "the defaults are exactly what they were" do
      assert GeminiSupervisor.feed_name([]) == Feed
      assert GeminiSupervisor.feed_name(name: nil) == Feed
      assert GeminiSupervisor.feed_name(name: GeminiSupervisor) == Feed
      assert GeminiSupervisor.feed_name(name: "not an atom") == Feed

      assert GeminiSupervisor.limiter_name(name: GeminiSupervisor) ==
               DpExchange.Gemini.RateLimiter

      assert GeminiSupervisor.feed_name(environment: :sandbox, name: nil) ==
               DpExchange.Gemini.SandboxFeed
    end

    test "an explicit :feed or :limiter wins over the derived name" do
      assert GeminiSupervisor.feed_name(name: :acct, feed: :mine) == :mine
      assert GeminiSupervisor.limiter_name(name: :acct, limiter: :mine) == :mine
    end

    test "two trees with only distinct names run side by side, each call reaching its own" do
      first = tree_name(:first)
      second = tree_name(:second)
      start_tree(name: first)
      start_tree(name: second)

      first_pid = spawn(fn -> Process.sleep(:infinity) end)
      second_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        Process.exit(first_pid, :kill)
        Process.exit(second_pid, :kill)
      end)

      assert :ok = DpExchange.Gemini.subscribe_notices(name: first, to: first_pid)
      assert :ok = DpExchange.Gemini.subscribe_notices(name: second, to: second_pid)

      first_feed = :sys.get_state(Module.concat(first, "Feed"))
      second_feed = :sys.get_state(Module.concat(second, "Feed"))

      assert MapSet.member?(first_feed.notice_subscribers, first_pid)
      refute MapSet.member?(first_feed.notice_subscribers, second_pid)
      assert MapSet.member?(second_feed.notice_subscribers, second_pid)
      refute MapSet.member?(second_feed.notice_subscribers, first_pid)

      assert is_pid(Process.whereis(Module.concat(first, "RateLimiter")))
      assert is_pid(Process.whereis(Module.concat(second, "RateLimiter")))
      assert DpExchange.Gemini.wanted(name: first) == []
      assert DpExchange.Gemini.coverage(name: second) == %{}
    end

    test "a name that no tree holds answers as a missing feed, not as the default one" do
      assert DpExchange.Gemini.subscribe_notices(name: tree_name(:absent)) ==
               {:error, :feed_not_started}
    end
  end

  # --- M: a feed restart keeps what the feed was asked to carry --------------------------

  # Two connections: the first is held until its client dies, the second is upgraded and
  # sends one book ticker, so a delivery after the restart is proof of the restored intent.
  defp serve_restart(listen_socket) do
    server =
      spawn(fn ->
        {:ok, first} = :gen_tcp.accept(listen_socket, 10_000)
        upgrade(first)
        hold(first)

        {:ok, second} = :gen_tcp.accept(listen_socket, 10_000)
        upgrade(second)
        ticker = ~s({"s":"btcusd","b":"100.5","a":"101.5"})
        :ok = :gen_tcp.send(second, [<<129, byte_size(ticker)>>, ticker])
        hold(second)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
  end

  describe "a feed that is killed comes back with what it was carrying" do
    test "the wanted set and the subscribers survive, and the subscriber is told" do
      {listen_socket, port} = listen()
      serve_restart(listen_socket)

      name = tree_name(:restart)
      start_tree(name: name, url: "ws://127.0.0.1:#{port}/")
      feed_name = Module.concat(name, "Feed")

      assert :ok = DpExchange.Gemini.subscribe_notices(name: name, to: self())
      assert :ok = DpExchange.Gemini.subscribe(["BTC-USD"], name: name, to: self())
      assert DpExchange.Gemini.wanted(name: name) == ["BTC-USD"]

      old_feed = Process.whereis(feed_name)
      Process.exit(old_feed, :kill)

      assert_receive {:dp_exchange, :gemini,
                      %Notice{kind: :coverage_change, details: %{reason: :feed_restarted}}},
                     5_000

      new_feed = Process.whereis(feed_name)
      assert is_pid(new_feed)
      assert new_feed != old_feed

      # The same wanted set, and the same subscriber: its delivery arrives on the new feed.
      assert DpExchange.Gemini.wanted(name: name) == ["BTC-USD"]
      assert_receive {:dp_exchange, :gemini, %TopOfBook{symbol: "BTC-USD"}}, 5_000
    end

    test "a feed that was never carrying anything restarts quietly" do
      name = tree_name(:quiet)
      start_tree(name: name)
      feed_name = Module.concat(name, "Feed")

      assert :ok = DpExchange.Gemini.subscribe_notices(name: name, to: self())
      old_feed = Process.whereis(feed_name)
      Process.exit(old_feed, :kill)

      # The notice subscriber is restored, and with nothing wanted nothing is announced.
      refute_receive {:dp_exchange, :gemini, %Notice{kind: :coverage_change}}, 500

      new_feed = Process.whereis(feed_name)
      assert is_pid(new_feed) and new_feed != old_feed
      assert MapSet.member?(:sys.get_state(new_feed).notice_subscribers, self())
    end
  end
end
