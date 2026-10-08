defmodule BackgroundTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(System.tmp_dir!(), "background-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "cwd, environment, stderr, status and persisted result", %{dir: dir} do
    assert {:ok, job} =
             Background.start("printf '%s:' \"$IO_TEST_VALUE\"; pwd; printf err >&2; exit 9",
               cwd: dir,
               output_dir: dir,
               env: %{"IO_TEST_VALUE" => "a'b $c"},
               notify: self()
             )

    id = job.id

    assert_receive {:background, ^id, %{status: 9, path: path, bytes: bytes, duration_ms: ms}},
                   2000

    assert File.read!(path) == "a'b $c:" <> dir <> "\nerr"
    assert bytes == File.stat!(path).size
    assert is_integer(ms) and ms >= 0
    assert {:ok, %{"status" => 9, "path" => ^path}} = Background.result(job)
  end

  for mode <- [:cancel, :timeout] do
    @mode mode
    test "#{mode} kills grandchildren, not just the port wrapper", %{dir: dir} do
      pidfile = Path.join(dir, "grandchild")
      # A nested shell and sleep both inherit the group of the actual setsid child.
      command = "/bin/sh -c 'sleep 30 & echo $! > #{pidfile}; wait' & wait"

      opts = [
        output_dir: dir,
        notify: self(),
        timeout: if(@mode == :timeout, do: 300, else: 5000)
      ]

      assert {:ok, job} = Background.start(command, opts)
      on_exit(fn -> Background.cancel(job) end)
      assert eventually(fn -> File.exists?(pidfile) end)
      pid = pidfile |> File.read!() |> String.trim()
      assert running?(pid)
      if @mode == :cancel, do: assert(:ok == Background.cancel(job))
      id = job.id
      expected = if @mode == :cancel, do: :cancelled, else: :timeout
      assert_receive {:background, ^id, %{status: ^expected}}, 2500
      assert eventually(fn -> not running?(pid) end)
      refute File.exists?(Path.join(dir, "should_not_exist"))
    end
  end

  test "dashboard-style worker kill also kills OS descendants", %{dir: dir} do
    pidfile = Path.join(dir, "kill-child")
    assert {:ok, job} = Background.start("sleep 30 & echo $! > #{pidfile}; wait", output_dir: dir)
    assert eventually(fn -> File.exists?(pidfile) end)
    pid = pidfile |> File.read!() |> String.trim()
    assert running?(pid)
    Process.exit(job.pid, :kill)
    id = job.id
    assert_receive {:background, ^id, %{status: :error, error: "worker exited: :killed"}}, 2000
    assert eventually(fn -> not running?(pid) end)
  end

  test "successful shell exit cleans up leftover background children", %{dir: dir} do
    pidfile = Path.join(dir, "child")
    assert {:ok, job} = Background.start("sleep 30 & echo $! > #{pidfile}", output_dir: dir)
    id = job.id
    assert_receive {:background, ^id, %{status: 0}}, 2000
    pid = pidfile |> File.read!() |> String.trim()
    assert eventually(fn -> not running?(pid) end)
  end

  test "named completion waits across recipient absence", %{dir: dir} do
    name = "background-recipient-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    assert {:ok, job} =
             Background.start("echo finished",
               output_dir: dir,
               notify: name,
               delivery_timeout: 5000
             )

    assert eventually(fn -> match?({:ok, _}, Background.result(job)) end)
    assert Process.alive?(job.pid)
    :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    id = job.id
    assert_receive {:"$gen_cast", {:notify, {:background, ^id, %{status: 0}}}}, 1000
    assert eventually(fn -> not Process.alive?(job.pid) end)
  end

  test "expired recipient leaves retrievable completion", %{dir: dir} do
    assert {:ok, job} =
             Background.start("true",
               output_dir: dir,
               notify: "missing-#{dir}",
               delivery_timeout: 100
             )

    assert eventually(fn -> not Process.alive?(job.pid) end)
    assert {:ok, %{"status" => 0}} = Background.result(job)
  end

  test "rejects invalid controls before launching", %{dir: dir} do
    for timeout <- [0, -1, nil, :infinity, "100"] do
      assert {:error, :invalid_timeout} =
               Background.start("true", timeout: timeout, output_dir: dir)
    end

    assert {:error, :invalid_cwd} = Background.start("true", cwd: Path.join(dir, "missing"))
    assert {:error, :invalid_notify} = Background.start("true", notify: 1, output_dir: dir)
    assert {:error, :invalid_command_or_options} = Background.start(nil)
  end

  defp running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, text} -> not Regex.match?(~r/\) [ZX] /, text)
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end

defmodule BackgroundRestartTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  test "actual agent restart preserves work, default named delivery and dashboard attribution" do
    Fake.start()
    model = Fake.model()
    name = "background-restart-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)
    {:ok, agent} = NanoAgent.start([name: name, start_idle: true] ++ Fake.opts(model))

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
      File.rm_rf(dir)
    end)

    task =
      Task.async(fn ->
        Process.put(:"$callers", [agent])

        Background.start("while [ ! -f '#{dir}/go' ]; do sleep .05; done; echo survived",
          output_dir: dir
        )
      end)

    assert {:ok, job} = Task.await(task)
    on_exit(fn -> Background.cancel(job) end)
    assert Nano.Ops.owner(job.pid) == name
    Process.exit(agent, :kill)

    assert eventually(fn ->
             pid = NanoAgent.whereis(name)
             is_pid(pid) and pid != agent
           end)

    new_agent = NanoAgent.whereis(name)

    assert eventually(fn ->
             case Process.info(job.pid, :dictionary) do
               {:dictionary, entries} -> entries[:"$ancestors"] == [new_agent]
               _ -> false
             end
           end)

    assert Nano.Ops.owner(job.pid) == name
    assert Process.alive?(job.pid)
    Fake.push(model, calls: [idle: nil])
    File.write!(Path.join(dir, "go"), "")
    assert_receive {:openrouter_request, ^model, body}, 3000
    assert inspect(body) =~ job.id
    assert inspect(body) =~ "background"
    assert {:ok, %{"status" => 0}} = Background.result(job)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end
