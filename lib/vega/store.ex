defmodule Vega.Store do
  @moduledoc false
  @max_bytes 4_000_000
  def path(kind, identity, opts) when is_binary(identity) and byte_size(identity) in 1..256 do
    {:ok,
     Path.join([
       Keyword.get(opts, :root, "/data/vega"),
       kind,
       Base.url_encode64(identity, padding: false) <> ".json"
     ])}
  end

  def path(_, _, _), do: {:error, :invalid_identity}

  def read(kind, identity, opts) do
    with {:ok, path} <- path(kind, identity, opts), do: load(path, kind)
  end

  def transact(kind, identity, opts, fun) do
    with {:ok, path} <- path(kind, identity, opts) do
      :global.trans(
        {{__MODULE__, Path.expand(path)}, self()},
        fn ->
          with {:ok, entries} <- load(path, kind),
               {:ok, result, next} <- fun.(entries),
               :ok <- save(path, next),
               do: {:ok, result}
        end,
        [node()]
      )
    end
  end

  defp load(path, kind) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %{size: size}} when size <= @max_bytes ->
        with {:ok, data} <- File.read(path),
             {:ok, %{"version" => 1, "entries" => entries}} <- Jason.decode(data),
             true <- is_list(entries) and valid_entries?(kind, entries),
             do: {:ok, entries},
             else: (_ -> {:error, :corrupt_store})

      {:ok, _} ->
        {:error, :store_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_entries?(kind, entries) do
    Enum.all?(entries, fn e ->
      is_map(e) and text?(e["id"], 256) and e["id"] != "" and
        text?(e["created_at"], 100) and text?(e["updated_at"], 100) and valid_record?(kind, e)
    end) and length(Enum.uniq_by(entries, & &1["id"])) == length(entries) and
      valid_links?(kind, entries)
  end

  defp valid_record?("goals", e) do
    text?(e["title"], 1000) and String.trim(e["title"]) != "" and text?(e["why"], 8000) and
      e["status"] in ~w(pending active blocked done cancelled) and
      (is_nil(e["parent_id"]) or text?(e["parent_id"], 256))
  end

  defp valid_record?("memory", e) do
    text?(e["content"], 32_000) and String.trim(e["content"]) != "" and is_list(e["tags"]) and
      length(e["tags"]) <= 32 and Enum.all?(e["tags"], &text?(&1, 100)) and
      is_map(e["provenance"]) and
      is_integer(e["revision"]) and e["revision"] > 0
  end

  defp valid_record?(_, _), do: false

  defp valid_links?("goals", entries) do
    parents = Map.new(entries, &{&1["id"], &1["parent_id"]})
    Enum.all?(entries, &acyclic?(&1["id"], parents, MapSet.new()))
  end

  defp valid_links?(_, _), do: true
  defp acyclic?(nil, _, _), do: true

  defp acyclic?(id, parents, seen) do
    not MapSet.member?(seen, id) and Map.has_key?(parents, id) and
      acyclic?(parents[id], parents, MapSet.put(seen, id))
  end

  defp save(path, entries) do
    with {:ok, data} <- Jason.encode(%{version: 1, entries: entries}),
         true <- byte_size(data) <= @max_bytes,
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> "." <> id() <> ".tmp"
      result = with :ok <- File.write(tmp, data, [:binary, :sync]), do: File.rename(tmp, path)
      File.rm(tmp)
      result
    else
      false -> {:error, :store_too_large}
      error -> error
    end
  end

  def id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def text?(value, max), do: is_binary(value) and String.valid?(value) and byte_size(value) <= max

  def attrs(attrs) when is_map(attrs) or is_list(attrs),
    do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
