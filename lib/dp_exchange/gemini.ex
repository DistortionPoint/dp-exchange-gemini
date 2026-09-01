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
    # Core 0.1.16 widened the facade; these are declared and not yet implemented, and each
    # is a Phase 3–13 item. **Gemini publishes most of them** — staking, positions,
    # funding, conversions, admin — so `:unsupported` here is a statement about this
    # package, not about the venue. That distinction is the one Phase 1 had to correct on
    # another venue, and it is stated here so it is not made again.
    {:get_positions, 1},
    {:get_funding, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3},
    {:get_conversion, 2},
    {:list_portfolios, 1},
    # Gemini lists no options at all, so these are the venue's absence rather than this
    # package's backlog.
    {:get_option_chain, 2},
    {:get_option_expirations, 2},
    {:get_option_greeks, 2},
    {:list_watchlists, 1},
    {:get_watchlist, 2},
    {:create_watchlist, 3},
    {:update_watchlist, 2},
    {:delete_watchlist, 2},
    {:get_financials, 3},
    {:get_corporate_events, 1},
    {:get_filings, 2},
    {:get_news, 1},
    {:get_screener, 2},
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    # **`replace_order/4` has no endpoint here — checked against the venue's published
    # specification on 2026-09-01, not assumed.** A caller cancels and re-places, which is
    # NOT equivalent: it opens a window in which no order is live.
    #
    # **`preview_order/3` is narrower than "no endpoint at all", which this said before.**
    # Gemini publishes `POST /v1/margin/order/preview` — a *margin impact* preview, giving
    # pre- and post-order risk statistics for a hypothetical spot order. That is not what
    # `preview_order/3` asks, which is what the order would cost, and answering the cost
    # question with margin statistics is precisely the nearby substitute §0 refuses. It is
    # a real endpoint with a real capability and it is scheduled on its own (Phase 11 of
    # the coverage plan), not folded into this one.
    #
    # `preview_replace/4` follows `replace_order/4`: there is nothing to preview when
    # there is nothing to amend.
    {:preview_order, 3},
    {:preview_replace, 4},
    {:replace_order, 4},
    # **The venue carries no positions to close.** Gemini's perpetuals surface is separate
    # and this package does not reach it; on spot there is no position, only a balance.
    {:close_position, 3},
    # **This venue runs no auctions and publishes no footprints.** A crypto book trades
    # continuously — there is no opening or closing auction to have an imbalance in — and
    # the venue publishes no volume-at-price split. Not "unimplemented": there is nothing
    # to implement.
    {:get_auction_imbalance, 2},
    {:get_volume_profile, 3},
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
      # `bookTicker` delivers top-of-book; a frame carrying a last trade also delivers a
      # quote. Two kinds from one channel, and each says which it is.
      streamable: [:quotes, :top_of_book],
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
  def get_top_of_book(symbol, opts \\ []), do: Rest.get_top_of_book(symbol, with_limiter(opts))

  @impl true
  def get_order_book(symbol, opts \\ []), do: Rest.get_order_book(symbol, with_limiter(opts))

  @impl true
  def get_market_overview(opts \\ []), do: Rest.get_market_overview(with_limiter(opts))

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  # --- account and trading -----------------------------------------------
  #
  # Credentials are arguments, used for one request and not kept. The host obtains them
  # and chooses the scheme; `:auth_scheme` names it, and when absent it follows what the
  # host supplied — never a guess between two, which the venue punishes with
  # `AmbiguousAuthentication`.

  @impl true
  def get_balances(credentials, opts),
    do: Private.get_balances(credentials, with_limiter(opts))

  @doc """
  Recent public trades — the tape.

  See `DpExchange.Gemini.Rest.get_trades/2`, including why `type` is the taker's side and
  why broken trades are excluded unless asked for.
  """
  @impl true
  def get_trades(symbol, opts \\ []), do: Rest.get_trades(symbol, with_limiter(opts))

  @doc """
  A foreign-exchange reference rate for `pair` at `at`.

  See `DpExchange.Gemini.Rest.get_fx_rate/3` — including why this is not a rate the venue
  trades at, and why the source is carried separately from the provider.
  """
  @impl true
  def get_fx_rate(pair, at, opts \\ []), do: Rest.get_fx_rate(pair, at, with_limiter(opts))

  @doc """
  The networks an asset moves over, or the assets a network carries.

  See `DpExchange.Gemini.Private.list_networks/2` — in particular why the network→assets
  direction is scoped to the credential and an empty answer does not describe the network.
  """
  @impl true
  def list_networks(asset, opts \\ []), do: Private.list_networks(asset, with_limiter(opts))

  @doc """
  Symbols currently carrying a promotional fee.

  See `DpExchange.Gemini.Rest.list_fee_promos/1` — not `get_fees/2`, which is the schedule
  applying to a credential.
  """
  @impl true
  def list_fee_promos(opts \\ []), do: Rest.list_fee_promos(with_limiter(opts))

  @doc """
  A fresh deposit address for `asset` on `network`.

  See `DpExchange.Gemini.Private.get_deposit_address/4` — in particular why `memo_required`
  comes back `nil` rather than `false`.
  """
  @impl true
  def get_deposit_address(asset, network, opts \\ []),
    do: Private.get_deposit_address(asset, network, credentials(opts), with_limiter(opts))

  @doc """
  The addresses this account may withdraw to on `opts[:network]`.

  See `DpExchange.Gemini.Private.list_approved_addresses/2` — an address on the list can
  still be time-locked.
  """
  @impl true
  def list_approved_addresses(opts \\ []),
    do: Private.list_approved_addresses(credentials(opts), with_limiter(opts))

  @doc """
  What the venue would charge to withdraw. Requires `opts[:address]`.

  Moves no funds. See `DpExchange.Gemini.Private.estimate_withdrawal_fee/5`.
  """
  @impl true
  def estimate_withdrawal_fee(asset, network, amount, opts \\ []),
    do:
      Private.estimate_withdrawal_fee(
        asset,
        network,
        amount,
        credentials(opts),
        with_limiter(opts)
      )

  @doc """
  **Moves funds.** Withdraws `amount` of `asset` over `network` to `address`.

  See `DpExchange.Gemini.Private.withdraw/6` — in particular the idempotency key this
  always sends, and the memo requirement this package cannot check for you.
  """
  @impl true
  def withdraw(asset, network, amount, address, opts \\ []),
    do: Private.withdraw(asset, network, amount, address, credentials(opts), with_limiter(opts))

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

  @doc """
  **Not supported.** Gemini publishes no order-preview endpoint.

  Declared through `supports_order_preview: false`, so a consumer routes around it rather
  than discovering the refusal at call time.
  """
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @doc """
  **Not supported.** Gemini has no atomic replace; a caller cancels and re-places.

  That is not equivalent — it opens a window in which no order is live — which is why
  `supports_order_replace: false` is a claim about **risk** rather than convenience.
  """
  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(credentials, order_id, opts),
    do: Private.cancel_order(credentials, order_id, with_limiter(opts))

  @doc """
  Cancels open orders in bulk. `opts[:scope]` is required — `:session` or `:account`.

  See `DpExchange.Gemini.Private.cancel_all_orders/2`, including why there is no default.
  """
  @impl true
  def cancel_all_orders(credentials, opts),
    do: Private.cancel_all_orders(credentials, with_limiter(opts))

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

  # **These callbacks take no credentials argument**, so the credential arrives in `opts`.
  # `%{}` rather than `nil` when absent: `Auth` pattern-matches on the key shape and a nil
  # produces a match error where an empty map produces the venue's own refusal, which is
  # the answer a caller can act on.
  defp credentials(opts), do: Keyword.get(opts, :credentials, %{})

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. Gemini
  # publishes most of what follows — staking, positions, funding, conversions, admin — and
  # each is a Phase 3–13 item in the coverage plan.
  #
  # They answer `{:error, :not_supported}` and are declared `:unsupported` in
  # `capabilities/0`, so a consumer routing on the declaration is told the truth. **The
  # declaration is what a caller reads; a stub that claimed otherwise would be the lie.**
  # Conformance assertion 12 checks the two agree in both directions, which is what stops
  # one being updated without the other.

  @impl true
  def get_positions(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts \\ []), do: Venue.not_supported()

  @doc """
  Quotes a conversion — Gemini's Instant quote. See
  `DpExchange.Gemini.Private.quote_conversion/4`, including when it refuses to guess the
  direction.
  """
  @impl true
  def quote_conversion(from, to, amount, opts \\ []),
    do: Private.quote_conversion(from, to, amount, with_limiter(opts))

  @doc "Commits a quoted conversion by its `quoteId`."
  @impl true
  def commit_conversion(id, opts \\ []), do: Private.commit_conversion(id, with_limiter(opts))

  @doc """
  Converts in one call — the venue's wrap endpoint.

  **Not a shorthand for `quote_conversion/4` then `commit_conversion/2`**: there is no rate
  held, and the caller learns the price from the result.
  """
  @impl true
  def convert(from, to, amount, opts \\ []),
    do: Private.convert(from, to, amount, with_limiter(opts))

  @doc "The account's own traded volume, one row per symbol per day."
  @impl true
  def get_trade_volume(credentials, opts),
    do: Private.get_trade_volume(credentials, with_limiter(opts))

  # **No quote-status endpoint.** The venue quotes and executes; it does not answer "what
  # became of quote N". A caller that lost a quote re-quotes.
  @impl true
  def get_conversion(_id, _opts \\ []), do: Venue.not_supported()
  @impl true
  def list_portfolios(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: Venue.not_supported()

  @impl true
  def create_account(_opts \\ []), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_roles(_opts \\ []), do: Venue.not_supported()
end
