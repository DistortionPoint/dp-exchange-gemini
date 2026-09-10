defmodule DpExchange.Gemini.Auth do
  @moduledoc """
  Signs a request with credentials the **host** has already obtained. Internal.

  > #### This package does not handle authentication {: .error}
  >
  > It signs. That is a different job, and the distinction is the whole of this moduledoc.
  >
  > **The host implements authentication and chooses which kind to use.** This module is
  > handed the result and turns it into headers. It never obtains a credential, never
  > stores one, never refreshes one, never reads one from the environment, and never
  > decides which scheme applies.

  ## Why the choice cannot live here

  Gemini offers two authentication types, and they are not two spellings of one thing.

  **API key** is a key pair the account holder provisions in Settings. Signing is a pure
  function of the payload and the secret, so a package *can* do it — and this one does,
  when the host says to.

  **OAuth 2.0** is an authorization-code flow with refresh tokens. Using it means
  registering an application, choosing a confidential or public client type (permanently),
  redirecting a *user* to `https://exchange.gemini.com/auth` to approve scopes, receiving
  a callback, exchanging a code for tokens, doing PKCE if the client is public, and
  refreshing a 24-hour access token forever after. That needs a redirect URI, a browser,
  somewhere safe to keep a refresh token, and a policy for what happens when refresh
  fails.

  **A venue package has none of those things and must not pretend to.** Which scheme an
  application uses is a decision about its users, its deployment and its risk — the host's
  decision, not a detail a market-data library gets to make on its behalf.

  So there is no default here. The host names the scheme; this module refuses to guess.

  ## Refusing to guess is not pedantry — the venue rejects a guess outright

  Gemini's own error table lists:

  > `AmbiguousAuthentication` — 400 — Both V1 API key headers (`X-GEMINI-APIKEY`) and
  > OAuth/V2 headers were supplied in the same request.

  A module that inspected the credentials and helpfully attached whatever it recognised
  would eventually attach both and get a 400 that reads like a signing bug. Naming the
  scheme makes that unrepresentable.

  ## What the host passes

  For `:api_key` — a map carrying the pair it provisioned:

      %{api_key: "account-...", api_secret: "..."}

  For `:oauth` — the access token the host's flow already obtained and keeps fresh:

      %{access_token: "..."}

  ## The nonce is also the host's decision, twice over

  A key is provisioned in one of two nonce validation modes, and they need
  differently-shaped values — Unix **seconds** for time-based (±30 s window, no ordering
  requirement), a strictly increasing value for incremental. **No single value satisfies
  both**, and the venue exposes no way to ask how a key was made.

  It is the host's key, so it is the host's answer: `nonce_mode: :time_based | :incremental`.
  The default is `:time_based`, matching the venue's own recommendation, and a mismatch
  fails loudly with `InvalidNonce` on the first request rather than producing a wrong
  result.

  OAuth requests carry no nonce at all.

  ## Raising the mark is a one-way door, and why this module cannot walk through it

  Every nonce the venue **accepts** becomes that key's stored high-water mark, and Gemini
  compares nonces as arbitrary-precision integers. So a caller who clears a stuck mark by
  emitting something enormous — a real consumer used `counter × 1_000` ≈ `1.78e21` — does
  clear it, and permanently sets the mark to `1.78e21`. Nothing lowers it again, and no mode
  here can ever satisfy that key afterwards: `:incremental` is anchored to epoch
  milliseconds (~`1.789e12`), and even nanosecond magnitudes reach only ~`1.789e18`, below
  `2^64` ≈ `1.844e19` let alone `1.78e21`. The key must be rotated, which is a human action.

  **`nonce(:incremental)` is structurally incapable of that escalation**, and that is the
  property to preserve if this function is ever changed: `max(now_ms, previous + 1)` is
  anchored to the wall clock and advances past it by exactly one, only when calls land
  inside the same millisecond. Reaching `1e21` would take on the order of `1e21` calls.

  There is deliberately **no runtime guard** against a nonce "too far ahead of the clock",
  even though a large forward jump of the system clock is the one path by which this module
  could raise a mark. A guard would turn ordinary NTP corrections into a dead feed — a worse
  failure, and a far more frequent one, than the case it would prevent. Recorded so the
  absence reads as a decision rather than an oversight.

  Reported by a consumer on dp-exchange-gemini issue #1, who reached the diagnosis using the
  venue `message` that same issue restored.
  """

  @nonce_counter {__MODULE__, :nonce_counter}

  @typedoc "An API key pair the host provisioned. This module signs with it and forgets it."
  @type api_key_credentials :: %{
          required(:api_key) => String.t(),
          required(:api_secret) => String.t()
        }

  @typedoc "An access token the host's own OAuth flow obtained and keeps fresh."
  @type oauth_credentials :: %{required(:access_token) => String.t()}

  @typedoc "Which authentication the host chose. There is no default and no inference."
  @type scheme :: :api_key | :oauth

  @typedoc "Which validation mode the host's API key was provisioned with."
  @type nonce_mode :: :time_based | :incremental

  @doc """
  Headers for a private request, for the scheme the host named.

  `path` is the endpoint the payload declares as `request` — Gemini requires it *inside*
  the signed payload, which is what makes a captured request unusable against a different
  endpoint. Ignored for `:oauth`, which signs nothing.

  ## Options

    * `:nonce_mode` — `:time_based` (default) or `:incremental`. `:api_key` only.

  Returns `{:error, {:unsupported_auth_scheme, scheme}}` when `scheme` names something
  this module does not implement — a caller-supplied `:auth_scheme` this venue has no
  handler for, which never happens by inference; `{:error, {:missing_credentials, scheme}}`
  when a scheme WAS named or inferred but the credentials do not carry what it needs; and
  `{:error, {:missing_credentials, :gemini}}` when `scheme` is `nil` — nothing
  credential-shaped was supplied and no `:auth_scheme` was named, so there is no scheme to
  be unsupported, only a credential that never arrived. Never a partially-signed request,
  which would fail at the venue with an error about signatures rather than about the
  missing field.

  ## `nil` is not a scheme the venue could reject

  This used to fall through to `{:error, {:unsupported_auth_scheme, nil}}`, which reads
  as "you asked for scheme `nil` and this package does not support it" — a claim this
  package never made and the venue was never asked to evaluate. The caller supplied no
  credential at all; `{:missing_credentials, :gemini}` is the same shape every other
  venue in this family returns for that condition (`Core.Venue`'s `:refused` is reserved
  for the venue's own word about a request it *received*, and a call this module refused
  to even sign never reached one). `:unsupported_auth_scheme` is reserved for a scheme
  that was actually named — by the caller's own `:auth_scheme`, since inference never
  produces one this module does not implement.
  """
  @spec headers(scheme(), String.t(), map(), map(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def headers(scheme, path, params \\ %{}, credentials, opts \\ [])

  def headers(:api_key, path, params, %{api_key: key, api_secret: secret}, opts)
      when is_binary(path) and is_map(params) do
    payload =
      params
      |> Map.merge(%{"request" => path, "nonce" => nonce(Keyword.get(opts, :nonce_mode))})
      |> Jason.encode!()
      |> Base.encode64()

    {:ok,
     [
       {"Content-Length", "0"},
       {"Content-Type", "text/plain"},
       {"Cache-Control", "no-cache"},
       {"X-GEMINI-APIKEY", key},
       {"X-GEMINI-PAYLOAD", payload},
       {"X-GEMINI-SIGNATURE", sign(payload, secret)}
     ]}
  end

  # The token is attached, not obtained. Whether it is still valid, and what to do when it
  # is not, is the host's flow — this module cannot refresh what it did not fetch.
  def headers(:oauth, _path, _params, %{access_token: token}, _opts) when is_binary(token) do
    {:ok, [{"Authorization", "Bearer " <> token}]}
  end

  def headers(scheme, _path, _params, _credentials, _opts) when scheme in [:api_key, :oauth] do
    {:error, {:missing_credentials, scheme}}
  end

  # `nil` means no credential-shaped value was supplied and no `:auth_scheme` was named —
  # there is nothing here to call an unsupported SCHEME, only a credential that never
  # arrived. See the moduledoc section above for why this is not folded into the
  # catch-all below, which is reserved for a scheme the caller actually asked for.
  def headers(nil, _path, _params, _credentials, _opts) do
    {:error, {:missing_credentials, :gemini}}
  end

  def headers(scheme, _path, _params, _credentials, _opts) do
    {:error, {:unsupported_auth_scheme, scheme}}
  end

  @doc """
  A nonce for the given validation mode.

  `:time_based` returns Unix **seconds**, which is what that mode validates against.
  `:incremental` returns a strictly increasing millisecond value, monotonic **node-wide** —
  two processes calling in the same millisecond get different, ordered values, because a
  repeated nonce is rejected outright by an incremental key.
  """
  @spec nonce(nonce_mode() | nil) :: pos_integer()
  def nonce(mode \\ :time_based)

  def nonce(:incremental) do
    counter = ensure_counter()
    now = System.system_time(:millisecond)

    previous = :atomics.get(counter, 1)
    next = max(now, previous + 1)

    case :atomics.compare_exchange(counter, 1, previous, next) do
      :ok -> next
      _lost_the_race -> nonce(:incremental)
    end
  end

  def nonce(mode) when mode in [:time_based, nil], do: System.system_time(:second)

  @doc """
  Establishes the shared nonce counter. Called once by this venue's supervisor.

  ## Why this is not purely lazy, which is what it was first

  A lazy `:persistent_term` init has a race with a consequence worse than the cost it
  saves. Two processes both see the key absent, both create an `:atomics` ref, and both
  store one — so the second **replaces** a counter the first is already drawing from. The
  replacement is seeded from the wall clock like the first was, so the sequence *restarts*,
  and two processes calling in the same millisecond receive **the same nonce**. Under
  incremental validation the second request is rejected as a replay.

  That is precisely the failure this counter exists to prevent, reintroduced by the
  initialisation of the thing preventing it. It was caught by a test asserting monotonicity
  *across processes*; the single-process version passed happily, which is why the test is
  written that way.
  """
  @spec ensure_counter() :: :atomics.atomics_ref()
  def ensure_counter do
    case :persistent_term.get(@nonce_counter, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@nonce_counter, ref)
        :persistent_term.get(@nonce_counter)

      ref ->
        ref
    end
  end

  defp sign(payload, secret) do
    :hmac
    |> :crypto.mac(:sha384, secret, payload)
    |> Base.encode16(case: :lower)
  end
end
