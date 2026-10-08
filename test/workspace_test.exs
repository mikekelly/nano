defmodule WorkspaceTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "workspace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "paging and unique exact editing", %{dir: dir} do
    path = Path.join(dir, "a")
    assert {:ok, ^path} = Workspace.write(path, "a\nb\na")
    assert {:ok, text} = Workspace.read(path, limit: 1)
    assert text =~ "offset: 2"
    assert {:error, _} = Workspace.edit(path, "a", "z")
    assert {:ok, _} = Workspace.edit(path, "b", "c")
    assert {:error, _} = Workspace.read(path, offset: 20)
    assert {:error, _} = Workspace.read(path, bytes: 1)
  end

  test "shell saves full output and reports exit and timeout", %{dir: dir} do
    assert {:ok, %{status: 7, tail: "hello", bytes: 5}} =
             Workspace.sh("printf hello; exit 7", output_dir: dir)

    assert {:ok, %{status: :timeout, tail: tail}} =
             Workspace.sh("echo before; sleep 10", output_dir: dir, timeout: 100)

    assert tail =~ "before"
  end

  test "background survives starter process", %{dir: dir} do
    parent = self()

    spawn(fn ->
      send(parent, Background.start("sleep .1; echo done", notify: parent, output_dir: dir))
    end)

    assert_receive {:ok, job}, 1000
    id = job.id
    assert_receive {:background, ^id, %{status: 0}}, 2000
    assert {:ok, "done\n"} = Workspace.tail(job.path)
  end
end
