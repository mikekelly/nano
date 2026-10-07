defmodule Nano.DurableStore do
  @moduledoc false
  @max_bytes 2_000_000

  def read(kind, owner, opts) do
    with {:ok, path} <- path(kind, owner, opts) do
      case File.stat(path) do
        {:error, :enoent} ->
          {:ok, %{}}

        {:ok, %{size: size}} when size <= @max_bytes ->
          with {:ok, bytes} <- File.read(path),
               {:ok, %{"version" => 1, "entries" => entries}} when is_map(entries) <-
                 Jason.decode(bytes) do
            if valid_entries?(kind, entries), do: {:ok, entries}, else: {:error, :corrupt_store}
          else
            _ -> {:error, :corrupt_store}
          end

        {:ok, _} ->
          {:error, :store_too_large}

        error ->
          error
      end
    end
  end

  def transact(kind, owner, opts, fun) do
    with {:ok, path} <- path(kind, owner, opts) do
      :global.trans(
        {{__MODULE__, path}, self()},
        fn ->
          with {:ok, entries} <- read(kind, owner, opts),
               {:ok, next, result} <- fun.(entries),
               :ok <- save(path, next) do
            {:ok, result}
          end
        end,
        [node()]
      )
    end
  end

  defp path(kind, owner, opts) when is_binary(owner) and byte_size(owner) in 1..512 do
    root =
      Keyword.get(opts, :root, Application.get_env(:nano, :library_root, "/data/nano-library"))

    if is_binary(root) do
      key = :crypto.hash(:sha256, owner) |> Base.url_encode64(padding: false)
      {:ok, Path.join([Path.expand(root), kind, key <> ".json"])}
    else
      {:error, :invalid_root}
    end
  end

  defp path(_, _, _), do: {:error, :invalid_owner}

  defp save(path, entries) do
    with {:ok, bytes} <- Jason.encode(%{version: 1, entries: entries}) do
      if byte_size(bytes) > @max_bytes do
        {:error, :store_too_large}
      else
        tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"

        try do
          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- write_sync(tmp, bytes),
               :ok <- File.rename(tmp, path) do
            :ok
          end
        after
          File.rm(tmp)
        end
      end
    end
  end

  defp write_sync(path, bytes) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- :file.write(file, bytes), do: :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp valid_entries?(kind, entries) do
    Enum.all?(entries, fn {key, e} ->
      is_binary(key) and is_map(e) and
        Enum.all?(~w(created_at updated_at), &is_binary(e[&1])) and
        case kind do
          "goals" ->
            e["id"] == key and text?(e["title"], 1000) and text?(e["why"]) and
              e["status"] in ~w(open active blocked done cancelled) and is_binary(e["note"]) and
              (is_nil(e["parent"]) or Map.has_key?(entries, e["parent"]))

          "memory" ->
            e["key"] == key and text?(e["text"], 32_000) and is_binary(e["why"]) and
              is_list(e["tags"]) and Enum.all?(e["tags"], &text?(&1, 100))

          _ ->
            false
        end
    end)
  end

  def text?(text, max \\ 8_000),
    do: is_binary(text) and String.valid?(text) and byte_size(text) > 0 and byte_size(text) <= max

  def limit(opts, default) do
    case Keyword.get(opts, :limit, default) do
      n when is_integer(n) -> {:ok, n |> max(0) |> min(50)}
      _ -> {:error, :invalid_limit}
    end
  end

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  def clip(text, max), do: text |> String.slice(0, max)
end
