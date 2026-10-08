defmodule Seedling.ImagesTest do
  use ExUnit.Case, async: true
  alias Seedling.Images
  alias Seedling.ImageFixture, as: Fixture

  test "immutable snapshot, detected type, hash, and canonical references" do
    bytes = Fixture.png()

    path =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "picture-#{System.unique_integer([:positive])}.jpg"
      )

    File.write!(path, bytes)
    assert {:ok, ref} = Images.view(path)
    assert ref["mime_type"] == "image/png"
    assert ref["width"] == 1 and ref["height"] == 1
    assert ref["id"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    refute Map.has_key?(ref, "data")
    refute Map.has_key?(ref, "path")
    File.write!(path, "changed")
    assert {:ok, ^ref, ^bytes} = Images.fetch(ref)
    assert {:ok, ^ref} = Images.store(bytes)
    assert {:ok, [^ref]} = Images.validate_refs([Map.put(ref, "mime_type", "image/jpeg")])
    assert {:ok, url} = Images.data_url(ref)
    assert url == "data:image/png;base64," <> Base.encode64(bytes)
  end

  test "bounds, unsupported bytes, malformed containers, and path traversal are refused" do
    assert {:error, _} = Images.store("not a picture.png")
    assert {:error, _} = Images.store("<svg></svg>")
    assert {:error, _} = Images.store(:binary.copy(<<0>>, Images.limits().bytes + 1))
    assert {:error, reason} = Images.store(Fixture.png(2001))
    assert reason =~ "PNG"
    assert {:error, _} = Images.store(Fixture.png(0))
    png = Fixture.png()
    assert {:error, _} = Images.store(binary_part(png, 0, byte_size(png) - 1))
    assert {:error, _} = Images.store(:binary.replace(png, "IDAT", "iDAT"))
    assert {:error, _} = Images.fetch("../secrets")
    assert {:error, _} = Images.fetch(String.duplicate("f", 64))
    assert {:error, _} = Images.validate_refs("anything")
    assert {:error, _} = Images.view(1)
  end

  test "concurrent uploads publish one complete object" do
    # Different valid bytes from the other tests; published object remains shared safely.
    bytes = Fixture.png(2, 2)

    results =
      1..12
      |> Task.async_stream(fn _ -> Images.store(bytes) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, ref}] = Enum.uniq(results)
    assert {:ok, ^ref, ^bytes} = Images.fetch(ref)
  end

  test "collect handles nested eval values and improper lists without unbounded traversal" do
    {:ok, ref} = Images.store(Fixture.png())
    assert Images.collect({:ok, ref}) == [ref]
    assert Images.collect(%{other: {ref, [ref | :tail]}}) == [ref]
    {:ok, other} = Images.store(Fixture.png(2, 1))
    assert Images.collect(List.duplicate(ref, 150) ++ [other]) == [ref, other]
    assert Images.collect(Enum.reduce(1..20, ref, fn _, acc -> [acc] end)) == []
  end

  test "unsupported model notices and conservative image accounting" do
    {:ok, ref} = Images.store(Fixture.png())
    assert {[ref], ""} == Images.prepare([ref], ["text", "image"])
    assert {[], notice} = Images.prepare([ref], ["text"])
    assert notice =~ "cannot see images"
    assert Images.prompt(["text"]) =~ "do not guess"
    assert Images.prompt(["image"]) =~ "Seedling.Images.view"
    messages = [%{"role" => "user", "content" => "hi", "images" => [ref]}]
    assert Images.estimate_bytes(messages) == byte_size(Jason.encode!(messages)) + 9600
    assert {[], invalid} = Images.prepare(["missing"], ["image"])
    assert invalid =~ "invalid, missing or corrupt"
  end

  test "modified immutable objects fail closed, and cannot be overwritten by re-upload" do
    bytes = Fixture.png(5, 7)
    {:ok, ref} = Images.store(bytes)
    path = Path.join(Images.dir(), ref["id"])
    File.chmod!(path, 0o600)
    File.write!(path, "modified")

    on_exit(fn ->
      File.write!(path, bytes)
      File.chmod!(path, 0o444)
    end)

    assert {:error, _} = Images.fetch(ref)
    assert {:error, _} = Images.data_url(ref)
    assert {:error, _} = Images.store(bytes)
  end

  test "symlinks cannot masquerade as immutable images" do
    bytes = Fixture.png(11, 12)
    id = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    path = Path.join(Images.dir(), id)
    source = path <> ".source"
    File.mkdir_p!(Images.dir())
    File.write!(source, bytes)
    File.ln_s!(source, path)

    on_exit(fn ->
      File.rm(path)
      File.rm(source)
    end)

    assert {:error, _} = Images.fetch(id)
    assert {:error, _} = Images.store(bytes)
  end

  test "PNG compressed data and scanline sizes are validated, including decompression bombs" do
    png = Fixture.png()
    <<header::binary-size(33), _::binary>> = png
    # Header is a valid 1x1 RGB image, but the payload is one megabyte rather than 4 bytes.
    data = :zlib.compress(:binary.copy(<<0>>, 1_000_000))
    idat = <<byte_size(data)::32, "IDAT", data::binary, :erlang.crc32("IDAT" <> data)::32>>
    iend = <<0::32, "IEND", :erlang.crc32("IEND")::32>>
    assert {:error, _} = Images.store(header <> idat <> iend)
  end

  test "interlaced and palette PNG plus progressive JPEG fixtures" do
    for name <- ["interlaced.png", "palette.png", "progressive.jpg"] do
      bytes = File.read!(Path.join([__DIR__, "fixtures", name]))
      assert {:ok, ref} = Images.store(bytes)
      assert ref["width"] == 3 and ref["height"] == 3
    end
  end

  test "indexed PNG needs a palette and unknown critical chunks are refused" do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    header =
      <<137, 80, 78, 71, 13, 10, 26, 10>> <> chunk.("IHDR", <<1::32, 1::32, 8, 3, 0, 0, 0>>)

    body = chunk.("IDAT", :zlib.compress(<<0, 0>>)) <> chunk.("IEND", "")
    assert {:error, _} = Images.store(header <> body)
    palette = chunk.("PLTE", <<255, 0, 0>>)
    assert {:ok, ref} = Images.store(header <> palette <> body)
    assert ref["mime_type"] == "image/png"
    assert {:error, _} = Images.store(header <> palette <> chunk.("BADX", "") <> body)
  end

  test "JPEG type and dimensions from SOF rather than filename" do
    # Tiny real JPEG encoded fixture, generated by the image decoder in the build environment.
    bytes = File.read!(Path.join(__DIR__, "fixtures/pixel.jpg"))
    assert {:ok, ref} = Images.store(bytes)
    assert ref["mime_type"] == "image/jpeg"
    assert ref["width"] == 1 and ref["height"] == 1
    assert {:error, _} = Images.store(binary_part(bytes, 0, byte_size(bytes) - 2))
  end
end
