defmodule Seedling.ToolsTest do
  use ExUnit.Case, async: true
  alias Seedling.Tools, as: T

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "orion-tools-test-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      path: Path.join(root, "file.txt"),
      shell_opts: [cwd: root, output_dir: Path.join(root, "logs")]
    }
  end

  test "write creates parents and rewrite replaces the complete file", %{root: root} do
    path = Path.join(root, "a/b/c.txt")
    assert :ok = T.write(path, "first")
    assert :ok = T.write(path, "next")
    assert File.read!(path) == "next"
  end

  test "read pages complete lines, totals don't count a phantom trailing line", %{path: path} do
    File.write!(path, "one\ntwo\nthree\n")

    assert {:ok,
            %{text: "one\ntwo\n", total_lines: 3, next_offset: 3, truncated: true, notice: notice}} =
             T.read(path, limit: 2)

    assert notice =~ "offset=3"
    assert {:ok, %{text: "three\n", next_offset: 4, truncated: false}} = T.read(path, offset: 3)
    assert {:error, %{kind: :offset, total_lines: 3, message: message}} = T.read(path, offset: 4)
    assert message =~ "3 lines"
  end

  test "byte cap advances only past lines actually shown", %{path: path} do
    File.write!(path, "one\ntwo\nthree")

    assert {:ok, %{text: "one\n", next_offset: 2, bytes: 4, truncated: true}} =
             T.read(path, max_bytes: 7)

    assert {:ok, %{text: "two\n", next_offset: 3}} = T.read(path, offset: 2, max_bytes: 7)

    assert {:ok, %{text: "three", total_lines: 3, truncated: false}} =
             T.read(path, offset: 3, max_bytes: 7)
  end

  test "long first line is an explicit error not a silent slice", %{path: path} do
    File.write!(path, String.duplicate("é", 100) <> "\nsmall\n")

    assert {:error, %{kind: :line_too_long, line: 1, line_bytes: 201, message: hint}} =
             T.read(path, max_bytes: 100)

    assert hint =~ "201"
    assert {:ok, %{text: "small\n"}} = T.read(path, offset: 2, max_bytes: 100)
    assert {:ok, %{bytes: 201}} = T.read(path, limit: 1, max_bytes: 201)
  end

  test "empty and final unterminated lines", %{path: path} do
    File.write!(path, "")
    assert {:ok, %{text: "", total_lines: 0, next_offset: 1, truncated: false}} = T.read(path)
    assert {:error, %{kind: :offset}} = T.read(path, offset: 2)
    File.write!(path, "x")
    assert {:ok, %{text: "x", total_lines: 1, next_offset: 2}} = T.read(path)
  end

  test "read keeps CRLF and enforces byte rather than Unicode character caps", %{path: path} do
    File.write!(path, "é\r\né\r\n")
    assert {:ok, %{text: "é\r\n", next_offset: 2, bytes: 4}} = T.read(path, max_bytes: 5)
  end

  test "missing paths, wrong path types, invalid options return actionable errors", %{
    root: root,
    path: path
  } do
    assert {:error, %{message: hint}} = T.read(path)
    assert hint =~ "path"
    assert {:error, %{message: _}} = T.read(root)
    assert {:error, %{message: msg}} = T.read(path, limit: 0)
    assert msg =~ "positive integer"
    File.write!(path, "x")
    assert {:error, %{message: _}} = T.ls(path)
    assert {:error, %{message: _}} = T.ls(Path.join(root, "missing"))
    assert {:error, %{message: _}} = T.tail(path, max_bytes: -1)
    assert {:error, %{message: _}} = T.sh("true", cwd: Path.join(root, "missing"))
  end

  test "exact edit is unique, reports diff and doesn't need reread", %{path: path} do
    File.write!(path, "first\nold\nlast\n")
    assert {:ok, %{replacements: 1, tolerant_matches: 0, diff: diff}} = T.edit(path, "old", "new")
    assert diff =~ "-2| old"
    assert diff =~ "+2| new"
    assert File.read!(path) == "first\nnew\nlast\n"
  end

  test "disjoint multi-edit matches original not intermediate replacements", %{path: path} do
    File.write!(path, "alpha beta gamma")
    assert {:ok, %{replacements: 2}} = T.edit(path, [{"alpha", "beta"}, {"beta", "delta"}])
    assert File.read!(path) == "beta delta gamma"
  end

  test "edit ambiguity, overlap, missing, no-change and invalid input are atomic", %{path: path} do
    original = "first second first third"
    File.write!(path, original)

    assert {:error, %{kind: :ambiguous, matches: 2, message: hint}} =
             T.edit(path, "first", "changed")

    assert hint =~ "Add context"
    assert {:error, %{kind: :overlap}} = T.edit(path, [{"first second", "x"}, {"second", "y"}])

    assert {:error, %{kind: :not_found, message: hint}} =
             T.edit(path, [{"third", "new"}, {"missing", "value"}])

    assert hint =~ "exactly"
    assert {:error, %{kind: :no_change}} = T.edit(path, "third", "third")
    assert {:error, %{kind: :invalid_edit}} = T.edit(path, "", "bad")
    assert {:error, %{kind: :invalid_edit}} = T.edit(path, [])
    assert {:error, %{kind: :invalid_edit}} = T.edit(path, [1])
    assert File.read!(path) == original
  end

  test "overlapping occurrences within old text count as ambiguous", %{path: path} do
    File.write!(path, "aaa")
    assert {:error, %{kind: :ambiguous, matches: 2}} = T.edit(path, "aa", "x")
    assert File.read!(path) == "aaa"
  end

  test "tolerant match handles quotes dashes trailing whitespace and preserves CRLF", %{
    path: path
  } do
    File.write!(path, "keep ‘curly’\r\n“old”—x  \r\nnext\t\r\nlast\r\n")
    assert {:ok, %{tolerant_matches: 1}} = T.edit(path, "\"old\"-x\nnext\n", "new\nline\n")
    assert File.read!(path) == "keep ‘curly’\r\nnew\r\nline\r\nlast\r\n"
  end

  test "tolerant edit preserves untouched text and detects tolerant ambiguity", %{path: path} do
    File.write!(path, "prefix “old”  \nuntouched—suffix")
    assert {:ok, _} = T.edit(path, "\"old\"", "new")
    assert File.read!(path) == "prefix new  \nuntouched—suffix"
    File.write!(path, "“same” and ‘other’ and “same”")
    assert {:error, %{kind: :ambiguous, matches: 2}} = T.edit(path, "\"same\"", "new")
  end

  test "exact match wins over tolerant alternatives and CRLF no-op is refused", %{path: path} do
    File.write!(path, "'exact' and ‘exact’\r\n")
    assert {:ok, %{tolerant_matches: 0}} = T.edit(path, "'exact'", "different")
    assert File.read!(path) == "different and ‘exact’\r\n"

    assert {:error, %{kind: :no_change}} =
             T.edit(path, "different and ‘exact’\n", "different and ‘exact’\n")
  end

  test "multi-edit refuses an individually unchanged replacement", %{path: path} do
    File.write!(path, "alpha beta")
    assert {:error, %{kind: :no_change}} = T.edit(path, [{"alpha", "other"}, {"beta", "beta"}])
    assert File.read!(path) == "alpha beta"
  end

  test "diff is bounded for long multi-line changes", %{path: path} do
    old = Enum.map_join(1..1000, "\n", &"old#{&1}")
    new = Enum.map_join(1..1000, "\n", &"new#{&1}")
    File.write!(path, old)
    assert {:ok, %{diff: diff}} = T.edit(path, old, new)
    assert byte_size(diff) < 9000
    assert diff =~ "Diff truncated"
    assert File.read!(path) == new
  end

  test "ls sorted, hidden names, directory slash, entry and byte caps", %{root: root} do
    assert {:ok, %{text: "(empty directory)", total_entries: 0}} = T.ls(root)
    File.mkdir_p!(Path.join(root, "b"))
    File.write!(Path.join(root, "a"), "")
    File.write!(Path.join(root, ".hidden"), "")

    assert {:ok, %{text: ".hidden\na\nb/", entries: [".hidden", "a", "b/"], truncated: false}} =
             T.ls(root)

    assert {:ok, %{entries: [".hidden"], truncated: true, notice: notice}} = T.ls(root, limit: 1)
    assert notice =~ "limit=2"
    assert {:ok, %{entries: [".hidden"], truncated: true}} = T.ls(root, max_bytes: 7)
  end

  test "find globs respect ignore and include hidden paths, dirs marked", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, ".gitignore"), "ignored.ex\n")

    for name <- ["a.ex", "ignored.ex", ".hidden.ex", "src/nested.ex", "a.txt", ".git/private.ex"],
        do: File.write!(Path.join(root, name), "")

    assert {:ok, result} = T.find("*.ex", cwd: root, output_dir: Path.join(root, "logs"))
    assert result.entries == [".hidden.ex", "a.ex", "src/nested.ex"]

    assert {:ok, %{truncated: true, notice: hint}} =
             T.find("*.ex", cwd: root, limit: 1, output_dir: Path.join(root, "logs"))

    assert hint =~ "limit=2"

    assert {:ok, %{entries: ["src/"]}} =
             T.find("src", cwd: root, output_dir: Path.join(root, "logs"))

    assert {:ok, %{text: "No files found matching pattern"}} =
             T.find("*.none", cwd: root, output_dir: Path.join(root, "logs"))

    assert {:error, %{message: _}} = T.find("[", cwd: root, output_dir: Path.join(root, "logs"))
  end

  test "grep regex/literal/case/glob/context and ignored/hidden files", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(root, "a.txt"), "before\nNeedle.a\nafter\nNeedleXa\n")
    File.write!(Path.join(root, ".hidden.txt"), "needle.a\n")
    File.write!(Path.join(root, "ignored.txt"), "Needle.a\n")
    File.write!(Path.join(root, ".git/private.txt"), "Needle.a\n")
    opts = [output_dir: Path.join(root, "logs"), glob: "*.txt"]
    assert {:ok, %{total_matches: 2, text: text}} = T.grep("Needle.a", root, opts)
    assert text =~ "a.txt:2: Needle.a"
    assert text =~ "a.txt:4: NeedleXa"
    refute text =~ "ignored"
    refute text =~ "private"

    assert {:ok, %{total_matches: 2, text: text}} =
             T.grep("needle.a", root, opts ++ [literal: true, ignore_case: true, context: 1])

    assert text =~ ".hidden.txt:1: needle.a"
    assert text =~ "a.txt-1- before"
    assert text =~ "a.txt-3- after"
    assert {:ok, %{text: "No matches found"}} = T.grep("missing", root, opts)
    assert {:error, %{message: _}} = T.grep("[", root, opts)
    assert {:error, %{message: _}} = T.grep("needle", Path.join(root, "missing"), opts)
  end

  test "grep announces match, byte and per-line character cuts", %{root: root, path: path} do
    File.write!(
      path,
      Enum.map_join(1..6, "\n", &"match#{&1} #{String.duplicate("é", 600)}") <> "\n"
    )

    opts = [output_dir: Path.join(root, "logs")]

    assert {:ok, %{truncated: true, text: text, total_matches: 6, matches: 2}} =
             T.grep("match", path, opts ++ [limit: 2])

    assert text =~ "limit=4"
    assert text =~ "500 characters"
    assert text =~ "match1"
    assert text =~ "match2"
    refute text =~ "match3"
    assert byte_size(text) < 16_500

    assert {:ok, %{truncated: true, notice: hint}} =
             T.grep("match", path, opts ++ [max_bytes: 100])

    assert hint =~ "max_bytes=200"
  end

  test "shell combines stderr/stdout with cwd, env, status and full artifact", %{
    root: root,
    shell_opts: opts
  } do
    result =
      T.sh(
        "printf '%s\\n' \"$PWD\"; printf '%s' \"$TOOL_TEST\"; echo err >&2; exit 7",
        opts ++ [env: [{"TOOL_TEST", "value"}]]
      )

    assert result.status == 7
    refute result.timed_out
    assert result.output == root <> "\nvalueerr\n"
    assert File.read!(result.full_output) == result.output
    assert result.elapsed_ms >= 0
    refute result.truncated
  end

  test "shell tail preserves end with line and byte caps including Unicode", %{shell_opts: opts} do
    result = T.sh("seq 1 1000; printf 'FINAL\\n'", opts ++ [limit: 3])
    assert result.output == "999\n1000\nFINAL\n"
    assert result.total_lines == 1001
    assert result.start_line == 999
    assert result.truncated
    assert result.notice =~ result.full_output
    assert result.notice =~ "offset: 999"
    assert String.starts_with?(File.read!(result.full_output), "1\n2\n")
    result = T.sh("printf 'éééééFIN'", opts ++ [max_bytes: 8])
    assert byte_size(result.output) <= 8
    assert String.valid?(result.output)
    assert String.ends_with?(result.output, "FIN")
    assert result.truncated
    assert result.total_bytes == 13
  end

  test "shell timeout keeps what printed and ends promptly", %{shell_opts: opts} do
    result = T.sh("printf 'before\\n'; sleep 5; printf 'after\\n'", opts ++ [timeout: 100])
    assert result.timed_out
    assert result.status in [124, 137]
    assert result.elapsed_ms < 2000
    assert result.output == "before\n"
    assert File.read!(result.full_output) == "before\n"
  end

  test "natural exit 124/137 isn't claimed as a timeout, optional infinity", %{shell_opts: opts} do
    for status <- [124, 137] do
      result = T.sh("exit #{status}", opts)
      assert result.status == status
      refute result.timed_out
    end

    assert %{status: 0, timed_out: false} = T.sh("true", opts ++ [timeout: :infinity])
  end

  test "shell quoting resists spaces and single quotes", %{shell_opts: opts} do
    value = "quote' ; echo unexpected; $HOME"
    assert %{status: 0, output: ^value} = T.sh("printf '%s' " <> T.quote_arg(value), opts)
  end

  test "tail handles empty, final unterminated, invalid bytes, exact byte boundary", %{path: path} do
    File.write!(path, "")
    assert %{output: "", total_lines: 0, truncated: false} = T.tail(path)
    File.write!(path, "one\ntwo\nthree")
    assert %{output: "two\nthree", start_line: 2, total_lines: 3} = T.tail(path, limit: 2)
    assert %{output: "three", start_line: 3, truncated: true} = T.tail(path, max_bytes: 5)
    File.write!(path, <<255, 0, 65>>)
    assert %{output: output, total_bytes: 3} = T.tail(path)
    assert String.valid?(output)
    assert byte_size(output) <= 3
    File.write!(path, "ééEND")
    assert %{output: output, truncated: false} = T.tail(path, max_bytes: 7)
    assert output == "ééEND"
  end

  test "ignore files work outside a Git repo and globs cannot reinclude ignored files", %{
    root: root,
    shell_opts: opts
  } do
    File.write!(Path.join(root, ".gitignore"), "ignored.ex\n")
    File.mkdir_p!(Path.join(root, "nested"))

    for name <- ["keep.ex", "nested/keep.ex", "ignored.ex", "not.txt"],
        do: File.write!(Path.join(root, name), "needle\n")

    assert {:ok, %{entries: ["keep.ex", "nested/keep.ex"]}} = T.find("*.ex", opts)
    assert {:ok, %{total_matches: 2, text: text}} = T.grep("needle", root, opts ++ [glob: "*.ex"])
    refute text =~ "ignored"
    refute text =~ "not.txt"

    assert {:ok, %{total_matches: 1, text: text}} =
             T.grep("needle", root, opts ++ [glob: "nested/*.ex"])

    assert text =~ "nested/keep.ex"

    assert {:ok, %{text: "No matches found", matches: 0}} =
             T.grep("needle", root, opts ++ [glob: "*.missing"])
  end

  test "find absolute globs retain a relative result, and byte caps are announced", %{
    root: root,
    shell_opts: opts
  } do
    File.write!(Path.join(root, "alpha.ex"), "x")
    File.write!(Path.join(root, "beta.ex"), "x")
    assert {:ok, %{entries: ["alpha.ex", "beta.ex"]}} = T.find(Path.join(root, "*.ex"), opts)
    assert {:ok, %{entries: ["alpha.ex"]}} = T.find(Path.join(root, "alpha.ex"), opts)

    assert {:ok, %{entries: ["alpha.ex"], truncated: true, notice: hint}} =
             T.find("*.ex", opts ++ [max_bytes: 8])

    assert hint =~ "max_bytes=16"
  end

  test "each edit must change after newline normalization and binary text is refused", %{
    path: path
  } do
    original = "alpha\r\nbeta\r\n"
    File.write!(path, original)

    assert {:error, %{kind: :no_change}} =
             T.edit(path, [{"alpha", "changed"}, {"beta\n", "beta\n"}])

    assert File.read!(path) == original
    File.write!(path, <<255, 65>>)
    assert {:error, %{kind: :invalid_encoding}} = T.edit(path, "A", "B")
    assert File.read!(path) == <<255, 65>>
  end

  test "shell timeout escalates TERM-resistant commands", %{shell_opts: opts} do
    result = T.sh("trap '' TERM; printf ready; while :; do sleep 1; done", opts ++ [timeout: 100])
    assert result.timed_out
    assert result.status == 137
    assert result.output == "ready"
    assert result.elapsed_ms < 2500
  end

  test "shell artifact quoting and displayed grep count under byte cap", %{
    root: root,
    path: path,
    shell_opts: opts
  } do
    dir = Path.join(root, "space and 'quote")
    result = T.sh("printf 'exact\\n'", Keyword.put(opts, :output_dir, dir))
    assert result.output == "exact\n"
    assert File.read!(result.full_output) == result.output
    File.write!(path, "match one\nmatch two\n")

    assert {:ok, %{matches: 0, total_matches: 2, truncated: true}} =
             T.grep("match", path, opts ++ [max_bytes: 1])
  end

  test "timeout kills resistant grandchildren even when the direct child exits", %{
    root: root,
    shell_opts: opts
  } do
    pid_path = Path.join(root, "grandchild.pid")

    cmd =
      "sh -c 'trap \"\" TERM; while :; do sleep 1; done' & echo $! > " <>
        T.quote_arg(pid_path) <> "; wait"

    result = T.sh(cmd, opts ++ [timeout: 100])
    assert result.timed_out
    pid = File.read!(pid_path) |> String.trim()
    # A killed orphan may remain a zombie until container PID 1 reaps it; it is
    # no longer executing. No unrelated processes are targeted by this test.
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        state = stat |> String.split(") ") |> List.last() |> String.first()
        unless state == "Z", do: System.cmd("kill", ["-KILL", pid])
        assert state == "Z"
    end
  end
end
