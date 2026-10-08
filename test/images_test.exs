defmodule ImagesTest do
  use ExUnit.Case, async: false
  alias Nano.ImageFixtures, as: F

  setup do
    old = Application.get_env(:nano, :images_dir)

    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "images-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:nano, :images_dir, dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:nano, :images_dir, old),
        else: Application.delete_env(:nano, :images_dir)

      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "type comes from bytes, copies are immutable and identical bytes deduplicate", %{dir: dir} do
    File.mkdir_p!(dir)
    source = Path.join(dir, "looks-like.txt")
    data = F.png(3, 2)
    File.write!(source, data)
    assert {:ok, ref} = Images.ingest(source)
    assert ref["mime"] == "image/png"
    assert ref["width"] == 3 and ref["height"] == 2
    assert {:ok, ^ref} = Images.ingest_bytes(data)
    File.write!(source, "changed")
    assert {:ok, ^data, "image/png"} = Images.read(ref)
    assert {:ok, ^data, "image/png"} = Images.read(ref["id"])
    assert {:ok, ^ref} = Images.resolve(Map.merge(ref, %{"mime" => "fake", "width" => 1}))
    refute Jason.encode!(ref) =~ Base.encode64(data)
    assert {:ok, %{mode: mode}} = File.stat(Path.join(dir, ref["id"]))
    assert Bitwise.band(mode, 0o222) == 0
  end

  test "concurrent ingest cannot expose partial files or overwrite", %{dir: dir} do
    refs =
      1..20
      |> Task.async_stream(fn _ -> Images.ingest_bytes(F.png()) end, max_concurrency: 20)
      |> Enum.map(fn {:ok, {:ok, ref}} -> ref end)

    assert length(Enum.uniq(refs)) == 1
    assert File.ls!(dir) == [hd(refs)["id"]]
  end

  test "corruption and symlinks are rejected, never silently replaced", %{dir: dir} do
    data = F.png()
    {:ok, ref} = Images.ingest_bytes(data)
    path = Path.join(dir, ref["id"])
    File.chmod!(path, 0o644)
    File.write!(path, "corrupt")
    assert {:error, _} = Images.read(ref)
    assert {:error, _} = Images.ingest_bytes(data)
    File.rm!(path)
    other = Path.join(dir, "other")
    File.write!(other, data)
    File.ln_s!(other, path)
    assert {:error, _} = Images.read(ref)
    assert {:error, _} = Images.read("../../etc/passwd")
    assert {:error, _} = Images.read(%{"id" => 1})
  end

  test "rejects bad types, malformed containers, zero and future-unsafe dimensions, and size" do
    for data <- [
          "not an image",
          "<svg></svg>",
          <<137, "PNG\r\n", 26, "\n">>,
          binary_part(F.png(), 0, 30),
          F.png(0, 1),
          F.png(2001, 1),
          F.png(1, 8001)
        ] do
      assert {:error, _} = Images.ingest_bytes(data)
    end

    assert {:error, error} = Images.ingest_bytes(:binary.copy("x", Images.max_bytes() + 1))
    assert error =~ "5 MB base64"
    assert {:error, _} = Images.ingest_bytes(nil)
    assert {:error, _} = Images.ingest("/nonexistent/deneb-image")
    assert {:ok, _} = Images.ingest_bytes(F.png(2000, 2000))
    <<head::binary-size(30), byte, tail::binary>> = F.png()
    assert {:error, _} = Images.ingest_bytes(head <> <<Bitwise.bxor(byte, 1)>> <> tail)
  end

  test "detects supported static formats and rejects animation" do
    assert {:ok, gif} = Images.ingest_bytes(F.gif())
    assert gif["mime"] == "image/gif"
    assert {:ok, webp} = Images.ingest_bytes(F.webp())
    assert webp["mime"] == "image/webp"
    # JPEG marker parser: SOF0 followed by scan and EOI; dimensions are from SOF, not filename.
    jpeg =
      <<255, 216, 255, 192, 0, 11, 8, 0, 2, 0, 3, 1, 1, 0x11, 0, 255, 218, 0, 8, 1, 1, 0, 0, 63,
        0, 1, 255, 217>>

    assert {:ok, %{"mime" => "image/jpeg", "width" => 3, "height" => 2}} =
             Images.ingest_bytes(jpeg)

    apng =
      binary_part(F.png(), 0, 33) <>
        F.chunk("acTL", <<1::32, 0::32>>) <> binary_part(F.png(), 33, byte_size(F.png()) - 33)

    assert {:error, message} = Images.ingest_bytes(apng)
    assert message =~ "animated"
  end

  test "references traverse arbitrary Erlang terms including improper lists" do
    {:ok, ref} = Images.ingest_bytes(F.png())
    assert Images.references({:ok, [ref | make_ref()]}) == [ref]
    assert Images.references(%{ref: ref}) == [ref]
    assert Images.references([:alias | make_ref()]) == []
  end

  test "view marks all viewed files but never returns image bytes", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "local.png")
    File.write!(path, F.png())
    assert {:ok, ref} = Images.view(path)
    assert Images.take_viewed() == [ref]
    assert Images.take_viewed() == []
    assert Images.references(Images.message("look", [ref])) == [ref]
  end

  test "admission validates metadata and bounds growing contexts, accounting uses image tokens" do
    {:ok, ref} = Images.ingest_bytes(F.png())
    {refs, notices} = Images.admit([ref, ref], 1)
    assert refs == [ref]
    assert hd(notices) =~ "limit"
    {[], [notice]} = Images.admit([%{"type" => "image_ref", "id" => "../bad"}])
    assert notice =~ "unavailable"
    enabled = Images.content("look", [ref], ["text", "image"])
    assert length(Images.references(enabled)) == 1
    assert Images.estimated_bytes(enabled) >= 9600
    assert Images.estimated_bytes(enabled) < 10000
    disabled = Images.content("look", [ref], ["text"])
    assert disabled =~ "cannot see images"
    assert Images.references(disabled) == []
    refute Images.capable?(nil)
    assert Images.prompt(["image"]) =~ "can see"
  end
end
