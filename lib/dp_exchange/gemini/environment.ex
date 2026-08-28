defmodule DpExchange.Gemini.Environment do
  @moduledoc """
  Which Gemini this package is talking to — production, or the demo environment.

  Gemini calls it the **demo environment**; its own URLs and most of the industry call it
  the **sandbox**. Both names appear in the venue's documentation for the same thing. This
  module uses `:sandbox` as the value and says "demo" in prose, so a reader coming from
  either direction lands in the right place.

  ## Why this venue gets a first-class environment and Coinbase did not

  Because Gemini's demo environment is **a full exchange with test funds**, not a stub.
  From the venue's own page:

  > Gemini's demo environment (sandbox) provides full exchange functionality with test
  > funds. Automated bots simulate order book activity and trading.

  New accounts are credited **$100,000 USD, 1,000 BTC, and 20,000 each of ETH, BCH, ZEC
  and LTC**. That changes what this package can honestly offer: order placement,
  cancellation and balances stop being tier-4 "never a test, answered only in production"
  and become **tier-3 testable against real venue machinery with fake money**.

  That is the whole reason the authenticated endpoints exist here at all. A consumer can
  run its entire trading integration against the demo environment before a single real
  order, which is the safest version of the thing this family exists to make possible.

  ## The URLs, and the documentation defect worth knowing about

  | Service | Production | Demo |
  |---|---|---|
  | REST | `https://api.gemini.com` | `https://api.sandbox.gemini.com` |
  | WebSocket | `wss://ws.gemini.com` | `wss://ws.sandbox.gemini.com` |

  Taken from `https://developer.gemini.com/get-started/sandbox`, read 2026-08-28, and
  verified against both live.

  **Gemini's market-data page names `exchange.sandbox.gemini.com` as the sandbox base
  URL. That is the website, not the API.** Measured the same day:
  `https://exchange.sandbox.gemini.com/v1/symbols` returns **404** and an HTML page, while
  `https://api.sandbox.gemini.com/v1/symbols` returns 391 symbols. A consumer following
  the market-data page gets 404s that look like a broken endpoint rather than a wrong
  host. Third documentation defect found on this venue in one day, which is why nothing
  here is taken on the page's word alone.

  ## Resolution order

  1. an explicit `:environment` in the call's options — wins always
  2. `DpExchange.Core.Config`, which resolves per **process**, so one async test can point
     at the demo environment while its neighbours do not
  3. `:production`

  Deliberately **not** `Application.put_env/3` as a first-class path: it is node-wide, and
  a consumer that flipped the whole node to sandbox mid-suite would silently redirect
  every other test running beside it. `Core.Config` reads application env underneath, so a
  consumer that genuinely wants a node-wide default still has one.

  ## Production is the default, and that is the safe direction

  A wrong default here fails in only one direction. Defaulting to production means a
  consumer who *meant* demo sends a real order to a real exchange with real money.
  Defaulting to demo means a consumer who meant production gets test balances and
  obviously-wrong prices — the demo book is crossed as often as not; a `bookTicker` frame
  captured 2026-08-28 carried a bid of `68169.88` against an ask of `64886.32`, which no
  real venue would ever show.

  The second failure is loud and costs nothing. The first is silent and costs money. So
  the default is production and selecting demo is an explicit act.
  """

  alias DpExchange.Core.Config

  @type t :: :production | :sandbox

  @rest %{production: "https://api.gemini.com", sandbox: "https://api.sandbox.gemini.com"}
  @websocket %{production: "wss://ws.gemini.com", sandbox: "wss://ws.sandbox.gemini.com"}

  @doc """
  The environment in force for these options.

  Raises on an unrecognised value rather than falling back to production. A typo like
  `environment: :sandox` must not quietly become a live order — that is the family's
  named failure mode with the highest possible stake.
  """
  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) do
    opts
    |> Keyword.get_lazy(:environment, fn ->
      Config.get(:dp_exchange_gemini, :environment, :production)
    end)
    |> validate!()
  end

  @doc "REST base URL for an environment."
  @spec rest_url(t()) :: String.t()
  def rest_url(environment), do: Map.fetch!(@rest, environment)

  @doc "WebSocket URL for an environment."
  @spec websocket_url(t()) :: String.t()
  def websocket_url(environment), do: Map.fetch!(@websocket, environment)

  @doc "Whether this environment moves real money."
  @spec live?(t()) :: boolean()
  def live?(:production), do: true
  def live?(:sandbox), do: false

  @doc "Every environment this package knows."
  @spec known() :: [t()]
  def known, do: [:production, :sandbox]

  defp validate!(environment) when environment in [:production, :sandbox], do: environment

  defp validate!(other) do
    raise ArgumentError,
          "unknown Gemini environment #{inspect(other)} — expected :production or :sandbox. " <>
            "Refusing rather than defaulting: a typo that silently resolved to :production " <>
            "would send a real order to a real exchange."
  end
end
