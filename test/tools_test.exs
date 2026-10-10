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
end
