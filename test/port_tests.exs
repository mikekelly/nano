# Ported from pi's packages/coding-agent/test/tools.test.ts and related suites.
# Each `PortTest.run/2` gets a fresh temp dir and cleans it up.

# ============ read tool ============

PortTest.run("read: reads file contents within limits", fn dir ->
  f = PortTest.tmp_file!(dir, "test.txt", "Hello, world!\nLine 2\nLine 3")
  r = PiTools.read(f, cwd: dir)
  A.eq!(PiTools.text(r), "Hello, world!\nLine 2\nLine 3", "content")
  A.hasnt!(PiTools.text(r), "Use offset=", "no truncation")
  A.truthy!(r.details == nil, "details nil")
end)

PortTest.run("read: non-existent file errors", fn dir ->
  r = PiTools.read(Path.join(dir, "nope.txt"), cwd: dir)
  A.truthy!(r.is_error == true, "is_error")
  A.match!(PiTools.text(r), ~r/not found|ENOENT/i, "error text")
end)

PortTest.run("read: truncates files exceeding line limit", fn dir ->
  lines = Enum.map(1..2500, fn i -> "Line #{i}" end)
  f = PortTest.tmp_file!(dir, "large.txt", Enum.join(lines, "\n"))
  out = PiTools.read(f, cwd: dir) |> PiTools.text()
  A.has!(out, "Line 1", "first")
  A.has!(out, "Line 2000", "2000")
  A.hasnt!(out, "Line 2001", "no 2001")
  A.has!(out, "[Showing lines 1-2000 of 2500. Use offset=2001 to continue.]", "notice")
end)

PortTest.run("read: truncates when byte limit exceeded", fn dir ->
  lines = Enum.map(1..500, fn i -> "Line #{i}: " <> String.duplicate("x", 200) end)
  f = PortTest.tmp_file!(dir, "large-bytes.txt", Enum.join(lines, "\n"))
  out = PiTools.read(f, cwd: dir) |> PiTools.text()
  A.has!(out, "Line 1:", "first")
  A.match!(out, ~r/\[Showing lines 1-\d+ of 500 \(.* limit\)\. Use offset=\d+ to continue\.\]/, "byte notice")
end)

PortTest.run("read: offset parameter", fn dir ->
  lines = Enum.map(1..100, fn i -> "Line #{i}" end)
  f = PortTest.tmp_file!(dir, "offset.txt", Enum.join(lines, "\n"))
  out = PiTools.read(f, cwd: dir, offset: 51) |> PiTools.text()
  A.hasnt!(out, "Line 50", "no 50")
  A.has!(out, "Line 51", "51")
  A.has!(out, "Line 100", "100")
  A.hasnt!(out, "Use offset=", "no notice")
end)

PortTest.run("read: limit parameter", fn dir ->
  lines = Enum.map(1..100, fn i -> "Line #{i}" end)
  f = PortTest.tmp_file!(dir, "limit.txt", Enum.join(lines, "\n"))
  out = PiTools.read(f, cwd: dir, limit: 10) |> PiTools.text()
  A.has!(out, "Line 1", "1")
  A.has!(out, "Line 10", "10")
  A.hasnt!(out, "Line 11", "no 11")
  A.has!(out, "[90 more lines in file. Use offset=11 to continue.]", "notice")
end)

PortTest.run("read: offset + limit together", fn dir ->
  lines = Enum.map(1..100, fn i -> "Line #{i}" end)
  f = PortTest.tmp_file!(dir, "ol.txt", Enum.join(lines, "\n"))
  out = PiTools.read(f, cwd: dir, offset: 41, limit: 20) |> PiTools.text()
  A.hasnt!(out, "Line 40", "no 40")
  A.has!(out, "Line 41", "41")
  A.has!(out, "Line 60", "60")
  A.hasnt!(out, "Line 61", "no 61")
  A.has!(out, "[40 more lines in file. Use offset=61 to continue.]", "notice")
end)

PortTest.run("read: offset beyond file length", fn dir ->
  f = PortTest.tmp_file!(dir, "short.txt", "Line 1\nLine 2\nLine 3")
  r = PiTools.read(f, cwd: dir, offset: 100)
  A.truthy!(r.is_error == true, "is_error")
  A.match!(PiTools.text(r), ~r/Offset 100 is beyond end of file \(3 lines total\)/, "msg")
end)

PortTest.run("read: truncation details", fn dir ->
  lines = Enum.map(1..2500, fn i -> "Line #{i}" end)
  f = PortTest.tmp_file!(dir, "big.txt", Enum.join(lines, "\n"))
  r = PiTools.read(f, cwd: dir)
  t = r.details.truncation
  A.truthy!(t.truncated == true, "truncated")
  A.eq!(t.truncated_by, "lines", "by")
  A.eq!(t.total_lines, 2500, "total")
  A.eq!(t.output_lines, 2000, "out")
end)

# ============ write tool ============

PortTest.run("write: writes contents and message", fn dir ->
  f = Path.join(dir, "write-test.txt")
  r = PiTools.write(f, "Test content", cwd: dir)
  A.eq!(PiTools.text(r), "Successfully wrote to #{f}", "msg")
  A.truthy!(r.details == nil, "details nil")
  A.eq!(File.read!(f), "Test content", "file")
end)

PortTest.run("write: creates parent directories", fn dir ->
  f = Path.join([dir, "nested", "dir", "test.txt"])
  r = PiTools.write(f, "Nested content", cwd: dir)
  A.has!(PiTools.text(r), "Successfully wrote", "msg")
  A.eq!(File.read!(f), "Nested content", "file")
end)

# ============ edit tool ============

PortTest.run("edit: replaces text and produces diff/patch", fn dir ->
  f = PortTest.tmp_file!(dir, "edit.txt", "Hello, world!")
  r = PiTools.edit(f, [%{oldText: "world", newText: "testing"}], cwd: dir)
  A.has!(PiTools.text(r), "Successfully replaced", "msg")
  A.has!(r.details.diff, "testing", "diff")
  A.has!(r.details.patch, "--- ", "patch ---")
  A.has!(r.details.patch, "+++ ", "patch +++")
  A.has!(r.details.patch, "@@", "patch @@")
  A.has!(r.details.patch, "-Hello, world!", "patch -")
  A.has!(r.details.patch, "+Hello, testing!", "patch +")
end)

PortTest.run("edit: fails if text not found", fn dir ->
  f = PortTest.tmp_file!(dir, "edit.txt", "Hello, world!")
  r = PiTools.edit(f, [%{oldText: "nonexistent", newText: "testing"}], cwd: dir)
  A.truthy!(r.is_error == true, "err")
  A.match!(PiTools.text(r), ~r/Could not find the exact text/, "msg")
end)

PortTest.run("edit: ENOENT for missing target", fn dir ->
  missing = Path.join(dir, "missing.txt")
  r = PiTools.edit(missing, [%{oldText: "hello", newText: "world"}], cwd: dir)
  A.truthy!(r.is_error == true, "err")
  A.has!(PiTools.text(r), "Could not edit file: #{missing}. Error code: ENOENT.", "msg")
end)

PortTest.run("edit: fails on multiple occurrences", fn dir ->
  f = PortTest.tmp_file!(dir, "edit.txt", "foo foo foo")
  r = PiTools.edit(f, [%{oldText: "foo", newText: "bar"}], cwd: dir)
  A.match!(PiTools.text(r), ~r/Found 3 occurrences/, "msg")
end)

PortTest.run("edit: multiple disjoint regions", fn dir ->
  f = PortTest.tmp_file!(dir, "edit-multi.txt", "alpha\nbeta\ngamma\ndelta\n")
  r = PiTools.edit(f, [%{oldText: "alpha\n", newText: "ALPHA\n"}, %{oldText: "gamma\n", newText: "GAMMA\n"}], cwd: dir)
  A.has!(PiTools.text(r), "Successfully replaced 2 block(s)", "msg")
  A.eq!(File.read!(f), "ALPHA\nbeta\nGAMMA\ndelta\n", "content")
  A.has!(r.details.diff, "ALPHA", "diff1")
  A.has!(r.details.diff, "GAMMA", "diff2")
end)

PortTest.run("edit: collapses large unchanged gaps in multi-edit diff", fn dir ->
  lines = Enum.map(1..600, fn i -> "line " <> String.pad_leading(Integer.to_string(i), 3, "0") end)
  f = PortTest.tmp_file!(dir, "gap.txt", Enum.join(lines, "\n") <> "\n")
  r = PiTools.edit(f, [
    %{oldText: "line 100\n", newText: "LINE 100\n"},
    %{oldText: "line 300\n", newText: "LINE 300\n"},
    %{oldText: "line 500\n", newText: "LINE 500\n"}
  ], cwd: dir)
  d = r.details.diff
  A.has!(d, "LINE 100", "100")
  A.has!(d, "LINE 300", "300")
  A.has!(d, "LINE 500", "500")
  A.has!(d, "...", "ellipsis")
  A.hasnt!(d, "line 250", "no 250")
  A.truthy!(length(String.split(d, "\n")) < 50, "diff under 50 lines, was #{length(String.split(d, "\n"))}")
end)

PortTest.run("edit: matches against original file, not incrementally", fn dir ->
  f = PortTest.tmp_file!(dir, "orig.txt", "foo\nbar\nbaz\n")
  PiTools.edit(f, [%{oldText: "foo\n", newText: "foo bar\n"}, %{oldText: "bar\n", newText: "BAR\n"}], cwd: dir)
  A.eq!(File.read!(f), "foo bar\nBAR\nbaz\n", "content")
end)

PortTest.run("edit: empty edits rejected", fn dir ->
  f = PortTest.tmp_file!(dir, "e.txt", "hello\nworld\n")
  r = PiTools.edit(f, [], cwd: dir)
  A.truthy!(r.is_error == true, "err")
  A.match!(PiTools.text(r), ~r/edits must contain at least one replacement/, "msg")
end)

PortTest.run("edit: overlapping regions rejected", fn dir ->
  f = PortTest.tmp_file!(dir, "ov.txt", "one\ntwo\nthree\n")
  r = PiTools.edit(f, [%{oldText: "one\ntwo\n", newText: "ONE\nTWO\n"}, %{oldText: "two\nthree\n", newText: "TWO\nTHREE\n"}], cwd: dir)
  A.match!(PiTools.text(r), ~r/overlap/, "msg")
end)

PortTest.run("edit: no partial application when one edit fails", fn dir ->
  orig = "alpha\nbeta\ngamma\n"
  f = PortTest.tmp_file!(dir, "np.txt", orig)
  r = PiTools.edit(f, [%{oldText: "alpha\n", newText: "ALPHA\n"}, %{oldText: "missing\n", newText: "MISSING\n"}], cwd: dir)
  A.truthy!(r.is_error == true, "err")
  A.eq!(File.read!(f), orig, "unchanged")
end)

PortTest.run("edit: keeps the first-changed line in details", fn dir ->
  f = PortTest.tmp_file!(dir, "fcl.txt", "a\nb\nc\nd\n")
  r = PiTools.edit(f, [%{oldText: "c", newText: "C"}], cwd: dir)
  A.eq!(r.details.first_changed_line, 3, "first changed")
end)

# ============ edit fuzzy matching ============

PortTest.run("fuzzy: trailing whitespace stripped", fn dir ->
  f = PortTest.tmp_file!(dir, "tw.txt", "line one   \nline two  \nline three\n")
  r = PiTools.edit(f, [%{oldText: "line one\nline two\n", newText: "replaced\n"}], cwd: dir)
  A.has!(PiTools.text(r), "Successfully replaced", "msg")
  A.eq!(File.read!(f), "replaced\nline three\n", "content")
end)

PortTest.run("fuzzy: fullwidth punctuation in Chinese", fn dir ->
  f = PortTest.tmp_file!(dir, "zh.txt", "你好，世界\n你好（世界）\n")
  r = PiTools.edit(f, [%{oldText: "你好,世界\n你好(世界)\n", newText: "你好，pi\n你好(pi)\n"}], cwd: dir)
  A.has!(PiTools.text(r), "Successfully replaced", "msg")
  A.eq!(File.read!(f), "你好，pi\n你好(pi)\n", "content")
end)

PortTest.run("fuzzy: compatibility-equivalent unicode", fn dir ->
  f = PortTest.tmp_file!(dir, "uc.txt", "ＡＢＣ１２３\ncafe\u0301\n")
  r = PiTools.edit(f, [%{oldText: "ABC123\ncafé\n", newText: "XYZ789\ncoffee\n"}], cwd: dir)
  A.has!(PiTools.text(r), "Successfully replaced", "msg")
  A.eq!(File.read!(f), "XYZ789\ncoffee\n", "content")
end)

PortTest.run("fuzzy: smart single quotes to ASCII", fn dir ->
  f = PortTest.tmp_file!(dir, "ss.txt", "console.log(\u2018hello\u2019);\n")
  PiTools.edit(f, [%{oldText: "console.log('hello');", newText: "console.log('world');"}], cwd: dir)
  A.has!(File.read!(f), "world", "content")
end)

PortTest.run("fuzzy: smart double quotes to ASCII", fn dir ->
  f = PortTest.tmp_file!(dir, "sd.txt", "const msg = \u201CHello World\u201D;\n")
  PiTools.edit(f, [%{oldText: "const msg = \"Hello World\";", newText: "const msg = \"Goodbye\";"}], cwd: dir)
  A.has!(File.read!(f), "Goodbye", "content")
end)

PortTest.run("fuzzy: unicode dashes to ASCII hyphen", fn dir ->
  f = PortTest.tmp_file!(dir, "ud.txt", "range: 1\u20135\nbreak\u2014here\n")
  PiTools.edit(f, [%{oldText: "range: 1-5\nbreak-here", newText: "range: 10-50\nbreak--here"}], cwd: dir)
  A.has!(File.read!(f), "10-50", "content")
end)

PortTest.run("fuzzy: non-breaking space to regular space", fn dir ->
  f = PortTest.tmp_file!(dir, "nb.txt", "hello\u00A0world\n")
  PiTools.edit(f, [%{oldText: "hello world", newText: "hello universe"}], cwd: dir)
  A.has!(File.read!(f), "universe", "content")
end)

PortTest.run("fuzzy: exact match preferred over fuzzy", fn dir ->
  f = PortTest.tmp_file!(dir, "ex.txt", "const x = 'exact';\nconst y = 'other';\n")
  PiTools.edit(f, [%{oldText: "const x = 'exact';", newText: "const x = 'changed';"}], cwd: dir)
  A.eq!(File.read!(f), "const x = 'changed';\nconst y = 'other';\n", "content")
end)

PortTest.run("fuzzy: still fails when truly not found", fn dir ->
  f = PortTest.tmp_file!(dir, "nm.txt", "completely different content\n")
  r = PiTools.edit(f, [%{oldText: "this does not exist", newText: "replacement"}], cwd: dir)
  A.match!(PiTools.text(r), ~r/Could not find the exact text/, "msg")
end)

PortTest.run("fuzzy: detects duplicates after normalization", fn dir ->
  f = PortTest.tmp_file!(dir, "fd.txt", "hello world   \nhello world\n")
  r = PiTools.edit(f, [%{oldText: "hello world", newText: "replaced"}], cwd: dir)
  A.match!(PiTools.text(r), ~r/Found 2 occurrences/, "msg")
end)

PortTest.run("fuzzy: multi-edit mode", fn dir ->
  f = PortTest.tmp_file!(dir, "fm.txt", "console.log(\u2018hello\u2019);\nhello\u00A0world\n")
  PiTools.edit(f, [
    %{oldText: "console.log('hello');\n", newText: "console.log('world');\n"},
    %{oldText: "hello world\n", newText: "hello universe\n"}
  ], cwd: dir)
  A.eq!(File.read!(f), "console.log('world');\nhello universe\n", "content")
end)

PortTest.run("fuzzy: preserves correct occurrence when replacement equals a nearby line", fn dir ->
  orig = ["replace me   ", "after   ", ""] |> Enum.join("\n")
  f = PortTest.tmp_file!(dir, "fp.txt", orig)
  PiTools.edit(f, [%{oldText: "replace me\n", newText: "after\n"}], cwd: dir)
  expected = ["after", "after   ", ""] |> Enum.join("\n")
  A.eq!(File.read!(f), expected, "content")
end)

PortTest.run("fuzzy: preserves untouched lines and patch applies", fn dir ->
  orig = [
    "keep before  ",
    "first target  ",
    "first after",
    "keep middle   ",
    "second target  ",
    "second after",
    "keep after  ",
    ""
  ] |> Enum.join("\n")
  f = PortTest.tmp_file!(dir, "fpm.txt", orig)
  _r = PiTools.edit(f, [
    %{oldText: "first target\nfirst after", newText: "FIRST\nFIRST2"},
    %{oldText: "second target\nsecond after", newText: "SECOND\nSECOND2"}
  ], cwd: dir)
  expected = [
    "keep before  ",
    "FIRST",
    "FIRST2",
    "keep middle   ",
    "SECOND",
    "SECOND2",
    "keep after  ",
    ""
  ] |> Enum.join("\n")
  A.eq!(File.read!(f), expected, "content")
end)

# ============ edit CRLF / BOM ============

PortTest.run("crlf: LF oldText matches CRLF file", fn dir ->
  f = PortTest.tmp_file!(dir, "c.txt", "line one\r\nline two\r\nline three\r\n")
  r = PiTools.edit(f, [%{oldText: "line two\n", newText: "replaced line\n"}], cwd: dir)
  A.has!(PiTools.text(r), "Successfully replaced", "msg")
end)

PortTest.run("crlf: preserves CRLF", fn dir ->
  f = PortTest.tmp_file!(dir, "c.txt", "first\r\nsecond\r\nthird\r\n")
  PiTools.edit(f, [%{oldText: "second\n", newText: "REPLACED\n"}], cwd: dir)
  A.eq!(File.read!(f), "first\r\nREPLACED\r\nthird\r\n", "content")
end)

PortTest.run("lf: preserves LF", fn dir ->
  f = PortTest.tmp_file!(dir, "l.txt", "first\nsecond\nthird\n")
  PiTools.edit(f, [%{oldText: "second\n", newText: "REPLACED\n"}], cwd: dir)
  A.eq!(File.read!(f), "first\nREPLACED\nthird\n", "content")
end)

PortTest.run("crlf: detects duplicates across CRLF/LF variants", fn dir ->
  f = PortTest.tmp_file!(dir, "m.txt", "hello\r\nworld\r\n---\r\nhello\nworld\n")
  r = PiTools.edit(f, [%{oldText: "hello\nworld\n", newText: "replaced\n"}], cwd: dir)
  A.match!(PiTools.text(r), ~r/Found 2 occurrences/, "msg")
end)

PortTest.run("bom: preserves UTF-8 BOM", fn dir ->
  f = PortTest.tmp_file!(dir, "b.txt", "\uFEFFfirst\r\nsecond\r\nthird\r\n")
  PiTools.edit(f, [%{oldText: "second\n", newText: "REPLACED\n"}], cwd: dir)
  A.eq!(File.read!(f), "\uFEFFfirst\r\nREPLACED\r\nthird\r\n", "content")
end)

PortTest.run("bom+crlf: preserved in multi-edit", fn dir ->
  f = PortTest.tmp_file!(dir, "bc.txt", "\uFEFFfirst\r\nsecond\r\nthird\r\nfourth\r\n")
  PiTools.edit(f, [%{oldText: "second\n", newText: "SECOND\n"}, %{oldText: "fourth\n", newText: "FOURTH\n"}], cwd: dir)
  A.eq!(File.read!(f), "\uFEFFfirst\r\nSECOND\r\nthird\r\nFOURTH\r\n", "content")
end)

# ============ bash tool ============

PortTest.run("bash: simple command", fn dir ->
  r = PiTools.bash("echo 'test output'", cwd: dir)
  A.has!(PiTools.text(r), "test output", "output")
  A.truthy!(r.details == nil, "details nil")
end)

PortTest.run("bash: non-zero exit reported as error", fn dir ->
  r = PiTools.bash("echo out; exit 3", cwd: dir)
  A.truthy!(r.is_error == true, "err")
  A.eq!(PiTools.text(r), "out\n\n\nCommand exited with code 3", "text")
end)

PortTest.run("bash: no output", fn dir ->
  r = PiTools.bash("true", cwd: dir)
  A.eq!(PiTools.text(r), "(no output)", "text")
end)

PortTest.run("bash: line truncation persists full output", fn dir ->
  r = PiTools.bash("seq 3000", cwd: dir)
  out = PiTools.text(r)
  A.eq!(r.details.truncation.truncated, true, "truncated")
  A.eq!(r.details.truncation.truncated_by, "lines", "by")
  A.truthy!(r.details.full_output != nil, "full output kept")
  A.match!(out, ~r/\[Showing lines \d+-\d+ of \d+\./, "notice")
  A.has!(r.details.full_output, "2998\n2999\n3000", "full kept end")
end)

PortTest.run("bash: trailing newline not counted as extra line", fn dir ->
  r = PiTools.bash("seq 4000", cwd: dir)
  out = PiTools.text(r)
  A.eq!(r.details.truncation.total_lines, 4000, "total")
  A.eq!(r.details.truncation.output_lines, 2000, "out")
  A.has!(out, "2001", "2001")
  A.has!(out, "4000", "4000")
  A.hasnt!(out, "4001", "no 4001")
end)

PortTest.run("bash: timeout", fn dir ->
  r = PiTools.bash("sleep 5", cwd: dir, timeout: 1)
  A.truthy!(r.is_error == true, "err")
  A.match!(PiTools.text(r), ~r/timed out/i, "msg")
end)

PortTest.run("bash: error when cwd does not exist", fn _dir ->
  r = PiTools.bash("echo test", cwd: "/this/does/not/exist/12345")
  A.truthy!(r.is_error == true, "err")
  A.match!(PiTools.text(r), ~r/Working directory does not exist/, "msg")
end)

PortTest.run("bash: signal-killed commands map to 128 + signal", fn dir ->
  for {sig, code} <- [{"KILL", 137}, {"TERM", 143}] do
    r = PiTools.bash("printf 'before-kill\\n'; kill -#{sig} $$", cwd: dir)
    A.truthy!(r.is_error == true, "err #{sig}")
    A.match!(PiTools.text(r), ~r/before-kill[\s\S]*Command exited with code #{code}$/, "msg #{sig}")
  end
end)

# ============ grep tool ============

PortTest.run("grep: filename included for single file", fn dir ->
  f = PortTest.tmp_file!(dir, "example.txt", "first line\nmatch line\nlast line")
  out = PiTools.grep("match", path: f, cwd: dir) |> PiTools.text()
  A.has!(out, "example.txt:2: match line", "output")
end)

PortTest.run("grep: respects global limit and includes context", fn dir ->
  content = ["before", "match one", "after", "middle", "match two", "after two"] |> Enum.join("\n")
  f = PortTest.tmp_file!(dir, "context.txt", content)
  out = PiTools.grep("match", path: f, cwd: dir, limit: 1, context: 1) |> PiTools.text()
  A.has!(out, "context.txt-1- before", "ctx1")
  A.has!(out, "context.txt:2: match one", "match")
  A.has!(out, "context.txt-3- after", "ctx2")
  A.has!(out, "[1 matches limit reached. Use limit=2 for more, or refine pattern]", "notice")
  A.hasnt!(out, "match two", "no second")
end)

PortTest.run("grep: flag-like patterns treated as search text", fn dir ->
  marker = Path.join(dir, "grep-injection-marker")
  payload = Path.join(dir, "payload.sh")
  File.write!(payload, "#!/bin/sh\necho executed > #{marker}\ncat \"$1\"\n")
  File.chmod!(payload, 0o755)
  PortTest.tmp_file!(dir, "target.txt", "target\n")
  r = PiTools.grep("--pre=#{payload}", cwd: dir)
  A.has!(PiTools.text(r), "No matches found", "output")
  A.truthy!(not File.exists?(marker), "no injection")
end)

PortTest.run("grep: 500-char line truncation", fn dir ->
  line = "match " <> String.duplicate("x", 600)
  PortTest.tmp_file!(dir, "long.txt", line <> "\n")
  out = PiTools.grep("match", cwd: dir) |> PiTools.text()
  A.has!(out, "... [truncated]", "truncated marker")
end)

# ============ find tool ============

PortTest.run("find: includes hidden non-gitignored files", fn dir ->
  PortTest.tmp_file!(dir, ".secret/hidden.txt", "hidden")
  PortTest.tmp_file!(dir, "visible.txt", "visible")
  out = PiTools.find("**/*.txt", cwd: dir) |> PiTools.text()
  lines = out |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  A.truthy!(Enum.member?(lines, "visible.txt"), "visible")
  A.truthy!(Enum.member?(lines, ".secret/hidden.txt"), "hidden")
end)

PortTest.run("find: respects .gitignore", fn dir ->
  {:ok, _} = System.cmd("git", ["init", "-q"], cd: dir) |> then(fn {_o, _c} -> {:ok, nil} end)
  PortTest.tmp_file!(dir, ".gitignore", "ignored.txt\n")
  PortTest.tmp_file!(dir, "ignored.txt", "ignored")
  PortTest.tmp_file!(dir, "kept.txt", "kept")
  out = PiTools.find("**/*.txt", cwd: dir) |> PiTools.text()
  A.has!(out, "kept.txt", "kept")
  A.hasnt!(out, "ignored.txt", "ignored")
end)

PortTest.run("find: glob parse errors surfaced", fn dir ->
  r = PiTools.find("[", cwd: dir)
  A.truthy!(r.is_error == true, "err")
  A.match!(PiTools.text(r), ~r/error parsing glob|fd exited with code 1|fd error|glob/i, "msg")
end)

PortTest.run("find: flag-like patterns treated as search text", fn dir ->
  PortTest.tmp_file!(dir, "a.txt", "")
  r = PiTools.find("--help", cwd: dir)
  A.has!(PiTools.text(r), "No files found matching pattern", "output")
end)

# ============ ls tool ============

PortTest.run("ls: lists dotfiles and directories", fn dir ->
  PortTest.tmp_file!(dir, ".hidden-file", "secret")
  File.mkdir_p!(Path.join(dir, ".hidden-dir"))
  out = PiTools.ls(cwd: dir) |> PiTools.text()
  A.has!(out, ".hidden-file", "dotfile")
  A.has!(out, ".hidden-dir/", "dotdir")
end)

# ============ path / cwd resolution ============

PortTest.run("path: read resolves relative to cwd", fn dir ->
  PortTest.tmp_file!(dir, "rel.txt", "hello from cwd")
  A.has!(PiTools.read("rel.txt", cwd: dir) |> PiTools.text(), "hello from cwd", "content")
end)

PortTest.run("path: write resolves relative to cwd", fn dir ->
  PiTools.write("w.txt", "written", cwd: dir)
  A.eq!(File.read!(Path.join(dir, "w.txt")), "written", "content")
end)

PortTest.run("path: grep resolves relative to cwd", fn dir ->
  PortTest.tmp_file!(dir, "g.txt", "match in cwd")
  A.has!(PiTools.grep("match", cwd: dir) |> PiTools.text(), "g.txt", "output")
end)

# ============ truncate internals ============

PortTest.run("truncate_head: lines limit", fn _dir ->
  c = Enum.map_join(1..10, "\n", &Integer.to_string/1)
  th = PiTools.truncate_head(c, max_lines: 3)
  A.truthy!(th.truncated, "truncated")
  A.eq!(th.truncated_by, "lines", "by")
  A.eq!(th.content, "1\n2\n3", "content")
end)

PortTest.run("truncate_tail: lines limit", fn _dir ->
  c = Enum.map_join(1..10, "\n", &Integer.to_string/1)
  tt = PiTools.truncate_tail(c, max_lines: 3)
  A.eq!(tt.content, "8\n9\n10", "content")
end)

PortTest.run("truncate_head: first line exceeds byte limit", fn _dir ->
  th = PiTools.truncate_head(String.duplicate("z", 200), max_bytes: 100)
  A.truthy!(th.first_line_exceeds_limit, "flag")
  A.eq!(th.content, "", "empty content")
end)
# ============ limits the user flagged as untested ============

PortTest.run("bash: truncated output points at full output file", fn dir ->
  r = PiTools.bash("seq 3000", cwd: dir)
  out = PiTools.text(r)
  A.match!(out, ~r/\[Showing lines \d+-\d+ of \d+\. Full output: /, "notice")
  A.hasnt!(out, "Full output: undefined", "no undefined")
  p = r.details.full_output_path
  A.truthy!(p != nil, "path")
  A.truthy!(File.exists?(p), "file exists")
  full = File.read!(p)
  A.has!(full, "1\n2\n3", "start")
  A.has!(full, "2998\n2999\n3000", "end")
end)

PortTest.run("bash: 50KB byte limit truncates even under 2000 lines", fn dir ->
  # 40 lines of ~2000 bytes = ~80KB, well under 2000 lines.
  r = PiTools.bash("for i in $(seq 1 40); do printf '%s' \"$(head -c 2000 /dev/zero | tr '\\0' 'a')\"; echo; done", cwd: dir)
  t = r.details.truncation
  A.truthy!(t.truncated, "truncated")
  A.eq!(t.truncated_by, "bytes", "by")
  A.eq!(t.max_bytes, 50 * 1024, "max bytes")
end)

PortTest.run("grep: default match limit is 100", fn dir ->
  PortTest.tmp_file!(dir, "many.txt", Enum.map_join(1..250, "\n", &"match #{&1}"))
  r = PiTools.grep("match", cwd: dir)
  A.eq!(r.details.match_limit_reached, 100, "limit")
  A.has!(PiTools.text(r), "[100 matches limit reached. Use limit=200 for more, or refine pattern]", "notice")
end)

PortTest.run("grep: default limit of 100 is not exceeded in output", fn dir ->
  PortTest.tmp_file!(dir, "many.txt", Enum.map_join(1..250, "\n", &"match #{&1}"))
  r = PiTools.grep("match", cwd: dir)
  lines = PiTools.text(r) |> String.split("\n") |> Enum.filter(&String.contains?(&1, "match "))
  A.eq!(length(lines), 100, "100 matches")
end)

PortTest.run("grep: default line truncation is 500 chars", fn dir ->
  PortTest.tmp_file!(dir, "long.txt", "match " <> String.duplicate("x", 800) <> "\n")
  r = PiTools.grep("match", cwd: dir)
  A.truthy!(r.details.lines_truncated, "flag")
  out = PiTools.text(r)
  A.has!(out, "... [truncated]", "marker")
  # the match line content before the suffix should be 500 chars
  line = out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "long.txt:1:"))
  prefix = "long.txt:1: "
  content = String.replace_prefix(line, prefix, "")
  content = String.replace_suffix(content, "... [truncated]", "")
  A.eq!(String.length(content), 500, "500 chars")
  A.has!(out, "[Some lines truncated to 500 chars. Use read tool to see full lines]", "notice")
end)

PortTest.run("find: default limit is 1000", fn dir ->
  for i <- 1..1100, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
  r = PiTools.find("*.txt", cwd: dir)
  A.eq!(r.details.result_limit_reached, 1000, "limit")
  A.has!(PiTools.text(r), "[1000 results limit reached. Use limit=2000 for more, or refine pattern]", "notice")
end)

PortTest.run("find: explicit limit respected", fn dir ->
  for i <- 1..5, do: File.write!(Path.join(dir, "g#{i}.txt"), "")
  r = PiTools.find("*.txt", cwd: dir, limit: 2)
  A.eq!(r.details.result_limit_reached, 2, "limit")
  A.has!(PiTools.text(r), "[2 results limit reached. Use limit=4 for more, or refine pattern]", "notice")
end)

PortTest.run("ls: default limit is 500", fn dir ->
  for i <- 1..510, do: File.write!(Path.join(dir, "f#{i}.txt"), "")
  r = PiTools.ls(cwd: dir)
  A.eq!(r.details.entry_limit_reached, 500, "limit")
  A.has!(PiTools.text(r), "[500 entries limit reached. Use limit=1000 for more]", "notice")
end)

PortTest.run("ls: explicit limit respected", fn dir ->
  for n <- ~w(a.txt b.txt c.txt), do: File.write!(Path.join(dir, n), "")
  r = PiTools.ls(cwd: dir, limit: 1)
  A.eq!(r.details.entry_limit_reached, 1, "limit")
  A.has!(PiTools.text(r), "[1 entries limit reached. Use limit=2 for more]", "notice")
end)

PortTest.run("read: 50KB byte limit message format", fn dir ->
  lines = Enum.map(1..500, fn i -> "Line #{i}: " <> String.duplicate("x", 200) end)
  f = PortTest.tmp_file!(dir, "b.txt", Enum.join(lines, "\n"))
  r = PiTools.read(f, cwd: dir)
  t = r.details.truncation
  A.eq!(t.truncated_by, "bytes", "by")
  A.eq!(t.max_bytes, 50 * 1024, "max")
  A.match!(PiTools.text(r), ~r/\(50\.0KB limit\)\. Use offset=\d+ to continue\./, "notice")
end)

# ============ image detection (magic bytes, per mime.ts) ============

PortTest.run("read: detects image MIME from file magic, not extension", fn dir ->
  png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="
  png = Base.decode64!(png_b64)
  f = PortTest.tmp_file!(dir, "image.txt", png)
  r = PiTools.read(f, cwd: dir)
  A.has!(PiTools.text(r), "Read image file [image/png]", "text")
  A.eq!(r.details.mime, "image/png", "mime")
end)

PortTest.run("read: image-extension with non-image content stays text", fn dir ->
  f = PortTest.tmp_file!(dir, "not-an-image.png", "definitely not a png")
  r = PiTools.read(f, cwd: dir)
  A.has!(PiTools.text(r), "definitely not a png", "content")
  A.truthy!(r.details == nil, "no image details")
end)

PortTest.run("detect_image_mime: jpeg and jpeg2000", fn _dir ->
  A.eq!(PiTools.detect_image_mime(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>), "image/jpeg", "jpeg")
  A.eq!(PiTools.detect_image_mime(<<0xFF, 0xD8, 0xFF, 0xF7, 0, 0>>), nil, "jp2")
end)

PortTest.run("detect_image_mime: gif and webp", fn _dir ->
  A.eq!(PiTools.detect_image_mime("GIF89a....."), "image/gif", "gif")
  A.eq!(PiTools.detect_image_mime("RIFF1234WEBPVP8 "), "image/webp", "webp")
end)

PortTest.run("detect_image_mime: bmp from magic", fn _dir ->
  repl = fn bin, off, r ->
    n = byte_size(r)
    binary_part(bin, 0, off) <> r <> binary_part(bin, off + n, byte_size(bin) - off - n)
  end

  bmp =
    (for _ <- 1..58, into: <<>>, do: <<0>>)
    |> then(&repl.(&1, 0, "BM"))
    |> then(&repl.(&1, 2, <<58::little-32>>))
    |> then(&repl.(&1, 10, <<54::little-32>>))
    |> then(&repl.(&1, 14, <<40::little-32>>))
    |> then(&repl.(&1, 18, <<1::little-32>>))
    |> then(&repl.(&1, 22, <<1::little-32>>))
    |> then(&repl.(&1, 26, <<1::little-16>>))
    |> then(&repl.(&1, 28, <<24::little-16>>))
    |> then(&repl.(&1, 30, <<0::little-32>>))
    |> then(&repl.(&1, 34, <<4::little-32>>))

  A.eq!(PiTools.detect_image_mime(bmp), "image/bmp", "bmp")
end)

# ============ path utils (port of path-utils.test.ts) ============

PortTest.run("path: expand ~ to home", fn _dir ->
  A.hasnt!(PiTools.normalize_path("~"), "~", "no tilde")
end)

PortTest.run("path: expand ~/path", fn _dir ->
  A.hasnt!(PiTools.normalize_path("~/Documents/file.txt"), "~/", "no tilde")
end)

PortTest.run("path: tilde-prefixed filenames stay literal", fn _dir ->
  A.eq!(PiTools.normalize_path("~draft.md"), "~draft.md", "tilde name")
  A.eq!(PiTools.normalize_path("@~draft.md", strip_at_prefix: true), "~draft.md", "at tilde name")
end)

PortTest.run("path: normalize unicode spaces", fn _dir ->
  A.eq!(PiTools.normalize_path("file\u00A0name.txt", normalize_unicode_spaces: true), "file name.txt", "nbsp")
end)

PortTest.run("path: resolveToCwd absolute as-is", fn _dir ->
  abs = Path.join([System.tmp_dir!(), "absolute", "path", "file.txt"])
  A.eq!(PiTools.resolve_to_cwd(abs, "/some/cwd"), Path.expand(abs), "absolute")
end)

PortTest.run("path: resolveToCwd relative against cwd", fn _dir ->
  A.eq!(PiTools.resolve_to_cwd("relative/file.txt", "/some/cwd"), "/some/cwd/relative/file.txt", "relative")
end)

PortTest.run("path: resolveToCwd tilde filename against cwd", fn _dir ->
  cwd = Path.join(System.tmp_dir!(), "pi-path-cwd")
  A.eq!(PiTools.resolve_to_cwd("~draft.md", cwd), Path.join(cwd, "~draft.md"), "tilde")
  A.eq!(PiTools.resolve_to_cwd("@~draft.md", cwd), Path.join(cwd, "~draft.md"), "at tilde")
end)

PortTest.run("path: resolveReadPath existing file", fn dir ->
  f = PortTest.tmp_file!(dir, "test-file.txt", "content")
  A.eq!(PiTools.resolve_read_path("test-file.txt", dir), f, "existing")
end)

PortTest.run("path: resolveReadPath curly quotes", fn dir ->
  curly = Path.join(dir, "Capture d\u2019cran.txt")
  File.write!(curly, "content")
  A.eq!(PiTools.resolve_read_path("Capture d'cran.txt", dir), curly, "curly")
end)

PortTest.run("path: resolveReadPath NFC/NFD accented name", fn dir ->
  nfd = Path.join(dir, "file\u0065\u0301.txt")
  File.write!(nfd, "content")
  result = PiTools.resolve_read_path("file\u00e9.txt", dir)
  A.has!(result, dir, "dir")
  A.match!(result, ~r/file.+\.txt$/, "name")
end)

PortTest.run("path: resolveReadPath macOS AM/PM narrow no-break space", fn dir ->
  macos = Path.join(dir, "Screenshot 2024-01-01 at 10.00.00\u202FAM.png")
  File.write!(macos, "content")
  A.eq!(PiTools.resolve_read_path("Screenshot 2024-01-01 at 10.00.00 AM.png", dir), macos, "ampm")
end)


# ============ summary ============
IO.puts("")
IO.puts("Failures: #{PortTest.failures()}")
if PortTest.failures() > 0, do: System.halt(1)
