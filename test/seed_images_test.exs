defmodule SeedImagesTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "rigel-images-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp png(w \\ 1, h \\ 1),
    do:
      <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, 8, 2, 0, 0, 0, 0::32,
        0::32>>

  test "immutable refs contain no bytes and preserve originals", %{root: root} do
    bytes = png()
    path = Path.join(root, "wrong.jpg")
    File.write!(path, bytes)
    assert {:ok, ref} = SeedImages.ingest(path, root: root)
    assert ref["mime"] == "image/png"
    File.write!(path, "changed")
    assert {:ok, ^bytes, "image/png"} = SeedImages.load(ref)
    assert {:ok, ^ref} = SeedImages.ingest_bytes(bytes, root: root)
    assert byte_size(Jason.encode!(ref)) < 500
    File.write!(ref["path"], "changed")
    assert {:error, _} = SeedImages.load(ref)
    assert {:error, _} = SeedImages.ingest_bytes(bytes, root: root)
  end

  test "types, file size and dimensions checked before storage", %{root: root} do
    for bytes <- ["", "not an image", png(0), png(2001), :binary.copy("a", 3_750_001)] do
      assert {:error, error} = SeedImages.ingest_bytes(bytes, root: root)
      assert byte_size(error) < 200
    end

    assert File.ls!(root) == []
    assert {:error, _} = SeedImages.ingest(Path.join(root, "missing"))
  end

  test "JPEG GIF and WebP dimension sniffing", %{root: root} do
    images = [
      {<<255, 216, 255, 224, 4::16, 0, 0, 255, 192, 7::16, 8, 2::16, 3::16>>, "image/jpeg"},
      {<<"GIF89a", 3::little-16, 2::little-16, 0, 0, 0>>, "image/gif"},
      {<<"RIFF", 22::little-32, "WEBPVP8X", 10::little-32, 0, 0::24, 2::little-24, 1::little-24>>,
       "image/webp"}
    ]

    for {bytes, mime} <- images do
      assert {:ok, ref} = SeedImages.ingest_bytes(bytes, root: root)
      assert ref["mime"] == mime
      assert ref["width"] == 3
      assert ref["height"] == 2
    end
  end

  test "both wires hydrate only at request boundary", %{root: root} do
    assert {:ok, ref} = SeedImages.ingest_bytes(png(), root: root)

    messages = [
      %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "Look"}, SeedImages.part(ref)]
      }
    ]

    assert {:ok, [router]} = SeedImages.hydrate(messages, :openrouter, ["text", "image"])

    assert [_, %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> _}}] =
             router["content"]

    assert {:ok, [codex]} = SeedImages.hydrate(messages, :chatgpt, ["image"])

    assert [_, %{"type" => "input_image", "image_url" => "data:image/png;base64," <> _}] =
             codex["content"]

    assert get_in(hd(messages), ["content", Access.at(1), "image"]) == ref
    assert SeedImages.tokens(ref) == 4800

    for support <- [nil, [], ["text"]] do
      assert {:ok, [unsupported]} = SeedImages.hydrate(messages, :openrouter, support)
      assert [_, %{"type" => "text", "text" => text}] = unsupported["content"]
      assert text =~ "does not support"
      assert SeedImages.orientation(support) =~ "cannot see"
    end

    assert SeedImages.orientation(["image"]) =~ "can see"
    tool = Map.put(hd(messages), "role", "tool")
    assert {:error, _} = SeedImages.hydrate([tool], :openrouter, ["image"])
    File.rm!(ref["path"])
    assert {:error, _} = SeedImages.hydrate(messages, :chatgpt, ["image"])
  end

  test "view queues metadata, never encoded data", %{root: root} do
    path = Path.join(root, "image.png")
    File.write!(path, png())
    assert {:ok, ref} = SeedImages.view(path, root: root, target: self())
    assert_receive {:seed_image, ^ref}
  end
end
