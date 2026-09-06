defmodule DpExchange.Gemini.WsChannels do
  @moduledoc """
  The venue's WebSocket channels, their addresses, and which need a credential.

  From the vendor's **AsyncAPI document** (`/specs/asyncapi/websocket.yaml`), read
  2026-09-01. That document — not the rendered Stream Matrix — is the surface: **ten of
  these channels never appear in the matrix**, including the whole `requestForQuote` family,
  `connection`, both `…Snapshot` channels and the four `…Fast` depth variants.

  ## Addresses are built, not guessed

  A per-symbol channel is `"{symbol}@name"` and a per-account one is a bare name like
  `orders@account`. Two of them are neither: `depthFast` is `"{symbol}@depth@100ms"` and the
  snapshot channels are `balances@account@1s` and `positions@account@1s` — **the interval is
  part of the address, not a parameter**. A package assembling `"{symbol}@depthFast"` from
  the channel's own name would subscribe to nothing and see silence rather than an error.

  ## Public and private are not interchangeable

  `orders`, `balances`, `positions`, `settlements` and the two private `requestForQuote`
  channels need an authenticated connection. Subscribing to one without a credential fails
  at the venue, so `requires_credential?/1` lets a caller be told here instead.
  """

  # {channel, address_template, requires_credential?}
  @channels [
    {:connection, "/", false},
    {:book_ticker, "{symbol}@bookTicker", false},
    {:trade, "{symbol}@trade", false},
    {:contract_status, "contractStatus", false},
    {:depth, "{symbol}@depth", false},
    # The interval is in the address, not a parameter.
    {:depth_fast, "{symbol}@depth@100ms", false},
    {:depth5, "{symbol}@depth5", false},
    {:depth5_fast, "{symbol}@depth5@100ms", false},
    {:depth10, "{symbol}@depth10", false},
    {:depth10_fast, "{symbol}@depth10@100ms", false},
    {:depth20, "{symbol}@depth20", false},
    {:depth20_fast, "{symbol}@depth20@100ms", false},
    {:orders_account, "orders@account", true},
    {:orders_session, "orders@session", true},
    {:balances_account, "balances@account", true},
    {:balances_account_snapshot, "balances@account@1s", true},
    {:positions_account, "positions@account", true},
    {:positions_account_snapshot, "positions@account@1s", true},
    {:settlements_account, "settlements@account", true},
    {:request_for_quote, "requestForQuote", false},
    {:request_for_quote_account, "requestForQuote@account", true},
    {:request_for_quote_session, "requestForQuote@session", true}
  ]

  @by_name Map.new(@channels, fn {name, address, auth} -> {name, {address, auth}} end)

  @doc """
  The subscription address for `channel`, with `{symbol}` filled in where the channel takes
  one.

  **A per-symbol channel with no symbol is an error**, and a per-account channel given one
  is too: `orders@account` with a symbol appended is not a channel the venue has, and
  subscribing to it produces silence rather than a refusal.
  """
  @spec address(atom(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def address(channel, symbol \\ nil) do
    case Map.fetch(@by_name, channel) do
      :error ->
        {:error, {:unknown_channel, channel}}

      {:ok, {template, _auth}} ->
        fill(template, symbol, channel)
    end
  end

  defp fill(template, symbol, channel) do
    cond do
      not String.contains?(template, "{symbol}") and not is_nil(symbol) ->
        {:error, {:channel_takes_no_symbol, channel}}

      String.contains?(template, "{symbol}") and is_nil(symbol) ->
        {:error, {:channel_requires_symbol, channel}}

      true ->
        {:ok, String.replace(template, "{symbol}", to_string(symbol))}
    end
  end

  @doc """
  Whether `channel` needs an authenticated connection.

  Subscribing to a private channel without a credential fails at the venue; answering here
  lets a caller be told before the round trip — `Socket.subscribe/3` does exactly that,
  refusing before it ever builds a frame, since `Socket` never carries a credential to
  authenticate a private channel with in the first place.
  """
  @spec requires_credential?(atom()) :: boolean() | {:error, term()}
  def requires_credential?(channel) do
    case Map.fetch(@by_name, channel) do
      {:ok, {_address, auth}} -> auth
      :error -> {:error, {:unknown_channel, channel}}
    end
  end

  @doc """
  Channels that carry a symbol in their address.

  `Socket.subscribe/3` and `unsubscribe/3` check membership here before ever reaching
  `address/2`: a non-empty symbol list against a channel absent from this list is refused
  with `{:error, {:channel_takes_no_symbol, channel}}` rather than silently subscribing to
  nothing, which is what `streams/2`'s own error-filtering used to let through.
  """
  @spec per_symbol() :: [atom()]
  def per_symbol do
    for {name, address, _auth} <- @channels, String.contains?(address, "{symbol}"), do: name
  end
end
