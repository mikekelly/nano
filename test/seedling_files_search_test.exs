defmodule Seedling.FilesSearchTest do
  use ExUnit.Case, async: true
  alias Seedling.Files

  setup do
    root =
      Path.join(System.tmp_dir!(), "lyra-files-" <> Base.encode16(:crypto.strong_rand_bytes(10)))

    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    File.write!(Path.join(root, ".gitignore"), "ignored/\n")
    File.mkdir_p!(Path.join(root, "ignored"))
    File.write!(Path.join(root, "ignored/hidden.ex"), "needle")
    File.write!(Path.join(root, ".hidden.ex"), "needle\n")
    File.write!(Path.join(root, "visible.ex"), "needle\nneedle\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "find respects gitignore and includes hidden files", %{root: root} do
    assert {:ok, %{paths: paths, truncated: false}} = Files.find(Path.join(root, "**/*.ex"))

    assert Enum.sort(paths) ==
             Enum.sort([Path.join(root, ".hidden.ex"), Path.join(root, "visible.ex")])
  end

  test "grep is globally bounded, literal-safe and ignores git internals", %{root: root} do
    assert {:ok, result} = Files.grep("needle", root, limit: 1)
    assert length(String.split(result.text, "\n", trim: true)) == 1
    assert result.truncated
    assert {:ok, result} = Files.grep("needle", root)
    refute result.text =~ "ignored"
    assert result.text =~ ".hidden.ex"
    assert {:ok, %{status: 1, text: ""}} = Files.grep("--not-an-option", root, literal: true)
    assert {:error, %{status: 2}} = Files.grep("[", root)
  end

  test "byte and long-line caps", %{root: root} do
    File.write!(Path.join(root, "huge.txt"), String.duplicate("needle", 10000))
    assert {:ok, %{text: text, truncated: true}} = Files.grep("needle", root, bytes: 1000)
    assert byte_size(text) <= 1000
  end
end
