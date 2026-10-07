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

  @tag :tmp_dir
  test "parent directories and atomic original-file multi-edit", %{tmp_dir: dir} do
    path = Path.join(dir, "nested/file")
    assert :ok = Files.write(path, "alpha beta gamma\n")
    assert {:ok, %{diff: diff}} = Files.edit(path, [{"alpha", "ALPHA"}, {"gamma", "GAMMA"}])
    assert is_binary(diff)
    assert File.read!(path) == "ALPHA beta GAMMA\n"
    assert {:error, _} = Files.edit(path, [{"ALPHA beta", "x"}, {"beta", "y"}])
    assert File.read!(path) == "ALPHA beta GAMMA\n"
    assert {:error, _} = Files.edit(path, "beta", "beta")
    assert {:error, _} = Files.edit(path, "", "new")
  end

  @tag :tmp_dir
  test "byte-limited pages never skip an unread line", %{tmp_dir: dir} do
    path = Path.join(dir, "pages")
    Files.write(path, "one\ntwo\nthree\n")

    assert {:ok, %{text: "one\n", next_offset: 1, more: true, clipped: true}} =
             Files.read(path, bytes: 5)

    assert {:ok, %{text: "two\n", next_offset: 2}} = Files.read(path, bytes: 5, offset: 1)
    assert {:error, _} = Files.read(path, offset: 99)
    assert {:error, _} = Files.read(path, bytes: 1)
  end

  @tag :tmp_dir
  test "regex and case insensitive grep", %{tmp_dir: dir} do
    path = Path.join(dir, "search")
    Files.write(path, "before\nAlpha 123\nafter\n")
    assert {:ok, %{matches: [%{line: 2}]}} = Files.grep(~r/Alpha \d+/, glob: path)
  end

  test "elapsed information and unbounded timeout option" do
    assert {:ok, %{status: 0, elapsed_ms: elapsed}} = Shell.sh("echo done", timeout: :infinity)
    assert is_integer(elapsed) and elapsed >= 0
  end

  test "immediate kill completes reliably" do
    for _ <- 1..8 do
      assert {:ok, worker} = Shell.start("sleep 30", notify: self())
      Shell.kill(worker)
      assert_receive {:shell_done, ^worker, %{reason: :kill_command}}, 6000
    end
  end

  @tag :tmp_dir
  test "grep context, case and nested git ignore semantics", %{tmp_dir: dir} do
    System.cmd("git", ["init", "-q", dir])
    Files.write(Path.join(dir, ".gitignore"), "ignored*\n!ignored-keep\n")
    Files.write(Path.join(dir, "ignored-file"), "ALPHA\n")
    Files.write(Path.join(dir, "ignored-keep"), "before\nALPHA\nafter\n")
    Files.write(Path.join(dir, "visible"), "other\n")

    assert {:ok, %{matches: [hit]}} =
             Files.grep("alpha", glob: dir <> "/*", ignore_case: true, context: 1)

    assert hit.line == 2
    assert [%{line: 1}] = hit.before
    assert [%{line: 3}] = hit.after

    assert {:ok, %{matches: hits}} =
             Files.grep(~r/alpha/, glob: dir <> "/*", ignore_case: true, gitignore: false)

    assert length(hits) == 2
    assert {:ok, %{entries: entries}} = Files.find(dir <> "/*")
    refute Path.join(dir, "ignored-file") in entries
  end

  @tag :tmp_dir
  test "tail announces line-only clipping and accurate counts", %{tmp_dir: dir} do
    path = Path.join(dir, "tail")
    Files.write(path, "one\ntwo\nthree\n")

    assert {:ok, %{text: "three\n", clipped: true, lines: 1, total_lines: 3, from_line: 3}} =
             Files.tail(path, lines: 1)

    assert {:ok, %{text: "one\ntwo\nthree\n", clipped: false, lines: 3, total_lines: 3}} =
             Files.tail(path)

    Files.write(path, "no newline")
    assert {:ok, %{text: "no newline", next_offset: 1, more: false}} = Files.read(path)
    assert {:ok, %{lines: 1, total_lines: 1}} = Files.tail(path)
  end

  @tag :tmp_dir
  test "multi-edit counts, late overlap and original matching", %{tmp_dir: dir} do
    path = Path.join(dir, "edits")
    Files.write(path, "a b c d a")
    assert {:error, {:expected_one_match, 2}} = Files.edit(path, "a", "z")
    assert {:error, _} = Files.edit(path, [{"b", "B"}, {"c d", "CD"}, {"d", "D"}])
    assert File.read!(path) == "a b c d a"
    assert {:error, _} = Files.edit(path, [{"b", "B"}, {"B", "X"}])
    assert File.read!(path) == "a b c d a"
  end
end
