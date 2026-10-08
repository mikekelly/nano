defmodule OptionalServicesTest.Service do
  use GenServer

  def start_link(opts) do
    send(opts[:owner], {:optional_attempt, opts[:id]})

    case Agent.get(opts[:control], & &1) do
      :fail ->
        {:error, :corrupt_state}

      :raise ->
        raise "bad optional configuration"

      :run ->
        GenServer.start_link(__MODULE__, opts)

      {:existing, pid} ->
        {:error, {:already_started, pid}}

      :wait ->
        send(opts[:owner], {:optional_blocked, opts[:id], self()})

        receive do
          :release -> GenServer.start_link(__MODULE__, opts)
        after
          5000 -> {:error, :startup_timeout}
        end
    end
  end

  def init(opts) do
    send(opts[:owner], {:optional_running, opts[:id], self()})
    {:ok, opts}
  end
end

defmodule OptionalServicesTest do
  use ExUnit.Case, async: true
  alias Nano.OptionalServices, as: Services

  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, tries - 1)
        )
  end

  defp spec(id, control) do
    %{
      id: id,
      start:
        {OptionalServicesTest.Service, :start_link, [[owner: self(), id: id, control: control]]}
    }
  end

  test "empty defaults boot and expose a small discoverable status" do
    manager = start_supervised!({Services, name: nil})
    assert Services.status(manager) == %{}
    refute Services.configured?(:missing, manager)
    refute Services.configured?(:missing, :optional_services_not_started)
    assert {:error, :unknown_service} = Services.retry(:missing, manager)
  end

  test "failed and malformed services do not prevent a healthy service or node boot; retry recovers" do
    {:ok, broken} = Agent.start_link(fn -> :fail end)
    {:ok, healthy} = Agent.start_link(fn -> :run end)

    manager =
      start_supervised!(
        {Services,
         name: nil,
         retry_ms: 5000,
         specs: [spec(:broken, broken), spec(:healthy, healthy), %{bad: :spec}]}
      )

    assert_receive {:optional_running, :healthy, healthy_pid}
    eventually(fn -> Services.status(manager)[:broken].status == :failed end)
    state = Services.status(manager)
    assert Services.configured?(:broken, manager)
    assert state[:healthy].status == :running
    assert state[:broken].error =~ "corrupt_state"
    assert is_integer(state[:broken].next_retry_at)
    assert state[:broken].next_retry_in_ms > 0
    refute Map.has_key?(state[:broken], :spec)
    assert state[{:invalid_spec, 2}].status in [:starting, :failed]
    Agent.update(broken, fn _ -> :run end)
    assert :ok = Services.retry(:broken, manager)
    assert_receive {:optional_running, :broken, broken_pid}
    eventually(fn -> Services.status(manager)[:broken].status == :running end)
    ref1 = Process.monitor(healthy_pid)
    ref2 = Process.monitor(broken_pid)
    stop_supervised!(Services)
    assert_receive {:DOWN, ^ref1, :process, ^healthy_pid, _}
    assert_receive {:DOWN, ^ref2, :process, ^broken_pid, _}
  end

  test "raising starts and a missing module remain isolated, bounded and observable" do
    {:ok, raising} = Agent.start_link(fn -> :raise end)

    manager =
      start_supervised!(
        {Services,
         name: nil,
         retry_ms: 10,
         max_retry_ms: 20,
         specs: [spec(:raising, raising), {OptionalServiceThatDoesNotExist, []}]}
      )

    eventually(fn ->
      statuses = Services.status(manager)
      statuses[:raising].attempts >= 2 and statuses[OptionalServiceThatDoesNotExist].attempts >= 2
    end)

    statuses = Services.status(manager)
    assert Process.alive?(manager)
    assert statuses[:raising].error =~ "bad optional configuration"
    assert byte_size(statuses[OptionalServiceThatDoesNotExist].error) <= 600
    assert statuses[OptionalServiceThatDoesNotExist].status in [:starting, :failed]
  end

  test "a service tree that dies is retried and duplicate ids are not silently discarded" do
    {:ok, control} = Agent.start_link(fn -> :run end)

    manager =
      start_supervised!(
        {Services, name: nil, retry_ms: 10, specs: [spec(:same, control), spec(:same, control)]}
      )

    assert_receive {:optional_running, :same, _}
    assert_receive {:optional_running, :same, _}

    eventually(fn ->
      Enum.all?(Services.status(manager), fn {_, s} -> s.status == :running end)
    end)

    state = Services.status(manager)
    assert Map.keys(state) |> Enum.sort() == [:same, {:duplicate, 1, :same}] |> Enum.sort()
    old = state[:same].pid
    Process.exit(old, :kill)
    assert_receive {:optional_running, :same, _}
    eventually(fn -> Services.status(manager)[:same].pid not in [nil, old] end)
  end

  test "stale retry timers cannot amplify attempts after manual retry" do
    {:ok, control} = Agent.start_link(fn -> :fail end)

    manager =
      start_supervised!({Services, name: nil, retry_ms: 5000, specs: [spec(:broken, control)]})

    eventually(fn -> Services.status(manager)[:broken].status == :failed end)
    slot = :sys.get_state(manager).services[:broken].slot
    old_ref = :sys.get_state(slot).attempt_ref
    Services.retry(:broken, manager)
    eventually(fn -> Services.status(manager)[:broken].attempts == 2 end)
    send(slot, {:attempt, old_ref})
    Process.sleep(20)
    assert Services.status(manager)[:broken].attempts == 2
  end

  test "runtime restart exhaustion is isolated and retry uses the unchanged desired spec" do
    {:ok, control} = Agent.start_link(fn -> :run end)

    manager =
      start_supervised!({Services, name: nil, retry_ms: 5000, specs: [spec(:runtime, control)]})

    assert_receive {:optional_running, :runtime, child}
    Agent.update(control, fn _ -> :fail end)
    Process.exit(child, :kill)
    eventually(fn -> Services.status(manager)[:runtime].status == :failed end)
    assert Process.alive?(manager)
    Agent.update(control, fn _ -> :run end)
    Services.retry(:runtime, manager)
    assert_receive {:optional_running, :runtime, new_child}
    assert new_child != child
  end

  test "slow initialization leaves boot, healthy peers and status responsive" do
    {:ok, slow} = Agent.start_link(fn -> :wait end)
    {:ok, healthy} = Agent.start_link(fn -> :run end)

    manager =
      start_supervised!(
        {Services, name: nil, specs: [spec(:slow, slow), spec(:healthy, healthy)]}
      )

    assert_receive {:optional_blocked, :slow, starter}, 2000

    try do
      assert_receive {:optional_running, :healthy, _}, 2000
      assert Services.status(manager)[:slow].status == :starting
    after
      send(starter, :release)
    end

    assert_receive {:optional_running, :slow, _}, 2000
    eventually(fn -> Services.status(manager)[:slow].status == :running end)
  end

  test "already-started external service is not stolen or killed" do
    {:ok, external} = Agent.start_link(fn -> :external end)
    {:ok, control} = Agent.start_link(fn -> {:existing, external} end)

    manager =
      start_supervised!({Services, name: nil, retry_ms: 5000, specs: [spec(:external, control)]})

    eventually(fn -> Services.status(manager)[:external].status == :failed end)
    assert Services.status(manager)[:external].error =~ "already_started"
    assert Process.alive?(external)
    stop_supervised!(Services)
    assert Process.alive?(external)
  end
end
