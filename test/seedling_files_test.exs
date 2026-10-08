defmodule Seedling.FilesTest do
  use ExUnit.Case, async: true
  alias Seedling.Files

  test "paging and exact edits return actionable values" do
    dir = Path.join(System.tmp_dir!(), "lyra-files-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "nested/a.txt")
    assert :ok = Files.write(path, "one\ntwo\nthree")
    assert {:ok, %{text: "one", next_offset: 2}} = Files.read(path, limit: 1)
    assert {:error, _} = Files.read(path, offset: 20)
    assert {:ok, %{text: "", warning: warning}} = Files.read(path, bytes: 1)
    assert is_binary(warning)
    assert :ok = Files.edit(path, "two", "second")
    assert {:error, _} = Files.edit(path, "missing", "new")
    assert {:error, _} = Files.edit(path, "one", "one")
    assert {:ok, %{entries: ["nested/"]}} = Files.ls(dir)
    assert {:ok, %{paths: [^path]}} = Files.find(Path.join(dir, "**/*.txt"))
    assert {:error, :enoent} = Files.read(Path.join(dir, "missing"))
  end
end
