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
end
