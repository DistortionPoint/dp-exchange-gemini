defmodule DpExchange.Gemini.TickAqTest do
  @moduledoc """
  Tick AQ: numbers and identifiers from venue text (S), start options (T), and state a stopped
  owner leaves behind (U).

    * A WebSocket frame's JSON numbers keep every digit; a bare fractional number is no frame.
    * The last-trade table a socket keeps is bounded.
    * A conversion's pair, a margin symbol, an FX pair and a clearing order's hours and
      counterparty are judged before anything is signed, real call and Fake alike.
    * A symbol-details reply that states no increment answers nothing.
    * A tree or feed refuses a start option it does not read, or cannot use, at start.
    * A resubscribe worker does not outlive a feed that was killed.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice}
  alias DpExchange.Core.Types.{Quote, TopOfBook, Trade}
  alias DpExchange.Gemini.{Fake, Feed, OptionKeys, Private, Rest, Socket}
  alias DpExchange.Gemini.Supervisor, as: GeminiSupervisor

  @moduletag :capture_log

  @credentials %{api_key: "account-test-key", api_secret: "test-secret-not-a-real-key"}

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

  defp exploding, do: fn _conn -> raise "must not reach the venue" end

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp unique, do: System.unique_integer([:positive])

  defp frame_state, do: %{subscriber: self(), last_heard_at: nil}

  defp book_frame(symbol, last) do
    Jason.encode!(%{"s" => symbol, "b" => "1", "a" => "2", "c" => last})
  end

  defp feed_frame(state, symbol, last) do
    Socket.handle_frame({:text, book_frame(symbol, last)}, state)
  end

  describe "a WebSocket frame keeps every digit of a JSON number" do
    # Against the bug: `Jason.decode/1` made 65000.12345678901234567 an Erlang float, which holds
    # 17 significant digits, so the low digits were gone before any decoder saw the frame.
    test "a bid and an ask sent as numbers arrive exactly" do
      frame = ~s({"s":"btcusd","b":65000.12345678901234567,"a":65001.5,"B":"1","A":"2"})

      assert {:ok, _state} = Socket.handle_frame({:text, frame}, frame_state())

      assert_receive {:dp_exchange, :gemini, %TopOfBook{bid: bid, ask: ask}}, 5_000
      assert Decimal.equal?(bid, Decimal.new("65000.12345678901234567"))
      assert Decimal.equal?(ask, Decimal.new("65001.5"))
    end

    test "a last trade sent as a number arrives exactly" do
      frame = ~s({"s":"btcusd","b":"1","a":"2","c":65000.12345678901234567})

      assert {:ok, _state} = Socket.handle_frame({:text, frame}, frame_state())

      assert_receive {:dp_exchange, :gemini, %Quote{price: price}}, 5_000
      assert Decimal.equal?(price, Decimal.new("65000.12345678901234567"))
    end

    test "a trade price and size sent as numbers arrive exactly" do
      frame =
        ~s({"e":"trade","s":"btcusd","t":7,"p":65000.12345678901234567,) <>
          ~s("q":0.12345678901234567,"m":true,"E":1787936147810330084})

      assert {:ok, _state} = Socket.handle_frame({:text, frame}, frame_state())

      assert_receive {:dp_exchange, :gemini, %Trade{price: price, quantity: quantity}}, 5_000
      assert Decimal.equal?(price, Decimal.new("65000.12345678901234567"))
      assert Decimal.equal?(quantity, Decimal.new("0.12345678901234567"))
    end

    # A fractional number alone is a `%Decimal{}` once decoded that way, and a Decimal is a map.
    test "a fractional number standing alone is an undecodable frame, not an object" do
      assert {:ok, _state} = Socket.handle_frame({:text, "1.5"}, frame_state())

      assert_receive {:dp_exchange, :gemini, %Notice{} = notice}, 5_000
      assert notice.kind == :data_quality
      assert notice.details.reason == :undecodable_frame
    end
  end

  describe "the last-trade table a socket keeps is bounded" do
    @bound 4_096

    defp tracked(count), do: Map.new(1..count, fn n -> {"SYM#{n}-USD", Decimal.new(n)} end)

    test "a new symbol at the bound restarts the table, and its Quote is still delivered" do
      state = Map.put(frame_state(), :last_trade_price, tracked(@bound))

      assert {:ok, after_frame} = feed_frame(state, "newusd", "10")

      assert Map.keys(after_frame.last_trade_price) == ["NEW-USD"]
      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "NEW-USD"}}, 5_000
    end

    test "a symbol already in the table at the bound is updated in place, not a restart" do
      state = Map.put(frame_state(), :last_trade_price, tracked(@bound))

      assert {:ok, after_frame} = feed_frame(state, "sym1usd", "99")

      assert map_size(after_frame.last_trade_price) == @bound
      assert Decimal.equal?(after_frame.last_trade_price["SYM1-USD"], Decimal.new(99))
    end

    test "a symbol seen again with the same price adds nothing and repeats nothing" do
      {:ok, once} = feed_frame(frame_state(), "btcusd", "10")
      {:ok, twice} = feed_frame(once, "btcusd", "10")

      assert map_size(twice.last_trade_price) == 1
      assert_receive {:dp_exchange, :gemini, %Quote{symbol: "BTC-USD"}}, 5_000
      refute_receive {:dp_exchange, :gemini, %Quote{}}
    end
  end

  describe "a conversion's pair is judged before anything is signed" do
    # Against the bug: `"" -> "USD"` was joined to `"-USD"` and sent as the symbol `usd`.
    @bad_pairs [
      {"", "USD", ""},
      {"USD", "", ""},
      {"BTC-X", "USD", "BTC-X"},
      {"USD", " BTC", " BTC"}
    ]

    test "a blank or separator-bearing asset is an invalid asset, never a derived symbol" do
      for {from, to, bad} <- @bad_pairs do
        refusal = {:error, {:invalid_asset, bad}}
        amount = Decimal.new(1)

        assert Private.instant_pair(from, to, []) == refusal

        real = Private.quote_conversion(from, to, amount, credentials: @credentials)
        assert real == refusal

        fake = Fake.quote_conversion(from, to, amount, credentials: @credentials)
        assert fake == refusal
      end
    end

    test "a blank :symbol is an invalid option, not the pair" do
      for symbol <- ["", "   "] do
        refusal = {:error, {:invalid_option, :symbol, symbol}}
        opts = [credentials: @credentials, symbol: symbol, side: :buy]

        assert Private.instant_pair("BTC", "USD", symbol: symbol, side: :buy) == refusal
        assert Fake.convert("BTC", "USD", Decimal.new(1), opts) == refusal
      end
    end

    test "a named symbol and side still make the pair" do
      assert {:ok, "gusdusd", "sell"} =
               Private.instant_pair("GUSD", "USD", symbol: "GUSD-USD", side: :sell)
    end
  end

  describe "a margin read's symbol is text" do
    test "an atom or blank :symbol is refused before the credential, real call and Fake alike" do
      for symbol <- [:btcgusdperp, "", "  ", 5] do
        refusal = {:error, {:invalid_option, :symbol, symbol}}
        real_opts = [symbol: symbol, plug: exploding()]
        fake_opts = [credentials: @credentials, symbol: symbol]

        assert Private.get_account_margin(@credentials, real_opts) == refusal
        assert Private.get_margin_account(@credentials, real_opts) == refusal
        assert Fake.get_account_margin(fake_opts) == refusal
        assert Fake.get_margin_account(fake_opts) == refusal
      end
    end

    test "an absent :symbol is still a missing option" do
      assert Private.validate_margin_symbol([]) == {:error, {:missing_option, :symbol}}
    end

    test "a margin preview of a blank symbol is missing its fields, real call and Fake alike" do
      request = %{symbol: " ", side: :buy, type: :limit, amount: "1", price: "2"}

      real = Private.preview_margin_order(request, @credentials, plug: exploding())
      assert real == {:error, :missing_order_fields}

      fake = Fake.preview_margin_order(request, credentials: @credentials)
      assert fake == {:error, :missing_order_fields}
    end
  end

  describe "an FX pair has one separator, between two codes" do
    @at ~U[2026-08-28 12:00:00Z]

    test "the spellings that name no pair are not the pair they collapse to" do
      refusal = {:error, {:unsupported_fx_pair, "EURUSD"}}

      for bad <- ["E-U-R-U-S-D", "EURUSD-", "-EURUSD", "EU-RUSD", "EUR--USD"] do
        assert Private.validate_fx_pair(bad) == refusal
        assert Fake.get_fx_rate(bad, @at, credentials: @credentials) == refusal
      end
    end

    test "the spellings the venue's pairs have are accepted" do
      for good <- ["EURUSD", "eurusd", "EUR-USD", "eur-usd", :"EUR-USD", :EURUSD] do
        assert Private.validate_fx_pair(good) == {:ok, "EURUSD"}
      end
    end
  end

  describe "a clearing order's hours and counterparty are judged before it is signed" do
    @terms %{symbol: "btcusd", amount: "1", price: "9500", side: :buy}

    test "expires_in_hrs is a whole number of hours above zero" do
      for hours <- [0, -5, 1.5, "24", "soon", :tomorrow] do
        refusal = {:error, {:invalid_option, :expires_in_hrs, hours}}
        real_opts = [expires_in_hrs: hours, plug: exploding()]
        fake_opts = [credentials: @credentials, expires_in_hrs: hours]

        assert Private.create_clearing_order(@terms, @credentials, real_opts) == refusal
        assert Fake.create_clearing_order(@terms, fake_opts) == refusal
      end

      good = Fake.create_clearing_order(@terms, credentials: @credentials, expires_in_hrs: 24)
      assert {:ok, %{"result" => "AwaitConfirm"}} = good
    end

    test "counterparty_id is a non-blank string when given" do
      for counterparty <- ["", "  ", 5, :abc] do
        refusal = {:error, {:invalid_option, :counterparty_id, counterparty}}
        real_opts = [counterparty_id: counterparty, plug: exploding()]
        fake_opts = [credentials: @credentials, counterparty_id: counterparty]

        assert Private.create_clearing_order(@terms, @credentials, real_opts) == refusal
        assert Fake.create_clearing_order(@terms, fake_opts) == refusal
      end
    end

    test "the terms are still judged first" do
      request = %{@terms | amount: "-1"}
      opts = [expires_in_hrs: 0, plug: exploding()]

      real = Private.create_clearing_order(request, @credentials, opts)
      assert real == {:error, {:invalid_amount, "-1"}}
    end

    test "the broker form's required hours are positive too" do
      parties = [source_counterparty_id: "s", target_counterparty_id: "t"]

      for hours <- [0, -1, 2.0, "1"] do
        refusal = {:error, {:invalid_option, :expires_in_hrs, hours}}
        real_opts = [expires_in_hrs: hours, plug: exploding()] ++ parties
        fake_opts = [credentials: @credentials, expires_in_hrs: hours] ++ parties

        assert Private.create_broker_clearing_order(@terms, @credentials, real_opts) == refusal
        assert Fake.create_broker_clearing_order(@terms, fake_opts) == refusal
      end

      missing = Fake.create_broker_clearing_order(@terms, [credentials: @credentials] ++ parties)
      assert missing == {:error, {:missing_option, :expires_in_hrs}}
    end
  end

  describe "a symbol-details reply that states no increment answers nothing" do
    setup do
      Config.put_override(:rate_limit_module, PermissiveLimiter)
      :ok
    end

    test "an empty object, or one with only a status, is a shape error, not an all-nil success" do
      for body <- [%{}, %{"status" => "open"}, %{"min_order_size" => "0.00001"}] do
        reply = Rest.quantization("BTC-USD", plug: responding(body), retry_attempts: 0)
        assert reply == {:error, :unexpected_response_shape}
      end
    end

    test "one stated increment is enough, and the other stays nil" do
      for {key, value} <- [{"tick_size", 1.0e-8}, {"quote_increment", 0.01}] do
        opts = [plug: responding(%{key => value}), retry_attempts: 0]

        assert {:ok, quantization} = Rest.quantization("BTC-USD", opts)

        increments = [quantization.price_increment, quantization.quantity_increment]
        assert Enum.count(increments, &is_nil/1) == 1
      end
    end
  end

  describe "a start option the tree does not read, or cannot use, is refused at start" do
    test "an unknown key starts nothing: a misspelt max_queue_len is not the default bound" do
      name = :"tick_aq_feed_#{unique()}"

      assert Feed.start_link(name: name, max_queu_len: 5) ==
               {:error, {:unknown_option, :max_queu_len}}

      assert Process.whereis(name) == nil
    end

    test "the tree refuses before it starts a ledger, a limiter or a feed" do
      id = unique()
      names = for part <- ~w(sup feed limiter ledger), do: :"tick_aq_#{part}_#{id}"
      [sup, feed, limiter, _ledger] = names
      tree = [name: sup, feed: feed, limiter: limiter]

      slow = GeminiSupervisor.start_link(tree ++ [socket_connect_timeout: "3000"])
      assert slow == {:error, {:invalid_option, :socket_connect_timeout, "3000"}}

      bogus = GeminiSupervisor.start_link(tree ++ [bogus: 1])
      assert bogus == {:error, {:unknown_option, :bogus}}

      assert Enum.all?(names, &(Process.whereis(&1) == nil))
    end

    test "a timeout is a positive whole number of milliseconds, or nil for absent" do
      for key <- [:socket_connect_timeout, :socket_recv_timeout],
          bad <- [0, -1, 1.5, "100", :infinity] do
        assert Feed.check_start_options([{key, bad}]) == {:error, {:invalid_option, key, bad}}
      end

      ok = Feed.check_start_options(socket_connect_timeout: nil, socket_recv_timeout: 500)
      assert ok == :ok
    end

    test "an environment is one the package knows, and the tree no longer raises on a typo" do
      typo = {:error, {:invalid_option, :environment, :sandox}}

      assert Feed.check_start_options(environment: :sandox) == typo
      assert GeminiSupervisor.start_link(environment: :sandox) == typo

      assert Feed.check_start_options(environment: nil) ==
               {:error, {:invalid_option, :environment, nil}}

      assert Feed.check_start_options(environment: :sandbox) == :ok
    end

    test "a url is a parseable WebSocket URL, and the refusal does not echo it" do
      secret_url = "not a url?token=s3cr3t"

      for bad <- [secret_url, 42, ""] do
        assert Feed.check_start_options(url: bad) == {:error, {:invalid_option, :url, :redacted}}
      end

      assert Feed.check_start_options(url: nil) == :ok
      assert Feed.check_start_options(url: "ws://127.0.0.1:9/") == :ok
    end

    test "options that are not a keyword list are refused with the credentials redacted" do
      reply = Feed.check_start_options(%{credentials: @credentials, name: :x})

      assert reply == {:error, {:invalid_options, %{credentials: :redacted, name: :x}}}
    end

    test "every key the tree passes its feed is in the table" do
      for key <- [:name, :feed, :limiter, :ledger, :credentials, :ssl_options, :channels] do
        assert OptionKeys.check_start([{key, nil}]) == :ok
      end
    end

    test "the Fake is started with the same refusals, and starts nothing" do
      assert Fake.start_link([]) == :ignore
      assert Fake.start_link(name: :anything, environment: :sandbox) == :ignore
      assert Fake.start_link(bogus: 1) == {:error, {:unknown_option, :bogus}}

      slow = Fake.start_link(socket_recv_timeout: 0)
      assert slow == {:error, {:invalid_option, :socket_recv_timeout, 0}}
    end
  end

  describe "a resubscribe worker does not outlive its feed" do
    # A socket that reports each frame it is sent and never answers it, so the worker is held in
    # WebSockex's 5s send window.
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

    # A feed with one wanted symbol and a resubscribe in flight to a socket that never answers.
    defp feed_with_worker(label) do
      Process.flag(:trap_exit, true)
      socket = stalled_socket(self())
      {:ok, feed} = Feed.start_link(name: :"tick_aq_#{label}_#{unique()}", socket: socket)
      :sys.replace_state(feed, &%{&1 | wanted: MapSet.new(["BTC-USD"])})

      send(feed, :resubscribe)
      assert_receive {:frame_seen, %{"method" => "subscribe"}}, 5_000
      %{pid: worker} = :sys.get_state(feed).resub
      {feed, worker}
    end

    test "killing the feed ends the worker at once, not after its send window" do
      {feed, worker} = feed_with_worker("killed")
      monitor = Process.monitor(worker)

      started = System.monotonic_time(:millisecond)
      Process.exit(feed, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 10_000
      # The send window is 5s, so a worker that waited it out ends at 5s or later. This is a
      # measured elapsed time, not a receive margin: the wait above is 10s.
      assert System.monotonic_time(:millisecond) - started < 4_500
      assert_receive {:EXIT, ^feed, :killed}, 5_000
    end

    test "a feed that stops normally still takes its worker with it" do
      {feed, worker} = feed_with_worker("stopped")
      monitor = Process.monitor(worker)

      assert :ok = GenServer.stop(feed)

      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
    end
  end
end
