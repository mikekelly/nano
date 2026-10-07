defmodule Vega.Images do
  @moduledoc """
  Immutable, content-addressed vision attachments. `view(path)` in an agent eval imports
  an image and queues it for vision; `import_file(path)` only imports. `import_bytes(bytes)`
  is for upload adapters. Results are `{:ok, ref}` or `{:error, explanation}`. References
  contain metadata, never bytes or arbitrary paths. See docs/vega-images.md.
  """
  @max_bytes 3_750_000
  @max_side 2_000
  @tokens 4_800

  def view(path) do
    with {:ok, ref} <- import_file(path) do
      Process.put({__MODULE__, :views}, Process.get({__MODULE__, :views}, []) ++ [ref])
      {:ok, ref}
    end
  end

  def take_views, do: Process.delete({__MODULE__, :views}) || []

  def import_file(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @max_bytes,
         {:ok, bytes} <- File.read(path) do
      import_bytes(bytes)
    else
      _ -> {:error, "image must be a readable regular file of at most #{@max_bytes} bytes"}
    end
  end

  def import_bytes(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, mime, w, h} <- dimensions(bytes),
         true <- w > 0 and h > 0 and w <= @max_side and h <= @max_side,
         id = digest(bytes),
         :ok <- File.mkdir_p(root()),
         :ok <- verify_pixels(bytes, id, mime, w, h),
         :ok <- store(id, bytes) do
      {:ok,
       %{
         "type" => "image_ref",
         "id" => id,
         "mime" => mime,
         "width" => w,
         "height" => h,
         "bytes" => byte_size(bytes)
       }}
    else
      false -> {:error, "image dimensions must be 1..#{@max_side} pixels per side"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "could not store image"}
    end
  end

  def import_bytes(_), do: {:error, "image must be at most #{@max_bytes} bytes (5 MB base64)"}

  def fetch(id) when is_binary(id) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, id),
         path = Path.join(root(), id),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size <= @max_bytes,
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == id,
         {:ok, mime, w, h} <- dimensions(bytes),
         true <- w > 0 and h > 0 and w <= @max_side and h <= @max_side,
         :ok <- verify_pixels(bytes, id, mime, w, h) do
      {:ok, bytes, mime}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "image missing or corrupt"}
    end
  end

  def fetch(_), do: {:error, "invalid image id"}

  def validate_refs(refs) when is_list(refs) and length(refs) <= 20 do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      with %{"type" => "image_ref", "id" => id} <- ref,
           {:ok, bytes, _} <- fetch(id),
           {:ok, canonical} <- import_bytes(bytes) do
        {:cont, {:ok, acc ++ [canonical]}}
      else
        _ -> {:halt, {:error, "invalid image reference"}}
      end
    end)
  end

  def validate_refs(_), do: {:error, "images must be a list of at most 20 references"}

  def content(text, []), do: text
  def content(text, refs), do: [%{"type" => "text", "text" => text} | refs]

  def vision_note(modalities) do
    if "image" in (modalities || []),
      do:
        "Your model can see image attachments. To see an image file on this node, call Vega.Images.view(path) in eval. It imports immutable bytes and attaches the image after tool results.",
      else:
        "Your model cannot see images. Attachments are described as metadata only; do not infer their contents. Vega.Images.view(path) can import them but cannot give this model vision."
  end

  # Only request builders call this: never store or log its result.
  def openrouter(messages), do: Enum.map(messages, &hydrate(&1, :openrouter))
  def responses_content(text) when is_binary(text), do: [%{type: "input_text", text: text}]
  def responses_content(parts) when is_list(parts), do: Enum.map(parts, &part(&1, :responses))

  @doc "Strip data URLs from provider error bodies before they can enter logs."
  def redact(value) when is_binary(value),
    do:
      Regex.replace(
        ~r/data:image\/[a-zA-Z0-9.+-]+;base64,[a-zA-Z0-9+\/=]+/,
        value,
        "[image data redacted]"
      )

  def redact(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, redact(v)} end)
  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value), do: value

  def estimated_bytes(term), do: estimate(term)

  defp estimate(%{"type" => "image_ref"}), do: @tokens * 2

  defp estimate(map) when is_map(map),
    do: Enum.reduce(map, 2, fn {k, v}, n -> n + estimate(k) + estimate(v) + 2 end)

  defp estimate(list) when is_list(list), do: Enum.reduce(list, 2, &(estimate(&1) + &2 + 1))
  defp estimate(value), do: byte_size(Jason.encode!(value))

  defp hydrate(%{"content" => parts} = m, provider) when is_list(parts),
    do: Map.put(m, "content", Enum.map(parts, &part(&1, provider)))

  defp hydrate(m, _), do: m

  defp part(%{"type" => "image_ref", "id" => id}, provider) do
    case fetch(id) do
      {:ok, bytes, mime} ->
        url = "data:" <> mime <> ";base64," <> Base.encode64(bytes)

        case provider do
          :openrouter ->
            %{"type" => "image_url", "image_url" => %{"url" => url, "detail" => "high"}}

          :responses ->
            %{type: "input_image", image_url: url, detail: "high"}
        end

      {:error, reason} ->
        # Legacy header-only refs can be invalid. Never send them to a provider forever;
        # leave the stored transcript immutable and send an explicit inability notice.
        text =
          "Image attachment #{id} unavailable: #{reason}. No image contents were provided; do not guess."

        case provider do
          :openrouter -> %{"type" => "text", "text" => text}
          :responses -> %{type: "input_text", text: text}
        end
    end
  end

  defp part(%{"type" => "text", "text" => text}, :responses),
    do: %{type: "input_text", text: text}

  defp part(p, _), do: p

  # Cache verified immutable byte hashes across turns/restarts, not per caller-supplied ref.
  # Bump the marker schema whenever decoder admission rules change.
  defp verify_pixels(bytes, id, mime, w, h) do
    marker = Path.join(root(), ".verified-v2-" <> id)
    expected = "#{mime}:#{w}:#{h}"

    case File.read(marker) do
      {:ok, ^expected} ->
        :ok

      {:ok, "invalid"} ->
        {:error, "invalid image pixels; re-import a valid image file"}

      _ ->
        case decode_pixels(bytes, mime, w, h) do
          :ok ->
            File.write(marker, expected, [:exclusive])
            :ok

          {:error, :invalid} ->
            File.write(marker, "invalid", [:exclusive])
            {:error, "invalid image pixels; use a complete static PNG, JPEG, GIF or WebP"}

          error ->
            error
        end
    end
  end

  defp decode_pixels(bytes, mime, w, h) do
    python = Application.get_env(:nano, :image_decoder_python, "/usr/bin/python3")
    helper = Path.join(to_string(:code.priv_dir(:nano)), "vega/verify_image.py")
    timeout = System.find_executable("timeout")

    if not is_binary(timeout) or not File.regular?(python) or not File.regular?(helper) do
      {:error, "image decoder unavailable; install python3-pil and GNU timeout"}
    else
      dir = Path.join(root(), ".validate-" <> Base.encode16(:crypto.strong_rand_bytes(16)))

      case File.mkdir(dir) do
        :ok ->
          try do
            path = Path.join(dir, "input")

            with :ok <- File.chmod(dir, 0o700),
                 :ok <- File.write(path, bytes, [:binary, :exclusive]),
                 :ok <- File.chmod(path, 0o600) do
              {output, status} =
                System.cmd(timeout, ["--signal=KILL", "5s", python, "-I", "-B", helper, path],
                  stderr_to_stdout: true
                )

              case {status, Jason.decode(output)} do
                {0, {:ok, %{"mime" => ^mime, "width" => ^w, "height" => ^h}}} ->
                  :ok

                {2, {:ok, %{"error" => "decoder_unavailable"}}} ->
                  {:error, "image decoder unavailable; install python3-pil"}

                {1, {:ok, %{"error" => reason}}}
                when reason in ["invalid_image", "animated_image"] ->
                  {:error, :invalid}

                _ ->
                  {:error, "image decoder failed or exceeded its 5 second resource limit"}
              end
            else
              _ -> {:error, "could not create private image validation file"}
            end
          rescue
            _ -> {:error, "image decoder could not run"}
          after
            File.rm_rf(dir)
          end

        _ ->
          {:error, "could not create private image validation directory"}
      end
    end
  end

  defp root, do: Path.join(Application.fetch_env!(:nano, :state_dir), "images")

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp store(id, bytes) do
    path = Path.join(root(), id)
    # Write privately, then hard-link atomically with exclusive destination creation.
    # Readers never observe partially written bytes, and concurrent imports cannot replace.
    temp = Path.join(root(), ".upload-" <> Base.encode16(:crypto.strong_rand_bytes(16)))

    try do
      with :ok <- File.write(temp, bytes, [:binary, :exclusive]),
           :ok <- File.chmod(temp, 0o444) do
        case File.ln(temp, path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            if File.read(path) == {:ok, bytes}, do: :ok, else: {:error, "image store corruption"}

          error ->
            error
        end
      end
    after
      File.rm(temp)
    end
  end

  def dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, _::binary>>),
    do: {:ok, "image/png", w, h}

  def dimensions(<<"GIF", version::binary-size(3), w::little-16, h::little-16, _::binary>>)
      when version in ["87a", "89a"], do: {:ok, "image/gif", w, h}

  def dimensions(<<255, 216, rest::binary>>), do: jpeg(rest)

  def dimensions(
        <<"RIFF", _::little-32, "WEBPVP8X", _::little-32, _flags, _::24, w::little-24,
          h::little-24, _::binary>>
      ),
      do: {:ok, "image/webp", w + 1, h + 1}

  def dimensions(
        <<"RIFF", _::little-32, "WEBPVP8L", _::little-32, 47, bits::little-32, _::binary>>
      ) do
    {:ok, "image/webp", Bitwise.band(bits, 16383) + 1,
     Bitwise.band(Bitwise.bsr(bits, 14), 16383) + 1}
  end

  def dimensions(
        <<"RIFF", _::little-32, "WEBPVP8 ", _::little-32, _::24, 157, 1, 42, w::little-16,
          h::little-16, _::binary>>
      ),
      do: {:ok, "image/webp", Bitwise.band(w, 16383), Bitwise.band(h, 16383)}

  def dimensions(_), do: {:error, "unsupported or malformed image; use PNG, JPEG, GIF or WebP"}
  defp jpeg(<<255, 255, rest::binary>>), do: jpeg(<<255, rest::binary>>)

  defp jpeg(<<255, marker, len::16, rest::binary>>)
       when len >= 2 and byte_size(rest) >= len - 2 do
    case {marker, rest} do
      {m, <<_precision, h::16, w::16, _::binary>>}
      when m in [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207] ->
        {:ok, "image/jpeg", w, h}

      _ ->
        skip = len - 2
        <<_::binary-size(^skip), tail::binary>> = rest
        jpeg(tail)
    end
  end

  defp jpeg(_), do: {:error, "malformed JPEG dimensions"}
end
