defmodule Images.Format do
  @moduledoc false
  import Bitwise

  def identify(<<137, "PNG\r\n", 26, "\n", rest::binary>>) do
    png(rest, nil, false)
  end

  def identify(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest, nil)

  def identify(
        <<"GIF", version::binary-size(3), w::little-16, h::little-16, flags, _, _, rest::binary>>
      )
      when version in ["87a", "89a"] do
    with {:ok, rest} <- skip_table(rest, flags),
         :ok <- gif(rest, w, h, 0) do
      {:ok, "image/gif", w, h}
    end
  end

  def identify(<<"RIFF", size::little-32, "WEBP", rest::binary>>)
      when size == byte_size(rest) + 4 do
    webp(rest, nil, nil)
  end

  def identify(_), do: invalid()

  defp invalid,
    do: {:error, "unsupported or malformed image; use PNG, JPEG, static GIF or static WebP"}

  defp animated, do: {:error, "animated images are not supported; use a static frame"}

  defp png(
         <<size::32, type::binary-size(4), data::binary-size(size), crc::32, rest::binary>>,
         dims,
         pixels
       ) do
    if :erlang.crc32(type <> data) != crc do
      invalid()
    else
      case {type, data, dims, pixels, rest} do
        {"IHDR", <<w::32, h::32, depth, color, 0, 0, interlace>>, nil, false, _}
        when interlace in [0, 1] ->
          if valid_png_depth?(depth, color), do: png(rest, {w, h}, false), else: invalid()

        {"IHDR", _, _, _, _} ->
          invalid()

        {"acTL", _, _, _, _} ->
          animated()

        {"IDAT", _, {_, _}, _, _} ->
          png(rest, dims, true)

        {"IEND", "", {w, h}, true, ""} ->
          {:ok, "image/png", w, h}

        {_, _, nil, _, _} ->
          invalid()

        {"IEND", _, _, _, _} ->
          invalid()

        _ ->
          png(rest, dims, pixels)
      end
    end
  end

  defp png(_, _, _), do: invalid()
  defp valid_png_depth?(depth, 0), do: depth in [1, 2, 4, 8, 16]
  defp valid_png_depth?(depth, 3), do: depth in [1, 2, 4, 8]
  defp valid_png_depth?(depth, c) when c in [2, 4, 6], do: depth in [8, 16]
  defp valid_png_depth?(_, _), do: false

  defp jpeg(<<0xFF, 0xFF, rest::binary>>, dims), do: jpeg(<<0xFF, rest::binary>>, dims)

  defp jpeg(<<0xFF, 0xDA, len::16, rest::binary>>, {w, h}) when len >= 2 do
    case rest do
      <<_header::binary-size(len - 2), scan::binary>> when byte_size(scan) >= 2 ->
        if binary_part(scan, byte_size(scan) - 2, 2) == <<0xFF, 0xD9>>,
          do: {:ok, "image/jpeg", w, h},
          else: invalid()

      _ ->
        invalid()
    end
  end

  defp jpeg(<<0xFF, marker, len::16, rest::binary>>, dims) when len >= 2 do
    case rest do
      <<segment::binary-size(len - 2), tail::binary>> ->
        if marker in [0xC0, 0xC1, 0xC2] do
          case segment do
            <<8, h::16, w::16, components, data::binary>>
            when components in [1, 3, 4] and byte_size(data) == components * 3 ->
              if dims in [nil, {w, h}], do: jpeg(tail, {w, h}), else: invalid()

            _ ->
              invalid()
          end
        else
          if marker in 0xE0..0xEF or marker in [0xDB, 0xC4, 0xDD, 0xFE],
            do: jpeg(tail, dims),
            else: invalid()
        end

      _ ->
        invalid()
    end
  end

  defp jpeg(_, _), do: invalid()

  defp skip_table(rest, flags) do
    size = if (flags &&& 128) != 0, do: 3 * (1 <<< ((flags &&& 7) + 1)), else: 0

    case rest do
      <<_::binary-size(size), tail::binary>> -> {:ok, tail}
      _ -> invalid()
    end
  end

  defp gif(<<0x3B>>, _, _, 1), do: :ok

  defp gif(<<0x21, label, rest::binary>>, w, h, count) when label in [0xF9, 0xFE, 0xFF] do
    with {:ok, tail} <- subblocks(rest), do: gif(tail, w, h, count)
  end

  defp gif(<<0x2C, _::binary>>, _, _, count) when count > 0, do: animated()

  defp gif(
         <<0x2C, x::little-16, y::little-16, iw::little-16, ih::little-16, flags, rest::binary>>,
         w,
         h,
         0
       )
       when iw > 0 and ih > 0 and x + iw <= w and y + ih <= h do
    with {:ok, <<code_size, blocks::binary>>} when code_size in 2..8 <- skip_table(rest, flags),
         {:ok, tail} <- subblocks(blocks) do
      gif(tail, w, h, 1)
    else
      _ -> invalid()
    end
  end

  defp gif(_, _, _, _), do: invalid()
  defp subblocks(<<0, rest::binary>>), do: {:ok, rest}
  defp subblocks(<<n, _data::binary-size(n), rest::binary>>), do: subblocks(rest)
  defp subblocks(_), do: invalid()

  defp webp("", dims, pixels) when pixels != nil do
    if dims in [nil, pixels] do
      {w, h} = pixels
      {:ok, "image/webp", w, h}
    else
      invalid()
    end
  end

  defp webp(
         <<type::binary-size(4), size::little-32, data::binary-size(size), rest::binary>>,
         dims,
         pixels
       ) do
    padding = rem(size, 2)

    case rest do
      <<_::binary-size(padding), rest::binary>> ->
        case {type, data, pixels} do
          {"ANIM", _, _} ->
            animated()

          {"ANMF", _, _} ->
            animated()

          {"VP8X", <<flags, 0, 0, 0, w::little-24, h::little-24>>, _} ->
            if (flags &&& 2) == 0, do: webp(rest, {w + 1, h + 1}, pixels), else: animated()

          {"VP8 ", <<tag::little-24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>,
           nil}
          when (tag &&& 1) == 0 ->
            webp(rest, dims, {w &&& 0x3FFF, h &&& 0x3FFF})

          {"VP8L", <<0x2F, packed::little-32, _::binary>>, nil} when packed >>> 29 == 0 ->
            webp(rest, dims, {(packed &&& 0x3FFF) + 1, (packed >>> 14 &&& 0x3FFF) + 1})

          {type, _, _} when type in ["ICCP", "ALPH", "EXIF", "XMP "] ->
            webp(rest, dims, pixels)

          _ ->
            invalid()
        end

      _ ->
        invalid()
    end
  end

  defp webp(_, _, _), do: invalid()
end
