defmodule Seedling.ShellTest do
  use ExUnit.Case, async: true
  alias Seedling.Shell

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "atlas-shell-test-" <> Base.encode16(:crypto.strong_rand_bytes(10))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "shell combines streams, exit code, cwd and environment without mutating node", %{dir: dir} do
    assert {:ok, result} =
             Shell.sh(
               "printf '%s:%s' \"$PWD\" \"$SEEDLING_TEST_VALUE\"; printf error >&2; exit 7",
               cwd: dir,
               env: %{"SEEDLING_TEST_VALUE" => "value"},
               spool_dir: dir
             )

    assert result.exit_code == 7
    assert result.status == :exited
    assert result.output == dir <> ":valueerror"
    assert result.duration_ms >= 0
    assert File.read!(result.output_path) == result.output
    assert System.get_env("SEEDLING_TEST_VALUE") == nil
  end

  test "shell keeps bounded tail while full log survives", %{dir: dir} do
    assert {:ok, result} = Shell.sh("seq 1 1000", max_bytes: 100, max_lines: 3, spool_dir: dir)
    assert result.output == "998\n999\n1000\n"
    assert result.shown_lines == 3
    assert result.truncated
    assert result.notice =~ "Full output"
    assert File.read!(result.output_path) =~ "1\n2\n3\n"
    assert {:ok, empty} = Shell.sh("true", spool_dir: dir)
    assert empty.output == ""
    assert empty.bytes == 0
  end

  test "timeout keeps printed data and kills a process group", %{dir: dir} do
    marker = Path.join(dir, "must-not-exist")
    command = "echo before; (sleep 0.5; touch '#{marker}') & wait"
    assert {:ok, result} = Shell.sh(command, timeout: 50, spool_dir: dir)
    assert result.status == :timeout
    assert result.output =~ "before"
    Process.sleep(600)
    refute File.exists?(marker)
  end

  test "background returns quickly, completion carries no output, status and tail recover", %{
    dir: dir
  } do
    started = System.monotonic_time(:millisecond)
    assert {:ok, task} = Shell.background("sleep 0.1; echo done", spool_dir: dir)
    assert System.monotonic_time(:millisecond) - started < 100
    assert {:ok, %{status: :running}} = Shell.status(task)
    assert_receive {:seedling_task, id, result}, 2_000
    assert id == task.id
    assert result.status == :exited
    refute Map.has_key?(result, :output)
    assert result.bytes == 5
    assert {:ok, ^result} = Shell.status(Map.delete(task, :pid))
    assert {:ok, %{output: "done\n"}} = Shell.tail(task)
    assert Shell.cancel(task) == :ok
  end

  test "background survives caller dying and cancel kills descendants", %{dir: dir} do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, task} = Shell.background("sleep 1; echo done", notify: parent, spool_dir: dir)
        send(parent, {:task, task})
      end)

    ref = Process.monitor(caller)
    assert_receive {:task, task}
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    assert Process.alive?(task.pid)
    assert :ok = Shell.cancel(task)
    assert_receive {:seedling_task, _, %{status: :cancelled}}, 2_000
  end

  test "worker killed by operator reports error and cleans command group", %{dir: dir} do
    marker = Path.join(dir, "operator-kill-marker")

    {:ok, task} =
      Shell.background("echo ready; (sleep 0.5; touch '#{marker}') & wait", spool_dir: dir)

    wait_for(fn -> File.exists?(task.group_path) end)
    Process.exit(task.pid, :kill)
    assert_receive {:seedling_task, _, %{status: :error}}, 2_000
    assert {:ok, %{status: :error}} = Shell.status(task)
    Process.sleep(600)
    refute File.exists?(marker)
  end

  test "bad options and missing cwd are actionable errors", %{dir: dir} do
    assert {:error, %{reason: :invalid_cwd}} = Shell.sh("true", cwd: Path.join(dir, "missing"))
    assert {:error, %{reason: :invalid_timeout}} = Shell.sh("true", timeout: 0)
    assert {:error, %{reason: :invalid_command}} = Shell.sh("")
    assert {:error, %{reason: :invalid_env}} = Shell.sh("true", env: [{"BAD=KEY", "value"}])
    assert {:error, %{reason: :invalid_options}} = Shell.tail("absent", max_lines: 0)
  end

  test "invalid binary output is announced, bounded and raw data is retained", %{dir: dir} do
    source = Path.join(dir, "raw.bin")
    File.write!(source, <<255, 0, 65, 10>>)
    assert {:ok, result} = Shell.sh("cat '#{source}'", spool_dir: dir)
    assert result.transformed
    assert result.notice =~ "raw bytes remain"
    assert result.output == "\\x00A\n"
    assert File.read!(result.output_path) == <<255, 0, 65, 10>>
    assert {:ok, tail} = Shell.tail(source, max_bytes: 2)
    assert tail.output == "A\n"
    assert tail.truncated
  end

  test "tail avoids breaking UTF-8 boundaries and caps a single long line", %{dir: dir} do
    path = Path.join(dir, "utf8.log")
    File.write!(path, "prefix é✓尾")
    assert {:ok, result} = Shell.tail(path, max_bytes: 4)
    assert String.valid?(result.output)
    assert result.output == "尾"
    assert result.truncated
    File.write!(path, String.duplicate("x", 100_000))
    assert {:ok, %{output: output, shown_lines: 1}} = Shell.tail(path, max_bytes: 64)
    assert byte_size(output) == 64
  end

  test "large output spills completely and results stay far below harness cap", %{dir: dir} do
    assert {:ok, result} = Shell.sh("seq 1 100000", spool_dir: dir)
    assert result.bytes > 500_000
    assert byte_size(result.output) <= 16_000
    assert result.shown_lines == 200
    assert byte_size(inspect(result, limit: :infinity, printable_limit: :infinity)) < 40_000
    assert File.stat!(result.output_path).size == result.bytes
  end

  test "unset environment, infinite timeout and command-not-found exits", %{dir: dir} do
    assert {:ok, result} =
             Shell.sh("printf '%s' \"${HOME-unset}\"",
               env: %{"HOME" => nil},
               timeout: :infinity,
               spool_dir: dir
             )

    assert result.output == "unset"

    assert {:ok, %{exit_code: 127, status: :exited}} =
             Shell.sh("seedling_nonexistent_command_7e3c", spool_dir: dir)
  end

  test "bad option shapes and corrupt persisted status are errors", %{dir: dir} do
    assert {:error, %{reason: :invalid_options}} = Shell.sh("true", nil)
    assert {:error, %{reason: :invalid_options}} = Shell.background("true", ["bad"])
    assert {:error, %{reason: :invalid_cwd}} = Shell.sh("true", cwd: nil)
    assert {:error, %{reason: :invalid_notify}} = Shell.background("true", notify: "name")
    assert {:error, %{reason: :invalid_spool_dir}} = Shell.background("true", spool_dir: nil)
    path = Path.join(dir, "invalid.term")
    task = %{result_path: path, output_path: path}
    assert {:error, %{reason: :missing_result}} = Shell.status(task)
    File.write!(path, "invalid")
    assert {:error, %{reason: :invalid_result}} = Shell.status(task)
    File.write!(path, :erlang.term_to_binary(:valid_term_but_not_metadata))
    assert {:error, %{reason: :invalid_result}} = Shell.status(task)
    assert {:error, %{reason: :invalid_task}} = Shell.status(%{})
  end

  test "start failure from unwritable spool path leaves manager usable", %{dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, "not a directory")
    assert {:error, %{message: message}} = Shell.background("true", spool_dir: path)
    assert message =~ "Cannot start command"
    assert {:ok, %{exit_code: 0}} = Shell.sh("true", spool_dir: dir)
  end

  test "named agent completion is retried during absence and delivered after restart", %{dir: dir} do
    name = "shell-restart-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    parent = self()
    old = fake_agent(name, parent)
    ref = Process.monitor(old)
    {:ok, task} = Shell.background("sleep 0.1; echo done", notify: {:agent, name}, spool_dir: dir)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    wait_for(fn -> File.exists?(task.result_path) end)
    refute_receive {:delivered, _, _}, 150
    new = fake_agent(name, parent)
    assert_receive {:delivered, ^new, {:seedling_task, id, result}}, 2_000
    assert id == task.id
    assert result.status == :exited
    Process.exit(new, :kill)
  end

  test "dashboard attribution survives an eval ending and an agent restarting", %{dir: dir} do
    name = "shell-owner-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    parent = self()
    old = fake_agent(name, parent)
    ref = Process.monitor(old)

    caller =
      spawn(fn ->
        Process.put(:"$callers", [old])
        {:ok, task} = Shell.background("sleep 30", notify: {:agent, name}, spool_dir: dir)
        send(parent, {:owned_task, task})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:owned_task, task}, 2_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert Nano.Ops.process(task.pid).kind == {:spawned_by, name}
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = fake_agent(name, parent)
    wait_for(fn -> Nano.Ops.process(task.pid).kind == {:spawned_by, name} end)
    assert :ok = Shell.cancel(task)
    assert_receive {:delivered, ^new, {:seedling_task, _, %{status: :cancelled}}}, 2_000
    Process.exit(new, :kill)
  end

  test "agent evals infer a stable default notification target", %{dir: dir} do
    name = "shell-default-owner-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    parent = self()
    owner = fake_agent(name, parent)

    caller =
      spawn(fn ->
        Process.put(:"$callers", [owner])
        {:ok, task} = Shell.background("sleep 0.1; echo done", spool_dir: dir)
        send(parent, {:default_task, task})
      end)

    ref = Process.monitor(caller)
    assert_receive {:default_task, task}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    assert_receive {:delivered, ^owner, {:seedling_task, id, %{status: :exited}}}, 2_000
    assert id == task.id
    Process.exit(owner, :kill)
  end

  test "tail is readable before completion without waking command early", %{dir: dir} do
    {:ok, task} = Shell.background("echo started; sleep 30", spool_dir: dir)
    wait_for(fn -> File.stat!(task.output_path).size > 0 end)
    assert {:ok, %{output: "started\n"}} = Shell.tail(task)
    assert {:ok, %{status: :running}} = Shell.status(task)
    :ok = Shell.cancel(task)
    assert_receive {:seedling_task, _, %{status: :cancelled}}, 2_000
  end

  defp fake_agent(name, parent) do
    pid =
      spawn(fn ->
        :yes = Nano.Names.register_name({:agent, name}, self())
        send(parent, {:registered, self()})
        forward(parent)
      end)

    assert_receive {:registered, ^pid}, 2_000

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      Nano.Names.unregister_name({:agent, name})
    end)

    pid
  end

  defp forward(parent) do
    receive do
      message ->
        send(parent, {:delivered, self(), message})
        forward(parent)
    end
  end

  defp wait_for(fun, tries \\ 100)

  defp wait_for(fun, tries) when tries > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for(fun, tries - 1)
        )
  end

  defp wait_for(_fun, 0), do: flunk("condition not reached")
end
