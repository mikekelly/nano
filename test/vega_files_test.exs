defmodule Vega.FilesTest do
  use ExUnit.Case, async: true
  alias Vega.Files, as: F

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vega-files-#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, p: Path.join(dir, "file")}
  end

  test "bounded pages preserve complete lines and exact continuation", c do
    File.write!(c.p, "aa\nbb\ncc\n")
    assert {:ok, %{text: "aa\n", next: 2, truncated: true}} = F.read(c.p, max_bytes: 4)
    assert {:ok, %{text: "bb\ncc\n", next: nil, total: 3}} = F.read(c.p, offset: 2)
    assert {:error, {:offset_past_end, 3}} = F.read(c.p, offset: 5)
    File.write!(c.p, String.duplicate("x", 100_000))
    assert {:error, {:line_exceeds_max_bytes, 1}} = F.read(c.p, max_bytes: 10)
  end

  test "exact edits unique even for overlapping occurrences and atomic multiple replacements",
       c do
    File.write!(c.p, "aaaa")
    assert {:error, _} = F.edit(c.p, "aaa", "b")
    File.write!(c.p, "alpha\r\nbeta\r\n")
    assert :ok = F.edit(c.p, [{"alpha", "A"}, {"beta", "B"}])
    assert File.read!(c.p) == "A\r\nB\r\n"
    assert {:error, :overlapping_replacements} = F.edit(c.p, [{"A\r\nB", "x"}, {"B", "y"}])
    assert File.read!(c.p) == "A\r\nB\r\n"
  end

  test "shell bounded true tail, full output spill, timeout and cwd/env", c do
    result =
      F.sh("seq 1 10000; printf END", cwd: c.dir, output_dir: c.dir, max_bytes: 100, limit: 3)

    assert result.status == 0
    assert result.truncated
    assert result.output == "9999\n10000\nEND"
    assert File.stat!(result.path).size == result.bytes
    assert byte_size(result.output) <= 100
    result = F.sh("printf before; sleep 3; printf after", timeout: 30, output_dir: c.dir)
    assert result.timed_out
    assert result.output == "before"

    assert F.sh("printf \"$HELLO\"", cwd: c.dir, env: [{"HELLO", "world"}], output_dir: c.dir).output ==
             "world"
  end
end
