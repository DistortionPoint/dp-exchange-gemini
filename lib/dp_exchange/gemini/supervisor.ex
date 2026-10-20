defmodule DpExchange.Gemini.Supervisor do
  @moduledoc """
  This venue's process tree — internal. A consumer starts `DpExchange.Gemini` and gets
  this; it never names or reaches into the children.

  ## The venue starts its own rate limiter, configured from what it declares

  Rate limiting is venue-internal under the facade contract, and this is what that means:
  **the ceilings `capabilities/0` declares are the ceilings the limiter is configured
  with.** The declaration is not decoration beside the mechanism — it *is* the mechanism's
  configuration, so the two cannot drift apart.

  ### Gemini publishes all three GCRA parameters, which no other venue here has

  Coinbase's limits had to be inherited from a prior adapter's moduledoc, unmeasured and
  labelled as such. Gemini states its own, on a documentation page, in words:

  > For public API entry points, we limit requests to **120 requests per minute** …
  > For private API entry points, we limit requests to **600 requests per minute** …
  > we offer a **"burst" rate of five additional requests** that are queued …

  That is `limit`, `per_ms` and `burst` — every parameter `Core.DefaultRateLimiter` takes,
  from the venue rather than from us. **`burst: 5` is a venue fact here, not a tuning
  choice**, which matters because Core's limiter had a defect where a declared burst of
  *n* granted *n − 1*. A venue that publishes its burst depth turns that class of bug from
  invisible into assertable.

  ### Public and private are separate buckets

  They differ 5×. One shared bucket would either throttle private calls to public speed or
  let public calls run five times over — and the venue's own wording is "the rate limit
  for a **group** of endpoints", which is two groups.

  ## Production and demo run side by side, and every default name accounts for it

  A consumer trading live while testing strategies against the demo environment is running
  **two of this venue at once**, in one node. That is a first-class case here, not a
  configuration someone has to discover:

      children = [
        {DpExchange.Gemini, environment: :production},
        {DpExchange.Gemini, environment: :sandbox}
      ]

  Nothing needs naming. The supervisor, the feed and the limiter all derive their default
  names from the environment, for two independent reasons — and both were bugs before the
  case was thought through:

    * **Name collision.** With one shared set of defaults the second tree fails to start,
      so the whole arrangement is simply unavailable.
    * **Budget contamination**, which is the worse one because it is silent. A REST call
      carrying `environment: :sandbox` but no `:limiter` metered against the *production*
      bucket. Strategy testing against demo would spend the budget live trading depends
      on, and the symptom would be a 429 on a real order at an arbitrary later moment,
      with nothing pointing at the demo traffic that caused it.

  Explicit names still win everywhere, for a consumer running two of the *same*
  environment — two credentials, two scopes. A tree started with a non-default atom `:name`
  and no `:feed` or `:limiter` names its processes after itself (`Module.concat(name, "Feed")`,
  `"RateLimiter"`, and the feed's `"Ledger"`), so two accounts need only distinct `name:`s, and
  a facade call carrying the same `name:` addresses that tree's feed and limiter.

  ## A feed restart keeps what the feed was asked to carry

  The tree is `:rest_for_one` over `Ledger`, the limiter and the `Feed`. The feed tells the
  ledger its accepted intent (wanted symbols, data and notice subscribers) after every change;
  a restarted feed reads it back in `handle_continue/2`, re-monitors the subscribers,
  resubscribes, and sends each notice subscriber a `:coverage_change` notice
  (`details.reason: :feed_restarted`). See `DpExchange.Gemini.Ledger`.

  ## What is deliberately not here

  No auto-start and no aggregate supervisor. A consumer puts `DpExchange.Gemini` in its own
  tree and chooses restart strategy, shutdown order and naming. A consumer that has not
  asked for this venue never finds a socket open.
  """

  use Supervisor

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Gemini.{Auth, Environment, Feed, Ledger}

  @doc """
  Starts this venue's tree: the rate limiter, then the feed.

  `opts` are the ones `DpExchange.Gemini.child_spec/1` takes (`:environment`, `:name`,
  `:feed`, `:limiter`, `:channels`, `:max_queue_len`, `:ssl_options`, ...) and pass straight
  through to `DpExchange.Gemini.Feed`. A `:credentials` entry is wrapped so a crash report
  cannot print it (`DpExchange.Gemini.Credentials`).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    # Idempotent with the wrap `DpExchange.Gemini.child_spec/1` already did. A caller that
    # reaches here directly (`DpExchange.Gemini.start_link/1`) would otherwise leave raw
    # credentials in the supervisor's init argument and in its child specs, both printed by
    # `:sys.get_status/1` and any crash report.
    opts = DpExchange.Gemini.Credentials.wrap_opt(opts)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(opts))
  end

  @doc """
  This tree's registered name, environment-derived like its children.

  Every default name in this module varies by environment so that **production and demo
  can run side by side without naming anything** — which is the case a consumer actually
  has: live trading against production while strategies are tested against demo, in the
  same node, at the same time.

  With one shared set of defaults the second tree simply fails to start.
  """
  @spec supervisor_name(keyword()) :: atom()
  def supervisor_name(opts) do
    Keyword.get_lazy(opts, :name, fn ->
      case Environment.resolve(opts) do
        :production -> __MODULE__
        :sandbox -> DpExchange.Gemini.SandboxSupervisor
      end
    end)
  end

  @impl true
  def init(opts) do
    # Established here, once, before anything can ask for a nonce. See
    # `Auth.ensure_counter/0` for the race this closes — a lazily-initialised counter can
    # be replaced mid-flight, which restarts the sequence and hands two processes the same
    # nonce.
    Auth.ensure_counter()

    ledger = ledger_name(opts)

    # Both children take their names from `opts`, so a consumer running two of this venue
    # — two credentials, two scopes — keeps them apart.
    feed_opts = opts |> Keyword.put(:name, feed_name(opts)) |> Keyword.put(:ledger, ledger)

    children =
      [
        ledger && {Ledger, name: ledger},
        {DefaultRateLimiter, name: limiter_name(opts), limits: limits()},
        {Feed, feed_opts}
      ]
      |> Enum.filter(& &1)

    # `:rest_for_one`, in the order ledger, limiter, feed. A feed that crashes restarts alone,
    # and finds its subscribers and wanted symbols in the ledger (`DpExchange.Gemini.Ledger`);
    # the limiter is not reset by it, so budget the venue has already been spent is not handed
    # back. A limiter crash restarts the feed after it (which restores from the ledger), and
    # a ledger crash restarts both, because the feed would otherwise write to nothing.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The name of this tree's ledger (`DpExchange.Gemini.Ledger`), derived from its feed's name,
  or `nil` when the feed is addressed by a name that is not an atom.
  """
  @spec ledger_name(keyword()) :: atom() | nil
  def ledger_name(opts) do
    case feed_name(opts) do
      name when is_atom(name) -> Module.concat(name, "Ledger")
      _not_an_atom -> nil
    end
  end

  # A tree started with a non-default atom `:name` and no explicit `:feed` or `:limiter` names
  # its processes after itself, so two accounts in one environment need only distinct names.
  # The default names (no name, `nil`, the default supervisor names, anything that is not an
  # atom) are exactly what they always were, and an explicit option wins over this.
  defp derived_name(opts, suffix) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and name not in [nil, true, false] ->
        if name in [__MODULE__, DpExchange.Gemini.SandboxSupervisor],
          do: nil,
          else: Module.concat(name, suffix)

      _default_or_not_an_atom ->
        nil
    end
  end

  @doc """
  The limiter this venue meters against, for `Core.HttpClient`'s `:limiter` option.

  **Defaults differ per environment, and that is not tidiness.** Production and demo are
  two separate venues with two separate budgets. A shared default meant a call carrying
  `environment: :sandbox` but no `:limiter` metered against the *production* bucket — so a
  consumer testing strategies against demo would spend the budget its live trading needs,
  and find out when a real order got a 429.
  """
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts) do
    Keyword.get_lazy(opts, :limiter, fn ->
      derived_name(opts, "RateLimiter") || environment_limiter(opts)
    end)
  end

  @doc """
  This venue's feed process.

  Also environment-derived, for a second reason: running production and demo side by side
  is a first-class case, and with one shared default the second tree fails to start on a
  name collision. Deriving them means the common case — live trading in one tree,
  strategy testing against demo in another — works without naming anything.
  """
  @spec feed_name(keyword()) :: GenServer.server()
  def feed_name(opts) do
    Keyword.get_lazy(opts, :feed, fn ->
      derived_name(opts, "Feed") || environment_feed(opts)
    end)
  end

  defp environment_feed(opts) do
    case Environment.resolve(opts) do
      :production -> Feed
      :sandbox -> DpExchange.Gemini.SandboxFeed
    end
  end

  defp environment_limiter(opts) do
    case Environment.resolve(opts) do
      :production -> DpExchange.Gemini.RateLimiter
      :sandbox -> DpExchange.Gemini.SandboxRateLimiter
    end
  end

  # Straight from the declaration. If a ceiling changes, it changes in one place.
  defp limits do
    caps = DpExchange.Gemini.capabilities()

    %{
      gemini: to_limit(caps.public_ceiling),
      gemini_private: to_limit(caps.authenticated_ceiling),
      default: to_limit(caps.public_ceiling)
    }
  end

  # `burst` comes from the venue's published burst depth, not from the limit. Every other
  # venue in this family has had to guess it.
  defp to_limit(%{limit: limit, per_ms: per_ms, burst: burst}),
    do: %{limit: limit, per_ms: per_ms, burst: burst}
end
