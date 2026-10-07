defmodule SeedlingTest do
  use ExUnit.Case, async: true
  alias Seedling.{Files, Shell}
  @tag :tmp_dir
  test "files are bounded and edits unambiguous", %{tmp_dir: dir} do
    path = Path.join(dir, "file")
    assert :ok = Files.write(path, "one\ntwo\nthree\n")
    assert {:ok, %{text: "one\n", next_offset: 1, more: true}} = Files.read(path, lines: 1)
    assert {:ok, %{text: "two\n"}} = Files.read(path, offset: 1, lines: 1)
    assert :ok = Files.edit(path, "two", "TWO")
    assert {:error, {:expected_one_match, 0}} = Files.edit(path, "absent", "x")
    assert {:error, _} = Files.read(path <> "missing")
    assert {:ok, %{matches: [%{line: 2}]}} = Files.grep("TWO", glob: path)
  end

  test "status, environment, cwd and tail" do
    assert {:ok, %{status: 7, text: "/tmp\nvalue\n"}} =
             Shell.sh("pwd; echo $SOL_TEST; exit 7", cwd: "/tmp", env: [{"SOL_TEST", "value"}])
  end

  test "named delivery resolves a replacement process" do
    name = "shell-test-#{System.unique_integer([:positive])}"
    parent = self()

    old =
      spawn(fn ->
        Registry.register(Nano.Registry, {:agent, name}, nil)
        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered
    {:ok, worker} = Shell.start("sleep 0.2; echo complete", notify: name)
    Process.exit(old, :kill)
    Process.sleep(50)

    replacement =
      spawn(fn ->
        Registry.register(Nano.Registry, {:agent, name}, nil)

        receive do
          message -> send(parent, {:delivered, message})
        end
      end)

    assert_receive {:delivered, {:shell_done, ^worker, %{status: 0}}}, 3000
    refute Process.alive?(replacement)
  end

  test "timeout kills a command" do
    assert {:ok, %{reason: :command_timeout, status: status}} = Shell.sh("sleep 30", timeout: 50)
    assert status != 0
  end

  test "worker survives caller death and can be killed" do
    receiver = self()

    caller =
      spawn(fn ->
        {:ok, worker} = Shell.start("sleep 30", notify: receiver)
        send(receiver, {:worker, worker})
      end)

    ref = Process.monitor(caller)
    assert_receive {:worker, worker}
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Process.alive?(worker)
    Shell.kill(worker)
    assert_receive {:shell_done, ^worker, %{reason: :kill_command}}, 6000
  end
end
