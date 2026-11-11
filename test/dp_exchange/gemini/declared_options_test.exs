defmodule DpExchange.Gemini.DeclaredOptionsTest do
  # DistortionPoint/dp-exchange-core#43: `start_options/0` and `call_options/1` declare the
  # keys a consumer may hand the venue, so it can `Keyword.take/2` instead of finding out by
  # being refused. No network: every check here is an option check, which runs before any
  # request is built.
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Venue}
  alias DpExchange.Gemini
  alias DpExchange.Gemini.{Fake, OptionKeys}

  @probe :dp_contract_unknown_option
  @venues [Gemini, Fake]

  defp public_names(module) do
    module.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
  end

  # The public functions with an entry in `OptionKeys`' table, i.e. those with a call-site
  # check that can be asked by name.
  defp checkable do
    Enum.filter(public_names(Gemini), &in_table?/1)
  end

  defp in_table?(name) do
    _keys = OptionKeys.allowed(name)
    true
  rescue
    KeyError -> false
  end

  defp callback_names, do: Venue.behaviour_info(:callbacks) |> Keyword.keys()

  describe "start_options/0" do
    for module <- @venues do
      test "#{inspect(module)} is a list of unique atoms without the probe key" do
        keys = unquote(module).start_options()

        assert Enum.all?(keys, &is_atom/1)
        assert keys == Enum.uniq(keys)
        refute @probe in keys
      end
    end

    test "is exactly the list the start check refuses against" do
      assert Gemini.start_options() == OptionKeys.start_keys()
      assert Fake.start_options() == Gemini.start_options()
    end

    test "every declared key passes the start check, even holding nil" do
      for key <- Gemini.start_options() do
        assert OptionKeys.check_start([{key, nil}]) == :ok
      end
    end

    test "the probe key is refused at start" do
      assert OptionKeys.check_start([{@probe, nil}]) == {:error, {:unknown_option, @probe}}
    end

    test "the keys the issue saw refused at start are not declared" do
      for key <- [:subscriber, :priority_symbols] do
        refute key in Gemini.start_options()
        assert OptionKeys.check_start([{key, nil}]) == {:error, {:unknown_option, key}}
      end
    end

    test "Keyword.take with the declaration leaves only keys start accepts" do
      opts = [environment: :sandbox, subscriber: self(), priority_symbols: ["BTC-USD"]]
      taken = Keyword.take(opts, Gemini.start_options())

      assert taken == [environment: :sandbox]
      assert OptionKeys.check_start(taken) == :ok
    end
  end

  describe "call_options/1" do
    for module <- @venues do
      test "#{inspect(module)}: every public function answers ok or not_supported" do
        module = unquote(module)

        for name <- public_names(module) do
          case module.call_options(name) do
            {:ok, keys} ->
              assert Enum.all?(keys, &is_atom/1), "#{name}"
              assert keys == Enum.uniq(keys), "#{name} repeats a key"

            {:error, :not_supported} ->
              assert name in callback_names()

            other ->
              flunk("#{inspect(module)}.call_options(#{inspect(name)}): #{inspect(other)}")
          end
        end
      end

      test "#{inspect(module)}: an unknown name or a non-atom is unknown_function" do
        module = unquote(module)

        assert module.call_options(:dp_contract_no_such_function) ==
                 {:error, {:unknown_function, :dp_contract_no_such_function}}

        assert module.call_options("get_price") == {:error, {:unknown_function, "get_price"}}
        assert module.call_options(nil) == {:error, {:unknown_function, nil}}

        assert module.call_options({:get_price, 2}) ==
                 {:error, {:unknown_function, {:get_price, 2}}}
      end

      test "#{inspect(module)}: an inactive endpoint is not_supported, an active one is not" do
        module = unquote(module)
        caps = module.capabilities()
        callbacks = Venue.behaviour_info(:callbacks)

        {active, inactive} =
          callbacks
          |> Enum.split_with(&Capabilities.active?(caps, &1))
          |> then(fn {a, i} -> {Keyword.keys(a), Keyword.keys(i)} end)

        assert inactive != []
        assert active != []

        for name <- inactive do
          assert module.call_options(name) == {:error, :not_supported}, "#{name}"
        end

        for name <- active do
          assert {:ok, _keys} = module.call_options(name)
        end
      end

      test "#{inspect(module)}: child_spec and start_link declare the start options" do
        module = unquote(module)

        assert module.call_options(:child_spec) == {:ok, module.start_options()}
        assert module.call_options(:start_link) == {:ok, module.start_options()}
      end
    end

    test "functions that take no options declare an empty list" do
      for name <- [
            :provider_name,
            :runtime_id,
            :asset_classes,
            :capabilities,
            :quantization,
            :start_options,
            :call_options,
            :venue_does_not_serve,
            :seed_nonce
          ] do
        assert Gemini.call_options(name) == {:ok, []}, "#{name}"
      end
    end

    test "a table function declares exactly OptionKeys.allowed/1" do
      for name <- [:get_trades, :place_order, :live?, :market_status, :subscribe] do
        assert Gemini.call_options(name) == {:ok, OptionKeys.allowed(name)}, "#{name}"
      end
    end

    test "a function the venue does not serve is not_supported, not an empty list" do
      assert Gemini.call_options(:get_news) == {:error, :not_supported}
      assert Gemini.call_options(:get_rate_limit_status) == {:error, :not_supported}
      assert Gemini.call_options(:list_portfolios) == {:error, :not_supported}
    end

    test "every declared key passes the matching check, holding nil" do
      for name <- checkable() -- [:child_spec, :start_link],
          {:ok, keys} <- [Gemini.call_options(name)],
          key <- keys do
        assert OptionKeys.check(name, [{key, nil}]) == :ok, "#{name} #{key}"
      end
    end

    test "a key outside the declaration is refused by the matching check" do
      for name <- checkable(), {:ok, keys} <- [Gemini.call_options(name)] do
        refute @probe in keys
        assert OptionKeys.check(name, [{@probe, nil}]) == {:error, {:unknown_option, @probe}}
      end
    end

    test "Keyword.take with the declaration leaves only keys the call accepts" do
      {:ok, keys} = Gemini.call_options(:get_trades)
      taken = Keyword.take([limit: 5, limt: 5, since: 1], keys)

      assert taken == [limit: 5, since: 1]
      assert OptionKeys.check(:get_trades, taken) == :ok
    end

    test "every key the facade declares for an active endpoint the fake accepts too" do
      for name <- public_names(Gemini), {:ok, facade_keys} <- [Gemini.call_options(name)] do
        assert {:ok, fake_keys} = Fake.call_options(name)

        assert facade_keys -- fake_keys == [],
               "#{name}: the fake refuses #{inspect(facade_keys -- fake_keys)}"
      end
    end

    test "the declared keys are accepted by the fake itself, holding nil" do
      for name <- checkable(), {:ok, keys} <- [Fake.call_options(name)], key <- keys do
        assert OptionKeys.check(name, [{key, nil}]) == :ok, "#{name} #{key}"
      end
    end
  end
end
