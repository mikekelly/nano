defmodule Seedling.Web.Cache do
  @moduledoc "Disk cache: one-hour TTL, 100 entries, immutable SHA256 ids. Options: :cache_dir, :ttl."
  def dir(opts), do: Keyword.get(opts, :cache_dir, "/data/seedling-web-cache")

  def put(text, meta \\ %{}, opts \\ []) when is_binary(text) do
    root = dir(opts)
    File.mkdir_p!(root)
    id = :crypto.hash(:sha256, Jason.encode!(meta) <> text) |> Base.encode16(case: :lower)
    path = Path.join(root, id <> ".json")
    tmp = path <> "." <> Integer.to_string(System.unique_integer([:positive]))

    File.write!(
      tmp,
      Jason.encode!(%{text: text, meta: meta, created: System.system_time(:second)})
    )

    File.rename!(tmp, path)

    root
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort_by(fn p -> File.stat!(p).mtime end, :desc)
    |> Enum.drop(100)
    |> Enum.each(&File.rm/1)

    root
    |> Path.join("url-*")
    |> Path.wildcard()
    |> Enum.sort_by(fn p -> File.stat!(p).mtime end, :desc)
    |> Enum.drop(100)
    |> Enum.each(&File.rm/1)

    {:ok, id}
  rescue
    e -> {:error, {:cache, Exception.message(e)}}
  end

  def get(id, opts \\ []) do
    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id) do
      with {:ok, raw} <- File.read(Path.join(dir(opts), id <> ".json")),
           {:ok, entry} <- Jason.decode(raw) do
        if System.system_time(:second) - entry["created"] <= Keyword.get(opts, :ttl, 3600),
          do: {:ok, entry},
          else: {:error, :cache_expired}
      end
    else
      {:error, :invalid_id}
    end
  end
end
