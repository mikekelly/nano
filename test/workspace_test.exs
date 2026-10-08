defmodule WorkspaceTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(System.tmp_dir!(), "workspace-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

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
    assert {:error, _} = Workspace.edit(path, "c", "c")
    assert {:error, _} = Workspace.edit(path, "missing", "c")
    assert {:error, _} = Workspace.read(path, offset: 20)
    assert {:error, _} = Workspace.read(path, bytes: 1)
  end

  test "streamed pages count actual lines and byte cuts give the next offset", %{dir: dir} do
    path = Path.join(dir, "lines")
    File.write!(path, "one\ntwo\nthree\n")
    assert {:ok, "two" <> more} = Workspace.read(path, offset: 2, bytes: 4)
    assert more =~ "offset: 3"
    assert {:ok, "three"} = Workspace.read(path, offset: 3)
    assert {:error, "offset 4 past 3 lines"} = Workspace.read(path, offset: 4)
    File.write!(path, "")
    assert {:ok, ""} = Workspace.read(path)
    assert {:error, "offset 2 past 0 lines"} = Workspace.read(path, offset: 2)
    File.write!(path, "\n\n")
    assert {:ok, "\n"} = Workspace.read(path)
  end

  test "multi-megabyte lines do not allocate a whole line or whole file", %{dir: dir} do
    path = Path.join(dir, "huge")
    File.write!(path, :binary.copy("x", 8_000_000) <> "\nlast")
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          first = Workspace.read(path, bytes: 100)
          second = Workspace.read(path, offset: 2, bytes: 100)
          send(parent, {:bounded_read, first, second})
        end,
        [:monitor, {:max_heap_size, %{size: 100_000, kill: true, error_logger: false}}]
      )

    assert_receive {:bounded_read, {:error, message}, {:ok, "last"}}, 3000
    assert message =~ "line 1 exceeds 100 bytes"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "tail preserves newline and blank lines, and caps lines and bytes", %{dir: dir} do
    path = Path.join(dir, "tail")
    File.write!(path, "a\nb\n\n")
    assert {:ok, "a\nb\n\n"} = Workspace.tail(path)
    assert {:ok, text} = Workspace.tail(path, limit: 2)
    assert text =~ "Tail truncated"
    assert String.ends_with?(text, "b\n\n")
    assert {:ok, text} = Workspace.tail(path, bytes: 2)
    assert String.ends_with?(text, "\n\n")
    File.write!(path, "")
    assert {:ok, ""} = Workspace.tail(path)

    for opts <- [[bytes: 0], [limit: -1], [bytes: nil], [limit: "a"]] do
      assert {:error, _} = Workspace.tail(path, opts)
      assert {:error, _} = Workspace.read(path, opts)
      assert {:error, _} = Workspace.ls(dir, opts)
    end

    assert {:error, :enoent} = Workspace.tail(path <> "missing")
  end

  test "ls caps bytes and entries, keeps hidden entries and marks directories", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".hidden"))
    File.write!(Path.join(dir, "z"), "")
    assert {:ok, ".hidden/\nz"} = Workspace.ls(dir)
    assert {:ok, text} = Workspace.ls(dir, limit: 1)
    assert text =~ ".hidden/"
    assert text =~ "Listing truncated"
    assert {:ok, text} = Workspace.ls(dir, bytes: 2)
    assert text =~ "Listing truncated"
  end

  test "find and grep respect nested ignores, negation and hidden files, even with positive globs",
       %{dir: dir} do
    search = Path.join(dir, "search")
    output = Path.join(dir, "output")
    File.mkdir_p!(Path.join(search, "nested"))
    File.mkdir_p!(Path.join(search, ".git"))
    File.write!(Path.join(search, ".gitignore"), "ignored*\n*.tmp\n!keep.tmp\n")
    File.write!(Path.join(search, "nested/.gitignore"), "secret*\n")

    for name <- [
          "visible.ex",
          ".hidden.ex",
          "ignored.ex",
          "junk.tmp",
          "keep.tmp",
          "nested/good.ex",
          "nested/secret.ex",
          ".git/internals.ex"
        ] do
      File.write!(Path.join(search, name), "Needle\n")
    end

    opts = [cwd: search, output_dir: output]
    assert {:ok, text} = Workspace.find("**/*.ex", opts)
    assert text =~ "visible.ex"
    assert text =~ ".hidden.ex"
    assert text =~ "nested/good.ex"
    refute text =~ "ignored.ex"
    refute text =~ "secret.ex"
    refute text =~ "internals.ex"
    assert {:ok, text} = Workspace.find("*.tmp", opts)
    assert text =~ "keep.tmp"
    refute text =~ "junk.tmp"
    assert {:ok, text} = Workspace.find("nested/{good,secret}.ex", opts)
    assert text =~ "nested/good.ex"
    refute text =~ "secret.ex"
    assert {:ok, text} = Workspace.grep("needle", opts ++ [ignore_case: true, glob: "**/*.ex"])
    assert text =~ ".hidden.ex:1:Needle"
    refute text =~ "ignored.ex"
    refute text =~ "secret.ex"
    assert {:ok, text} = Workspace.find("*.ex", opts ++ [no_ignore: true])
    assert text =~ "ignored.ex"
    refute text =~ "internals.ex"
    assert {:ok, "No files found matching pattern"} = Workspace.find("*.none", opts)
    assert {:ok, "No matches found"} = Workspace.grep("absent", opts)
    assert {:error, %{status: 2}} = Workspace.grep("[", opts)
    assert {:error, :invalid_glob} = Workspace.find("[", opts)
  end

  test "search truncates matches, bytes and huge lines with full output path", %{dir: dir} do
    search = Path.join(dir, "search")
    File.mkdir_p!(search)

    File.write!(
      Path.join(search, "huge.ex"),
      Enum.map_join(1..300, "\n", fn _ -> "hit " <> :binary.copy("x", 1000) end)
    )

    opts = [cwd: search, output_dir: Path.join(dir, "output")]
    assert {:ok, text} = Workspace.grep("hit", opts ++ [limit: 2])
    assert text =~ "Results truncated"
    assert text =~ "Full unfiltered results:"
    assert text =~ "500 columns"
    assert byte_size(text) < 1600
    assert {:ok, text} = Workspace.grep("hit", opts ++ [bytes: 100])
    assert text =~ "Results truncated"
    assert byte_size(text) < 500
  end

  test "shell saves full output and reports exit and timeout", %{dir: dir} do
    assert {:ok, %{status: 7, tail: "hello", bytes: 5}} =
             Workspace.sh("printf hello; exit 7", output_dir: dir)

    assert {:ok, %{status: :timeout, tail: tail}} =
             Workspace.sh("echo before; sleep 10", output_dir: dir, timeout: 100)

    assert tail =~ "before"

    assert {:ok, %{status: 0, tail: tail, path: path}} =
             Workspace.sh("seq 1 5000", output_dir: dir, bytes: 100, limit: 3)

    assert tail =~ "Tail truncated"
    assert String.ends_with?(tail, "4998\n4999\n5000\n")
    assert byte_size(File.read!(path)) > 20_000
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
