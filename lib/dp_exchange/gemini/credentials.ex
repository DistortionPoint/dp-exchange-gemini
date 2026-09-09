defmodule DpExchange.Gemini.Credentials do
  @moduledoc """
  A redacting wrapper for the credentials the host passes in — internal.

  This exists for one reason: **a raw secret in a supervisor's stored child spec ends up in
  the log in cleartext.** A supervisor holds the `{module, :start_link, [opts]}` MFA it was
  handed, and OTP writes that argument list through `inspect/1` into the `Start Call:` line
  of the report it logs whenever the child terminates. A plain `%{api_key: ..., api_secret:
  ...}` map therefore prints its values, in full, on **any** child crash.

  dp-exchange-core issue #29: a consumer found live API keys in cleartext in ordinary
  application logs and nearly pasted them into a GitHub issue while reporting a different
  bug. Application logs are exactly the artifact most likely to be shipped to an
  aggregator, attached to a bug report, or quoted in a ticket, so this defeats credential
  hygiene upstream of it — a consumer can hold the key encrypted at rest and still have it
  written out in the clear by a crash.

  Redacting the value rather than suppressing the report is deliberate. A `:sensitive`
  process flag would also hide the secret, and would hide the stack trace with it — the one
  that made the unrelated bug diagnosable in the first place. This keeps the report and
  removes only the secret.

  ## Why `Inspect`, and not a scrub at each log site

  OTP formats those args with `inspect/1`, so one redacting `Inspect` implementation covers
  every path at once: supervisor reports, crash reports, `:sys.get_state/1` dumps, and
  anything a consumer inspects itself. There is no list of log call sites to keep current,
  which is the kind of list that silently stops being complete.

  A struct is a map, so nothing downstream changes: `Auth.headers/5` pattern-matches only
  the keys it needs and keeps working unchanged.

  ## Both schemes, one struct

  Gemini takes two shapes — an `:api_key` pair and an `:oauth` access token (see
  `DpExchange.Gemini.Auth`). All three fields live here rather than in two structs, because
  `Kernel.struct/2` ignores keys the struct does not declare, so one struct accepts either
  shape and redacts whichever arrived. Splitting them would mean choosing which struct to
  build from an untagged map — an inference this family does not make about credentials.

  ## The wrap lives in `child_spec/1`, so bypassing it bypasses the redaction

  `child_spec/1` is where `wrap_opt/1` is applied, because a supervisor captures the
  `{module, :start_link, [opts]}` MFA before `start_link/1` or `init/1` ever runs — see
  `wrap_opt/1`'s own doc. A consumer who uses the supported `{DpExchange.X, credentials:
  ...}` child form gets the redaction for free.

  **A consumer who builds the child spec themselves does not**, and upgrading this package
  will not change that: their supervisor stores the raw map and OTP renders it on the next
  crash, with nothing from this package on that path to intervene. It is a real path with a
  real reason — a caller needing a delivery target other than the supervisor has to reach
  `start_link/1` directly — so `wrap/1` and `wrap_opt/1` are **public** for it. Reported by
  a consumer who went looking for their canary in supervisor state after upgrading and
  found it; the natural assumption, "upgraded, therefore redacted", is wrong there.

  The same applies to a host that *reshapes* a credential before handing it over — mapping
  its own key names into this venue's and returning a bare map re-introduces the leak
  downstream of anything this package can reach.
  """

  # `except:`, never `only:`. `only:` would print any field added later by default, which is
  # the wrong direction for a struct whose entire purpose is not printing things: a new
  # secret field would start leaking the moment someone added it and forgot this line.
  @derive {Inspect, except: [:api_key, :api_secret, :access_token]}
  defstruct [:api_key, :api_secret, :access_token]

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          api_secret: String.t() | nil,
          access_token: String.t() | nil
        }

  @doc """
  Wraps a raw credentials map.

  Any map is struct-ified with `Kernel.struct/2`, which ignores keys the struct does not
  declare rather than raising — matching how `Auth.headers/5` already reads this map, by
  pattern-matching only the keys it needs.
  """
  @spec wrap(map()) :: t()
  def wrap(%__MODULE__{} = credentials), do: credentials
  def wrap(credentials) when is_map(credentials), do: struct(__MODULE__, credentials)

  @doc """
  Wraps the `:credentials` entry of an options keyword list, IN PLACE and only when that
  key is actually present.

  Applied in `child_spec/1`, which is the only place early enough: wrapping inside
  `start_link/1` or `init/1` does nothing for the supervisor's report, because by then the
  raw list has already been captured by the supervisor above.
  """
  @spec wrap_opt(keyword()) :: keyword()
  def wrap_opt(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} when is_map(credentials) ->
        Keyword.put(opts, :credentials, wrap(credentials))

      _absent_or_not_a_map ->
        opts
    end
  end
end
