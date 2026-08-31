defmodule DpExchange.Gemini.ArchivedSocketsTest do
  @moduledoc """
  Gemini's earlier WebSocket APIs are archived, and this package must never speak one.

  ## Why this venue in particular

  This is the venue where it already happened. The host adapter this package was extracted
  from was built against a Gemini socket API that Gemini later replaced, and nothing was
  watching the documentation — the code kept compiling and the endpoint kept being wrong.
  That incident is why the family has a rule about undocumented endpoints at all.

  Four socket APIs are archived (`websocket/archived/{v1,v2,order-events,multi-market-data}`):

      wss://api.gemini.com/v1/marketdata/{symbol}    Market Data v1
      wss://api.gemini.com/v1/order/events           Order Events
      wss://api.gemini.com/v1/multimarketdata        Multi Market Data
      wss://api.gemini.com/v2/marketdata             Market Data v2

  The current API is `wss://ws.gemini.com`, and its channels come from the vendor's
  AsyncAPI document. Note the host differs: archived sockets live on `api.gemini.com`, the
  current one on `ws.gemini.com`. **A path check alone would miss that**, so the host is
  checked too.

  ## This test reads code, not prose

  Its first version failed on `Socket`'s moduledoc — which names the archived endpoint in
  order to explain why the package does not use it. That explanation is the most valuable
  thing in that file and must not be deleted to satisfy a test, so the test strips
  documentation blocks and comments before looking.

  The consequence is worth stating plainly: **this guard cannot see an archived endpoint
  hidden in a docstring**, which is fine, because a docstring cannot open a socket.
  """

  use ExUnit.Case, async: true

  @lib Path.join([__DIR__, "..", "..", "..", "lib"]) |> Path.expand()

  @archived_paths [
    "/v1/marketdata",
    "/v1/order/events",
    "/v1/multimarketdata",
    "/v2/marketdata"
  ]

  defp source_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

  # Strip heredoc blocks (@moduledoc/@doc and any other `"""` block) and `#` comments, so
  # what remains is code. Deliberately simple: it over-strips rather than under-strips,
  # which for a guard means it can miss, never falsely accuse.
  defp code_only(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_heredoc?} ->
      cond do
        in_heredoc? and String.contains?(line, ~s(""")) -> {acc, false}
        in_heredoc? -> {acc, true}
        String.contains?(line, ~s(""")) -> {acc, true}
        true -> {[String.replace(line, ~r/#.*$/, "") | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp offending(match_fun) do
    for path <- source_files(),
        code = code_only(File.read!(path)),
        hits = match_fun.(code),
        hits != [] do
      {Path.relative_to(path, @lib), hits}
    end
  end

  test "no code path speaks an archived socket endpoint" do
    offenders =
      offending(fn code -> Enum.filter(@archived_paths, &String.contains?(code, &1)) end)

    assert offenders == [],
           """
           These files reference Gemini's archived WebSocket APIs in code: #{inspect(offenders)}

           The current socket API is wss://ws.gemini.com. The archived ones can be
           withdrawn without notice, which is how this venue's adapter broke once already.
           """
  end

  test "no code path points a socket at the archived host" do
    offenders =
      offending(fn code ->
        if String.contains?(code, "wss://api.gemini.com"), do: ["wss://api.gemini.com"], else: []
      end)

    assert offenders == [],
           "Archived sockets live on api.gemini.com; the current one is ws.gemini.com. " <>
             "Offending files: #{inspect(offenders)}"
  end

  test "the current socket host is still the one in use" do
    # The mirror of the guards above: absence of the wrong host is only reassuring if the
    # right one is present. A package that spoke no socket at all would pass both.
    assert Enum.any?(source_files(), fn path ->
             path |> File.read!() |> code_only() |> String.contains?("wss://ws.gemini.com")
           end)
  end

  test "stripping documentation does not strip the whole file" do
    # If `code_only/1` ever returned "", every guard above would pass vacuously.
    assert Enum.any?(source_files(), fn path ->
             path |> File.read!() |> code_only() |> String.contains?("defmodule")
           end)
  end
end
