defmodule SeedImages do
  @moduledoc """
  Immutable, bounded image attachments for harness integration. `ingest(path)` or
  `ingest_bytes(bytes)` returns `{:ok, ref}`; refs contain metadata, never base64.
  `view(path)` sends `{:seed_image, ref}` to the calling agent after validation.
  NanoAgent consumes that event into a user message after tool results; Nano.Model
  calls `hydrate(messages, provider, input_modalities)` only at request construction.
  Providers are `:openrouter` and `:chatgpt`. Store refs in state/logs, not hydrated
  messages. Serve operator images with `load(ref)` (validated bytes and MIME).

  Image support is explicit: persist provider `input_modalities` when starting an
  agent. Missing modalities means unsupported, never infer support from a name.
  `orientation(modalities)` states the actual capability. Images cost `tokens/1`,
  not their encoded byte length. A conservative 2,000-pixel limit on either side
  keeps attachments valid even when a transcript later contains over 20 images.
  The default content-addressed store is `<state_dir>/images`; custom `root:` is
  useful for tests. Do not modify files in it; hydration verifies their digest.
  """
  @max_bytes 3_750_000
  @max_side 2_000
  @token_cost 4_800

  @doc "Default attachment store, scoped to the node's persisted state directory."
  def root, do: Path.join(Application.fetch_env!(:nano, :state_dir), "images")

  @doc "Transform reference parts into conservative byte-equivalents for the harness estimator."
  def for_estimate(%{"type" => "seed_image"}), do: String.duplicate("x", @token_cost * 2)
  def for_estimate(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, for_estimate(v)} end)
  def for_estimate(list) when is_list(list), do: Enum.map(list, &for_estimate/1)
  def for_estimate(value), do: value

  @doc "Remove embedded image data from raw HTTP debug records, not the actual request."
  def redact(iodata) when is_list(iodata), do: redact(IO.iodata_to_binary(iodata))

  def redact(binary) when is_binary(binary),
    do:
      Regex.replace(
        ~r/data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+\/=]+/,
        binary,
        "[image bytes omitted]"
      )

  @doc "Whether persisted
 provider metadata explicitly includes image input."
  def supported?(modalities) when is_list(modalities), do: "image" in modalities
  def supported?(_), do: false

  @doc "Short truthful prompt orientation, suitable for every model."
  def orientation(modalities) do
    if supported?(modalities),
      do:
        "You can see images. Use SeedImages.view(path) to view a local image; see Code.fetch_docs(SeedImages).",
      else:
        "Your model cannot see images. Image attachments are reported as unavailable; do not guess what they show."
  end

  @doc "Import a local file with bounded reading. Returns a reference or a bounded error."
  def ingest(path, opts \\ [])

  def ingest(path, opts) when is_binary(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      result = IO.binread(io, @max_bytes + 1)
      File.close(io)

      case result do
        bytes when is_binary(bytes) -> ingest_bytes(bytes, opts)
        :eof -> {:error, "Image file is empty."}
        _ -> {:error, "Could not read image file."}
      end
    else
      {:error, reason} -> {:error, "Could not open image file: #{:file.format_error(reason)}."}
    end
  end

  def ingest(_, _), do: {:error, "Image path must be a string."}

  @doc "Import uploaded bytes; rejects wrong types, oversized files and dimensions."
  def ingest_bytes(bytes, opts \\ []) do
    with :ok <- size(bytes),
         {:ok, mime, width, height} <- dimensions(bytes),
         :ok <- bounds(width, height),
         hash = digest(bytes),
         root = Keyword.get(opts, :root, root()),
         :ok <- File.mkdir_p(root),
         path = Path.join(root, hash),
         :ok <- store(path, bytes) do
      {:ok,
       %{
         "type" => "seed_image",
         "sha256" => hash,
         "path" => path,
         "mime" => mime,
         "width" => width,
         "height" => height,
         "bytes" => byte_size(bytes)
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "Could not persist image attachment."}
    end
  end

  @doc "Queue a validated image for the calling agent's next model turn."
  def view(path, opts \\ []) do
    with {:ok, ref} <- ingest(path, opts) do
      target = Keyword.get(opts, :target, caller())
      send(target, {:seed_image, ref})
      {:ok, ref}
    end
  end

  defp caller, do: List.first(Process.get(:"$callers", [])) || self()

  @doc "Reference-only content part to persist in a user message."
  def part(ref), do: %{"type" => "seed_image", "image" => ref}

  @doc "Conservative image token budget (never count base64 as text)."
  def tokens(_ref), do: @token_cost

  @doc "Verify immutable attachment and return {:ok, bytes, mime}; safe for serving."
  def load(%{"path" => path, "sha256" => hash} = ref)
      when is_binary(path) and is_binary(hash) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      bytes = IO.binread(io, @max_bytes + 1)
      File.close(io)

      with :ok <- size(bytes),
           true <- digest(bytes) == hash,
           {:ok, mime, w, h} <- dimensions(bytes),
           :ok <- bounds(w, h),
           true <- mime == ref["mime"] and w == ref["width"] and h == ref["height"] do
        {:ok, bytes, mime}
      else
        _ -> {:error, "Image attachment is corrupt or changed; re-import the original."}
      end
    else
      _ -> {:error, "Image attachment is missing; re-import the original."}
    end
  end

  def load(_), do: {:error, "Invalid image reference."}

  @doc "Expand user image refs only at the provider boundary; unsupported models get text."
  def hydrate(messages, provider, modalities) when provider in [:openrouter, :chatgpt] do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case hydrate_message(message, provider, modalities) do
        {:ok, expanded} -> {:cont, {:ok, [expanded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp hydrate_message(%{"content" => parts} = message, provider, modalities)
       when is_list(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      %{"type" => "seed_image", "image" => ref}, {:ok, acc} ->
        cond do
          not supported?(modalities) ->
            {:cont,
             {:ok,
              [
                %{
                  "type" => "text",
                  "text" => "[Image unavailable: your model does not support image input.]"
                }
                | acc
              ]}}

          message["role"] != "user" ->
            {:halt, {:error, "Images must be placed in a user message after tool results."}}

          true ->
            case load(ref) do
              {:ok, bytes, mime} ->
                url = "data:" <> mime <> ";base64," <> Base.encode64(bytes)

                image =
                  if provider == :openrouter,
                    do: %{"type" => "image_url", "image_url" => %{"url" => url}},
                    else: %{"type" => "input_image", "image_url" => url}

                {:cont, {:ok, [image | acc]}}

              error ->
                {:halt, error}
            end
        end

      other, {:ok, acc} ->
        {:cont, {:ok, [other | acc]}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Map.put(message, "content", Enum.reverse(parts))}
      error -> error
    end
  end

  defp hydrate_message(message, _, _), do: {:ok, message}

  defp size(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max_bytes, do: :ok
  defp size(_), do: {:error, "Image must contain 1 to 3,750,000 bytes (at most 5 MB base64)."}
  defp bounds(w, h) when w in 1..@max_side and h in 1..@max_side, do: :ok

  defp bounds(_, _),
    do:
      {:error,
       "Image dimensions must be between 1 and 2,000 pixels on each side; resize it first."}

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp store(path, bytes) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- File.write(temporary, bytes, [:binary, :exclusive]) do
        case File.ln(temporary, path) do
          :ok -> :ok
          {:error, :eexist} -> existing(path, bytes)
          error -> error
        end
      end
    after
      File.rm(temporary)
    end
  end

  defp existing(path, bytes) do
    with {:ok, io} <- File.open(path, [:binary, :read]) do
      stored = IO.binread(io, @max_bytes + 1)
      File.close(io)

      if stored == bytes,
        do: :ok,
        else: {:error, "Stored image digest collision or corrupt attachment."}
    end
  end

  # Read only bounded headers; reject unsupported formats instead of trusting extensions.
  defp dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, rest::binary>>)
       when byte_size(rest) >= 13, do: {:ok, "image/png", w, h}

  defp dimensions(<<"GIF", version::binary-size(3), w::little-16, h::little-16, rest::binary>>)
       when version in ["87a", "89a"] and byte_size(rest) >= 3, do: {:ok, "image/gif", w, h}

  defp dimensions(<<255, 216, rest::binary>>), do: jpeg(rest)

  defp dimensions(
         <<"RIFF", _::little-32, "WEBP", "VP8X", 10::little-32, _flags, _reserved::24,
           w::little-24, h::little-24, _::binary>>
       ),
       do: {:ok, "image/webp", w + 1, h + 1}

  defp dimensions(
         <<"RIFF", _::little-32, "WEBP", "VP8L", _::little-32, 47,
           w::little-unsigned-integer-size(32), _::binary>>
       ),
       do:
         {:ok, "image/webp", Bitwise.band(w, 0x3FFF) + 1,
          Bitwise.band(Bitwise.bsr(w, 14), 0x3FFF) + 1}

  defp dimensions(
         <<"RIFF", _::little-32, "WEBP", "VP8 ", _::little-32, _::binary-size(3), 157, 1, 42,
           w::little-16, h::little-16, _::binary>>
       ),
       do: {:ok, "image/webp", Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}

  defp dimensions(_), do: {:error, "Unsupported or malformed image; use PNG, JPEG, GIF or WebP."}
  defp jpeg(<<255, 255, rest::binary>>), do: jpeg(<<255, rest::binary>>)

  defp jpeg(<<255, marker, len::16, rest::binary>>)
       when len >= 2 and byte_size(rest) >= len - 2 do
    if marker in [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207] do
      case rest do
        <<_precision, h::16, w::16, _::binary>> when len >= 7 -> {:ok, "image/jpeg", w, h}
        _ -> dimensions(<<>>)
      end
    else
      <<_segment::binary-size(^len - 2), tail::binary>> = rest
      jpeg(tail)
    end
  end

  defp jpeg(_), do: dimensions(<<>>)
end
