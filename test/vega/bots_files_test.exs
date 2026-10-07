defmodule Vega.BotsFilesTest do
  use ExUnit.Case, async: true

  test "files import immutable bytes and never trust arbitrary ids or supplied metadata" do
    root = Path.join(System.tmp_dir!(), "bots-files-" <> Vega.Store.id())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "unsafe\".html")
    File.write!(path, "<script>alert(1)</script>")
    assert {:ok, ref} = Vega.Bots.Files.import(path, root)
    assert ref["filename"] == "unsafe_.html"
    assert {:ok, "<script>alert(1)</script>", ^ref} = Vega.Bots.Files.fetch(ref["id"], root)
    File.write!(path, "new version")
    assert {:ok, other} = Vega.Bots.Files.import(path, root)
    refute other["id"] == ref["id"]
    assert {:error, _} = Vega.Bots.Files.fetch("../../etc/passwd", root)
    assert {:error, _} = Vega.Bots.Files.validate([%{"path" => path}], root)

    assert {:ok, [^ref]} =
             Vega.Bots.Files.validate([Map.put(ref, "filename", "injected\r\nheader")], root)

    File.write!(Path.join([root, "bots", "files", ref["id"]]), "corrupt")
    assert {:error, _} = Vega.Bots.Files.fetch(ref["id"], root)
  end
end
