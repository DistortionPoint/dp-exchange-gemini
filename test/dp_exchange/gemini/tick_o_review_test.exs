defmodule DpExchange.Gemini.TickOReviewTest do
  @moduledoc """
  Tick O: load, scale and what reaches a log.

  A venue's words are quoted bounded wherever they reach an error tuple, and the shared
  `Feed` does not print the caller's TLS options into a crash report.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
  alias DpExchange.Gemini.{Feed, Private, Rest}

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{api_key: "account-test", api_secret: "test-secret-not-real"}
  @truncated "... [truncated]"

  describe "a refusal quotes the venue's words bounded" do
    test "a CDN error page in a 4xx body is cut, not carried whole" do
      page = "<html>" <> String.duplicate("x", 100_000) <> "</html>"

      assert {:unknown_reason, text} = Rest.refusal_reason(page)
      assert String.starts_with?(text, "<html>")
      assert String.ends_with?(text, @truncated)
      assert byte_size(text) <= 2_048 + byte_size(@truncated)
    end

    test "a cut inside a multi-byte character leaves valid text" do
      # Three bytes each, so the 2,048th byte falls inside one.
      page = String.duplicate("€", 5_000)

      assert {:unknown_reason, text} = Rest.refusal_reason(page)
      assert String.valid?(text)
      assert String.ends_with?(text, @truncated)
    end

    test "a known reason's message and an unknown reason's word are both bounded" do
      long = String.duplicate("m", 50_000)

      assert {:invalid_nonce, message} =
               Rest.refusal_reason(%{"reason" => "InvalidNonce", "message" => long})

      assert byte_size(message) <= 2_048 + byte_size(@truncated)

      assert {:unknown_reason, word} = Rest.refusal_reason(%{"reason" => long})
      assert byte_size(word) <= 2_048 + byte_size(@truncated)
    end

    test "text inside the bound is returned byte-identical" do
      padded = %{"reason" => "InvalidNonce", "message" => " Nonce 1 is low "}
      assert Rest.refusal_reason(padded) == {:invalid_nonce, "Nonce 1 is low"}

      assert Rest.refusal_reason("Supplied value 'X' is not a valid symbol") ==
               {:unknown_reason, "Supplied value 'X' is not a valid symbol"}

      exactly = String.duplicate("a", 2_048)
      assert Rest.refusal_reason(exactly) == {:unknown_reason, exactly}
    end

    test "a private call refused with a whole page answers the bounded text" do
      page = "<html>" <> String.duplicate("y", 200_000) <> "</html>"
      plug = fn conn -> Plug.Conn.resp(conn, 400, page) end

      assert {:refused, {:unknown_reason, text}} =
               Private.get_balances(@credentials, plug: plug, retry_attempts: 0)

      assert byte_size(text) <= 2_048 + byte_size(@truncated)
    end
  end

  describe "the feed's status does not print the TLS options" do
    test "ssl_options is redacted in :sys.get_status/1 and intact in :sys.get_state/1" do
      canary = "tick-o-canary-private-key-password"
      ssl_options = [verify: :verify_peer, password: canary]

      {:ok, feed} =
        Feed.start_link(
          name: :"feed_#{System.unique_integer([:positive])}",
          ssl_options: ssl_options
        )

      status = feed |> :sys.get_status() |> inspect(limit: :infinity, printable_limit: :infinity)

      refute status =~ canary
      assert status =~ "redacted"
      assert :sys.get_state(feed).socket_opts[:ssl_options] == ssl_options
    end

    test "a feed started without ssl_options shows its socket options as they are" do
      {:ok, feed} =
        Feed.start_link(
          name: :"feed_#{System.unique_integer([:positive])}",
          socket_connect_timeout: 1_234
        )

      status = feed |> :sys.get_status() |> inspect(limit: :infinity)

      assert status =~ "1234"
      refute status =~ "ssl_options"
    end
  end
end
