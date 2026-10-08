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
    {:ok, task} = Shell.background("echo ready; sleep 30", spool_dir: dir)
    wait_for(fn -> File.exists?(task.group_path) end)
    Process.exit(task.pid, :kill)
    assert_receive {:seedling_task, _, %{status: :error}}, 2_000
    assert {:ok, %{status: :error}} = Shell.status(task)
  end

  test "bad options and missing cwd are actionable errors", %{dir: dir} do
    assert {:error, %{reason: :invalid_cwd}} = Shell.sh("true", cwd: Path.join(dir, "missing"))
    assert {:error, %{reason: :invalid_timeout}} = Shell.sh("true", timeout: 0)
    assert {:error, %{reason: :invalid_command}} = Shell.sh("")
    assert {:error, %{reason: :invalid_env}} = Shell.sh("true", env: [{"BAD=KEY", "value"}])
    assert {:error, %{reason: :invalid_options}} = Shell.tail("absent", max_lines: 0)
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
