# Run separately so no application/global process names are changed in a running suite:
# MIX_ENV=test mix run --no-start test/support/bots_managed_start_check.exs
ExUnit.start()

defmodule Bots.ManagedStartCheck do
  use ExUnit.Case

  test "managed recovery cannot be bypassed by facade lazy start" do
    old = Application.get_env(:nano, :optional_services, [])
    Application.put_env(:nano, :optional_services, [{Bots, []}])
    on_exit(fn -> Application.put_env(:nano, :optional_services, old) end)
    manager = spawn(fn -> Process.sleep(:infinity) end)
    true = Process.register(manager, Nano.OptionalServices)
    on_exit(fn -> Process.exit(manager, :kill) end)
    assert Process.whereis(Bots.Server) == nil

    assert_raise RuntimeError, "Bots service unavailable: waiting for supervised recovery", fn ->
      Bots.snapshot()
    end

    assert_raise RuntimeError, "Bots service unavailable: waiting for supervised recovery", fn ->
      Bots.create_bot(%{name: "Must not create an unmonitored service"})
    end

    assert Process.whereis(Bots.Server) == nil
  end
end
