defmodule DpExchange.Gemini.Private do
  @moduledoc """
  Gemini's authenticated endpoints — internal. Balances, orders and trade history.

  ## The boundary, precisely

  **The host authenticates. This module makes authenticated requests with what the host
  hands it.** Those are different jobs and the difference is the whole design: a caller
  passes credentials into every one of these functions, they are used to sign that one
  request, and nothing is kept. This module never obtains a credential, never stores one,
  never refreshes one, and never decides which authentication scheme applies — see `Auth`,
  which refuses to guess.

  Which means trading works exactly as the facade intends: the host does auth, calls
  `place_order/3` with credentials, and gets a `Core.Types.Order` back.

  ## Gemini has no market orders, and this package will not fake one

  From the venue's own page:

  > The API doesn't directly support market orders because they provide you with no price
  > protection. Instead, use the "immediate-or-cancel" order execution option, coupled
  > with an aggressive limit price (i.e. very high for a buy order or very low for a sell
  > order), to achieve the same result.

  **That advice is not something a package may take on a caller's behalf.** "An aggressive
  limit price" means *inventing a number the caller did not supply* and sending it to a
  live exchange as a real order. How aggressive? Ten percent through the book? Fifty? The
  package cannot know, the caller never said, and the difference is money.

  So `order_type: :market` is `{:error, {:unsupported_order_type, :market}}` — the venue
  does not serve it, and the nearest thing requires a price only the caller can choose. A
  caller who wants that behaviour asks for it explicitly, with their own limit:

      %{order_type: :limit, time_in_force: :ioc, price: my_aggressive_price, …}

  This is the family's named failure mode in its most expensive form. Every other instance
  in this codebase costs a wrong number in a chart; this one costs a fill at a price nobody
  chose.

  ## Order execution options are mutually exclusive

  > If you specify more than one option (or an unsupported option) in the options array,
  > the exchange will reject your order.

  So `time_in_force` maps to exactly one option, or none:

  | `time_in_force` | Gemini option | Meaning |
  |---|---|---|
  | `:gtc` (default) | none | fills what it can, rests the remainder on the book |
  | `:post_only` / `:maker_or_cancel` | `maker-or-cancel` | adds liquidity only, cancels if it would take |
  | `:ioc` | `immediate-or-cancel` | takes what it can, cancels the rest |
  | `:fok` | `fill-or-kill` | fills entirely or cancels entirely |

  No option may be combined with a stop-limit order.

  ## A cancelled order is not a failed request

  MOC, IOC and FOK orders that do not fill come back **200 with `"is_cancelled": true`**.
  That is the venue answering successfully; the order simply did not rest. It maps to
  `status: :cancelled` on a `{:ok, order}`, never to an error — a caller that treated it as
  a failure would retry an order the venue already handled.

  ## Auth failures are refusals, not errors

  Measured 2026-08-28 against the demo environment: an unauthenticated POST to any private
  endpoint returns **`401 MissingSecurityHeaders`**. Gemini's own error table documents
  `MissingApikeyHeader` at **400**, so the documented codes and the live ones disagree —
  the fourth documentation divergence found on this venue.

  Either way 400, 401 and 403 are permanent *for the request as sent*: retrying the
  identical bytes cannot succeed. They are `{:refused, reason}`. A caller whose token
  expired refreshes it and calls again with new credentials, which is a different request —
  not a retry of this one.
  """

  alias DpExchange.Core.HttpClient

  alias DpExchange.Core.Types.{
    ApprovedAddress,
    Balance,
    Conversion,
    DepositAddress,
    Fill,
    Order,
    Position,
    StakingBalance,
    StakingReward,
    StakingTransaction,
    Withdrawal
  }

  alias DpExchange.Gemini.{Auth, Environment, Rest, SymbolFormat}

  @doc "Every currency the account holds, with what is available and what is on hold."
  @spec get_balances(map(), keyword()) ::
          {:ok, [Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, opts) do
    with {:ok, rows, headers} <- post("/v1/balances", %{}, credentials, opts),
         {:ok, timestamp} <- venue_time(headers) do
      {:ok, Enum.map(rows, &to_balance(&1, timestamp))}
    end
  end

  @doc "The account's own record of itself — name, type, and the roles the key carries."
  @spec get_accounts(map(), keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/account", %{}, credentials, opts) do
      {:ok, List.wrap(body)}
    end
  end

  @doc """
  The fee tier this account trades at, from `/v1/notionalvolume`.

  Returned as the venue states it — basis points, per maker/taker, alongside the notional
  volume that determined the tier. Nothing is converted to a rate, because the venue's own
  units are what a caller will reconcile against.
  """
  @spec get_fees(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_fees(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/notionalvolume", %{}, credentials, opts) do
      {:ok, body}
    end
  end

  @doc """
  Transfers in and out of the account.

  Calls **`/v2/transfers`**. The v1 path this package used until the D6 migration is absent
  from Gemini's published OpenAPI document, and v2's own description says why: *"The v1
  transfers endpoint is being retired. This v2 endpoint is the recommended"* replacement.

  The three parameters are unchanged — `currency`, `timestamp`, `limit_transfers` — so this
  was a path swap and nothing more. v2 additionally accepts `network`, `account` and
  `show_completed_deposit_advances`, and each returned transfer now carries a `network`
  field naming the chain. None of that is surfaced here yet; the rows are passed through.
  """
  @spec get_transfers(map(), keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transfers(credentials, opts) do
    params = take_params(opts, [:limit_transfers, :currency, :timestamp])

    with {:ok, rows, _headers} <- post("/v2/transfers", params, credentials, opts) do
      {:ok, List.wrap(rows)}
    end
  end

  @doc """
  Places an order.

  `request` is a map carrying at least `:symbol`, `:side`, `:quantity` and `:price`.
  `:order_type` defaults to `:limit`; `:time_in_force` defaults to `:gtc`. A
  `:client_order_id` is passed through when given and is strongly recommended by the venue.

  Refuses rather than substituting:

    * `order_type: :market` — the venue serves none, and the documented workaround needs a
      limit price only the caller can choose
    * an unknown `:time_in_force` — the venue rejects an unsupported option outright
    * a missing price on a type that requires one
  """
  @spec place_order(map(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, {type, _from_type} = resolved} <-
           order_type(Map.get(request, :order_type, :limit)),
         {:ok, options} <- execution_options(Map.get(request, :time_in_force, :gtc), resolved),
         {:ok, price} <- required_price(request) do
      params =
        %{
          "symbol" => SymbolFormat.to_exchange_symbol(Map.fetch!(request, :symbol)),
          "amount" => to_string(Map.fetch!(request, :quantity)),
          "price" => to_string(price),
          "side" => to_string(Map.fetch!(request, :side)),
          "type" => type,
          "options" => options
        }
        |> maybe_put("stop_price", Map.get(request, :stop_price))
        |> maybe_put("client_order_id", Map.get(request, :client_order_id))
        |> maybe_put("account", Keyword.get(opts, :account))

      with {:ok, body, _headers} <- post("/v1/order/new", params, credentials, opts) do
        to_order(body)
      end
    end
  end

  @doc "Cancels one order by the venue's order id."
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, order_id, opts) do
    with {:ok, body, _headers} <-
           post("/v1/order/cancel", %{"order_id" => order_id}, credentials, opts) do
      to_order(body)
    end
  end

  @doc "One order's current state."
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, order_id, opts) do
    with {:ok, body, _headers} <-
           post("/v1/order/status", %{"order_id" => order_id}, credentials, opts) do
      to_order(body)
    end
  end

  @doc """
  Orders for this account — resting by default, closed with `history: true`.

  **Two endpoints, not one with a filter.** `/v1/orders` returns what is still on the book;
  `/v1/orders/history` returns what is not. A caller asking for "orders" without saying
  which gets the resting ones, the set that can still change.

  History accepts `symbol:` and `limit:` (the venue's `limit_orders`, default 50, max 500)
  and a `since:` `DateTime`. The venue's own default applies where the caller gives none —
  this does not substitute one of its own, because a page size chosen here would silently
  become the caller's answer.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    {path, params} =
      if Keyword.get(opts, :history, false) do
        {"/v1/orders/history", history_params(opts)}
      else
        {"/v1/orders", %{}}
      end

    with {:ok, rows, _headers} <- post(path, params, credentials, opts) do
      rows
      |> List.wrap()
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case to_order(row) do
          {:ok, order} -> {:cont, {:ok, [order | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, orders} -> {:ok, Enum.reverse(orders)}
        error -> error
      end
    end
  end

  defp history_params(opts) do
    %{}
    |> put_present("symbol", symbol_param(Keyword.get(opts, :symbol)))
    |> put_present("limit_orders", Keyword.get(opts, :limit))
    |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))
  end

  defp symbol_param(nil), do: nil
  defp symbol_param(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  # The venue's own unit. Milliseconds, because that is what its examples show and what its
  # own responses carry in `timestampms`.
  defp timestamp_param(nil), do: nil
  defp timestamp_param(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp timestamp_param(other), do: other

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Cancels open orders in bulk, at the scope the caller states.

  Gemini publishes both scopes as separate endpoints:

      :session  ->  /v1/order/cancel/session
      :account  ->  /v1/order/cancel/all

  **`opts[:scope]` is required.** The account scope reaches orders no API key placed —
  including ones a person entered through the web interface, which the venue says
  explicitly — and picking it for a caller who meant the session would cancel work nobody
  asked about. Gemini's own documentation recommends the session scope; that is guidance
  for the caller, not licence to choose here.

  Returns the venue's own two lists. **A non-empty `rejected` is not a failure of this
  call** — the venue answered, and some of those orders were already gone. Reporting an
  error would tell a caller nothing was cancelled when most of it was.
  """
  @spec cancel_all_orders(map(), keyword()) ::
          {:ok, %{cancelled: [String.t()], rejected: [String.t()]}}
          | {:error, term()}
          | {:refused, term()}
  def cancel_all_orders(credentials, opts) do
    with {:ok, path} <- cancel_scope(Keyword.get(opts, :scope)),
         {:ok, body, _headers} <- post(path, %{}, credentials, opts) do
      cancel_all_result(body)
    end
  end

  defp cancel_scope(:session), do: {:ok, "/v1/order/cancel/session"}
  defp cancel_scope(:account), do: {:ok, "/v1/order/cancel/all"}
  defp cancel_scope(nil), do: {:error, :scope_required}
  defp cancel_scope(other), do: {:error, {:unsupported_scope, other}}

  defp cancel_all_result(%{"details" => details}) when is_map(details) do
    {:ok,
     %{
       cancelled: ids(details["cancelledOrders"]),
       rejected: ids(details["cancelRejects"])
     }}
  end

  defp cancel_all_result(_body), do: {:error, :unexpected_response_shape}

  # The venue sends integers; every other order id in this package is a string, and a
  # caller holding both should not have to know which call produced which.
  defp ids(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp ids(_absent), do: []

  @doc """
  Past fills for a symbol.

  Gemini requires a symbol here — there is no all-symbols variant — so a caller asking for
  everything is asking for one request per symbol, and it is theirs to decide whether to.
  """
  @spec get_trade_history(map(), keyword()) ::
          {:ok, [Fill.t()]} | {:error, term()} | {:refused, term()}
  def get_trade_history(credentials, opts) do
    case Keyword.get(opts, :symbol) do
      nil ->
        {:error, {:missing_option, :symbol}}

      symbol ->
        params =
          %{"symbol" => SymbolFormat.to_exchange_symbol(symbol)}
          |> maybe_put("limit_trades", Keyword.get(opts, :limit))
          |> maybe_put("timestamp", Keyword.get(opts, :since))

        with {:ok, rows, _headers} <- post("/v1/mytrades", params, credentials, opts) do
          {:ok, Enum.map(List.wrap(rows), &to_fill(&1, symbol))}
        end
    end
  end

  @doc """
  Confirms the credentials reach the venue, using its own heartbeat endpoint.

  A real round trip rather than a guess: `/v1/heartbeat` is authenticated, so a success
  proves the key, the signature and the nonce mode are all right. It also resets the
  session's cancel-on-disconnect timer, which is a side effect worth knowing about — on a
  key provisioned with *Requires Heartbeat*, calling this keeps open orders alive.
  """
  @spec test_connection(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def test_connection(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/heartbeat", %{}, credentials, opts) do
      {:ok, %{reachable: true, environment: Environment.resolve(opts), response: body}}
    end
  end

  # --- request ------------------------------------------------------------

  defp post(path, params, credentials, opts) do
    scheme = auth_scheme(credentials, opts)

    with {:ok, headers} <- Auth.headers(scheme, path, stringify(params), credentials, opts) do
      url = base_url(opts) <> path

      case HttpClient.request(:post, url, headers, "", request_opts(opts)) do
        {:ok, %{status: status, body: body, headers: response_headers}}
        when status in 200..299 ->
          {:ok, decode(body), response_headers}

        # Permanent for the request as sent. A caller refreshes a token and calls again —
        # that is a different request, not a retry of this one.
        {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
          {:refused, refusal(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :gemini, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The host chose its authentication; `:auth_scheme` says which. When it is absent the
  # scheme is taken from what the host actually supplied — which is the host's choice
  # expressed a different way, not this package inferring one. Credentials carrying BOTH
  # are refused rather than resolved: sending both header families is
  # `AmbiguousAuthentication` at the venue, and picking one would be guessing.
  defp auth_scheme(credentials, opts) do
    Keyword.get_lazy(opts, :auth_scheme, fn ->
      case credentials do
        %{api_key: _key, access_token: _token} -> :ambiguous
        %{api_key: _key} -> :api_key
        %{access_token: _token} -> :oauth
        _other -> nil
      end
    end)
  end

  defp base_url(opts) do
    Keyword.get_lazy(opts, :base_url, fn ->
      opts |> Environment.resolve() |> Environment.rest_url()
    end)
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([:limiter, :timeout, :retry_attempts, :log_requests, :plug, :req_adapter])
    |> Keyword.merge(provider: :gemini_private, raw_status: true)
  end

  # An authenticated **GET**, where the signed `request` is the full path *including the
  # query string*. Gemini signs a payload even on its private GETs, and the payload's
  # `request` field is documented with the query attached — signing the bare path yields a
  # valid signature over the wrong string, which the venue reports as a credential problem
  # rather than a parameter one. One string, used in both places, is what keeps them equal.
  defp signed_get(path, credentials, opts) do
    scheme = auth_scheme(credentials, opts)

    with {:ok, headers} <- Auth.headers(scheme, path, %{}, credentials, opts) do
      case HttpClient.request(:get, base_url(opts) <> path, headers, nil, request_opts(opts)) do
        {:ok, %{status: status, body: body, headers: response_headers}}
        when status in 200..299 ->
          {:ok, decode(body), response_headers}

        {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
          {:refused, refusal(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :gemini, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The same call, returning the venue's bytes untouched. A spreadsheet is not JSON and
  # decoding it would turn a real file into an empty map.
  defp signed_get_raw(path, credentials, opts) do
    case signed_get_bytes(path, credentials, opts) do
      {:ok, body} -> {:ok, body}
      other -> other
    end
  end

  defp signed_get_bytes(path, credentials, opts) do
    scheme = auth_scheme(credentials, opts)

    with {:ok, headers} <- Auth.headers(scheme, path, %{}, credentials, opts) do
      case HttpClient.request(:get, base_url(opts) <> path, headers, nil, request_opts(opts)) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
          {:refused, refusal(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:exchange_error, :gemini, "HTTP #{status}: #{inspect(body)}"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- order mapping ------------------------------------------------------

  # The contract models maker-or-cancel, IOC and fill-or-kill as ORDER TYPES; Gemini
  # models them as execution *options* on a limit order. Both spellings are therefore
  # accepted and both land on the same wire representation, which is what translation
  # means. Each returns `{type, options}`.
  #
  # `:market` and `:stop` are absent deliberately — see the moduledoc. Neither exists at
  # this venue, and reaching the nearest thing would mean choosing a price the caller
  # never supplied.
  defp order_type(:limit), do: {:ok, {"exchange limit", []}}
  defp order_type(:stop_limit), do: {:ok, {"exchange stop limit", []}}
  defp order_type(:post_only), do: {:ok, {"exchange limit", ["maker-or-cancel"]}}
  defp order_type(:maker_or_cancel), do: {:ok, {"exchange limit", ["maker-or-cancel"]}}
  defp order_type(:ioc), do: {:ok, {"exchange limit", ["immediate-or-cancel"]}}
  defp order_type(:fok), do: {:ok, {"exchange limit", ["fill-or-kill"]}}
  defp order_type(other), do: {:error, {:unsupported_order_type, other}}

  # Exactly one option reaches the venue, or none: "if you specify more than one option
  # (or an unsupported option) in the options array, the exchange will reject your order."
  #
  # A caller can express the same intent twice — `order_type: :ioc` and
  # `time_in_force: :ioc`. Agreeing is fine. **Disagreeing is refused**, not resolved by
  # precedence: an order that says both post-only and fill-or-kill has no correct reading,
  # and picking one would be this package deciding how someone's money is spent.
  defp execution_options(tif, {type, from_type}) do
    case {tif_option(tif), from_type} do
      {{:error, reason}, _from_type} ->
        {:error, reason}

      {{:ok, []}, from_type} ->
        allow(type, from_type)

      {{:ok, from_tif}, []} ->
        allow(type, from_tif)

      {{:ok, same}, same} ->
        allow(type, same)

      {{:ok, from_tif}, from_type} ->
        {:error, {:conflicting_execution_options, from_type, from_tif}}
    end
  end

  defp tif_option(:gtc), do: {:ok, []}
  defp tif_option(:ioc), do: {:ok, ["immediate-or-cancel"]}
  defp tif_option(:fok), do: {:ok, ["fill-or-kill"]}
  defp tif_option(other), do: {:error, {:unsupported_time_in_force, other}}

  # "No options can be applied to stop-limit orders at this time."
  defp allow("exchange stop limit", [option | _rest]),
    do: {:error, {:unsupported_time_in_force, option, :not_allowed_on_stop_limit}}

  defp allow(_type, options), do: {:ok, options}

  defp required_price(request) do
    case Map.get(request, :price) do
      nil -> {:error, {:missing_field, :price}}
      price -> {:ok, price}
    end
  end

  defp to_order(%{"order_id" => _id} = body) do
    {:ok,
     %Order{
       id: to_string(body["order_id"]),
       symbol: SymbolFormat.to_canonical_symbol(body["symbol"]),
       side: side(body["side"]),
       order_type: order_type_of(body),
       quantity: decimal(body["original_amount"]),
       price: decimal(body["price"]),
       stop_price: decimal(body["stop_price"]),
       status: status_of(body),
       filled_quantity: decimal(body["executed_amount"]),
       average_price: decimal(body["avg_execution_price"]),
       created_at: epoch_ms(body["timestampms"]),
       updated_at: epoch_ms(body["timestampms"]),
       provider: :gemini
     }}
  end

  defp to_order(_body), do: {:error, :unexpected_response_shape}

  defp side("buy"), do: :buy
  defp side("sell"), do: :sell
  defp side(_other), do: nil

  defp order_type_of(%{"type" => "exchange stop limit"}), do: :stop_limit
  defp order_type_of(%{"options" => ["maker-or-cancel" | _rest]}), do: :post_only
  defp order_type_of(%{"options" => ["immediate-or-cancel" | _rest]}), do: :ioc
  defp order_type_of(%{"options" => ["fill-or-kill" | _rest]}), do: :fok
  defp order_type_of(_body), do: :limit

  # A cancelled MOC/IOC/FOK order arrives as a successful 200. It is a state, not a
  # failure, and reporting it as one would have a caller retry an order the venue handled.
  defp status_of(%{"is_cancelled" => true} = body) do
    if positive?(body["executed_amount"]), do: :filled, else: :cancelled
  end

  defp status_of(%{"is_live" => true} = body) do
    if positive?(body["executed_amount"]), do: :partially_filled, else: :open
  end

  defp status_of(body) do
    if positive?(body["executed_amount"]), do: :filled, else: :pending
  end

  defp positive?(nil), do: false

  defp positive?(amount) do
    case decimal(amount) do
      nil -> false
      value -> Decimal.positive?(value)
    end
  end

  # --- other mapping ------------------------------------------------------

  defp to_balance(row, timestamp) do
    %Balance{
      currency: row["currency"],
      balance: decimal(row["amount"]),
      available_balance: decimal(row["available"]),
      hold: hold(row),
      timestamp: timestamp,
      provider: :gemini
    }
  end

  # Gemini reports the total and what is available, not the hold. The difference is the
  # hold — derived rather than invented, and `nil` when either side is missing rather than
  # a zero that would read as "nothing on hold".
  defp hold(%{"amount" => amount, "available" => available})
       when is_binary(amount) and is_binary(available) do
    # Both fields go through the safe parser now, not `Decimal.new/1` directly — a
    # malformed side must not raise, and it must not produce a fabricated hold either.
    subtract_hold(decimal(amount), decimal(available))
  end

  defp hold(_row), do: nil

  defp subtract_hold(nil, _available), do: nil
  defp subtract_hold(_amount, nil), do: nil
  defp subtract_hold(amount, available), do: Decimal.sub(amount, available)

  defp to_fill(row, symbol) do
    %Fill{
      order_id: to_string(row["order_id"]),
      trade_id: to_string(row["tid"]),
      symbol: symbol,
      side: side(row["type"] && String.downcase(row["type"])),
      quantity: decimal(row["amount"]),
      price: decimal(row["price"]),
      fee: decimal(row["fee_amount"]),
      fee_currency: row["fee_currency"],
      timestamp: epoch_ms(row["timestampms"]),
      liquidity: liquidity(row["aggressor"]),
      provider: :gemini
    }
  end

  defp liquidity(true), do: :taker
  defp liquidity(false), do: :maker
  defp liquidity(_other), do: nil

  @doc """
  Quotes a conversion between two assets, holding a rate the caller may then commit.

  This is Gemini's **Instant** pair, `/v1/instant/quote` then `/v1/instant/execute`. The
  venue states the price, the quantity, the fee and a `maxAgeMs`, and holds that rate for
  the window — typically 60 seconds. Nothing has moved until `commit_conversion/2`.

  ## Which of the two assets is the pair, and why this refuses more often than you expect

  The venue takes a symbol and a side, not a from/to pair, and the two are not
  interchangeable: `totalSpend` is `CCY2` on a buy and `CCY1` on a sell. So `DAI -> BTC` is
  *buy BTCDAI spending DAI*, and `BTC -> DAI` is *sell BTCDAI spending BTC*.

  Deriving that needs to know which of the two is the pair's quote side, and **this venue
  quotes in crypto as well as fiat** — `SymbolFormat.quotes/0` lists BTC, ETH, SOL and FIL
  alongside USD and the stablecoins. So for `USD -> BTC` both assets are quote currencies,
  both orientations parse, and only the venue's catalogue says which pair exists.

  **It refuses with `{:ambiguous_conversion, from, to}` rather than picking one**, and that
  includes the common `USD -> BTC`. Choosing wrongly spends the wrong asset, which is a
  real loss rather than a wrong-looking number, and this package will not resolve it by
  fetching a catalogue behind the caller's back.

  So pass `opts[:symbol]` and `opts[:side]`. Derivation is the convenience for the case
  where exactly one side is a quote currency, not the main path.

  The expiry comes from the venue's `maxAgeMs` measured from the response's own `Date`
  header, not from the local clock. A quote whose window is computed against a clock the
  venue does not share is a quote that expires at the wrong time.
  """
  @spec quote_conversion(String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, Conversion.t()} | {:error, term()} | {:refused, term()}
  def quote_conversion(from, to, amount, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    with {:ok, symbol, side} <- instant_pair(from, to, opts) do
      params = %{
        "symbol" => symbol,
        "side" => side,
        "totalSpend" => to_string(amount)
      }

      with {:ok, body, headers} <- post("/v1/instant/quote", params, credentials, opts) do
        to_conversion(body, from, to, :quoted, headers)
      end
    end
  end

  @doc """
  Commits a quote by its `quoteId`, moving the assets.

  `/v1/instant/execute`. **A quote past its window does not fill at the quoted rate** —
  see `Core.Types.Conversion`, whose `expires_at` exists for exactly this. Ask
  `Conversion.expired?/2` before committing; the venue is still the authority on whether
  a commit succeeds.
  """
  @spec commit_conversion(String.t(), keyword()) ::
          {:ok, Conversion.t()} | {:error, term()} | {:refused, term()}
  def commit_conversion(id, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    with {:ok, params} <- execute_params(id, opts),
         {:ok, body, headers} <- post("/v1/instant/execute", params, credentials, opts) do
      to_conversion(body, nil, nil, :settled, headers)
    end
  end

  # The venue needs the same symbol, side and spend it quoted against, alongside the id —
  # `/v1/instant/execute` does not take the quote id alone. A caller holding the
  # `Conversion` this package returned has all of them, so they come from `opts` and a
  # missing one is an error rather than a value invented here.
  defp execute_params(id, opts) do
    required = [:symbol, :side, :amount, :price]

    case Enum.reject(required, &Keyword.has_key?(opts, &1)) do
      [] ->
        {:ok,
         %{
           "quoteId" => id,
           "symbol" => SymbolFormat.to_exchange_symbol(Keyword.fetch!(opts, :symbol)),
           "side" => opts |> Keyword.fetch!(:side) |> to_string(),
           "quantity" => to_string(Keyword.fetch!(opts, :amount)),
           "price" => to_string(Keyword.fetch!(opts, :price)),
           "fee" => to_string(Keyword.get(opts, :fee, "0"))
         }}

      missing ->
        {:error, {:missing_option, missing}}
    end
  end

  defp instant_pair(from, to, opts) do
    case {Keyword.get(opts, :symbol), Keyword.get(opts, :side)} do
      {nil, nil} ->
        derive_instant_pair(from, to)

      {symbol, side} when is_binary(symbol) and side in [:buy, :sell] ->
        {:ok, SymbolFormat.to_exchange_symbol(symbol), to_string(side)}

      _partial ->
        {:error, {:missing_option, [:symbol, :side]}}
    end
  end

  defp derive_instant_pair(from, to) do
    quotes = SymbolFormat.quotes()
    from_quote? = String.upcase(from) in quotes
    to_quote? = String.upcase(to) in quotes

    cond do
      from_quote? and not to_quote? ->
        {:ok, SymbolFormat.to_exchange_symbol("#{to}-#{from}"), "buy"}

      to_quote? and not from_quote? ->
        {:ok, SymbolFormat.to_exchange_symbol("#{from}-#{to}"), "sell"}

      true ->
        # Both or neither. This venue quotes in crypto too, so `USD -> BTC` lands here:
        # both are quote currencies and only the catalogue says which pair exists. Picking
        # one spends the wrong asset — a real loss, not a wrong-looking number.
        {:error, {:ambiguous_conversion, from, to}}
    end
  end

  # The venue's own window, anchored to the venue's own clock. `maxAgeMs` measured from the
  # local clock would expire at the wrong moment on any client whose time has drifted, and
  # a conversion committed a second late fills at a rate the caller was never shown.
  defp to_conversion(%{} = body, from, to, status, headers) do
    {:ok,
     %Conversion{
       id: body |> Map.get("quoteId") |> to_string_or_nil(),
       status: status,
       from_asset: from || Map.get(body, "totalSpendCurrency"),
       to_asset: to || Map.get(body, "quantityCurrency"),
       from_amount: decimal(Map.get(body, "totalSpend")),
       to_amount: decimal(Map.get(body, "quantity")),
       rate: decimal(Map.get(body, "price")),
       fee: decimal(Map.get(body, "fee")),
       expires_at: expires_at(Map.get(body, "maxAgeMs"), headers),
       venue_time: venue_date(headers),
       provider: :gemini
     }}
  end

  defp to_conversion(_body, _from, _to, _status, _headers),
    do: {:error, :unexpected_response_shape}

  defp expires_at(nil, _headers), do: nil

  defp expires_at(max_age_ms, headers) when is_integer(max_age_ms) do
    case venue_date(headers) do
      nil -> nil
      at -> DateTime.add(at, max_age_ms, :millisecond)
    end
  end

  defp expires_at(_other, _headers), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # `venue_time/1` returns a result tuple because its callers need to fail on a missing
  # date. Here a missing date costs the expiry window and nothing else, so it degrades to
  # `nil` — which `Conversion.expired?/2` reports as *unknown*, not as "still valid".
  defp venue_date(headers) do
    case venue_time(headers) do
      {:ok, at} -> at
      _no_date -> nil
    end
  end

  @doc """
  Wraps or unwraps in one call — the venue's `/v1/wrap/{symbol}`.

  **This is `convert/4`'s one-step form and not the Instant pair.** There is no quote to
  accept: the venue executes at its own price and reports the rate in the result. A caller
  that must see a price first uses `quote_conversion/4` instead.

  The direction comes from the two assets, exactly as it does for Instant, and it refuses
  the same way when neither orientation is determinable — pass `opts[:symbol]` and
  `opts[:side]` to say which.

  Returns a `Conversion` already `:settled`. It has happened.
  """
  @spec convert(String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, Conversion.t()} | {:error, term()} | {:refused, term()}
  def convert(from, to, amount, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    with {:ok, symbol, side} <- instant_pair(from, to, opts) do
      params = %{"amount" => to_string(amount), "side" => side}

      with {:ok, body, headers} <- post("/v1/wrap/#{symbol}", params, credentials, opts) do
        to_conversion(body, from, to, :settled, headers)
      end
    end
  end

  @doc """
  The account's own traded volume, as the venue aggregates it — `/v1/tradevolume`.

  One row per symbol per day, with the maker and taker breakdown the venue's fee tiers are
  computed from. **Not `get_trade_history/2` summed**: this venue requires a symbol on every
  fills request, so reproducing this means one request per symbol per period, and the answer
  would still be this package's arithmetic against the venue's ledger.

  Rows come back as the venue sends them. The fields differ enough between venues that a
  normalised struct would be mostly `nil`, and a caller reading `buy_maker_notional` wants
  the venue's number under the venue's name.
  """
  @spec get_trade_volume(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_trade_volume(credentials, opts) do
    with {:ok, rows, _headers} <- post("/v1/tradevolume", %{}, credentials, opts) do
      # The venue nests one list per symbol inside the outer list.
      {:ok, rows |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  The networks an asset moves over, or the assets a network carries.

  **Call this before `get_deposit_address/3`.** That endpoint takes a network, and a wrong
  one produces an address on a chain this venue does not credit — funds sent there are gone.

  Two directions and two endpoints, both authenticated GETs:

      list_networks("USDC", credentials: creds)              GET /v2/network/USDC
      list_networks(nil, network: "…", credentials: creds)   GET /v2/networks/{network}/assets

  **Both directions were dead until 2026-09-05, in two different ways.** The asset
  direction used to be documented "Public" and delegate to `Rest.networks_for_asset/2`,
  which sends no credentials — that is `Rest`'s whole design. Measured live: an
  unauthenticated `GET /v2/network/BTC` returns `401 MissingSecurityHeaders`, and the
  vendor's OpenAPI requires apiKeyAuth, signatureAuth and payloadAuth on it, so this
  direction could never succeed for any consumer. The network direction had its own,
  independent bug: it `POST`ed to `/v2/networks/{network}/assets`, and the vendor documents
  that route as `GET` (`operationId: getAssetsForNetwork`) — there is no POST form. Both
  now go through `signed_get/3`, the helper this module already used for exactly this
  request shape elsewhere.

  **Both are scoped to the credential.** The vendor requires the Fund Manager or Auditor
  role and states the network direction returns *"only the assets where your account has
  deposit and withdraw access enabled"*. So an empty answer means **this account cannot
  move anything on that network**, not that the network carries nothing — a caller reading
  it as a description of the network would draw the wrong conclusion from a true response.
  """
  @spec list_networks(String.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_networks(nil, opts) do
    case Keyword.get(opts, :network) do
      nil ->
        {:error, :asset_or_network_required}

      network ->
        credentials = Keyword.get(opts, :credentials, %{})

        with {:ok, body, _headers} <-
               signed_get("/v2/networks/#{network}/assets", credentials, opts) do
          {:ok, List.wrap(body)}
        end
    end
  end

  def list_networks(asset, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    with {:ok, body, _headers} <- signed_get("/v2/network/#{asset}", credentials, opts) do
      {:ok, List.wrap(body)}
    end
  end

  @doc """
  A fresh deposit address for `asset` on `network` — `/v1/deposit/{network}/newAddress`.

  **The network is not optional and must not be guessed.** An address generated for the
  wrong chain still looks like an address; funds sent to it on another chain are gone.
  `list_networks/2` is how a caller learns which networks this venue credits for an asset.

  `opts[:label]` names the address at the venue. `opts[:legacy]` asks for a legacy
  P2SH-P2PKH Litecoin address, which is the venue's own flag and defaults to false.

  **`memo_required` is `nil`, not `false`.** Some networks — Solana, XRP, Cosmos — need a
  destination tag or the deposit is unattributable, and this endpoint's response does not
  say whether this one does. `false` would be a claim that no memo is needed; `nil` says
  this package does not know, and a caller must check the network before sending.
  """
  @spec get_deposit_address(String.t(), String.t(), map(), keyword()) ::
          {:ok, DepositAddress.t()} | {:error, term()} | {:refused, term()}
  def get_deposit_address(asset, network, credentials, opts) do
    params =
      %{}
      |> put_present("label", Keyword.get(opts, :label))
      |> put_present("legacy", Keyword.get(opts, :legacy))

    with {:ok, body, _headers} <-
           post("/v1/deposit/#{network}/newAddress", params, credentials, opts) do
      {:ok,
       %DepositAddress{
         asset: asset,
         network: network,
         address: body["address"],
         memo: body["memo"],
         # Not `false`. This endpoint does not say, and `false` would be a claim that no
         # memo is needed — which on Solana or XRP loses the deposit.
         memo_required: nil,
         label: body["label"],
         created_at: nil,
         provider: :gemini
       }}
    end
  end

  @doc """
  The addresses this account may withdraw to on `network` —
  `/v1/approvedAddresses/account/{network}`.

  **An address on this list is not necessarily usable yet.** The venue reports
  `status: "pending-time"` for one still inside its time lock, and a withdrawal to it is
  refused. `Core.Types.ApprovedAddress.usable?/2` answers that, and returns `nil` where the
  venue gave a pending status with no activation time — unknown, not "ready".

  `opts[:network]` selects; there is no all-networks variant, because the venue keeps a list
  per network.
  """
  @spec list_approved_addresses(map(), keyword()) ::
          {:ok, [ApprovedAddress.t()]} | {:error, term()} | {:refused, term()}
  def list_approved_addresses(credentials, opts) do
    case Keyword.get(opts, :network) do
      nil ->
        {:error, {:missing_option, :network}}

      network ->
        with {:ok, body, _headers} <-
               post("/v1/approvedAddresses/account/#{network}", %{}, credentials, opts) do
          {:ok,
           body
           |> approved_rows()
           |> Enum.map(&to_approved_address(&1, network))}
        end
    end
  end

  defp approved_rows(%{"approvedAddresses" => rows}) when is_list(rows), do: rows
  defp approved_rows(rows) when is_list(rows), do: rows
  defp approved_rows(_other), do: []

  defp to_approved_address(row, network) do
    %ApprovedAddress{
      address: row["address"],
      network: row["network"] || network,
      status: approval_status(row["status"]),
      asset: nil,
      label: row["label"],
      # The venue publishes `createdAt` and no activation time. `usable?/2` therefore
      # answers `nil` for a pending address rather than guessing when the lock lifts.
      active_from: nil,
      requested_at: epoch_ms_to_datetime(row["createdAt"]),
      provider: :gemini
    }
  end

  # The venue's own words. Anything it invents later is `:pending` rather than `:active`:
  # treating an unknown status as usable is the direction that loses money.
  defp approval_status("active"), do: :active
  defp approval_status("rejected"), do: :rejected
  defp approval_status(_pending_or_unknown), do: :pending

  defp epoch_ms_to_datetime(nil), do: nil

  defp epoch_ms_to_datetime(value) when is_binary(value) do
    case Integer.parse(value) do
      {ms, ""} -> DateTime.from_unix!(ms, :millisecond)
      _not_an_epoch -> nil
    end
  end

  defp epoch_ms_to_datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp epoch_ms_to_datetime(_other), do: nil

  @doc """
  What the venue would charge to withdraw `amount` of `asset` over `network` to `address` —
  `/v2/withdraw/{network}/{ticker}/feeEstimate`.

  **The address is part of the estimate**, not decoration: fees differ by destination on
  some networks, so an estimate for one address does not hold for another.

  This moves no funds. `withdraw/6` does.
  """
  @spec estimate_withdrawal_fee(String.t(), String.t(), Decimal.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def estimate_withdrawal_fee(asset, network, amount, credentials, opts) do
    with {:ok, address} <- required_address(opts) do
      params = %{"address" => address, "amount" => to_string(amount)}
      ticker = String.downcase(asset)

      with {:ok, body, _headers} <-
             post("/v2/withdraw/#{network}/#{ticker}/feeEstimate", params, credentials, opts) do
        {:ok,
         %{
           fee: decimal(body["fee"] || body["feeAmount"]),
           fee_currency: body["currency"] || body["feeCurrency"],
           network: network,
           address: address
         }}
      end
    end
  end

  defp required_address(opts) do
    case Keyword.get(opts, :address) do
      nil -> {:error, {:missing_option, :address}}
      address -> {:ok, address}
    end
  end

  @doc """
  Withdraws `amount` of `asset` over `network` to `address` — `/v2/withdraw/{network}/{ticker}`.

  **This moves funds and cannot be undone.** Everything below exists because of that.

  ## A retry without an idempotency key withdraws twice

  The venue accepts `clientTransferId`, *"a unique UUID for idempotent withdrawals. If
  provided, duplicate requests with the same `clientTransferId` will not create additional
  withdrawals."* It is optional at the venue and **not optional here**: this generates one
  when the caller gives none.

  A withdrawal request that times out has an unknown outcome — the funds may already be
  moving. Without a key, the safe-looking response (retry) is the one that sends the money
  again. `opts[:client_transfer_id]` lets a caller supply its own so a retry across a
  process restart is still the same request.

  ## The memo is required on some networks and this package cannot tell you which

  The venue: *"Required for certain networks that use memos (e.g., Solana, XRP, Cosmos)."*
  It publishes no machine-readable list, so **this does not guess one**. A withdrawal to an
  exchange address on a memo network without one is credited to nobody and is generally not
  recoverable.

  `opts[:memo]` is passed through. **`opts[:memo_required]` is a caller's assertion, not a
  lookup**: passing `true` with no memo is refused here rather than sent.

  ## Three preconditions the venue states

  1. The account has an approved address list
  2. **The destination is already on it** — `list_approved_addresses/2`, and note that an
     address can be present and still time-locked
  3. The API key carries the Fund Manager role

  None can be checked from here without spending a request, and all three fail at the venue
  with a message; they are stated so a caller can check them before it gets there.
  """
  @spec withdraw(String.t(), String.t(), Decimal.t(), String.t(), map(), keyword()) ::
          {:ok, Withdrawal.t()} | {:error, term()} | {:refused, term()}
  def withdraw(asset, network, amount, address, credentials, opts) do
    memo = Keyword.get(opts, :memo)

    with :ok <- memo_present(memo, Keyword.get(opts, :memo_required, false)) do
      transfer_id = Keyword.get(opts, :client_transfer_id) || generate_transfer_id()

      params =
        %{
          "address" => address,
          "amount" => to_string(amount),
          # Always sent. A retry without one is a second withdrawal.
          "clientTransferId" => transfer_id
        }
        |> put_present("memo", memo)

      ticker = String.downcase(asset)

      with {:ok, body, _headers} <-
             post("/v2/withdraw/#{network}/#{ticker}", params, credentials, opts) do
        {:ok, to_withdrawal(body, asset, network, address, amount, memo)}
      end
    end
  end

  # A caller that says the network needs a memo and then sends none is stopped here, where
  # nothing has moved, rather than at the venue after the transfer is accepted.
  defp memo_present(nil, true), do: {:error, :memo_required}
  defp memo_present(_memo, _required), do: :ok

  # `crypto.strong_rand_bytes` rather than a counter or a timestamp: two processes retrying
  # the same withdrawal must not generate the same id by accident, and must not generate a
  # *different* one for what is meant to be the same request either — which is why a caller
  # that needs a stable id across restarts passes its own.
  defp generate_transfer_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      Bitwise.band(c, 0xFFF),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ])
    |> to_string()
  end

  defp to_withdrawal(body, asset, network, address, amount, memo) do
    %Withdrawal{
      id: to_string_or_nil(body["withdrawalId"] || body["clientTransferId"]),
      # The venue accepting a withdrawal is not the chain confirming it. `:pending` unless
      # the venue says otherwise, because `:completed` on an unconfirmed transfer would
      # tell a caller the money has arrived.
      status: withdrawal_status(body["status"]),
      asset: asset,
      amount: amount,
      network: network,
      address: address,
      memo: memo,
      fee: decimal(body["fee"]),
      tx_id: body["txHash"] || body["txn_hash"],
      requested_at: DateTime.utc_now(),
      provider: :gemini
    }
  end

  defp withdrawal_status("complete"), do: :completed
  defp withdrawal_status("completed"), do: :completed
  defp withdrawal_status("failed"), do: :failed
  defp withdrawal_status("cancelled"), do: :cancelled
  # Anything else, including nothing, is pending. A withdrawal the venue has not described
  # has not arrived.
  defp withdrawal_status(_other), do: :pending

  @doc """
  The funding sources this account can move fiat through — `/v1/payments/methods`.

  Rows are the venue's own. **A method being listed is not the same as being usable**: a
  bank account added through `add_payment_method/2` sits pending verification, and the
  status is in the row.
  """
  @spec list_payment_methods(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_payment_methods(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/payments/methods", %{}, credentials, opts) do
      {:ok, body |> payment_rows() |> List.wrap()}
    end
  end

  defp payment_rows(%{"methods" => rows}) when is_list(rows), do: rows
  defp payment_rows(rows) when is_list(rows), do: rows
  defp payment_rows(%{} = row), do: [row]
  defp payment_rows(_other), do: []

  @doc """
  Registers a bank account — `/v1/payments/addbank`, or `/v1/payments/addbank/cad` for a
  Canadian one.

  **Two endpoints, because the details differ by country.** A US account is a routing and
  account number; a Canadian one adds an institution and transit number. `opts[:country]`
  selects, defaulting to the US endpoint — and a country this venue has no endpoint for is
  refused rather than sent to the wrong one, where the fields would be read as the other
  country's and the account registered wrong.

  **The venue verifies out of band.** A successful response starts that; it does not finish
  it, and the method is not usable until the venue says so — which `list_payment_methods/2`
  reports.
  """
  @spec add_payment_method(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def add_payment_method(details, credentials, opts) do
    with {:ok, path} <- addbank_path(Keyword.get(opts, :country, "US")) do
      with {:ok, body, _headers} <- post(path, details, credentials, opts) do
        {:ok, body}
      end
    end
  end

  defp addbank_path("US"), do: {:ok, "/v1/payments/addbank"}
  defp addbank_path("CA"), do: {:ok, "/v1/payments/addbank/cad"}

  # Sending Canadian details to the US endpoint would have the fields read as the other
  # country's and the account registered wrong.
  defp addbank_path(country), do: {:error, {:unsupported_country, country}}

  @doc """
  Moves `amount` of `asset` between two accounts at this venue —
  `/v1/account/transfer/{currency}`.

  **Not `withdraw/5`.** Nothing leaves the venue and no chain is involved, so there is no
  address, no network and no network fee. `opts[:from]` and `opts[:to]` are the venue's own
  account names and both are required: a transfer with one end missing is not a transfer,
  and defaulting either would move funds between accounts the caller did not name.
  """
  @spec transfer_internal(String.t(), Decimal.t(), keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def transfer_internal(asset, amount, transfer_opts, credentials, opts) do
    with {:ok, from} <- required_opt(transfer_opts, :from),
         {:ok, to} <- required_opt(transfer_opts, :to) do
      params = %{
        "sourceAccount" => from,
        "targetAccount" => to,
        "amount" => to_string(amount)
      }

      currency = String.downcase(asset)

      with {:ok, body, _headers} <-
             post("/v1/account/transfer/#{currency}", params, credentials, opts) do
        {:ok, body}
      end
    end
  end

  defp required_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_option, key}}
      value -> {:ok, value}
    end
  end

  @doc """
  Asks the venue to add `address` to the withdrawal allowlist for `network` —
  `/v1/approvedAddresses/{network}/request`.

  **A successful response is not permission to withdraw.** The venue holds a new entry under
  a time lock and reports it as `pending-time` until the lock lifts; a withdrawal to it
  before then is refused. Read the list back with `list_approved_addresses/2` and check
  `ApprovedAddress.usable?/2`, which answers `nil` while the venue states no activation time.
  """
  @spec request_approved_address(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def request_approved_address(network, address, label, credentials, opts) do
    params = put_present(%{"address" => address}, "label", label)

    with {:ok, body, _headers} <-
           post("/v1/approvedAddresses/#{network}/request", params, credentials, opts) do
      {:ok, body}
    end
  end

  @doc """
  Removes `address` from the allowlist for `network` —
  `/v1/approvedAddresses/{network}/remove`.

  Generally immediate where addition is not: the venue is slow to widen what funds may reach
  and quick to narrow it.
  """
  @spec remove_approved_address(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def remove_approved_address(network, address, credentials, opts) do
    with {:ok, body, _headers} <-
           post(
             "/v1/approvedAddresses/#{network}/remove",
             %{"address" => address},
             credentials,
             opts
           ) do
      {:ok, body}
    end
  end

  @doc """
  Everything that moved on this account — `/v1/transactions`.

  **Wider than `get_trade_history/2` and wider than `get_transfers/2`**: fees, interest,
  credits and adjustments alongside deposits and fills. Rows are the venue's own, because
  the kinds do not share a shape.

  `opts[:since]` and `opts[:limit]` narrow it, in the venue's own names.

  **Summing this is not a balance.** `get_balances/2` is the authority; this explains it.
  """
  @spec get_transactions(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transactions(credentials, opts) do
    params =
      %{}
      |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))
      |> put_present("limit_transactions", Keyword.get(opts, :limit))

    with {:ok, body, _headers} <- post("/v1/transactions", params, credentials, opts) do
      {:ok, body |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  Every balance, each also valued in one notional currency — `/v1/notionalbalances/{currency}`.

  **Not `get_balances/2` in another unit.** The `amount` is the venue's ledger; the
  `amountNotional` beside it is Gemini's own valuation of that quantity, at a rate Gemini
  chose and does not publish here. Rows are returned as the venue sends them so the two
  cannot be read as one number.

  The currency is a path segment, not a parameter. Gemini documents `usd`; anything else is
  sent as given and the venue answers for itself, because a package that allowed only the
  documented one would be wrong the day a second is added.
  """
  @spec get_notional_balances(map(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_notional_balances(credentials, currency, opts) when is_binary(currency) do
    path = "/v1/notionalbalances/" <> String.downcase(currency)

    with {:ok, body, _headers} <- post(path, %{}, credentials, opts) do
      {:ok, body |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  What Gemini charged this account for *holding* assets — `/v1/custodyaccountfees`.

  Custody fees come straight out of the balance with no trade behind them, so a consumer
  reconciling balances against fills alone finds a gap this is the only explanation for.

  **An empty list means nothing was charged in the window asked for.** It does not mean the
  account holds nothing in custody, and it does not mean Gemini does not charge — an account
  with no custody balance and an account billed nothing this period return the same thing.

  `opts[:since]` and `opts[:limit]` page it, under the venue's own parameter names.
  """
  @spec list_custody_fees(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_custody_fees(credentials, opts) do
    params =
      %{}
      |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))
      |> put_present("limit_transfers", Keyword.get(opts, :limit))

    with {:ok, body, _headers} <- post("/v1/custodyaccountfees", params, credentials, opts) do
      {:ok, body |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  Staked positions, one per asset — `POST /v1/balances/staking`.

  **Three amounts, kept apart.** A real response carries `balance: 10`, `available: 0`,
  `availableForWithdrawal: 10` — the whole position is redeemable and none of it is
  tradable. A caller reading a single "available" would size an order against ten and place
  it against zero, which is why `StakingBalance` refuses to collapse them.

  **A missing state is `nil`, not zero.** A venue that did not report one has not said it is
  none, and this package will not say it for it.

  Zero-balance rows are **kept**. The host adapter this package replaces dropped them, which
  makes "the venue reports no position in ETH" and "the account holds nothing in ETH" the
  same answer; they are not.
  """
  @spec get_staking_balances(map(), keyword()) ::
          {:ok, [StakingBalance.t()]} | {:error, term()} | {:refused, term()}
  def get_staking_balances(credentials, opts) do
    with {:ok, rows, headers} <- post("/v1/balances/staking", %{}, credentials, opts) do
      at = venue_time_or_nil(headers)
      {:ok, rows |> List.wrap() |> Enum.map(&to_staking_balance(&1, at))}
    end
  end

  defp to_staking_balance(row, at) when is_map(row) do
    %StakingBalance{
      asset: String.upcase(row["currency"] || ""),
      staked: decimal(row["balance"]),
      available_to_trade: decimal(row["available"]),
      available_for_withdrawal: decimal(row["availableForWithdrawal"]),
      # Empty means the venue did not break the position down — never that there is one
      # provider, which is what a `%{}` default silently asserts.
      by_provider: %{},
      venue_time: at,
      provider: :gemini
    }
  end

  defp to_staking_balance(_row, at) do
    %StakingBalance{asset: "", staked: nil, venue_time: at, provider: :gemini}
  end

  @doc """
  Rewards accrued over a window — `POST /v1/staking/rewards`.

  **The window is part of the value.** The same number is a good day or a poor quarter
  depending on it, so `opts[:since]` and `opts[:until]` are sent to the venue and the bounds
  the venue reports back travel on the struct. Where the venue reports none, they stay `nil`
  rather than being filled in from the request — the venue is free to clamp a window, and a
  package that echoed the ask would report a period that was never served.

  `:apy_pct` is the rate **at accrual**, which is not what `get_staking_rates/1` reports
  today. That is what lets a caller reconcile a reward against the rate that produced it.
  """
  @spec get_staking_rewards(map(), keyword()) ::
          {:ok, [StakingReward.t()]} | {:error, term()} | {:refused, term()}
  def get_staking_rewards(credentials, opts) do
    params =
      %{}
      |> put_present("since", timestamp_param(Keyword.get(opts, :since)))
      |> put_present("until", timestamp_param(Keyword.get(opts, :until)))
      |> put_present("providerId", Keyword.get(opts, :provider_id))

    with {:ok, rows, _headers} <- post("/v1/staking/rewards", params, credentials, opts) do
      {:ok, rows |> List.wrap() |> Enum.map(&to_staking_reward/1)}
    end
  end

  defp to_staking_reward(row) when is_map(row) do
    %StakingReward{
      asset: String.upcase(row["currency"] || ""),
      amount: decimal(row["amount"]),
      provider_id: row["providerId"],
      apy_pct: decimal(row["apyPct"]),
      accrual_count: row["accrualCount"],
      period_start: staking_time(row["since"]),
      period_end: staking_time(row["until"]),
      provider: :gemini
    }
  end

  defp to_staking_reward(_row) do
    %StakingReward{asset: "", amount: nil, provider: :gemini}
  end

  @doc """
  Movements in and out of staked positions — `POST /v1/staking/history`.

  **A redemption is a process, not an event.** Rows carry `amount`, `amountPaidSoFar` and
  `amountRemaining`, and the three differ for most of a redemption's life while the asset
  unbonds. All three travel; `nil` on the last two means the venue does not report progress,
  **not** that the operation is complete.

  `:type` is the normalised atom and `:venue_type` keeps Gemini's own word — `Deposit`,
  `Redeem`, `Interest` and others. A normalisation that loses the original cannot be audited
  when it turns out to be wrong, and an unrecognised word maps to `:other` rather than to
  the nearest one that fits.
  """
  @spec get_staking_history(map(), keyword()) ::
          {:ok, [StakingTransaction.t()]} | {:error, term()} | {:refused, term()}
  def get_staking_history(credentials, opts) do
    params =
      %{}
      |> put_present("since", timestamp_param(Keyword.get(opts, :since)))
      |> put_present("until", timestamp_param(Keyword.get(opts, :until)))
      |> put_present("limit", Keyword.get(opts, :limit))
      |> put_present("providerId", Keyword.get(opts, :provider_id))

    with {:ok, rows, _headers} <- post("/v1/staking/history", params, credentials, opts) do
      {:ok, rows |> List.wrap() |> Enum.map(&to_staking_transaction/1)}
    end
  end

  @doc """
  Stakes `amount` of `asset` — `POST /v1/staking/stake`.

  **This moves funds.** The decision belongs to the consumer; this package carries it out
  and reports what the venue said.

  `opts[:provider_id]` names the provider. It is **required**, because the same asset can be
  staked with several at different rates and picking one here would stake at a rate the
  caller never chose. Missing it is `{:error, :missing_provider_id}` before a request is
  made.
  """
  @spec stake(String.t(), Decimal.t(), map(), keyword()) ::
          {:ok, StakingTransaction.t()} | {:error, term()} | {:refused, term()}
  def stake(asset, amount, credentials, opts) do
    staking_write("/v1/staking/stake", asset, amount, credentials, opts)
  end

  @doc """
  Redeems `amount` of a staked `asset` — `POST /v1/staking/unstake`.

  **Returns immediately; the redemption does not complete immediately.** The returned
  transaction carries `:amount_remaining`, non-zero for as long as the asset is unbonding. A
  caller treating the return value as settled will spend an asset it does not have yet.

  `opts[:provider_id]` is required for the same reason it is on `stake/4`: redeeming from
  the wrong provider redeems at the wrong rate, and a default gives the caller no way to
  notice.
  """
  @spec unstake(String.t(), Decimal.t(), map(), keyword()) ::
          {:ok, StakingTransaction.t()} | {:error, term()} | {:refused, term()}
  def unstake(asset, amount, credentials, opts) do
    staking_write("/v1/staking/unstake", asset, amount, credentials, opts)
  end

  defp staking_write(path, asset, amount, credentials, opts) do
    with {:ok, provider_id} <- required_provider_id(opts) do
      params = %{
        "currency" => String.upcase(asset),
        "amount" => Decimal.to_string(amount, :normal),
        "providerId" => provider_id
      }

      with {:ok, body, _headers} <- post(path, params, credentials, opts) do
        {:ok, to_staking_transaction(body)}
      end
    end
  end

  defp required_provider_id(opts) do
    case Keyword.get(opts, :provider_id) do
      nil -> {:error, :missing_provider_id}
      provider_id -> {:ok, provider_id}
    end
  end

  defp to_staking_transaction(row) when is_map(row) do
    %StakingTransaction{
      id: row["transactionId"] || row["id"],
      type: staking_type(row["transactionType"]),
      venue_type: row["transactionType"],
      asset: String.upcase(row["currency"] || ""),
      amount: decimal(row["amount"]),
      amount_paid_so_far: decimal(row["amountPaidSoFar"]),
      amount_remaining: decimal(row["amountRemaining"]),
      provider_id: row["providerId"],
      venue_time: staking_time(row["timestamp"] || row["timestampms"]),
      provider: :gemini
    }
  end

  defp to_staking_transaction(_row) do
    %StakingTransaction{
      id: nil,
      type: :other,
      asset: "",
      amount: nil,
      provider: :gemini
    }
  end

  defp staking_type("Deposit"), do: :stake
  defp staking_type("Redeem"), do: :unstake
  defp staking_type("Interest"), do: :reward
  # A word this package does not know is `:other`, and `:venue_type` still carries it. The
  # nearest atom that fits would be a guess a caller cannot see it made.
  defp staking_type(_other), do: :other

  # Gemini mixes seconds and milliseconds across its endpoints and the payload does not say
  # which. Anything at or past 10^12 is milliseconds; below it is seconds. A ms value read
  # as seconds lands past the epoch ceiling and raises.
  defp staking_time(nil), do: nil

  defp staking_time(value) when is_integer(value) do
    unit = if value >= 1_000_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, at} -> at
      {:error, _reason} -> nil
    end
  end

  defp staking_time(value) when is_float(value), do: staking_time(trunc(value))
  defp staking_time(_other), do: nil

  defp venue_time_or_nil(headers) do
    case venue_time(headers) do
      {:ok, at} -> at
      _other -> nil
    end
  end

  # --- perpetuals and margin ---------------------------------------------

  @doc """
  Open positions — `POST /v1/positions`.

  **Gemini sends a negative quantity for a short**, and `Types.Position` refuses to carry
  one: `:quantity` is the size, always positive, and `:side` says which way. A sign
  convention is a fact about one venue's JSON, not about the market, and a package that
  passed it through would hand a caller a position that is exactly backwards while every
  number in it stays plausible.

  `notional_value` is negative for shorts too, and it is **kept as the venue sent it** —
  that one is a signed value rather than a magnitude with a direction beside it, and
  flipping it would change what the number means.

  **Realised and unrealised P&L stay apart.** One has happened; the other is a mark-to-market
  opinion that may never be realised.

  `liquidation_price` is `nil` here: `/v1/positions` does not publish one. **That does not
  mean the position is safe** — `get_account_margin/2` publishes
  `estimated_liquidation_price` for the account, which is where a caller must look.
  """
  @spec get_positions(map(), keyword()) ::
          {:ok, [Position.t()]} | {:error, term()} | {:refused, term()}
  def get_positions(credentials, opts) do
    with {:ok, body, headers} <- post("/v1/positions", %{}, credentials, opts) do
      at = venue_time_or_nil(headers)
      {:ok, body |> position_rows() |> Enum.map(&to_position(&1, at))}
    end
  end

  defp position_rows(%{"openPositions" => rows}) when is_list(rows), do: rows
  defp position_rows(rows) when is_list(rows), do: rows
  defp position_rows(_other), do: []

  defp to_position(row, at) when is_map(row) do
    quantity = decimal(row["quantity"])

    %Position{
      symbol: row["symbol"],
      side: position_side(quantity),
      quantity: position_size(quantity),
      instrument_type: position_instrument(row["instrument_type"]),
      average_cost: decimal(row["average_cost"]),
      mark_price: decimal(row["mark_price"]),
      # Signed as the venue sent it: this is a value, not a magnitude with a side beside it.
      notional_value: decimal(row["notional_value"]),
      realised_pnl: decimal(row["realised_pnl"]),
      unrealised_pnl: decimal(row["unrealised_pnl"]),
      # Not published on this endpoint. `nil` is "not stated", never "no liquidation risk".
      liquidation_price: nil,
      leverage: nil,
      venue_time: at,
      provider: :gemini
    }
  end

  defp to_position(_row, at) do
    %Position{
      symbol: nil,
      side: nil,
      quantity: nil,
      venue_time: at,
      provider: :gemini
    }
  end

  # The contract types this as an atom, and the venue sends "spot" or "perp". A word this
  # package does not know is `nil` rather than the nearest atom that fits — an instrument
  # kind is what a caller routes on.
  defp position_instrument("perp"), do: :perp
  defp position_instrument("spot"), do: :spot
  defp position_instrument(_other), do: nil

  # A quantity of exactly zero has no side, and guessing one would invent a direction the
  # venue did not state.
  defp position_side(nil), do: nil

  defp position_side(quantity) do
    case Decimal.compare(quantity, Decimal.new(0)) do
      :lt -> :short
      :gt -> :long
      :eq -> nil
    end
  end

  defp position_size(nil), do: nil
  defp position_size(quantity), do: Decimal.abs(quantity)

  @doc """
  The perpetuals margin account — `POST /v1/margin`.

  Collateral, leverage, buying and selling power, and **the estimated liquidation price**,
  which `get_positions/2` does not publish. A caller judging how much room is left reads it
  here.

  Returned as the venue's own map. Its eleven fields divide margin four ways — by position,
  by open order, by buy side and by sell side — and a struct that kept only a total would
  drop the split a caller sizing its next order needs.
  """
  @spec get_account_margin(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_account_margin(credentials, opts) do
    params = put_present(%{}, "symbol", Keyword.get(opts, :symbol))

    with {:ok, body, _headers} <- post("/v1/margin", params, credentials, opts) do
      {:ok, body}
    end
  end

  @doc """
  Funding payments credited to or debited from this account —
  `POST /v1/perpetuals/fundingPayment`.

  **Not `get_funding/2`.** That is the contract's rate; this is what this account actually
  paid or received. A caller reconciling a balance needs the second, and computing it from
  the first plus a position size is this package's arithmetic rather than the venue's ledger.

  Rows are the venue's own. Each carries `action` — `Credit` or `Debit` — beside a positive
  quantity, so **the direction is in the action and not in the sign**. Normalising it into a
  signed number here would drop the venue's own word for it.

  The venue notes `instrumentSymbol` is attached only to records from 16 April 2024 onwards;
  older rows have none, and this package does not fill one in.
  """
  @spec list_funding_payments(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_funding_payments(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/perpetuals/fundingPayment", %{}, credentials, opts) do
      {:ok, body |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  The funding payment report as JSON —
  `/v1/perpetuals/fundingpaymentreport/records.json`.

  **The query string is part of what is signed.** Gemini's private GETs put the *full* path,
  query string included, in the signed `request` field; signing the bare path produces a
  valid signature over the wrong string, and the venue reports that as a credential problem
  rather than a parameter one. This builds the query once and uses the same string in both
  places.

  `opts[:from]` and `opts[:to]` are dates, `opts[:rows]` a count. The venue's own default is
  **8760 rows** — a year of hourly funding — and this package does not send one, because a
  page size chosen here would silently truncate a report the caller asked for in full.
  """
  @spec funding_payment_report(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def funding_payment_report(credentials, opts) do
    path = report_path("/v1/perpetuals/fundingpaymentreport/records.json", opts)

    with {:ok, body, _headers} <- signed_get(path, credentials, opts) do
      {:ok, body |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  The funding **amount** report as a spreadsheet —
  `/v1/fundingamountreport/records.xlsx`.

  Returns the venue's bytes unparsed, as `{:ok, binary}`. This package ships no spreadsheet
  reader and will not grow one: a parsed cell is a number this package chose from a layout
  the venue can change without notice, and the file is what the venue actually issued.

  `symbol` is required by the venue. `opts[:from]` and `opts[:to]` must be given **together
  or not at all** — the venue makes each mandatory if the other is present, and sending one
  alone is refused here rather than silently returning a differently-bounded report.
  """
  @spec funding_amount_report(String.t(), map(), keyword()) ::
          {:ok, binary()} | {:error, term()} | {:refused, term()}
  def funding_amount_report(symbol, credentials, opts) do
    with :ok <- both_dates_or_neither(opts) do
      path =
        report_path(
          "/v1/fundingamountreport/records.xlsx",
          Keyword.put(opts, :symbol, symbol)
        )

      signed_get_raw(path, credentials, opts)
    end
  end

  @doc """
  The funding **payment** report as a spreadsheet —
  `/v1/perpetuals/fundingpaymentreport/records.xlsx`.

  The same bytes-not-cells rule as `funding_amount_report/3`, and the same account scope as
  `funding_payment_report/2`. Takes no symbol: a funding payment belongs to the account, not
  to one contract.
  """
  @spec funding_payment_report_file(map(), keyword()) ::
          {:ok, binary()} | {:error, term()} | {:refused, term()}
  def funding_payment_report_file(credentials, opts) do
    with :ok <- both_dates_or_neither(opts) do
      path = report_path("/v1/perpetuals/fundingpaymentreport/records.xlsx", opts)
      signed_get_raw(path, credentials, opts)
    end
  end

  # The venue: "Mandatory if toDate is specified, else optional", and the same in reverse.
  # One alone comes back bounded by `numRows` instead of by the date the caller gave, which
  # is a real report over the wrong window.
  defp both_dates_or_neither(opts) do
    both_dates_present(Keyword.get(opts, :from), Keyword.get(opts, :to))
  end

  defp both_dates_present(nil, nil), do: :ok
  defp both_dates_present(nil, _to), do: {:error, :from_and_to_together}
  defp both_dates_present(_from, nil), do: {:error, :from_and_to_together}
  defp both_dates_present(_from, _to), do: :ok

  defp report_path(path, opts) do
    query =
      []
      |> maybe_param("symbol", Keyword.get(opts, :symbol))
      |> maybe_param("fromDate", report_date(Keyword.get(opts, :from)))
      |> maybe_param("toDate", report_date(Keyword.get(opts, :to)))
      |> maybe_param("numRows", Keyword.get(opts, :rows))
      |> Enum.reverse()

    case query do
      [] -> path
      pairs -> path <> "?" <> URI.encode_query(pairs)
    end
  end

  defp maybe_param(pairs, _name, nil), do: pairs
  defp maybe_param(pairs, name, value), do: [{name, to_string(value)} | pairs]

  defp report_date(%Date{} = date), do: Date.to_iso8601(date)
  defp report_date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()
  defp report_date(other), do: other

  @doc """
  The **spot** margin account summary — `POST /v1/margin/account`.

  Not `get_account_margin/2`: that one is the perpetuals account. These are two margin
  systems on one venue, and their fields are named differently on purpose — this one nests
  every amount as `%{"currency" => _, "value" => _}` where the perpetuals one sends bare
  decimals in dollars.

  Returned as the venue's own map for that reason. Flattening the currency off an amount is
  how a caller ends up adding a BTC number to a USD one.
  """
  @spec get_margin_account(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_margin_account(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/margin/account", %{}, credentials, opts) do
      {:ok, body}
    end
  end

  @doc """
  Margin interest rates for every borrowable asset — `POST /v1/margin/rates`.

  **Three rates per currency, and they are not three ways of saying one thing.** The venue
  publishes `borrowRate` hourly, `borrowRateDaily` as hourly × 24 and `borrowRateAnnual` as
  daily × 365, and all three travel: a caller that took the hourly rate for an annual one
  would be out by four orders of magnitude, and the number would still look like a rate.

  `lastUpdated` is milliseconds, and it matters — a borrow rate is a moving quote, not a
  schedule.
  """
  @spec get_margin_rates(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_margin_rates(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/margin/rates", %{}, credentials, opts) do
      {:ok, body |> margin_rate_rows() |> List.wrap()}
    end
  end

  defp margin_rate_rows(%{"rates" => rates}) when is_list(rates), do: rates
  defp margin_rate_rows(rates) when is_list(rates), do: rates
  defp margin_rate_rows(_other), do: []

  @doc """
  What a spot order would do to this account's margin — `POST /v1/margin/order/preview`.

  **Places nothing.** It returns the account's margin statistics before and after the
  hypothetical order, as `preorder` and `postorder`, and a caller reads the difference.

  `symbol`, `side` and `type` are required by the venue and are not defaulted here. The
  fourth parameter depends on the first three and the venue states which:
  **`amount` for a limit order or a market sell, `totalSpend` for a market buy**, and
  `price` for a limit order. Sending the wrong one is refused up front rather than sent —
  a preview computed against a quantity the caller did not mean is a number that looks
  right.
  """
  @spec preview_margin_order(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_margin_order(request, credentials, opts) do
    with {:ok, params} <- margin_preview_params(request) do
      with {:ok, body, _headers} <-
             post("/v1/margin/order/preview", params, credentials, opts) do
        {:ok, body}
      end
    end
  end

  defp margin_preview_params(%{symbol: symbol, side: side, type: type} = request)
       when is_binary(symbol) do
    base = %{
      "symbol" => SymbolFormat.to_exchange_symbol(symbol),
      "side" => to_string(side),
      "type" => to_string(type)
    }

    with {:ok, sized} <- margin_preview_size(base, to_string(type), to_string(side), request) do
      {:ok, put_present(sized, "price", decimal_string(Map.get(request, :price)))}
    end
  end

  defp margin_preview_params(_request), do: {:error, :missing_order_fields}

  # The venue's own rule, enforced rather than discovered: a market **buy** is sized in quote
  # currency and everything else in base. Sending `amount` on a market buy previews a
  # different order than the caller described.
  defp margin_preview_size(base, "market", "buy", request) do
    case decimal_string(Map.get(request, :total_spend)) do
      nil -> {:error, :total_spend_required}
      spend -> {:ok, Map.put(base, "totalSpend", spend)}
    end
  end

  defp margin_preview_size(base, "limit", _side, request) do
    with {:ok, amount} <- required_amount(request),
         {:ok, _price} <- required_preview_price(request) do
      {:ok, Map.put(base, "amount", amount)}
    end
  end

  defp margin_preview_size(base, _type, _side, request) do
    with {:ok, amount} <- required_amount(request), do: {:ok, Map.put(base, "amount", amount)}
  end

  # Not `required_price/1` above: that one reports `{:missing_field, :price}` for an order
  # this package is about to place, and this reports `:price_required` for a preview it is
  # about to describe. Two callers, two vocabularies, and merging them would report a
  # placement error on a call that places nothing.
  defp required_preview_price(request) do
    case decimal_string(Map.get(request, :price)) do
      nil -> {:error, :price_required}
      price -> {:ok, price}
    end
  end

  defp required_amount(request) do
    case decimal_string(Map.get(request, :amount)) do
      nil -> {:error, :amount_required}
      amount -> {:ok, amount}
    end
  end

  # Full notation, never scientific: `1E-8` is not a number this venue reads.
  defp decimal_string(nil), do: nil
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value), do: to_string(value)

  # --- account administration ---------------------------------------------

  @doc """
  Creates a subaccount — `POST /v1/account/create`.

  **`name` is a display name and the venue answers with a different string.** It returns
  `account`, a kebab-cased shortname derived from the name — spaces to hyphens, symbols
  removed, lower-cased — and **that shortname is what every other endpoint's `account`
  parameter takes**. A caller that kept the name it sent would address the wrong thing, or
  nothing.

  `opts[:type]` is `"exchange"` or `"custody"`, and the venue's own default when it is
  omitted is `exchange`. This package does not send one: choosing between an exchange
  account and a custody account for a caller who did not is choosing what the account can do.

  Requires the **Administrator** role.
  """
  @spec create_account(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def create_account(name, credentials, opts) when is_binary(name) do
    params = put_present(%{"name" => name}, "type", Keyword.get(opts, :type))

    with {:ok, body, _headers} <- post("/v1/account/create", params, credentials, opts),
         do: {:ok, body}
  end

  @doc """
  Renames a subaccount — `POST /v1/account/rename`.

  **Two different things can be renamed and they are not the same field.** `opts[:name]` is
  the display name; `opts[:shortname]` is the kebab-cased `account` string every other
  endpoint addresses by. Changing the second **changes how the account is addressed**, and a
  caller with a stored shortname will stop finding it.

  Either or both; neither is `{:error, :nothing_to_rename}` rather than a call that changes
  nothing and reports success. The venue returns only the fields that changed.

  `opts[:account]` names which subaccount to rename and is required on a master key.
  """
  @spec rename_account(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def rename_account(credentials, opts) do
    params =
      %{}
      |> put_present("account", Keyword.get(opts, :account))
      |> put_present("newName", Keyword.get(opts, :name))
      |> put_present("newAccount", Keyword.get(opts, :shortname))

    if Map.has_key?(params, "newName") or Map.has_key?(params, "newAccount") do
      with {:ok, body, _headers} <- post("/v1/account/rename", params, credentials, opts),
           do: {:ok, body}
    else
      {:error, :nothing_to_rename}
    end
  end

  @doc """
  Every subaccount in the group — `POST /v1/account/list`.

  **The venue caps this at 500 and does not paginate.** `limit_accounts` is both the maximum
  and the default, so a group with more than 500 subaccounts returns a truncated list with
  nothing to say it was truncated. This package sends no limit unless asked, and states the
  cap here because there is no cursor to follow.

  Each row's `account` is the kebab-cased shortname other endpoints address by; `name` is
  the display name. `counterparty_id` is `None` on a custody account — the venue's own
  string, not `nil`.
  """
  @spec list_accounts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_accounts(credentials, opts) do
    params =
      %{}
      |> put_present("limit_accounts", Keyword.get(opts, :limit))
      |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))

    with {:ok, body, _headers} <- post("/v1/account/list", params, credentials, opts) do
      {:ok, body |> List.wrap() |> List.flatten()}
    end
  end

  @doc """
  The roles this API key carries — `POST /v1/roles`.

  Returns the venue's own booleans: `isAuditor`, `isFundManager`, `isTrader`. **`Auditor`
  cannot be combined with the others**, and `Fund Manager` and `Trader` can — which is why
  three booleans rather than one role.

  This is the call that answers "will the venue let this key do that", and asking it is
  cheaper than discovering a missing role from a refused withdrawal.
  """
  @spec get_roles(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_roles(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/roles", %{}, credentials, opts), do: {:ok, body}
  end

  # --- OAuth token lifecycle ----------------------------------------------

  @doc """
  Exchanges a refresh token for a new access token —
  `POST https://exchange.gemini.com/auth/token`.

  **This is credential *use*, not consent.** The browser redirect that obtains the first
  authorization code belongs to the host and is not here; refreshing a token the host
  already holds is the same category as Schwab's `Auth.refresh/2`, and a package that could
  not do it would leave a consumer unable to keep a session alive.

  **A different host from every other endpoint** — `exchange.gemini.com`, not
  `api.gemini.com` — and a form body rather than Gemini's signed payload. It is the same URL
  the host's initial code exchange posts to, separated only by `grant_type`, which is why
  the package/host split cannot be read off a path.

  **The response carries a *new* refresh token and the old one stops working.** A caller
  that stores the access token and keeps the old refresh token has a session that ends at
  the next refresh.

  `client_secret` is sent only when given: the venue documents it for confidential clients
  and says public clients must not send it.
  """
  @spec refresh_access_token(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def refresh_access_token(client_id, refresh_token, opts)
      when is_binary(client_id) and is_binary(refresh_token) do
    form =
      %{
        "client_id" => client_id,
        "refresh_token" => refresh_token,
        "grant_type" => "refresh_token"
      }
      |> put_present("client_secret", Keyword.get(opts, :client_secret))

    url = Keyword.get(opts, :auth_url, "https://exchange.gemini.com") <> "/auth/token"
    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case HttpClient.request(:post, url, headers, URI.encode_query(form), request_opts(opts)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode(body)}

      {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
        {:refused, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:exchange_error, :gemini, "HTTP #{status}: #{inspect(body)}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Revokes an access token — `POST /v1/oauth/revokeByToken`.

  **Only reachable with an OAuth token**, not with an API key: the endpoint revokes the
  token that authenticates the call. A credential map without `access_token` is refused here
  rather than sent, because an API-key-signed call would revoke nothing and report success
  shape.

  Once revoked the token cannot be used again, and neither can any request already in
  flight that had not reached the venue.
  """
  @spec revoke_access_token(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def revoke_access_token(credentials, opts) do
    case credentials do
      %{access_token: token} when is_binary(token) ->
        with {:ok, body, _headers} <-
               post(
                 "/v1/oauth/revokeByToken",
                 %{},
                 credentials,
                 Keyword.put(opts, :auth_scheme, :oauth)
               ),
             do: {:ok, body}

      _other ->
        {:error, :oauth_token_required}
    end
  end

  # --- clearing -----------------------------------------------------------

  @doc """
  Creates a bilateral clearing order — `POST /v1/clearing/new`.

  **This is not `place_order/3`.** A clearing order does not go to the book: it is one half
  of a trade agreed directly with a named counterparty, and it does nothing until that
  counterparty confirms it. A caller that treated a successful response as a fill has a
  position it does not have.

  `symbol`, `amount`, `price` and `side` are required by the venue and are not defaulted.
  `opts[:counterparty_id]` names the other side; `opts[:expires_in_hrs]` bounds how long the
  offer stands.

  **`is_confirmed` on the response is the field that matters.** `false` means the trade has
  not happened; the order sits until the counterparty confirms it or it expires.
  """
  @spec create_clearing_order(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def create_clearing_order(request, credentials, opts) do
    with {:ok, params} <- clearing_order_params(request) do
      params =
        params
        |> put_present("counterparty_id", Keyword.get(opts, :counterparty_id))
        |> put_present("expires_in_hrs", Keyword.get(opts, :expires_in_hrs))

      with {:ok, body, _headers} <- post("/v1/clearing/new", params, credentials, opts),
           do: {:ok, body}
    end
  end

  @doc """
  Submits a **broker-facilitated** clearing order — `POST /v1/clearing/broker/new`.

  Not `create_clearing_order/3`: a broker order names **both** counterparties and the broker
  is neither of them. `opts[:source_counterparty_id]` and `opts[:target_counterparty_id]` are
  both required, and so is `opts[:expires_in_hrs]` — the venue marks it required here where
  it is optional on the bilateral form.

  **`side` is assigned to the source**, and the opposite side goes to the target. Passing the
  two counterparties the wrong way round produces a valid order in which each side is trading
  the direction the other meant.

  The venue answers `AwaitSourceTargetConfirm`: **both** parties still have to confirm.
  """
  @spec create_broker_clearing_order(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def create_broker_clearing_order(request, credentials, opts) do
    with {:ok, params} <- clearing_order_params(request),
         {:ok, source} <- required_opt(opts, :source_counterparty_id),
         {:ok, target} <- required_opt(opts, :target_counterparty_id),
         {:ok, hours} <- required_opt(opts, :expires_in_hrs) do
      params =
        params
        |> Map.put("source_counterparty_id", source)
        |> Map.put("target_counterparty_id", target)
        |> Map.put("expires_in_hrs", hours)

      with {:ok, body, _headers} <- post("/v1/clearing/broker/new", params, credentials, opts),
           do: {:ok, body}
    end
  end

  @doc """
  One clearing order's state — `POST /v1/clearing/status`.

  **Read `is_confirmed`, not `status`.** The status string is the venue's own description and
  the boolean is the fact: an order that is not confirmed has not traded, whatever the
  description says.
  """
  @spec get_clearing_order(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_clearing_order(clearing_id, credentials, opts) when is_binary(clearing_id) do
    with {:ok, body, _headers} <-
           post("/v1/clearing/status", %{"clearing_id" => clearing_id}, credentials, opts),
         do: {:ok, body}
  end

  @doc """
  Cancels a clearing order — `POST /v1/clearing/cancel`.

  Only an unconfirmed order can be cancelled; once both sides have confirmed there is a
  trade, and a trade is not cancellable. The venue's `result` and `details` both travel,
  because `details` is where it says why a cancel did not take.
  """
  @spec cancel_clearing_order(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def cancel_clearing_order(clearing_id, credentials, opts) when is_binary(clearing_id) do
    with {:ok, body, _headers} <-
           post("/v1/clearing/cancel", %{"clearing_id" => clearing_id}, credentials, opts),
         do: {:ok, body}
  end

  @doc """
  Confirms a clearing order — `POST /v1/clearing/confirm`. **This executes a trade.**

  **The venue re-asks for every term.** `symbol`, `amount`, `price` and `side` are required
  alongside the `clearing_id`, and this package does not fill any of them in from the order
  it is confirming: the point of re-stating them is that the confirming side says what it
  believes it is agreeing to, and a package that read them back from the venue would confirm
  whatever the venue had, which is the one thing the check exists to prevent.

  `side` here is **the confirming party's own side**, which is the opposite of the side the
  order was created with.
  """
  @spec confirm_clearing_order(String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def confirm_clearing_order(clearing_id, request, credentials, opts)
      when is_binary(clearing_id) do
    with {:ok, params} <- clearing_order_params(request) do
      params = Map.put(params, "clearing_id", clearing_id)

      with {:ok, body, _headers} <- post("/v1/clearing/confirm", params, credentials, opts),
           do: {:ok, body}
    end
  end

  @doc """
  Clearing orders this account is party to — `POST /v1/clearing/list`.

  Every filter is optional and none is defaulted: `opts[:symbol]`, `opts[:counterparty]`
  (which takes an id **or** an alias), `opts[:side]`, and four timestamp bounds —
  `expiration_start`, `expiration_end`, `submission_start` and `submission_end`.

  **Expiration and submission are different windows.** An order submitted last week can
  expire tomorrow, and filtering on the wrong one returns a real list that is not the one
  asked for.
  """
  @spec list_clearing_orders(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_clearing_orders(credentials, opts) do
    params =
      %{}
      |> put_present("symbol", clearing_symbol(Keyword.get(opts, :symbol)))
      |> put_present("counterparty", Keyword.get(opts, :counterparty))
      |> put_present("side", clearing_side(Keyword.get(opts, :side)))
      |> put_present("expiration_start", timestamp_param(Keyword.get(opts, :expiration_start)))
      |> put_present("expiration_end", timestamp_param(Keyword.get(opts, :expiration_end)))
      |> put_present("submission_start", timestamp_param(Keyword.get(opts, :submission_start)))
      |> put_present("submission_end", timestamp_param(Keyword.get(opts, :submission_end)))

    with {:ok, body, _headers} <- post("/v1/clearing/list", params, credentials, opts) do
      {:ok, body |> clearing_rows("orders") |> List.wrap()}
    end
  end

  @doc """
  Broker clearing orders — `POST /v1/clearing/broker/list`.

  Separate from `list_clearing_orders/2` because the rows are a different shape: a broker
  order names a **source** and a **target** counterparty and a `source_side`, where a
  bilateral order names one counterparty and one side. Merging the two would leave a caller
  reading `side` on a row that has none.
  """
  @spec list_clearing_brokers(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_clearing_brokers(credentials, opts) do
    params =
      %{}
      |> put_present("symbol", clearing_symbol(Keyword.get(opts, :symbol)))
      |> put_present("expiration_start", timestamp_param(Keyword.get(opts, :expiration_start)))
      |> put_present("expiration_end", timestamp_param(Keyword.get(opts, :expiration_end)))

    with {:ok, body, _headers} <- post("/v1/clearing/broker/list", params, credentials, opts) do
      {:ok, body |> clearing_rows("orders") |> List.wrap()}
    end
  end

  @doc """
  Clearing trades — `POST /v1/clearing/trades`.

  Orders that **completed**, where `list_clearing_orders/2` shows what is outstanding. Rows
  are camelCase here and snake_case there; the venue's own keys are kept either way rather
  than normalised into one shape that matches neither response.

  `opts[:limit]` maps to the venue's `limit_per_account` — default 100, maximum 300 — and
  `opts[:since_nanos]` to `timestamp_nanos`, which is **nanoseconds**, not the milliseconds
  every other Gemini timestamp uses.
  """
  @spec list_clearing_trades(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_clearing_trades(credentials, opts) do
    params =
      %{}
      |> put_present("symbol", clearing_symbol(Keyword.get(opts, :symbol)))
      |> put_present("timestamp_nanos", Keyword.get(opts, :since_nanos))
      |> put_present("limit_per_account", Keyword.get(opts, :limit))

    with {:ok, body, _headers} <- post("/v1/clearing/trades", params, credentials, opts) do
      {:ok, body |> clearing_rows("results") |> List.wrap()}
    end
  end

  # The four terms the venue requires on every clearing write, and none of them defaulted.
  defp clearing_order_params(%{symbol: symbol, amount: amount, price: price, side: side})
       when is_binary(symbol) do
    {:ok,
     %{
       "symbol" => SymbolFormat.to_exchange_symbol(symbol),
       "amount" => decimal_string(amount),
       "price" => decimal_string(price),
       "side" => to_string(side)
     }}
  end

  defp clearing_order_params(_request), do: {:error, :missing_clearing_terms}

  defp clearing_symbol(nil), do: nil
  defp clearing_symbol(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  defp clearing_side(nil), do: nil
  defp clearing_side(side), do: to_string(side)

  defp clearing_rows(%{} = body, key) do
    case Map.get(body, key) do
      rows when is_list(rows) -> rows
      _other -> []
    end
  end

  defp clearing_rows(rows, _key) when is_list(rows), do: rows
  defp clearing_rows(_body, _key), do: []
  # --- shared helpers -----------------------------------------------------

  defp venue_time(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == "date", do: value
    end)
    |> case do
      [value | _rest] -> parse_http_date(value)
      value when is_binary(value) -> parse_http_date(value)
      _other -> {:error, :missing_venue_timestamp}
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_http_date(value) when is_binary(value) do
    with [_day, d, mon, y, time, _tz] <- String.split(value, [" ", ", "], trim: true),
         {day, ""} <- Integer.parse(d),
         {year, ""} <- Integer.parse(y),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == mon)),
         [h, m, s] <- String.split(time, ":"),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(m),
         {second, ""} <- Integer.parse(s),
         {:ok, naive} <- NaiveDateTime.new(year, month + 1, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _other -> {:error, :missing_venue_timestamp}
    end
  end

  defp parse_http_date(_other), do: {:error, :missing_venue_timestamp}

  defp epoch_ms(nil), do: nil

  # A float reaches here whenever the venue's encoder emits one — JSON has a single
  # number type, so 1.787936147e12 and 1787936147000 are the same instant. Without this
  # clause the order simply had no timestamp, silently.
  defp epoch_ms(value) when is_float(value), do: epoch_ms(trunc(value))

  defp epoch_ms(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      _error -> nil
    end
  end

  defp epoch_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> epoch_ms(integer)
      :error -> nil
    end
  end

  defp epoch_ms(_other), do: nil

  # Delegated to `Rest.refusal_reason/1` rather than duplicated. This was a second, exact
  # copy of the same `String.to_atom/1` on venue-supplied text, so the atom-table DoS it
  # carried had to be found and fixed twice — and could as easily have been fixed in only
  # one of the two. One implementation, one place to get it right.
  defp refusal(body), do: Rest.refusal_reason(decode(body))

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode(body), do: body

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  defp take_params(opts, keys) do
    opts
    |> Keyword.take(keys)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.new/1` raises on a string that is not a number. `Decimal.parse/1`, requiring
  # the whole string be consumed (`{d, ""}`), is what this package already does in
  # `ws_decode.ex`; every copy of this helper now matches it.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> parsed
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil
end
