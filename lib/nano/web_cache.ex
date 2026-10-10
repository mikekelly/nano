defmodule Nano.Web.Cache do
  @moduledoc false
  def lookup(key, opts) do
    locked(opts, fn dir ->
      entries(dir)
      |> Enum.map(&load/1)
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(&1["key"] == key))
      |> Enum.max_by(& &1["created_ms"], fn -> nil end)
      |> then(&{:ok, &1})
    end)
  end

  def get(id, opts) do
    if not is_binary(id) or not Regex.match?(~r/^[a-f0-9]{64}$/, id),
      do: raise(ArgumentError, "invalid web snapshot id")

    locked(opts, fn dir ->
      case load(Path.join(dir, id <> ".json")) do
        %{} = entry -> {:ok, entry}
        _ -> {:error, "snapshot missing, expired or evicted; fetch its URL again"}
      end
    end)
  end

  def put(key, doc, opts) do
    locked(opts, fn dir ->
      sha = hash(doc["text"])
      id = hash(key <> sha <> Integer.to_string(doc["created_ms"]))
      entry = Map.merge(doc, %{"id" => id, "key" => key, "content_sha256" => sha})
      json = Jason.encode!(entry)

      if byte_size(json) > positive(opts, :max_cache_bytes, 32_000_000),
        do: raise("document exceeds cache byte quota")

      path = Path.join(dir, id <> ".json")
      File.write!(path <> ".tmp", json)
      File.rename!(path <> ".tmp", path)
      prune(dir, opts)
      {:ok, entry}
    end)
  end

  defp locked(opts, fun) do
    dir =
      Path.expand(
        Keyword.get(opts, :cache_dir, System.get_env("NANO_WEB_CACHE_DIR") || "/data/web")
      )

    File.mkdir_p!(dir)

    :global.trans({{__MODULE__, dir}, self()}, fn ->
      prune(dir, opts)
      fun.(dir)
    end)
  end

  defp prune(dir, opts) do
    ttl = positive(opts, :ttl, 3_600_000)
    quota = positive(opts, :max_cache_bytes, 32_000_000)
    count = positive(opts, :max_entries, 128)
    now = System.system_time(:millisecond)
    # Abandoned fetch workspaces from a killed eval are reclaimed after two minutes.
    for path <- Path.wildcard(Path.join(dir, "work-*")) ++ Path.wildcard(Path.join(dir, "*.tmp")) do
      case File.stat(path, time: :posix) do
        {:ok, stat} when now - stat.mtime * 1000 > 120_000 -> File.rm_rf(path)
        _ -> :ok
      end
    end

    live =
      entries(dir)
      |> Enum.flat_map(fn path ->
        case load(path) do
          %{"created_ms" => created} when is_integer(created) ->
            if now - created >= ttl do
              File.rm(path)
              []
            else
              [{path, created, File.stat!(path).size}]
            end

          _ ->
            File.rm(path)
            []
        end
      end)
      |> Enum.sort_by(fn {path, time, _} -> {time, path} end, :desc)

    Enum.reduce(live, {0, 0}, fn {path, _, size}, {n, bytes} ->
      if n + 1 > count or bytes + size > quota do
        File.rm(path)
        {n, bytes}
      else
        {n + 1, bytes + size}
      end
    end)
  end

  defp entries(dir), do: Path.wildcard(Path.join(dir, "*.json"))

  defp load(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"id" => _, "text" => text} = e} <- Jason.decode(bytes),
         true <- is_binary(text),
         true <- hash(text) == e["content_sha256"],
         do: e,
         else: (_ -> nil)
  end

  defp positive(opts, key, default) do
    n = Keyword.get(opts, key, default)
    if not is_integer(n) or n <= 0, do: raise(ArgumentError, "#{key} must be a positive integer")
    n
  end

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
