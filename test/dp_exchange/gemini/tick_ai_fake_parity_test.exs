defmodule DpExchange.Gemini.TickAIFakeParityTest do
  @moduledoc """
  Tick AI: every public function `DpExchange.Gemini` exposes is on `Fake` at the same arity.

  The venue-specific functions that are not `Venue` callbacks (margin, clearing, funding
  reports, OAuth, account listing) were missing from `Fake`, so a consumer's tier-1 suite got
  an `UndefinedFunctionError` for a call that works against the real adapter. Each now refuses
  with the real call's own validation, in the real order, then the credential, then answers a
  fixed value in the shape of the vendor's response example.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Gemini
  alias DpExchange.Gemini.Fake

  @credentials %{api_key: "k", api_secret: "s"}
  @missing {:error, {:missing_credentials, :gemini}}
  @terms %{symbol: "btcusd", amount: "1", price: "2", side: :buy}

  defp creds(extra \\ []), do: Keyword.merge([credentials: @credentials], extra)

  test "the facade's public functions minus the Fake's is empty" do
    facade = Gemini.__info__(:functions)
    fake = Fake.__info__(:functions)

    assert facade -- fake == []
  end

  describe "live?/1, venue_does_not_serve/0, seed_nonce/1" do
    test "live? and venue_does_not_serve are the real adapter's" do
      assert Fake.live?([]) == Gemini.live?([])
      assert Fake.live?(environment: :sandbox) == false
      assert Fake.venue_does_not_serve() == Gemini.venue_does_not_serve()
    end

    test "seed_nonce refuses as the real call does, and only ever raises" do
      assert Fake.seed_nonce(0) == {:error, :invalid_seed}
      assert Fake.seed_nonce("5") == {:error, :invalid_seed}
      assert Fake.seed_nonce(Integer.pow(2, 64)) == {:error, :above_counter_range}
      assert Fake.seed_nonce(5) == :ok
      assert Fake.seed_nonce(5) == {:error, :below_current}
      assert Fake.seed_nonce(6) == :ok
    end
  end

  describe "next_funding_timestamp/2" do
    test "a perpetual answers a time and anything else is refused" do
      assert {:ok, %DateTime{}} = Fake.next_funding_timestamp("BTCGUSDPERP")
      assert Fake.next_funding_timestamp("BTC-USD") == {:refused, :not_listed}
      assert Fake.next_funding_timestamp("") == {:error, {:invalid_symbol, ""}}
    end
  end

  describe "margin" do
    test "get_account_margin and get_margin_account need a symbol before a credential" do
      assert Fake.get_account_margin([]) == {:error, {:missing_option, :symbol}}
      assert Fake.get_margin_account([]) == {:error, {:missing_option, :symbol}}
      assert Fake.get_account_margin(symbol: "BTC-GUSD-PERP") == @missing
      assert Fake.get_margin_account(symbol: "btcusd") == @missing
    end

    test "they answer the vendor's shapes" do
      assert {:ok, %{"estimated_liquidation_price" => _value}} =
               Fake.get_account_margin(creds(symbol: "BTC-GUSD-PERP"))

      assert {:ok, %{"buyingPower" => %{"currency" => "USD"}}} =
               Fake.get_margin_account(creds(symbol: "btcusd"))
    end

    test "get_margin_rates carries all three rates per currency" do
      assert Fake.get_margin_rates([]) == @missing
      assert {:ok, [first | _rest] = rows} = Fake.get_margin_rates(creds())
      assert length(rows) == 3

      assert %{"borrowRate" => _rate, "borrowRateDaily" => _daily, "borrowRateAnnual" => _annual} =
               first
    end

    test "preview_margin_order validates the request before the credential" do
      assert Fake.preview_margin_order(%{}) == {:error, :missing_order_fields}

      market_buy = %{symbol: "ethusd", side: :buy, type: :market}
      assert Fake.preview_margin_order(market_buy) == {:error, :total_spend_required}

      assert Fake.preview_margin_order(%{market_buy | side: :hold}) ==
               {:error, {:unknown_side, "hold"}}

      sized = Map.put(market_buy, :total_spend, "5000")
      assert Fake.preview_margin_order(sized) == @missing

      assert {:ok, %{"preorder" => _preorder, "postorder" => _postorder}} =
               Fake.preview_margin_order(sized, creds())
    end
  end

  describe "funding" do
    test "list_funding_payments validates, then narrows by timestamp" do
      assert Fake.list_funding_payments(since: "yesterday") ==
               {:error, {:invalid_option, :since, "yesterday"}}

      assert Fake.list_funding_payments([]) == @missing
      assert {:ok, [_first, _second]} = Fake.list_funding_payments(creds())
      assert {:ok, [only]} = Fake.list_funding_payments(creds(since: 1_683_732_000_000))
      assert only["hourlyFundingTransfer"]["instrumentSymbol"] == "BTCGUSDPERP"
      assert {:ok, []} = Fake.list_funding_payments(creds(to: 1_683_000_000_000))
    end

    test "funding_payment_report validates dates and rows, then answers rows" do
      assert Fake.funding_payment_report(rows: 0) == {:error, {:invalid_option, :rows, 0}}

      assert Fake.funding_payment_report(from: "not-a-date") ==
               {:error, {:invalid_option, :from, "not-a-date"}}

      assert Fake.funding_payment_report([]) == @missing
      assert {:ok, [%{"action" => "Credit"}]} = Fake.funding_payment_report(creds())
    end

    test "the spreadsheet reports return bytes and need from and to together" do
      assert Fake.funding_amount_report("btcgusdperp", from: ~D[2026-01-01]) ==
               {:error, :from_and_to_together}

      assert Fake.funding_amount_report("", []) == {:error, {:invalid_option, :symbol, ""}}
      assert Fake.funding_amount_report("btcgusdperp", []) == @missing
      assert {:ok, <<"PK", _rest::binary>>} = Fake.funding_amount_report("btcgusdperp", creds())

      assert Fake.funding_payment_report_file(to: ~D[2026-01-01]) ==
               {:error, :from_and_to_together}

      assert {:ok, <<"PK", _rest::binary>>} = Fake.funding_payment_report_file(creds())
    end
  end

  describe "clearing" do
    test "create validates the terms before the credential and awaits the counterparty" do
      assert Fake.create_clearing_order(%{}) == {:error, :missing_clearing_terms}
      assert Fake.create_clearing_order(@terms) == @missing

      assert {:ok, %{"result" => "AwaitConfirm", "clearing_id" => _value}} =
               Fake.create_clearing_order(@terms, creds())
    end

    test "broker create needs both counterparties and an expiry, in that order" do
      assert Fake.create_broker_clearing_order(@terms) ==
               {:error, {:missing_option, :source_counterparty_id}}

      assert Fake.create_broker_clearing_order(@terms, source_counterparty_id: "A") ==
               {:error, {:missing_option, :target_counterparty_id}}

      both = [source_counterparty_id: "A", target_counterparty_id: "B"]

      assert Fake.create_broker_clearing_order(@terms, both) ==
               {:error, {:missing_option, :expires_in_hrs}}

      assert {:ok, %{"result" => "AwaitSourceTargetConfirm"}} =
               Fake.create_broker_clearing_order(@terms, creds(both ++ [expires_in_hrs: 1]))
    end

    test "status, cancel and confirm validate the id, and confirm the terms, first" do
      assert Fake.get_clearing_order("") == {:error, {:invalid_clearing_id, ""}}
      assert Fake.cancel_clearing_order(nil) == {:error, {:invalid_clearing_id, nil}}
      assert Fake.confirm_clearing_order("", %{}) == {:error, {:invalid_clearing_id, ""}}
      assert Fake.confirm_clearing_order("ID1", %{}) == {:error, :missing_clearing_terms}
      assert Fake.get_clearing_order("ID1") == @missing

      assert {:ok, %{"result" => "ok"}} = Fake.get_clearing_order("ID1", creds())

      assert {:ok, %{"result" => "ok", "details" => "ID1 order canceled"}} =
               Fake.cancel_clearing_order("ID1", creds())

      assert {:ok, %{"result" => "confirmed"}} =
               Fake.confirm_clearing_order("ID1", @terms, creds())
    end

    test "list_clearing_orders needs both bounds of a window and filters by symbol and side" do
      assert Fake.list_clearing_orders(expiration_start: 1) ==
               {:error, {:window_needs_both_bounds, :expiration}}

      assert Fake.list_clearing_orders(submission_end: 1) ==
               {:error, {:window_needs_both_bounds, :submission}}

      assert Fake.list_clearing_orders([]) == @missing
      assert {:ok, [_first, _second]} = Fake.list_clearing_orders(creds(symbol: "BTCEUR"))
      assert {:ok, []} = Fake.list_clearing_orders(creds(symbol: "ethusd"))
      assert {:ok, [%{"side" => "buy"}]} = Fake.list_clearing_orders(creds(side: :buy))
    end

    test "list_clearing_brokers and list_clearing_trades validate, then answer" do
      assert Fake.list_clearing_brokers(expiration_end: 1) ==
               {:error, {:window_needs_both_bounds, :expiration}}

      assert {:ok, [%{"source_side" => "buy"}]} = Fake.list_clearing_brokers(creds())
      assert Fake.list_clearing_trades(limit: 0) == {:error, {:invalid_option, :limit, 0}}
      assert Fake.list_clearing_trades([]) == @missing
      assert {:ok, [_first, _second]} = Fake.list_clearing_trades(creds())
      assert {:ok, [%{"clearingId" => "41M23L5Q"}]} = Fake.list_clearing_trades(creds(limit: 1))
    end
  end

  describe "accounts and OAuth" do
    test "list_accounts honours limit and the venue's created-on-or-before :since" do
      assert Fake.list_accounts(limit: 0) == {:error, {:invalid_option, :limit, 0}}
      assert Fake.list_accounts([]) == @missing
      assert {:ok, [_first, _second]} = Fake.list_accounts(creds())
      assert {:ok, [%{"account" => "primary"}]} = Fake.list_accounts(creds(limit: 1))

      assert {:ok, [%{"account" => "primary"}]} =
               Fake.list_accounts(creds(since: 1_500_000_000_000))

      master = %{api_key: "k", api_secret: "s", key_scope: :master}
      assert {:ok, [_first, _second]} = Fake.list_accounts(credentials: master)
    end

    test "refresh_access_token refuses as the real call does, and rotates the refresh token" do
      assert Fake.refresh_access_token("", "r") == {:error, :client_id_required}
      assert Fake.refresh_access_token(nil, "r") == {:error, :client_id_required}
      assert Fake.refresh_access_token("c", " ") == {:error, :refresh_token_required}

      assert Fake.refresh_access_token("c", "r", client_secret: 5) ==
               {:error, {:invalid_option, :client_secret, :redacted}}

      assert Fake.refresh_access_token("c", "r", auth_url: "http://example.com") ==
               {:error, {:insecure_url, :gemini}}

      assert {:ok, %{"access_token" => _value, "refresh_token" => rotated}} =
               Fake.refresh_access_token("c", "old-refresh")

      assert rotated != "old-refresh"
    end

    test "revoke_access_token needs an OAuth token, not an API key" do
      assert Fake.revoke_access_token([]) == {:error, :oauth_token_required}
      assert Fake.revoke_access_token(creds()) == {:error, :oauth_token_required}

      assert Fake.revoke_access_token(credentials: %{access_token: ""}) ==
               {:error, :oauth_token_required}

      assert {:ok, %{"message" => message}} =
               Fake.revoke_access_token(credentials: %{access_token: "token"})

      assert message =~ "revoked"
    end
  end
end
