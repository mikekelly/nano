defmodule Nano.Image do
  @moduledoc """
  An image an agent can be shown: a value holding where its bytes are kept, never the bytes.

  `new/1` takes image data or a path on this node, checks the type by its first bytes (PNG,
  JPEG, GIF or WebP, the four every provider takes) and the size (at most 3,750,000 bytes,
  so that its base64, 5,000,000 bytes, is within the strictest provider limit: Claude on
  Bedrock and Vertex), and stores the bytes once, immutable and named by their SHA-256, as
  `<image_dir>/<sha>.<ext>` (`IMAGE_DIR`). The same bytes are always the same image.

  A `%Nano.Image{}` in a message to an agent, or in an eval's result, is attached for the
  model to see (`NanoAgent`). The transcript, state and logs keep only its reference
  (`ref/1`); the bytes are read from the store and inlined (`parts/1`) only when a request
  is built.
  """

  @enforce_keys [:sha, :mime, :bytes, :path]
  defstruct [:sha, :mime, :bytes, :path]

  @max_bytes 3_750_000
  @types %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @doc """
  `{:ok, %Nano.Image{}}` for image data, or for a path to an image file, stored in the image
  store; or `{:error, message}`. A binary that starts like an image is data; printable text of
  up to 4096 bytes is a path; anything else is data that is not an image.
  """
  def new(data_or_path) when is_binary(data_or_path) do
    path? =
      mime(data_or_path) == nil and byte_size(data_or_path) <= 4096 and
        String.printable?(data_or_path)

    case if(path?, do: File.read(data_or_path), else: {:ok, data_or_path}) do
      {:ok, data} -> store(data, mime(data))
      {:error, e} -> {:error, "cannot read #{data_or_path}: #{:file.format_error(e)}"}
    end
  end

  def new(other), do: {:error, "give image data or a path, not #{inspect(other, limit: 5)}"}

  defp store(_data, nil),
    do: {:error, "not a PNG, JPEG, GIF or WebP image (the type is read from its first bytes)"}

  defp store(data, _mime) when byte_size(data) > @max_bytes,
    do: {:error, "the image is #{byte_size(data)} bytes; the most is #{@max_bytes}"}

  defp store(data, mime) do
    sha = Base.encode16(:crypto.hash(:sha256, data), case: :lower)
    image = from_ref(%{"sha" => sha, "mime" => mime, "bytes" => byte_size(data)})
    tmp = image.path <> ".#{System.unique_integer([:positive])}.tmp"

    # Content-addressed: a file already there holds these bytes. Written whole, then renamed.
    with false <- File.exists?(image.path),
         :ok <- File.mkdir_p(Path.dirname(image.path)),
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, image.path) do
      {:ok, image}
    else
      true -> {:ok, image}
      {:error, e} -> {:error, "cannot store the image in #{image.path}: #{:file.format_error(e)}"}
    end
  end

  defp mime(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  defp mime(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp mime(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: "image/gif"
  defp mime(<<"RIFF", _::binary-4, "WEBP", _::binary>>), do: "image/webp"
  defp mime(_), do: nil

  @doc """
  The images in a term (in messages, tuples, lists, maps and structs, at any depth), each
  once, in the order found.
  """
  def find(term), do: term |> walk([]) |> Enum.reverse() |> Enum.uniq_by(& &1.sha)

  # Only well-formed ones: a struct built by hand cannot name a file outside the store.
  defp walk(%__MODULE__{sha: sha, mime: mime} = image, acc) when is_map_key(@types, mime),
    do: if(sha =~ ~r/^[0-9a-f]{64}$/, do: [image | acc], else: acc)

  defp walk(t, acc) when is_tuple(t), do: walk(Tuple.to_list(t), acc)
  defp walk(m, acc) when is_map(m), do: walk(Map.to_list(m), acc)
  defp walk([h | t], acc), do: walk(t, walk(h, acc))
  defp walk(_, acc), do: acc

  @doc "What the transcript and the log keep of an image: `%{\"sha\", \"mime\", \"bytes\"}`."
  def ref(%__MODULE__{} = i), do: %{"sha" => i.sha, "mime" => i.mime, "bytes" => i.bytes}

  @doc "The image a reference names, with its path in the store."
  def from_ref(%{"sha" => sha, "mime" => mime, "bytes" => bytes}),
    do: %__MODULE__{sha: sha, mime: mime, bytes: bytes, path: path(sha <> "." <> @types[mime])}

  @doc "The path of a file in the store, by its name (`<sha>.<ext>`)."
  def path(file), do: Path.expand(Path.join(Application.fetch_env!(:nano, :image_dir), file))

  @doc """
  What a request shows of images, by reference, read from the store as it is built: for each,
  `{:text, how it prints}` then `{:image, data_url}`; for one whose file cannot be read,
  `{:text, why}` instead. The store never changes a file, so the same images give the same
  request, and a provider's cache still matches.
  """
  def parts(refs) do
    Enum.flat_map(refs, fn ref ->
      image = from_ref(ref)

      case File.read(image.path) do
        {:ok, data} ->
          [{:text, inspect(image)}, {:image, "data:#{image.mime};base64," <> Base.encode64(data)}]

        {:error, e} ->
          [{:text, "[image not shown: #{image.path} cannot be read: #{:file.format_error(e)}]"}]
      end
    end)
  end

  defimpl Inspect do
    def inspect(image, _opts), do: "#Nano.Image<#{image.path}, #{image.bytes} bytes>"
  end
end
