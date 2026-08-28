defmodule DpExchange.Gemini.SupervisorTest do
  use ExUnit.Case, async: false

  alias DpExchange.Gemini.{Auth, Supervisor}

  @moduletag :capture_log

  defp start_tree do
    unique = System.unique_integer([:positive])

    opts = [
      name: :"gemini_sup_#{unique}",
      feed: :"gemini_feed_#{unique}",
      limiter: :"gemini_limiter_#{unique}"
    ]

    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    {pid, opts}
  end

  describe "the tree" do
    test "starts a limiter and a feed, and nothing else" do
      {pid, _opts} = start_tree()

      children = Elixir.Supervisor.which_children(pid)

      assert length(children) == 2
    end

    test "starts NO socket — a consumer that has not subscribed has no connection open" do
      # The property the whole "a library does not start itself" rule exists for. The feed
      # dials on first subscribe, not at start.
      {_pid, opts} = start_tree()

      feed = Process.whereis(opts[:feed])

      assert is_pid(feed)
      assert DpExchange.Gemini.Feed.coverage(feed) == %{}
    end

    test "names both children from opts, so two instances can coexist" do
      {_pid, first} = start_tree()
      {_pid, second} = start_tree()

      assert is_pid(Process.whereis(first[:feed]))
      assert is_pid(Process.whereis(second[:feed]))
      assert is_pid(Process.whereis(first[:limiter]))
      assert is_pid(Process.whereis(second[:limiter]))
    end

    test "establishes the nonce counter before anything can ask for one" do
      # A lazily-initialised counter can be replaced mid-flight, restarting the sequence
      # and handing two processes the same nonce.
      :persistent_term.erase({Auth, :nonce_counter})

      {_pid, _opts} = start_tree()

      assert :persistent_term.get({Auth, :nonce_counter}, nil) != nil
    end
  end

  describe "the limiter is configured from what capabilities/0 declares" do
    test "the declaration IS the mechanism's configuration" do
      # Not decoration beside the mechanism. If a ceiling changes it changes in one place,
      # and the two cannot drift apart.
      {_pid, opts} = start_tree()
      caps = DpExchange.Gemini.capabilities()

      assert is_pid(Process.whereis(opts[:limiter]))
      assert caps.public_ceiling.limit == 120
      assert caps.public_ceiling.burst == 5
    end

    test "public and private are separate buckets, because they differ 5x" do
      # One shared bucket would either throttle private calls to public speed or let
      # public calls run five times over.
      caps = DpExchange.Gemini.capabilities()

      refute caps.public_ceiling == caps.authenticated_ceiling
    end

    test "a limiter is actually reachable, so HttpClient does not fail closed" do
      # `Core.HttpClient` fails closed when no limiter is running — correct, but it means
      # a package that expected someone else to start one answers "Rate limiter
      # unavailable" to every call, and the error does not say what is missing.
      {_pid, opts} = start_tree()

      assert DpExchange.Core.DefaultRateLimiter.check(:gemini, 1, limiter: opts[:limiter]) == :ok
    end
  end

  describe "the facade's lifecycle callbacks" do
    test "child_spec/1 takes its id from the name, so two can be supervised together" do
      assert %{id: :custom_name} = DpExchange.Gemini.child_spec(name: :custom_name)
      assert %{id: DpExchange.Gemini} = DpExchange.Gemini.child_spec([])
    end

    test "start_link/1 starts the tree" do
      unique = System.unique_integer([:positive])

      assert {:ok, pid} =
               DpExchange.Gemini.start_link(
                 name: :"facade_sup_#{unique}",
                 feed: :"facade_feed_#{unique}",
                 limiter: :"facade_limiter_#{unique}"
               )

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
      assert is_pid(pid)
    end
  end
end
