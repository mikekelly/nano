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
    with {:ok, path} <- path(kind, identity, opts), do: load(path)
  end

  def transact(kind, identity, opts, fun) do
    with {:ok, path} <- path(kind, identity, opts) do
      :global.trans(
        {{__MODULE__, Path.expand(path)}, self()},
        fn ->
          with {:ok, entries} <- load(path),
               {:ok, result, next} <- fun.(entries),
               :ok <- save(path, next),
               do: {:ok, result}
        end,
        [node()]
      )
    end
  end

  defp load(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %{size: size}} when size <= @max_bytes ->
        with {:ok, data} <- File.read(path),
             {:ok, %{"version" => 1, "entries" => entries}} <- Jason.decode(data),
             true <- is_list(entries) and Enum.all?(entries, &is_map/1),
             do: {:ok, entries},
             else: (_ -> {:error, :corrupt_store})

      {:ok, _} ->
        {:error, :store_too_large}

      {:error, reason} ->
        {:error, reason}
    end
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
