defmodule Nano.ImagesTest do
  use ExUnit.Case, async: true

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "altair-images-store-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, opts: [store_dir: dir]}
  end

  defp chunk(t, d), do: <<byte_size(d)::32, t::binary, d::binary, :erlang.crc32(t <> d)::32>>

  defp png(w \\ 1, h \\ 1) do
    <<137, "PNG\r\n", 26, 10>> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(<<0, 255, 0, 0>>)) <> chunk("IEND", "")
  end

  test "PNG roundtrip, deduplication, file import and data URL", %{opts: opts} do
    data = png()
    assert {:ok, ref} = Nano.Images.import_bytes(data, opts)
    assert ref.mime == "image/png"
    assert ref.width == 1 and ref.height == 1 and ref.bytes == byte_size(data)
    assert {:ok, ^ref} = Nano.Images.import_bytes(data, opts)
    path = Path.join(opts[:store_dir], "input")
    File.write!(path, data)
    assert {:ok, ^ref} = Nano.Images.import_file(path, opts)
    assert {:ok, ^data} = Nano.Images.read(ref, opts)
    assert {:ok, url} = Nano.Images.data_url(ref, opts)
    assert url == "data:image/png;base64," <> Base.encode64(data)
    assert Nano.Images.token_estimate(ref) == 4800
  end

  test "canonical references and agent look", %{opts: opts} do
    assert {:ok, ref} = Nano.Images.import_bytes(png(), opts)
    assert {:ok, ^ref} = Nano.Images.canonicalize(Map.put(ref, :base64, "unsafe"), opts)
    path = Path.join(opts[:store_dir], "look.png")
    File.write!(path, png())
    assert {:ok, ^ref} = Nano.Images.look(path, self(), opts)
    assert_receive {:"$gen_cast", {:notify, %{text: "Image opened from file", images: [^ref]}}}
  end

  test "GIF JPEG WebP headers", %{opts: opts} do
    gif = Base.decode64!("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")

    jpeg =
      <<255, 216, 255, 192, 0, 11, 8, 0, 1, 0, 1, 1, 1, 17, 0, 255, 218, 0, 8, 1, 1, 0, 0, 63, 0,
        10, 255, 217>>

    payload = <<47, 0::little-32, 0>>
    webp = <<"RIFF", 18::little-32, "WEBPVP8L", 6::little-32, payload::binary>>

    for {bytes, mime} <- [{gif, "image/gif"}, {jpeg, "image/jpeg"}, {webp, "image/webp"}] do
      assert {:ok, ref} = Nano.Images.import_bytes(bytes, opts)
      assert ref.mime == mime
      assert ref.width == 1 and ref.height == 1

      assert {:error, :invalid_image} =
               Nano.Images.import_bytes(binary_part(bytes, 0, byte_size(bytes) - 1), opts)
    end
  end

  test "dimension and encoded-size bounds", %{opts: opts} do
    assert {:ok, _} = Nano.Images.import_bytes(png(2000, 2000), opts)

    for {w, h} <- [{2001, 1}, {1, 2001}, {0, 1}, {1, 0}] do
      assert {:error, :invalid_dimensions} = Nano.Images.import_bytes(png(w, h), opts)
    end

    assert {:error, :image_too_large} =
             Nano.Images.import_bytes(:binary.copy(<<0>>, 3_932_161), opts)

    for _ <- 1..25, do: assert({:ok, _} = Nano.Images.import_bytes(png(2000, 2000), opts))
  end

  test "reject garbage, invalid refs, metadata and corruption without overwrite", %{opts: opts} do
    for data <- ["", "not an image", <<137, "PNG\r\n", 26, 10>>, nil],
        do: assert({:error, :invalid_image} = Nano.Images.import_bytes(data, opts))

    assert {:error, :invalid_ref} = Nano.Images.read(%{image_ref: "../outside"}, opts)
    assert {:error, :invalid_ref} = Nano.Images.read(nil, opts)
    assert {:ok, ref} = Nano.Images.import_bytes(png(), opts)
    assert {:error, :metadata_mismatch} = Nano.Images.data_url(%{ref | mime: "text/html"}, opts)
    path = Path.join(opts[:store_dir], ref.image_ref)
    File.chmod!(path, 0o644)
    File.write!(path, "corrupt")
    assert {:error, :hash_mismatch} = Nano.Images.read(ref, opts)
    assert {:error, :hash_mismatch} = Nano.Images.import_bytes(png(), opts)
    assert File.read!(path) == "corrupt"
  end

  test "concurrent publication is complete and leaves no temporary objects", %{opts: opts} do
    refs =
      1..20
      |> Task.async_stream(fn _ -> Nano.Images.import_bytes(png(), opts) end)
      |> Enum.map(fn {:ok, {:ok, ref}} -> ref end)

    assert length(Enum.uniq(refs)) == 1
    assert {:ok, files} = File.ls(opts[:store_dir])
    assert files == [hd(refs).image_ref]
  end
end
