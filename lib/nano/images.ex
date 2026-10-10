defmodule Nano.Images do
  @moduledoc """
  Immutable SHA-256 image store (default `/data/images`, override `store_dir:`).
  PNG, JPEG, GIF and WebP container headers and dimensions are checked; this is
  not a full pixel decoder. Both axes must be 1..2000 and base64 at most 5 MiB,
  independent of image count. Refs are plain maps with image_ref, mime, width,
  height and raw bytes size. Reads verify identity and metadata. Atomic hard-link
  publication never replaces existing objects, even corrupt ones. Storage is a
  trusted local directory, not a boundary against hostile filesystem writers.

      {:ok, ref} = Nano.Images.import_file("picture.png")
      {:ok, url} = Nano.Images.data_url(ref)
  """
  @max_raw div(5 * 1024 * 1024, 4) * 3
  def import_file(path, opts \\ []) do
    with {:ok, data} <- bounded_read(path), do: import_bytes(data, opts)
  end

  def import_bytes(data, opts \\ []) do
    with {:ok, ref} <- describe(data),
         :ok <- File.mkdir_p(dir(opts)),
         :ok <- publish(data, ref, opts),
         do: {:ok, ref}
  end

  def read(ref, opts \\ []) do
    with :ok <- valid_ref(ref),
         {:ok, data} <- bounded_read(Path.join(dir(opts), ref.image_ref)),
         true <- hash(data) == ref.image_ref or {:error, :hash_mismatch},
         {:ok, actual} <- describe(data),
         true <-
           actual == Map.take(ref, [:image_ref, :mime, :width, :height, :bytes]) or
             {:error, :metadata_mismatch},
         do: {:ok, data}
  end

  def data_url(ref, opts \\ []) do
    with {:ok, data} <- read(ref, opts),
         do: {:ok, "data:" <> ref.mime <> ";base64," <> Base.encode64(data)}
  end

  @doc "Conservative constant budget for each image."
  def token_estimate(_ref \\ nil), do: 4800

  defp dir(opts),
    do: Keyword.get(opts, :store_dir, Application.get_env(:nano, :image_dir, "/data/images"))

  @doc "Verify and return only canonical reference fields."
  def canonicalize(ref, opts \\ []) do
    with {:ok, data} <- read(ref, opts), do: describe(data)
  end

  @doc "Import a file and notify an agent with a small image reference."
  def look(path, agent, opts \\ []) do
    with {:ok, ref} <- import_file(path, opts) do
      NanoAgent.notify(agent, %{text: "Image opened from file", images: [ref]})
      {:ok, ref}
    end
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp valid_ref(%{image_ref: h}) when is_binary(h) do
    if h =~ ~r/\A[0-9a-f]{64}\z/, do: :ok, else: {:error, :invalid_ref}
  end

  defp valid_ref(_), do: {:error, :invalid_ref}

  defp bounded_read(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_raw + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) <= @max_raw -> {:ok, data}
      {:ok, data} when is_binary(data) -> {:error, :image_too_large}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, e}} -> {:error, e}
      {:error, e} -> {:error, e}
    end
  end

  defp describe(data) when is_binary(data) and byte_size(data) > @max_raw,
    do: {:error, :image_too_large}

  defp describe(data) when is_binary(data) do
    case dimensions(data) do
      {mime, w, h} when w in 1..2000 and h in 1..2000 ->
        {:ok, %{image_ref: hash(data), mime: mime, width: w, height: h, bytes: byte_size(data)}}

      {_, _, _} ->
        {:error, :invalid_dimensions}

      _ ->
        {:error, :invalid_image}
    end
  end

  defp describe(_), do: {:error, :invalid_image}

  defp publish(data, ref, opts) do
    dest = Path.join(dir(opts), ref.image_ref)
    temp = dest <> "." <> Base.encode16(:crypto.strong_rand_bytes(12)) <> ".tmp"

    try do
      with :ok <- File.write(temp, data, [:binary, :exclusive]), :ok <- File.chmod(temp, 0o444) do
        case File.ln(temp, dest) do
          :ok ->
            :ok

          {:error, :eexist} ->
            case read(ref, opts) do
              {:ok, ^data} -> :ok
              error -> error
            end

          error ->
            error
        end
      end
    after
      File.rm(temp)
    end
  end

  defp dimensions(<<137, "PNG\r\n", 26, 10, rest::binary>>), do: png(rest, nil, false)

  defp dimensions(<<"GIF", v::binary-size(3), w::little-16, h::little-16, f, _, _, rest::binary>>)
       when v in ["87a", "89a"] do
    n = table_size(f)

    with <<_::binary-size(^n), body::binary>> <- rest,
         true <- gif(body, false),
         do: {"image/gif", w, h}
  end

  defp dimensions(<<255, 216, rest::binary>>), do: jpeg(rest, nil)

  defp dimensions(<<"RIFF", n::little-32, "WEBP", rest::binary>>) when n == byte_size(rest) + 4,
    do: webp(rest, nil, false)

  defp dimensions(_), do: nil

  defp png(<<n::32, t::binary-size(4), d::binary-size(n), crc::32, rest::binary>>, dims, pixels) do
    if :erlang.crc32(t <> d) == crc do
      case {t, d, dims} do
        {"IHDR", <<w::32, h::32, depth, color, 0, 0, interlace>>, nil}
        when depth in [1, 2, 4, 8, 16] and color in [0, 2, 3, 4, 6] and interlace in [0, 1] ->
          png(rest, {"image/png", w, h}, pixels)

        {"IEND", "", dims} when dims != nil and pixels and rest == "" ->
          dims

        {"IDAT", _, dims} when dims != nil ->
          png(rest, dims, pixels or n > 0)

        {"IHDR", _, _} ->
          nil

        {_, _, dims} when dims != nil ->
          png(rest, dims, pixels)

        _ ->
          nil
      end
    end
  end

  defp png(_, _, _), do: nil

  defp table_size(f),
    do: if(Bitwise.band(f, 128) != 0, do: 3 * Bitwise.bsl(1, Bitwise.band(f, 7) + 1), else: 0)

  defp gif(<<59>>, seen), do: seen

  defp gif(<<33, _, rest::binary>>, seen) do
    case blocks(rest) do
      {:ok, tail} -> gif(tail, seen)
      _ -> false
    end
  end

  defp gif(<<44, _::32, w::little-16, h::little-16, f, rest::binary>>, _)
       when w in 1..2000 and h in 1..2000 do
    n = table_size(f)

    with <<_::binary-size(^n), code, body::binary>> <- rest,
         true <- code in 2..8,
         {:ok, tail} <- blocks(body),
         do: gif(tail, true),
         else: (_ -> false)
  end

  defp gif(_, _), do: false
  defp blocks(<<0, rest::binary>>), do: {:ok, rest}
  defp blocks(<<n, _::binary-size(n), rest::binary>>), do: blocks(rest)
  defp blocks(_), do: :error
  defp jpeg(<<255, 255, rest::binary>>, dims), do: jpeg(<<255, rest::binary>>, dims)

  defp jpeg(<<255, m, n::16, d::binary-size(n - 2), rest::binary>>, dims) when n >= 2 do
    cond do
      m in [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207] ->
        case d do
          <<_, h::16, w::16, c, desc::binary>> when c > 0 and byte_size(desc) == c * 3 ->
            jpeg(rest, {"image/jpeg", w, h})

          _ ->
            nil
        end

      m == 218 and dims != nil ->
        scan(rest, dims)

      m in [0, 216, 217] ->
        nil

      true ->
        jpeg(rest, dims)
    end
  end

  defp jpeg(_, _), do: nil
  defp scan(<<255, 217>>, dims), do: dims
  defp scan(<<255, 0, rest::binary>>, dims), do: scan(rest, dims)
  defp scan(<<255, m, rest::binary>>, dims) when m in 208..215, do: scan(rest, dims)
  defp scan(<<255, rest::binary>>, dims), do: jpeg(<<255, rest::binary>>, dims)
  defp scan(<<_, rest::binary>>, dims), do: scan(rest, dims)
  defp scan(_, _), do: nil
  defp webp(<<>>, dims, true), do: dims

  defp webp(<<t::binary-size(4), n::little-32, d::binary-size(n), rest::binary>>, dims, pixels) do
    pad = rem(n, 2)

    with <<_::binary-size(^pad), tail::binary>> <- rest do
      case {t, d} do
        {"VP8X", <<_, 0, 0, 0, w::little-24, h::little-24>>} ->
          webp(tail, {"image/webp", w + 1, h + 1}, pixels)

        {"VP8L", <<47, bits::little-32, _::binary>>} ->
          if Bitwise.bsr(bits, 29) == 0,
            do:
              webp(
                tail,
                dims ||
                  {"image/webp", Bitwise.band(bits, 16383) + 1,
                   Bitwise.band(Bitwise.bsr(bits, 14), 16383) + 1},
                true
              )

        {"VP8 ", <<_::24, 157, 1, 42, w::little-16, h::little-16, _::binary>>} ->
          webp(tail, dims || {"image/webp", Bitwise.band(w, 16383), Bitwise.band(h, 16383)}, true)

        _ ->
          webp(tail, dims, pixels)
      end
    end
  end

  defp webp(_, _, _), do: nil
end
