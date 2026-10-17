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

  `DpExchange.Core.Options.transport_options/0` (credentials, environment, base URL, the
  `Req` test seams, the limiter, timeout and retry knobs) plus the keys in the table below,
  which are the keys that function, and what it forwards to, actually reads. The table is
  `@own`; `allowed/1` answers a function's whole list. A function the venue does not serve
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
    * `{:error, {:invalid_options, opts}}` - `opts` is not a keyword list

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
    get_balances: @signed,
    get_accounts: @signed,
    get_fees: [:symbol | @signed],
    get_transfers: [:limit_transfers, :currency, :network, :timestamp | @signed],
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
    get_staking_rewards: [:since, :until, :provider_id | @signed],
    get_staking_history: [:limit, :since, :until, :provider_id | @signed],
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
      :submission_end | @signed
    ],
    list_clearing_brokers: [:symbol, :expiration_start, :expiration_end | @signed],
    list_clearing_trades: [:symbol, :limit, :since_nanos | @signed],
    # --- administration and OAuth ------------------------------------------------------
    create_account: [:name, :type | @group_signed],
    # `id` and `name` are positional, so a caller's `:account` / `:name` would be overwritten.
    rename_account: [:shortname | @group_signed],
    list_accounts: [:limit, :since | @group_signed],
    get_roles: @group_signed,
    refresh_access_token: [:client_secret, :auth_url],
    revoke_access_token: [:account]
  }

  # The keyword terms some functions take as a positional argument. They are checked against
  # their own keys alone: the transport options are the call's, not the terms'.
  @terms %{
    transfer_internal: [:from, :to, :client_transfer_id]
  }

  @typedoc "The refusal `check/2` and `check_terms/2` answer."
  @type refusal :: {:error, {:unknown_option, atom()} | {:invalid_options, term()}}

  @doc """
  Every key `function` accepts: the shared transport keys, then its own.

  Raises `KeyError` for a function not in the table, which is a programming error in this
  package and not something a caller can cause.
  """
  @spec allowed(atom()) :: [atom()]
  def allowed(function), do: Options.transport_options() ++ Map.fetch!(@own, function)

  @doc """
  Checks `opts` against what `function` accepts.

  `:ok`, `{:error, {:unknown_option, key}}` for the first key not accepted (a key holding
  `nil` counts), or `{:error, {:invalid_options, opts}}` for anything but a keyword list.
  """
  @spec check(atom(), term()) :: :ok | refusal()
  def check(function, opts), do: Options.check(opts, allowed(function))

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

  @doc """
  Checks the keyword terms a function takes as a positional argument (`transfer_internal/4`'s
  `:from`, `:to` and `:client_transfer_id`) against those keys alone.
  """
  @spec check_terms(atom(), term()) :: :ok | refusal()
  def check_terms(function, terms), do: Options.check(terms, Map.fetch!(@terms, function))
end
