defmodule Seedling.Web.Store do
  @moduledoc false
  @root "/data/orion-web/cache"

  def root(opts), do: Keyword.get(opts, :cache_dir, @root)
  def id(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  def put(key, text, metadata, opts \\ []) when is_binary(text) do
    dir = root(opts)
    id = id(key)

    record =
      Map.merge(metadata, %{
        "id" => id,
        "text" => text,
        "stored_at" => System.system_time(:second)
      })

    path = Path.join(dir, id <> ".json")
    tmp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Jason.encode!(record)),
         :ok <- File.rename(tmp, path) do
      prune(opts, path)
      {:ok, record}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, %{kind: :cache, reason: reason}}
    end
  end

  def get(id, opts \\ []) do
    with true <- is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id),
         {:ok, raw} <- File.read(Path.join(root(opts), id <> ".json")),
         {:ok, record} <- Jason.decode(raw),
         true <- is_binary(record["text"]) and is_integer(record["stored_at"]) do
      ttl = Keyword.get(opts, :ttl, 3600)

      if System.system_time(:second) - record["stored_at"] <= ttl,
        do: {:ok, record},
        else: {:error, %{kind: :cache_expired, id: id}}
    else
      _ -> {:error, %{kind: :cache_miss, id: id}}
    end
  end

  def page(record, opts \\ []) do
    text = record["text"]
    total = String.length(text)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 6000)
    bytes = Keyword.get(opts, :max_bytes, 12000)

    if is_integer(offset) and offset >= 0 and offset <= total and
         is_integer(limit) and limit > 0 and is_integer(bytes) and bytes >= 4 do
      part = text |> String.slice(offset, min(limit, 12000)) |> clip_graphemes(min(bytes, 24000))
      next = offset + String.length(part)

      if part == "" and offset < total do
        {:error,
         %{kind: :oversized_grapheme, hint: "Increase max_bytes to fit the next character"}}
      else
        {:ok,
         %{
           id: record["id"],
           url: bounded(record["url"], 2000),
           title: bounded(record["title"], 500),
           source: record["source"],
           fetched_at: record["stored_at"],
           text: part,
           offset: offset,
           next_offset: if(next < total, do: next, else: nil),
           total_characters: total,
           returned_bytes: byte_size(part),
           truncated: next < total,
           content_truncated: record["content_truncated"] || false,
           metadata_truncated:
             (is_binary(record["url"]) and byte_size(record["url"]) > 2000) or
               (is_binary(record["title"]) and byte_size(record["title"]) > 500)
         }}
      end
    else
      {:error,
       %{
         kind: :invalid_page,
         total_characters: total,
         hint: "offset is zero-based characters; limit > 0, max_bytes >= 4"
       }}
    end
  end

  def clip(text, bytes) when is_binary(text) and is_integer(bytes) and bytes >= 0 do
    if byte_size(text) <= bytes do
      text
    else
      prefix = binary_part(text, 0, bytes)
      valid_prefix(prefix)
    end
  end

  defp bounded(text, bytes) when is_binary(text), do: clip(text, bytes)
  defp bounded(_, _), do: nil

  defp clip_graphemes(text, bytes) do
    {chunks, _} =
      Enum.reduce_while(String.graphemes(text), {[], 0}, fn chunk, {acc, n} ->
        if n + byte_size(chunk) <= bytes,
          do: {:cont, {[chunk | acc], n + byte_size(chunk)}},
          else: {:halt, {acc, n}}
      end)

    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end

  defp prune(opts, current) do
    max = Keyword.get(opts, :cache_entries, 100) |> max(1)

    Path.wildcard(Path.join(root(opts), "*.json"))
    |> Enum.map(fn path ->
      {path,
       case File.stat(path, time: :posix) do
         {:ok, s} -> s.mtime
         _ -> 0
       end}
    end)
    |> Enum.sort_by(fn {path, mtime} -> {path == current, mtime} end, :desc)
    |> Enum.drop(max)
    |> Enum.each(fn {path, _} -> File.rm(path) end)
  end
end
