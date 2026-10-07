defmodule Vega.Web.Cache do
  @moduledoc "Disk-backed, TTL bounded content store used by Web and Search. IDs are sha256; page offsets are Unicode characters (zero based)."
  def root(opts), do: Keyword.get(opts, :cache_dir, "/data/vega/web-cache")
  def id(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  def put(key, text, meta \\ %{}, opts \\ []) do
    dir = root(opts)
    truncated = String.length(text) > Keyword.get(opts, :content_limit, 500_000)
    text = String.slice(text, 0, Keyword.get(opts, :content_limit, 500_000))

    record =
      Map.merge(meta, %{
        id: id(key),
        text: text,
        truncated: truncated,
        fetched_at: System.system_time(:second)
      })

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- prune(opts),
         path = Path.join(dir, record.id <> ".json"),
         tmp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
         :ok <- File.write(tmp, Jason.encode!(record)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      prune(Keyword.put(opts, :keep, path))
      {:ok, record.id}
    end
  rescue
    _ -> {:error, :cache_write_failed}
  end

  def get(id, opts \\ []) do
    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id) do
      with {:ok, data} <- File.read(Path.join(root(opts), id <> ".json")),
           {:ok, rec} <- Jason.decode(data) do
        if System.system_time(:second) - rec["fetched_at"] <= Keyword.get(opts, :ttl, 3600),
          do: {:ok, rec},
          else: {:error, :expired}
      end
    else
      {:error, :invalid_id}
    end
  rescue
    _ -> {:error, :invalid_cache}
  end

  def read(id, opts \\ []) do
    with {:ok, rec} <- get(id, opts) do
      offset = Keyword.get(opts, :offset, 0)
      limit = min(Keyword.get(opts, :limit, 8000), 16000)
      total = String.length(rec["text"])

      if is_integer(offset) and offset >= 0 and offset <= total and is_integer(limit) and
           limit > 0 do
        text = String.slice(rec["text"], offset, limit)
        next = offset + String.length(text)

        {:ok,
         %{
           id: id,
           text: text,
           offset: offset,
           next: if(next < total, do: next),
           total: total,
           source: rec["url"],
           title: rec["title"],
           fetched_at: rec["fetched_at"],
           method: rec["method"],
           truncated: rec["truncated"] || false
         }}
      else
        {:error, {:invalid_page, total}}
      end
    end
  end

  def prune(opts \\ []) do
    now = System.system_time(:second)
    ttl = Keyword.get(opts, :ttl, 3600)

    entries =
      Path.wildcard(Path.join(root(opts), "*.json"))
      |> Enum.flat_map(fn p ->
        case File.stat(p, time: :posix) do
          {:ok, st} ->
            if now - st.mtime > ttl,
              do:
                (
                  File.rm(p)
                  []
                ),
              else: [{p, st}]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(fn {p, st} -> {p == Keyword.get(opts, :keep), st.mtime, p} end, :desc)

    Enum.reduce(entries, {0, 0}, fn {p, st}, {count, bytes} ->
      if count >= Keyword.get(opts, :max_entries, 100) or
           bytes + st.size > Keyword.get(opts, :max_cache_bytes, 20_000_000) do
        File.rm(p)
        {count, bytes}
      else
        {count + 1, bytes + st.size}
      end
    end)

    :ok
  end
end
