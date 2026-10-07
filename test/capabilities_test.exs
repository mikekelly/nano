defmodule Nano.CapabilitiesTest do
  use ExUnit.Case, async: true
  test "index is discoverable and generated notes are deterministic" do
    root = Path.join(System.tmp_dir!(), "nova-index-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    entries = Nano.Capabilities.entries()
    assert Enum.any?(entries, &(&1.module == Nano.Delegation))
    assert Enum.all?(entries, &is_boolean(&1.loaded))
    assert Nano.Capabilities.index() =~ "delegation:"
    path = Path.join(root, "NOTES.md")
    assert :ok = Nano.Capabilities.notes(path)
    assert File.read!(path) =~ Nano.Capabilities.index()
    assert {:error, _} = Nano.Capabilities.notes(Path.join(root, "missing/NOTES.md"))
  end
end
