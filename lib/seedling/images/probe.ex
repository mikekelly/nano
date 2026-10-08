defmodule Seedling.Images.Probe do
  @moduledoc """
  Byte-level PNG/JPEG identification and dimensions. Filename and client MIME are ignored.
  PNG must have a valid IHDR, nonempty IDAT, IEND, and correct CRC for every chunk.
  JPEG must have a supported SOF, SOS and final EOI. This validates the container, not
  decoded pixels; no shell command, mutable external decoder or new runtime package is used.
  """
  @png <<137, 80, 78, 71, 13, 10, 26, 10>>
  @doc "`{:ok, %{\"mime_type\" => type, \"width\" => w, \"height\" => h}}` or `{:error, text}`."
  def inspect(<<@png, rest::binary>>) do
    case png(rest, nil, []) do
      {:ok, {w, h, _, _, _}} -> metadata("image/png", w, h)
      _ -> {:error, "invalid or truncated PNG"}
    end
  end

  def inspect(<<255, 216, rest::binary>>) do
    case jpeg(rest, nil) do
      {:ok, {w, h}} -> metadata("image/jpeg", w, h)
      _ -> {:error, "invalid or truncated JPEG"}
    end
  end

  def inspect(_), do: {:error, "unsupported image type: only PNG and JPEG bytes are accepted"}
  defp metadata(type, w, h), do: {:ok, %{"mime_type" => type, "width" => w, "height" => h}}

  defp png(
         <<len::32, type::binary-size(4), data::binary-size(len), crc::32, rest::binary>>,
         dimensions,
         idat
       ) do
    if :erlang.crc32(type <> data) == crc do
      case {type, data, dimensions} do
        {"IHDR", <<w::32, h::32, depth, color, 0, 0, interlace>>, nil}
        when w in 1..2000 and h in 1..2000 and depth in [1, 2, 4, 8, 16] and
               color in [0, 2, 3, 4, 6] and interlace in [0, 1] ->
          if valid_depth?(color, depth),
            do: png(rest, {w, h, depth, color, interlace}, idat),
            else: :error

        {"IHDR", _, _} ->
          :error

        {"IDAT", _, {_, _, _, _, _}} ->
          png(rest, dimensions, [data | idat])

        {"IEND", "", {_, _, _, _, _}} when idat != [] and rest == "" ->
          if valid_pixels?(Enum.reverse(idat), dimensions), do: {:ok, dimensions}, else: :error

        {"acTL", _, _} ->
          :error

        {_, _, {_, _, _, _, _}} ->
          png(rest, dimensions, idat)

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp png(_, _, _), do: :error

  defp valid_depth?(0, depth), do: depth in [1, 2, 4, 8, 16]
  defp valid_depth?(3, depth), do: depth in [1, 2, 4, 8]
  defp valid_depth?(_, depth), do: depth in [8, 16]

  # Decode only the bounded deflate stream, not pixels. Row lengths and filter tags must
  # match IHDR; safeInflate bounds each chunk so a tiny decompression bomb is refused.
  defp valid_pixels?(compressed, {w, h, depth, color, interlace}) do
    channels = %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[color]

    passes =
      if interlace == 0,
        do: [{0, 0, 1, 1}],
        else: [
          {0, 0, 8, 8},
          {4, 0, 8, 8},
          {0, 4, 4, 8},
          {2, 0, 4, 4},
          {0, 2, 2, 4},
          {1, 0, 2, 2},
          {0, 1, 1, 2}
        ]

    rows =
      for {x, y, dx, dy} <- passes,
          pw = div(max(w - x, 0) + dx - 1, dx),
          pw > 0,
          ph = div(max(h - y, 0) + dy - 1, dy),
          ph > 0,
          _ <- 1..ph,
          do: div(pw * channels * depth + 7, 8)

    expected = Enum.sum(rows) + length(rows)
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)

      case inflate(z, compressed, expected, []) do
        {:ok, chunks} ->
          :ok = :zlib.inflateEnd(z)
          valid_rows?(IO.iodata_to_binary(Enum.reverse(chunks)), rows)

        :error ->
          false
      end
    catch
      _, _ -> false
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, input, left, acc) do
    {status, output} = :zlib.safeInflate(z, input)
    size = IO.iodata_length(output)

    cond do
      size > left -> :error
      status == :finished -> {:ok, [output | acc]}
      true -> inflate(z, [], left - size, [output | acc])
    end
  end

  defp valid_rows?("", []), do: true

  defp valid_rows?(<<filter, rest::binary>>, [size | rows])
       when filter <= 4 and byte_size(rest) >= size do
    <<_::binary-size(^size), rest::binary>> = rest
    valid_rows?(rest, rows)
  end

  defp valid_rows?(_, _), do: false

  defp jpeg(<<255, 255, rest::binary>>, dimensions), do: jpeg(<<255, rest::binary>>, dimensions)

  defp jpeg(<<255, marker, len::16, data::binary-size(len - 2), rest::binary>>, dimensions)
       when len >= 2 do
    cond do
      marker in [192, 193, 194] ->
        case data do
          <<depth, h::16, w::16, channels, components::binary>>
          when depth == 8 and channels in [1, 3, 4] and byte_size(components) == channels * 3 ->
            jpeg(rest, {w, h})

          _ ->
            :error
        end

      marker == 218 and dimensions != nil ->
        if byte_size(rest) > 2 and binary_part(rest, byte_size(rest) - 2, 2) == <<255, 217>>,
          do: {:ok, dimensions},
          else: :error

      marker in [216, 217, 0] ->
        :error

      true ->
        jpeg(rest, dimensions)
    end
  end

  defp jpeg(_, _), do: :error
end
