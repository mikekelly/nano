defmodule Nano.ToolsTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(System.tmp_dir!(), "altair-tools-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "read line and byte bounds, errors and exact edit", %{dir: dir} do
    p = Path.join(dir, "nested/a")
    assert {:ok, _} = Nano.Tools.write(p, "one\r\ntwo\r\nthree")
    assert {:ok, %{text: "one\r\n", cut: true, next_offset: 2}} = Nano.Tools.read(p, limit: 1)
    assert {:ok, %{text: "two\r\nthree", cut: false}} = Nano.Tools.read(p, offset: 2)
    assert {:error, _} = Nano.Tools.read(p, offset: 5)
    assert {:error, _} = Nano.Tools.read(p, max_bytes: 1)
    assert {:error, _} = Nano.Tools.read(p, limit: 0)
    assert {:error, _} = Nano.Tools.read(p <> "absent")
    assert {:error, _} = Nano.Tools.edit(p, "missing", "x")
    assert {:error, _} = Nano.Tools.edit(p, "one", "one")
    assert {:ok, _} = Nano.Tools.edit(p, "one", "ONE")
    assert File.read!(p) == "ONE\r\ntwo\r\nthree"
    File.write!(p, "a a")
    assert {:error, _} = Nano.Tools.edit(p, "a", "b")
  end

  test "list find grep page and cap", %{dir: dir} do
    File.write!(Path.join(dir, ".hidden"), "match\nmatch\n")
    File.write!(Path.join(dir, "z"), "none")

    assert {:ok, %{entries: [".hidden"], cut: true, next_offset: 1}} =
             Nano.Tools.ls(dir, limit: 1)

    assert {:ok, %{entries: ["z"], cut: false}} = Nano.Tools.ls(dir, offset: 1)
    assert {:ok, %{entries: [".hidden", "z"]}} = Nano.Tools.find("*", cwd: dir)
    assert {:ok, %{cut: true, next_offset: 1}} = Nano.Tools.grep("match", path: dir, limit: 1)
    assert {:ok, %{entries: [_], cut: false}} = Nano.Tools.grep("match", path: dir, offset: 1)
    assert {:ok, %{entries: []}} = Nano.Tools.grep("absent", path: dir)
    assert {:error, _} = Nano.Tools.grep("[", path: dir)
  end

  test "shell output, exit, environment, timeout, complete spool", %{dir: dir} do
    assert {:ok, r} =
             Nano.Tools.sh("printf '%s\\n' \"$TEST_VALUE\"; printf err >&2; exit 7",
               cwd: dir,
               dir: dir,
               env: [{"TEST_VALUE", "hello"}]
             )

    assert r.exit_code == 7
    assert r.text == "hello\nerr"
    assert r.status == :completed

    assert {:ok, r} =
             Nano.Tools.sh("printf 123456789; sleep 3", dir: dir, timeout: 50, max_bytes: 4)

    assert r.status == :timed_out
    assert r.cut
    assert r.text == "6789"
    assert File.read!(r.path) == "123456789"
    assert {:error, _} = Nano.Tools.sh("true", cwd: dir <> "missing")
  end

  test "background survives caller death, kill and durable status", %{dir: dir} do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, h} =
          Nano.Background.start("sleep 0.1; echo complete",
            owner: "nonexistent-" <> dir,
            dir: dir
          )

        send(parent, {:handle, h})
      end)

    ref = Process.monitor(caller)
    assert_receive {:handle, h}
    assert_receive {:DOWN, ^ref, :process, ^caller, _}
    Process.sleep(200)
    assert {:ok, %{status: :completed, exit_code: 0}} = Nano.Background.status(h)
    assert {:ok, %{text: "complete\n"}} = Nano.Background.tail(h)
    Process.exit(h.pid, :kill)
    {:ok, h} = Nano.Background.start("sleep 10", owner: "nonexistent", dir: dir)
    Process.sleep(50)
    assert :ok = Nano.Background.stop(h)
    Process.sleep(100)
    assert {:ok, %{status: :killed}} = Nano.Background.status(h)
    Process.exit(h.pid, :kill)
  end

  test "completion waits for replacement owner and dashboard attribution persists", %{dir: dir} do
    name = "tools-owner-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    old =
      spawn(fn ->
        receive do
          :quit -> :ok
        end
      end)

    assert :yes = Nano.Names.register_name({:agent, name}, old)
    {:ok, h} = Nano.Background.start("sleep 0.1; printf done", owner: name, dir: dir)
    assert Nano.Ops.owner(h.pid) == name
    Process.exit(old, :kill)
    Process.sleep(200)
    assert Process.alive?(h.pid)
    assert Nano.Ops.owner(h.pid) == name
    assert :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    id = h.id
    assert_receive {:background, ^id, %{status: :completed, bytes: 4, output_path: path}}, 1000
    assert File.read!(path) == "done"
    refute_receive {:background, ^id, _}, 150
  end

  test "dashboard worker death terminates descendants", %{dir: dir} do
    marker = Path.join(dir, "must-not-exist")

    {:ok, h} =
      Nano.Background.start("(sleep 0.3; touch '#{marker}') & wait", owner: "absent", dir: dir)

    Process.sleep(80)
    Process.exit(h.pid, :kill)
    Process.sleep(400)
    refute File.exists?(marker)
    assert {:ok, %{status: :interrupted}} = Nano.Background.status(h)
  end

  test "default search cap, line truncation, byte caps and invalid inputs", %{dir: dir} do
    path = Path.join(dir, "matches")
    File.write!(path, String.duplicate("needle " <> String.duplicate("x", 800) <> "\n", 105))
    assert {:ok, r} = Nano.Tools.grep("needle", path: path)
    assert r.cut
    assert byte_size(r.text) <= 16000
    assert r.next_offset == length(r.entries)
    assert r.lines_truncated
    assert Enum.any?(r.notices, &String.contains?(&1, "500"))
    File.write!(path, String.duplicate("needle\n", 105))

    assert {:ok, %{entries: matches, cut: true, next_offset: 100}} =
             Nano.Tools.grep("needle", path: path)

    assert length(matches) == 100

    assert {:ok, %{entries: last, cut: false}} =
             Nano.Tools.grep("needle", path: path, offset: 100)

    assert length(last) == 5
    assert {:error, _} = Nano.Tools.grep("needle", path: path <> "absent")
    assert {:error, _} = Nano.Tools.ls(path)
    assert {:error, _} = Nano.Tools.ls(dir, offset: -1)
    assert {:error, _} = Nano.Background.start("true", owner: "test", timeout: 0, dir: dir)
    assert {:error, _} = Nano.Tools.sh("true", dir: dir, env: [bad: 3])
    File.write!(path, String.duplicate("x", 1_000_000))
    assert {:error, text} = Nano.Tools.read(path, max_bytes: 100)
    assert text =~ "single line exceeds"
  end

  test "owner inference and large output spooling", %{dir: dir} do
    name = "tools-inferred-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert :yes = Nano.Names.register_name({:agent, name}, self())
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    {:ok, h} = Nano.Background.start("printf done", dir: dir)
    assert h.owner == name
    id = h.id
    assert_receive {:background, ^id, %{status: :completed}}, 1000

    {:ok, r} =
      Nano.Tools.sh("awk 'BEGIN {for(i=0;i<10000;i++) print \"output\"}'",
        dir: dir,
        limit: 5,
        max_bytes: 100
      )

    assert r.bytes == 70000
    assert r.cut
    assert byte_size(r.text) <= 100
    assert length(String.split(r.text, "\n")) <= 5
    assert File.stat!(r.path).size == 70000
  end

  test "ignore-aware files and relative search paths", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "nested"))
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, ".gitignore"), "ignored*\n")
    File.write!(Path.join(dir, "ignored.txt"), "needle\n")
    File.write!(Path.join(dir, ".hidden"), "needle\n")
    File.write!(Path.join(dir, ".git/secret"), "needle\n")
    File.write!(Path.join(dir, "nested/a.txt"), "needle\n")
    assert {:ok, r} = Nano.Tools.find("**/*", cwd: dir)
    assert ".hidden" in r.entries
    refute "ignored.txt" in r.entries
    refute ".git/secret" in r.entries
    assert {:ok, r} = Nano.Tools.find("**/*", cwd: dir, include_ignored: true)
    assert "ignored.txt" in r.entries
    assert {:ok, r} = Nano.Tools.grep("needle", path: dir)
    assert Enum.sort(r.entries) == [".hidden:1: needle", "nested/a.txt:1: needle"]
    assert {:ok, r} = Nano.Tools.grep("needle", path: dir, include_ignored: true)
    assert "ignored.txt:1: needle" in r.entries

    assert {:ok, %{entries: ["a.txt:1: needle"]}} =
             Nano.Tools.grep("needle", path: Path.join(dir, "nested/a.txt"))
  end

  test "precise cuts, zero progress errors and EOF offset", %{dir: dir} do
    File.write!(Path.join(dir, "long-entry"), "normal match\n")
    assert {:error, message} = Nano.Tools.ls(dir, max_bytes: 1)
    assert message =~ "increase max_bytes"
    assert {:error, _} = Nano.Tools.find("*", cwd: dir, max_bytes: 1)
    assert {:error, _} = Nano.Tools.find("*", cwd: dir, enumeration_timeout: 0)
    assert {:error, _} = Nano.Tools.grep("match", path: dir, max_bytes: 1)
    assert {:ok, r} = Nano.Tools.grep("match", path: dir)
    refute r.lines_truncated
    assert r.notices == []
    assert r.continuation == nil
    assert {:error, message} = Nano.Tools.read(Path.join(dir, "long-entry"), offset: 2)
    assert message =~ "1 lines"
    File.write!(Path.join(dir, "empty"), "")
    assert {:ok, %{text: "", cut: false}} = Nano.Tools.read(Path.join(dir, "empty"))
    assert {:error, _} = Nano.Tools.read(Path.join(dir, "empty"), offset: 2)
  end

  test "bounded giant lines, binary skips, valid tail text", %{dir: dir} do
    File.write!(Path.join(dir, "giant"), "needle " <> String.duplicate("x", 20000))
    assert {:error, message} = Nano.Tools.grep("needle", path: dir, max_line_bytes: 1000)
    assert message =~ "single line exceeds"
    assert {:ok, r} = Nano.Tools.grep("needle", path: dir, max_line_bytes: 30000)
    assert r.lines_truncated

    assert r.notices == [
             "Some matching lines truncated to 500 characters; use read for full lines"
           ]

    File.rm!(Path.join(dir, "giant"))
    File.write!(Path.join(dir, "nul"), <<0, "needle\n">>)
    File.write!(Path.join(dir, "invalid"), <<255, "needle\n">>)
    File.write!(Path.join(dir, "valid"), "needle αβγ\n")
    assert {:ok, r} = Nano.Tools.grep("needle", path: dir)
    assert r.binary_files_skipped == 2
    assert r.entries == ["valid:1: needle αβγ"]
    path = Path.join(dir, "invalid")
    assert {:ok, r} = Nano.Tools.tail(path, max_bytes: 10)
    assert r.encoding_replaced
    assert String.valid?(r.text)
    assert byte_size(r.text) <= 10
    File.write!(path, "αβγδ")
    assert {:ok, r} = Nano.Tools.tail(path, max_bytes: 5)
    assert String.valid?(r.text)
    assert byte_size(r.text) <= 5
    assert r.cut
  end

  test "search offsets cross files without retaining skipped matches", %{dir: dir} do
    File.write!(Path.join(dir, "a"), String.duplicate("needle\n", 1000))
    File.write!(Path.join(dir, "b"), "needle " <> String.duplicate("α", 700) <> "\n")

    assert {:ok, %{entries: [entry], cut: false, lines_truncated: true}} =
             Nano.Tools.grep("needle", path: dir, offset: 1000, limit: 1)

    assert entry == "b:1: needle " <> String.duplicate("α", 493)
    assert {:ok, %{entries: [], cut: false}} = Nano.Tools.grep("needle", path: dir, offset: 1001)
    assert {:error, _} = Nano.Tools.grep("needle", path: dir, offset: -1)
  end
end
