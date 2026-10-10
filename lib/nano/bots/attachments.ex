defmodule Nano.Bots.Attachments do
  @moduledoc """
  Immutable generic downloads, maximum 10 MiB. All generic files (including HTML,
  SVG and polyglots) are download-only octet streams, never inline previews.
  `import_bytes(bytes, filename: "report.txt")` / `import_file(path, opts)` return
  `{:ok, metadata}` including a string `ref`, safe filename, bytes, kind and url.
  `metadata(ref)` and `read(ref)` revalidate content identity. `store_dir:` overrides
  the default `state_dir/bot_attachments`. Names never become paths. The store root
  is trusted local storage, not protection against a hostile filesystem writer.
  `image_ref(map, opts)` validates existing Nano.Images objects without copying;
  image refs are `image:<sha256>`, generic refs `attachment:<sha256>`.
  """
  @max 10 * 1024 * 1024
  def max_bytes, do: @max

  def import_file(path, opts \\ []) do
    with {:ok, data} <- bounded_read(path, @max),
         do: import_bytes(data, Keyword.put_new(opts, :filename, Path.basename(path)))
  end

  def import_bytes(data, opts \\ [])

  def import_bytes(data, opts) when is_binary(data) and byte_size(data) <= @max do
    filename = filename(Keyword.get(opts, :filename, "download"))
    object = Jason.encode!(%{filename: filename, data: Base.encode64(data)})
    id = hash(object)
    root = dir(opts)
    dest = Path.join(root, id)
    temp = dest <> "." <> Base.encode16(:crypto.strong_rand_bytes(12)) <> ".tmp"

    try do
      with :ok <- File.mkdir_p(root),
           :ok <- File.write(temp, object, [:binary, :exclusive]),
           :ok <- File.chmod(temp, 0o444),
           :ok <- publish(temp, dest),
           {:ok, meta} <- metadata("attachment:" <> id, opts),
           do: {:ok, meta}
    after
      File.rm(temp)
    end
  end

  def import_bytes(_, _), do: {:error, :attachment_too_large}

  def image_ref(ref, opts \\ []) do
    with {:ok, canonical} <- Nano.Images.canonicalize(ref, opts),
         do: {:ok, "image:" <> canonical.image_ref}
  end

  def metadata(ref, opts \\ [])

  def metadata("image:" <> id, opts) do
    with true <- valid_id?(id) or {:error, :invalid_ref},
         {:ok, image} <- Nano.Images.canonicalize(%{image_ref: id}, opts) do
      {:ok,
       Map.merge(image, %{
         ref: "image:" <> id,
         kind: :image,
         filename: "image",
         url: "/api/images/" <> id
       })}
    end
  end

  def metadata(ref, opts) do
    with {:ok, {meta, _}} <- object(ref, opts), do: {:ok, meta}
  end

  def read(ref, opts \\ []) do
    with {:ok, {meta, data}} <- object(ref, opts), do: {:ok, data, meta}
  end

  defp object("attachment:" <> id = ref, opts) do
    with true <- valid_id?(id) or {:error, :invalid_ref},
         {:ok, encoded} <- confined_read(Path.join(dir(opts), id)),
         true <- hash(encoded) == id or {:error, :hash_mismatch},
         {:ok, %{"filename" => name, "data" => b64}} <- Jason.decode(encoded),
         true <-
           (is_binary(name) and name == filename(name) and is_binary(b64)) or
             {:error, :invalid_object},
         {:ok, data} <- Base.decode64(b64),
         true <- byte_size(data) <= @max or {:error, :attachment_too_large} do
      {:ok,
       {%{
          ref: ref,
          kind: :file,
          filename: name,
          bytes: byte_size(data),
          url: "/bots/attachments/" <> id
        }, data}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_object}
    end
  end

  defp object(_, _), do: {:error, :invalid_ref}

  defp dir(opts),
    do:
      Keyword.get(
        opts,
        :store_dir,
        Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "bot_attachments")
      )

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)
  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp filename(name) when is_binary(name) do
    safe =
      name
      |> String.replace(~r/[^a-zA-Z0-9._ -]/, "_")
      |> String.slice(0, 120)
      |> then(&Regex.replace(~r/\A[ .]+|[ .]+\z/, &1, ""))

    if safe == "", do: "download", else: safe
  end

  defp filename(_), do: "download"

  defp confined_read(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular or {:error, :not_regular_file},
         do: bounded_read(path, div(@max * 4, 3) + 1024)
  end

  defp bounded_read(path, limit) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular or {:error, :not_regular_file},
         true <- stat.size <= limit or {:error, :attachment_too_large} do
      case File.open(path, [:read, :binary], &IO.binread(&1, limit + 1)) do
        {:ok, data} when is_binary(data) and byte_size(data) <= limit -> {:ok, data}
        {:ok, :eof} -> {:ok, ""}
        {:ok, data} when is_binary(data) -> {:error, :attachment_too_large}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp publish(temp, dest) do
    case File.ln(temp, dest) do
      {:error, :eexist} -> :ok
      result -> result
    end
  end
end
