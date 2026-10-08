defmodule Seedling.FilesTest do
  use ExUnit.Case, async: true
  alias Seedling.Files

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "atlas-files-test-" <> Base.encode16(:crypto.strong_rand_bytes(10))
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "file.txt")}
  end

  test "read pages preserve line endings and report exact continuation", %{path: path} do
    File.write!(path, "one\r\ntwo\r\nthree")
    assert {:ok, page} = Files.read(path, limit: 2)
    assert page.text == "one\r\ntwo\r\n"
    assert page.total_lines == 3
    assert page.next_offset == 3
    assert page.notice =~ "offset: 3"
    assert {:ok, last} = Files.read(path, offset: page.next_offset)
    assert last.text == "three"
    refute last.truncated
    assert {:error, %{reason: :offset_past_end, message: message}} = Files.read(path, offset: 4)
    assert message =~ "3 lines"
  end

  test "read byte cuts do not split lines, long lines and binary data are explicit errors", %{
    path: path
  } do
    File.write!(path, "abc\ndef\n")
    assert {:ok, page} = Files.read(path, max_bytes: 5)
    assert page.text == "abc\n"
    assert page.next_offset == 2
    File.write!(path, "123456789\n")
    assert {:error, %{reason: :line_too_long, message: message}} = Files.read(path, max_bytes: 5)
    assert message =~ "at least 10"
    File.write!(path, <<255, 0>>)
    assert {:error, %{reason: :binary_file}} = Files.read(path)
  end

  test "empty file, missing file, directory and invalid offset", %{path: path, dir: dir} do
    assert {:error, %{reason: :enoent}} = Files.read(path)
    File.write!(path, "")
    assert {:ok, %{text: "", total_lines: 0, next_offset: nil}} = Files.read(path)
    assert {:error, %{reason: :offset_past_end}} = Files.read(path, offset: 2)
    assert {:error, %{reason: :invalid_options}} = Files.read(path, offset: 0)
    assert {:error, %{reason: :eisdir}} = Files.read(dir)
  end

  test "write creates parents and edit applies disjoint matches against original", %{dir: dir} do
    path = Path.join(dir, "parent/file")
    assert {:ok, %{bytes: 17}} = Files.write(path, "hello world\nbye\n!")
    File.chmod!(path, 0o640)
    assert {:ok, result} = Files.edit(path, [{"hello", "bye"}, {"bye\n!", "hello\n!"}])
    assert result.text =~ "@@ line 1 @@"
    assert result.text =~ "+ bye"
    assert File.read!(path) == "bye world\nhello\n!"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
  end

  test "edit refuses missing, ambiguous including overlapping, overlapping edits and no-op", %{
    path: path
  } do
    File.write!(path, "aaa and hello world")
    assert {:error, %{reason: :not_found, message: m}} = Files.edit(path, "missing", "x")
    assert m =~ "including whitespace"
    assert {:error, %{reason: :ambiguous_match, message: m}} = Files.edit(path, "aa", "x")
    assert m =~ "2 times"

    assert {:error, %{reason: :overlapping_edits}} =
             Files.edit(path, [{"hello", "x"}, {"hello world", "y"}])

    assert {:error, %{reason: :no_changes}} = Files.edit(path, "hello", "hello")
    assert File.read!(path) == "aaa and hello world"
  end

  test "edit tolerant quotes, dashes, trailing whitespace and CRLF", %{path: path} do
    File.write!(path, "say “hello”—world   \r\nnext\r\n")
    assert {:ok, %{tolerant: true}} = Files.edit(path, "say \"hello\"-world\nnext", "new\nline")
    assert File.read!(path) == "new\r\nline\r\n"

    assert {:error, %{reason: :not_found}} =
             Files.edit(path, [{"new \nline", "x"}], tolerant: false)
  end

  test "symlinks are not replaced and preview is bounded", %{path: path, dir: dir} do
    File.write!(path, "old")
    link = Path.join(dir, "link")
    File.ln_s!(path, link)
    assert {:error, %{reason: :symlink}} = Files.write(link, "oops")
    assert {:error, %{reason: :symlink}} = Files.edit(link, "old", "oops")
    assert {:ok, result} = Files.edit(path, "old", String.duplicate("x", 20_000))
    assert byte_size(result.text) <= 8_000
    assert result.truncated
    assert result.notice =~ "read/2"
  end

  test "ls includes hidden, sorts, marks directories and announces limits", %{dir: dir} do
    File.write!(Path.join(dir, "z"), "")
    File.write!(Path.join(dir, ".hidden"), "")
    File.mkdir!(Path.join(dir, "a"))
    assert {:ok, %{entries: [".hidden", "a/", "z"]}} = Files.ls(dir)

    assert {:ok, %{entries: [".hidden"], truncated: true, notice: notice}} =
             Files.ls(dir, limit: 1)

    assert notice =~ "Increase limit"
    assert {:error, %{reason: :enotdir}} = Files.ls(Path.join(dir, "z"))
  end

  test "find and grep respect ignores, include hidden and quote hostile patterns/paths", %{
    dir: dir
  } do
    File.write!(Path.join(dir, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(dir, "ignored.txt"), "needle")
    File.write!(Path.join(dir, ".hidden.txt"), "before\nNeedle's $(exit 9)\nafter\n")
    File.write!(Path.join(dir, "space ' file.txt"), "other")
    assert {:ok, found} = Files.find("*.txt", cwd: dir)
    assert Enum.sort(found.entries) == [".hidden.txt", "space ' file.txt"]

    assert {:ok, search} =
             Files.grep("needle's $(exit 9)",
               path: dir,
               literal: true,
               ignore_case: true,
               context: 1
             )

    assert search.matches == 1
    assert search.text =~ ".hidden.txt:2: Needle's $(exit 9)"
    assert search.text =~ ".hidden.txt-1- before"
    refute search.text =~ "ignored.txt"
    assert Enum.count(search.entries, &(&1.kind == :context)) == 2
  end

  test "search limits match count and line length, distinguishes no matches and errors", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "x.txt"), "needle long text\nneedle again\nneedle third\n")
    assert {:ok, result} = Files.grep("needle", path: dir, limit: 1, max_line_chars: 6)
    assert result.matches == 1
    assert result.truncated
    assert result.lines_truncated
    assert result.notice =~ "Use read/2"
    assert {:ok, %{matches: 0, text: "No matches found"}} = Files.grep("absent", path: dir)
    assert {:error, %{reason: :search_failed}} = Files.grep("[", path: dir)

    assert {:ok, %{entries: [], text: "No files found matching pattern"}} =
             Files.find("*.absent", cwd: dir)

    assert {:ok, %{entries: [_], truncated: false}} = Files.find("*.txt", cwd: dir, limit: 1)
  end

  test "read scans huge skipped lines with bounded buffers and preserves final blank lines", %{
    path: path
  } do
    File.write!(path, String.duplicate("a", 300_000) <> "\r\nlast\r\n\r\n")
    assert {:error, %{reason: :line_too_long, message: message}} = Files.read(path, max_bytes: 10)
    assert message =~ "300002 bytes"
    assert {:ok, result} = Files.read(path, offset: 2, max_bytes: 10)
    assert result.text == "last\r\n\r\n"
    assert result.total_lines == 3
    assert result.bytes == 8
  end

  test "edit batches are transactional on a later failed match and have a size guard", %{
    path: path
  } do
    File.write!(path, "original unique")

    assert {:error, %{reason: :not_found}} =
             Files.edit(path, [{"original", "new"}, {"absent", "x"}])

    assert File.read!(path) == "original unique"

    assert {:error, %{reason: :file_too_large}} =
             Files.edit(path, [{"original", "new"}], max_file_bytes: 1)

    assert {:error, %{reason: :invalid_replacement}} = Files.edit(path, "", "new")
    assert {:error, %{reason: :no_changes}} = Files.edit(path, [])
    assert {:error, %{reason: :invalid_replacement}} = Files.edit(path, [{"original", nil}])
  end

  test "tolerant fallback never hides exact ambiguity, and maps Unicode ranges accurately", %{
    path: path
  } do
    File.write!(path, "é: ‘a’ – b  \nkeep ✓\n")
    assert {:ok, %{tolerant: true}} = Files.edit(path, "'a' - b\nkeep ✓", "new\nnext ✓")
    assert File.read!(path) == "é: new\nnext ✓\n"
    File.write!(path, "x x “x”")
    assert {:error, %{reason: :ambiguous_match}} = Files.edit(path, "x", "z")
  end

  test "empty listing and byte limit are distinct", %{dir: dir} do
    assert {:ok, %{text: "(empty directory)", truncated: false}} = Files.ls(dir)
    File.write!(Path.join(dir, "long-name"), "needle")
    assert {:ok, result} = Files.ls(dir, max_bytes: 1)
    assert result.truncated
    assert result.text =~ "No entries fit"
    assert {:ok, result} = Files.grep("needle", path: dir, max_bytes: 1)
    assert result.truncated
    assert result.text =~ "No matches fit"
  end

  test "find globs support path components, braces, classes and recursive zero directories", %{
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "nested/deep"))

    for file <- ["root.ex", "nested/a.ex", "nested/b.exs", "nested/deep/c.ex"] do
      File.write!(Path.join(dir, file), "needle\n")
    end

    assert {:ok, result} = Files.find("nested/*.{ex,exs}", cwd: dir)
    assert Enum.sort(result.entries) == ["nested/a.ex", "nested/b.exs"]
    assert {:ok, result} = Files.find("**/[ac].ex", cwd: dir)
    assert Enum.sort(result.entries) == ["nested/a.ex", "nested/deep/c.ex"]
    assert {:ok, result} = Files.find("**/root.ex", cwd: dir)
    assert result.entries == ["root.ex"]
    assert {:ok, result} = Files.grep("needle", path: dir, glob: "nested/*.ex")
    assert result.matches == 1
    assert hd(result.entries).path == "nested/a.ex"
    assert {:error, %{reason: :invalid_glob}} = Files.find("[", cwd: dir)
  end

  test "grep glob still respects ignored files and excludes .git", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, ".git/x.ex"), "needle")
    File.write!(Path.join(dir, ".gitignore"), "ignored.ex\n")
    File.write!(Path.join(dir, "ignored.ex"), "needle")
    File.write!(Path.join(dir, "included.ex"), "needle")
    assert {:ok, %{matches: 1}} = Files.grep("needle", path: dir, glob: "*.ex")
    assert {:ok, %{entries: ["included.ex"]}} = Files.find("**/*.ex", cwd: dir)
    assert {:ok, %{matches: 1}} = Files.grep("needle", path: Path.join(dir, "included.ex"))
  end

  test "find supports newlines in names without splitting entries", %{dir: dir} do
    File.write!(Path.join(dir, "strange\nname.txt"), "text")
    assert {:ok, %{entries: ["strange\nname.txt"]}} = Files.find("*.txt", cwd: dir)
  end

  test "malformed arguments return errors rather than raising", %{path: path} do
    assert {:error, %{reason: :invalid_argument}} = Files.read(nil)
    assert {:error, %{reason: :invalid_options}} = Files.read(path, :not_options)
    assert {:error, %{reason: :invalid_options}} = Files.ls(".", [{"limit", 10}])
    assert {:error, %{reason: :invalid_path}} = Files.grep("x", path: nil)
    assert {:error, %{reason: :invalid_argument}} = Files.grep(~r/x/)
    assert {:error, %{reason: :invalid_argument}} = Files.find(nil)
    assert {:error, %{reason: :invalid_argument}} = Files.write(nil, "text")
    assert {:error, %{reason: :invalid_replacement}} = Files.edit(path, nil, nil)
  end

  test "special files are refused without blocking", %{path: path} do
    {_, 0} = System.cmd("mkfifo", [path])
    assert {:error, %{reason: :unsupported_file_type}} = Files.read(path)
    assert {:error, %{reason: :unsupported_file_type}} = Files.write(path, "data")
  end

  test "mixed line endings are preserved locally in replacements", %{path: path} do
    File.write!(path, "first\r\nsecond\nthird\r\n")
    assert {:ok, _} = Files.edit(path, [{"first", "first\nadded"}, {"second", "second\nmore"}])
    assert File.read!(path) == "first\r\nadded\r\nsecond\nmore\nthird\r\n"
  end

  test "structured search result including metadata fits comfortably below harness cap", %{
    path: path,
    dir: dir
  } do
    File.write!(path, String.duplicate("needle " <> String.duplicate("x", 500) <> "\n", 200))
    assert {:ok, result} = Files.grep("needle", path: dir)
    assert result.truncated
    assert result.lines_truncated
    assert byte_size(inspect(result, limit: :infinity, printable_limit: :infinity)) < 40_000
  end

  test "malformed context and regex text never raise", %{dir: dir} do
    assert {:error, %{reason: :invalid_options}} = Files.grep("x", path: dir, context: {})
    assert {:error, %{reason: :invalid_options}} = Files.grep("x", path: dir, context: -1)
    assert {:error, %{reason: :invalid_options}} = Files.find("*", cwd: dir, limit: 0)
  end

  test "search display sanitation is announced and raw search spool is available", %{
    path: path,
    dir: dir
  } do
    File.write!(path, "needle" <> <<1>> <> "text\n")
    assert {:ok, result} = Files.grep("needle", path: dir)
    assert result.matches == 1
    assert result.transformed
    assert result.text =~ "\\x01"
    assert result.notice =~ "sanitized"
    assert File.exists?(result.output_path)
  end
end
