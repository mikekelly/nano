defmodule SeedToolsTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "seed-tools-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "pages announce the actual next line, not the requested limit", %{dir: dir} do
    path = Path.join(dir, "file")

    File.write!(
      path,
      String.duplicate("x", 9000) <> "\n" <> "second\n" <> String.duplicate("y", 9000) <> "\n"
    )

    assert {:ok, text} = SeedTools.read(path)
    assert text =~ "offset=3"
    assert {:ok, next} = SeedTools.read(path, offset: 3)
    assert next =~ "EOF"
    assert {:error, _} = SeedTools.read(path, offset: 9)
    assert {:error, _} = SeedTools.read(path, offset: 0)
  end

  test "oversized lines and ambiguous edits are explicit errors", %{dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, String.duplicate("a", 16001))
    assert {:error, _} = SeedTools.read(path)
    assert {:error, _} = SeedTools.edit(path, "", "b")
    assert {:error, _} = SeedTools.edit(path, "a", "b")
  end

  test "shell preserves complete output but bounds the returned tail" do
    result = SeedTools.sh("printf beginning; head -c 20000 /dev/zero; printf ending")
    on_exit(fn -> File.rm_rf!(Path.dirname(result.full_output)) end)
    assert result.status == 0
    assert result.truncated
    assert byte_size(result.output) == 16000
    assert String.ends_with?(result.output, "ending")
    assert File.read!(result.full_output) |> String.starts_with?("beginning")
  end

  test "shell timeout retains output" do
    result = SeedTools.sh("printf before; sleep 10", timeout: 50)
    on_exit(fn -> File.rm_rf!(Path.dirname(result.full_output)) end)
    assert result.timed_out
    assert result.output == "before"
    assert {:error, _} = SeedTools.sh("true", timeout: 0)
  end
end
