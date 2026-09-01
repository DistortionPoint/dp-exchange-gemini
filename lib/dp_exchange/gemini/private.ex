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
  alias DpExchange.Core.Types.{Balance, Conversion, Fill, Order}
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
    Decimal.sub(Decimal.new(amount), Decimal.new(available))
  end

  defp hold(_row), do: nil

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

  Two directions and two endpoints, and they are not symmetric:

      list_networks("USDC", [])          public,  GET /v2/network/USDC
      list_networks(nil, network: "…")   private, /v2/networks/{network}/assets

  **The second is scoped to the credential and the first is not.** The vendor requires the
  Fund Manager or Auditor role and states it returns *"only the assets where your account
  has deposit and withdraw access enabled"*. So an empty answer means **this account cannot
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
               post("/v2/networks/#{network}/assets", %{}, credentials, opts) do
          {:ok, List.wrap(body)}
        end
    end
  end

  def list_networks(asset, opts), do: Rest.networks_for_asset(asset, opts)
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

  defp refusal(body) do
    case decode(body) do
      %{"reason" => reason} -> String.to_atom(Macro.underscore(reason))
      _other -> :refused
    end
  end

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
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
end
