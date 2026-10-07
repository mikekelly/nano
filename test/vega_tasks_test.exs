defmodule Vega.TasksTest do
  use ExUnit.Case, async: false
  alias Vega.Tasks

  setup do
    root =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "tasks-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp eventually(fun, tries \\ 300)
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

  defp done(task),
    do:
      eventually(fn ->
        case Tasks.status(task) do
          {:ok, s} -> s.status not in [:starting, :running]
          _ -> false
        end
      end)

  test "returns immediately, saves full merged output, cwd/env/exit and bounded byte paging", %{
    root: root
  } do
    {:ok, task} =
      Tasks.start("sleep 0.2; printf '%s\\n' \"$VEGA_TEST\"; pwd; printf err >&2; exit 7",
        root: root,
        cwd: root,
        env: [{"VEGA_TEST", "hello"}]
      )

    assert Process.alive?(task.pid)
    assert_receive {:vega_task, event}, 2000
    assert event.id == task.id
    assert event.status == :completed
    assert event.exit_code == 7
    refute Map.has_key?(event, :text)
    assert {:ok, s} = Tasks.status(task.dir)
    assert s.completed_at >= s.started_at
    assert {:ok, %{text: text, truncated: false}} = Tasks.read(task)
    assert text == "hello\n#{root}\nerr"
    assert event.bytes == byte_size(text)
    assert {:ok, %{text: "err", truncated: true}} = Tasks.read(task, limit: 3)
    assert {:ok, %{text: "hello", next: 5}} = Tasks.read(task, offset: 0, limit: 5)
    assert {:error, :invalid_offset} = Tasks.read(task, offset: -1)
    assert {:error, :limit_must_be_1_to_50000} = Tasks.read(task, limit: 100_000)
    assert {:error, :not_running} = Tasks.stop(task)
  end

  test "large output remains on disk, bounded default tail", %{root: root} do
    {:ok, task} = Tasks.start("head -c 200000 /dev/zero; printf end", root: root)
    assert_receive {:vega_task, %{bytes: 200_003}}, 2000
    assert {:ok, %{text: text, truncated: true}} = Tasks.read(task)
    assert byte_size(text) == 16000
    assert String.ends_with?(text, "end")
    assert File.stat!(task.output_path).size == 200_003
  end

  for mode <- [:stop, :timeout, :kill, :normal] do
    test "#{mode} cleans descendants in the OS process group", %{root: root} do
      cleanup_case(unquote(mode), root)
    end
  end

  defp cleanup_case(mode, root) do
    childfile = Path.join(root, "child")
    suffix = if mode == :normal, do: "sleep 0.1; exit 0", else: "wait"
    opts = if mode == :timeout, do: [timeout: 300], else: []

    {:ok, task} =
      Tasks.start("sleep 60 & echo $! > '#{childfile}'; " <> suffix, [root: root] ++ opts)

    eventually(fn -> File.exists?(childfile) and File.read!(childfile) != "" end)
    child = String.trim(File.read!(childfile))

    case mode do
      :stop -> assert :ok = Tasks.stop(task)
      :kill -> Process.exit(task.pid, :kill)
      _ -> :ok
    end

    done(task)

    eventually(fn ->
      case File.read("/proc/#{child}/stat") do
        {:error, :enoent} -> true
        {:ok, stat} -> String.split(stat) |> Enum.at(2) == "Z"
        _ -> false
      end
    end)

    {:ok, s} = Tasks.status(task)

    assert s.status ==
             %{stop: :stopped, timeout: :timed_out, kill: :failed, normal: :completed}[mode]
  end

  test "eval process death cannot kill the unlinked controller", %{root: root} do
    parent = self()

    eval =
      spawn(fn ->
        {:ok, task} = Tasks.start("sleep 0.3; printf survived", root: root, notify: parent)
        send(parent, {:started, task})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, task}
    Process.exit(eval, :kill)
    assert Process.alive?(task.pid)
    assert_receive {:vega_task, %{status: :completed}}, 2000
    assert {:ok, %{text: "survived"}} = Tasks.read(task)
  end

  test "actual Nano agent restart, dashboard attribution and named delivery", %{root: root} do
    Nano.FakeOpenRouter.start()
    name = "task-owner-#{System.unique_integer([:positive])}"
    model = Nano.FakeOpenRouter.model()
    Nano.FakeOpenRouter.listen(model)
    {:ok, old} = NanoAgent.start([name: name] ++ Nano.FakeOpenRouter.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    # Halt model work: this test exercises real agent lifecycle, not a model.
    :sys.suspend(old)
    {:ok, task} = Tasks.start("sleep 0.8; printf restarted", root: root, agent: name)

    eventually(fn ->
      Enum.any?(Nano.Ops.processes(), &(&1.pid == task.pid and &1.kind == {:spawned_by, name}))
    end)

    assert :ok = Nano.Ops.restart_agent(name)
    eventually(fn -> is_pid(NanoAgent.whereis(name)) and NanoAgent.whereis(name) != old end)
    assert Process.alive?(task.pid)
    eventually(fn -> Nano.Ops.process(task.pid).kind == {:spawned_by, name} end)
    done(task)
    id = NanoAgent.info(name).id

    eventually(fn ->
      Enum.any?(Nano.Log.read(id), &(inspect(&1) =~ "vega_task" and inspect(&1) =~ task.id))
    end)

    assert {:ok, %{text: "restarted"}} = Tasks.read(task)
    assert {:ok, %{delivered_at: at}} = Tasks.status(task)
    assert is_integer(at)
  end

  test "completion waits for an absent name, then replays from its durable record", %{root: root} do
    Nano.FakeOpenRouter.start()
    name = "late-owner-#{System.unique_integer([:positive])}"
    {:ok, task} = Tasks.start("printf late", root: root, agent: name)
    done(task)
    assert {:ok, %{delivered_at: nil}} = Tasks.status(task)
    model = Nano.FakeOpenRouter.model()
    Nano.FakeOpenRouter.listen(model)
    {:ok, _} = NanoAgent.start([name: name] ++ Nano.FakeOpenRouter.opts(model))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)

    eventually(fn ->
      case Tasks.status(task) do
        {:ok, %{delivered_at: at}} -> is_integer(at)
        _ -> false
      end
    end)

    assert {:ok, _pid} = Tasks.replay(task, agent: nil)
    assert_receive {:vega_task, %{id: id}}, 2000
    assert id == task.id
  end

  test "immediate stop races command startup safely", %{root: root} do
    for _ <- 1..10 do
      {:ok, task} = Tasks.start("sleep 60 & wait", root: root)
      assert :ok = Tasks.stop(task)
      done(task)
      assert {:ok, %{status: :stopped}} = Tasks.status(task)
    end
  end

  test "relative artifact root remains absolute when command changes cwd", %{root: root} do
    relative =
      Path.join(
        List.duplicate("..", length(Path.split(File.cwd!())) - 1) ++
          [String.trim_leading(root, "/")]
      )

    {:ok, task} = Tasks.start("printf relative", root: relative, cwd: "/tmp")
    assert Path.type(task.dir) == :absolute
    assert_receive {:vega_task, %{status: :completed}}, 2000
    assert {:ok, %{text: "relative"}} = Tasks.read(task)
  end

  test "invalid command and timeout errors are values",
       %{root: root} do
    assert {:error, :command_must_be_nonempty_string} = Tasks.start("", root: root)
    assert {:error, :invalid_timeout} = Tasks.start("true", timeout: -1, root: root)

    assert {:error, :cwd_must_be_existing_directory} =
             Tasks.start("true", cwd: Path.join(root, "missing"), root: root)
  end
end
