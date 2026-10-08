defmodule Nano.ImageFixtures do
  @moduledoc false
  def png(w \\ 1, h \\ 1) do
    # A real, RGB, solid red PNG; keep large-boundary fixtures cheap by using tiny IDAT.
    pixels =
      if w * h <= 10000,
        do: :binary.copy(<<0>> <> :binary.copy(<<255, 0, 0>>, w), h),
        else: <<0, 255, 0, 0>>

    <<137, "PNG\r\n", 26, "\n">> <>
      chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(pixels)) <> chunk("IEND", "")
  end

  def chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  def gif, do: Base.decode64!("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
  def webp, do: Base.decode64!("UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")
end
