defmodule DpExchange.Gemini.Fake do
  @moduledoc """
  An in-process Gemini, for a consumer's tier-1 tests and for the conformance suite's
  active-endpoint assertion.

  **It is not a mock.** Nothing is stubbed, no expectation is recorded, and no call is
  verified. It is a real implementation of `DpExchange.Core.Venue` that answers from
  memory instead of from the network, and it runs the *same* conformance suite as the
  real adapter.

  ## Two rules

  **Less capable is allowed. Differently capable is not.** Where this cannot answer, it
  returns an error. It never returns an empty success for something unsupported — a
  plausible wrong answer is worse than a failure, because only one of the two gets
  noticed.

  **It never rewrites a value the caller supplied**, and it never stamps the current
  clock. `@at` below is fixed, because a fake that stamps `utc_now/0` cannot be used to
  test anything about freshness and is itself the substitution this family refuses.

  ## It models Gemini's refusals, and its two shapes of refusal differ

  A fake where everything works proves half the contract. This one refuses:

    * a symbol it does not carry, with **the real reason for that endpoint** — Gemini
      does not refuse a bad symbol the same way everywhere, and neither does this fake:
      `:invalid_symbol` where `Rest`'s own tests pin a JSON `InvalidSymbol` body
      (`get_order_book/2`, `quantization/1`, `place_order/3`), `{:unknown_reason, text}`
      where the venue answers with plain text instead (`get_price/2`, `get_top_of_book/2`
      — measured live, `/v1/pubticker` — and `get_historical_prices/4` — measured live,
      `/v2/candles`), or the venue's own unrecognised JSON reason (`get_trades/2`,
      measured live as `BadRequest`). A single invented `:not_listed` used to stand in
      for all of these, which is precisely the divergence the 2026-09-06 real/fake
      parity sweep exists to catch: a consumer's test pattern-matching the real shape
      passed here for the wrong reason;
    * a timeframe Gemini does not serve, including `2h`, `4h` and `12h`, which the shared
      vocabulary models and this venue does not;
    * a range reaching **before the venue's fixed window**, with `{:range_unavailable,
      …}` rather than a short answer — because the real endpoint ignores bounds entirely
      and a truncated result reads as a complete one.

  That last one is this venue's distinctive failure mode, and a consumer that has not
  handled it will find out here rather than in production.

  ## Failure injection and anonymous mode

  Every function below that has a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is.
  `authenticated/2` also checks `FakeInjection.credentials_bypassed?/1` before running the
  same scheme-resolution `Private`'s `Auth.headers/5` runs — see that function's own
  comment for the shapes it returns. Neither changes anything for a test that never calls
  `FakeInjection` — see that module for the full contract.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired: each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express — see `FakeInjection`'s own moduledoc.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{Capabilities, Config, FakeInjection, Types, Venue}
  alias DpExchange.Gemini.{Feed, Private, Rest, SymbolFormat}

  @symbols ~w(BTC-USD BTC-GUSD ETH-USD SOL-RLUSD)

  @price %{
    "BTC-USD" => "77845.79",
    "BTC-GUSD" => "77851.02",
    "ETH-USD" => "2951.40",
    "SOL-RLUSD" => "121.66"
  }

  # Fixed, not `utc_now/0`.
  @at ~U[2026-08-28 12:00:00Z]

  # `subscribe/2`'s `:channels` default — matches `DpExchange.Gemini.Feed`'s own
  # `@default_channels` exactly, so a caller of neither sees any change from before
  # `:trades` existed as a kind.
  @default_channels [:quotes, :top_of_book]

  # Process-dictionary key for which symbols were subscribed WITH `:trades` in their
  # `:channels` — kept apart from `__MODULE__` (which `subscribed/0` reads) because a
  # symbol can be subscribed for quotes without trades, or vice versa across two separate
  # `subscribe/2` calls, and the two facts must not collapse into one set the way a single
  # boolean would.
  @trades_key {__MODULE__, :trades}
  @top_of_book_key {__MODULE__, :top_of_book}

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def provider_name, do: DpExchange.Gemini.provider_name()

  @impl true
  def runtime_id, do: DpExchange.Gemini.runtime_id()

  @impl true
  def asset_classes, do: DpExchange.Gemini.asset_classes()

  # The real declaration, deliberately. A fake declaring different capabilities from the
  # venue it stands in for is a fake a consumer cannot use to test capability branching.
  @impl true
  def capabilities, do: DpExchange.Gemini.capabilities()

  @impl true
  def get_price(symbol, _opts \\ []) do
    symbol = canonical(symbol)
    with_injection(symbol, fn -> fake_quote(symbol) end)
  end

  # Outside `with_injection/2`, so `subscribe/2` builds its push without consuming a failure
  # a test queued for `get_price/2` — the stream never touches the REST endpoint it would
  # otherwise have stood in for.
  defp fake_quote(symbol) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        {:ok,
         %Types.Quote{
           symbol: symbol,
           price: Decimal.new(price),
           volume: Decimal.new("183.72"),
           # As the real `get_price/2`: the ticker's 24-hour volume.
           volume_window: :rolling_24h,
           venue_time: @at,
           observed_at: @at,
           provider: :gemini
         }}

      :error ->
        not_listed(symbol)
    end
  end

  @impl true
  def get_top_of_book(symbol, _opts \\ []) do
    symbol = canonical(symbol)
    with_injection(symbol, fn -> fake_top_of_book(symbol) end)
  end

  defp fake_top_of_book(symbol) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        {:ok,
         %Types.TopOfBook{
           symbol: symbol,
           # A spread around the fake's price. The bid is deliberately *not* equal to the
           # price: a test that passes only when they coincide is not testing the split
           # this type exists to enforce.
           bid: Decimal.sub(Decimal.new(price), Decimal.new("0.31")),
           ask: Decimal.add(Decimal.new(price), Decimal.new("0.69")),
           bid_size: nil,
           ask_size: nil,
           venue_time: @at,
           observed_at: @at,
           provider: :gemini
         }}

      :error ->
        not_listed(symbol)
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], _opts \\ []) do
    symbol = canonical(symbol)

    with_injection(symbol, fn ->
      # **The width and the range are checked by the real function, and before the symbol.**
      # `Rest.get_historical_prices/4` refuses an unsupported width (`2h`, `4h` and `12h` are
      # modelled by the vocabulary and not served), a bound that is not a `DateTime`, and a
      # start before the venue's fixed window, all before it makes a request, so the venue
      # never gets the chance to refuse the symbol. This checked the symbol first, so a call
      # wrong in both ways answered with the venue's refusal where the real package answers
      # with its own, and it carried its own copy of the window arithmetic, anchored a bar
      # away from the real boundary and without the `:invalid_range` refusal.
      with :ok <- Rest.validate_history(timeframe, range) do
        if symbol in @symbols do
          {:ok, [candle(symbol, timeframe)]}
        else
          # Measured live 2026-09-06: `/v2/candles/{symbol}/{width}` refuses an unknown
          # symbol with a plain-text 400, `Supplied value '#{symbol}' is not a valid
          # symbol` — see `Rest.get_body/2`'s own comment. `:not_listed` never appeared
          # anywhere in the real vocabulary; found in the parity sweep.
          {:refused, {:unknown_reason, "Supplied value '#{symbol}' is not a valid symbol"}}
        end
      end
    end)
  end

  @impl true
  def get_symbols(_opts \\ []) do
    with_injection(fn -> {:ok, @symbols} end)
  end

  @impl true
  def get_order_book(symbol, _opts \\ []) do
    symbol = canonical(symbol)

    with_injection(symbol, fn ->
      case Map.fetch(@price, symbol) do
        {:ok, price} ->
          bid = Decimal.new(price)

          # **Three levels a side, and the depth is load-bearing.** This fake returned one
          # level each way, and `Core.AdapterContract`'s assertion 25 — the one that exists
          # to check that bids come back highest-first and asks lowest-first — ran against
          # it, reached the behaviour, and passed. It could not have done anything else: a
          # list of one is sorted under every comparator, so there was no edit to this
          # function that could have made that assertion fail. Adding a second, deliberately
          # misordered level turned the suite red immediately (48 tests, 1 failure), which
          # is how the inertness was measured rather than argued.
          #
          # Core now refuses a book this thin, so this cannot silently go back to one level.
          # Keeping the ladder here as well, rather than relying only on that refusal, is
          # the point: the fixture is what gives the assertion something to be wrong about.
          {:ok,
           %Types.OrderBook{
             symbol: symbol,
             bids: [
               {bid, Decimal.new("0.0031")},
               {Decimal.sub(bid, Decimal.new("0.01")), Decimal.new("0.0140")},
               {Decimal.sub(bid, Decimal.new("0.02")), Decimal.new("0.2500")}
             ],
             asks: [
               {Decimal.add(bid, Decimal.new("0.01")), Decimal.new("0.0182")},
               {Decimal.add(bid, Decimal.new("0.02")), Decimal.new("0.0910")},
               {Decimal.add(bid, Decimal.new("0.03")), Decimal.new("0.3300")}
             ],
             # `nil`, not `@at` — `Rest.get_order_book/2` never has a real time to report
             # here: the venue's own schema marks the only field this endpoint carries a
             # "timestamp" — `OrderBookEntry.timestamp` — a dummy value, "DO NOT USE". A
             # fake reporting a real `venue_time` would be more capable than the endpoint
             # it fakes, which this family's parity rule ("less capable is allowed;
             # differently capable is not") refuses exactly as much as the reverse.
             venue_time: nil,
             observed_at: @at,
             provider: :gemini
           }}

        :error ->
          # `Rest.get_order_book/2`'s own test pins `/v1/book/{symbol}` to a JSON
          # `InvalidSymbol` refusal for an unlisted symbol, not the invented `:not_listed`
          # this used to answer — found in the parity sweep.
          {:refused, :invalid_symbol}
      end
    end)
  end

  @impl true
  def get_trades(symbol, opts \\ []) do
    symbol = canonical(symbol)

    with_injection(symbol, fn ->
      if symbol in @symbols do
        trades = [
          %Types.Trade{
            id: "5335307668",
            symbol: symbol,
            # The taker's side: a buyer lifted the offer.
            side: :buy,
            price: Decimal.new("3610.85"),
            quantity: Decimal.new("0.27413495"),
            timestamp: @at,
            broken: false,
            provider: :gemini
          },
          %Types.Trade{
            id: "5335307669",
            symbol: symbol,
            side: :sell,
            price: Decimal.new("9999.99"),
            quantity: Decimal.new("1"),
            timestamp: @at,
            # A busted print. The fake carries one so a consumer's suite exercises the
            # exclusion rather than assuming it.
            broken: true,
            provider: :gemini
          }
        ]

        if Keyword.get(opts, :include_broken, false) do
          {:ok, trades}
        else
          {:ok, Enum.reject(trades, & &1.broken)}
        end
      else
        # This used to answer unconditionally for ANY symbol — never refusing at all,
        # which is more capable than `Rest.get_trades/2` rather than less. Measured live
        # 2026-09-06: `GET /v1/trades/{symbol}` refuses an unlisted symbol with
        # `{"reason":"BadRequest",...}`, a reason outside `Rest`'s recognised vocabulary
        # and so `{:unknown_reason, ...}` there too. Found in the parity sweep.
        {:refused, {:unknown_reason, "BadRequest"}}
      end
    end)
  end

  @impl true
  def get_fx_rate(pair, at, opts \\ []) do
    with_injection(fn ->
      # The fourteen pairs the venue serves, refused by the real function and BEFORE the
      # credential: `Private.get_fx_rate/3` refuses an unsupported pair (its 404 reads the
      # same as one for a bad timestamp) without signing anything, so a call wrong in both
      # ways was answered `:missing_credentials` here and `:unsupported_fx_pair` there.
      #
      # Signed on the real venue (`Private.get_fx_rate/3`'s own doc — measured against
      # `rest.yaml:7836-7851`), so the fake requires a credential too, the same as
      # `list_networks/2` does for both of its directions: a fake that accepted `nil` here
      # would let a consumer's test pass while the real call was refused before it ever
      # signed a request.
      with :ok <- Private.validate_fx_instant(at),
           {:ok, native} <- Private.validate_fx_pair(pair),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.FxRate{
           pair: native,
           rate: Decimal.new("0.69"),
           as_of: at,
           # The institution that computed it — not the venue, which is `provider`.
           source: "bcb",
           benchmark: "Spot",
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def list_networks(asset, opts \\ []) do
    with_injection(fn ->
      case {asset, Keyword.get(opts, :network)} do
        {nil, nil} ->
          {:error, :asset_or_network_required}

        {nil, network} ->
          # Scoped to the credential on the real venue, so the fake requires one: an empty
          # answer means this account cannot move anything on that network, not that the
          # network carries nothing.
          with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            {:ok, [%{"network" => network, "assets" => ["USDC", "USDT"]}]}
          end

        {asset, _network} ->
          # **Signed too.** This answered the asset→networks direction with no credential,
          # calling it "the public direction". `Private.list_networks/2` has never had one:
          # `GET /v2/network/{token}` measured `401 MissingSecurityHeaders` unauthenticated
          # (see its own doc), so a consumer's tier-1 test passed here with no key where the
          # real call is refused before a request is made.
          with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            {:ok, [%{"asset" => asset, "networks" => ["ethereum", "solana"]}]}
          end
      end
    end)
  end

  @impl true
  def list_fee_promos(_opts \\ []) do
    with_injection(fn -> {:ok, [%{"symbol" => "btcusd"}]} end)
  end

  @impl true
  def get_market_overview(_opts \\ []) do
    with_injection(fn ->
      {:ok,
       Map.new(@symbols, fn symbol ->
         {symbol, %{price: Decimal.new(@price[symbol]), change_24h: Decimal.new("-0.0424")}}
       end)}
    end)
  end

  @impl true
  def quantization(symbol) do
    symbol = canonical(symbol)

    with_injection(symbol, fn ->
      case Map.fetch(@price, symbol) do
        {:ok, _price} ->
          {:ok,
           %{
             price_increment: Decimal.new("0.01"),
             quantity_increment: Decimal.new("0.00000001"),
             min_quantity: Decimal.new("0.00001"),
             status: "open"
           }}

        :error ->
          # Measured live 2026-09-06: `/v1/symbols/details/{symbol}` refuses an unlisted
          # symbol with `{"reason":"InvalidSymbol",...}` — the one case in this sweep
          # confirmed against the venue itself, not just against `Rest`'s own tests.
          {:refused, :invalid_symbol}
      end
    end)
  end

  # `Rest.list_instruments/1`'s shape: every listed symbol open, honouring `symbols:`, and
  # an unlisted one failing the whole call with the venue's own `InvalidSymbol` refusal
  # inside, as the real call does.
  @impl true
  def list_instruments(opts \\ []) do
    with_injection(fn ->
      # The real function's own reading of `:symbols`: canonical spellings, each once, and
      # a value that is not a list of strings refused rather than raised on.
      with {:ok, requested} <- Rest.requested_instrument_symbols(Keyword.get(opts, :symbols)) do
        symbols = requested || @symbols

        case Enum.find(symbols, &(&1 not in @symbols)) do
          nil ->
            {:ok, Enum.map(symbols, &fake_instrument/1)}

          unlisted ->
            {:error, {:instrument_detail_failed, unlisted, {:refused, :invalid_symbol}}}
        end
      end
    end)
  end

  defp fake_instrument(symbol) do
    [base, quote_asset] = String.split(symbol, "-")

    DpExchange.Core.Instrument.new(
      symbol: symbol,
      base: base,
      quote: quote_asset,
      instrument: :spot,
      status: :tradable
    )
  end

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  # --- account and trading, in memory -------------------------------------
  #
  # Credentials are an argument here exactly as in the real adapter. The fake checks that
  # something credential-shaped arrived and otherwise refuses — a fake that accepted `nil`
  # would let a consumer's test pass while the real call fails on a missing key.

  @impl true
  def get_balances(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok,
         [
           %Types.Balance{
             currency: "USD",
             balance: Decimal.new("100000.00"),
             available_balance: Decimal.new("99000.00"),
             hold: Decimal.new("1000.00"),
             timestamp: @at,
             provider: :gemini
           },
           %Types.Balance{
             currency: "BTC",
             balance: Decimal.new("1000.00000000"),
             available_balance: Decimal.new("1000.00000000"),
             hold: Decimal.new("0E-8"),
             timestamp: @at,
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def get_accounts(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, [%{"account" => "primary", "type" => "exchange"}]}
      end
    end)
  end

  @impl true
  def get_fees(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok, %{"api_maker_fee_bps" => 10, "api_taker_fee_bps" => 35}}
      end
    end)
  end

  @impl true
  def get_transfers(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts), do: {:ok, []}
    end)
  end

  @impl true
  def place_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The refusals matter more than the success. A fake where every order works proves
      # only that the happy path compiles. `Private.validate_order/1` is the SAME function
      # the real adapter validates against — the type and time in force (one "at most one
      # execution option" table, not a second copy, which is how this fake used to accept
      # `:stop_limit` with any `time_in_force` and `:post_only` with `:fok`), then the price,
      # then each of `:symbol`, `:quantity` and `:side` by name. The fake defaulted those
      # last three to "1" and `:buy`, so a consumer's suite passed an order the venue never
      # sees.
      #
      # **Before the credential, not after.** `Private.place_order/3` refuses a malformed
      # request before it signs anything, so a request wrong in both ways is
      # `{:error, {:missing_field, _}}` there. This answered `:missing_credentials`.
      with :ok <- Private.validate_order(request),
           :ok <- authenticated(credentials, opts),
           :ok <- listed(canonical(Map.get(request, :symbol))) do
        {:ok, order(request)}
      end
    end)
  end

  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def preview_replace(_credentials, _id, _changes, _opts \\ []), do: Venue.not_supported()

  @impl true
  def close_position(_credentials, _symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    with_injection(fn ->
      # The id is checked BEFORE the credential, as `Private.cancel_order/3` does, through
      # the same `Private.order_id_param/1`, so the fake cannot be the more permissive one.
      with {:ok, wire_id} <- Private.order_id_param(order_id),
           :ok <- authenticated(credentials, opts) do
        {:ok, %{order(%{}) | id: Integer.to_string(wire_id), status: :cancelled}}
      end
    end)
  end

  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    with_injection(fn ->
      with {:ok, wire_id} <- Private.order_id_param(order_id),
           :ok <- authenticated(credentials, opts) do
        {:ok, %{order(%{}) | id: Integer.to_string(wire_id)}}
      end
    end)
  end

  @impl true
  def get_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # Open and historical are two endpoints on this venue, not one with a filter, and the
      # fake says so rather than answering the same empty list to both.
      with :ok <- authenticated(credentials, opts) do
        if Keyword.get(opts, :history, false),
          do: {:ok, [%{order(%{}) | status: :filled}]},
          else: {:ok, []}
      end
    end)
  end

  @impl true
  def cancel_all_orders(credentials, opts \\ []) do
    with_injection(fn ->
      # The fake enforces the contract's rule, so a consumer's suite cannot go green on a
      # bulk cancel that never said which orders it meant. `Private.cancel_scope/1` is the
      # real function, and runs first as it does there: a call with no scope is
      # `:scope_required` whether or not it carries credentials, because nothing is signed
      # for it. This asked for the credential first.
      with {:ok, _path} <- Private.cancel_scope(Keyword.get(opts, :scope)),
           :ok <- authenticated(credentials, opts) do
        {:ok, %{cancelled: ["fake-gemini-order-1"], rejected: []}}
      end
    end)
  end

  @impl true
  def get_trade_history(credentials, opts) do
    with_injection(fn ->
      # `opts[:symbol]` is optional on the real endpoint — `MyTradesRequest`
      # (`rest.yaml:8294-8298`) names only `request` and `nonce` as required — so the fake
      # no longer refuses a call with none. This used to require one; a fake that refused
      # what the real venue accepts is differently capable, not less.
      with :ok <- authenticated(credentials, opts) do
        {:ok, []}
      end
    end)
  end

  # Mirrors `Private`'s `auth_scheme/2` + `Auth.headers/5` decision tree exactly — not
  # the cryptography, which the fake never does, but the SHAPE of what a caller with no
  # credentials, or the wrong ones, gets back. That tree found here used to be flattened
  # to one bare `{:refused, :missing_credentials}` for every case, which was wrong on two
  # axes at once against the real path's most common outcome: the wrong *kind*
  # (`:refused`, which the real adapter reserves for the venue's own 401/403 body, never
  # for a call this package refused to even sign and send) and the wrong *shape*
  # (`:missing_credentials` alone, dropping which scheme was missing it). Found in the
  # 2026-09-06 real/fake parity sweep — every one of `auth_test.exs`'s cases now has a
  # pinned equivalent against this fake in `fake_parity_test.exs`.
  defp authenticated(credentials, opts) do
    with :ok <- authenticated_group(credentials, opts),
         do: account_named(credentials, opts)
  end

  # For the calls that act on the key or the whole group (`create_account/1`, `get_roles/1`),
  # which a master key makes without naming an account; see `Private`'s `@group_level_paths`.
  defp authenticated_group(credentials, opts) do
    if FakeInjection.credentials_bypassed?(:gemini) do
      :ok
    else
      scheme = Config.opt(opts, :auth_scheme, resolve_scheme(credentials))
      authenticated_venue_faithful(scheme, credentials)
    end
  end

  # dp-exchange-core issue #38. A master-scoped key must name the subaccount on every
  # account-level call, and the venue answers `MissingAccounts` when it does not. A fake
  # credential declares itself master-scoped with `key_scope: :master` (the real package
  # ignores the field; the venue documents no way to read a key's scope from the key), and
  # then an account-level call without `opts[:account]` is refused with the exact shape the
  # real path returns, so a consumer's test catches the omission before production does.
  defp account_named(%{key_scope: :master}, opts) do
    case Keyword.get(opts, :account) do
      account when is_binary(account) and account != "" -> :ok
      _absent -> {:refused, {:unknown_reason, "MissingAccounts"}}
    end
  end

  defp account_named(_credentials, _opts), do: :ok

  # The same auto-detection `Private`'s private `auth_scheme/2` runs when the caller
  # named no scheme explicitly. Both fields present is the venue's own
  # `AmbiguousAuthentication` (400) waiting to happen, caught here before either header
  # family is built rather than sent and rejected.
  defp resolve_scheme(%{api_key: _key, access_token: _token}), do: :ambiguous
  defp resolve_scheme(%{api_key: _key}), do: :api_key
  defp resolve_scheme(%{access_token: _token}), do: :oauth
  defp resolve_scheme(_other), do: nil

  defp authenticated_venue_faithful(:api_key, %{api_key: _key, api_secret: _secret}), do: :ok
  defp authenticated_venue_faithful(:oauth, %{access_token: token}) when is_binary(token), do: :ok

  defp authenticated_venue_faithful(scheme, _credentials) when scheme in [:api_key, :oauth] do
    {:error, {:missing_credentials, scheme}}
  end

  # `nil` — nothing credential-shaped, and no scheme was named — is not an unsupported
  # SCHEME, it is an absent CREDENTIAL: there was never a scheme to be unsupported.
  # `Auth.headers/5` used to fall this through to its catch-all and answer
  # `{:error, {:unsupported_auth_scheme, nil}}`, mislabelling the one condition every
  # other venue in this family calls `{:error, {:missing_credentials, venue}}`. Fixed in
  # both places together 2026-09-07 — see `Auth.headers/5`'s own moduledoc for the
  # argument this mirrors.
  defp authenticated_venue_faithful(nil, _credentials) do
    {:error, {:missing_credentials, :gemini}}
  end

  # What remains is `:ambiguous` — both header families present, refused before either is
  # built — which really is a scheme this module declines to resolve, exactly as
  # `Auth.headers/5`'s own catch-all treats it.
  defp authenticated_venue_faithful(scheme, _credentials) do
    {:error, {:unsupported_auth_scheme, scheme}}
  end

  defp with_injection(symbol \\ nil, fun) do
    case FakeInjection.next_outcome(:gemini, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  # The staking callbacks carry no credentials argument; the fake finds them where the
  # facade does, so a consumer wiring them wrong fails here rather than in production.
  defp fake_credentials(opts), do: Keyword.get(opts, :credentials, %{})

  defp listed(symbol) do
    # `/v1/order/new` shares `Private`'s `refusal(body)` -> `Rest.refusal_reason/1`
    # vocabulary with every other private POST, and `InvalidSymbol` is the one entry in
    # that table that names a bad symbol rather than a credential problem.
    if symbol in @symbols, do: :ok, else: {:refused, :invalid_symbol}
  end

  # `/v1/pubticker/{symbol}` — the endpoint behind `get_price/2` and `get_top_of_book/2`
  # — 404s on an unlisted symbol with plain text, not JSON: `'<symbol>' does not have
  # available data yet`, measured live 2026-09-06 (`rest_test.exs`, "get_price refuses
  # on a 404, keeping the venue's own words"). `{:refused, :not_listed}` used to stand
  # in here — an atom absent from the venue's own vocabulary and from `Rest`'s — found
  # in the parity sweep.
  defp not_listed(symbol) do
    {:refused, {:unknown_reason, "'#{symbol}' does not have available data yet"}}
  end

  # The order the venue would describe back for `request`, with the type recovered the way
  # `Private.to_order/1` recovers it from the venue's own body: `maker_or_cancel` is
  # `:post_only`, and an `:ioc` or `:fok` time in force on a plain limit order is `:ioc` or
  # `:fok`. The request's own spelling used to be echoed, so `order_type: :maker_or_cancel`
  # came back as `:maker_or_cancel` — an atom no real order carries — and a limit order sent
  # with `time_in_force: :ioc` came back `:limit`, naming a different order from the one
  # the venue holds. `request` has passed `Private.validate_order/1` (or is `%{}`, whose
  # defaults are valid), so `order_wire/2` cannot refuse it here.
  defp order(request) do
    {:ok, {wire_type, options}} =
      Private.order_wire(
        Map.get(request, :order_type, :limit),
        Map.get(request, :time_in_force, :gtc)
      )

    %Types.Order{
      # Numeric, as the venue's are, so `Private.order_id_param/1` (which `get_order/3` and
      # `cancel_order/3` check through) accepts the id this fake issued itself. It was
      # `"fake-order-1"`, which those two refused: issue #5.
      id: "1",
      symbol: canonical(Map.get(request, :symbol, "BTC-USD")),
      side: Map.get(request, :side, :buy),
      order_type: order_type_of(wire_type, options),
      quantity: decimal(Map.get(request, :quantity, "1")),
      price: decimal(Map.get(request, :price, "1")),
      stop_price: optional_decimal(Map.get(request, :stop_price)),
      status: :open,
      filled_quantity: Decimal.new(0),
      created_at: @at,
      updated_at: @at,
      provider: :gemini
    }
  end

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value), do: value |> to_string() |> Decimal.new()

  # Streaming, in memory. The fake pushes immediately on subscribe, which is what the
  # real venue's first `@bookTicker` frame does from the caller's side — and the caller
  # cannot tell the difference, which is the property the facade exists to hold.
  #
  # `opts[:channels]` mirrors `DpExchange.Gemini.Feed`'s own `:channels` option — see its
  # moduledoc's "`channels:`" section — defaulting to the same `[:quotes, :top_of_book]`.
  # Unlike `Feed`, where it is a `start_link/1`-time choice for the whole connection, here
  # it is per `subscribe/2` call: this fake has no persistent connection to configure, so
  # the option is read where it is given. `:trades` in the list pushes a `Types.Trade` for
  # each valid symbol alongside the streamed `Quote`, consistent with the real decode
  # (`WsDecode.to_trade/2`) — a real `id`, a real `side`, `broken: false` because the
  # socket publishes no bust flag, and a non-nil `timestamp`, never the placeholders a
  # less careful fake would reach for.
  @impl true
  def subscribe(symbols, opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols),
         {:ok, _subscriber} <- Feed.valid_subscriber(Config.opt(opts, :to, self())) do
      do_subscribe(symbols, opts)
    end
  end

  # `Feed.canonical_symbols/1` is what the real feed spells and refuses symbols with —
  # `btcusd` and `BTCUSD` are `BTC-USD`, not merely upper-cased, and a value that is not a
  # list of strings is refused rather than raised on. `canonical_case/1` upper-cased only, so
  # `BTCUSD` was filtered out as unlisted and nothing was delivered where the real package
  # delivers `BTC-USD`.
  defp do_subscribe(symbols, opts) do
    target = Config.opt(opts, :to, self())
    channels = Config.opt(opts, :channels, @default_channels)
    wanted = Enum.filter(symbols, &(&1 in @symbols))

    push(wanted, target, channels)

    # **Added to, never replacing.** This was the identical line `update_symbols/2`
    # carries below — the two callbacks were byte-for-byte the same function — so a
    # second `subscribe/2` dropped whatever the first had subscribed. The real
    # facade unions (`wanted: MapSet.union(state.wanted, MapSet.new(symbols))` in
    # `Feed`), so a consumer's tier-1 tests against this fake certified the opposite
    # of what the venue does: subscribe twice, keep one symbol here, keep both there.
    #
    # The contract settles which is right without needing a new sentence in it.
    # `c:DpExchange.Core.Venue.update_symbols/2` exists to "change a live
    # subscription's symbol set", and `c:unsubscribe/2` to stop delivery for named
    # symbols. Neither has any purpose if `subscribe/2` already replaces — you would
    # just subscribe the new list. Two callbacks the contract distinguishes,
    # implemented as one function, is the tell.
    Process.put(__MODULE__, MapSet.union(subscribed(), MapSet.new(wanted)))

    if :top_of_book in channels do
      Process.put(@top_of_book_key, MapSet.union(subscribed_top_of_book(), MapSet.new(wanted)))
    end

    # Unioned the same way, and only for symbols this very call actually pushed a trade
    # for — a symbol subscribed earlier WITHOUT `:trades` does not retroactively gain
    # trade coverage just because a later, unrelated call asked for trades on other
    # symbols.
    if :trades in channels do
      Process.put(@trades_key, MapSet.union(subscribed_trades(), MapSet.new(wanted)))
    end

    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols) do
      dropped = MapSet.new(symbols)
      Process.put(__MODULE__, MapSet.difference(subscribed(), dropped))
      Process.put(@trades_key, MapSet.difference(subscribed_trades(), dropped))
      Process.put(@top_of_book_key, MapSet.difference(subscribed_top_of_book(), dropped))
      :ok
    end
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    with {:ok, symbols} <- Feed.canonical_symbols(symbols) do
      do_update_symbols(symbols)
    end
  end

  defp do_update_symbols(symbols) do
    wanted = MapSet.new(Enum.filter(symbols, &(&1 in @symbols)))

    # **A symbol this adds is pushed for, as `subscribe/2` pushes.** It used to be put
    # straight into the covered set with nothing sent, so `coverage/1` answered `:stream`
    # for a symbol that had delivered nothing, the intent-for-evidence substitution
    # `c:DpExchange.Core.Venue.coverage/1` forbids. Pushed to the caller, with the default
    # channels: the contract's callback takes neither a `to:` nor `:channels`.
    added = wanted |> MapSet.difference(subscribed()) |> MapSet.to_list()
    push(added, self(), @default_channels)

    Process.put(__MODULE__, wanted)

    Process.put(
      @top_of_book_key,
      subscribed_top_of_book() |> MapSet.union(MapSet.new(added)) |> MapSet.intersection(wanted)
    )

    # Narrowed to the new set, never expanded by it — `update_symbols/2` carries no
    # `:channels` of its own (the contract's callback takes none), so a symbol it adds
    # cannot be assumed to want trades; one it keeps can only keep what it already had.
    Process.put(@trades_key, MapSet.intersection(subscribed_trades(), wanted))
    :ok
  end

  # What a real `@bookTicker` frame delivers for each symbol — a `Quote` and, with
  # `:top_of_book` asked for, a `TopOfBook` — plus a `Trade` per symbol for `:trades`. The
  # real Feed's default delivers both of the first two, and this fake used to push only the
  # `Quote`, so a consumer's book handling had nothing to run against.
  defp push(symbols, target, channels) do
    for symbol <- symbols do
      with {:ok, quote_struct} <- fake_quote(symbol),
           do: send(target, {:dp_exchange, :gemini, streamed(quote_struct)})

      if :top_of_book in channels do
        with {:ok, book} <- fake_top_of_book(symbol),
             do: send(target, {:dp_exchange, :gemini, %{book | venue_time: nil}})
      end

      if :trades in channels, do: send(target, {:dp_exchange, :gemini, trade_for(symbol)})
    end

    :ok
  end

  # Observed, not intended — only symbols actually pushed for.
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  @doc """
  See `DpExchange.Gemini.coverage_by_kind/1`.

  `subscribe/2` pushes a `Types.Quote` for every symbol, a `Types.TopOfBook` when
  `:top_of_book` is in `opts[:channels]` (the default, as on the real Feed), and
  `update_symbols/2` pushes both for a symbol it adds. Each kind reads here only for symbols
  it was actually pushed for.
  `:trades` is real, not empty: a symbol reads here only for a `subscribe/2` call that
  named it AND asked for `:trades` in `opts[:channels]` — narrowed the same way
  `subscribed/0` narrows `:quotes` on `unsubscribe/2` and `update_symbols/2`, so a symbol
  no longer wanted, or one dropped from a later `update_symbols/2` call, stops reading as
  covered here too. **Less capable than the real adapter is allowed; answering a
  different shape is not**, so the keys match `capabilities().streamable` exactly, the
  same three the real adapter reports.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{
          Capabilities.data_kind() => %{Venue.symbol() => Venue.route()}
        }
  def coverage_by_kind(_opts \\ []) do
    %{
      quotes: Map.new(subscribed(), &{&1, :stream}),
      top_of_book: Map.new(subscribed_top_of_book(), &{&1, :stream}),
      trades: Map.new(subscribed_trades(), &{&1, :stream})
    }
  end

  @impl true
  def subscribe_notices(opts \\ []) do
    # Registers, and sends nothing: the real Feed answers `:ok` and notifies on the next
    # event, so a `:link_up` here was a notice a consumer's test saw that production never
    # sends. Found 2026-10-10.
    with {:ok, _subscriber} <- Feed.valid_subscriber(Config.opt(opts, :to, self())), do: :ok
  end

  @impl true
  def test_connection(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts), do: {:ok, %{reachable: true}}
    end)
  end

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  defp subscribed_trades, do: Process.get(@trades_key, MapSet.new())

  defp subscribed_top_of_book, do: Process.get(@top_of_book_key, MapSet.new())

  # `get_price/2`'s `Quote` is the REST shape — `venue_time` is the venue's `Date` header
  # when it sends a readable one, else `nil` (see `usage-rules.md`'s "Quote.venue_time is the
  # venue's HTTP Date"); the fake always answers with the header present. The STREAMED
  # `Quote` is a different fact from a different transport: it comes off a `bookTicker`
  # frame's `c`, which the vendor's own AsyncAPI documents no trade time for at all (websocket.yaml:1254-1256), so
  # `DpExchange.Gemini.Socket` delivers it with `venue_time: nil` unconditionally — see
  # `Socket.deliver_last_trade/3`. Reusing `get_price/2`'s struct unmodified here answered
  # `venue_time: @at` on the stream, which is not "less capable than the real adapter", the
  # only kind of divergence this fake is allowed — it is a DIFFERENT capability: a
  # consumer's test asserting on the streamed Quote's `venue_time` would pass against this
  # fake and fail against the real venue, the exact defect `CLAUDE.md` names as the family's
  # own fail-closed rule for fakes.
  #
  # The same holds for volume: the streamed `Quote` carries none (`Socket` builds it with
  # `volume: nil`, the venue's volume arriving as `Trade.quantity`), where `get_price/2`'s
  # carries the ticker's 24-hour total. Kept, the fake's stream showed a volume the real one
  # never sends — the kind of quantity dp-exchange-core issue #42 found consumers summing.
  defp streamed(%Types.Quote{} = quote_struct),
    do: %{quote_struct | venue_time: nil, volume: nil, volume_window: nil}

  # A `Types.Trade` consistent with `WsDecode.to_trade/2`'s own shape: a real `id`
  # (`to_string_or_nil/1` never turns an absent id into `""` there, so this never does
  # either), a real `side` rather than `nil` (`aggressor/1` only answers `nil` for a frame
  # missing `m` entirely, which this fake never has to model), `broken: false` because the
  # socket publishes no bust flag and a venue that says nothing has not said a trade was
  # busted, and a fixed, non-nil `timestamp` — `Types.Trade` enforces one, and `@at` is
  # this fake's one clock throughout, never `DateTime.utc_now/0`.
  defp trade_for(symbol) do
    %Types.Trade{
      id: "fake-trade-1",
      symbol: symbol,
      side: :buy,
      price: Decimal.new(@price[symbol]),
      quantity: Decimal.new("1"),
      timestamp: @at,
      broken: false,
      provider: :gemini
    }
  end

  defp candle(symbol, timeframe) do
    price = Decimal.new(@price[symbol])

    %Types.Candle{
      symbol: symbol,
      timeframe: timeframe,
      opened_at: @at,
      open: price,
      high: price,
      low: price,
      close: price,
      volume: Decimal.new("4.81"),
      provider: :gemini
    }
  end

  # The spelling every real call resolves a symbol to. `Rest` and `Private` send
  # `to_exchange_symbol/1` and report `to_canonical_symbol/1`, so `get_price("btcusd")`,
  # `get_price("BTCUSD")` and `get_price("BTC-USD")` are one request there and one answer
  # under `BTC-USD`. This looked the caller's spelling up verbatim, so only the exact
  # canonical one was found and the others were refused as unlisted, with a venue refusal the
  # venue never sent. A value that is not a string is left for the lookup to refuse, as the
  # real functions refuse it by raising.
  defp canonical(symbol) when is_binary(symbol) do
    symbol |> SymbolFormat.to_exchange_symbol() |> SymbolFormat.to_canonical_symbol()
  end

  defp canonical(other), do: other

  # What `Private.to_order/1` makes of the venue's own `type` and `options`: a stop-limit by
  # its type, otherwise the single execution option, otherwise a plain limit order.
  defp order_type_of("exchange stop limit", _options), do: :stop_limit
  defp order_type_of(_type, ["maker-or-cancel" | _rest]), do: :post_only
  defp order_type_of(_type, ["immediate-or-cancel" | _rest]), do: :ioc
  defp order_type_of(_type, ["fill-or-kill" | _rest]), do: :fok
  defp order_type_of(_type, _options), do: :limit

  defp optional_decimal(nil), do: nil
  defp optional_decimal(value), do: decimal(value)

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

  @impl true
  def get_positions(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # A short, because the short is where the sign convention bites: the venue sends a
        # negative quantity and a fake that only ever returned a long would never exercise it.
        {:ok,
         [
           %Types.Position{
             symbol: "BTCGUSDPERP",
             side: :short,
             quantity: Decimal.new("0.2"),
             instrument_type: :perp,
             average_cost: Decimal.new("60000"),
             mark_price: Decimal.new("59500"),
             notional_value: Decimal.new("-11900"),
             realised_pnl: Decimal.new("12.5"),
             unrealised_pnl: Decimal.new("100"),
             # Not published on /v1/positions. `nil` is "not stated", never "no risk".
             liquidation_price: nil,
             leverage: nil,
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def get_funding(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
      # Settled and estimated differ, and by a lot — a fake that made them equal would let a
      # consumer read either as the other and still pass.
      {:ok,
       %Types.Funding{
         symbol: symbol,
         amount: Decimal.new("-1.50991"),
         estimated_amount: Decimal.new("-2.10595"),
         funded_at: ~U[2026-09-01 18:00:00Z],
         next_funding_at: ~U[2026-09-01 19:00:00Z],
         provider: :gemini
       }}
    end)
  end

  @impl true
  def get_contract_stats(symbol, _opts \\ []) do
    with_injection(symbol, fn ->
      # Mark away from index, because that divergence is the reason both are carried.
      {:ok,
       %Types.ContractStats{
         symbol: symbol,
         product_type: "PerpetualSwapContract",
         mark_price: Decimal.new("59500"),
         index_price: Decimal.new("59480"),
         open_interest: Decimal.new("1240"),
         open_interest_notional: Decimal.new("73780000"),
         venue_time: nil,
         provider: :gemini
       }}
    end)
  end

  @impl true
  def get_staking_rates(_opts \\ []) do
    with_injection(fn ->
      # Two providers for one asset, at different rates. One rate would hide the reason
      # `provider_id` is required on stake/3 and unstake/3.
      {:ok,
       [
         %Types.StakingRate{
           asset: "ETH",
           provider_id: "provider-a",
           rate_pct: Decimal.new("4.0"),
           apy_pct: Decimal.new("4.07"),
           provider: :gemini
         },
         %Types.StakingRate{
           asset: "ETH",
           provider_id: "provider-b",
           rate_pct: Decimal.new("3.5"),
           # APY absent where the venue publishes none — never derived from the rate above it.
           apy_pct: nil,
           provider: :gemini
         }
       ]}
    end)
  end

  @impl true
  def get_staking_balances(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # The whole position redeemable and none of it tradable — the real shape that breaks
        # a caller reading a single "available". `by_provider` carries a real breakdown
        # rather than the empty map this used to hardcode — `balanceByProvider`
        # (`rest.yaml:6565,6573`) is sent on every row in the venue's own example, and an
        # always-empty fake taught nothing about the field it exists for.
        {:ok,
         [
           %Types.StakingBalance{
             asset: "ETH",
             staked: Decimal.new("10"),
             available_to_trade: Decimal.new("0"),
             available_for_withdrawal: Decimal.new("10"),
             by_provider: %{"provider-a" => Decimal.new("10")},
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def get_staking_rewards(opts \\ []) do
    with_injection(fn ->
      # `since` is required at the venue (`rest.yaml:6885`, in the request schema's
      # `required` list) — the fake refuses its absence the same way
      # `Private.get_staking_rewards/2` does now, rather than answering for a window the
      # caller never named. Before the credential, as there: a call with no `:since` is
      # refused before anything is signed, and was asked for its credential first here. The
      # staking writes below do the same with `:provider_id`.
      with {:ok, _since} <- fake_required_since(opts),
           :ok <- authenticated(fake_credentials(opts), opts) do
        {:ok,
         [
           %Types.StakingReward{
             asset: "ETH",
             amount: Decimal.new("0.0031"),
             provider_id: "provider-a",
             apy_pct: Decimal.new("4.07"),
             accrual_count: 7,
             period_start: ~U[2026-08-25 00:00:00Z],
             period_end: ~U[2026-09-01 00:00:00Z],
             provider: :gemini
           }
         ]}
      end
    end)
  end

  defp fake_required_since(opts) do
    case Keyword.get(opts, :since) do
      nil -> {:error, {:missing_option, :since}}
      since -> {:ok, since}
    end
  end

  @impl true
  def get_staking_history(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(fake_credentials(opts), opts) do
        # A redemption mid-unbond: requested, part paid, part outstanding. A fake whose rows
        # all settled would never exercise the field this type exists for.
        {:ok,
         [
           %Types.StakingTransaction{
             id: "stk-1",
             type: :unstake,
             venue_type: "Redeem",
             asset: "ETH",
             amount: Decimal.new("10"),
             amount_paid_so_far: Decimal.new("4"),
             amount_remaining: Decimal.new("6"),
             provider_id: "provider-a",
             provider: :gemini
           }
         ]}
      end
    end)
  end

  @impl true
  def stake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with {:ok, provider_id} <- fake_provider_id(opts),
           {:ok, _currency, _wire_amount} <- Private.validate_staking_terms(asset, amount),
           :ok <- authenticated(fake_credentials(opts), opts) do
        {:ok,
         %Types.StakingTransaction{
           id: "stk-new",
           type: :stake,
           # `nil`, not `"Deposit"` — `StakingDeposit` (`rest.yaml:9466-9497`), this
           # endpoint's own reply shape, carries no `transactionType` field at all; that
           # belongs to the *history* endpoint's row, a different schema. A fake naming a
           # word the real reply never sends is more capable than the endpoint it fakes.
           venue_type: nil,
           asset: String.upcase(asset),
           amount: amount,
           amount_paid_so_far: nil,
           amount_remaining: nil,
           provider_id: provider_id,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def unstake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with {:ok, provider_id} <- fake_provider_id(opts),
           {:ok, _currency, _wire_amount} <- Private.validate_staking_terms(asset, amount),
           :ok <- authenticated(fake_credentials(opts), opts) do
        # Nothing has arrived yet. A fake reporting the full amount paid would teach a
        # consumer to spend an asset that is still unbonding.
        {:ok,
         %Types.StakingTransaction{
           id: "stk-redeem",
           type: :unstake,
           # `nil` — `StakingWithdrawal` (`rest.yaml:9663-9692`) carries no `transactionType`
           # either. `venue_time` is `requestInitiated`, the one field this reply DOES carry
           # that `StakingDeposit` does not — `stake/4`'s fake stays `nil` for the reason
           # given there.
           venue_type: nil,
           asset: String.upcase(asset),
           amount: amount,
           amount_paid_so_far: Decimal.new("0"),
           amount_remaining: amount,
           provider_id: provider_id,
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  defp fake_provider_id(opts) do
    case Keyword.get(opts, :provider_id) do
      nil -> {:error, :missing_provider_id}
      provider_id -> {:ok, provider_id}
    end
  end

  @impl true
  def quote_conversion(from, to, amount, opts \\ []) do
    with_injection(fn ->
      # The fake refuses the ambiguous direction the real package refuses, with the real
      # function (`Private.instant_pair/3`) and before the credential, as the real path does:
      # nothing is signed for a direction it cannot determine. A fake that picked one would
      # let a consumer's suite pass on a conversion that spends the wrong asset.
      with {:ok, _symbol, _side} <- Private.instant_pair(from, to, opts),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.Conversion{
           # Numeric, as the venue's `quoteId` is, so `commit_conversion/2` (which checks the id
           # through `Private.validate_commit_terms/2`) accepts the quote this fake issued.
           # `"fake-gemini-quote-1"` was refused as `:invalid_quote_id`, the same defect as
           # issue #5 for orders.
           id: "1",
           status: :quoted,
           from_asset: from,
           to_asset: to,
           from_amount: amount,
           to_amount: Decimal.div(amount, Decimal.new("40000")),
           rate: Decimal.new("40000"),
           fee: Decimal.new("0.30"),
           # A real window, so a consumer testing expiry has something to test against.
           expires_at: DateTime.add(@at, 60, :second),
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def commit_conversion(id, opts \\ []) do
    with_injection(fn ->
      # The venue's execute call needs the terms it quoted against, not the id alone —
      # `:symbol`, `:side`, `:amount`, `:price` and `:fee` (the venue requires the last and
      # states it "must match fee returned in the quote", `rest.yaml:5071`). Checked by the
      # real function, `Private.validate_commit_terms/2`, and before the credential, exactly
      # as `Private.commit_conversion/2` does. This used its own `Keyword.has_key?/2` test,
      # which `price: nil` and `price: ""` satisfy (the real one counts neither as given),
      # never looked at the quote id, and asked for the credential first.
      with :ok <- Private.validate_commit_terms(id, opts),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.Conversion{
           id: id,
           status: :settled,
           from_asset: "USD",
           to_asset: "BTC",
           rate: Decimal.new("40000"),
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def convert(from, to, amount, opts \\ []) do
    with_injection(fn ->
      # One step and already settled — no rate was held, which is the whole difference from
      # quote_conversion/4.
      with {:ok, _symbol, _side} <- Private.instant_pair(from, to, opts),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.Conversion{
           id: "fake-gemini-wrap-1",
           status: :settled,
           from_asset: from,
           to_asset: to,
           from_amount: amount,
           to_amount: amount,
           rate: Decimal.new("1"),
           expires_at: nil,
           venue_time: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def get_trade_volume(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        {:ok,
         [%{"symbol" => "btcusd", "total_volume_base" => "10.5", "data_date" => "2026-08-31"}]}
      end
    end)
  end

  @impl true
  def get_conversion(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()
  @impl true
  def list_portfolios(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_deposit_address(asset, network, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.DepositAddress{
           asset: asset,
           network: network,
           address: "0x0000000000000000000000000000000000000000",
           memo: nil,
           # `nil`, as in production. `false` would tell a consumer no memo is needed, which
           # on Solana or XRP loses the deposit.
           memo_required: nil,
           label: Keyword.get(opts, :label),
           created_at: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def list_approved_addresses(opts \\ []) do
    with_injection(fn ->
      # The network is named before the credential is asked for, as
      # `Private.list_approved_addresses/2` does: there is no all-networks variant, and a
      # call that names none is refused before anything is signed.
      case Keyword.get(opts, :network) do
        nil ->
          {:error, {:missing_option, :network}}

        network ->
          with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            # One active and one still time-locked, because a consumer that only ever sees
            # active addresses never handles the pending case — and a withdrawal to a pending
            # address is refused.
            {:ok,
             [
               %Types.ApprovedAddress{
                 address: "0x1111111111111111111111111111111111111111",
                 network: network,
                 status: :active,
                 label: "desk",
                 requested_at: @at,
                 provider: :gemini
               },
               %Types.ApprovedAddress{
                 address: "0x2222222222222222222222222222222222222222",
                 network: network,
                 status: :pending,
                 # No activation time, so `usable?/2` answers nil — unknown, not "ready".
                 active_from: nil,
                 label: "new",
                 requested_at: @at,
                 provider: :gemini
               }
             ]}
          end
      end
    end)
  end

  @impl true
  def estimate_withdrawal_fee(_asset, network, _amount, opts \\ []) do
    with_injection(fn ->
      # The destination first, then the credential — `Private.estimate_withdrawal_fee/5`
      # refuses a missing `:address` before it signs anything.
      case Keyword.get(opts, :address) do
        nil ->
          {:error, {:missing_option, :address}}

        address ->
          with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            {:ok,
             %{
               fee: Decimal.new("0.0005"),
               fee_currency: "ETH",
               network: network,
               address: address
             }}
          end
      end
    end)
  end

  @impl true
  def withdraw(asset, network, amount, address, opts \\ []) do
    with_injection(fn ->
      # The memo rule first, then the credential: `Private.withdraw/6` refuses a required
      # memo that is missing "here, where nothing has moved", before it signs anything.
      with :ok <- fake_memo(Keyword.get(opts, :memo), Keyword.get(opts, :memo_required, false)),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok,
         %Types.Withdrawal{
           # The idempotency key the real package always sends, echoed so a consumer can
           # assert its own was used.
           id: Config.opt(opts, :client_transfer_id, "fake-transfer-1"),
           # **`:pending`, never `:completed`.** The venue accepting a withdrawal is not the
           # chain confirming it, and a fake that reported completion would teach a consumer
           # the money has arrived.
           status: :pending,
           asset: asset,
           amount: amount,
           network: network,
           address: address,
           memo: Keyword.get(opts, :memo),
           fee: Decimal.new("0.0005"),
           tx_id: nil,
           requested_at: @at,
           provider: :gemini
         }}
      end
    end)
  end

  @impl true
  def list_payment_methods(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # `PaymentMethodsResponse` (`rest.yaml:5454`, schema `:9316-9328`) is
        # `{balances: [...], banks: [...]}`, not the `"methods"` list this used to fake.
        # `Private.list_payment_methods/2` tags each row `"kind" => "balance"` or
        # `"kind" => "bank"` to keep the split the venue's own two arrays make; this mirrors
        # that split with the venue's own example values rather than an invented
        # verified/pending pair neither array actually carries (`PaymentMethodBank` has no
        # status field at all).
        {:ok,
         [
           %{
             "kind" => "balance",
             "type" => "exchange",
             "currency" => "USD",
             "amount" => "50893484.26",
             "available" => "50889972.01",
             "availableForWithdrawal" => "50889972.01"
           },
           %{
             "kind" => "bank",
             "bank" => "Jpmorgan Chase Bank Checking  - 1111",
             "bankId" => "97631a24-ca40-4277-b3d5-38c37673d029"
           }
         ]}
      end
    end)
  end

  @impl true
  def add_payment_method(details, opts \\ []) do
    with_injection(fn ->
      # The country first, then the credential — `Private.add_payment_method/3` picks the
      # endpoint, and refuses a country it has none for, before it signs anything.
      with {:ok, _path} <- fake_country(Config.opt(opts, :country, "US")),
           :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        # **Pending, never verified.** The venue verifies out of band; a fake that returned a
        # usable method would teach a consumer the first transfer will work.
        {:ok, Map.merge(%{"id" => "bank-3", "status" => "pending"}, details)}
      end
    end)
  end

  defp fake_country("US"), do: {:ok, :us}
  defp fake_country("CA"), do: {:ok, :ca}
  defp fake_country(country), do: {:error, {:unsupported_country, country}}

  @impl true
  def transfer_internal(asset, amount, transfer_opts, opts \\ []) do
    with_injection(fn ->
      # Both ends first, then the credential: `Private.transfer_internal/5` refuses a missing
      # `:from` or `:to` before it signs anything. The amount is written out in full, as there,
      # through `decimal/1` — `Decimal.new/1` raised on a float.
      case {Keyword.get(transfer_opts, :from), Keyword.get(transfer_opts, :to)} do
        {nil, _to} ->
          {:error, {:missing_option, :from}}

        {_from, nil} ->
          {:error, {:missing_option, :to}}

        {from, to} ->
          # The asset and amount are checked by the function the real call uses, after the
          # two account names and before the credential, as there.
          with {:ok, _currency, wire_amount} <- Private.validate_internal_transfer(asset, amount),
               :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
            {:ok,
             %{
               "asset" => asset,
               "amount" => wire_amount,
               "sourceAccount" => from,
               "targetAccount" => to
             }}
          end
      end
    end)
  end

  @impl true
  def request_approved_address(network, address, label, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts),
           :ok <- label_present(label) do
        # **Pending.** A successful response is not permission to withdraw, and a fake that
        # returned "active" would teach a consumer it is.
        {:ok,
         %{
           "network" => network,
           "address" => address,
           "label" => label,
           "status" => "pending-time"
         }}
      end
    end)
  end

  # The real adapter refuses a missing label (the venue requires one, `rest.yaml:5702`); a
  # fake that accepted it would be differently capable.
  defp label_present(label) when is_binary(label) and label != "", do: :ok
  defp label_present(_label), do: {:error, {:missing_required_field, :label}}

  @impl true
  def remove_approved_address(network, address, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(Keyword.get(opts, :credentials, %{}), opts) do
        {:ok, %{"network" => network, "address" => address, "status" => "removed"}}
      end
    end)
  end

  @impl true
  def get_transactions(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # Kinds that are not trades and not transfers, because that is the point of the
        # endpoint and a fake returning only fills would hide it.
        {:ok,
         [
           %{"type" => "Trade", "amount" => "1"},
           %{"type" => "Deposit", "amount" => "100"},
           %{"type" => "Fee", "amount" => "-0.5"}
         ]}
      end
    end)
  end

  @impl true
  def get_notional_balances(credentials, currency, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # The quantity and its valuation are different keys and different numbers. A fake that
        # made them equal would let a consumer read either as the other and still pass.
        {:ok,
         [
           %{
             "currency" => "BTC",
             "amount" => "1.5",
             "amountNotional" => "60000.00",
             "available" => "1.5",
             "availableNotional" => "60000.00",
             "notionalCurrency" => String.upcase(currency)
           }
         ]}
      end
    end)
  end

  @impl true
  def list_custody_fees(credentials, opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated(credentials, opts) do
        # A charge with no trade behind it — the gap a consumer reconciling against fills
        # alone cannot otherwise explain.
        {:ok,
         [
           %{
             "currency" => "BTC",
             "amount" => "0.00012",
             "timestampms" => 1_700_000_000_000,
             "eid" => 123_456
           }
         ]}
      end
    end)
  end

  @impl true
  def get_payment_method(_credentials, _id, _opts \\ []), do: Venue.not_supported()

  defp fake_memo(nil, true), do: {:error, :memo_required}
  defp fake_memo(_memo, _required), do: :ok

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_account(opts \\ []) do
    with_injection(fn ->
      case Keyword.get(opts, :name) do
        name when is_binary(name) ->
          with :ok <- authenticated_group(fake_credentials(opts), opts) do
            # The venue answers with a kebab-cased shortname, not the name that was sent —
            # a fake that echoed the name would let a consumer address the wrong thing.
            {:ok,
             %{
               "account" => name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
               "type" => Config.opt(opts, :type, "exchange")
             }}
          end

        _missing ->
          {:error, :name_required}
      end
    end)
  end

  @impl true
  def rename_account(id, name, opts \\ []) do
    with_injection(fn ->
      # As `DpExchange.Gemini.rename_account/3` hands `Private.rename_account/2` its options:
      # `id` IS the `account` the call is made against, so a master key that names the
      # account by `id` has named it. Without the merge a master-scoped fake credential was
      # refused `MissingAccounts` for an account the caller had named.
      opts = Keyword.merge(opts, account: id, name: name)
      shortname = Keyword.get(opts, :shortname)

      # `Private.rename_account/2` refuses a call that would change nothing, before it signs
      # anything: no new name and no new shortname is `:nothing_to_rename`, not a success.
      if is_nil(name) and is_nil(shortname) do
        {:error, :nothing_to_rename}
      else
        with :ok <- authenticated(fake_credentials(opts), opts),
             do: {:ok, renamed(id, name, shortname)}
      end
    end)
  end

  # Only the fields that changed come back, as the venue documents: the account's (new)
  # shortname, and the display name when one was sent.
  defp renamed(id, nil, shortname), do: %{"account" => shortname || id}
  defp renamed(id, name, shortname), do: %{"name" => name, "account" => shortname || id}

  @impl true
  def get_roles(opts \\ []) do
    with_injection(fn ->
      with :ok <- authenticated_group(fake_credentials(opts), opts) do
        # Trader and Fund Manager combined, and Auditor false — the combination the venue
        # allows. One role field would not be able to say this.
        {:ok, %{"isAuditor" => false, "isFundManager" => true, "isTrader" => true}}
      end
    end)
  end
end
