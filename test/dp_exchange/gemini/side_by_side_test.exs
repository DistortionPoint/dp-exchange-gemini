defmodule DpExchange.Gemini.SideBySideTest do
  @moduledoc """
  Production and demo, running at the same time in the same node.

  This is the case a consumer actually has — live trading against production while
  strategies are tested against the demo environment — and it is the one that found two
  bugs: a name collision that made the arrangement impossible, and a shared rate-limit
  bucket that made it dangerous.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Core.Config
  alias DpExchange.Gemini
  alias DpExchange.Gemini.{Environment, Supervisor}
  alias Elixir.Supervisor, as: ExSupervisor

  @moduletag :capture_log

  # Under the test supervisor, not `start_link` with an `on_exit` exit signal. Both trees use
  # the default GLOBAL names, and `Process.exit(pid, :shutdown)` only sends the signal: the
  # next test could start before the old supervisor had unregistered them, and failed with
  # `{:already_started, pid}`. Two of six `mix test --cover` runs did, measured 2026-09-26.
  # `start_supervised!/1` stops each child and waits for it before the next test begins.
  defp start_both do
    production =
      start_supervised!(
        ExSupervisor.child_spec({Gemini, environment: :production}, id: :production)
      )

    sandbox =
      start_supervised!(ExSupervisor.child_spec({Gemini, environment: :sandbox}, id: :sandbox))

    {production, sandbox}
  end

  describe "both environments start together with nothing named" do
    test "two trees, neither colliding" do
      {production, sandbox} = start_both()

      assert Process.alive?(production)
      assert Process.alive?(sandbox)
      refute production == sandbox
    end

    test "each tree registers its own supervisor, feed and limiter" do
      {_production, _sandbox} = start_both()

      for name <- [
            DpExchange.Gemini.Supervisor,
            DpExchange.Gemini.SandboxSupervisor,
            DpExchange.Gemini.Feed,
            DpExchange.Gemini.SandboxFeed,
            DpExchange.Gemini.RateLimiter,
            DpExchange.Gemini.SandboxRateLimiter
          ] do
        assert is_pid(Process.whereis(name)), "#{inspect(name)} is not registered"
      end
    end

    test "the two feeds are genuinely different processes" do
      {_production, _sandbox} = start_both()

      refute Process.whereis(DpExchange.Gemini.Feed) ==
               Process.whereis(DpExchange.Gemini.SandboxFeed)
    end
  end

  describe "the budgets do not touch, which is the dangerous one" do
    test "demo traffic meters against a different limiter than production" do
      # The silent failure this prevents: strategy testing against demo spending the
      # budget live trading depends on, surfacing later as a 429 on a real order with
      # nothing pointing back at the demo traffic that caused it.
      refute Supervisor.limiter_name(environment: :production) ==
               Supervisor.limiter_name(environment: :sandbox)
    end

    test "each limiter is separately reachable and separately full" do
      {_production, _sandbox} = start_both()

      for environment <- Environment.known() do
        limiter = Supervisor.limiter_name(environment: environment)

        assert DpExchange.Core.DefaultRateLimiter.check(:gemini, 1, limiter: limiter) == :ok
      end
    end

    test "an explicit :limiter still wins over the environment-derived default" do
      # A consumer running two of the SAME environment — two credentials, two scopes —
      # names them, and naming must not be overridden by this.
      assert Supervisor.limiter_name(environment: :sandbox, limiter: :mine) == :mine
      assert Supervisor.feed_name(environment: :sandbox, feed: :mine_feed) == :mine_feed
      assert Supervisor.supervisor_name(environment: :sandbox, name: :mine_sup) == :mine_sup
    end
  end

  describe "streaming calls follow the environment, as REST and the limiter do" do
    # The facade's default feed was the literal production one, so under `:sandbox` REST went
    # to demo while `subscribe/2`, `coverage/1` and `subscribe_notices/1` still addressed the
    # production feed whenever one was running: demo and live in one call path, silently.
    defp notice_subscribers(feed), do: :sys.get_state(feed).notice_subscribers

    test "a per-call :sandbox reaches the sandbox feed and leaves production alone" do
      {_production, _sandbox} = start_both()

      assert :ok = Gemini.subscribe_notices(environment: :sandbox, to: self())

      assert MapSet.member?(notice_subscribers(DpExchange.Gemini.SandboxFeed), self())
      refute MapSet.member?(notice_subscribers(DpExchange.Gemini.Feed), self())
    end

    test "a per-process :sandbox does the same, with no option on the call" do
      {_production, _sandbox} = start_both()
      Config.put_override(:environment, :sandbox)

      assert :ok = Gemini.subscribe_notices(to: self())

      assert MapSet.member?(notice_subscribers(DpExchange.Gemini.SandboxFeed), self())
      refute MapSet.member?(notice_subscribers(DpExchange.Gemini.Feed), self())
    end

    test "production stays the default" do
      {_production, _sandbox} = start_both()

      assert :ok = Gemini.subscribe_notices(to: self())

      assert MapSet.member?(notice_subscribers(DpExchange.Gemini.Feed), self())
      refute MapSet.member?(notice_subscribers(DpExchange.Gemini.SandboxFeed), self())
    end
  end

  describe "per-process selection, for a host running strategies on demo in some processes" do
    test "one process can be on demo while another is on production" do
      # `Core.Config` resolves per process, so this is not a global switch. A strategy
      # runner can be pointed at demo without redirecting the trading path beside it.
      task =
        Task.async(fn ->
          Config.put_override(:environment, :sandbox)
          Environment.resolve([])
        end)

      mine = Environment.resolve([])

      assert Task.await(task) == :sandbox
      assert mine == :production
    end

    test "a per-call option overrides whatever the process is set to" do
      Config.put_override(:environment, :sandbox)

      assert Environment.resolve(environment: :production) == :production
      assert Environment.resolve([]) == :sandbox
    end

    test "REST URLs differ per process without any shared state" do
      task =
        Task.async(fn ->
          Config.put_override(:environment, :sandbox)
          DpExchange.Gemini.Rest.base_url()
        end)

      assert DpExchange.Gemini.Rest.base_url() == "https://api.gemini.com"
      assert Task.await(task) == "https://api.sandbox.gemini.com"
    end
  end
end
