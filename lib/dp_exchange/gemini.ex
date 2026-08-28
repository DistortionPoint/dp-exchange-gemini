defmodule DpExchange.Gemini do
  @moduledoc """
  Gemini, behind the DpExchange facade.

  > #### ⚠️ EXPERIMENTAL {: .warning}
  >
  > This package has not run in production. While it is `0.x` the API may change without
  > a major version — pin all three segments. **Maturity is declared per endpoint**
  > through `capabilities/0`; do not read this banner as your check.

  **This module is the entire public API of this package.** Transport, signing, session
  handling and supervision are internal, and there is nothing here that returns them.

  ## What is specific to Gemini, and what a caller can therefore rely on

  **Seven candle widths, and the venue's own documentation names three of them wrong.**
  The accepted set is `1m 5m 15m 30m 1h 6h 1d` in canonical form. Gemini's documentation
  lists values that its API rejects; this package sends what the venue accepts, measured.
  Asking for a width Gemini does not serve — `2h`, `4h`, `12h` — is an **error**, never
  the nearest one.

  **The candle window is fixed and unbounded requests are refused.** Gemini ignores
  `start`, `end` and `limit` entirely and returns a fixed window per width, from 1 day of
  one-minute bars to a year of daily ones. This package filters to your range, and refuses
  with `{:error, {:range_unavailable, …}}` when your range starts before the window can
  reach — rather than handing back a shorter period that reads as a complete answer.

  **Quote timestamps come from the venue's clock, or the call fails.** Neither Gemini
  ticker publishes a quote timestamp — `/v1/pubticker`'s only timestamp stamps its
  24-hour volume window, about a minute stale. This package uses the venue's HTTP `Date`
  header and returns `{:error, :missing_venue_timestamp}` when it is absent. It never
  substitutes the local clock.

  **Gemini publishes no rate-limit headers.** Measured 2026-08-28: a response carries
  `date`, `x-request-id` and `x-envoy-upstream-service-time`, and nothing else. It does
  publish its **limits**, in prose, which is better — and `capabilities/0` carries all
  three GCRA parameters from the venue's own page rather than from a guess.

  ## The demo environment is first-class here

  Gemini runs a **full exchange with test funds** — its own words — where automated bots
  simulate order-book activity and new accounts are credited $100,000 USD, 1,000 BTC and
  20,000 each of ETH, BCH, ZEC and LTC. Point this package at it with one option:

      children = [{DpExchange.Gemini, environment: :sandbox}]

      {:ok, quote} = DpExchange.Gemini.get_price("BTC-USD", environment: :sandbox)

  Both REST and the WebSocket follow the setting. `:production` is the default, and
  deliberately so: a wrong default fails in only one direction. Meaning demo and getting
  production sends a real order to a real exchange; meaning production and getting demo
  gives obviously-wrong prices — the demo book is frequently **crossed**, and a frame
  captured 2026-08-28 carried a bid of `68169.88` against an ask of `64886.32`.

  Selecting it once for a whole process tree, rather than per call, goes through
  `DpExchange.Core.Config` — which resolves per **process**, so one async test can point at
  demo without redirecting every test running beside it.

  ## You authenticate; this package signs

  Account and trading are implemented, and **credentials arrive as arguments** — used to
  sign that one request and not kept:

      {:ok, balances} = DpExchange.Gemini.get_balances(credentials, [])
      {:ok, order} = DpExchange.Gemini.place_order(credentials, request, [])

  What stays yours is credential **storage** and the **choice of scheme**. Gemini offers an
  API key pair and a full OAuth 2.0 authorization-code flow — app registration, a
  permanent client type, redirecting users to approve scopes, PKCE, and refreshing a
  24-hour token — and which one an application uses is a decision about its users and its
  deployment. Name it with `auth_scheme: :api_key | :oauth`; with it absent, whichever you
  actually supplied is used. Credentials carrying *both* are refused rather than resolved,
  because sending both header families is `AmbiguousAuthentication` at the venue.

  This package never reads a credential from the environment or a vault.

  ## Gemini serves no market orders, and this package will not invent one

  `capabilities/0` declares `supported_order_types: [:limit, :stop_limit]`. The venue's own
  reasoning: market orders "provide you with no price protection". Its documented
  workaround is an immediate-or-cancel order "coupled with an aggressive limit price" —
  and **that price is not one a package may choose for you.** How aggressive is a question
  only the caller can answer, and the answer is money.

  So `order_type: :market` is `{:error, {:unsupported_order_type, :market}}`. Ask for the
  behaviour explicitly, with your own number:

      %{order_type: :limit, time_in_force: :ioc, price: my_price, …}

  **Your API key's nonce mode is also something only you know.** Gemini provisions keys in
  either time-based or incremental mode, and the two need differently-shaped nonces —
  seconds versus a strictly increasing value, with no single value satisfying both. The
  default is `:time_based`, the venue's own recommendation; pass
  `nonce_mode: :incremental` if that is how your key was made. A mismatch fails loudly on
  the first request.

  ## Supervision

  Add it to your own tree. Nothing starts on load — a consumer that has not asked for
  Gemini must not find a socket open.

      children = [{DpExchange.Gemini, []}]

      {:ok, quote} = DpExchange.Gemini.get_price("BTC-USD", [])
      :ok = DpExchange.Gemini.subscribe(["BTC-USD"], to: self())
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Gemini.{Feed, Private, Rest, SymbolFormat}

  # Account and trading ARE implemented: credentials arrive as function arguments and are
  # used to sign that one request (§6.0, invariant #2). Credential *storage* is the host's
  # and never enters this package; credential *use* — signing, session refresh, token
  # rotation — is venue strategy and belongs here.
  #
  # Only two things are genuinely unsupported, and neither is about authentication:
  @unsupported [
    # 346 symbols, and the venue offers no bulk detail endpoint — one request per symbol
    # is not a listing, it is a rate-limit incident. `get_symbols/1` gives the catalogue
    # and `quantization/1` gives one symbol's detail on demand.
    {:list_instruments, 1},
    # The venue publishes no rate-limit headers at all — measured, not assumed. Returning
    # a constant that never moves as budget is spent is worse than refusing.
    {:get_rate_limit_status, 2}
  ]

  # --- lifecycle ---------------------------------------------------------

  @impl true
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def start_link(opts), do: DpExchange.Gemini.Supervisor.start_link(opts)

  # --- declaration -------------------------------------------------------

  @impl true
  def provider_name, do: "Gemini"

  @impl true
  def runtime_id, do: :gemini

  @impl true
  def asset_classes, do: [:crypto]

  @impl true
  def capabilities do
    Capabilities.new(
      endpoints: endpoint_maturities(),
      supported_quotes: SymbolFormat.quotes(),
      supported_instrument_types: [:spot],
      supports_short_selling: false,
      streamable: [:quotes],
      historical_timeframes: Rest.timeframes(),

      # **`:market` is absent, and that is the declaration doing its job.** The venue
      # serves no market orders — "they provide you with no price protection", in its own
      # words — and its documented workaround is an IOC order "coupled with an aggressive
      # limit price". A package cannot pick that price: the caller never said how
      # aggressive, and the difference is money. So a caller reads this list and asks for
      # what it wants explicitly, rather than a package inventing a price on its behalf.
      #
      # `:stop` is absent too: Gemini serves stop-*limit* only, so a plain stop would have
      # to become a stop-limit at a price we would be choosing. Same refusal, same reason.
      #
      # `:post_only`, `:ioc` and `:fok` appear here rather than under time-in-force
      # because that is how **the contract** models them. Gemini models them differently —
      # as execution *options* on a limit order — and this package translates. The mapping
      # is written down in `Private` rather than left for a reader to infer from behaviour.
      supported_order_types: [:limit, :stop_limit, :post_only, :ioc, :fok],

      # The contract's time-in-force vocabulary is `[:gtc, :ioc, :fok, :gtd, :day]`; Gemini
      # serves the first three. It has no good-til-date and no day order — an order rests
      # until it fills or is cancelled.
      supported_time_in_force: [:gtc, :ioc, :fok],

      # `nil`, not a number, and the distinction is load-bearing: the endpoint accepts no
      # bounds and no limit, so there is no page to size and nothing to paginate. One
      # call is the whole history the venue offers at that width.
      max_candles_per_request: nil,
      reports_trade_volume: true,
      catalog_size: :small,

      # Credentials buy nothing for market data here — every endpoint this package
      # implements is public, and an authenticated call to them returns the same thing.
      credential_benefit: :no_difference,

      # From the venue's own rate-limit page, in words, including the burst depth. This
      # is the first venue in the family to publish all three, and `:burst` exists in
      # `Core.Capabilities` because this declaration needed it.
      public_ceiling: %{limit: 120, per_ms: 60_000, burst: 5},
      authenticated_ceiling: %{limit: 600, per_ms: 60_000, burst: 5},
      measured_at: ~D[2026-08-28],
      measured_against:
        "timeframes, the fixed candle windows (all seven bar counts), symbol catalogue, " <>
          "book/ticker/pricefeed shapes and the absence of rate-limit headers measured " <>
          "live against api.gemini.com; the bookTicker stream measured live against " <>
          "ws.gemini.com; CEILINGS taken from developer.gemini.com/rate-limit as " <>
          "published prose and NOT probed — probing a limit means deliberately " <>
          "exceeding a third party's"
    )
  end

  # Everything implemented is `:experimental` — the honest state for code no one has run
  # in production. The rest are `:unsupported` and return the atom, which the conformance
  # suite checks in both directions.
  defp endpoint_maturities do
    active =
      for {name, arity} <- Venue.behaviour_info(:callbacks),
          {name, arity} not in @unsupported,
          into: %{},
          do: {{name, arity}, :experimental}

    Enum.reduce(@unsupported, active, &Map.put(&2, &1, :unsupported))
  end

  # --- market data -------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []), do: Rest.get_price(symbol, with_limiter(opts))

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []),
    do: Rest.get_historical_prices(symbol, timeframe, range, with_limiter(opts))

  @impl true
  def get_symbols(opts \\ []), do: Rest.get_symbols(with_limiter(opts))

  @impl true
  def get_order_book(symbol, opts \\ []), do: Rest.get_order_book(symbol, with_limiter(opts))

  @impl true
  def get_market_overview(opts \\ []), do: Rest.get_market_overview(with_limiter(opts))

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  # --- account and trading -----------------------------------------------
  #
  # Credentials are arguments, used for one request and not kept. The host obtains them
  # and chooses the scheme; `:auth_scheme` names it, and when absent it follows what the
  # host supplied — never a guess between two, which the venue punishes with
  # `AmbiguousAuthentication`.

  @impl true
  def get_balances(credentials, opts),
    do: Private.get_balances(credentials, with_limiter(opts))

  @impl true
  def get_accounts(credentials, opts),
    do: Private.get_accounts(credentials, with_limiter(opts))

  @impl true
  def get_fees(credentials, opts), do: Private.get_fees(credentials, with_limiter(opts))

  @impl true
  def get_transfers(credentials, opts),
    do: Private.get_transfers(credentials, with_limiter(opts))

  @impl true
  def place_order(credentials, request, opts),
    do: Private.place_order(credentials, request, with_limiter(opts))

  @impl true
  def cancel_order(credentials, order_id, opts),
    do: Private.cancel_order(credentials, order_id, with_limiter(opts))

  @impl true
  def get_order(credentials, order_id, opts),
    do: Private.get_order(credentials, order_id, with_limiter(opts))

  @impl true
  def get_orders(credentials, opts),
    do: Private.get_orders(credentials, with_limiter(opts))

  @impl true
  def get_trade_history(credentials, opts),
    do: Private.get_trade_history(credentials, with_limiter(opts))

  # --- streaming ---------------------------------------------------------

  @impl true
  def subscribe(symbols, opts \\ []), do: Feed.subscribe(feed(opts), symbols, opts)

  @impl true
  def unsubscribe(symbols, opts \\ []), do: Feed.unsubscribe(feed(opts), symbols)

  @impl true
  def update_symbols(symbols, opts \\ []), do: Feed.update_symbols(feed(opts), symbols)

  # NOT declarable `:unsupported`: `coverage/1` returns a map, so it has no way to answer
  # `{:error, :not_supported}`. It always answers, and an empty map is the honest answer
  # for a venue delivering nothing.
  @impl true
  def coverage(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.coverage(feed), else: %{}
  end

  @impl true
  def subscribe_notices(opts \\ []), do: Feed.subscribe_notices(feed(opts), opts)

  defp feed(opts), do: Keyword.get(opts, :feed, Feed)

  defp alive?(name) when is_atom(name), do: is_pid(GenServer.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  # --- health ------------------------------------------------------------

  @impl true
  def test_connection(credentials, opts),
    do: Private.test_connection(credentials, with_limiter(opts))

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  # Crypto, 24/7. Per-symbol trading status is a different question and lives in
  # `quantization/1`, which reports the venue's own `status` for that pair.
  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def quantization(symbol), do: Rest.quantization(symbol, with_limiter([]))

  # Meters against the limiter this venue's own supervisor starts, unless the caller
  # names another. `Core.HttpClient` fails closed with no limiter running, so a package
  # that left this unset would answer "Rate limiter unavailable" to every call.
  defp with_limiter(opts) do
    Keyword.put_new(opts, :limiter, DpExchange.Gemini.Supervisor.limiter_name(opts))
  end
end
