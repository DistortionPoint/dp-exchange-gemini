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
  | (none — an ORDER TYPE: `order_type: :post_only`, alias `:maker_or_cancel`) | `maker-or-cancel` | adds liquidity only, cancels if it would take |
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

  ## History reads check their options before signing

  `:limit` (`:limit_transfers` on `get_transfers/2`) is a whole number from 1 to the venue's
  maximum for that endpoint, and a window bound (`:since`, `:timestamp`, `:to`,
  `:since_nanos`) a `DateTime`, a non-negative integer or a string of digits. Anything else —
  `limit: 0`, `limit: "ten"`, `since: ~D[2026-01-01]` — is
  `{:error, {:invalid_option, key, value}}`, from `validate_history_opts/2`, which
  `DpExchange.Gemini.Fake` runs too. Each used to go on the wire as given: a venue 400 read
  as a credential problem, or a filter that silently narrowed nothing.

  ## A write is sent once unless the venue can tell the repeat

  See `post_once/4`'s comment. Besides orders, transfers and staking, that now covers a
  conversion commit, a clearing confirm and cancel, an account rename and a token revoke: a
  repeat of any of them, signed with a fresh nonce, is answered as a refusal for something
  that worked.
  """

  alias DpExchange.Core.{Config, HttpClient}

  alias DpExchange.Core.Types.{
    ApprovedAddress,
    Balance,
    Conversion,
    DepositAddress,
    Fill,
    FxRate,
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
      to_balances(rows, timestamp)
    end
  end

  @doc "The account's own record of itself — name, type, and the roles the key carries."
  @spec get_accounts(map(), keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/account", %{}, credentials, opts) do
      object_rows(body)
    end
  end

  # The vendor's 200 for `/v1/account` and the two network lookups is ONE object, so one
  # object is one row honestly; a list of objects is accepted as the rows it is. Anything
  # else is unreadable. `List.wrap/1` stood here: it turned a JSON `null` into `[]` ("this
  # account has no record of itself", "this account cannot move anything on that network")
  # and a bare string or number into a one-row list holding it. Both are plausible answers
  # the venue never gave.
  defp object_rows(%{} = body), do: {:ok, [body]}

  defp object_rows(rows) when is_list(rows) do
    if Enum.all?(rows, &is_map/1), do: {:ok, rows}, else: {:error, :unexpected_response_shape}
  end

  defp object_rows(_unreadable), do: {:error, :unexpected_response_shape}

  @doc """
  The fee tier this account trades at, from `/v1/notionalvolume`.

  Returned as the venue states it — basis points, per maker/taker, alongside the notional
  volume that determined the tier. Nothing is converted to a rate, because the venue's own
  units are what a caller will reconcile against.

  ## `opts[:symbol]` — where fee promotions live now

  The vendor's current OpenAPI document gives this operation an optional `symbol`, described
  in its own words as "The symbol to get fee promotions or specific fee schedule rates for",
  with a worked example named `withSymbol` whose summary is "Request with symbol parameter
  for fee promotions".

  That matters because `GET /v1/feepromos` — the public path `Rest.list_fee_promos/1` calls
  — **vanished from that specification**, found by `script/check_endpoint_inventory.sh` on
  2026-09-21. On this venue absence is the announcement: it removes things with no changelog
  entry. So the capability did not disappear, it moved, and it moved from a public path to
  this authenticated one.

  **Read from the specification, not probed.** This repository holds no Gemini credentials
  and tier-3 tests are not run here, so what is claimed is exactly what the vendor's document
  says and no more. Passing no `:symbol` sends the same empty payload it always did.
  """
  @spec get_fees(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_fees(credentials, opts) do
    params =
      case Config.opt(opts, :symbol, nil) do
        symbol when is_binary(symbol) -> %{"symbol" => SymbolFormat.to_exchange_symbol(symbol)}
        _absent -> %{}
      end

    # The vendor's 200 is one `NotionalVolume` object. A `null`, string or list is not a fee
    # schedule, and handing it back inside `{:ok, _}` is a fee tier nobody stated.
    with {:ok, body, _headers} <- post("/v1/notionalvolume", params, credentials, opts) do
      Rest.object(body)
    end
  end

  @transfers_page_max 50

  @doc """
  Transfers in and out of the account.

  Calls **`/v2/transfers`**. The v1 path this package used until the D6 migration is absent
  from Gemini's published OpenAPI document, and v2's own description says why: *"The v1
  transfers endpoint is being retired. This v2 endpoint is the recommended"* replacement.

  The three parameters are unchanged — `currency`, `timestamp`, `limit_transfers` — so this
  was a path swap and nothing more. v2 additionally accepts `network` (passed through when
  given), `account` (see `opts[:account]`) and `show_completed_deposit_advances`, and each
  returned transfer now carries a `network` field naming the chain; the rows are passed
  through. `:timestamp` may be a `DateTime`, sent as milliseconds, or the venue's own number.

  **A full page with no `:limit_transfers` is refused, not returned as the whole history.**
  The venue's page is 10 rows by default and 50 at most (`rest.yaml:3267`), and it carries no
  cursor, so the first 10 transfers were answered as the account's complete ledger while every
  later one was dropped. With no `:limit_transfers` this asks for the maximum, 50, and a page
  that full is `{:error, {:history_truncated, 50}}` — narrow with `:timestamp`, or pass
  `:limit_transfers` to take exactly one page on purpose. The same rule `get_orders/2` and
  `get_trade_history/2` apply.
  """
  @spec get_transfers(map(), keyword()) :: {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transfers(credentials, opts) do
    with :ok <- validate_history_opts(:transfers, opts) do
      fetch_transfers(credentials, opts)
    end
  end

  defp fetch_transfers(credentials, opts) do
    # `timestamp` is the venue's own unit, milliseconds (`TimestampType`, rest.yaml). A
    # `DateTime` handed through unconverted was JSON-encoded as an ISO string, a shape the
    # filter does not parse, so the window silently failed to narrow anything. `network` is
    # the venue's chain filter (`/v2/transfers` request schema).
    params =
      opts
      |> take_params([:limit_transfers, :currency, :network, :timestamp])
      |> Map.update("timestamp", nil, &timestamp_param/1)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.put_new("limit_transfers", @transfers_page_max)

    # `Rest.list/1`, not `List.wrap/1`. The vendor's OpenAPI document gives this endpoint's
    # 200 as `type: array` of `V2Transfer` — never an object — so an object here is not a
    # transfer, and `List.wrap/1` handed it back as one: the same wrapper-as-row defect
    # `dp_exchange_webull`'s `rows/1` had. `list_networks/2` reads its reply with
    # `object_rows/1` because ITS documented 200 is a single object (`NetworkAssets`), which
    # is one row honestly, and anything else is unreadable rather than wrapped.
    with {:ok, body, _headers} <- post("/v2/transfers", params, credentials, opts),
         {:ok, rows} <- Rest.list(body),
         :ok <- transfers_complete(rows, Keyword.get(opts, :limit_transfers)) do
      {:ok, rows}
    end
  end

  defp transfers_complete(rows, requested_limit) do
    if requested_limit == nil and length(rows) >= @transfers_page_max,
      do: {:error, {:history_truncated, @transfers_page_max}},
      else: :ok
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
    * a `:symbol` that is not a non-blank string — `{:error, {:invalid_symbol, symbol}}` — and
      a `:client_order_id` that is neither a non-blank string nor an integer —
      `{:error, {:invalid_client_order_id, id}}`
    * a `:side` other than `:buy` / `:sell` — `{:error, {:invalid_side, side}}`
    * a `:quantity`, `:price` or `:stop_price` that is not a finite number above zero —
      `{:error, {:invalid_decimal, field, value}}` or
      `{:error, {:non_positive_amount, field, value}}`. Numbers go out in plain notation,
      never scientific, whatever shape the caller held them in
    * a `:stop_limit` with no `:stop_price` (`{:error, {:missing_field, :stop_price}}`), and a
      `:stop_price` on any other type (`{:error, {:unexpected_field, :stop_price}}`) — the
      venue's trigger price exists only on a stop-limit order
  """
  @spec place_order(map(), map(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, terms} <- order_terms(request) do
      %{
        type: type,
        options: options,
        price: price,
        symbol: symbol,
        quantity: quantity,
        side: side,
        stop_price: stop_price,
        client_order_id: client_order_id
      } = terms

      params =
        %{
          "symbol" => SymbolFormat.to_exchange_symbol(symbol),
          "amount" => quantity,
          "price" => price,
          "side" => side,
          "type" => type,
          "options" => options
        }
        |> put_present("stop_price", stop_price)
        |> maybe_put("client_order_id", client_order_id)
        |> maybe_put("account", Keyword.get(opts, :account))

      with {:ok, body, _headers} <- post_once("/v1/order/new", params, credentials, opts) do
        # A placed order whose id the venue did not return readably stays
        # `{:ok, %Order{id: nil}}`. It was made `{:error, :order_id_not_returned}` on
        # 2026-10-10 and reverted the same day: the venue accepted the order, an error reads
        # as "nothing was placed", and since this venue's `client_order_id` is no idempotency
        # key, a caller retrying on it places a second order. Coinbase keeps the same rule.
        to_order(body, :lenient)
      end
    end
  end

  @doc """
  Whether `request` would be sent by `place_order/3`, checked without sending it.

  This is the validation `place_order/3` runs before it signs anything — the order type and
  time in force, then the price, then `:symbol`, `:quantity` and `:side`, then that the side
  is `buy` or `sell`, the stop price agrees with the order type, and `:quantity`, `:price`
  and `:stop_price` are finite numbers above zero — in that order and with those error
  shapes. It is exposed so `DpExchange.Gemini.Fake` refuses with this exact
  function rather than a second copy of the rules.
  """
  @spec validate_order(map()) :: :ok | {:error, term()}
  def validate_order(request) do
    with {:ok, _terms} <- order_terms(request), do: :ok
  end

  # The values `place_order/3` sends, or the first refusal. Named refusals, not
  # `Map.fetch!/2`: a `KeyError` raised in the caller's process on a money-moving call, where
  # every other missing field is an `{:error, _}`.
  defp order_terms(request) do
    with {:ok, {type, options}} <-
           order_wire(
             Map.get(request, :order_type, :limit),
             Map.get(request, :time_in_force, :gtc)
           ),
         {:ok, price} <- required_price(request),
         {:ok, symbol} <- required_field(request, :symbol),
         {:ok, symbol} <- order_symbol_arg(symbol),
         {:ok, quantity} <- required_field(request, :quantity),
         {:ok, side} <- required_field(request, :side),
         {:ok, side} <- wire_side(side),
         {:ok, stop_price} <- stop_price_for(type, Map.get(request, :stop_price)),
         {:ok, quantity} <- wire_positive(quantity, :quantity),
         {:ok, price} <- wire_positive(price, :price),
         {:ok, client_order_id} <- client_order_id_for(Map.get(request, :client_order_id)) do
      {:ok,
       %{
         type: type,
         options: options,
         price: price,
         symbol: symbol,
         quantity: quantity,
         side: side,
         stop_price: stop_price,
         client_order_id: client_order_id
       }}
    end
  end

  # A symbol is a non-blank string. `SymbolFormat.to_exchange_symbol/1` raised in the caller's
  # process on an atom or a number, and wrote the empty string into the order for `""`.
  defp order_symbol_arg(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "",
      do: {:error, {:invalid_symbol, symbol}},
      else: {:ok, symbol}
  end

  defp order_symbol_arg(other), do: {:error, {:invalid_symbol, other}}

  # **A client order id is a string or a whole number, or it is refused.** It went to
  # `to_string/1`, which raised `Protocol.UndefinedError` in the caller's process on a map
  # or a tuple of a live order and wrote an empty string for `""`. Absent stays absent. Whether
  # the venue treats `""` as absent is unmeasured, so a blank id is refused, not guessed at.
  defp client_order_id_for(nil), do: {:ok, nil}
  defp client_order_id_for(id) when is_integer(id), do: {:ok, id}

  defp client_order_id_for(id) when is_binary(id) do
    if String.trim(id) == "",
      do: {:error, {:invalid_client_order_id, id}},
      else: {:ok, id}
  end

  defp client_order_id_for(other), do: {:error, {:invalid_client_order_id, other}}

  # **A side the venue does not know is refused, not sent.** `to_string/1` put whatever the
  # caller held on the wire of a live order (`:hold`, `"BUY "`, a number). Only `buy` and
  # `sell` exist (`NewOrderRequest.side`).
  defp wire_side(side) when side in [:buy, "buy"], do: {:ok, "buy"}
  defp wire_side(side) when side in [:sell, "sell"], do: {:ok, "sell"}
  defp wire_side(other), do: {:error, {:invalid_side, other}}

  # **`stop_price` belongs to a stop-limit order and to nothing else.** The vendor: "The
  # price to trigger a stop-limit order. Only available for stop-limit orders." Sending one
  # on a plain limit order risks an order that rests or fills at once instead of waiting for
  # the trigger the caller named, which is a fill at a price nobody chose; a stop-limit with
  # no trigger is not an order the venue can describe. Both are refused before signing.
  defp stop_price_for("exchange stop limit", nil), do: {:error, {:missing_field, :stop_price}}
  defp stop_price_for("exchange stop limit", stop), do: wire_positive(stop, :stop_price)
  defp stop_price_for(_type, nil), do: {:ok, nil}
  defp stop_price_for(_type, _stop), do: {:error, {:unexpected_field, :stop_price}}

  # **A number that reaches a live exchange is checked first.** These went out through
  # `decimal_string/1`, which is `to_string/1` for anything but a `Decimal`: `"abc"` and a
  # `Decimal` NaN or Infinity were sent as the quantity of an order, `-1` and `0` as a
  # price, and a float as `"1.0e-8"`. The venue refuses most of those, but "most" is not a
  # property to leave to a money-moving call, and the refusal read as a venue fault.
  #
  # Returns the plain-notation string the wire carries (never scientific), or the named
  # refusal. A float is taken through its shortest round-trip representation, which is what
  # its author typed. Zero and negatives are `:non_positive_amount`: no order, transfer or
  # conversion this package makes has a meaning at or below zero.
  defp wire_positive(value, field) do
    with {:ok, number} <- wire_decimal(value, field) do
      if Decimal.positive?(number),
        do: {:ok, Decimal.to_string(number, :normal)},
        else: {:error, {:non_positive_amount, field, value}}
    end
  end

  # A fee may honestly be zero (`/v1/wrap`'s own example is `"fee": "0"`), but never negative.
  defp wire_non_negative(value, field) do
    with {:ok, number} <- wire_decimal(value, field) do
      if Decimal.negative?(number),
        do: {:error, {:negative_amount, field, value}},
        else: {:ok, Decimal.to_string(number, :normal)}
    end
  end

  defp wire_decimal(value, field) do
    case wire_number(value) do
      {:ok, number} -> {:ok, number}
      :error -> {:error, {:invalid_decimal, field, value}}
    end
  end

  defp wire_number(value) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp wire_number(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  # NaN, Infinity and an exponent no amount has are refused. The last matters here as it does
  # for a venue string: `Decimal.to_string(1E999999999, :normal)` writes a billion digits into
  # the request this package is about to sign.
  defp wire_number(%Decimal{} = value) do
    case bounded(value) do
      nil -> :error
      bounded -> {:ok, bounded}
    end
  end

  defp wire_number(value) when is_binary(value) do
    case decimal(value) do
      nil -> :error
      parsed -> {:ok, parsed}
    end
  end

  defp wire_number(_other), do: :error

  @doc """
  Cancels one order by the venue's order id.

  The id is the string this package returned and is sent as the unsigned 64-bit integer the
  venue's schema names. One that is not a whole number in that range is
  `{:error, {:invalid_order_id, id}}`, before anything is signed.
  """
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, order_id, opts) do
    with {:ok, wire_id} <- order_id_param(order_id),
         {:ok, body, _headers} <-
           post_once("/v1/order/cancel", %{"order_id" => wire_id}, credentials, opts) do
      to_order(body)
    end
  end

  @doc """
  One order's current state.

  `order_id` is the venue's id as this package returned it (a string) and goes out as the
  integer the venue's request schema names — see `cancel_order/3`'s id handling.
  """
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, order_id, opts) do
    with {:ok, wire_id} <- order_id_param(order_id),
         {:ok, body, _headers} <-
           post("/v1/order/status", %{"order_id" => wire_id}, credentials, opts) do
      to_order(body)
    end
  end

  # `order_id` is `type: integer, format: int64` in both `CancelOrderRequest` and
  # `OrderStatusRequest` (rest.yaml, "transmitted as an unsigned 64-bit integer in JSON
  # format"), while every order id THIS package hands a caller is a string (`order_id/1`).
  # The string went to the venue unconverted, a JSON string where the schema names a number.
  # Parsed back here, and refused, never guessed, when it is not a whole number in the
  # unsigned 64-bit range: an id the venue cannot have issued names no order, and a cancel
  # for it is a request with nothing to act on.
  @max_order_id 18_446_744_073_709_551_615

  @doc """
  Parses an order id into the unsigned 64-bit integer the venue's schema names.

  Public so `DpExchange.Gemini.Fake` refuses exactly what the real `cancel_order/3` and
  `get_order/3` refuse, from one implementation. A string of digits (or an integer) in
  `0..18_446_744_073_709_551_615` is `{:ok, integer}`; anything else is
  `{:error, {:invalid_order_id, id}}`.
  """
  @spec order_id_param(term()) ::
          {:ok, non_neg_integer()} | {:error, {:invalid_order_id, term()}}
  def order_id_param(id) when is_integer(id) and id >= 0 and id <= @max_order_id,
    do: {:ok, id}

  # Digits only. `Integer.parse/1` also reads `"+5"` and `"-0"` as whole numbers, and an id
  # with a sign is not one this package ever returned: it is refused, not normalised.
  def order_id_param(id) when is_binary(id) do
    with true <- String.match?(id, ~r/\A[0-9]+\z/),
         {value, ""} when value <= @max_order_id <- Integer.parse(id) do
      {:ok, value}
    else
      _not_an_order_id -> {:error, {:invalid_order_id, id}}
    end
  end

  def order_id_param(other), do: {:error, {:invalid_order_id, other}}

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
    with :ok <- validate_history_opts(:orders, opts) do
      fetch_orders(credentials, opts)
    end
  end

  defp fetch_orders(credentials, opts) do
    {path, params} =
      if Keyword.get(opts, :history, false) do
        {"/v1/orders/history", history_params(opts)}
      else
        {"/v1/orders", %{}}
      end

    with {:ok, rows, _headers} <- post(path, params, credentials, opts),
         {:ok, rows} <- list_rows(rows),
         :ok <- complete_page(rows, path == "/v1/orders/history", opts) do
      rows
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

  # **A full page with no `:limit` is refused, not returned as the whole history.** Both
  # history endpoints answered one page, the venue's default of 50 rows, and every row past
  # it was dropped while the call reported success. The vendor's own paging recipe for
  # `/v1/orders/history` (rest.yaml:1436-1443) contradicts itself on direction and has not
  # been probed, so this does not walk pages on a guess. It asks for the documented maximum,
  # 500, and a page that full says there may be more: narrow with `:since`, or pass `:limit`
  # to take exactly one page on purpose.
  @history_page_max 500

  defp history_params(opts) do
    %{}
    |> put_present("symbol", symbol_param(Keyword.get(opts, :symbol)))
    |> put_present("limit_orders", Keyword.get(opts, :limit) || @history_page_max)
    |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))
  end

  defp complete_page(_rows, false, _opts), do: :ok

  defp complete_page(rows, true, opts) do
    if Keyword.get(opts, :limit) == nil and length(rows) >= @history_page_max,
      do: {:error, {:history_truncated, @history_page_max}},
      else: :ok
  end

  defp symbol_param(nil), do: nil
  defp symbol_param(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  # The paging and window options of the history reads, by read. **Checked before anything is
  # signed**, and by the one function `DpExchange.Gemini.Fake` calls too.
  #
  # These went onto the wire as given. `limit: "ten"` was a venue 400 read as a credential
  # problem; `limit: 0` asked the venue for a page size it never describes; `since: ~D[...]`
  # was JSON-encoded as an ISO string where `timestamp` takes an epoch number, so the filter
  # silently failed to narrow anything; and `symbol: :btcusd` raised in the caller. The
  # maxima are the vendor's own (`limit_orders` and `limit_trades` 500, `limit_transfers` 50,
  # `limit_accounts` 500, staking `limit` 500, `limit_per_account` 300, `/v1/transactions`
  # `limit` 300). What the venue does with a larger value is not documented, so it is refused,
  # not clamped here.
  @history_specs %{
    orders: [symbol: :symbol, limit: {:limit, 500}, since: :epoch],
    trades: [symbol: :symbol, limit: {:limit, 500}, since: :epoch],
    transfers: [
      currency: :symbol,
      network: :symbol,
      limit_transfers: {:limit, 50},
      timestamp: :epoch
    ],
    custody_fees: [limit: {:limit, 50}, since: :epoch],
    accounts: [limit: {:limit, 500}, since: :epoch],
    staking_history: [limit: {:limit, 500}, since: :iso, until: :iso, provider_id: :symbol],
    staking_rewards: [since: :iso, until: :iso, provider_id: :symbol],
    clearing_trades: [symbol: :symbol, limit: {:limit, 300}, since_nanos: :epoch],
    clearing_orders: [
      symbol: :symbol,
      counterparty: :symbol,
      side: :side,
      expiration_start: :epoch,
      expiration_end: :epoch,
      submission_start: :epoch,
      submission_end: :epoch
    ],
    clearing_brokers: [symbol: :symbol, expiration_start: :epoch, expiration_end: :epoch],
    transactions: [limit: {:limit, 300}, since: :epoch],
    funding_payments: [since: :epoch, to: :epoch]
  }

  @typedoc "Which history read `validate_history_opts/2` checks the options of."
  @type history_read ::
          :orders
          | :trades
          | :transfers
          | :custody_fees
          | :accounts
          | :staking_history
          | :staking_rewards
          | :clearing_trades
          | :clearing_orders
          | :clearing_brokers
          | :transactions
          | :funding_payments

  @doc """
  Whether the paging and window options of a history read are ones its endpoint takes.

  `:limit` (`:limit_transfers` for transfers) is a whole number from 1 to the venue's maximum
  for that endpoint; `:since`, `:timestamp`, `:to` and `:since_nanos` a `DateTime`, a
  non-negative integer or a string of digits; the staking windows a `DateTime` or an ISO 8601
  string; `:symbol`, `:currency`, `:network`, `:counterparty` and `:provider_id` a non-blank
  string; a clearing `:side` `:buy` or `:sell`. Anything else is
  `{:error, {:invalid_option, key, value}}`. `nil` is absent.

  `:orders` checks only a `history: true` read: the resting-orders endpoint takes none of
  them. Exposed so `DpExchange.Gemini.Fake` refuses with this function, before the credential.
  """
  @spec validate_history_opts(history_read(), keyword()) ::
          :ok | {:error, {:invalid_option, atom(), term()}}
  def validate_history_opts(:orders, opts) do
    if Keyword.get(opts, :history, false),
      do: check_history_opts(Map.fetch!(@history_specs, :orders), opts),
      else: :ok
  end

  def validate_history_opts(read, opts) do
    check_history_opts(Map.fetch!(@history_specs, read), opts)
  end

  defp check_history_opts(specs, opts) do
    Enum.find_value(specs, :ok, fn {key, kind} ->
      case Keyword.get(opts, key) do
        nil -> nil
        value -> if history_value?(kind, value), do: nil, else: invalid_option(key, value)
      end
    end)
  end

  defp invalid_option(key, value), do: {:error, {:invalid_option, key, value}}

  defp history_value?({:limit, max}, value) do
    is_integer(value) and value >= 1 and value <= max
  end

  defp history_value?(:epoch, %DateTime{}), do: true
  defp history_value?(:epoch, value) when is_integer(value), do: value >= 0

  defp history_value?(:epoch, value) when is_binary(value) do
    String.match?(value, ~r/\A[0-9]+\z/)
  end

  defp history_value?(:iso, %DateTime{}), do: true

  defp history_value?(:iso, value) when is_binary(value) do
    match?({:ok, _at, _offset}, DateTime.from_iso8601(value))
  end

  defp history_value?(:symbol, value) when is_binary(value), do: String.trim(value) != ""
  defp history_value?(:side, value), do: value in [:buy, :sell, "buy", "sell"]
  defp history_value?(_kind, _value), do: false

  # The venue's own unit. Milliseconds, because that is what its examples show and what its
  # own responses carry in `timestampms`.
  defp timestamp_param(nil), do: nil
  defp timestamp_param(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp timestamp_param(other), do: other

  # The staking endpoints are the exception to `timestamp_param/1`'s rule above: both
  # `/v1/staking/history` (`rest.yaml:6729,6733`) and `/v1/staking/rewards` (`:6896,:6900`)
  # document `since`/`until` as "in iso datetime with timezone format", and their own
  # request examples give `"2022-11-01T00:00:00.000Z"` (`:6758`) — not an epoch number. A
  # `DateTime` is formatted to ISO 8601; a caller's own already-ISO string passes through
  # unchanged, the same shape `timestamp_param/1` affords its own callers.
  defp iso_timestamp_param(nil), do: nil
  defp iso_timestamp_param(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso_timestamp_param(other), do: other

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

  @doc """
  The endpoint a `cancel_all_orders/2` scope names, or the refusal for one it does not.

  Checked before anything is signed, so a call with no scope is `{:error, :scope_required}`
  whether or not it carries credentials. Exposed so `DpExchange.Gemini.Fake` refuses with
  this function in the same order.
  """
  @spec cancel_scope(term()) :: {:ok, String.t()} | {:error, term()}
  def cancel_scope(:session), do: {:ok, "/v1/order/cancel/session"}
  def cancel_scope(:account), do: {:ok, "/v1/order/cancel/all"}
  def cancel_scope(nil), do: {:error, :scope_required}
  def cancel_scope(other), do: {:error, {:unsupported_scope, other}}

  defp cancel_all_result(%{"details" => details}) when is_map(details) do
    with {:ok, cancelled} <- ids(details["cancelledOrders"]),
         {:ok, rejected} <- ids(details["cancelRejects"]) do
      {:ok, %{cancelled: cancelled, rejected: rejected}}
    end
  end

  defp cancel_all_result(_body), do: {:error, :unexpected_response_shape}

  # The venue sends integers; every other order id in this package is a string, and a
  # caller holding both should not have to know which call produced which.
  #
  # An entry that is not an id refuses the result. `to_string/1` used to stand here: it
  # raised on a map or a list (REST mutation fuzz, 2026-09-27) and turned `nil` into `""`.
  # Dropping the entry instead would under-report what was cancelled, and a caller
  # reconciling open orders against that list would see an order as still working when it
  # is not. Cancelling everything again is safe, so an error here costs a retry and
  # nothing more.
  defp ids(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case required_id(value, :order_id) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        _unreadable -> {:halt, {:error, :unexpected_response_shape}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  # Absent is none. Present and not a list is unreadable: `{:ok, []}` for it said nothing was
  # cancelled, and a caller reconciling would keep treating cancelled orders as working.
  defp ids(nil), do: {:ok, []}
  defp ids(_unreadable), do: {:error, :unexpected_response_shape}

  @doc """
  Past fills, optionally narrowed to one symbol.

  **`opts[:symbol]` is optional.** `MyTradesRequest` (`rest.yaml:8294-8298`) names only
  `request` and `nonce` as required; `symbol` sits beside `limit_trades` and `timestamp` as
  a filter. This used to refuse a call with no symbol before a request was ever made,
  reading a per-request filter as an all-or-nothing requirement the venue never stated —
  every fill row the venue returns already carries its own `"symbol"` (`:1727`, the
  endpoint's own example responses — `MyTrade`'s schema omits the field entirely, another
  gap between the two), which is exactly what a caller asking across every symbol needs
  and a refusal here withheld.

  `opts[:since]` accepts a `DateTime`, converted to the venue's own unit — **milliseconds**,
  per its own request examples (`timestamp: 1591084414000`) — the same conversion every
  other filtered endpoint in this module uses. This used to reach `maybe_put/3` instead,
  which stringifies whatever it is handed rather than converting it: a `DateTime` became
  `"2026-08-28 17:00:01Z"` on the wire, a shape the venue's `timestamp` field does not
  parse, so the filter silently failed to narrow anything rather than erroring — the same
  bug `get_orders/2`'s `history_params/1` already carries the fix for. `opts[:limit]` had
  the same defect for `limit_trades`, sent as `"100"` instead of the documented integer.

  **Reversed trades.** A row the venue marks `"break": "full"` is left out: the vendor states
  it "should not be accounted for ... as though the transfer of fund associated with the
  trade had simply not happened". `"manual"` is kept, as the vendor says it must be for the
  balance to reconcile. Any other non-empty `break` is
  `{:error, {:unknown_break_type, value}}`. The truncation check counts the rows the venue
  sent, before any are left out.
  """
  @spec get_trade_history(map(), keyword()) ::
          {:ok, [Fill.t()]} | {:error, term()} | {:refused, term()}
  def get_trade_history(credentials, opts) do
    with :ok <- validate_history_opts(:trades, opts) do
      fetch_trade_history(credentials, opts)
    end
  end

  defp fetch_trade_history(credentials, opts) do
    requested_symbol = Keyword.get(opts, :symbol)

    params =
      %{}
      |> put_present(
        "symbol",
        requested_symbol && SymbolFormat.to_exchange_symbol(requested_symbol)
      )
      |> put_present("limit_trades", Keyword.get(opts, :limit) || @history_page_max)
      |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))

    # See `complete_page/3`: one page of the venue's default 50 was answered as the whole
    # trade history.
    with {:ok, rows, _headers} <- post("/v1/mytrades", params, credentials, opts),
         {:ok, rows} <- list_rows(rows),
         :ok <- complete_page(rows, true, opts) do
      to_fills(rows, requested_symbol)
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

  # **A POST that moves money or creates an order, sent exactly once.**
  #
  # `Core.HttpClient` retries any error that is not a 4xx, which includes a timeout and a
  # connection reset — exactly the failures where the venue may have received and ACTED ON
  # the request. A `/v1/order/new` that times out after Gemini accepted it, retried, places
  # a second order. `/v2/withdraw/...` retried sends the money twice. `/v1/wrap/...` retried
  # converts twice. The caller sees one call and one answer either way.
  #
  # Retrying is only safe where the venue deduplicates. Gemini's `client_order_id` is
  # accepted on `/v1/order/new` but this repository has no evidence it is an idempotency
  # key — unlike `dp_exchange_coinbase` and `dp_exchange_robinhood`, whose venues document
  # theirs as one and whose writes may therefore retry — and the withdraw, wrap and staking
  # endpoints take no such field at all. So these are sent once and the transport failure is
  # handed to the caller, who knows what it asked for and can decide.
  #
  # `:retry_attempts` is dropped rather than defaulted, so a caller cannot re-enable it by
  # forwarding its own opts.
  #
  # **`withdraw/6` deliberately does NOT use this.** It always sends a `clientTransferId`,
  # generated when the caller gives none, which is an idempotency key for that endpoint —
  # see `money_movement_test.exs`, "an idempotency key is ALWAYS sent, even when the caller
  # gives none". A retry there re-sends the same key and the venue answers with the original
  # transfer, so retrying is both safe and useful. That is the distinction this helper turns
  # on: not "is it a write" but "can the venue tell the second attempt from the first".
  #
  # **The nonce is not that key.** `Core.HttpClient` retries a transport error, and since
  # `signer/5` hands it a function each attempt is signed afresh (a repeated nonce is
  # refused, so a read could not be retried at all). A fresh nonce makes the retry of a
  # request that already took effect a NEW request, under API-key auth as under OAuth, which
  # has no nonce: the effect happens twice. `transfer_internal/5` and both clearing-order
  # creates relied on the nonce refusing the repeat, and use this helper now.
  # `commit_conversion/2` uses it too: its `quoteId` is spent by the first execution, so a
  # retry is refused and a success is reported as a refusal, which is the wrong way round.
  defp post_once(path, params, credentials, opts) do
    post(path, params, credentials, Keyword.put(opts, :retry_attempts, 1))
  end

  defp post(path, params, credentials, opts) do
    scheme = auth_scheme(credentials, opts)

    headers = signer(scheme, path, stringify(params), credentials, opts)
    url = base_url(opts) <> path

    case HttpClient.request(:post, url, headers, "", request_opts(opts)) do
      {:ok, %{status: status, body: body, headers: response_headers}}
      when status in 200..299 ->
        with {:ok, decoded} <- decoded_body(body), do: {:ok, decoded, response_headers}

      # Permanent for the request as sent. A caller refreshes a token and calls again —
      # that is a different request, not a retry of this one.
      {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
        {:refused, refusal(body, opts)}

      {:ok, %{status: status, body: body}} ->
        status_error(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A status this module has no answer for (a 405, 409, 413, 422 and so on; Core has already
  # turned a 429 into a retry or a rate-limited error). **The body is quoted bounded**, as
  # Core quotes every body it puts in a message: `raw_status: true` hands a 4xx back whole,
  # and `inspect(body)` wrote an entire CDN error page into the error tuple, and from there
  # into every caller's log. The limits leave a body inside them byte-identical.
  defp status_error(status, body) do
    message = "HTTP #{status}: #{inspect(body, limit: 50, printable_limit: 2_048)}"
    {:error, {:exchange_error, :gemini, message}}
  end

  # The host chose its authentication; `:auth_scheme` says which. When it is absent the
  # scheme is taken from what the host actually supplied — which is the host's choice
  # expressed a different way, not this package inferring one. Credentials carrying BOTH
  # are refused rather than resolved: sending both header families is
  # `AmbiguousAuthentication` at the venue, and picking one would be guessing.
  # **A retry is signed again, with a fresh nonce.** Every request carries a nonce the venue
  # refuses to see twice. `Core.HttpClient` used to retry with the first attempt's headers,
  # so a read whose first attempt timed out was retried with a nonce already used, and the
  # venue refused it (`InvalidNonce`, surfaced as a refusal) although nothing was wrong
  # with the key. Passing a function makes the client sign each attempt afresh. A write
  # that must not take effect twice is still sent once (`post_once/4`), so a fresh nonce
  # never repeats a transfer or an order.
  defp signer(scheme, path, params, credentials, opts) do
    params = with_account(params, path, opts)
    fn -> Auth.headers(scheme, path, params, credentials, opts) end
  end

  # **`opts[:account]` reaches every account-level payload, here, once.** A master-scoped API
  # key must name the subaccount on each account-level call ("Required for Master API keys",
  # rest.yaml, e.g. `/v1/account`'s `account` property), and without it the venue answers
  # `MissingAccounts`. Only `place_order/3` and `rename_account/2` read the option, so on a
  # master key every other private call (balances, trades, transfers, orders, staking) was
  # refused with no way to name the account (dp-exchange-core issue #38). Added in the one
  # place every private request is signed, so an endpoint added later cannot miss it.
  #
  # An explicit `"account"` a function put in its own params wins. The three endpoints that
  # act on the key or the group rather than on one account (`@group_level_paths`) never get
  # it. Absent option, absent field: an account-scoped key is unaffected.
  @group_level_paths ["/v1/account/create", "/v1/account/list", "/v1/roles"]

  defp with_account(params, path, opts) do
    case Keyword.get(opts, :account) do
      account when is_binary(account) and account != "" ->
        if path in @group_level_paths, do: params, else: Map.put_new(params, "account", account)

      _absent ->
        params
    end
  end

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

  # `:rate_limit_blocking` is forwarded from here too — see `Rest.request_opts/1`'s
  # comment for the full family-wide gap (DpCryptoManagement's issue #23). Not defaulted,
  # same reasoning: this venue's periodic resubscribe is WebSocket frames, not HTTP.
  #
  # `decode_body: false` hands this module the venue's BYTES. Gemini types several money
  # fields as JSON numbers (balances, a fee estimate's `fee`, staking `accrualTotal`), and
  # Req's own decoder turns each into an Elixir float, which holds at most 17 significant
  # digits: a longer amount is rounded before this package sees it (measured:
  # `1234.567890123456789` decodes as `1234.567890123457`). `decoded_body/1` decodes with
  # `floats: :decimals` instead, so every digit survives. Core before 0.3.65 drops the
  # option; the body then arrives already decoded (a map) and `decoded_body/1` passes it
  # through, so the digits are only safe once Core carries the option.
  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :limiter,
      :timeout,
      :retry_attempts,
      :log_requests,
      :plug,
      :req_adapter,
      :rate_limit_blocking
    ])
    |> Keyword.merge(provider: :gemini_private, raw_status: true, decode_body: false)
  end

  # An authenticated **GET**, where the signed `request` is the full path *including the
  # query string*. Gemini signs a payload even on its private GETs, and the payload's
  # `request` field is documented with the query attached — signing the bare path yields a
  # valid signature over the wrong string, which the venue reports as a credential problem
  # rather than a parameter one. One string, used in both places, is what keeps them equal.
  defp signed_get(path, credentials, opts) do
    scheme = auth_scheme(credentials, opts)

    headers = signer(scheme, path, %{}, credentials, opts)

    case HttpClient.request(:get, base_url(opts) <> path, headers, nil, request_opts(opts)) do
      {:ok, %{status: status, body: body, headers: response_headers}}
      when status in 200..299 ->
        with {:ok, decoded} <- decoded_body(body), do: {:ok, decoded, response_headers}

      {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
        {:refused, refusal(body, opts)}

      {:ok, %{status: status, body: body}} ->
        status_error(status, body)

      {:error, reason} ->
        {:error, reason}
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

    headers = signer(scheme, path, %{}, credentials, opts)

    case HttpClient.request(:get, base_url(opts) <> path, headers, nil, request_opts(opts)) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in [400, 401, 403, 404] ->
        {:refused, refusal(body, opts)}

      {:ok, %{status: status, body: body}} ->
        status_error(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- order mapping ------------------------------------------------------

  @doc false
  # Exposed (not `defp`) so `Fake` validates a `{order_type, time_in_force}` pair with
  # this exact function rather than a second copy of the table below. Two copies is how
  # the fake ended up silently MORE permissive than the venue — accepting
  # `order_type: :stop_limit, time_in_force: :ioc` and `order_type: :post_only,
  # time_in_force: :fok`, both of which the venue's own "at most one execution option"
  # rule refuses — found in the 2026-09-06 real/fake parity sweep. One implementation
  # is what `Rest.refusal_reason/1` already does for `Rest` and `Private` sharing a
  # refusal vocabulary; this is the same fix for the order-validation vocabulary.
  @spec order_wire(atom(), atom()) :: {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def order_wire(order_type, time_in_force) do
    with {:ok, {type, _from_type} = resolved} <- order_type(order_type),
         {:ok, options} <- execution_options(time_in_force, resolved) do
      {:ok, {type, options}}
    end
  end

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

  # **A numeric field that is PRESENT and unreadable fails the row** (`:strict`, the default).
  # `nil` is "the venue did not say"; a quantity, price or time the venue sent and this package
  # cannot read is a malformed reply, and an order whose size or price became `nil` looks like
  # one the venue never sized or priced. An ABSENT field stays `nil`.
  #
  # `place_order/3` alone reads `:lenient`: the order it describes is already live at the venue,
  # an error would read as "nothing was placed", and a retry places a second one (see the note
  # there). Its unreadable fields are `nil` and the order is still returned.
  defp to_order(body, mode \\ :strict)

  defp to_order(%{"order_id" => _id} = body, mode) do
    with {:ok, quantity} <- order_decimal(body, "original_amount", mode),
         {:ok, price} <- order_decimal(body, "price", mode),
         {:ok, stop_price} <- order_decimal(body, "stop_price", mode),
         {:ok, filled} <- order_decimal(body, "executed_amount", mode),
         {:ok, average} <- order_average(body, mode),
         {:ok, created_at} <- order_time(body, mode) do
      {:ok,
       %Order{
         id: order_id(body["order_id"]),
         symbol: order_symbol(body["symbol"]),
         side: side(body["side"]),
         order_type: order_type_of(body),
         quantity: quantity,
         price: price,
         stop_price: stop_price,
         status: status_of(body),
         filled_quantity: filled,
         average_price: average,
         created_at: created_at,
         # The order status body has one time, its placement. Repeated here it claimed the
         # order had not changed since, through every fill; `nil` says the venue did not say.
         updated_at: nil,
         provider: :gemini
       }}
    end
  end

  defp to_order(_body, _mode), do: {:error, :unexpected_response_shape}

  defp order_decimal(body, key, mode) do
    case Map.get(body, key) do
      nil ->
        {:ok, nil}

      value ->
        case {decimal(value), mode} do
          {nil, :strict} -> {:error, :unexpected_response_shape}
          {parsed, _mode} -> {:ok, parsed}
        end
    end
  end

  # The venue states `"0.00"` for an order with nothing executed (rest.yaml:847,1369). That is
  # no average, not a fill at zero, which a notional computed from it reads.
  defp order_average(body, mode) do
    if positive?(body["executed_amount"]),
      do: order_decimal(body, "avg_execution_price", mode),
      else: {:ok, nil}
  end

  defp order_time(body, mode) do
    case {Map.get(body, "timestampms"), mode} do
      {nil, _mode} ->
        {:ok, nil}

      {value, mode} ->
        case {epoch_ms(value), mode} do
          {nil, :strict} -> {:error, :unexpected_response_shape}
          {at, _mode} -> {:ok, at}
        end
    end
  end

  # The venue's id as a string, or `nil`. `to_string/1` used to stand here, so an absent
  # `order_id` became `""` (the substitution `to_fill/2`'s note describes) and a map or a list
  # raised out of `get_order/3`, `get_orders/2`, `cancel_order/3` and `place_order/3`. A REST
  # mutation fuzz found the raise (2026-09-27). `nil` is what a caller can detect. It is not an
  # error, because on `place_order/3` the order this body describes is live at the venue.
  defp order_id(id) when is_binary(id) and id != "", do: id
  defp order_id(id) when is_integer(id), do: Integer.to_string(id)
  defp order_id(_unreadable), do: nil

  defp order_symbol(symbol) when is_binary(symbol), do: SymbolFormat.to_canonical_symbol(symbol)
  defp order_symbol(_absent), do: nil

  defp side("buy"), do: :buy
  defp side("sell"), do: :sell
  defp side(_other), do: nil

  # **The schema and the vendor's own example disagree on this string.** `NewOrderRequest`/
  # `Order`'s own enum (`rest.yaml` components.schemas) names `"exchange stop limit"`, the
  # same wire string `order_type/1` above sends on a stop-limit REQUEST — but the vendor's
  # own `/v1/order/new` `stopLimitOrder` response EXAMPLE (`rest.yaml:686`) gives `"type":
  # "stop-limit"`, not the schema's spelling, found by driving that exact example through
  # this decoder in this package's own spec-example conformance suite: it fell through to
  # the catch-all below and reported a stop-limit order as an ordinary `:limit` one,
  # silently dropping the ONE fact that distinguishes it, while `stop_price` still carried
  # a real value on an order the caller could no longer tell needed one. The family's
  # standing rule for a documented schema/example contradiction (`Rest.get_funding/2`'s
  # `amount`/`fundingAmount`, `get_positions/2`'s bare-array/`openPositions`) is to accept
  # both spellings rather than pick the one that happens to be checkable — never a guess in
  # either direction.
  defp order_type_of(%{"type" => type}) when type in ["exchange stop limit", "stop-limit"],
    do: :stop_limit

  # **A market order is reported as one.** This package refuses to PLACE a market order, but
  # the account can still hold them: the venue's own `/v1/order/status` example
  # (`rest.yaml:1259`) returns `"type": "market buy"`, and the `type` enums list
  # `exchange market`. Both fell through to the catch-all below and came back as `:limit`,
  # so a history read showed an order that took whatever price was there as a limit the
  # caller had chosen, with every other field real.
  @market_types ["market buy", "market sell", "exchange market"]

  defp order_type_of(%{"type" => type}) when type in @market_types, do: :market

  defp order_type_of(%{"options" => ["maker-or-cancel" | _rest]}), do: :post_only
  defp order_type_of(%{"options" => ["immediate-or-cancel" | _rest]}), do: :ioc
  defp order_type_of(%{"options" => ["fill-or-kill" | _rest]}), do: :fok
  defp order_type_of(_body), do: :limit

  # A cancelled MOC/IOC/FOK order arrives as a successful 200. It is a state, not a
  # failure, and reporting it as one would have a caller retry an order the venue handled.
  #
  # **A cancelled order can have filled PART of its quantity, and this used to report that
  # as `:filled` — a status `Core.Types.Order`'s own contract means "the entire quantity
  # traded" (`filled_quantity == quantity`).** Found by this package's own spec-example
  # conformance suite (`test/dp_exchange/gemini/spec_examples_test.exs`) against the
  # vendor's OWN `/v1/order/cancel` "cancelledOrder" example (`rest.yaml:874`, response
  # `examples.cancelledOrder`): `original_amount: "5"`, `executed_amount: "3.7610296649"`,
  # `is_cancelled: true` — a cancel that landed after a 75.2% fill, not a 100% one. The old
  # two-way branch below (`positive? -> :filled, else -> :cancelled`) decoded it as
  # `%Order{status: :filled, quantity: ~M[5], filled_quantity: ~M[3.7610296649]}` — a
  # caller trusting `status == :filled` to mean `filled_quantity == quantity` would have
  # been wrong. `test/dp_exchange/gemini/private_test.exs`'s existing coverage of this
  # branch ("a cancelled order that did fill is `:filled`, not `:cancelled`") used a fixture
  # where `executed_amount == original_amount`, so it never exercised the partial case the
  # vendor's own example documents — a fixture written to agree with the code's binary
  # framing rather than with the vendor, the exact failure mode that suite exists to catch.
  #
  # A cancelled partial fill is `:cancelled`, not `:partially_filled`. That atom is what the
  # `is_live` branch below uses for an order still WORKING with a fill on it, and a caller
  # reading it would wait for more fills on an order the venue has already closed. The order
  # is finished; how much of it filled is `filled_quantity`, which carries it exactly.
  # `:filled` is kept for a cancel that arrived after the whole amount executed.
  defp status_of(%{"is_cancelled" => true} = body) do
    if fully_filled?(body["executed_amount"], body["original_amount"]),
      do: :filled,
      else: :cancelled
  end

  defp status_of(%{"is_live" => true} = body) do
    if positive?(body["executed_amount"]), do: :partially_filled, else: :open
  end

  # Neither live nor cancelled. With a fill it is `:filled`; with none, `:pending`, accepted
  # and not yet booked. Reviewed 2026-10-10 against the suggestion that this is a rejected
  # order: the venue answers a rejection with an error, not an order body, so a body here is
  # an order it accepted. Not `:open`, which would claim it is resting on the book.
  #
  # `:filled` only when the whole amount executed, the check the cancelled clause already
  # makes. Any fill made it `:filled`, so `:filled` did not mean `filled_quantity == quantity`.
  defp status_of(body) do
    cond do
      fully_filled?(body["executed_amount"], body["original_amount"]) -> :filled
      positive?(body["executed_amount"]) -> :partially_filled
      true -> :pending
    end
  end

  defp required_field(request, key) do
    case Map.get(request, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp positive?(nil), do: false

  defp positive?(amount) do
    case decimal(amount) do
      nil -> false
      value -> Decimal.positive?(value)
    end
  end

  # Whether `executed_amount` accounts for the ENTIRE `original_amount` — the boundary
  # between a full fill (`:filled`) and a partial one that was cancelled before it finished
  # (`:partially_filled`). Either side unreadable answers `false` rather than guessing the
  # order filled in full: an order this package cannot compare is not one it can vouch for
  # as fully filled.
  defp fully_filled?(executed_amount, original_amount) do
    case {decimal(executed_amount), decimal(original_amount)} do
      {nil, _original} -> false
      {_executed, nil} -> false
      {executed, original} -> Decimal.equal?(executed, original)
    end
  end

  # --- other mapping ------------------------------------------------------

  # Refuses a balance row this package cannot read, rather than emitting an unusable
  # `Balance` and reporting it as success.
  #
  # `Core.Types.Balance` names `:currency` among the fields its `new/1` refuses a `nil` in.
  # Nothing here called `new/1` — this built the struct literally, the way all five venues
  # do — so the check never ran, and `currency` came straight out of the venue's JSON by
  # key. A renamed or absent `"currency"` produced `%Balance{currency: nil}`: an amount
  # attributable to no asset, returned inside `{:ok, balances}`, which a consumer cannot
  # size, book or reconcile against. It is the renamed-field scenario
  # `Core.Types.Validate`'s moduledoc exists for, arriving through the one path that
  # bypassed the constructor written to catch it.
  #
  # `amount` is deliberately NOT guarded the same way, and that is a decision this package
  # already made and recorded — see `private_test.exs`'s "a non-numeric amount does not
  # raise". A malformed or absent amount yields `balance: nil` for that currency rather than
  # destroying a page whose other rows are real, and `Core.Types.Balance` now states plainly
  # that `:balance` may honestly be `nil` while `:currency` may not. The two are not the same
  # kind of required: an unknown quantity is still a balance, an unattributable one is not.
  # `available` and `hold` stay unguarded for the same reason — both are optional on this
  # type.
  defp to_balance(row, _timestamp) when not is_map(row), do: {:error, :unexpected_response_shape}

  defp to_balance(row, timestamp) do
    with {:ok, currency} <- required_currency(row["currency"]) do
      {:ok,
       %Balance{
         currency: currency,
         balance: decimal(row["amount"]),
         available_balance: decimal(row["available"]),
         hold: hold(row),
         timestamp: timestamp,
         provider: :gemini
       }}
    end
  end

  # One unreadable row refuses the whole reply rather than leaving a gap in it. A balance
  # list with an entry silently missing reads as "you hold none of that currency", which is
  # a different and more dangerous statement than "this response could not be read".
  # A body that is not a list at all used to reach `Enum.reduce_while/3` and raise on a
  # string or a number, or iterate a map as tuples. It is not a balance list.
  defp to_balances(rows, _timestamp) when not is_list(rows),
    do: {:error, :unexpected_response_shape}

  defp to_balances(rows, timestamp) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_balance(row, timestamp) do
        {:ok, balance} -> {:cont, {:ok, [balance | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, balances} -> {:ok, Enum.reverse(balances)}
      error -> error
    end
  end

  defp required_currency(code) when is_binary(code) and code != "", do: {:ok, code}
  defp required_currency(_absent), do: {:error, :unexpected_response_shape}

  # Gemini reports the total and what is available, not the hold. The difference is the
  # hold — derived rather than invented, and `nil` when either side is missing rather than
  # a zero that would read as "nothing on hold".
  #
  # `Balance`'s own schema (`rest.yaml:8730-8750`) types `amount` and `available` as
  # `number`, not `string` — the `is_binary` guard this used to carry refused every real
  # `/v1/balances` row, which sends JSON numbers, and answered `nil` for a hold this
  # decoder could plainly compute. Both fields go through `decimal/1`, the same safe parser
  # for either shape, rather than requiring one specific JSON type the venue does not
  # promise: a malformed side must not raise, and it must not produce a fabricated hold
  # either.
  defp hold(%{"amount" => amount, "available" => available}) do
    subtract_hold(decimal(amount), decimal(available))
  end

  defp hold(_row), do: nil

  defp subtract_hold(nil, _available), do: nil
  defp subtract_hold(_amount, nil), do: nil
  defp subtract_hold(amount, available), do: Decimal.sub(amount, available)

  # Refuses a fill this package cannot read, rather than returning one that reconciles to
  # nothing.
  #
  # A `Types.Fill` is an execution record — the value a consumer reconciles money against —
  # and `Fill`'s `new/1` refuses a `nil` in `:order_id`, `:symbol`, `:side`, `:quantity`,
  # `:price` and `:timestamp`. Nothing here called `new/1` (the struct is built literally, as
  # everywhere in this family), so that check never ran, and this decoder guarded none of
  # them. One malformed row produced a fill saying an unstated quantity traded at an unstated
  # price at an unknown time, inside `{:ok, fills}`.
  #
  # **`to_string/1` was the sharpest part.** `to_string(nil)` is `""`, so a row with no
  # `order_id` produced `order_id: ""` — a value that passes every `nil` check a consumer
  # might write while identifying no order at all. An empty string is not a weaker id; it is
  # a different kind of wrong, because `nil` is at least detectable.
  #
  # `fee`, `fee_currency` and `liquidity` stay unguarded on purpose: none is enforced, and a
  # venue that did not state a fee has not stated one.
  defp to_fill(row, _requested_symbol) when not is_map(row),
    do: {:error, :unexpected_response_shape}

  # `symbol` used to be the CALLER's own argument, echoed onto every row unread — safe only
  # because `get_trade_history/2` required a symbol on every call, so caller and row could
  # never disagree. Now that the venue's filter is optional (`get_trade_history/2`'s own
  # doc), a call naming none can return fills across several symbols, and every one of the
  # venue's own example rows carries its own `"symbol"` (`rest.yaml:1727`) — so the row's
  # own field is read first, `SymbolFormat.to_canonical_symbol/1` the same conversion every
  # other decoder in this module applies to a venue symbol. `requested_symbol` is the
  # fallback for a row that somehow carries none, not the primary source it used to be.
  defp to_fill(row, requested_symbol) do
    with {:ok, disposition} <- break_disposition(Map.get(row, "break")) do
      case disposition do
        :excluded -> :skip
        :included -> decode_fill(row, requested_symbol)
      end
    end
  end

  # **A reversed trade is not an execution, and `/v1/mytrades` says so in its own words.**
  # The vendor's "Break Types" table (`rest.yaml`, `/v1/mytrades` and `/v1/orders/history`):
  # `manual` — "all fees, proceeds, and debits associated with the trade have been credited or
  # debited to the account separately ... this reported trade must be included for the
  # account balance to be correct"; `full` — "The reported trade should not be accounted for.
  # It will be as though the transfer of fund associated with the trade had simply not
  # happened." This decoder read neither: a fully broken trade came back as an ordinary
  # `Fill`, quantity and price intact, and a consumer reconciling fills against the balance
  # counted money that never moved.
  #
  # Absent or `""` is an ordinary trade (the schema's own example). `full` is dropped, which
  # is the venue's stated meaning and not a silent gap. Any other value, including the schema
  # enum's `"trade correct"`, whose treatment the vendor does not state, refuses the read:
  # counting it or dropping it would both be a guess about money.
  defp break_disposition(nil), do: {:ok, :included}
  defp break_disposition(""), do: {:ok, :included}
  defp break_disposition("manual"), do: {:ok, :included}
  defp break_disposition("full"), do: {:ok, :excluded}
  defp break_disposition(other), do: {:error, {:unknown_break_type, other}}

  defp decode_fill(row, requested_symbol) do
    with {:ok, order_id} <- required_id(row["order_id"], :order_id),
         {:ok, symbol} <- fill_symbol(row["symbol"], requested_symbol),
         {:ok, side} <- required_side(row["type"]),
         {:ok, quantity} <- required_decimal(row["amount"], :quantity),
         {:ok, price} <- required_decimal(row["price"], :price),
         {:ok, timestamp} <- required_time(row["timestampms"]) do
      {:ok,
       %Fill{
         order_id: order_id,
         trade_id: fill_id(row["tid"]),
         symbol: symbol,
         side: side,
         quantity: quantity,
         price: price,
         fee: decimal(row["fee_amount"]),
         fee_currency: row["fee_currency"],
         timestamp: timestamp,
         liquidity: liquidity(row["aggressor"]),
         provider: :gemini
       }}
    end
  end

  defp fill_symbol(row_symbol, _requested) when is_binary(row_symbol) and row_symbol != "" do
    {:ok, SymbolFormat.to_canonical_symbol(row_symbol)}
  end

  # Canonical, like the row's own symbol above. The caller's spelling (`"btcusd"`, `"BTCUSD"`)
  # was echoed as given, so one call could return fills under two spellings of one pair.
  defp fill_symbol(_row_symbol, requested) when is_binary(requested) and requested != "" do
    {:ok, requested |> SymbolFormat.to_exchange_symbol() |> SymbolFormat.to_canonical_symbol()}
  end

  defp fill_symbol(_row_symbol, _requested), do: {:error, {:missing_required_field, :symbol}}

  # One unreadable fill refuses the whole page rather than leaving a gap in it. A trade
  # history with an execution silently missing is the one shape a consumer cannot detect: it
  # reconciles to a smaller number and looks complete.
  defp to_fills(rows, symbol) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_fill(row, symbol) do
        {:ok, fill} -> {:cont, {:ok, [fill | acc]}}
        :skip -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      # Oldest first, by the venue's own time — see `Core.Venue`'s callback doc.
      {:ok, fills} -> {:ok, fills |> Enum.reverse() |> Enum.sort_by(& &1.timestamp, DateTime)}
      error -> error
    end
  end

  # `trade_id` is NOT enforced by `Fill`, so an absent one stays `nil` rather than becoming
  # `""`. `to_string/1` was applied to both ids alike; only one of them may be absent.
  defp fill_id(nil), do: nil
  defp fill_id(value), do: order_id(value)

  defp required_id(nil, field), do: {:error, {:missing_required_field, field}}
  defp required_id("", field), do: {:error, {:missing_required_field, field}}
  defp required_id(value, _field) when is_binary(value), do: {:ok, value}
  defp required_id(value, _field) when is_integer(value), do: {:ok, Integer.to_string(value)}

  # A map or a list is not an id, and `to_string/1` raised on it (REST fuzz, 2026-09-27).
  defp required_id(_value, _field), do: {:error, :unexpected_response_shape}

  defp required_side(type) when is_binary(type) do
    case side(String.downcase(type)) do
      nil -> {:error, {:unknown_side, type}}
      side -> {:ok, side}
    end
  end

  defp required_side(other), do: {:error, {:unknown_side, other}}

  defp required_time(value) do
    case epoch_ms(value) do
      nil -> {:error, {:unparseable_venue_timestamp, value}}
      at -> {:ok, at}
    end
  end

  # The same shape as `Rest`'s own copy. A `nil` out of `decimal/1` means "absent, empty,
  # unparseable, or a NaN/Infinity this package refuses"; this is how a field says it may not
  # carry that forward.
  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
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

    with {:ok, symbol, side} <- instant_pair(from, to, opts),
         {:ok, total_spend} <- wire_positive(amount, :amount) do
      params = %{
        "symbol" => symbol,
        "side" => side,
        "totalSpend" => total_spend
      }

      with {:ok, body, headers} <- post("/v1/instant/quote", params, credentials, opts) do
        to_conversion(body, from, to, :quoted, headers, side)
      end
    end
  end

  @doc """
  Commits a quote by its `quoteId`, moving the assets.

  `/v1/instant/execute`. **A quote past its window does not fill at the quoted rate** —
  see `Core.Types.Conversion`, whose `expires_at` exists for exactly this. Ask
  `Conversion.expired?/2` before committing; the venue is still the authority on whether
  a commit succeeds.

  `opts[:symbol]`, `opts[:side]`, `opts[:amount]` and `opts[:price]` are the terms the quote
  was made at — see `execute_params/2`'s own comment. **`opts[:amount]` is the quote's
  `quantity` (CCY1, the asset bought or sold), not its `totalSpend`**: it is sent as the
  execute request's `quantity`, which the venue requires to "match quantity returned in the
  quote" (`rest.yaml`, `/v1/instant/execute`). On a buy the two differ — `totalSpend` is the
  CCY2 amount spent — and passing the spend would be a quantity the quote never held. The
  amount and price must be finite numbers above zero and the fee one that is not negative,
  else `{:error, {:invalid_decimal, field, value}}`, `{:error, {:non_positive_amount, field,
  value}}` or `{:error, {:negative_amount, :fee, value}}` before a request is made. A `:side`
  other than `:buy` / `:sell` is `{:error, {:invalid_side, side}}`.

  `opts[:fee]` is required too: the venue
  requires it and states it "must match fee returned in the quote" (`rest.yaml:5071`), so
  this package sends what the caller was quoted rather than a `"0"` this package used to
  invent. All five are required; any missing is `{:error, {:missing_option, missing}}`
  before a request is made. `id` — the quote's `quoteId` — is sent as the integer the
  venue's own schema names (`rest.yaml:5072`), parsed back from the string this package
  handed the caller in the quote; an id that does not parse is refused rather than sent.
  """
  @spec commit_conversion(String.t(), keyword()) ::
          {:ok, Conversion.t()} | {:error, term()} | {:refused, term()}
  def commit_conversion(id, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    # Once. A commit that timed out after the venue executed it, sent again with a fresh
    # nonce, comes back as a refusal (the quote is spent), and the caller reads "refused" as
    # "no conversion happened" for one that did. The transport error this sends instead says
    # what is true: the outcome is unknown. The spec never says a repeat of a spent
    # `quoteId` returns the original result, so this does not assume it. See `post_once/4`.
    with {:ok, params} <- execute_params(id, opts),
         {:ok, body, headers} <- post_once("/v1/instant/execute", params, credentials, opts) do
      to_conversion(body, nil, nil, :settled, headers, params["side"])
    end
  end

  @doc """
  Whether `id` and `opts` carry everything `commit_conversion/2` sends, checked without
  sending it.

  The five terms the quote was made at (`:symbol`, `:side`, `:amount`, `:price`, `:fee`) first,
  as `{:error, {:missing_option, missing}}`, then the quote id, as
  `{:error, {:invalid_quote_id, id}}`. Exposed so `DpExchange.Gemini.Fake` refuses with this
  exact function, in the same order, rather than a second copy of the rules.
  """
  @spec validate_commit_terms(term(), keyword()) :: :ok | {:error, term()}
  def validate_commit_terms(id, opts) do
    with {:ok, _params} <- execute_params(id, opts), do: :ok
  end

  # The venue needs the same symbol, side and spend it quoted against, alongside the id —
  # `/v1/instant/execute` does not take the quote id alone. A caller holding the
  # `Conversion` this package returned has all of them, so they come from `opts` and a
  # missing one is an error rather than a value invented here.
  #
  # **Two defects lived here, both on the call that moves the money.**
  #
  # The guard was `Keyword.has_key?/2`, which answers `true` for `price: nil`. So a caller
  # forwarding options its own caller never set passed the check, and `to_string(nil)` put
  # `"quantity": ""` and `"price": ""` into a signed `/v1/instant/execute` — measured on the
  # wire. The comment above promises "a missing one is an error rather than a value invented
  # here", and an empty string is an invented value. Presence is now judged by what the value
  # IS, through `Config.opt/3`, and a blank string counts as absent too.
  #
  # And the numbers went out through `to_string/1`, which on a `Decimal` means
  # `String.Chars` and therefore scientific notation: `0.00000001` was sent as `"1E-8"` and
  # `1500000` as `"1.5E+6"`, also measured on the wire. `place_order/3` in this same module
  # already sends through `decimal_string/1` for exactly that reason; this path was the one
  # the earlier sweep missed.
  #
  # **A third defect, on the same call.** `fee` defaulted to `"0"` here. The venue's own
  # requirement (`rest.yaml:5077`): "The fee for the order. fee must match fee returned in
  # the quote" — `fee` is in the request schema's `required` list (`:5049-5057`) alongside
  # `quoteId`, `symbol`, `side`, `quantity` and `price`, and a real fee is essentially never
  # zero (`quote_conversion/4`'s own doc example: `"2.9900309233"`). Sending `"0"` when the
  # caller did not supply one was not a safe default, it was asserting a fee the venue never
  # quoted — the caller now supplies it, exactly as it does `:amount` and `:price`, both of
  # which already come from the quote this package returned.
  defp execute_params(id, opts) do
    required = [:symbol, :side, :amount, :price, :fee]
    values = Map.new(required, &{&1, Config.opt(opts, &1, nil)})

    case Enum.reject(required, &present?(values[&1])) do
      [] ->
        # The quote id is checked only once the terms it belongs to are all present — a
        # caller who forwarded no terms at all sees "the terms are missing", not "the id
        # looks wrong", which would send them looking at the wrong thing.
        with {:ok, quote_id} <- quote_id_integer(id),
             {:ok, side} <- wire_side(values.side),
             {:ok, quantity} <- wire_positive(values.amount, :amount),
             {:ok, price} <- wire_positive(values.price, :price),
             {:ok, fee} <- wire_non_negative(values.fee, :fee) do
          {:ok,
           %{
             "quoteId" => quote_id,
             "symbol" => SymbolFormat.to_exchange_symbol(values.symbol),
             "side" => side,
             "quantity" => quantity,
             "price" => price,
             "fee" => fee
           }}
        end

      missing ->
        {:error, {:missing_option, missing}}
    end
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  # `quoteId` is `type: integer` in the venue's own schema (`rest.yaml:5072`), not the
  # string `commit_conversion/2`'s caller received back — `Conversion.id` is always a
  # string, including when it came from an integer (`required_id/2` above runs every
  # `quoteId` through `Integer.to_string/1` on the way in). Signing and sending that string
  # unchanged would put a JSON string where the venue's schema names a number. Parsed back
  # to an integer here, and refused — never guessed — when it does not parse: an id this
  # package cannot read back as the number it came from is not one it can vouch for.
  defp quote_id_integer(id) when is_binary(id) do
    # Digits only: `Integer.parse/1` also reads `"-5"` and `"+5"`, and a signed id is no
    # quote this package returned.
    with true <- String.match?(id, ~r/\A[0-9]+\z/),
         {value, ""} <- Integer.parse(id) do
      {:ok, value}
    else
      _unparseable -> {:error, {:invalid_quote_id, id}}
    end
  end

  defp quote_id_integer(id) when is_integer(id) and id >= 0, do: {:ok, id}
  defp quote_id_integer(id), do: {:error, {:invalid_quote_id, id}}

  @doc """
  The venue symbol and side a conversion between `from` and `to` is made at.

  From `opts[:symbol]` and `opts[:side]` when both are given (`:buy` or `:sell`); one without
  the other is `{:error, {:missing_option, [:symbol, :side]}}`; neither derives them from the
  assets and refuses with `{:error, {:ambiguous_conversion, from, to}}` when that is not
  determinable. Checked before anything is signed. Exposed so `DpExchange.Gemini.Fake`
  refuses with this function in the same order.
  """
  @spec instant_pair(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def instant_pair(from, to, opts) do
    case {Keyword.get(opts, :symbol), Keyword.get(opts, :side)} do
      {nil, nil} ->
        derive_instant_pair(from, to)

      {symbol, side} when is_binary(symbol) and side in [:buy, :sell] ->
        {:ok, SymbolFormat.to_exchange_symbol(symbol), to_string(side)}

      _partial ->
        {:error, {:missing_option, [:symbol, :side]}}
    end
  end

  # A non-string asset raised in `String.upcase/1`, in the caller, before anything was signed.
  defp derive_instant_pair(from, _to) when not is_binary(from),
    do: {:error, {:invalid_asset, from}}

  defp derive_instant_pair(_from, to) when not is_binary(to),
    do: {:error, {:invalid_asset, to}}

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
  # `:id`, `:status`, `:from_asset` and `:to_asset` are all in `Conversion`'s
  # `@enforce_keys`, so its `new/1` refuses a `nil` in any of them — and nothing here calls
  # `new/1`, the struct being built literally as everywhere in this family, so that check
  # never ran.
  #
  # `:status` is safe: every caller passes a literal atom. The other three were not.
  # `to_string_or_nil/1` answers `nil` for an absent quote id, and the two asset fields fall
  # back to the body only when the CALLER did not name them — which `commit_conversion/3`
  # does, passing `nil, nil` — so a body without `totalSpendCurrency` produced a conversion
  # naming neither side of itself. A conversion that does not say what was sold, what was
  # bought, or which quote it belongs to cannot be reconciled against anything.
  defp to_conversion(%{} = body, from, to, status, headers, requested_side) do
    # `quoteId` OR `orderId`. The quote-and-commit endpoints name it `quoteId`; the one-step
    # wrap endpoint (`convert/4`) names it `orderId` and sends no `quoteId` at all — so
    # reading only the first meant EVERY wrap conversion came back with `id: nil`, on a
    # field `Conversion` marks required. The test covering that path asserted on `status`
    # and `expires_at` and never on the id, so it passed throughout.
    with {:ok, id} <- required_id(Map.get(body, "quoteId") || Map.get(body, "orderId"), :id),
         {:ok, side} <- conversion_side(Map.get(body, "side"), requested_side),
         {:ok, from_asset, from_amount, to_asset, to_amount} <-
           conversion_amounts(side, body, from, to) do
      {:ok,
       build_conversion(body, id, from_asset, from_amount, to_asset, to_amount, status, headers)}
    end
  end

  defp to_conversion(_body, _from, _to, _status, _headers, _side),
    do: {:error, :unexpected_response_shape}

  # **Which of the two asset columns is the one given up depends on the side, so the side
  # must be known — never defaulted.** `conversion_amounts/4` used to treat every body that
  # was not literally `"side": "sell"` as a buy, so a sell whose reply carried no `side`
  # (the wrap endpoint's `side` is optional on the request and this package's own tests fed
  # it one without) was decoded with CCY1 amounts under CCY2 labels: a plausible
  # `to_amount` in the wrong asset. The body's own `side` wins; the side this package asked
  # for stands in only when the body is silent; a `side` that is neither `buy` nor `sell`,
  # or no side from either source, refuses the read.
  defp conversion_side(side, _requested) when side in ["buy", "sell"], do: {:ok, side}
  defp conversion_side(nil, requested) when requested in ["buy", "sell"], do: {:ok, requested}
  defp conversion_side(_unknown, _requested), do: {:error, :unexpected_response_shape}

  # **`quantity`/`quantityCurrency` name `CCY1` on both a buy and a sell.** The venue's own
  # examples agree across both endpoints: a BTCUSD buy's `quantityCurrency` is `BTC`, on
  # the quote (`rest.yaml:4971,4972`) as well as the execute (`:5160,5161`) response, and
  # an ETHUSD SELL's is `ETH` on both too (`:4990,4991` quote; `:5178,5179` execute) — the
  # base of the pair either way, never the quote currency. `totalSpend`/`totalSpendCurrency`
  # name whichever side was actually given up: `CCY2` on a buy (cash spent for crypto
  # received), but `CCY1` on a sell — the sell quote example gives `totalSpend: "1"`,
  # `totalSpendCurrency: "ETH"`, identical to `quantity`, because selling IS spending the
  # quantity sold.
  #
  # This used to read `from`/`to` unconditionally from `totalSpend(Currency)` and
  # `quantity(Currency)` regardless of side. On a buy that is right. On a sell it put
  # `quantityCurrency` — `CCY1`, the asset being SOLD — on `to_asset` too, so a sell's
  # `Conversion` named the same asset on both ends and reported `to_amount` in `CCY1` units
  # under a `to_asset` a caller-supplied override could still label `USD`: a caller selling
  # ETH for USD read `to_amount: 1` as "1 USD received" when the venue said nothing of the
  # kind.
  #
  # **The venue reports no proceeds figure for a sell.** Nothing in this response — quote,
  # execute or wrap — carries a quote-currency amount received; `quantity`/`totalSpend` are
  # both `CCY1`, and `price`/`priceCurrency` is a rate, not an amount. `to_amount` is `nil`
  # on a sell rather than computed here from `quantity * price`: that would be this
  # package's arithmetic reported as the venue's own number, the exact substitution this
  # family's `Conversion` types refuse elsewhere.
  #
  # `from`/`to` — the caller's own asset names, where the caller already knows them
  # (`quote_conversion/4`, `convert/4`) — still win over anything derived from the body, as
  # they did before; only the AMOUNTS, which never had a caller-supplied override, depend on
  # `body["side"]`.
  defp conversion_amounts("sell", body, from, to) do
    with {:ok, from_asset} <-
           required_id(from || Map.get(body, "quantityCurrency"), :from_asset),
         {:ok, to_asset} <- required_id(to || Map.get(body, "priceCurrency"), :to_asset) do
      {:ok, from_asset, decimal(Map.get(body, "quantity")), to_asset, nil}
    end
  end

  defp conversion_amounts("buy", body, from, to) do
    with {:ok, from_asset} <-
           required_id(from || Map.get(body, "totalSpendCurrency"), :from_asset),
         {:ok, to_asset} <- required_id(to || Map.get(body, "quantityCurrency"), :to_asset) do
      {:ok, from_asset, decimal(Map.get(body, "totalSpend")), to_asset,
       decimal(Map.get(body, "quantity"))}
    end
  end

  defp build_conversion(body, id, from_asset, from_amount, to_asset, to_amount, status, headers) do
    %Conversion{
      id: id,
      status: status,
      from_asset: from_asset,
      to_asset: to_asset,
      from_amount: from_amount,
      to_amount: to_amount,
      rate: decimal(Map.get(body, "price")),
      fee: decimal(Map.get(body, "fee")),
      expires_at: expires_at(Map.get(body, "maxAgeMs"), headers),
      venue_time: venue_date(headers),
      provider: :gemini
    }
  end

  defp expires_at(nil, _headers), do: nil

  @max_quote_age_ms 3_600_000

  # **Bounded, because `DateTime.add/3` is not.** It computes a date for any offset, and for
  # an extreme one it took longer than 4 seconds (measured 2026-09-27 at 10^20 seconds and
  # above). A REST mutation fuzz found the case: a `maxAgeMs` of 10^27 left `quote_conversion/4`
  # and `commit_conversion/2` running in the caller's process with no answer. The venue
  # documents a window of about 60 seconds. `@max_quote_age_ms` is one hour, chosen rather
  # than measured, and 60 times that. A window outside 0..one hour is not a quote window
  # this venue gives. It is `nil`, which `Conversion.expired?/2` already reports as unknown
  # rather than as still valid.
  defp expires_at(max_age_ms, headers)
       when is_integer(max_age_ms) and max_age_ms in 0..@max_quote_age_ms do
    case venue_date(headers) do
      nil -> nil
      at -> DateTime.add(at, max_age_ms, :millisecond)
    end
  end

  defp expires_at(_other, _headers), do: nil

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

    with {:ok, symbol, side} <- instant_pair(from, to, opts),
         {:ok, wire_amount} <- wire_positive(amount, :amount) do
      params = %{"amount" => wire_amount, "side" => side}

      with {:ok, body, headers} <-
             post_once("/v1/wrap/#{segment(symbol)}", params, credentials, opts) do
        to_conversion(body, from, to, :settled, headers, side)
      end
    end
  end

  @doc """
  The account's own traded volume, as the venue aggregates it — `/v1/tradevolume`.

  One row per symbol per day, with the maker and taker breakdown the venue's fee tiers are
  computed from. **Not `get_trade_history/2` summed**: `get_trade_history/2` answers fills,
  not the venue's own daily aggregation, so reproducing this from fills would still be this
  package's arithmetic against the venue's ledger rather than the number `/v1/tradevolume`
  itself publishes.

  Rows come back as the venue sends them. The fields differ enough between venues that a
  normalised struct would be mostly `nil`, and a caller reading `buy_maker_notional` wants
  the venue's number under the venue's name.
  """
  @spec get_trade_volume(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_trade_volume(credentials, opts) do
    # The venue nests one list per symbol inside the outer list. Every flattened entry must
    # be a volume object: `List.flatten/1` hands a bare scalar straight back, and a row that
    # is not an object is a reply this package could not read, not a volume row.
    with {:ok, rows, _headers} <- post("/v1/tradevolume", %{}, credentials, opts),
         {:ok, flat} <- flattened_rows(rows) do
      if Enum.all?(flat, &is_map/1), do: {:ok, flat}, else: {:error, :unexpected_response_shape}
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
  def list_networks(asset, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    with {:ok, path} <- network_lookup_path(asset, Keyword.get(opts, :network)),
         {:ok, body, _headers} <- signed_get(path, credentials, opts) do
      object_rows(body)
    end
  end

  @doc """
  The path `list_networks/2` asks for, or its refusal, checked before anything is signed.

  `asset` wins when both are given. Neither is `{:error, :asset_or_network_required}`; a
  value that is not a non-blank string is `{:error, {:invalid_asset, value}}` or
  `{:error, {:invalid_network, value}}`: a blank one built `/v2/network/` or
  `/v2/networks//assets`, a different route from the one asked for. Exposed so
  `DpExchange.Gemini.Fake` refuses with this function.
  """
  @spec network_lookup_path(term(), term()) :: {:ok, String.t()} | {:error, term()}
  def network_lookup_path(nil, nil), do: {:error, :asset_or_network_required}

  def network_lookup_path(nil, network) do
    with {:ok, network_segment} <- withdrawal_network(network),
         do: {:ok, "/v2/networks/#{network_segment}/assets"}
  end

  # The asset keeps the caller's case: the vendor's `{token}` example is `BTC`.
  def network_lookup_path(asset, _network) when is_binary(asset) do
    if String.trim(asset) == "",
      do: {:error, {:invalid_asset, asset}},
      else: {:ok, "/v2/network/#{segment(asset)}"}
  end

  def network_lookup_path(asset, _network), do: {:error, {:invalid_asset, asset}}

  # The pairs the venue serves, from its own documentation. **Enumerated rather than passed
  # through** because an unsupported pair returns a 404 the caller cannot distinguish from
  # a bad timestamp, and the list is short and stated.
  @fx_pairs ~w(AUDUSD CADUSD COPUSD EURUSD CHFUSD HKDUSD NZDUSD GBPUSD BRLUSD INRUSD
               SGDUSD KRWUSD JPYUSD CNYUSD)

  @doc """
  A foreign-exchange reference rate for `pair` at `at` — `GET /v2/fxrate/{symbol}/{timestamp}`.

  **This used to live in `Rest`, documented "Public". It is not.** Measured against the
  vendor's own OpenAPI (`rest.yaml:7836-7851`): this route's `security` lists `apiKeyAuth`,
  `signatureAuth` and `payloadAuth`, the same full private scheme as `/v1/margin` or any
  signed POST, and the vendor states the key must carry the Auditor role. `Rest` sends no
  credentials at all — that is that module's whole design — so this could never succeed no
  matter what a caller passed it, the same defect `list_networks/2`'s own doc records for
  `/v2/network/{token}`. Signed here through `signed_get/3` like every other authenticated
  GET in this module; `opts[:credentials]` names the key, exactly as `list_networks/2`
  reads its own.

  **This is not a rate the venue trades at.** Gemini's own documentation: *"Gemini does not
  offer foreign exchange services. This endpoint is for historical reference only and does
  not provide any guarantee of future exchange rates."* The number comes from a third party
  the venue names in `provider`, which this package carries as `Types.FxRate`'s `:source` —
  `:provider` stays `:gemini`, the venue relaying it.

  Fourteen pairs are served and they are all `…USD`; a pair outside the list is refused here
  rather than sent, because the venue's 404 for an unsupported pair reads the same as one
  for a bad timestamp.

  `at` is the instant, sent as milliseconds.
  """
  @spec get_fx_rate(String.t(), DateTime.t() | term(), keyword()) ::
          {:ok, FxRate.t()} | {:error, term()} | {:refused, term()}
  def get_fx_rate(_pair, at, _opts) when not is_struct(at, DateTime),
    do: validate_fx_instant(at)

  def get_fx_rate(pair, %DateTime{} = at, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    with {:ok, native} <- validate_fx_pair(pair) do
      timestamp = DateTime.to_unix(at, :millisecond)

      with {:ok, body, _headers} <-
             signed_get("/v2/fxrate/#{segment(native)}/#{segment(timestamp)}", credentials, opts) do
        to_fx_rate(body, native, at)
      end
    end
  end

  @doc """
  Whether `at` is an instant `get_fx_rate/3` can ask about: a `DateTime`. Anything else —
  a `NaiveDateTime` with no zone, a `Date`, a unix integer — is
  `{:error, {:invalid_fx_instant, at}}`. It raised `FunctionClauseError` in the caller's
  process; `DpExchange.Gemini.Fake` runs the same check.
  """
  @spec validate_fx_instant(term()) :: :ok | {:error, {:invalid_fx_instant, term()}}
  def validate_fx_instant(%DateTime{}), do: :ok
  def validate_fx_instant(at), do: {:error, {:invalid_fx_instant, at}}

  @doc """
  The venue's spelling of `pair` (`EUR-USD` and `eurusd` are both `EURUSD`), or
  `{:error, {:unsupported_fx_pair, native}}` for one of the fourteen it does not serve.

  Checked before anything is signed. Exposed so `DpExchange.Gemini.Fake` refuses with this
  function in the same order.
  """
  @spec validate_fx_pair(term()) ::
          {:ok, String.t()} | {:error, {:unsupported_fx_pair, String.t()}}
  def validate_fx_pair(pair) when is_binary(pair) or is_atom(pair) do
    native = pair |> to_string() |> String.replace("-", "") |> String.upcase()

    if native in @fx_pairs,
      do: {:ok, native},
      else: {:error, {:unsupported_fx_pair, native}}
  end

  # `to_string/1` raised `Protocol.UndefinedError` in the caller on a map, a tuple or a list.
  def validate_fx_pair(other), do: {:error, {:unsupported_fx_pair, inspect(other)}}

  defp to_fx_rate(%{"rate" => rate} = body, native, _requested_at) do
    with {:ok, parsed_rate} <- required_decimal(rate, :rate),
         {:ok, as_of} <- fx_as_of(body["asOf"]) do
      {:ok,
       %FxRate{
         pair: body["fxPair"] || native,
         rate: parsed_rate,
         # The venue's own `asOf`, and only that. The venue may answer for a nearby moment,
         # so the instant asked for is not a stand-in for the one it answered for.
         as_of: as_of,
         # The institution that computed the rate. Named `provider` by the venue and
         # carried as `source` here, because `provider` in this contract means the venue.
         source: body["provider"],
         benchmark: body["benchmark"],
         provider: :gemini
       }}
    end
  end

  defp to_fx_rate(_body, _native, _requested_at), do: {:error, :unexpected_response_shape}

  # `Core.Types.FxRate`: `:as_of` is the instant "echoed by the venue", and "a rate without
  # it is a number with no time attached, which is not a rate". This must not fall back to
  # the instant requested when `asOf` is absent — the venue may answer for a nearby moment,
  # so the instant asked for is not a stand-in for the one it answered for — and must not
  # date a non-positive `asOf` to 1970 or raise on one outside `DateTime`'s range.
  defp fx_as_of(ms) when is_integer(ms) and ms > 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> {:ok, at}
      {:error, _out_of_range} -> {:error, :missing_venue_timestamp}
    end
  end

  defp fx_as_of(_absent_or_unreadable), do: {:error, :missing_venue_timestamp}

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

  A blank or non-string `network` is `{:error, {:invalid_network, network}}`, and a reply
  whose own `network` differs from the one asked for is
  `{:error, {:network_mismatch, requested, returned}}` — an address on another chain is never
  handed back as the requested one.
  """
  @spec get_deposit_address(String.t(), String.t(), map(), keyword()) ::
          {:ok, DepositAddress.t()} | {:error, term()} | {:refused, term()}
  def get_deposit_address(asset, network, credentials, opts) do
    params =
      %{}
      |> put_present("label", Keyword.get(opts, :label))
      |> put_present("legacy", Keyword.get(opts, :legacy))

    with {:ok, network_segment} <- withdrawal_network(network),
         # Once: every call generates a NEW address, and nothing in the request lets the venue
         # tell a retry from a second ask, so a retried timeout would create an address the
         # caller never saw. See `post_once/4`.
         {:ok, body, _headers} <-
           post_once("/v1/deposit/#{network_segment}/newAddress", params, credentials, opts),
         # An object, or a refusal — `body["address"]` on a list raises. See
         # `Rest.object/1`.
         {:ok, body} <- Rest.object(body),
         # **The address must be on the network that was asked for.** The reply names its own
         # `network` (`Address` schema). One that disagrees is an address on a chain this
         # call did not request, and funds sent over the requested chain to it are gone —
         # the loss this function's whole doc is written to prevent. An absent `network` is
         # accepted: the vendor's schema does not promise it.
         :ok <- same_network(network, body["network"]),
         # `:address` is in `DepositAddress`'s `@enforce_keys`, so its `new/1` refuses a
         # `nil` there — and nothing here calls `new/1`, the struct being built literally as
         # everywhere in this family, so that check never ran. An address is the entire
         # content of this call: a `DepositAddress` carrying `nil` is not a weaker answer,
         # it is one a caller can present to a person as somewhere to send funds.
         {:ok, address} <- required_id(body["address"], :address) do
      {:ok,
       %DepositAddress{
         asset: asset,
         network: network,
         address: address,
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

  defp same_network(_requested, nil), do: :ok

  defp same_network(requested, returned) when is_binary(returned) do
    if String.downcase(returned) == String.downcase(requested),
      do: :ok,
      else: {:error, {:network_mismatch, requested, returned}}
  end

  defp same_network(requested, returned), do: {:error, {:network_mismatch, requested, returned}}

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
        with :ok <- validate_deposit_network(network),
             {:ok, body, _headers} <-
               post("/v1/approvedAddresses/account/#{segment(network)}", %{}, credentials, opts),
             {:ok, rows} <- approved_rows(body) do
          to_approved_addresses(rows, network)
        end
    end
  end

  # A reply this package cannot find the list in is unreadable, not empty. It used to answer
  # `{:ok, []}`, "no approved addresses", and a caller withdrawing only to an approved
  # address was told it had none — or, reconciling, that one it had approved was gone.
  defp approved_rows(%{"approvedAddresses" => rows}) when is_list(rows), do: {:ok, rows}
  defp approved_rows(%{"approvedAddresses" => nil}), do: {:ok, []}
  defp approved_rows(rows) when is_list(rows), do: {:ok, rows}
  defp approved_rows(_other), do: {:error, :unexpected_response_shape}

  # One unreadable entry refuses the whole page rather than leaving a gap in it, the rule
  # `to_fills/2` above already states: a list with an entry silently missing reconciles to a
  # smaller number and looks complete.
  defp to_approved_addresses(rows, network) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_approved_address(row, network) do
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, addresses} -> {:ok, Enum.reverse(addresses)}
      error -> error
    end
  end

  # `:address` is in `ApprovedAddress`'s `@enforce_keys`, so its `new/1` refuses a `nil`
  # there — and nothing here calls `new/1`, the struct being built literally as everywhere in
  # this family, so that check never ran. An allowlist entry with no address is the one shape
  # this type must not take: a caller checking whether a withdrawal destination is approved
  # would be comparing against nothing.
  defp to_approved_address(row, _network) when not is_map(row),
    do: {:error, :unexpected_response_shape}

  defp to_approved_address(row, network) do
    with {:ok, address} <- required_id(row["address"], :address) do
      {:ok, to_approved_address(row, network, address)}
    end
  end

  defp to_approved_address(row, network, address) do
    %ApprovedAddress{
      address: address,
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
      {ms, ""} -> epoch_ms_to_datetime(ms)
      _not_an_epoch -> nil
    end
  end

  # `DateTime.from_unix/2`, not `from_unix!/2`, and non-positive is refused — the same two
  # holes `Rest.trade_time/1` had. Out of range RAISES out of the read (a venue moving to
  # microseconds is `invalid Unix time`), and zero or negative quietly becomes 1970 or
  # earlier. `nil` here means "the venue did not state one", which is what every caller of
  # this already handles.
  defp epoch_ms_to_datetime(ms) when is_integer(ms) and ms > 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> at
      {:error, _out_of_range} -> nil
    end
  end

  defp epoch_ms_to_datetime(_other), do: nil

  @doc """
  What the venue would charge to withdraw `amount` of `asset` over `network` to `address` —
  `/v2/withdraw/{network}/{ticker}/feeEstimate`.

  **The address is part of the estimate**, not decoration: fees differ by destination on
  some networks, so an estimate for one address does not hold for another.

  This moves no funds. `withdraw/6` does.

  The same pre-signing checks as `withdraw/6` apply to `asset`, `network` and `amount`. A
  reply with no readable `fee` is `{:error, :unexpected_response_shape}`, not an estimate of
  `nil`.
  """
  @spec estimate_withdrawal_fee(String.t(), String.t(), Decimal.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def estimate_withdrawal_fee(asset, network, amount, credentials, opts) do
    with {:ok, address} <- required_address(opts),
         {:ok, ticker} <- withdrawal_ticker(asset),
         {:ok, network_segment} <- withdrawal_network(network),
         {:ok, wire_amount} <- wire_positive(amount, :amount) do
      params = %{"address" => address, "amount" => wire_amount}

      with {:ok, body, _headers} <-
             post(
               "/v2/withdraw/#{network_segment}/#{segment(ticker)}/feeEstimate",
               params,
               credentials,
               opts
             ),
           {:ok, body} <- Rest.object(body),
           {:ok, fee} <- estimated_fee(body) do
        {:ok,
         %{
           fee: fee,
           fee_currency: body["currency"] || body["feeCurrency"],
           network: network,
           address: address
         }}
      end
    end
  end

  # **An estimate with no readable fee is not an estimate.** `decimal/1` answers `nil` for an
  # absent, blank or non-numeric `fee`, and that `nil` was returned inside `{:ok, _}` — a
  # caller deciding whether a withdrawal is affordable read "no fee stated" as "no fee". The
  # vendor's `FeeEstimateV2Response` always carries `fee` (a JSON number, e.g. `0.001`).
  defp estimated_fee(body) do
    case decimal(body["fee"] || body["feeAmount"]) do
      nil -> {:error, :unexpected_response_shape}
      fee -> {:ok, fee}
    end
  end

  # The path segments of a withdrawal. `String.downcase/1` raised in the caller's process on
  # a `nil` asset, and a `nil` or blank network produced `/v2/withdraw//eth` — a request for
  # a resource the caller never named, on the call that moves money.
  defp withdrawal_ticker(asset) when is_binary(asset) do
    if String.trim(asset) == "",
      do: {:error, {:invalid_asset, asset}},
      else: {:ok, String.downcase(asset)}
  end

  defp withdrawal_ticker(asset), do: {:error, {:invalid_asset, asset}}

  defp withdrawal_network(network) when is_binary(network) do
    if String.trim(network) == "",
      do: {:error, {:invalid_network, network}},
      else: {:ok, segment(network)}
  end

  defp withdrawal_network(network), do: {:error, {:invalid_network, network}}

  defp required_address(opts) do
    case Keyword.get(opts, :address) do
      address when is_binary(address) ->
        if String.trim(address) == "",
          do: {:error, {:missing_option, :address}},
          else: {:ok, address}

      nil ->
        {:error, {:missing_option, :address}}

      other ->
        {:error, {:invalid_address, other}}
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

  **An accepted withdrawal is always `{:ok, _}`, with an id.** The id is the venue's
  `withdrawalId` where it sends a readable one, and otherwise the `clientTransferId` that went
  out with this request. A 2xx whose body could not be read used to come back as an error.
  That told the caller a withdrawal had failed when the venue had accepted it, and the
  obvious next step, a retry without a key, sends the money again.

  ## The memo is required on some networks and this package cannot tell you which

  The venue: *"Required for certain networks that use memos (e.g., Solana, XRP, Cosmos)."*
  It publishes no machine-readable list, so **this does not guess one**. A withdrawal to an
  exchange address on a memo network without one is credited to nobody and is generally not
  recoverable.

  `opts[:memo]` is passed through (an integer tag as its digits; a blank memo is not sent).
  **`opts[:memo_required]` is a caller's assertion, not a lookup**: passing `true` with no
  memo, or a blank one, is refused here rather than sent.

  Before anything is signed, `asset`, `network` and `address` must be non-blank strings
  (`{:error, {:invalid_asset | :invalid_network | :invalid_address, value}}`) and `amount` a
  finite number above zero (`{:error, {:invalid_decimal | :non_positive_amount, :amount,
  value}}`). A blank `opts[:client_transfer_id]` is treated as none, and one is generated.

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

    with :ok <- validate_memo(memo, Keyword.get(opts, :memo_required, false)),
         {:ok, ticker} <- withdrawal_ticker(asset),
         {:ok, network_segment} <- withdrawal_network(network),
         {:ok, destination} <- withdrawal_address(address),
         {:ok, wire_amount} <- wire_positive(amount, :amount) do
      transfer_id = transfer_id(Keyword.get(opts, :client_transfer_id))

      params =
        %{
          "address" => destination,
          # A plain-notation string from `wire_positive/2`, not `to_string/1` — on a
          # `Decimal` the latter goes through `String.Chars` and so scientific notation, and
          # a one-satoshi withdrawal went out as `"1E-8"`. The same defect
          # `execute_params/2` had; and a zero, negative or non-numeric amount is refused
          # here, where nothing has moved, rather than discovered at the venue.
          "amount" => wire_amount,
          # Always sent. A retry without one is a second withdrawal.
          "clientTransferId" => transfer_id
        }
        |> put_present("memo", wire_memo(memo))

      with {:ok, body, _headers} <-
             post(
               "/v2/withdraw/#{network_segment}/#{segment(ticker)}",
               params,
               credentials,
               opts
             ) do
        # The amount and memo as the contract types them (`Decimal`, string), not as the caller
        # held them: an integer or a string amount and an integer destination tag came back
        # on the `Withdrawal` unchanged, in fields typed otherwise.
        to_withdrawal(
          body,
          transfer_id,
          {asset, network, address, Decimal.new(wire_amount), wire_memo(memo)}
        )
      end
    end
  end

  # A caller that says the network needs a memo and then sends none is stopped here, where
  # nothing has moved, rather than at the venue after the transfer is accepted. A blank memo
  # is no memo: `""` passed this check and the venue credited the transfer to nobody.
  #
  # Public so `DpExchange.Gemini.Fake` refuses with the same function: it tested only for
  # `nil`, so `memo: ""` with `memo_required: true` was refused by the real call and accepted
  # by the fake.
  @doc """
  Whether a withdrawal's memo satisfies `memo_required`: with `true`, a memo that is not blank
  (an integer tag counts), else `{:error, :memo_required}`. Anything but `true` is `:ok`.
  """
  @spec validate_memo(term(), term()) :: :ok | {:error, :memo_required}
  def validate_memo(memo, true) do
    if present?(memo), do: :ok, else: {:error, :memo_required}
  end

  def validate_memo(_memo, _required), do: :ok

  # A blank `client_transfer_id` is no key: `"" || generate_transfer_id()` kept the empty
  # string, because it is truthy, and the withdrawal went out with an idempotency key every
  # other withdrawal shares.
  defp transfer_id(supplied) do
    if present?(supplied), do: supplied, else: generate_transfer_id()
  end

  # `memo` is `type: string` (`/v2/withdraw` request). A destination tag held as an integer
  # is sent as its digits rather than as a JSON number; a blank memo is not sent at all.
  defp wire_memo(memo) when is_integer(memo), do: Integer.to_string(memo)
  defp wire_memo(memo) when is_binary(memo), do: if(present?(memo), do: memo)
  defp wire_memo(memo), do: memo

  defp withdrawal_address(address) when is_binary(address) do
    if String.trim(address) == "",
      do: {:error, {:invalid_address, address}},
      else: {:ok, address}
  end

  defp withdrawal_address(address), do: {:error, {:invalid_address, address}}

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

  # `:id` is in `Withdrawal`'s `@enforce_keys`. A withdrawal with no id is a transfer the
  # caller cannot look up, reference in a support request, or reconcile against — and the
  # money has already left. `nil` there looks like a value.
  #
  # **The `clientTransferId` this package sent is the last id tried, and it is never
  # missing.** This used to refuse a 2xx whose body named no readable id, and raised on a body
  # that was not an object at all (REST mutation fuzz, 2026-09-27). Both told the caller the
  # withdrawal had failed after the venue had accepted it. The caller's natural next move is
  # to retry, and a retry without `opts[:client_transfer_id]` generates a new key and sends the
  # money a second time. The key that went out is a real id for this withdrawal: the venue
  # documents it as the idempotency reference for exactly this request. The body is read for
  # anything better, and a body that cannot be read adds nothing but takes nothing away.
  # The status stays `:pending`, which `withdrawal_status/1` already answers for a withdrawal
  # the venue did not describe.
  #
  # **A 2xx body that SAYS it failed is a refusal, not a withdrawal.** The spec documents
  # errors as non-2xx (`BadRequest` and friends: `{result: "error", reason, message}`) and
  # the 200 as `{withdrawalId, address, amount, currency, fee}` (`WithdrawCryptoFundsResponse`,
  # rest.yaml). Nothing documents a 200 carrying an error, but Gemini's error envelope is
  # the same on every endpoint, so a 2xx body with `result` of `"error"` / `"failed"`, or one
  # carrying an error `reason` or `message` and no withdrawal id, is returned as
  # `{:refused, body}`: reporting an accepted transfer the venue said it did not make is the
  # worse mistake. A body that merely cannot be read (not an object, or an empty object) is
  # NOT such a statement: the venue answered 2xx, which is its acceptance, the spec's
  # success shape is the only 2xx shape it documents, and the key sent is the idempotency
  # reference for the request, so success with that id is safe where a reported failure
  # invites a retry that may send the money twice. (A body that is not JSON at all never gets
  # here; `decoded_body/1` refuses it.)
  defp to_withdrawal(body, transfer_id, details) do
    if withdrawal_error_body?(body),
      do: {:refused, body},
      else: accepted_withdrawal(body, transfer_id, details)
  end

  defp withdrawal_error_body?(%{} = body) do
    failed_result?(body["result"]) or
      (not has_withdrawal_id?(body) and
         (error_text?(body["reason"]) or error_text?(body["message"])))
  end

  defp withdrawal_error_body?(_unreadable), do: false

  defp failed_result?(result) when is_binary(result),
    do: String.downcase(String.trim(result)) in ["error", "failed"]

  defp failed_result?(_other), do: false

  defp error_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp has_withdrawal_id?(body),
    do: match?({:ok, _id}, required_id(body["withdrawalId"], :id))

  defp accepted_withdrawal(body, transfer_id, {asset, network, address, amount, memo}) do
    body = if is_map(body), do: body, else: %{}

    id =
      Enum.find_value([body["withdrawalId"], body["clientTransferId"], transfer_id], fn value ->
        case required_id(value, :id) do
          {:ok, id} -> id
          _unreadable -> nil
        end
      end)

    {:ok, build_withdrawal(body, id, asset, network, address, amount, memo)}
  end

  defp build_withdrawal(body, id, asset, network, address, amount, memo) do
    %Withdrawal{
      id: id,
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

  **The reply has no `"methods"` key.** Measured against the vendor's `rest.yaml`
  (2026-09-29): `PaymentMethodsResponse` (`rest.yaml:5448` request, `:5454` response
  example; schema `:9316-9328`) is `{balances: [...], banks: [...]}` — two arrays under two
  names, neither called `"methods"`. This used to read a `"methods"` array the endpoint
  does not send, so every real response fell through to this module's bare-object or
  bare-list fallback and was decoded as a shape this endpoint never returns.

  `Core.Venue`'s `list_payment_methods/2` callback returns `[map()]` — one flat list, with
  no room for two arrays under two names — so each row is tagged `"kind" => "balance"` or
  `"kind" => "bank"` rather than losing which array it came from. A consumer filtering on
  `row["kind"]` sees the same split the venue's own response makes; one that ignores the
  key gets every funding source in one list, which is what the contract promises.

  A missing array is no rows of that kind, not an error — the venue's own example always
  sends both, but nothing states either is required. A present array that is not a list is
  unreadable.
  """
  @spec list_payment_methods(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_payment_methods(credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/payments/methods", %{}, credentials, opts) do
      payment_rows(body)
    end
  end

  defp payment_rows(%{} = body) do
    with {:ok, balances} <- payment_kind_rows(body["balances"], "balance"),
         {:ok, banks} <- payment_kind_rows(body["banks"], "bank") do
      {:ok, balances ++ banks}
    end
  end

  defp payment_rows(_other), do: {:error, :unexpected_response_shape}

  defp payment_kind_rows(nil, _kind), do: {:ok, []}

  defp payment_kind_rows(rows, kind) when is_list(rows) do
    reduce_rows(rows, &payment_kind_row(&1, kind))
  end

  defp payment_kind_rows(_unreadable, _kind), do: {:error, :unexpected_response_shape}

  defp payment_kind_row(%{} = row, kind), do: {:ok, Map.put(row, "kind", kind)}
  defp payment_kind_row(_unreadable, _kind), do: {:error, :unexpected_response_shape}

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
    with :ok <- validate_payment_details(details),
         {:ok, path} <- addbank_path(Config.opt(opts, :country, "US")) do
      # `post_once`: `details` is the caller's own map, opaque to this module, so there is
      # nothing here the venue could tell a retry by — and `HttpClient` retries a timeout or
      # a 5xx three times by default. Adding a bank account twice is not a retry, it is a
      # second payment method, and removing one is not something this API does.
      with {:ok, body, _headers} <- post_once(path, details, credentials, opts) do
        {:ok, body}
      end
    end
  end

  @doc """
  Whether `details` is a map `add_payment_method/3` can sign: the bank fields the caller
  holds. Anything else is `{:error, {:invalid_details, details}}`; a `nil` or a list raised in
  the caller's process. Exposed so `DpExchange.Gemini.Fake` refuses with this function,
  before the country and the credential.
  """
  @spec validate_payment_details(term()) :: :ok | {:error, {:invalid_details, term()}}
  def validate_payment_details(details) when is_map(details) and not is_struct(details), do: :ok
  def validate_payment_details(details), do: {:error, {:invalid_details, details}}

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

  **`clientTransferId` is sent on every call**, generated when `opts[:client_transfer_id]`
  names none — the same pattern `withdraw/6` uses for its own idempotency key, and the
  venue offers one here too (`rest.yaml:6210`, uuid4). Unlike `withdraw/6`'s field, this one
  is not documented to be idempotent: the venue states only that it is "a unique identifier
  for the internal transfer", never the `withdraw` endpoint's *"duplicate requests with the
  same clientTransferId will not create additional withdrawals"*. Absent that guarantee,
  this still sends once (`post_once/4`) rather than assume a retry is safe because an id
  happens to be attached — the id is worth sending regardless, as a correlation handle for
  reconciling with the venue, but this package will not claim a dedup behaviour the spec
  does not state.
  """
  @spec transfer_internal(String.t(), Decimal.t(), keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def transfer_internal(asset, amount, transfer_opts, credentials, opts) do
    with {:ok, from} <- required_opt(transfer_opts, :from),
         {:ok, to} <- required_opt(transfer_opts, :to),
         {:ok, currency, wire_amount} <- validate_internal_transfer(asset, amount) do
      transfer_id = transfer_id(Keyword.get(transfer_opts, :client_transfer_id))

      params = %{
        "sourceAccount" => from,
        "targetAccount" => to,
        # Full notation, and finite and above zero — see `withdraw/6`.
        "amount" => wire_amount,
        "clientTransferId" => transfer_id
      }

      # Once: the venue's own schema never says a repeated `clientTransferId` here
      # deduplicates the way `withdraw/6`'s does — see this function's own doc — so a retry
      # is not known to be safe, and an OAuth request carries no nonce to be refused on
      # replay either. See `post_once/4`.
      with {:ok, body, _headers} <-
             post_once("/v1/account/transfer/#{segment(currency)}", params, credentials, opts) do
        {:ok, body}
      end
    end
  end

  @doc """
  The lower-case currency segment and plain-notation amount `transfer_internal/5` sends, or
  the refusal.

  `asset` must be a non-blank string (`{:error, {:invalid_asset, value}}`) and `amount` a
  finite number above zero (`{:error, {:invalid_decimal | :non_positive_amount, :amount,
  value}}`). Before this, `String.downcase/1` raised on a non-string asset and any amount,
  `"abc"`, zero or a negative included, was signed into an account-to-account transfer.
  Exposed so `DpExchange.Gemini.Fake` refuses with this function, after the two account
  names and before the credential.
  """
  @spec validate_internal_transfer(term(), term()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def validate_internal_transfer(asset, amount) do
    with {:ok, currency} <- withdrawal_ticker(asset),
         {:ok, wire_amount} <- wire_positive(amount, :amount) do
      {:ok, currency, wire_amount}
    end
  end

  @doc """
  The plain-notation string `quote_conversion/4`, `convert/4` and the other money-moving calls
  send for `value`, or the refusal: a finite number above zero, else
  `{:error, {:invalid_decimal | :non_positive_amount, field, value}}`.

  Exposed so `DpExchange.Gemini.Fake` refuses with this function rather than a second copy.
  """
  @spec validate_amount(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  def validate_amount(value, field), do: wire_positive(value, field)

  @doc """
  Whether `withdraw/6` would get past its own checks, without sending anything: the asset,
  network and destination must be non-blank strings and the amount a finite number above zero
  (`{:error, {:invalid_asset | :invalid_network | :invalid_address, value}}`,
  `{:error, {:invalid_decimal | :non_positive_amount, :amount, value}}`), in that order.

  Exposed so `DpExchange.Gemini.Fake` refuses with this function, after the memo rule and
  before the credential, as the real call does.
  """
  @spec validate_withdrawal(term(), term(), term(), term()) :: :ok | {:error, term()}
  def validate_withdrawal(asset, network, amount, address) do
    with {:ok, _ticker} <- withdrawal_ticker(asset),
         {:ok, _segment} <- withdrawal_network(network),
         {:ok, _destination} <- withdrawal_address(address),
         {:ok, _wire_amount} <- wire_positive(amount, :amount) do
      :ok
    end
  end

  @doc """
  Whether `estimate_withdrawal_fee/5` would get past its own checks, without sending anything:
  `opts[:address]` first (`{:error, {:missing_option, :address}}` or
  `{:error, {:invalid_address, value}}`), then the asset, network and amount as in
  `validate_withdrawal/4`.

  Exposed so `DpExchange.Gemini.Fake` refuses with this function.
  """
  @spec validate_fee_estimate(term(), term(), term(), keyword()) :: :ok | {:error, term()}
  def validate_fee_estimate(asset, network, amount, opts) do
    with {:ok, _address} <- required_address(opts),
         {:ok, _ticker} <- withdrawal_ticker(asset),
         {:ok, _segment} <- withdrawal_network(network),
         {:ok, _wire_amount} <- wire_positive(amount, :amount) do
      :ok
    end
  end

  @doc """
  Whether `network` is one `get_deposit_address/4` would build a path from: a non-blank
  string, else `{:error, {:invalid_network, value}}`.

  Exposed so `DpExchange.Gemini.Fake` refuses with this function.
  """
  @spec validate_deposit_network(term()) :: :ok | {:error, {:invalid_network, term()}}
  def validate_deposit_network(network) do
    with {:ok, _segment} <- withdrawal_network(network), do: :ok
  end

  @doc """
  The label `request_approved_address/5` requires, or
  `{:error, {:missing_required_field, :label}}`. Exposed so `DpExchange.Gemini.Fake` refuses
  with this function, before the credential.
  """
  @spec validate_label(term()) :: :ok | {:error, {:missing_required_field, :label}}
  def validate_label(label) do
    with {:ok, _label} <- required_label(label), do: :ok
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

  **`label` is required** (`rest.yaml:5702` lists it beside `address`). A `nil` or empty one
  is `{:error, {:missing_required_field, :label}}` before a request goes out, then a blank or
  non-string `network` or `address` is `{:error, {:invalid_network | :invalid_address, value}}`
  (see `validate_approved_address/2`). `opts[:memo]` is sent when given; the venue documents
  it for networks that use one (cosmos).
  """
  @spec request_approved_address(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def request_approved_address(network, address, label, credentials, opts) do
    with {:ok, label} <- required_label(label),
         :ok <- validate_approved_address(network, address) do
      params =
        %{"address" => address, "label" => label}
        |> put_present("memo", Keyword.get(opts, :memo))

      # Still `post/4`, deliberately. Unlike the two writes above, the thing being
      # created IS the key: the request names one address on one network, and re-sending
      # it asks for the same allowlist entry rather than a second one. That is the test
      # `post_once/4` states — "can the venue tell the second attempt from the first" —
      # and here it can, from the payload this module builds itself. Recorded so the
      # next sweep does not flatten all three into one rule.
      with {:ok, body, _headers} <-
             post("/v1/approvedAddresses/#{segment(network)}/request", params, credentials, opts) do
        {:ok, body}
      end
    end
  end

  # `rest.yaml:5702` lists `label` in the request's `required` beside `address`. This used to
  # omit it when `nil` and send the request anyway, so the venue's refusal for a missing
  # field was the first the caller heard of it.
  defp required_label(label) when is_binary(label) and label != "", do: {:ok, label}
  defp required_label(_label), do: {:error, {:missing_required_field, :label}}

  @doc """
  Removes `address` from the allowlist for `network` —
  `/v1/approvedAddresses/{network}/remove`.

  Generally immediate where addition is not: the venue is slow to widen what funds may reach
  and quick to narrow it.
  """
  @spec remove_approved_address(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def remove_approved_address(network, address, credentials, opts) do
    with :ok <- validate_approved_address(network, address),
         {:ok, body, _headers} <-
           post(
             "/v1/approvedAddresses/#{segment(network)}/remove",
             %{"address" => address},
             credentials,
             opts
           ) do
      {:ok, body}
    end
  end

  @doc """
  Whether `network` and `address` are ones `request_approved_address/5` and
  `remove_approved_address/4` would sign: non-blank strings, else
  `{:error, {:invalid_network | :invalid_address, value}}`, the network first.

  A `nil` or blank network built `/v1/approvedAddresses//request`, and a `nil` address went
  into the allowlist payload as JSON `null`, on the two calls that widen and narrow where
  funds may be sent. Exposed so `DpExchange.Gemini.Fake` refuses with this function, after the
  label and before the credential.
  """
  @spec validate_approved_address(term(), term()) ::
          :ok | {:error, {:invalid_network | :invalid_address, term()}}
  def validate_approved_address(network, address) do
    with {:ok, _segment} <- withdrawal_network(network),
         {:ok, _address} <- withdrawal_address(address) do
      :ok
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
  @transactions_page 300
  @transactions_max_pages 50
  @accounts_page_max 500
  @staking_history_page_max 500
  @clearing_trades_page_max 300
  @funding_report_rows_default 8760

  @spec get_transactions(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_transactions(credentials, opts) do
    with :ok <- validate_history_opts(:transactions, opts) do
      params = put_present(%{}, "timestamp_nanos", nanos_param(Keyword.get(opts, :since)))
      fetch_transactions(params, Keyword.get(opts, :limit), credentials, opts)
    end
  end

  defp fetch_transactions(params, nil, credentials, opts) do
    walk_transactions(Map.put(params, "limit", @transactions_page), credentials, opts, [], 0)
  end

  defp fetch_transactions(params, limit, credentials, opts) do
    with {:ok, rows, _token} <-
           transactions_page(Map.put(params, "limit", limit), credentials, opts),
         do: {:ok, rows}
  end

  # **The request and the response were both read from the wrong shape.** Measured against
  # the vendor's `rest.yaml`, 2026-09-29:
  #
  #   * the window parameter is `timestamp_nanos`, in nanoseconds. This sent `timestamp` in
  #     milliseconds, a field the endpoint does not name, so `:since` was not a filter at all;
  #   * the page size is `limit`. This sent `limit_transactions`, so `:limit` was ignored and
  #     every call got the venue's default of 100;
  #   * the reply is `{"results": [...], "continuationToken": ...}`, not a bare array. The
  #     wrapper was flattened as if it were a row list.
  #
  # And the token is the reason the reply is not the whole answer. Returned alone, the first
  # page of 100 read as the account's complete history. `Core.Venue` types this call `[map()]`,
  # so there is nowhere to hand a cursor back: without `:limit` this follows the token to the
  # end, at the documented maximum page of 300, and refuses rather than truncates if it runs
  # past `@transactions_max_pages` (above). With `:limit` the caller asked for at most that
  # many, and gets one page.

  defp walk_transactions(_params, _credentials, _opts, _acc, page)
       when page >= @transactions_max_pages,
       do: {:error, {:too_many_pages, @transactions_max_pages}}

  defp walk_transactions(params, credentials, opts, acc, page) do
    case transactions_page(params, credentials, opts) do
      {:ok, rows, nil} ->
        {:ok, acc |> Enum.reverse([rows]) |> Enum.concat()}

      # **An empty page ends the walk, whatever token comes with it.** The venue describes
      # the token as "for subsequent requests" and says nothing of it ever being absent on
      # the last page, so a walk that only stopped on a missing token would, against a venue
      # that always sends one, fetch an empty page, then either refuse an echoed token as
      # `:repeated_continuation_token` or run into `@transactions_max_pages` — turning a
      # complete history into an error. A page with no rows has nothing after it.
      {:ok, [], _token} ->
        {:ok, acc |> Enum.reverse() |> Enum.concat()}

      {:ok, rows, token} ->
        # A token the venue echoes back unchanged would page forever.
        if Map.get(params, "continuation_token") == token do
          {:error, :repeated_continuation_token}
        else
          # The spec says the token and `timestamp_nanos` are not sent together.
          next = params |> Map.delete("timestamp_nanos") |> Map.put("continuation_token", token)
          walk_transactions(next, credentials, opts, [rows | acc], page + 1)
        end

      error ->
        error
    end
  end

  defp transactions_page(params, credentials, opts) do
    with {:ok, body, _headers} <- post("/v1/transactions", params, credentials, opts),
         do: transactions_body(body)
  end

  defp transactions_body(%{"results" => rows} = body) when is_list(rows) do
    case body["continuationToken"] do
      token when is_binary(token) and token != "" -> {:ok, rows, token}
      nil -> {:ok, rows, nil}
      "" -> {:ok, rows, nil}
      _unreadable -> {:error, :unexpected_response_shape}
    end
  end

  defp transactions_body(_other), do: {:error, :unexpected_response_shape}

  defp nanos_param(nil), do: nil
  defp nanos_param(%DateTime{} = at), do: DateTime.to_unix(at, :nanosecond)
  defp nanos_param(other), do: other

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
  @spec get_notional_balances(map(), term(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_notional_balances(credentials, currency, opts) do
    with {:ok, ticker} <- notional_currency(currency) do
      # `segment/1`: a currency carrying `/` or `?` must not change the signed path.
      path = "/v1/notionalbalances/" <> segment(ticker)

      with {:ok, body, _headers} <- post(path, %{}, credentials, opts) do
        flattened_rows(body)
      end
    end
  end

  # A non-string currency was a `FunctionClauseError` in the caller, and a blank one asked for
  # `/v1/notionalbalances/` — a resource the caller never named.
  defp notional_currency(currency) when is_binary(currency) do
    if String.trim(currency) == "",
      do: {:error, {:invalid_currency, currency}},
      else: {:ok, String.downcase(currency)}
  end

  defp notional_currency(currency), do: {:error, {:invalid_currency, currency}}

  @doc """
  Whether `get_notional_balances/3` would accept `currency`, without sending anything:
  `:ok` for a non-blank string, else `{:error, {:invalid_currency, value}}`. Exposed so
  `DpExchange.Gemini.Fake` refuses with this function, before the credential.
  """
  @spec validate_notional_currency(term()) :: :ok | {:error, {:invalid_currency, term()}}
  def validate_notional_currency(currency) do
    with {:ok, _ticker} <- notional_currency(currency), do: :ok
  end

  @doc """
  What Gemini charged this account for *holding* assets — `/v1/custodyaccountfees`.

  Custody fees come straight out of the balance with no trade behind them, so a consumer
  reconciling balances against fills alone finds a gap this is the only explanation for.

  **An empty list means nothing was charged in the window asked for.** It does not mean the
  account holds nothing in custody, and it does not mean Gemini does not charge — an account
  with no custody balance and an account billed nothing this period return the same thing.

  `opts[:since]` and `opts[:limit]` page it, under the venue's own parameter names.

  **A full page with no `:limit` is refused, not returned as every fee.** The venue's page is
  10 by default and 50 at most (`rest.yaml:3446`) with no cursor, so the first 10 charges were
  answered as the whole history. With no `:limit` this asks for 50, and a page that full is
  `{:error, {:history_truncated, 50}}`: narrow with `:since`, or pass `:limit` to take exactly
  one page on purpose. See `get_transfers/2`.
  """
  @spec list_custody_fees(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_custody_fees(credentials, opts) do
    params =
      %{}
      |> put_present("timestamp", timestamp_param(Keyword.get(opts, :since)))
      |> put_present("limit_transfers", Keyword.get(opts, :limit) || @transfers_page_max)

    with :ok <- validate_history_opts(:custody_fees, opts),
         {:ok, body, _headers} <- post("/v1/custodyaccountfees", params, credentials, opts),
         {:ok, rows} <- flattened_rows(body),
         :ok <- transfers_complete(rows, Keyword.get(opts, :limit)) do
      {:ok, rows}
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
    with {:ok, rows, headers} <- post("/v1/balances/staking", %{}, credentials, opts),
         {:ok, rows} <- list_rows(rows) do
      at = venue_time_or_nil(headers)
      to_staking_balances(rows, at)
    end
  end

  # One unreadable row refuses the page rather than leaving a gap in it — `to_fills/2`'s rule.
  # One unreadable row refuses the whole page rather than leaving a gap in it — the rule
  # `to_fills/2` states: a list with an entry silently missing reconciles to a smaller
  # number and looks complete.
  defp reduce_rows(rows, builder) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case builder.(row) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  defp to_staking_balances(rows, at) do
    reduce_rows(rows, &to_staking_balance(&1, at))
  end

  # `:asset` and `:staked` are both in `StakingBalance`'s `@enforce_keys`, so its `new/1`
  # refuses a `nil` in either — and nothing here calls `new/1`, the struct being built
  # literally as everywhere in this family, so that check never ran.
  #
  # `asset` had the same `String.upcase(row["currency"] || "")` that
  # `to_staking_transaction/1` was fixed for: `""` is not a weaker answer but a different
  # kind of wrong, because it passes every `nil` check a consumer might write while naming
  # no asset at all. The fix went into one of the three functions that shared the line.
  defp to_staking_balance(row, at) when is_map(row) do
    # Optional fields: absent is `nil`, but one the venue SENT and this package cannot read
    # fails the row — `nil` would claim the venue did not say.
    with {:ok, asset} <- required_id(row["currency"], :asset),
         {:ok, staked} <- required_decimal(row["balance"], :staked),
         {:ok, tradable} <- order_decimal(row, "available", :strict),
         {:ok, withdrawable} <- order_decimal(row, "availableForWithdrawal", :strict),
         {:ok, by_provider} <- by_provider(row["balanceByProvider"]) do
      {:ok,
       %StakingBalance{
         asset: String.upcase(asset),
         staked: staked,
         available_to_trade: tradable,
         available_for_withdrawal: withdrawable,
         by_provider: by_provider,
         venue_time: at,
         provider: :gemini
       }}
    end
  end

  defp to_staking_balance(_row, _at), do: {:error, :unexpected_response_shape}

  # `by_provider` used to be hardcoded `%{}` with a comment claiming the venue never breaks
  # the position down — it does. `rest.yaml:6565,6573` (schema `:9429-9465`):
  # `balanceByProvider` is `{<providerId uuid>: {balance: <number>}}`, sent on every row in
  # the endpoint's own example. Empty now means what the comment always said it should —
  # the venue reported no breakdown for THIS row — rather than a value this decoder never
  # read.
  #
  # Absent (or `null`) is no breakdown. A breakdown that is present and not readable — not an
  # object, an entry without a readable `balance` — fails the row: dropping the entry would
  # present a partial split as the whole one.
  defp by_provider(nil), do: {:ok, %{}}

  defp by_provider(%{} = breakdown) do
    Enum.reduce_while(breakdown, {:ok, %{}}, fn
      {provider_id, %{"balance" => balance}}, {:ok, acc} when not is_nil(balance) ->
        case decimal(balance) do
          nil -> {:halt, {:error, :unexpected_response_shape}}
          amount -> {:cont, {:ok, Map.put(acc, provider_id, amount)}}
        end

      _unreadable, _acc ->
        {:halt, {:error, :unexpected_response_shape}}
    end)
  end

  defp by_provider(_unreadable), do: {:error, :unexpected_response_shape}

  @doc """
  Rewards accrued over a window — `POST /v1/staking/rewards`.

  **The window is part of the value.** The same number is a good day or a poor quarter
  depending on it, so `opts[:since]` and `opts[:until]` are sent to the venue and the bounds
  the venue reports back travel on the struct. Where the venue reports none, they stay `nil`
  rather than being filled in from the request — the venue is free to clamp a window, and a
  package that echoed the ask would report a period that was never served.

  `:apy_pct` is the rate **at accrual**, which is not what `get_staking_rates/1` reports
  today. That is what lets a caller reconcile a reward against the rate that produced it.

  `opts[:since]` goes out in ISO datetime with timezone format (`rest.yaml:6896`), not the
  epoch-millisecond number every other filtered endpoint in this module sends, and it is
  **required** at the venue (`rest.yaml:6885` lists it in the request schema's `required`
  alongside `request` and `nonce`) — refused here as `{:error, {:missing_option, :since}}`
  before a request goes out, rather than sent without it or defaulted to a window this
  package invented. `opts[:until]` is the same format and stays optional, matching the
  venue.
  """
  @spec get_staking_rewards(map(), keyword()) ::
          {:ok, [StakingReward.t()]} | {:error, term()} | {:refused, term()}
  def get_staking_rewards(credentials, opts) do
    with {:ok, since} <- required_opt(opts, :since),
         :ok <- validate_history_opts(:staking_rewards, opts) do
      params =
        %{"since" => iso_timestamp_param(since)}
        |> put_present("until", iso_timestamp_param(Keyword.get(opts, :until)))
        |> put_present("providerId", Keyword.get(opts, :provider_id))

      with {:ok, body, _headers} <- post("/v1/staking/rewards", params, credentials, opts),
           {:ok, periods} <- reward_periods(body) do
        reduce_rows(periods, &to_staking_reward/1)
      end
    end
  end

  # **The reply is a map of maps, and this read it as a list.** Measured against the vendor's
  # `rest.yaml`, 2026-09-29: `StakingRewardsResponse` is keyed by provider UUID, then by
  # currency, and each entry carries `ratePeriods`, one per rate the position earned at, each
  # with its own `apyPct`, `accrualTotal`, `numberOfAccruals`, `firstAccrualAt` and
  # `lastAccrualAt`. This decoded a flat array of rows with `amount`, `accrualCount`, `since`
  # and `until`, fields the endpoint does not send, against a fixture written the same way.
  # Given the documented reply it could not produce a single reward.
  #
  # One `StakingReward` per rate period, because that is what the type is for: its `apy_pct`
  # is "the rate at accrual", which only a period has, and its window is the period's first
  # and last accrual. The provider and currency come from the keys the venue nested them
  # under. Anything that is not the documented nesting is refused.
  defp reward_periods(%{} = body) do
    body
    |> Enum.reduce_while({:ok, []}, fn {provider_id, currencies}, {:ok, acc} ->
      case provider_periods(provider_id, currencies) do
        {:ok, periods} -> {:cont, {:ok, [periods | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp reward_periods(_other), do: {:error, :unexpected_response_shape}

  defp provider_periods(provider_id, %{} = currencies) do
    currencies
    |> Enum.reduce_while({:ok, []}, fn
      {currency, %{"ratePeriods" => periods}}, {:ok, acc} when is_list(periods) ->
        tagged = Enum.map(periods, &{provider_id, currency, &1})
        {:cont, {:ok, [tagged | acc]}}

      _unreadable, _acc ->
        {:halt, {:error, :unexpected_response_shape}}
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp provider_periods(_provider_id, _other), do: {:error, :unexpected_response_shape}

  # `:asset` and `:amount` are both in `StakingReward`'s `@enforce_keys`. Same `""` asset
  # substitution as `to_staking_balance/2` and `to_staking_transaction/1`; same answer.
  defp to_staking_reward({provider_id, currency, period}) when is_map(period) do
    with {:ok, asset} <- required_id(currency, :asset),
         {:ok, amount} <- required_decimal(period["accrualTotal"], :amount),
         {:ok, apy} <- order_decimal(period, "apyPct", :strict),
         {:ok, count} <- accrual_count(period["numberOfAccruals"]),
         {:ok, first} <- stated_time(period["firstAccrualAt"]),
         {:ok, last} <- stated_time(period["lastAccrualAt"]) do
      {:ok,
       %StakingReward{
         asset: String.upcase(asset),
         amount: amount,
         provider_id: provider_id,
         apy_pct: apy,
         accrual_count: count,
         period_start: first,
         period_end: last,
         provider: :gemini
       }}
    end
  end

  defp to_staking_reward(_unreadable), do: {:error, :unexpected_response_shape}

  # A count is a whole number or absent; whatever else the venue sent was passed through
  # untouched into a field typed as an integer.
  defp accrual_count(nil), do: {:ok, nil}
  defp accrual_count(count) when is_integer(count) and count >= 0, do: {:ok, count}
  defp accrual_count(_unreadable), do: {:error, :unexpected_response_shape}

  # Absent is `nil`; a time the venue sent and this package cannot read fails the row.
  defp stated_time(nil), do: {:ok, nil}

  defp stated_time(value) do
    case staking_time(value) do
      nil -> {:error, :unexpected_response_shape}
      at -> {:ok, at}
    end
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

  `opts[:since]` and `opts[:until]` go out **in ISO datetime with timezone format**
  (`rest.yaml:6729,6733`; the request example at `:6758` gives
  `"2022-11-01T00:00:00.000Z"`), not the epoch-millisecond number `timestamp_param/1` sends
  every other filtered endpoint in this module — measured against the vendor's own spec,
  2026-09-29. A `DateTime` is formatted to ISO 8601; a caller's own already-ISO string
  passes through unchanged.

  **The reply is nested, not flat.** `rest.yaml:6770-6794` (schemas `:9499-9545`):
  an array of `{providerId, transactions: [{transactionId, transactionType,
  amountCurrency, amount, dateTime}]}`, one entry per provider the account has staked
  with — not the flat array of transaction rows this used to assume, a shape the endpoint
  does not send. `providerId` comes from the parent entry, since a `StakingTransaction`
  in the reply carries none of its own.

  **A full page with no `:limit` is refused, not returned as the whole history.** The venue's
  page is 50 by default and 500 at most (`/v1/staking/history`, `rest.yaml:6677`) with no cursor, so the 50 most
  recent transactions were answered as everything. With no `:limit` this asks for 500, and a
  reply that full is `{:error, {:history_truncated, 500}}`: narrow with `:since`/`:until`, or
  pass `:limit` to take exactly one page on purpose.
  """
  @spec get_staking_history(map(), keyword()) ::
          {:ok, [StakingTransaction.t()]} | {:error, term()} | {:refused, term()}
  def get_staking_history(credentials, opts) do
    limit = Keyword.get(opts, :limit)

    params =
      %{}
      |> put_present("since", iso_timestamp_param(Keyword.get(opts, :since)))
      |> put_present("until", iso_timestamp_param(Keyword.get(opts, :until)))
      |> put_present("limit", limit || @staking_history_page_max)
      |> put_present("providerId", Keyword.get(opts, :provider_id))

    with :ok <- validate_history_opts(:staking_history, opts),
         {:ok, groups, _headers} <- post("/v1/staking/history", params, credentials, opts),
         {:ok, groups} <- list_rows(groups),
         {:ok, transactions} <- to_staking_history(groups),
         :ok <- page_complete(transactions, limit, @staking_history_page_max) do
      {:ok, transactions}
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
    staking_write("/v1/staking/stake", :stake, asset, amount, credentials, opts)
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
    staking_write("/v1/staking/unstake", :unstake, asset, amount, credentials, opts)
  end

  defp staking_write(path, type, asset, amount, credentials, opts) do
    with {:ok, provider_id} <- required_provider_id(opts),
         {:ok, currency, wire_amount} <- validate_staking_terms(asset, amount) do
      params = %{
        "currency" => currency,
        "amount" => wire_amount,
        "providerId" => provider_id
      }

      with {:ok, body, _headers} <- post_once(path, params, credentials, opts) do
        to_staking_transaction(body, type)
      end
    end
  end

  @doc """
  The upper-case currency and plain-notation amount `stake/4` and `unstake/4` send, or the
  refusal.

  `asset` must be a non-blank string (`{:error, {:invalid_asset, value}}`) and `amount` a
  finite number above zero (`{:error, {:invalid_decimal | :non_positive_amount, :amount,
  value}}`). Before this, `String.upcase/1` and `Decimal.to_string/2` raised in the caller on
  a non-string asset or a non-`Decimal` amount, and a zero, negative or NaN `Decimal` was
  signed into a staking write. Exposed so `DpExchange.Gemini.Fake` refuses with this function,
  after the provider and before the credential.
  """
  @spec validate_staking_terms(term(), term()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def validate_staking_terms(asset, amount) do
    with {:ok, ticker} <- withdrawal_ticker(asset),
         {:ok, wire_amount} <- wire_positive(amount, :amount) do
      {:ok, String.upcase(ticker), wire_amount}
    end
  end

  defp required_provider_id(opts) do
    case Keyword.get(opts, :provider_id) do
      nil -> {:error, :missing_provider_id}
      provider_id -> {:ok, provider_id}
    end
  end

  # `StakingTransaction` names `:id`, `:type`, `:asset`, `:amount` and `:provider` in its
  # `@enforce_keys`, so its `new/1` refuses a `nil` in any of them. Nothing here calls
  # `new/1` — the struct is built literally, as everywhere in this family — so that check
  # never ran and none of them was guarded.
  #
  # `asset` had the sharper version. `String.upcase(row["currency"] || "")` answered `""` for
  # an absent currency: not a weaker answer but a different kind of wrong, because `""`
  # passes every `nil` check a consumer might write while naming no asset at all. It is the
  # same substitution this module already records for `to_string(nil)` on `order_id`, and the
  # same answer applies.
  #
  # `type` is not read from the body at all — see `build_staking_transaction/5` below for
  # why — so the reply naming no `transactionType` (it never does, on either of these two
  # endpoints) can no longer produce `:other`, an answer that used to be true only because
  # this decoder was misreading a shape it never receives.
  defp to_staking_transaction(row, type) when is_map(row) do
    with {:ok, id} <- required_id(row["transactionId"] || row["id"], :id),
         {:ok, asset} <- required_id(row["currency"], :asset),
         {:ok, amount} <- required_decimal(row["amount"], :amount),
         # `:lenient`, like `place_order/3`: this is the reply to a stake or redemption the venue
         # has ALREADY accepted, so an error would read as "nothing moved" and invite a retry.
         # An optional field it sent and this package cannot read is `nil` here.
         {:ok, paid} <- order_decimal(row, "amountPaidSoFar", :lenient),
         {:ok, remaining} <- order_decimal(row, "amountRemaining", :lenient) do
      at = staking_time(row["requestInitiated"])
      {:ok, build_staking_transaction(row, id, asset, amount, type, {paid, remaining, at})}
    end
  end

  # This used to hand-build the exact struct the guards above exist to prevent — `id: nil`,
  # `asset: ""`, `amount: nil` — for any row that was not a map. A staking transaction naming
  # no id, no asset and no amount is not a degraded record, it is a placeholder wearing the
  # shape of one.
  defp to_staking_transaction(_row, _type), do: {:error, :unexpected_response_shape}

  # `type` comes from **which endpoint was called**, not from a `transactionType` field —
  # `StakingDeposit` (`rest.yaml:9466-9497`) and `StakingWithdrawal` (`:9663-9692`) are
  # `stake/4`'s and `unstake/4`'s own reply shapes, and neither carries one; that field
  # belongs to `StakingTransaction`, the *history* endpoint's row (see
  # `to_staking_history_transaction/2`), a different schema this decoder used to assume by
  # mistake. `venue_type` stays `nil` for the same reason: the venue did not say a word here
  # for this package to keep beside the normalised one.
  #
  # `venue_time` is `requestInitiated` (`rest.yaml:7044`, schema `:9689`, ISO datetime with
  # timezone, e.g. `"2022-11-02T19:49:20.153Z"`) — present only on `StakingWithdrawal`. A
  # stake response has no time field at all, so `staking_time(nil)` answers `nil`, not a
  # read time standing in for one the venue never gave.
  defp build_staking_transaction(row, id, asset, amount, type, {paid, remaining, at}) do
    %StakingTransaction{
      id: id,
      type: type,
      venue_type: nil,
      asset: String.upcase(asset),
      amount: amount,
      amount_paid_so_far: paid,
      amount_remaining: remaining,
      provider_id: row["providerId"],
      venue_time: at,
      provider: :gemini
    }
  end

  # `get_staking_history/2`'s reply — an array of `{providerId, transactions: [...]}`
  # (`rest.yaml:6770-6794`, schemas `:9499-9545`) — not the flat array of transaction rows
  # this used to assume. One unreadable group, or one unreadable transaction inside a
  # group, refuses the whole page rather than leaving a gap in it — the rule `to_fills/2`
  # above already states: a list with an entry silently missing reconciles to a smaller
  # number and looks complete.
  defp to_staking_history(groups) do
    with {:ok, per_group} <- reduce_rows(groups, &staking_history_group/1) do
      {:ok, List.flatten(per_group)}
    end
  end

  defp staking_history_group(%{"providerId" => provider_id, "transactions" => transactions})
       when is_list(transactions) do
    reduce_rows(transactions, &to_staking_history_transaction(&1, provider_id))
  end

  defp staking_history_group(_unreadable), do: {:error, :unexpected_response_shape}

  # `providerId` lives on the PARENT group, not on the transaction — a `StakingTransaction`
  # row (`rest.yaml:9499-9518`) carries `transactionId`, `transactionType`,
  # `amountCurrency`, `amount`, `dateTime` and nothing that names the provider. `asset`
  # comes from `amountCurrency`, not `currency`, which this row does not have either.
  #
  # `dateTime` goes through `staking_time/1`, which already reads both shapes the venue's
  # own `TimestampType` allows — an epoch number (the field's own example,
  # `1667418560153`, and its description "in milliseconds") or an ISO string, should the
  # venue ever send one here the way `requestInitiated` does elsewhere.
  defp to_staking_history_transaction(txn, provider_id) when is_map(txn) do
    with {:ok, id} <- required_id(txn["transactionId"], :id),
         {:ok, asset} <- required_id(txn["amountCurrency"], :asset),
         {:ok, amount} <- required_decimal(txn["amount"], :amount),
         {:ok, paid} <- order_decimal(txn, "amountPaidSoFar", :strict),
         {:ok, remaining} <- order_decimal(txn, "amountRemaining", :strict),
         {:ok, at} <- stated_time(txn["dateTime"]) do
      {:ok,
       %StakingTransaction{
         id: id,
         type: staking_type(txn["transactionType"]),
         venue_type: txn["transactionType"],
         asset: String.upcase(asset),
         amount: amount,
         amount_paid_so_far: paid,
         amount_remaining: remaining,
         provider_id: provider_id,
         venue_time: at,
         provider: :gemini
       }}
    end
  end

  defp to_staking_history_transaction(_txn, _provider_id),
    do: {:error, :unexpected_response_shape}

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

  # Zero and negatives are valid Unix times and would date a movement to 1970 — refused, as
  # `epoch_ms/1` refuses them (falls through to the `nil` catch-all below).
  defp staking_time(value) when is_integer(value) and value > 0 do
    unit = if value >= 1_000_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, at} -> at
      {:error, _reason} -> nil
    end
  end

  defp staking_time(value) when is_float(value), do: staking_time(trunc(value))

  # A fractional epoch (`1667418560.153` seconds) arrives as a `Decimal` under
  # `floats: :decimals`; truncated to a whole number, then read like any integer epoch.
  #
  # The exponent is bounded BEFORE any arithmetic: `Decimal.round/3` and `to_integer/1` on
  # `1E+999999999` build an integer of a billion digits. A real epoch has a small exponent.
  defp staking_time(%Decimal{coef: coef, exp: exp} = value)
       when is_integer(coef) and exp >= -30 and exp <= 18,
       do: value |> Decimal.round(0, :down) |> Decimal.to_integer() |> staking_time()

  defp staking_time(%Decimal{}), do: nil

  # `/v1/staking/rewards` names its window in this shape — `firstAccrualAt`/`lastAccrualAt`
  # are ISO 8601 strings (`rest.yaml`'s own example: `"2022-08-23T20:00:00.000Z"`), not the
  # epoch number every other staking endpoint sends. Reusing the epoch-only clauses above for
  # a period whose bounds this venue names would have silently read every reward's window as
  # unreported, since `staking_time/1` fell to its own `nil` catch-all.
  # `TimestampType` (`rest.yaml:7900`) also allows the epoch as a STRING, in seconds or
  # milliseconds (`"1495127793000"`), which `DateTime.from_iso8601/1` refuses — a numeric
  # string used to read as "the venue reported no time". A whole-string integer is the epoch;
  # anything else is tried as ISO 8601.
  defp staking_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> staking_time(integer)
      _not_an_epoch -> staking_iso_time(value)
    end
  end

  defp staking_time(_other), do: nil

  defp staking_iso_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

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

  **`symbol` is read through `SymbolFormat`, not carried raw.** The venue's own example
  response sends it lowercase (`"btcgusdperp"`), the same case `/v1/symbols` uses — this
  used to pass `row["symbol"]` straight onto the struct unchanged, so a real position
  arrived as `symbol: "btcgusdperp"` beside `to_order/1`'s and every other reader's
  uppercase form. Nothing here failed loudly: the test fixtures that exist all wrote
  `"BTCGUSDPERP"` by hand, and none of them ever asserted on `position.symbol` at all, so
  the venue's real casing was never exercised. Perpetuals take the same `:nomatch` path
  through `CanonicalPair.to_canonical/2` that produces the uppercased, unsplit form
  `SymbolFormat`'s own moduledoc documents — `to_canonical_symbol/1` is the same
  conversion `to_order/1` already applies to a symbol from the same family of endpoints.
  """
  @spec get_positions(map(), keyword()) ::
          {:ok, [Position.t()]} | {:error, term()} | {:refused, term()}
  def get_positions(credentials, opts) do
    with {:ok, body, headers} <- post("/v1/positions", %{}, credentials, opts) do
      at = venue_time_or_nil(headers)
      with {:ok, rows} <- position_rows(body), do: to_positions(rows, at)
    end
  end

  # A reply without its position list is unreadable, not flat. `[]` for it said the account
  # holds no positions — the most dangerous empty in this module, because a caller sizes
  # risk and hedges from it.
  defp position_rows(%{"openPositions" => rows}) when is_list(rows), do: {:ok, rows}
  defp position_rows(%{"openPositions" => nil}), do: {:ok, []}
  defp position_rows(rows) when is_list(rows), do: {:ok, rows}
  defp position_rows(_other), do: {:error, :unexpected_response_shape}

  # Refuses a position row this package cannot read, rather than reporting one that says
  # nothing about what is held.
  #
  # `Core.Types.Position` enforces `:symbol`, `:side` and `:quantity`, and its `new/1` refuses
  # a `nil` in any of them. Nothing here called `new/1` — the struct is built literally, as
  # everywhere in this family — so that check never ran, and all three could be `nil` at once:
  # `position_symbol/1` passes a `nil` through, and `position_side/1` and `position_size/1`
  # both answer `nil` for a quantity `decimal/1` could not read.
  #
  # A position is a claim about what an account holds. One naming no instrument, or stating
  # no size, is not a weaker claim — it is not a claim at all, and it sits in a list of real
  # positions looking like one.
  #
  # **A flat row is not a position, and is dropped.**
  #
  # This used to build one with `side: nil`, on the reasoning that "a quantity of exactly
  # zero has no side, and guessing one would invent a direction the venue did not state".
  # That reasoning is right and is not what changed — `:long` for a flat row would still be
  # a direction nobody stated. What changed is that the question is moot once the row is not
  # built, and the old answer was a value with no meaning in the contract:
  # `Core.Types.Position` enforces `:side` and types it `:long | :short` with no `nil` in it,
  # so `side: nil` was reachable only because this decoder builds the struct literally and
  # never calls `new/1`.
  #
  # `Position.from_signed_quantity/1` states the resolution — "a zero-quantity position
  # should generally not be built at all: a closed position is not an open one" — and the
  # venue agrees with it: this list is called `openPositions`, and a zero row in it is not
  # open.
  #
  # Dropping rather than widening the contract is the opposite call from the one `Trade` got
  # the same day, and the difference is where the `nil` comes from. A `nil` trade id is a
  # fact the venue states about a print that really happened; a `nil` position side is an
  # artifact of a row that should not exist. Legalising it would also let a genuine decode
  # bug arrive looking like "flat".
  #
  # A quantity that could not be READ is still a refusal, and that distinction is the one
  # this must not blur: one is a decode failure, the other a fact about the account.
  defp to_position(row, at) when is_map(row) do
    with {:ok, symbol} <- required_position_symbol(position_symbol(row["symbol"])),
         {:ok, quantity} <- required_decimal(row["quantity"], :quantity) do
      case position_side(quantity) do
        nil ->
          :flat

        side ->
          {:ok, position_struct(row, at, symbol, side, position_size(quantity))}
      end
    end
  end

  # A row that is not a map at all. This used to build a `%Position{}` with `symbol`, `side`
  # and `quantity` all `nil` and hand it back inside `{:ok, positions}` — the same fabricating
  # fallback `dp_exchange_robinhood.Rest.to_order/1` carried, in a different type and a
  # different package. A caller could not tell it from a real position the venue had declined
  # to describe: every field was plausible-looking `nil` and the tuple said success.
  defp to_position(_row, _at), do: {:error, :unexpected_response_shape}

  # One unreadable row refuses the whole reply rather than leaving a gap in it. A position
  # list with an entry silently missing reads as "you hold none of that instrument", which is
  # a different and more dangerous claim than "this response could not be read".
  defp to_positions(rows, at) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_position(row, at) do
        {:ok, position} -> {:cont, {:ok, [position | acc]}}
        :flat -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, positions} -> {:ok, Enum.reverse(positions)}
      error -> error
    end
  end

  defp required_position_symbol(nil), do: {:error, {:missing_required_field, :symbol}}
  defp required_position_symbol(symbol), do: {:ok, symbol}

  defp position_struct(row, at, symbol, side, quantity) do
    %Position{
      symbol: symbol,
      side: side,
      quantity: quantity,
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

  # The venue's own case, whatever it is — `to_canonical_symbol/1` uppercases (and, for a
  # spot pair, splits) it. `nil` stays `nil`: a position with no symbol has nothing to
  # canonicalise, and `to_canonical_symbol/1` requires a binary.
  defp position_symbol(nil), do: nil

  defp position_symbol(symbol) when is_binary(symbol),
    do: SymbolFormat.to_canonical_symbol(symbol)

  defp position_symbol(_not_a_symbol), do: nil

  # The contract types this as an atom, and the venue sends "spot" or "perp". A word this
  # package does not know is `nil` rather than the nearest atom that fits — an instrument
  # kind is what a caller routes on.
  defp position_instrument("perp"), do: :perp
  defp position_instrument("spot"), do: :spot
  defp position_instrument(_other), do: nil

  # A quantity of exactly zero has no side, and guessing one would invent a direction the
  # venue did not state.
  #
  # This and `position_size/1` below used to carry a `nil` clause for a quantity `decimal/1`
  # could not read. `to_position/2` now guards that with `required_decimal/2` and refuses the
  # row, so a `nil` can no longer reach either — dialyzer said so, and both clauses are gone
  # rather than left as dead branches that read like a case someone still has to think about.
  defp position_side(quantity) do
    case Decimal.compare(quantity, Decimal.new(0)) do
      :lt -> :short
      :gt -> :long
      :eq -> nil
    end
  end

  defp position_size(quantity), do: Decimal.abs(quantity)

  @doc """
  The perpetuals margin account — `POST /v1/margin`.

  Collateral, leverage, buying and selling power, and **the estimated liquidation price**,
  which `get_positions/2` does not publish. A caller judging how much room is left reads it
  here.

  Returned as the venue's own map. Its eleven fields divide margin four ways — by position,
  by open order, by buy side and by sell side — and a struct that kept only a total would
  drop the split a caller sizing its next order needs.

  `opts[:symbol]` is **required** — `rest.yaml:7158` lists it in the request schema's
  `required` alongside `request` and `nonce`, and the venue's own example
  (`"BTC-GUSD-PERP"`) names one contract, not the account as a whole. Missing it is
  `{:error, {:missing_option, :symbol}}` before a request is made, rather than a request
  the venue would refuse for the same reason. It goes through `SymbolFormat`, the same as
  every other private call that takes a symbol (`margin_preview_params/1` below, `to_order/1`),
  rather than the caller's raw string sent unchanged.
  """
  @spec get_account_margin(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_account_margin(credentials, opts) do
    with {:ok, symbol} <- required_opt(opts, :symbol) do
      params = %{"symbol" => SymbolFormat.to_exchange_symbol(symbol)}

      with {:ok, body, _headers} <- post("/v1/margin", params, credentials, opts) do
        {:ok, body}
      end
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

  **With no `:since` the venue answers the last 24 hours only** ("Default value is 24h in
  past", `rest.yaml:7201`), so an unwindowed call is a day, not the account's history.
  `opts[:since]` and `opts[:to]` are the venue's `since` and `to` query parameters
  (milliseconds, or a `DateTime`). They are documented as *query* parameters, not body
  fields, so they are appended to the path and signed with it, exactly as
  `funding_payment_report/2` does for its documented query — the spec's own request example
  for this path shows the bare path, so this signing is inferred from the sibling and has not
  been measured against the live venue.
  """
  @spec list_funding_payments(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_funding_payments(credentials, opts) do
    with :ok <- validate_history_opts(:funding_payments, opts),
         {:ok, body, _headers} <- post(funding_payments_path(opts), %{}, credentials, opts) do
      flattened_rows(body)
    end
  end

  defp funding_payments_path(opts) do
    query =
      []
      |> maybe_param("since", timestamp_param(Keyword.get(opts, :since)))
      |> maybe_param("to", timestamp_param(Keyword.get(opts, :to)))
      |> Enum.reverse()

    case query do
      [] -> "/v1/perpetuals/fundingPayment"
      pairs -> "/v1/perpetuals/fundingPayment?" <> URI.encode_query(pairs)
    end
  end

  @doc """
  The funding payment report as JSON —
  `/v1/perpetuals/fundingpaymentreport/records.json`.

  **This is a `POST`, not a `GET`.** The vendor's spec defines only a `post:` for this
  path (`rest.yaml:7412`) — the sibling `.xlsx` report one path up (`:7308`) is the `get:`,
  and the two used to be read as the same shape. Sent as a GET, the venue's routing either
  404s or reaches a handler that never parses this package's query string, either of which
  this package would have reported as an empty or unreadable report rather than the wrong
  verb.

  **The query string is still part of what is signed**, exactly as on the `.xlsx` sibling:
  the venue's own request example (`:7479`) gives `request` as the full path *with* the
  query string attached — `?fromDate=...&toDate=...&numRows=...` — not the bare path a
  POST's signed payload usually carries. This builds that query once with `report_path/2`
  and sends it as the POST's own URL, so the string that is signed and the string the venue
  receives are the same one.

  `opts[:from]` and `opts[:to]` are dates, `opts[:rows]` a count. The venue's own default is
  **8760 rows** — a year of hourly funding — and this package does not send one, because a
  page size chosen here would silently truncate a report the caller asked for in full.

  **The venue's cap still applies, so a reply that reaches it is refused when no `:rows` was
  given:** `{:error, {:history_truncated, 8760}}`. The cap is a row count and the reply says
  nothing when it cut the report short, so 8760 rows is either the whole answer or the first
  slice of a longer one. Narrow with `:from`/`:to`, or pass `:rows` to take exactly that many
  on purpose.
  """
  @spec funding_payment_report(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def funding_payment_report(credentials, opts) do
    path = report_path("/v1/perpetuals/fundingpaymentreport/records.json", opts)

    with {:ok, body, _headers} <- post(path, %{}, credentials, opts),
         {:ok, rows} <- flattened_rows(body),
         :ok <- page_complete(rows, Keyword.get(opts, :rows), @funding_report_rows_default) do
      {:ok, rows}
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

  defp maybe_param(pairs, name, %Decimal{} = value),
    do: [{name, decimal_string(value)} | pairs]

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

  `opts[:symbol]` is **required** — `rest.yaml:2255-2257` lists it in the request schema's
  `required` alongside `request` and `nonce` ("The trading pair for which to calculate
  pair-specific buying and selling power"), and the venue's own request example sends it as
  the plain native form (`"btcusd"`). Missing it is `{:error, {:missing_option, :symbol}}`
  before a request is made, rather than a request the venue would refuse for the same
  reason.

  **Found empty of this field entirely** while building this package's spec-example
  conformance suite (`test/dp_exchange/gemini/spec_examples_test.exs`): this used to POST
  `%{}`, an empty body, against an endpoint whose own schema requires `symbol` — every real
  call to this endpoint would have been rejected by the venue for a missing required field,
  silently, since nothing in this repository's fakes or fixtures ever sent this request
  anywhere that checked. Fixed to require and send it, the same way `get_account_margin/2`
  already does for its own (perpetuals) `symbol` requirement.
  """
  @spec get_margin_account(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_margin_account(credentials, opts) do
    with {:ok, symbol} <- required_opt(opts, :symbol) do
      params = %{"symbol" => SymbolFormat.to_exchange_symbol(symbol)}

      with {:ok, body, _headers} <- post("/v1/margin/account", params, credentials, opts) do
        {:ok, body}
      end
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
      margin_rate_rows(body)
    end
  end

  # Unreadable is not empty: `{:ok, []}` for a reply without its list said no rates.
  defp margin_rate_rows(%{"rates" => rates}) when is_list(rates), do: {:ok, rates}
  defp margin_rate_rows(%{"rates" => nil}), do: {:ok, []}
  defp margin_rate_rows(rates) when is_list(rates), do: {:ok, rates}
  defp margin_rate_rows(_other), do: {:error, :unexpected_response_shape}

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

  `side` is `buy` or `sell` and `type` is `market` or `limit` (`rest.yaml:2426`); anything
  else is `{:error, {:unknown_side, side}}` / `{:error, {:unknown_order_type, type}}` before
  a request goes out, rather than being sized as though it were a market sell.
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

    with :ok <- preview_side(to_string(side)),
         {:ok, sized} <- margin_preview_size(base, to_string(type), to_string(side), request),
         {:ok, price} <- preview_number(Map.get(request, :price), nil, :price) do
      {:ok, put_present(sized, "price", price)}
    end
  end

  defp margin_preview_params(_request), do: {:error, :missing_order_fields}

  # **Every number is checked as `place_order/3`'s are.** These went through
  # `decimal_string/1`, so `"abc"`, zero, a negative or a NaN `Decimal` was signed into the
  # preview and a margin figure came back for an order nobody could place. `nil` is absent,
  # answered with the preview's own vocabulary (`missing`) where the field is required and
  # left out where it is not (`missing` is `nil`).
  defp preview_number(nil, nil, _field), do: {:ok, nil}
  defp preview_number(nil, missing, _field), do: {:error, missing}
  defp preview_number(value, _missing, field), do: wire_positive(value, field)

  # The venue's own rule, enforced rather than discovered: a market **buy** is sized in quote
  # currency and everything else in base. Sending `amount` on a market buy previews a
  # different order than the caller described.
  defp margin_preview_size(base, "market", "buy", request) do
    with {:ok, spend} <-
           preview_number(Map.get(request, :total_spend), :total_spend_required, :total_spend) do
      {:ok, Map.put(base, "totalSpend", spend)}
    end
  end

  defp margin_preview_size(base, "limit", _side, request) do
    with {:ok, amount} <- required_amount(request),
         {:ok, _price} <- required_preview_price(request) do
      {:ok, Map.put(base, "amount", amount)}
    end
  end

  defp margin_preview_size(base, "market", _sell, request) do
    with {:ok, amount} <- required_amount(request), do: {:ok, Map.put(base, "amount", amount)}
  end

  # `type` is `market` or `limit` (`rest.yaml:2426`). Anything else used to fall into the
  # sized-by-`amount` branch and go out as given, so a type the venue has no sizing rule for
  # was previewed as though it had one.
  defp margin_preview_size(_base, type, _side, _request),
    do: {:error, {:unknown_order_type, type}}

  defp preview_side(side) when side in ["buy", "sell"], do: :ok
  defp preview_side(side), do: {:error, {:unknown_side, side}}

  # Not `required_price/1` above: that one reports `{:missing_field, :price}` for an order
  # this package is about to place, and this reports `:price_required` for a preview it is
  # about to describe. Two callers, two vocabularies, and merging them would report a
  # placement error on a call that places nothing.
  defp required_preview_price(request) do
    preview_number(Map.get(request, :price), :price_required, :price)
  end

  defp required_amount(request) do
    preview_number(Map.get(request, :amount), :amount_required, :amount)
  end

  # Full notation, never scientific: `1E-8` is not a number this venue reads.
  #
  # **`Decimal.to_string/1` defaults to SCIENTIFIC**, and `to_string/1` on a `%Decimal{}`
  # reaches that same default through `String.Chars`. An exponent is not exotic:
  # `Decimal.normalize/1` — the ordinary way to strip trailing zeros — turns `150.00` into
  # `1.5E+2`, and anything below a millionth carries one by construction.
  #
  # This helper existed, with that first line on it, while `place_order/3` sent its `amount`
  # and `price` through bare `to_string/1` a few hundred lines above. The generic
  # `maybe_put/3` and `maybe_param/3` now refuse a `%Decimal{}` before it can reach
  # `String.Chars` at all, so a new money field cannot repeat it by being added to a map.
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)

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

    # `post_once`. The account NAME is the only thing here a venue could dedupe on, and this
    # package has no evidence it does — Gemini documents no uniqueness constraint on it, and
    # a second subaccount is an artifact only an Administrator can clear up. A caller whose
    # call times out re-issues it deliberately, which is the right way round; guessing that
    # the venue would have refused the duplicate is not.
    with {:ok, body, _headers} <- post_once("/v1/account/create", params, credentials, opts),
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
      # Once: `account` names the CURRENT shortname, so a rename that took effect and lost its
      # reply, sent again, finds no such account and reads as a refusal. See `post_once/4`.
      with {:ok, body, _headers} <- post_once("/v1/account/rename", params, credentials, opts),
           do: {:ok, body}
    else
      {:error, :nothing_to_rename}
    end
  end

  @doc """
  Every subaccount in the group — `POST /v1/account/list`.

  **The venue caps this at 500 and does not paginate.** `limit_accounts` is both the maximum
  and the default, so a group with more than 500 subaccounts returns a truncated list with
  nothing to say it was truncated. **A full page with no `:limit` is therefore refused, not
  returned as every account:** `{:error, {:history_truncated, 500}}`. Pass `:limit` to take
  exactly one page on purpose, or `:since` to narrow — the venue reads it as "created on or
  before" (`rest.yaml:6037`), despite the name every other call gives it.

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

    with :ok <- validate_history_opts(:accounts, opts),
         {:ok, body, _headers} <- post("/v1/account/list", params, credentials, opts),
         {:ok, rows} <- flattened_rows(body),
         :ok <- page_complete(rows, Keyword.get(opts, :limit), @accounts_page_max) do
      {:ok, rows}
    end
  end

  # A page that is exactly as full as the venue's maximum, asked for without a `:limit`, may
  # be the whole answer or the first slice of it, and nothing in the reply says which.
  defp page_complete(rows, nil, page_max) when length(rows) >= page_max,
    do: {:error, {:history_truncated, page_max}}

  defp page_complete(_rows, _limit, _page_max), do: :ok

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
  and says public clients must not send it. A blank `client_id` is
  `{:error, :client_id_required}` and a blank `refresh_token` is
  `{:error, :refresh_token_required}`, before anything is sent: neither can succeed, and a
  refused refresh is not a reason to discard the stored token. The shape of the success body
  is unmeasured (the vendor spec does not document `/auth/token`), so it is returned as sent.
  """
  @spec refresh_access_token(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def refresh_access_token(client_id, refresh_token, opts)
      when is_binary(client_id) and is_binary(refresh_token) do
    cond do
      String.trim(client_id) == "" -> {:error, :client_id_required}
      String.trim(refresh_token) == "" -> {:error, :refresh_token_required}
      true -> post_refresh(client_id, refresh_token, opts)
    end
  end

  defp post_refresh(client_id, refresh_token, opts) do
    form =
      %{
        "client_id" => client_id,
        "refresh_token" => refresh_token,
        "grant_type" => "refresh_token"
      }
      |> put_present("client_secret", Keyword.get(opts, :client_secret))

    url = Config.opt(opts, :auth_url, "https://exchange.gemini.com") <> "/auth/token"
    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    # Sent once. The refresh token is single-use (see above): a refresh that timed out after
    # the venue rotated the token, retried with the OLD one, comes back `invalid_grant` and
    # the new pair is lost with the response, ending the session over a transport blip.
    # `Core.HttpClient` retries timeouts and 5xx by default, so the retry is turned off here
    # and the failure is the caller's to handle.
    http_opts = opts |> Keyword.put(:retry_attempts, 1) |> request_opts()
    form_body = URI.encode_query(form)

    case HttpClient.request(:post, url, headers, form_body, http_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decoded_body(body)

      {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
        {:refused, refused_token_body(body)}

      {:ok, %{status: status, body: body}} ->
        status_error(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The OAuth error (`{"error": "invalid_grant"}`), as the map it is. Bodies arrive as bytes
  # (`decode_body: false`, see `request_opts/1`), which handed the caller the raw JSON string
  # where it had always received the decoded map; text that is not JSON stays as the venue
  # wrote it.
  defp refused_token_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _not_json} -> body
    end
  end

  defp refused_token_body(body), do: body

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
      # A blank token authenticates nothing, so signing it revokes nothing and is refused here.
      %{access_token: token} when is_binary(token) and token != "" ->
        # Once: a revoke that took effect leaves the token dead, so a repeat is answered 401
        # and reads as a refusal of a revoke that worked. See `post_once/4`.
        with {:ok, body, _headers} <-
               post_once(
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

      # Once: a repeated offer is a second offer to the counterparty. See `post_once/4`.
      with {:ok, body, _headers} <- post_once("/v1/clearing/new", params, credentials, opts),
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

      # Once, for the same reason as `create_clearing_order/3`.
      with {:ok, body, _headers} <-
             post_once("/v1/clearing/broker/new", params, credentials, opts),
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

  **The venue answers a cancel that did not take with HTTP 200** and `result: "failed"`
  (`rest.yaml:3978`, its own `failedCancel` example). That is `{:refused, body}` here, not
  `{:ok, body}`: a caller matching `{:ok, _}` would have treated an order still standing as
  cancelled. A 200 naming no `result` at all is `{:error, :unexpected_response_shape}`.
  """
  @spec cancel_clearing_order(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def cancel_clearing_order(clearing_id, credentials, opts) when is_binary(clearing_id) do
    params = %{"clearing_id" => clearing_id}

    # Once: a cancel sent again after it took effect is answered as a cancel that did not.
    with {:ok, body, _headers} <- post_once("/v1/clearing/cancel", params, credentials, opts) do
      clearing_result(body, "ok")
    end
  end

  # The clearing writes that answer HTTP 200 for a failure too: the outcome is in `result`,
  # and only the documented success word is a success. `{:refused, body}` keeps the venue's
  # own `reason`/`details`/`message` for the caller.
  defp clearing_result(%{"result" => expected} = body, expected), do: {:ok, body}
  defp clearing_result(%{"result" => _other} = body, _expected), do: {:refused, body}
  defp clearing_result(_body, _expected), do: {:error, :unexpected_response_shape}

  @doc """
  Confirms a clearing order — `POST /v1/clearing/confirm`. **This executes a trade.**

  **The venue re-asks for every term.** `symbol`, `amount`, `price` and `side` are required
  alongside the `clearing_id`, and this package does not fill any of them in from the order
  it is confirming: the point of re-stating them is that the confirming side says what it
  believes it is agreeing to, and a package that read them back from the venue would confirm
  whatever the venue had, which is the one thing the check exists to prevent.

  `side` here is **the confirming party's own side**, which is the opposite of the side the
  order was created with.

  **Only `result: "confirmed"` is a confirmation.** A refused confirm is still HTTP 200 —
  `result: "error"` with a `reason` and `message` (`rest.yaml:4072`, its `failedConfirm`
  example) — and is returned as `{:refused, body}`, not `{:ok, body}`: a caller matching
  `{:ok, _}` on a call that executes a trade would have recorded a trade that never happened.
  A 200 naming no `result` is `{:error, :unexpected_response_shape}`.
  """
  @spec confirm_clearing_order(String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def confirm_clearing_order(clearing_id, request, credentials, opts)
      when is_binary(clearing_id) do
    with {:ok, params} <- clearing_order_params(request) do
      params = Map.put(params, "clearing_id", clearing_id)

      # Once, like the create: a confirm that executed and lost its reply, sent again, is
      # answered "already confirmed", which reads as `{:refused, _}` for a trade that
      # happened. See `post_once/4`.
      with {:ok, body, _headers} <- post_once("/v1/clearing/confirm", params, credentials, opts),
           do: clearing_result(body, "confirmed")
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

  **Each window needs both of its bounds** (`rest.yaml:4184`: "Requires `expiration_end` if
  set", and the same for `submission_*`). One bound alone is
  `{:error, {:window_needs_both_bounds, :expiration | :submission}}` before a request goes
  out, rather than a request the venue refuses or reads as unbounded.
  """
  @spec list_clearing_orders(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_clearing_orders(credentials, opts) do
    with :ok <- window_pair(opts, :expiration_start, :expiration_end, :expiration),
         :ok <- window_pair(opts, :submission_start, :submission_end, :submission),
         :ok <- validate_history_opts(:clearing_orders, opts) do
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
        clearing_rows(body, "orders")
      end
    end
  end

  defp window_pair(opts, start_key, end_key, window) do
    case {Keyword.get(opts, start_key), Keyword.get(opts, end_key)} do
      {nil, nil} -> :ok
      {nil, _end} -> {:error, {:window_needs_both_bounds, window}}
      {_start, nil} -> {:error, {:window_needs_both_bounds, window}}
      {_start, _end} -> :ok
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
    with :ok <- window_pair(opts, :expiration_start, :expiration_end, :expiration),
         :ok <- validate_history_opts(:clearing_brokers, opts) do
      params =
        %{}
        |> put_present("symbol", clearing_symbol(Keyword.get(opts, :symbol)))
        |> put_present("expiration_start", timestamp_param(Keyword.get(opts, :expiration_start)))
        |> put_present("expiration_end", timestamp_param(Keyword.get(opts, :expiration_end)))

      with {:ok, body, _headers} <- post("/v1/clearing/broker/list", params, credentials, opts) do
        clearing_rows(body, "orders")
      end
    end
  end

  @doc """
  Clearing trades — `POST /v1/clearing/trades`.

  Orders that **completed**, where `list_clearing_orders/2` shows what is outstanding. Rows
  are camelCase here and snake_case there; the venue's own keys are kept either way rather
  than normalised into one shape that matches neither response.

  `opts[:limit]` maps to the venue's `limit_per_account` — default 100, maximum 300 — and
  `opts[:since_nanos]` to `timestamp_nanos`, which is **nanoseconds**, not the milliseconds
  every other Gemini timestamp uses. A `DateTime` is converted to nanoseconds.

  **A full page with no `:limit` is refused, not returned as every trade.** The venue's page
  is 100 by default and 300 at most (`rest.yaml:4700`) with no cursor, so the first 100
  trades were answered as the whole list. With no `:limit` this asks for 300, and a reply
  that full is `{:error, {:history_truncated, 300}}`: narrow with `:since_nanos`, or pass
  `:limit` to take exactly one page on purpose.
  """
  @spec list_clearing_trades(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_clearing_trades(credentials, opts) do
    limit = Keyword.get(opts, :limit)

    with :ok <- validate_history_opts(:clearing_trades, opts),
         {:ok, body, _headers} <-
           post("/v1/clearing/trades", clearing_trades_params(opts), credentials, opts),
         {:ok, rows} <- clearing_rows(body, "results"),
         :ok <- page_complete(rows, limit, @clearing_trades_page_max) do
      {:ok, rows}
    end
  end

  defp clearing_trades_params(opts) do
    %{}
    |> put_present("symbol", clearing_symbol(Keyword.get(opts, :symbol)))
    |> put_present("timestamp_nanos", nanos_param(Keyword.get(opts, :since_nanos)))
    |> put_present("limit_per_account", Keyword.get(opts, :limit) || @clearing_trades_page_max)
  end

  # The four terms the venue requires on every clearing write, and none of them defaulted.
  defp clearing_order_params(%{symbol: symbol, amount: amount, price: price, side: side})
       when is_binary(symbol) do
    # **Checked like `place_order/3`'s numbers.** These went out through `decimal_string/1`
    # and `to_string/1`, so `"abc"`, `0`, `-1` and a `Decimal` NaN were signed into an offer
    # to a counterparty, and `side: :hold` went out as `"hold"`. A confirm or create here
    # commits a trade; the refusal belongs before anything is signed.
    with {:ok, wire_amount} <- wire_positive(amount, :amount),
         {:ok, wire_price} <- wire_positive(price, :price),
         {:ok, wire_side} <- wire_side(side) do
      {:ok,
       %{
         "symbol" => SymbolFormat.to_exchange_symbol(symbol),
         "amount" => wire_amount,
         "price" => wire_price,
         "side" => wire_side
       }}
    end
  end

  defp clearing_order_params(_request), do: {:error, :missing_clearing_terms}

  defp clearing_symbol(nil), do: nil
  defp clearing_symbol(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  defp clearing_side(nil), do: nil
  defp clearing_side(side), do: to_string(side)

  # **A key absent is not a key present and empty.** `Map.get/2` answered `[]` for both — a
  # body with `"orders": null` AND a body with no `"orders"` key at all, the second of which
  # the vendor's own OpenAPI never documents (`/v1/clearing/list`, `/v1/clearing/broker/list`
  # and `/v1/clearing/trades` all shape their 200 as `{orders: [...]}` / `{results: [...]}`,
  # never a bare object without it). A reply missing the list entirely is unreadable, and a
  # caller polling for outstanding clearing orders on a malformed reply saw "nothing
  # outstanding" — the one shape it cannot tell apart from the truth — instead of an error it
  # could retry.
  defp clearing_rows(%{} = body, key) do
    case Map.fetch(body, key) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, nil} -> {:ok, []}
      {:ok, _unreadable} -> {:error, :unexpected_response_shape}
      :error -> {:error, :unexpected_response_shape}
    end
  end

  defp clearing_rows(rows, _key) when is_list(rows), do: {:ok, rows}
  defp clearing_rows(_body, _key), do: {:error, :unexpected_response_shape}

  # **A reply that is a genuine JSON array decodes as sent; anything else is unreadable.**
  # `List.wrap/1` used to sit at each of these call sites: `List.wrap(nil) == []` turned an
  # unreadable body into a silent "nothing here", and `List.wrap(%{...})` turned an object
  # this package could not parse into a one-row list holding that whole object — the wrapper
  # treated as a row. Both looked like a plausible answer; neither was one the venue gave.
  defp list_rows(rows) when is_list(rows), do: {:ok, rows}
  defp list_rows(_unreadable), do: {:error, :unexpected_response_shape}

  # `/v1/tradevolume` nests one list per symbol inside the outer list — `get_trade_volume/2`'s
  # own doc. Flattening only makes sense once the outer shape is confirmed to be a list;
  # flattening a wrapped scalar would still be `list_rows/1`'s substitution, just delayed a
  # step.
  defp flattened_rows(rows) do
    with {:ok, rows} <- list_rows(rows), do: {:ok, List.flatten(rows)}
  end

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
    # The zone is required to be the literal `GMT`, as RFC 7231's IMF-fixdate requires. It
    # used to be matched and discarded, so a header in any other zone was read as UTC and
    # could be hours off: a plausible time with the wrong meaning.
    with [_day, d, mon, y, time, "GMT"] <- String.split(value, [" ", ", "], trim: true),
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

  # Under `floats: :decimals` (see `decoded_body/1`) the same non-integer number is a
  # `Decimal`; truncated toward zero exactly as the float clause does.
  defp epoch_ms(%Decimal{} = value) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: nil,
      else: value |> Decimal.round(0, :down) |> Decimal.to_integer() |> epoch_ms()
  end

  # Positive only. Zero and negatives are not a venue instant: they dated a fill to 1970 and
  # slipped past `required_time/1`'s refusal, which waits for the `nil` this now answers.
  defp epoch_ms(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> datetime
      _error -> nil
    end
  end

  # A WHOLE-string parse only, and the `_rest` this used to discard is why.
  #
  # `Integer.parse/1` answers `{integer, rest}` for anything that merely STARTS with digits,
  # so ignoring `rest` read a venue timestamp out of text that is not one: `"2026-09-14"`
  # became 2026 and then `~U[1970-01-01 00:00:02.026Z]`, and `"1787936147.5"` — a seconds
  # timestamp carrying a fraction — became `~U[1970-01-21 16:38:56.147Z]`. Both are real
  # `DateTime`s, which is the whole problem: a caller cannot tell one from the venue's own
  # instant, and 1970 is not obviously wrong to code that only checks for `nil`.
  #
  # It also walked straight past the guard built to stop exactly this. `required_time/1`
  # refuses with `{:unparseable_venue_timestamp, value}` when this answers `nil` — and it
  # never answered `nil` for those inputs, so a `Fill` (an execution record, timestamped for
  # reconciliation) would have carried a 1970 instant instead of the read being refused.
  defp epoch_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> epoch_ms(integer)
      _partial_or_error -> nil
    end
  end

  defp epoch_ms(_other), do: nil

  # Delegated to `Rest.refusal_reason/1` rather than duplicated. This was a second, exact
  # copy of the same `String.to_atom/1` on venue-supplied text, so the atom-table DoS it
  # carried had to be found and fixed twice — and could as easily have been fixed in only
  # one of the two. One implementation, one place to get it right.
  #
  # `body` is passed RAW, not through this module's own `decoded_body/1` — see
  # `Rest.refusal_reason/1`'s moduledoc. That decoder's old fallback collapsed unparseable JSON
  # to `%{}`, which would discard a plain-text refusal body before `refusal_reason/1` gets
  # a chance to keep it; `refusal_reason/1` now decodes a raw body itself.
  defp refusal(body, opts),
    do: body |> Rest.refusal_reason() |> nonce_reach(Keyword.get(opts, :nonce_mode))

  # dp-exchange-core issues #34, #36 and #37. Under the clock-anchored modes finer than
  # milliseconds, "has not increased" (the incremental validator's own sentence) means the
  # key's mark is above what that mode can send, and a host should stop retrying:
  #
  #   * under `:incremental_us`, the next step is `:incremental_ns`;
  #   * under `:incremental_ns`, no 64-bit nonce reaches the mark. That is NOT proof the key
  #     must be rotated: a client before this package may have set it with larger integers
  #     (#37), and `{:incremental_ns, scale: k}` reaches above 64 bits;
  #   * under `{:incremental_ns, scale: k}`, the next step is a larger declared scale.
  #
  # One shape for all three, so a host already handling it needs no new clause; which step
  # it means is the mode the host chose. The venue's sentence travels with it. Other modes keep
  # `{:invalid_nonce, message}` (see `Auth`'s moduledoc).
  defp nonce_reach({:invalid_nonce, message} = reason, mode) when is_binary(message) do
    if sub_millisecond_mode?(mode) and
         message |> String.downcase() |> String.contains?("has not increased"),
       do: {:nonce_mark_out_of_reach, message},
       else: reason
  end

  defp nonce_reach(reason, _mode), do: reason

  defp sub_millisecond_mode?(mode) when mode in [:incremental_us, :incremental_ns], do: true
  defp sub_millisecond_mode?({:incremental_ns, _scale}), do: true
  defp sub_millisecond_mode?(_mode), do: false

  # A 2xx body this package cannot decode is NOT an empty object. See
  # `DpExchange.Gemini.Rest.decoded_body/1` for the full note; the short version is that
  # collapsing an unparseable success body to `%{}` produces a well-formed struct with
  # every field `nil`, handed back as `{:ok, value}`, and the realistic source is a `200`
  # that never reached the venue — a captive portal or CDN maintenance page answering
  # `200 text/html`.
  #
  # On THIS module it is worse than on the public one, because these are the authenticated
  # calls. `%{}` reached `to_order/1` as a map and became an order with no id and no status
  # reported as success from `place_order/4`, and reached the balance readers as an empty
  # portfolio. Refuse instead.
  #
  # `floats: :decimals`: a JSON number with a fraction or exponent becomes a `Decimal`, an
  # integer stays an integer. Every consumer below reads numbers through `decimal/1`,
  # `epoch_ms/1`, `staking_time/1` or `required_id/2`, each of which accepts a `Decimal`.
  defp decoded_body(body) when is_binary(body) do
    case Jason.decode(body, floats: :decimals) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:undecodable_response, :gemini}}
    end
  end

  defp decoded_body(body), do: {:ok, body}

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, %Decimal{} = value),
    do: Map.put(map, key, decimal_string(value))

  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  defp take_params(opts, keys) do
    opts
    |> Keyword.take(keys)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: bounded(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.new/1` raises on a string that is not a number. `Decimal.parse/1`, requiring
  # the whole string be consumed (`{d, ""}`), is what this package already does in
  # `ws_decode.ex`; every copy of this helper now matches it.
  # `Decimal.parse/1` requiring the whole string be consumed is NOT a sufficient guard on
  # its own, which is the half this copy was missing. "NaN", "Inf" and "-Inf" all parse
  # fully and case-insensitively — `"-nan"` and `"inf"` too — so each arrived here as a
  # perfectly well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than the raise this parse replaced, and it fails a long way from the
  # cause. Measured: `Decimal.add(nan, 1)` is NaN, so it poisons a consumer's arithmetic
  # silently; `Decimal.compare(nan, _)` RAISES `invalid_operation: operation on NaN`, in
  # the consumer's own process, with a message naming Decimal rather than the venue that
  # sent it. An Infinity is quieter still — it compares greater than everything and never
  # raises at all.
  #
  # `dp_exchange_webull` found this and guarded both of its own copies; the other four
  # venues guarded none of their nine. Fixed where it was found, not where it applied —
  # which is why this comment is in each of them now rather than one of them.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        bounded(parsed)

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

  # A finite `Decimal` whose exponent is one a price or size can have, or `nil`. `"1e999999999"`
  # parses, and `Decimal.compare/2` or `Decimal.add/2` against it aligns exponents by building
  # an integer of that many digits: one venue string stalls the caller's process. NaN and
  # Infinity carry no integer coefficient and are refused here too.
  defp bounded(%Decimal{coef: coef, exp: exp} = value)
       when is_integer(coef) and exp >= -100 and exp <= 100,
       do: value

  defp bounded(_nan_infinite_or_unbounded), do: nil

  # One path segment, percent-encoded. Symbols, networks and tickers were interpolated raw,
  # so a value carrying `/` or `?` changed the path or started a query, and on a signed
  # request the venue was asked for a resource the caller never named. Every value the venue
  # documents is unreserved already, so for them this changes nothing.
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
