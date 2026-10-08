defmodule Nano.Images do
  @moduledoc """
  Immutable image attachments, stored outside transcripts/logs. `import/1` snapshots a
  local PNG, JPEG or GIF by content hash; `from_base64/1` imports an API upload.
  `view/1` inside an agent eval displays the image after the tool results (both providers).
  `NanoAgent.notify_image/3` delivers one with optional text. Unknown/text-only models get
  an explicit warning, never a filename masquerading as visual input.

  Conservative limits: 3,750,000 raw bytes (5 MB base64), 2,000 pixels per side even in
  histories with over 20 images. Types/dimensions are read from bytes, not names. Images
  are retained on disk across restart/compaction. No automatic garbage collection.
  """
  @max 3_750_000
  @tokens 4_800
  def tokens, do: @tokens

  def dir,
    do:
      Application.get_env(
        :nano,
        :image_dir,
        Path.join(Application.fetch_env!(:nano, :state_dir), "images")
      )

  def import(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @max,
         {:ok, bytes} <- File.read(path) do
      store(bytes)
    else
      false -> {:error, "image must be a regular file at most #{@max} bytes"}
      {:error, reason} -> {:error, "cannot read image: #{inspect(reason)}"}
    end
  end

  def from_base64(text) when is_binary(text) and byte_size(text) <= 5_000_000 do
    case Base.decode64(text) do
      {:ok, bytes} -> store(bytes)
      :error -> {:error, "invalid base64 image"}
    end
  end

  def from_base64(_), do: {:error, "image base64 must be at most 5 MB"}

  def store(bytes) when is_binary(bytes) and byte_size(bytes) <= @max do
    with {:ok, mime, width, height} <- dimensions(bytes),
         true <- width in 1..2000 and height in 1..2000,
         :ok <- File.mkdir_p(dir()) do
      id = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      path = Path.join(dir(), id)

      tmp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"

      result =
        with :ok <- File.write(tmp, bytes, [:exclusive]), :ok <- File.chmod(tmp, 0o444) do
          case File.ln(tmp, path) do
            {:error, :eexist} -> :ok
            other -> other
          end
        end

      File.rm(tmp)

      with :ok <- result do
        File.chmod(path, 0o444)

        {:ok,
         %{
           "type" => "nano_image",
           "id" => id,
           "mime" => mime,
           "width" => width,
           "height" => height
         }}
      end
    else
      false -> {:error, "image dimensions must be 1..2000 pixels per side"}
      {:error, reason} -> {:error, reason}
    end
  end

  def store(_), do: {:error, "image is over 3,750,000 bytes"}

  def read(%{"id" => id}) when is_binary(id) do
    if id =~ ~r/\A[0-9a-f]{64}\z/ do
      with {:ok, bytes} <- File.read(Path.join(dir(), id)),
           ^id <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
           {:ok, mime, _, _} <- dimensions(bytes) do
        {:ok, bytes, mime}
      else
        _ -> {:error, "image missing or changed: #{id}"}
      end
    else
      {:error, "invalid image reference"}
    end
  end

  def read(_), do: {:error, "invalid image reference"}

  def view(path) do
    with {:ok, ref} <- __MODULE__.import(path) do
      Process.put({__MODULE__, :views}, Process.get({__MODULE__, :views}, []) ++ [ref])
      {:ok, ref}
    end
  end

  @doc false
  def take_views, do: Process.delete({__MODULE__, :views}) || []

  def parts(text, refs), do: [%{"type" => "text", "text" => text} | refs]

  def count(messages),
    do: Enum.sum(for m <- messages, do: Enum.count(List.wrap(m["content"]), &image?/1))

  defp image?(%{"type" => "nano_image"}), do: true
  defp image?(_), do: false

  @doc "Expands references at the request boundary only, never in saved history."
  def expand(messages) do
    Enum.map(messages, fn m ->
      if is_list(m["content"]) do
        Map.put(
          m,
          "content",
          Enum.map(m["content"], fn
            %{"type" => "nano_image"} = ref ->
              case read(ref) do
                {:ok, bytes, mime} ->
                  %{
                    "type" => "image_url",
                    "image_url" => %{"url" => "data:#{mime};base64," <> Base.encode64(bytes)}
                  }

                {:error, reason} ->
                  raise ArgumentError, reason
              end

            part ->
              part
          end)
        )
      else
        m
      end
    end)
  end

  defp dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", w::32, h::32, _::binary>>),
    do: {:ok, "image/png", w, h}

  defp dimensions(<<"GIF", version::binary-size(3), w::little-16, h::little-16, _::binary>>)
       when version in ["87a", "89a"], do: {:ok, "image/gif", w, h}

  defp dimensions(<<255, 216, rest::binary>>), do: jpeg(rest)
  defp dimensions(_), do: {:error, "unsupported or malformed image (PNG, JPEG, GIF only)"}
  defp jpeg(<<255, 255, rest::binary>>), do: jpeg(<<255, rest::binary>>)

  defp jpeg(<<255, marker, len::16, rest::binary>>)
       when len >= 2 and byte_size(rest) >= len - 2 do
    <<segment::binary-size(^len - 2), tail::binary>> = rest

    if marker in [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207] do
      case segment do
        <<_, h::16, w::16, _::binary>> -> {:ok, "image/jpeg", w, h}
        _ -> {:error, "malformed JPEG dimensions"}
      end
    else
      jpeg(tail)
    end
  end

  defp jpeg(_), do: {:error, "malformed JPEG"}
end
