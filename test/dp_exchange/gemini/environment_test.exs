defmodule DpExchange.Gemini.EnvironmentTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Environment, Rest}

  describe "the URLs, which are measured rather than taken from the page" do
    test "production" do
      assert Environment.rest_url(:production) == "https://api.gemini.com"
      assert Environment.websocket_url(:production) == "wss://ws.gemini.com"
    end

    test "demo" do
      assert Environment.rest_url(:sandbox) == "https://api.sandbox.gemini.com"
      assert Environment.websocket_url(:sandbox) == "wss://ws.sandbox.gemini.com"
    end

    test "the REST host is api.sandbox, NOT exchange.sandbox" do
      # Gemini's market-data page names `exchange.sandbox.gemini.com` as the sandbox base
      # URL. That is the website. Measured 2026-08-28: `/v1/symbols` there returns 404 and
      # an HTML page, while api.sandbox returns 391 symbols. A consumer following that
      # page gets 404s that read like a broken endpoint rather than a wrong host.
      refute Environment.rest_url(:sandbox) =~ "exchange.sandbox"
      assert Environment.rest_url(:sandbox) =~ "api.sandbox"
    end
  end

  describe "resolution" do
    test "defaults to production" do
      # The safe direction. Meaning demo and getting production sends a real order to a
      # real exchange; meaning production and getting demo gives obviously-wrong prices.
      assert Environment.resolve([]) == :production
    end

    test "an explicit option wins" do
      assert Environment.resolve(environment: :sandbox) == :sandbox
    end

    test "Core.Config resolves it per process, so async tests do not collide" do
      Config.put_override(:environment, :sandbox)

      assert Environment.resolve([]) == :sandbox
    end

    test "an explicit option beats the process-scoped setting" do
      Config.put_override(:environment, :sandbox)

      assert Environment.resolve(environment: :production) == :production
    end

    test "an unknown environment RAISES rather than falling back" do
      # A typo must not quietly become a live order. This is the family's named failure
      # mode with the highest possible stake, so it is the one place that raises.
      assert_raise ArgumentError, ~r/unknown Gemini environment :sandox/, fn ->
        Environment.resolve(environment: :sandox)
      end
    end

    test "the error explains why it refuses instead of defaulting" do
      error =
        assert_raise ArgumentError, fn -> Environment.resolve(environment: "sandbox") end

      assert Exception.message(error) =~ "real order to a real exchange"
    end
  end

  describe "the feed carries the environment through to the socket" do
    test ":environment survives into the options the socket is dialled with" do
      # The feed is what starts the socket, so a tree started with `environment: :sandbox`
      # only reaches the demo host if the feed forwards it. Asserting the process is alive
      # would prove nothing — this reads the options it would dial with.
      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(
          name: :"env_feed_#{System.unique_integer([:positive])}",
          environment: :sandbox,
          socket: self()
        )

      assert :sys.get_state(feed).socket_opts[:environment] == :sandbox
    end

    test "an explicit :url is carried too, which is what keeps tests off the network" do
      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(
          name: :"url_feed_#{System.unique_integer([:positive])}",
          url: "wss://127.0.0.1:1/nowhere",
          socket: self()
        )

      assert :sys.get_state(feed).socket_opts[:url] == "wss://127.0.0.1:1/nowhere"
    end

    test "nothing else leaks into the socket's options" do
      # The feed takes only what the socket needs. A credential or a limiter name reaching
      # a socket would be a boundary this package should not cross.
      {:ok, feed} =
        DpExchange.Gemini.Feed.start_link(
          name: :"tidy_feed_#{System.unique_integer([:positive])}",
          environment: :sandbox,
          limiter: :some_limiter,
          socket: self()
        )

      assert Keyword.keys(:sys.get_state(feed).socket_opts) == [:environment]
    end
  end

  describe "live?/1 names which one moves real money" do
    test "production does, demo does not" do
      assert Environment.live?(:production)
      refute Environment.live?(:sandbox)
    end

    test "every known environment answers" do
      for environment <- Environment.known() do
        assert is_boolean(Environment.live?(environment))
      end
    end
  end

  describe "REST follows the environment" do
    test "by default it is production" do
      assert Rest.base_url() == "https://api.gemini.com"
    end

    test "an explicit option redirects it" do
      assert Rest.base_url(environment: :sandbox) == "https://api.sandbox.gemini.com"
    end

    test "the process-scoped setting redirects it" do
      Config.put_override(:environment, :sandbox)

      assert Rest.base_url() == "https://api.sandbox.gemini.com"
    end

    test "an explicit :base_url still wins, which is what the test seam needs" do
      assert Rest.base_url(base_url: "https://elsewhere.test", environment: :sandbox) ==
               "https://elsewhere.test"
    end
  end
end
