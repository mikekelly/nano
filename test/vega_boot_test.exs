defmodule Vega.BootTest do
  use ExUnit.Case, async: true

  defmodule Service do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, nil, name: Keyword.fetch!(opts, :name))

    def init(_), do: {:ok, nil}
  end

  test "a lazy service is adopted and restarted without replacing its live state" do
    name = {:global, {__MODULE__, make_ref()}}
    {:ok, pid} = Service.start_link(name: name)
    Process.unlink(pid)

    sup =
      start_supervised!(%{
        id: :vega_boot_test_sup,
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      })

    assert {:ok, ^pid} = Vega.Boot.ensure_child(sup, {Service, [name: name]})
    assert {:links, links} = Process.info(pid, :links)
    assert sup in links
    assert {:ok, ^pid} = Vega.Boot.ensure_child(sup, {Service, [name: name]})
    Process.exit(pid, :kill)
    next = wait_for(name, pid, 100)
    assert is_pid(next) and next != pid
  end

  defp wait_for(_, _, 0), do: nil

  defp wait_for(name, old, n) do
    case GenServer.whereis(name) do
      nil ->
        Process.sleep(5)
        wait_for(name, old, n - 1)

      ^old ->
        Process.sleep(5)
        wait_for(name, old, n - 1)

      pid ->
        pid
    end
  end
end
