defmodule DpExchange.Gemini.TickArSocketDocsTest do
  @moduledoc """
  Tick AR, lens V: what the `Socket`, `WsDecode` and `Auth` docs promise, pinned against the
  code that makes the promise.

  The socket is never dialled. `Socket.subscribe/3` and `unsubscribe/3` decide these refusals
  before any frame is built, so a name nothing is registered under is enough.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini.{Auth, Socket, WsDecode}

  @ns 1_787_936_147_000_000_000

  defp frame(overrides) do
    Map.merge(%{"E" => @ns, "p" => "1.5", "q" => "2", "m" => true}, overrides)
  end

  describe "Socket.subscribe/3 and unsubscribe/3 refuse what builds no address" do
    test "an unknown channel is an error naming it, not a subscription for nothing" do
      assert Socket.subscribe(:no_such_socket, ["BTC-USD"], :candles) ==
               {:error, {:unknown_channel, :candles}}

      assert Socket.subscribe(:no_such_socket, [], :candles) ==
               {:error, {:unknown_channel, :candles}}

      assert Socket.unsubscribe(:no_such_socket, ["BTC-USD"], :candles) ==
               {:error, {:unknown_channel, :candles}}
    end

    test "a blank or non-text symbol is refused whole, naming the symbol" do
      for bad <- ["", "   ", :btc_usd, nil, 7] do
        assert Socket.subscribe(:no_such_socket, [bad], :book_ticker) ==
                 {:error, {:invalid_symbol, bad}}

        # One bad symbol in a batch refuses the batch: the rest used to be subscribed and
        # the call answered `:ok`.
        assert Socket.subscribe(:no_such_socket, ["BTC-USD", bad], :trade) ==
                 {:error, {:invalid_symbol, bad}}

        assert Socket.unsubscribe(:no_such_socket, [bad], :book_ticker) ==
                 {:error, {:invalid_symbol, bad}}
      end
    end

    test "symbols that are not a list are refused, not raised on" do
      assert Socket.subscribe(:no_such_socket, "BTC-USD", :book_ticker) ==
               {:error, {:invalid_symbol, "BTC-USD"}}
    end

    test "one call naming several distinct partial-depth symbols is refused with the list" do
      assert Socket.subscribe(:no_such_socket, ["BTC-USD", "ETH-USD"], :depth5) ==
               {:error, {:partial_depth_symbol_conflict, ["BTC-USD", "ETH-USD"]}}
    end

    test "the existing refusals keep their documented shapes" do
      assert Socket.subscribe(:no_such_socket, ["BTC-USD"], :contract_status) ==
               {:error, {:channel_takes_no_symbol, :contract_status}}

      assert Socket.subscribe(:no_such_socket, [], :orders_account) ==
               {:error, {:credential_required, :orders_account}}

      assert Socket.subscribe(:no_such_socket, [], :book_ticker) == :ok
    end
  end

  describe "WsDecode.to_trade/2 returns the errors its doc names" do
    test "side is the inverse of m, and nil when m is not a boolean" do
      assert {:ok, %{side: :sell}} = WsDecode.to_trade(frame(%{"m" => true}), "BTC-USD")
      assert {:ok, %{side: :buy}} = WsDecode.to_trade(frame(%{"m" => false}), "BTC-USD")
      assert {:ok, %{side: nil}} = WsDecode.to_trade(frame(%{"m" => "yes"}), "BTC-USD")
      assert {:ok, %{side: nil}} = WsDecode.to_trade(Map.delete(frame(%{}), "m"), "BTC-USD")
    end

    test "each documented error tuple" do
      assert WsDecode.to_trade(%{"E" => @ns}, "BTC-USD") == {:error, :unexpected_frame_shape}

      assert WsDecode.to_trade(frame(%{"E" => nil}), "BTC-USD") ==
               {:error, :missing_venue_timestamp}

      assert WsDecode.to_trade(frame(%{"E" => 1_787_936_147_000}), "BTC-USD") ==
               {:error, :missing_venue_timestamp}

      assert WsDecode.to_trade(frame(%{"p" => nil}), "BTC-USD") ==
               {:error, {:missing_required_field, :price}}

      assert WsDecode.to_trade(frame(%{"q" => "abc"}), "BTC-USD") ==
               {:error, {:invalid_decimal, :quantity, "abc"}}

      assert WsDecode.to_trade(frame(%{"p" => "0"}), "BTC-USD") ==
               {:error, {:non_positive_price, :price, "0"}}

      assert WsDecode.to_trade(frame(%{"q" => "-1"}), "BTC-USD") ==
               {:error, {:non_positive_quantity, :quantity, "-1"}}
    end
  end

  describe "Auth signs the way the vendor documents" do
    test "the signature is hex(HMAC-SHA384(base64(payload), api_secret)), headers as listed" do
      credentials = %{api_key: "account-abc", api_secret: "s3cret"}

      assert {:ok, headers} =
               Auth.headers(:api_key, "/v1/balances", %{}, credentials, nonce_mode: :time_based)

      header = Map.new(headers)

      assert header["Content-Length"] == "0"
      assert header["Content-Type"] == "text/plain"
      assert header["Cache-Control"] == "no-cache"
      assert header["X-GEMINI-APIKEY"] == "account-abc"

      expected =
        :hmac
        |> :crypto.mac(:sha384, "s3cret", header["X-GEMINI-PAYLOAD"])
        |> Base.encode16(case: :lower)

      assert header["X-GEMINI-SIGNATURE"] == expected

      payload = header["X-GEMINI-PAYLOAD"] |> Base.decode64!() |> Jason.decode!()
      assert payload["request"] == "/v1/balances"
      assert is_integer(payload["nonce"])
    end

    test "a path that is not text, or params that are not a map, answer missing_credentials" do
      credentials = %{api_key: "account-abc", api_secret: "s3cret"}

      assert Auth.headers(:api_key, 5, %{}, credentials) ==
               {:error, {:missing_credentials, :gemini}}

      assert Auth.headers(:api_key, "/v1/x", [], credentials) ==
               {:error, {:missing_credentials, :gemini}}
    end

    test "seed_nonce/1 refuses anything that is not a positive integer, as its spec says" do
      for bad <- ["1", 0, -5, 1.5, nil, :one] do
        assert Auth.seed_nonce(bad) == {:error, :invalid_seed}
      end

      assert Auth.seed_nonce(0xFFFF_FFFF_FFFF_FFFF) == {:error, :above_counter_range}
    end
  end
end
