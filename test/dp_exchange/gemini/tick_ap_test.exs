defmodule DpExchange.Gemini.TickApTest do
  @moduledoc """
  Tick AP: clocks and timers, and the documentation's claims about them.

    * A feed's delivery record is stamped on the monotonic clock, not the wall clock.
    * The socket's moduledoc says what the venue's AsyncAPI document says about heartbeats,
      sequences and the `ping` method, and a change to the reference that falsifies it fails
      here.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Gemini.{Fake, Feed, Private, Rest, Socket}

  @moduletag :capture_log

  @websocket_reference Path.expand(
                         "../../../docs/reference/gemini/asyncapi/websocket.yaml",
                         __DIR__
                       )

  defp start_feed do
    name = :"tick_ap_feed_#{System.unique_integer([:positive])}"
    {:ok, pid} = Feed.start_link(name: name)
    pid
  end

  defp quote_for(symbol) do
    %Quote{
      symbol: symbol,
      price: Decimal.new("77845.79"),
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :gemini
    }
  end

  describe "a delivery record is an elapsed-time reading" do
    # Against the bug: `:os.system_time(:millisecond)` is ~1.8e12 and `System.monotonic_time/1`
    # is an unrelated (often negative) number, so a stamp read from the wall clock cannot sit
    # between two monotonic readings taken around the delivery.
    test "the stamp lies between two monotonic readings taken around the frame" do
      feed = start_feed()
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      before_frame = System.monotonic_time(:millisecond)
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      # A call is answered after the frame was handled: the mailbox is in order.
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
      after_frame = System.monotonic_time(:millisecond)

      stamp = :sys.get_state(feed).delivering_by_kind.quotes["BTC-USD"]

      assert is_integer(stamp)
      assert stamp >= before_frame and stamp <= after_frame
    end
  end

  # A socket that reports each frame it is sent and never answers it: what the feed meets when
  # the real socket is too busy, or asleep in a reconnect backoff, to read a send.
  defp stalled_socket(report_to) do
    socket = spawn(fn -> stall(report_to) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    socket
  end

  defp stall(report_to) do
    receive do
      {:"$websockex_send", _from, {:text, frame}} ->
        send(report_to, {:frame_seen, Jason.decode!(frame)})
        stall(report_to)
    end
  end

  # A socket that answers every frame `:ok` and reports it.
  defp answering_socket(report_to) do
    socket = spawn(fn -> answer(report_to) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    socket
  end

  defp answer(report_to) do
    receive do
      {:"$websockex_send", from, {:text, frame}} ->
        send(report_to, {:frame_sent, Jason.decode!(frame)})
        :gen.reply(from, :ok)
        answer(report_to)
    end
  end

  describe "a resubscribe never blocks the feed on the wire" do
    test "the feed keeps handling frames and calls while the socket does not answer a send" do
      socket = stalled_socket(self())
      name = :"tick_ap_stalled_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name, socket: socket)
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)

      # The worker's frame reached the socket, which will not answer it for 5s. Before the
      # fix the feed itself was the one waiting, and everything below queued behind it.
      assert_receive {:frame_seen, %{"method" => "subscribe"}}, 5_000
      assert %{pid: worker} = :sys.get_state(feed).resub

      # A frame is delivered and counted, and a call is answered, while the send is pending.
      send(feed, {:dp_exchange, :gemini, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
      assert Process.alive?(worker)
      assert %{pid: ^worker} = :sys.get_state(feed).resub
    end

    test "a request made while one is in flight is folded into it, not run beside it" do
      socket = stalled_socket(self())
      name = :"tick_ap_folded_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name, socket: socket)
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      assert_receive {:frame_seen, %{"method" => "subscribe"}}, 5_000
      assert %{pid: worker, again?: false} = :sys.get_state(feed).resub

      send(feed, :resubscribe)

      assert %{pid: ^worker, again?: true} = :sys.get_state(feed).resub
    end

    test "a worker that dies unanswered is a failed resubscribe, and the latch fires once" do
      socket = stalled_socket(self())
      name = :"tick_ap_died_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name, socket: socket)
      :ok = Feed.subscribe_notices(feed, to: self())
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      assert_receive {:frame_seen, %{"method" => "subscribe"}}, 5_000
      %{pid: worker} = :sys.get_state(feed).resub

      Process.exit(worker, :kill)

      assert_receive {:dp_exchange, :gemini,
                      %Notice{kind: :coverage_change, details: %{reason: :resubscribe_failed}}},
                     5_000

      assert :sys.get_state(feed).resub == nil
      assert :sys.get_state(feed).resubscribe_notice_state == :dead
    end
  end

  describe "a call held behind a dial is replayed only while its caller is still waiting" do
    defp install_dial(feed, socket) do
      ref = make_ref()

      :sys.replace_state(feed, fn state ->
        timer = Process.send_after(self(), {:dial_timeout, ref}, 600_000)

        dial = %{
          socket: socket,
          ref: ref,
          timer: timer,
          waiters: [],
          waiting: 0,
          resubscribe?: false
        }

        %{state | socket: socket, dial: dial}
      end)
    end

    # Polls the feed (answering is itself a proof it is alive) until `count` calls are held.
    defp await_held(feed, count, tries \\ 5_000) do
      cond do
        :sys.get_state(feed).dial.waiting == count -> :ok
        tries == 0 -> flunk("the feed never held #{count} calls")
        true -> await_held(feed, count, tries - 1)
      end
    end

    test "a waiter whose deadline has passed is refused by name; the others are replayed" do
      socket = answering_socket(self())
      name = :"tick_ap_dial_#{System.unique_integer([:positive])}"
      {:ok, feed} = Feed.start_link(name: name)
      install_dial(feed, socket)
      me = self()

      gone = Task.async(fn -> Feed.subscribe(feed, ["BTC-USD"], to: me) end)
      await_held(feed, 1)

      # Its caller's `@call_timeout` has run out by the time the dial connects. Relative to
      # now, not `0`: the monotonic clock is often negative, so `0` can lie in the future.
      past = System.monotonic_time(:millisecond) - 1

      :sys.replace_state(feed, fn state ->
        waiters = Enum.map(state.dial.waiters, fn {from, call, _at} -> {from, call, past} end)
        %{state | dial: %{state.dial | waiters: waiters}}
      end)

      waiting = Task.async(fn -> Feed.subscribe(feed, ["ETH-USD"], to: me) end)
      await_held(feed, 2)

      send(feed, {:dp_exchange, :gemini, :connected, socket})

      assert {:error, :dial_deadline_exceeded} = Task.await(gone, 30_000)
      assert :ok = Task.await(waiting, 30_000)

      # Nothing was recorded or sent for the refused call; the other was applied as usual.
      assert Feed.wanted(feed) == ["ETH-USD"]
      assert_receive {:frame_sent, %{"method" => "subscribe", "params" => ["ethusd@bookTicker"]}}
      refute_received {:frame_sent, %{"params" => ["btcusd@bookTicker"]}}
    end
  end

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

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  # 2026-08-24T00:00:00Z in SECONDS: a valid `DateTime` as seconds, 1970-01-21 as milliseconds.
  @seconds 1_787_270_400
  @milliseconds 1_787_270_400_000

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("date", "Fri, 28 Aug 2026 17:00:01 GMT")
      |> Req.Test.json(body)
    end
  end

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  describe "a seconds value in a milliseconds field is another unit, not a 1970 time" do
    setup do
      Config.put_override(:rate_limit_module, PermissiveLimiter)
      :ok
    end

    # Against the bug: `timestampms: 1787270400` was `> 0`, a valid `DateTime`, 1970-01-21.
    test "a public print timed in seconds in `timestampms` is refused; in `timestamp` it reads" do
      row = %{"tid" => 1, "price" => "100.5", "amount" => "0.1", "type" => "buy"}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_trades(
                 "BTC-USD",
                 opts(responding([Map.put(row, "timestampms", @seconds)]))
               )

      assert {:ok, [trade]} =
               Rest.get_trades(
                 "BTC-USD",
                 opts(responding([Map.put(row, "timestamp", @seconds)]))
               )

      assert DateTime.to_unix(trade.timestamp) == @seconds

      # And the other way round, as before: milliseconds in the seconds field is out of range.
      assert {:error, :missing_venue_timestamp} =
               Rest.get_trades(
                 "BTC-USD",
                 opts(responding([Map.put(row, "timestamp", @milliseconds)]))
               )
    end

    test "a funding time and a candle time in seconds are refused, in milliseconds they read" do
      body = %{"symbol" => "btcgusdperp", "nextFundingTimestamp" => @seconds}

      assert Rest.get_funding("BTCGUSDPERP", opts(responding(body))) ==
               {:error, :unexpected_response_shape}

      assert {:ok, funding} =
               Rest.get_funding(
                 "BTCGUSDPERP",
                 opts(responding(%{body | "nextFundingTimestamp" => @milliseconds}))
               )

      assert DateTime.to_unix(funding.next_funding_at) == @seconds

      row = [@seconds, "1.5", "2.5", "1.0", "2.0", "3.0"]

      assert Rest.get_historical_prices("BTC-USD", "1d", [], opts(responding([row]))) ==
               {:error, {:unparseable_venue_timestamp, @seconds}}
    end

    test "a fill timed in seconds is refused, never dated to 1970" do
      fill = %{
        "order_id" => "1",
        "price" => "100",
        "amount" => "0.5",
        "type" => "Buy",
        "symbol" => "btcusd",
        "timestampms" => @seconds
      }

      assert {:error, {:unparseable_venue_timestamp, @seconds}} =
               Private.get_trade_history(@credentials, opts(responding([fill])))

      assert {:ok, [read]} =
               Private.get_trade_history(
                 @credentials,
                 opts(responding([%{fill | "timestampms" => @milliseconds}]))
               )

      assert DateTime.to_unix(read.timestamp) == @seconds
    end
  end

  describe "a bound the package multiplies, or names in nanoseconds, must be in that unit" do
    setup do
      Config.put_override(:rate_limit_module, PermissiveLimiter)
      :ok
    end

    test "get_transactions refuses a :since that is not milliseconds, real call and Fake alike" do
      # Multiplied into `timestamp_nanos`, 1.78e9 is 1970-01-21 and the venue answered the whole
      # history for what was meant as a recent bound.
      for bad <- [@seconds, "1787270400", 1, 1_420_070_399_999] do
        refusal = {:error, {:invalid_option, :since, bad}}

        assert Private.get_transactions(@credentials, [since: bad] ++ opts(exploding())) ==
                 refusal

        assert Fake.get_transactions(@credentials, since: bad) == refusal
      end

      for good <- [@milliseconds, "1787270400000", ~U[2026-08-24 00:00:00Z], 1_420_070_400_000] do
        assert {:ok, _rows} = Fake.get_transactions(@credentials, since: good)
      end

      me = self()

      capture = fn conn ->
        payload =
          conn
          |> Plug.Conn.get_req_header("x-gemini-payload")
          |> List.first()
          |> Base.decode64!()
          |> Jason.decode!()

        send(me, {:payload, payload})
        Req.Test.json(conn, %{"results" => []})
      end

      assert {:ok, []} =
               Private.get_transactions(@credentials, [since: @milliseconds] ++ opts(capture))

      assert_receive {:payload, %{"timestamp_nanos" => nanos}}, 5_000
      assert nanos == @milliseconds * 1_000_000
    end

    test "list_clearing_trades refuses a :since_nanos below 2015 in nanoseconds, Fake alike" do
      # A milliseconds or seconds value in the nanoseconds field is January 1970 to the venue.
      for bad <- [@milliseconds, @seconds, "1787270400000", 1_420_070_399_999_999_999] do
        refusal = {:error, {:invalid_option, :since_nanos, bad}}
        real = Private.list_clearing_trades(@credentials, [since_nanos: bad] ++ opts(exploding()))

        assert real == refusal
        assert Fake.list_clearing_trades(credentials: @credentials, since_nanos: bad) == refusal
      end

      good = @milliseconds * 1_000_000

      assert {:ok, _rows} =
               Fake.list_clearing_trades(credentials: @credentials, since_nanos: good)

      assert {:ok, _rows} =
               Fake.list_clearing_trades(
                 credentials: @credentials,
                 since_nanos: ~U[2026-08-24 00:00:00Z]
               )
    end
  end

  describe "the socket's documentation about liveness matches the venue's reference" do
    defp socket_moduledoc do
      {:docs_v1, _anno, _language, _format, %{"en" => doc}, _meta, _docs} =
        Code.fetch_docs(Socket)

      doc
    end

    test "the reference lists a `ping` request method and models no reply or heartbeat" do
      reference = File.read!(@websocket_reference)

      # The request envelope is there ...
      assert reference =~ "PingRequest"
      assert reference =~ "const: ping"
      # ... and nothing the socket could wait on: no pong or heartbeat message, no sequence
      # number on the connection.
      refute reference =~ ~r/pong/i
      refute reference =~ ~r/heartbeat/i
      refute reference =~ ~r/socket_sequence/i
    end

    test "the moduledoc names the ping method, says its reply is not modelled, and the window" do
      doc = socket_moduledoc()

      assert doc =~ "PingRequest"
      assert doc =~ "not enumerated"
      assert doc =~ "socket_sequence"
      assert doc =~ "between 90s and"
      assert doc =~ "System.monotonic_time/1"
    end
  end
end
