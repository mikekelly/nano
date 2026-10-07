defmodule Nano.UtilTest do
  use ExUnit.Case, async: true

  alias Nano.Util

  setup do
    dir = Path.join(System.tmp_dir!(), "nano-util-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "read returns {:ok, text} and errors for a missing file", %{dir: dir} do
    path = Path.join(dir, "a.txt")
    File.write!(path, "hello")
    assert {:ok, "hello"} = Util.read(path)
    assert {:error, :enoent} = Util.read(Path.join(dir, "nope"))
    assert {:error, :eisdir} = Util.read(dir)
  end

  test "read max: keeps the head, tail: keeps the end, with a marker", %{dir: dir} do
    path = Path.join(dir, "b.txt")
    File.write!(path, String.duplicate("x", 100))
    {:ok, head} = Util.read(path, max: 10)
    assert head =~ String.duplicate("x", 10)
    assert head =~ "truncated at 10 bytes"
    {:ok, tail} = Util.read(path, tail: true, max: 10)
    assert tail =~ "kept the last 10"
  end

  test "write creates parent directories", %{dir: dir} do
    path = Path.join([dir, "a", "b", "c.txt"])
    assert {:ok, ^path} = Util.write(path, "x")
    assert File.read!(path) == "x"
  end

  test "edit replaces one occurrence and refuses ambiguous or missing text", %{dir: dir} do
    path = Path.join(dir, "c.txt")
    File.write!(path, "one two two")
    assert {:ok, _} = Util.edit(path, "one", "1")
    assert File.read!(path) == "1 two two"
    assert {:error, :ambiguous} = Util.edit(path, "two", "2")
    assert {:error, :not_found} = Util.edit(path, "zzz", "q")
    assert {:ok, _} = Util.edit(path, "two", "2", all: true)
    assert File.read!(path) == "1 2 2"
  end

  test "find uses globs", %{dir: dir} do
    File.write!(Path.join(dir, "a.ex"), "")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join([dir, "sub", "b.ex"]), "")
    File.write!(Path.join(dir, "c.txt"), "")
    assert length(Util.find("**/*.ex", dir)) == 2
  end

  test "grep finds lines with file and number", %{dir: dir} do
    File.write!(Path.join(dir, "g.ex"), "defmodule A do\n  def start, do: :ok\nend\n")
    [hit] = Util.grep("def start", path: dir)
    assert hit.file =~ "g.ex"
    assert hit.line == 2
    assert hit.text =~ "def start"
    assert Util.grep("DEF START", path: dir, ignore_case: true) != []
  end

  test "sh returns a map with status and output, and kills on timeout" do
    assert %{status: 0, out: "hi\n"} = Util.sh("echo hi")
    assert %{status: 3} = Util.sh("exit 3")
    assert %{timeout: true} = Util.sh("sleep 5", timeout: 200)
  end

  test "shell_quote quotes single quotes" do
    assert Util.shell_quote("a'b") == "'a'\\''b'"
  end

  test "clip and clip_tail bound text" do
    assert Util.clip("abcdef", max: 3) =~ "abc"
    assert Util.clip_tail("abcdef", 3) =~ "def"
    assert Util.clip_tail("ab", 10) == "ab"
  end

  test "node_info and status read the node without touching an agent process" do
    info = Util.node_info()
    assert Map.fetch!(info, :node) == node()
    assert processes = Map.fetch!(info, :processes)
    assert is_integer(processes) and processes > 0
  end
end
