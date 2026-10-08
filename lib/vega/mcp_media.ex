defmodule Vega.MCP.Media do
  @moduledoc """
  Opaque, private, bounded MCP binary payloads. Normal RPC results contain references,
  not bare base64. `info/1` and `page/1` return metadata only. `view_image/1` explicitly
  asks Vega.Images to verify/import pixels and queue native vision; no decoder is
  duplicated here. Unverified refs never claim that image contents have been seen.
  """
  @images ["image/png", "image/jpeg", "image/gif", "image/webp"]
  @max_parts 20

  def normalize(value), do: elem(walk(value, @max_parts), 0)

  defp walk(%{"type" => type, "data" => data} = part, budget) when type in ["image", "audio"] do
    mime = mime(part["mimeType"])
    {media, remaining} = extract(data, mime, budget)
    base = part |> Map.delete("data") |> Map.put("mimeType", mime)
    {base, remaining} = walk_map(base, remaining)
    {Map.put(base, "media", media), remaining}
  end

  defp walk(%{"uri" => _, "blob" => data} = part, budget) do
    mime = mime(part["mimeType"])
    {media, remaining} = extract(data, mime, budget)
    base = part |> Map.delete("blob") |> Map.put("mimeType", mime)
    {base, remaining} = walk_map(base, remaining)
    {Map.put(base, "media", media), remaining}
  end

  defp walk(map, budget) when is_map(map), do: walk_map(map, budget)
  defp walk(list, budget) when is_list(list), do: Enum.map_reduce(list, budget, &walk/2)
  defp walk(value, budget), do: {value, budget}

  defp walk_map(map, budget),
    do:
      Enum.map_reduce(map, budget, fn {key, value}, left ->
        {value, left} = walk(value, left)
        {{key, value}, left}
      end)
      |> then(fn {pairs, left} -> {Map.new(pairs), left} end)

  defp extract(data, mime, 0), do: {error(:too_many_media_parts, data, mime), 0}

  defp extract(data, mime, budget) do
    result =
      cond do
        not is_binary(data) ->
          {:error, :invalid_base64_type}

        byte_size(data) > 5_000_000 ->
          {:error, :payload_too_large}

        true ->
          with {:ok, bytes} <- Base.decode64(data),
               true <- byte_size(bytes) > 0 and byte_size(bytes) <= 3_750_000 do
            kind = if mime in @images, do: "image", else: "binary"
            Vega.MCP.Media.Cache.store(bytes, mime, kind)
          else
            :error -> {:error, :invalid_base64}
            false -> {:error, :payload_too_large_or_empty}
          end
      end

    case result do
      {:ok, ref} -> {ref, budget - 1}
      {:error, reason} -> {error(reason, data, mime), budget - 1}
    end
  catch
    :exit, _ -> {error(:media_cache_unavailable, data, mime), budget - 1}
  end

  defp mime(value) when is_binary(value) and byte_size(value) <= 128 do
    value = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    if Regex.match?(~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/, value),
      do: value,
      else: "application/octet-stream"
  end

  defp mime(_), do: "application/octet-stream"

  defp error(reason, data, mime),
    do: %{
      "type" => "mcp_media_error",
      "reason" => Atom.to_string(reason),
      "encoded_bytes" => if(is_binary(data), do: byte_size(data), else: nil),
      "mimeType" => mime,
      "visible" => false
    }

  @doc "Return small canonical metadata; no bytes/base64 or arbitrary file path."
  def info(ref), do: safely(fn -> Vega.MCP.Media.Cache.info(id(ref)) end)
  @doc "Page cached reference metadata (default 20, max 50); payloads are never returned."
  def page(opts \\ [])

  def page(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and is_integer(Keyword.get(opts, :offset, 0)) and
         is_integer(Keyword.get(opts, :limit, 20)) do
      safely(fn -> Vega.MCP.Media.Cache.page(opts) end)
    else
      {:error, :invalid_media_page}
    end
  end

  def page(_), do: {:error, :invalid_media_page}
  def delete(ref), do: safely(fn -> Vega.MCP.Media.Cache.delete(id(ref)) end)

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :invalid_media_request}
  catch
    :exit, _ -> {:error, :media_cache_unavailable}
  end

  defp id(%{"type" => "mcp_media_ref", "id" => id}), do: id
  defp id(id) when is_binary(id), do: id
  defp id(_), do: nil

  @doc "Explicit pixel verification/import and native vision intent, via Vega.Images only."
  def view_image(ref) do
    if Code.ensure_loaded?(Vega.Images) do
      with {:ok, path, canonical} <- Vega.MCP.Media.Cache.open_image(id(ref)),
           {:ok, image_ref} <- apply(Vega.Images, :import_file, [path]),
           true <-
             image_ref["mime"] == canonical["mimeType"] and
               image_ref["id"] == canonical["_native_id"] do
        apply(Vega.Images, :view, [image_ref])
      else
        false -> {:error, :image_mime_or_content_mismatch}
        error -> error
      end
    else
      {:error, :images_unavailable}
    end
  rescue
    _ -> {:error, :images_reference_view_unavailable}
  catch
    :exit, _ -> {:error, :media_cache_unavailable}
  end
end

defmodule Vega.MCP.Media.Cache do
  @moduledoc false
  use GenServer
  @max_file 3_750_000
  @max_bytes 64_000_000
  @max_files 128
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def root, do: Path.join(Vega.MCP.State.directory(), "media")

  def init(_) do
    with :ok <- File.mkdir_p(root()), :ok <- File.chmod(root(), 0o700) do
      {:ok, scan()}
    else
      {:error, reason} -> {:stop, {:media_directory, reason}}
    end
  end

  def store(bytes, mime, kind), do: GenServer.call(__MODULE__, {:store, bytes, mime, kind})
  def info(id), do: GenServer.call(__MODULE__, {:info, id})
  def page(opts), do: GenServer.call(__MODULE__, {:page, opts})
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
  def open_image(id), do: GenServer.call(__MODULE__, {:open_image, id})

  defp digest(bytes, mime, kind),
    do:
      :crypto.hash(:sha256, ["mcp-media-v1\n", kind, "\n", mime, "\n", bytes])
      |> Base.encode16(case: :lower)

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)

  def handle_call({:store, bytes, mime, kind}, _, s) do
    id = digest(bytes, mime, kind)
    size = byte_size(bytes)

    cond do
      Map.has_key?(s.refs, id) ->
        {:reply, lookup(s, id), s}

      size > @max_file or size == 0 ->
        {:reply, {:error, :payload_too_large_or_empty}, s}

      s.files >= @max_files or s.bytes + size > @max_bytes ->
        {:reply, {:error, :media_cache_quota}, s}

      true ->
        ref = %{
          "type" => "mcp_media_ref",
          "id" => id,
          "mimeType" => mime,
          "kind" => kind,
          "bytes" => size,
          "verification" => "deferred",
          "visible" => false
        }

        case write(id, bytes, ref) do
          :ok ->
            {:reply, {:ok, ref},
             %{s | refs: Map.put(s.refs, id, ref), files: s.files + 1, bytes: s.bytes + size}}

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end
    end
  end

  def handle_call({:info, id}, _, s), do: {:reply, lookup(s, id), s}

  def handle_call({:page, opts}, _, s) do
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = Keyword.get(opts, :limit, 20) |> max(1) |> min(50)
    refs = s.refs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    page = Enum.slice(refs, offset, limit)
    next = if offset + length(page) < length(refs), do: offset + length(page), else: nil

    {:reply,
     {:ok,
      %{
        refs: page,
        next_offset: next,
        files: s.files,
        bytes: s.bytes,
        max_files: @max_files,
        max_bytes: @max_bytes
      }}, s}
  end

  def handle_call({:delete, id}, _, s) do
    if valid_id?(id) and Map.has_key?(s.refs, id) do
      ref = s.refs[id]

      case File.rm(Path.join(root(), id)) do
        :ok ->
          File.rm(Path.join(root(), id <> ".json"))

          {:reply, :ok,
           %{s | refs: Map.delete(s.refs, id), files: s.files - 1, bytes: s.bytes - ref["bytes"]}}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    else
      {:reply, {:error, :unknown_media}, s}
    end
  end

  def handle_call({:open_image, id}, _, s) do
    result =
      with {:ok, ref} <- lookup(s, id),
           true <- ref["kind"] == "image",
           {:ok, bytes} <- File.read(Path.join(root(), id)),
           true <- digest(bytes, ref["mimeType"], ref["kind"]) == id do
        {:ok, Path.join(root(), id),
         Map.put(ref, "_native_id", :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))}
      else
        false -> {:error, :not_image_or_corrupt_media}
        _ -> {:error, :unknown_or_corrupt_media}
      end

    {:reply, result, s}
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_request}, s}
  def handle_cast(_, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  def format_status(status),
    do: Vega.MCP.Redact.status(status, Map.take(status.state, [:files, :bytes]))

  def terminate(reason, _), do: Vega.MCP.Redact.terminate(reason, :media_cache)

  defp lookup(s, id) do
    with true <- valid_id?(id),
         {:ok, ref} <- Map.fetch(s.refs, id),
         {:ok, stat} <- File.lstat(Path.join(root(), id)),
         true <- stat.type == :regular and stat.size == ref["bytes"] and stat.size <= @max_file do
      {:ok, ref}
    else
      _ -> {:error, :unknown_or_corrupt_media}
    end
  end

  defp write(id, bytes, ref) do
    path = Path.join(root(), id)
    # Exclusive creation never follows/removes pre-existing entries. The private
    # directory protects the initially empty inode; chmod happens before raw data.
    with :ok <- private_file(path, bytes) do
      case private_file(path <> ".json", Jason.encode!(ref)) do
        :ok ->
          :ok

        {:error, _} ->
          File.rm(path)
          {:error, :media_storage_failed}
      end
    end
  end

  defp private_file(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, bytes)
        File.close(io)

        case result do
          :ok ->
            :ok

          _ ->
            File.rm(path)
            {:error, :media_storage_failed}
        end

      {:error, _} ->
        {:error, :media_storage_failed}
    end
  end

  defp scan do
    files =
      case File.ls(root()) do
        {:ok, files} -> files
        _ -> []
      end

    Enum.reduce(files, %{refs: %{}, files: 0, bytes: 0}, fn id, s ->
      if valid_id?(id) do
        case File.lstat(Path.join(root(), id)) do
          {:ok, %{type: :regular, size: size}} ->
            ref =
              with true <- size <= @max_file,
                   {:ok, stat} <- File.lstat(Path.join(root(), id <> ".json")),
                   true <- stat.type == :regular and stat.size <= 1024,
                   {:ok, json} <- File.read(Path.join(root(), id <> ".json")),
                   {:ok, %{"type" => "mcp_media_ref", "id" => ^id, "bytes" => ^size} = ref} <-
                     Jason.decode(json),
                   true <- ref["kind"] in ["image", "binary"],
                   mime when is_binary(mime) <- ref["mimeType"],
                   true <- byte_size(mime) <= 128,
                   true <- Regex.match?(~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/, mime),
                   true <-
                     ref["kind"] != "image" or
                       mime in ["image/png", "image/jpeg", "image/gif", "image/webp"],
                   do: ref

            ref =
              if is_map(ref),
                do:
                  Map.take(ref, ["type", "id", "bytes", "mimeType", "kind"])
                  |> Map.put("visible", false)
                  |> Map.put("verification", "deferred"),
                else: nil

            refs =
              if is_map(ref) and map_size(s.refs) < @max_files,
                do: Map.put(s.refs, id, ref),
                else: s.refs

            %{s | refs: refs, files: s.files + 1, bytes: s.bytes + size}

          _ ->
            s
        end
      else
        s
      end
    end)
  end
end
