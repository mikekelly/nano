defmodule Nano.ToolsTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "nano-tools-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "read paging, caps and actionable errors", %{dir: dir} do
    p = Path.join(dir, "a")
    assert {:ok, _} = Nano.Tools.write(p, "one\ntwo\nthree\n")
    assert {:ok, %{text: "one", next_offset: 2, truncated: true}} = Nano.Tools.read(p, limit: 1)
    assert {:ok, %{text: "two\nthree", truncated: false}} = Nano.Tools.read(p, offset: 2)
    assert {:error, _} = Nano.Tools.read(p, offset: 5)
    assert {:error, _} = Nano.Tools.read(p, max_bytes: 2)
    assert {:error, _} = Nano.Tools.read(p, offset: 0)
    assert {:error, :enoent} = Nano.Tools.read(p <> "missing")
    assert {:ok, %{text: "three"}} = Nano.Tools.tail(p, limit: 1)
  end

  test "unique edits, disjoint edits and no partial modification", %{dir: dir} do
    p = Path.join(dir, "nested/a")
    Nano.Tools.write(p, "aa bb aa\r\n")
    assert {:error, _} = Nano.Tools.edit(p, "aa", "c")
    assert {:error, _} = Nano.Tools.edit(p, "absent", "c")
    assert {:error, _} = Nano.Tools.edit(p, "bb", "bb")
    assert {:error, _} = Nano.Tools.edit(p, [{"aa bb", "x"}, {"bb aa", "y"}])
    assert File.read!(p) == "aa bb aa\r\n"
    assert {:ok, _} = Nano.Tools.edit(p, [{"aa bb", "x"}, {" aa", "y"}])
    assert File.read!(p) == "xy\r\n"
  end

  test "listing find and bounded grep", %{dir: dir} do
    Nano.Tools.write(Path.join(dir, ".hidden"), "Hello\nhello\n")
    Nano.Tools.write(Path.join(dir, "a.txt"), "hello longer text\n")
    assert {:ok, %{truncated: true, entries: [_]}} = Nano.Tools.ls(dir, limit: 1)
    assert {:ok, %{paths: paths}} = Nano.Tools.find("*", cwd: dir)
    assert length(paths) == 2

    assert {:ok, %{truncated: true, matches: [%{line: 1, text: "Hell", truncated: true}]}} =
             Nano.Tools.grep("hello", path: dir, ignore_case: true, limit: 1, line_limit: 4)

    assert {:error, _} = Nano.Tools.grep("[")
  end

  test "git ignored files excluded", %{dir: dir} do
    System.cmd("git", ["init", "-q", dir])
    Nano.Tools.write(Path.join(dir, ".gitignore"), "secret\n")
    Nano.Tools.write(Path.join(dir, "secret"), "needle")
    assert {:ok, %{paths: []}} = Nano.Tools.find("secret", cwd: dir)
    assert {:ok, %{matches: []}} = Nano.Tools.grep("needle", path: dir)
  end

  test "byte caps, continuation and UTF8 tail", %{dir: dir} do
    p = Path.join(dir, "unicode")
    Nano.Tools.write(p, "αβγ")
    assert {:ok, %{text: text, truncated: true}} = Nano.Tools.tail(p, max_bytes: 3)
    assert text == "γ"
    assert String.valid?(text)

    for i <- 1..30,
        do:
          Nano.Tools.write(
            Path.join(dir, "long-name-#{i}"),
            "needle " <> String.duplicate("λ", 100)
          )

    assert {:ok, %{entries: entries, next_offset: n, truncated: true}} =
             Nano.Tools.ls(dir, max_bytes: 100)

    assert byte_size(inspect(entries)) <= 100
    assert {:ok, %{entries: rest}} = Nano.Tools.ls(dir, offset: n)
    assert MapSet.disjoint?(MapSet.new(entries), MapSet.new(rest))

    assert {:ok, %{matches: matches, next_offset: n, truncated: true}} =
             Nano.Tools.grep("needle", path: dir, max_bytes: 1000)

    assert byte_size(inspect(matches, limit: :infinity)) <= 1000
    assert {:ok, %{matches: rest}} = Nano.Tools.grep("needle", path: dir, offset: n)
    refute hd(matches).path == hd(rest).path
  end

  test "shell exit
, environment and bounded output",
       %{dir: dir} do
    assert {:ok, %{exit_status: 7, text: "yes", path: path}} =
             Nano.Tools.sh("printf \"$TEST_VALUE\"; exit 7",
               cwd: dir,
               env: [{"TEST_VALUE", "yes"}]
             )

    assert File.read!(path) == "yes"

    assert {:ok, %{truncated: true, text: "last"}} =
             Nano.Tools.sh("printf 'first\\nlast\\n'", limit: 1)

    assert {:ok, %{state: :timed_out}} = Nano.Tools.sh("printf before; sleep 10", timeout: 30)
  end
end
