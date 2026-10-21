defmodule DpExchange.Gemini.OptionKeys do
  @moduledoc """
  The options each `DpExchange.Gemini` facade function reads, in one place, and the check that
  refuses the rest.

  A misspelt `limt:` or `sinse:` that is silently ignored answers a different question from
  the one the caller asked, with a plausible value: the "nearby substitute where there should
  be an error" this family exists to avoid. Every facade function that takes a keyword `opts`
  calls `check/2` (or `check!/2` for a read with no error channel) at the boundary, before
  anything is sent and before an internal key such as `:limiter` is added, and
  `DpExchange.Gemini.Fake` calls the very same function, so the real adapter and the fake
  cannot drift on what they accept.

  ## What a function accepts

  The keys in the table below (`@own`), which are the keys that function, and what it
  forwards to, actually reads, plus the shared transport keys it reads
  (`DpExchange.Core.Options.transport_options/0`: credentials, environment, base URL, the
  `Req` test seams, the limiter, timeout, weight, body cap and retry knobs). `allowed/1`
  answers a function's whole list.

    * A call that **sends an HTTP request** reads every shared transport key
      (`Rest.request_opts/1` and `Private.request_opts/1` forward them all to
      `Core.HttpClient`), except those `not_read/1` names: the writes that are sent exactly
      once (`@sent_once`) never honour `:retry_attempts` or `:retry_delay`, and
      `refresh_access_token/3` posts to `:auth_url`, so it reads neither `:environment` nor
      `:base_url`, and is sent once (no `:retry_attempts`, no `:retry_delay`). Those
      keys are refused as `{:unknown_option, key}`. `:credentials` is accepted everywhere: one
      credential set is handed to every call, and one a call does not need changes no answer.
    * A call that **sends no request** accepts no transport key but `:credentials`:
      `market_status/1` (answers `:open` from nothing) and, with `:environment` as well
      because it picks the feed (or, for `live?/1`, the environment), `subscribe/2`,
      `unsubscribe/2`, `update_symbols/2`, `subscribe_notices/1`, `coverage/1`,
      `coverage_by_kind/1`, `wanted/1` and `live?/1`. A `:timeout` or `:weight` there is
      refused, since nothing would read it.

  A function the venue does not serve
  (`DpExchange.Core.Venue.not_supported/0`) is not in the table: it answers `:not_supported`
  whatever the options.

  Signed calls (`@signed`) also read `:nonce_mode`, `:auth_scheme` and `:account`. The three
  group-level calls (`create_account/1`, `rename_account/3`, `list_accounts/1`, `get_roles/1`)
  never send `:account`, so a stray one is refused there rather than dropped
  (`@group_signed`). A funding payment report takes no symbol, so a `:symbol` there is refused
  as well: it used to be accepted and dropped.

  ## What it answers

    * `:ok`
    * `{:error, {:unknown_option, key}}` - the first key (in the caller's order) not accepted
    * `{:error, {:invalid_options, opts}}` - `opts` is not a keyword list. A value under a
      credential-looking key (`:api_secret`, `:credentials`, `:access_token`, ...) is shown as
      `:redacted`, at any depth: the argument that was passed in the options' place is
      sometimes the credentials themselves.

  `check!/2` raises `ArgumentError` for either, for the reads (`coverage/1`,
  `coverage_by_kind/1`, `wanted/1`, `live?/1`) whose result has no room for an error.

  ## Order

  Where a function has a positional argument this package can check without any state (a
  market-data symbol), that is checked first; every other function checks its options first,
  before the credential and before anything is signed or sent.
  """

  alias DpExchange.Core.Options

  # Keys every signed (authenticated) call reads: `Auth.headers/5` reads `:nonce_mode`,
  # `Private.auth_scheme/2` reads `:auth_scheme`, and `Private.with_account/3` adds `:account`
  # to every account-level payload.
  @signed [:nonce_mode, :auth_scheme, :account]

  # The calls that act on the key or the group rather than on one account never send
  # `:account` (`@group_level_paths` in `Private`).
  @group_signed [:nonce_mode, :auth_scheme]

  # The calls that send no HTTP request and address no feed: `market_status/1` answers `:open`
  # from nothing. They accept `:credentials` (the one key every call may be handed) and their
  # own keys; every other transport key is refused as `{:unknown_option, key}`.
  @no_request [:market_status]

  # The calls that send no HTTP request but address a feed (or, for `live?/1`, resolve an
  # environment): they read `:environment` to pick the feed (`Supervisor.feed_name/1`), plus
  # their own keys, and no other transport key.
  @feed_addressing [
    :subscribe,
    :unsubscribe,
    :update_symbols,
    :subscribe_notices,
    :coverage,
    :coverage_by_kind,
    :wanted,
    :live?
  ]

  # Writes the venue cannot tell a repeat of (`Private.post_once/5`): `:retry_attempts` is
  # forced to 1 whatever the caller gave, so it and `:retry_delay` (the wait before a retry that
  # never happens) are never honoured and are refused here.
  @sent_once [
    :place_order,
    :cancel_order,
    :cancel_all_orders,
    :commit_conversion,
    :convert,
    :get_deposit_address,
    :add_payment_method,
    :transfer_internal,
    :request_approved_address,
    :remove_approved_address,
    :stake,
    :unstake,
    :create_account,
    :rename_account,
    :revoke_access_token,
    :create_clearing_order,
    :create_broker_clearing_order,
    :cancel_clearing_order,
    :confirm_clearing_order
  ]

  @sent_once_not_read [
    retry_attempts: "sent exactly once whatever the caller gives (no idempotency key)",
    retry_delay: "there is no retry to wait before: the request is sent exactly once"
  ]

  # The OAuth refresh posts to the token host (`:auth_url`, default exchange.gemini.com), not to
  # the REST host, so neither `:environment` nor `:base_url` selects anything there; and the
  # refresh token is single-use, so the request is sent once whatever `:retry_attempts` says.
  @refresh_not_read [
    environment: "the token host is `:auth_url`; the environment does not select it",
    base_url: "the token host is `:auth_url`, not the REST host",
    retry_attempts: "a single-use refresh token: sent exactly once",
    retry_delay: "a single-use refresh token: sent once, so no retry to wait before"
  ]

  # The history reads page by the venue's own names; see `Private.validate_history_opts/2`.
  @own %{
    # --- public market data (`Rest`) ---------------------------------------------------
    get_price: [],
    get_top_of_book: [],
    get_symbols: [],
    get_market_overview: [],
    get_historical_prices: [:include_partial, :limit],
    # `:limit` is a family option this venue cannot honour: `Rest.validate_book_opts/1` answers
    # `{:unsupported_option, :limit}`, never `unknown_option`.
    get_order_book: [:depth, :limit],
    get_trades: [:since, :since_tid, :limit, :include_broken],
    list_instruments: [:symbols],
    list_fee_promos: [],
    get_staking_rates: [],
    get_funding: [],
    get_contract_stats: [],
    next_funding_timestamp: [],
    market_status: [],
    # --- streaming and health ----------------------------------------------------------
    subscribe: [:to, :feed, :channels],
    unsubscribe: [:feed],
    update_symbols: [:feed],
    subscribe_notices: [:to, :feed],
    coverage: [:feed],
    coverage_by_kind: [:feed],
    wanted: [:feed],
    live?: [],
    # --- account and trading (`Private`, signed) ---------------------------------------
    test_connection: @signed,
    # `showPendingBalances` (rest.yaml, `/v1/balances`) is deliberately not exposed: it makes the
    # venue slower to add `pendingDeposit` / `pendingWithdrawal`, and `Core.Types.Balance` has
    # nowhere to carry either, so the option would cost latency for a figure dropped on arrival.
    get_balances: @signed,
    get_accounts: @signed,
    get_fees: [:symbol | @signed],
    get_transfers: [
      :limit_transfers,
      :currency,
      :network,
      :timestamp,
      :show_completed_deposit_advances | @signed
    ],
    place_order: @signed,
    cancel_order: @signed,
    get_order: @signed,
    get_orders: [:history, :symbol, :limit, :since | @signed],
    cancel_all_orders: [:scope | @signed],
    get_trade_history: [:symbol, :limit, :since | @signed],
    get_transactions: [:since, :limit | @signed],
    get_notional_balances: @signed,
    list_custody_fees: [:since, :limit | @signed],
    get_trade_volume: @signed,
    get_fx_rate: @signed,
    list_networks: [:network | @signed],
    # --- money movement ----------------------------------------------------------------
    get_deposit_address: [:label, :legacy | @signed],
    list_approved_addresses: [:network | @signed],
    estimate_withdrawal_fee: [:address | @signed],
    withdraw: [:memo, :memo_required, :client_transfer_id | @signed],
    list_payment_methods: @signed,
    add_payment_method: [:country | @signed],
    transfer_internal: @signed,
    request_approved_address: [:memo | @signed],
    remove_approved_address: @signed,
    # --- staking and conversions -------------------------------------------------------
    get_staking_balances: @signed,
    get_staking_rewards: [:since, :until, :provider_id, :currency | @signed],
    get_staking_history: [
      :limit,
      :since,
      :until,
      :provider_id,
      :currency,
      :interest_only,
      :sort_asc | @signed
    ],
    stake: [:provider_id | @signed],
    unstake: [:provider_id | @signed],
    quote_conversion: [:symbol, :side | @signed],
    commit_conversion: [:symbol, :side, :amount, :price, :fee | @signed],
    convert: [:symbol, :side | @signed],
    # --- perpetuals and margin ---------------------------------------------------------
    get_positions: @signed,
    get_account_margin: [:symbol | @signed],
    get_margin_account: [:symbol | @signed],
    get_margin_rates: @signed,
    preview_margin_order: @signed,
    list_funding_payments: [:since, :to | @signed],
    funding_payment_report: [:from, :to, :rows | @signed],
    funding_amount_report: [:from, :to, :rows | @signed],
    funding_payment_report_file: [:from, :to, :rows | @signed],
    # --- clearing ----------------------------------------------------------------------
    create_clearing_order: [:counterparty_id, :expires_in_hrs | @signed],
    create_broker_clearing_order: [
      :source_counterparty_id,
      :target_counterparty_id,
      :expires_in_hrs | @signed
    ],
    get_clearing_order: @signed,
    cancel_clearing_order: @signed,
    confirm_clearing_order: @signed,
    list_clearing_orders: [
      :symbol,
      :counterparty,
      :side,
      :expiration_start,
      :expiration_end,
      :submission_start,
      :submission_end,
      :funded,
      :status,
      :timestamp,
      :limit_orders | @signed
    ],
    list_clearing_brokers: [
      :symbol,
      :expiration_start,
      :expiration_end,
      :submission_start,
      :submission_end,
      :funded,
      :status,
      :timestamp,
      :limit_orders | @signed
    ],
    list_clearing_trades: [:symbol, :limit, :since_nanos, :timestamp, :limit_trades | @signed],
    # --- administration and OAuth ------------------------------------------------------
    create_account: [:name, :type | @group_signed],
    # `id` and `name` are positional, so a caller's `:account` / `:name` would be overwritten.
    rename_account: [:shortname | @group_signed],
    list_accounts: [:limit, :since | @group_signed],
    get_roles: @group_signed,
    refresh_access_token: [:client_secret, :auth_url],
    # An OAuth call signs nothing and sends no body (`Auth.headers/5`), and the token already
    # names the account, so no key of its own is read here.
    revoke_access_token: []
  }

  # The keyword terms some functions take as a positional argument. They are checked against
  # their own keys alone: the transport options are the call's, not the terms'.
  #
  # `:credentials` is the one key every call may be handed (the contract suite hands the same
  # keyword to the terms and to `opts`), so the terms accept it too; nothing reads it there.
  @terms %{
    transfer_internal: [:from, :to, :client_transfer_id, :credentials]
  }

  @typedoc "The refusal `check/2` and `check_terms/2` answer."
  @type refusal :: {:error, {:unknown_option, atom()} | {:invalid_options, term()}}

  @doc """
  Every key `function` accepts: the shared transport keys, then its own.

  Raises `KeyError` for a function not in the table, which is a programming error in this
  package and not something a caller can cause.
  """
  @spec allowed(atom()) :: [atom()]
  def allowed(function) do
    own = Map.fetch!(@own, function)

    cond do
      function in @no_request -> [:credentials | own]
      function in @feed_addressing -> [:credentials, :environment] ++ tree_name(function) ++ own
      true -> (Options.transport_options() -- not_read(function)) ++ tree_name(function) ++ own
    end
  end

  # `:name` is the tree's own name (`DpExchange.Gemini.Supervisor`): a call carrying it
  # addresses that tree's feed and limiter, which are named after it unless given explicitly.
  # Every call that addresses either lists it. Not `live?/1`, which addresses neither, and not
  # the two calls whose `:name` is something else: `rename_account/3` takes the new name
  # positionally, and `create_account/1`'s `:name` is the subaccount's (a string, which never
  # names a tree; its own table entry already reads it).
  defp tree_name(function) when function in [:live?, :rename_account, :create_account], do: []
  defp tree_name(_function), do: [:name]

  @doc """
  The shared transport keys `function` sends a request and still does not read, each with
  the reason (see the moduledoc). Empty for a call that reads every one, and for a call that
  sends no request (which allows no transport key but `:credentials`, see `allowed/1`).
  """
  @spec not_read(atom()) :: [atom()]
  def not_read(function) do
    cond do
      function in @no_request or function in @feed_addressing -> []
      function == :refresh_access_token -> Keyword.keys(@refresh_not_read)
      function in @sent_once -> Keyword.keys(@sent_once_not_read)
      true -> []
    end
  end

  @doc """
  Checks `opts` against what `function` accepts.

  `:ok`, `{:error, {:unknown_option, key}}` for the first key not accepted (a key holding
  `nil` counts), or `{:error, {:invalid_options, opts}}` for anything but a keyword list.
  """
  @spec check(atom(), term()) :: :ok | refusal()
  def check(function, opts), do: opts |> Options.check(allowed(function)) |> scrubbed()

  @doc """
  `check/2` for a read whose result has no room for an error: raises `ArgumentError` for an
  unknown key or for options that are not a keyword list.
  """
  @spec check!(atom(), term()) :: :ok
  def check!(function, opts) do
    case check(function, opts) do
      :ok ->
        :ok

      {:error, {:unknown_option, key}} ->
        raise ArgumentError, "#{function} does not read the option #{inspect(key)}"

      {:error, {:invalid_options, bad}} ->
        raise ArgumentError, "#{function}: options must be a keyword list, got #{inspect(bad)}"
    end
  end

  # The options a tree (`DpExchange.Gemini.Supervisor.start_link/1`) or a standalone feed
  # (`DpExchange.Gemini.Feed.start_link/1`) reads at start. `:ledger` is the supervisor's own
  # hand-off to its feed, and `:socket` an already-connected socket a test hands in; neither is
  # for a consumer, but both are read. Everything else a start option could have been is
  # refused as `{:unknown_option, key}` rather than dropped: a misspelt `max_queu_len:` kept the
  # default bound without a word.
  @start [
    :name,
    :feed,
    :limiter,
    :environment,
    :channels,
    :max_queue_len,
    :url,
    :socket_connect_timeout,
    :socket_recv_timeout,
    :ssl_options,
    :credentials,
    :socket,
    :ledger
  ]

  @doc """
  Checks the options a tree or a feed is started with against the keys it reads (`:name`,
  `:feed`, `:limiter`, `:environment`, `:channels`, `:max_queue_len`, `:url`,
  `:socket_connect_timeout`, `:socket_recv_timeout`, `:ssl_options`, `:credentials`, and the
  hand-offs `:socket` and `:ledger`): `:ok`, `{:error, {:unknown_option, key}}` for the first
  key not read, or `{:error, {:invalid_options, opts}}` for anything but a keyword list (a
  `:credentials` entry shown as `:redacted`, as `check/2` does).
  """
  @spec check_start(term()) :: :ok | refusal()
  def check_start(opts), do: opts |> Options.check(@start) |> scrubbed()

  @doc """
  Checks the keyword terms a function takes as a positional argument (`transfer_internal/4`'s
  `:from`, `:to` and `:client_transfer_id`) against those keys alone.
  """
  @spec check_terms(atom(), term()) :: :ok | refusal()
  def check_terms(function, terms) do
    terms |> Options.check(Map.fetch!(@terms, function)) |> scrubbed()
  end

  # **`{:invalid_options, opts}` carries the caller's argument back, and the argument can be a
  # credential.** Passing the credentials where the options go (`get_balances(creds, creds)`,
  # or the two swapped) is an ordinary slip, and `opts` then came back whole in the error tuple
  # (and, from `check!/2`, in an `ArgumentError` message), which callers log. The shape of what
  # was passed stays, and every value under a credential-looking key is `:redacted`, at any
  # depth. Anything else is returned as it was given.
  @secret_names ~w(api_key api_secret access_token refresh_token client_secret credentials
                   password secret token key passphrase private_key signature)

  defp scrubbed({:error, {:invalid_options, bad}}), do: {:error, {:invalid_options, scrub(bad)}}
  defp scrubbed(other), do: other

  defp scrub(map) when is_map(map) and not is_struct(map), do: Map.new(map, &scrub_entry/1)
  defp scrub(list) when is_list(list), do: scrub_list(list)
  defp scrub({_key, _value} = entry), do: scrub_entry(entry)
  defp scrub(other), do: other

  defp scrub_list([]), do: []
  defp scrub_list([head | tail]), do: [scrub(head) | scrub_list(tail)]
  defp scrub_list(improper_tail), do: scrub(improper_tail)

  defp scrub_entry({key, value}) do
    if secret_name?(key), do: {key, :redacted}, else: {key, scrub(value)}
  end

  defp secret_name?(key) when is_atom(key) or is_binary(key), do: to_string(key) in @secret_names
  defp secret_name?(_other), do: false
end
