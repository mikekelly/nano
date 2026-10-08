defmodule Memory do
  @moduledoc """
  Durable JSON memory, shared by agents and bot sessions. Owners and keys are nonempty
  strings; an owner may be an agent name or a bot identity. Reads are lock-free snapshots;
  writes are serialized per owner on this node and atomically rename a synced file.
  `root:` isolates stores (default `/data/memory`). Do not share a root across BEAM nodes.

      Memory.put("researcher", "preference", %{"style" => "brief"})
      Memory.get("researcher", "preference")
      Memory.update("researcher", "count", 0, fn n -> {:ok, n + 1} end)

  Results: `{:ok, value}`, `{:error, reason}`; delete returns `:ok`. Missing keys return
  `{:error, :not_found}`. `list/2` returns the owner's entire map (bounded to 1 MB on disk).
  `update/5` callbacks run under the owner lock: keep them fast, never call Memory writes
  recursively, and return `{:ok, new_value}` or `{:error, reason}`. JSON round-tripping
  normalizes atom map keys to strings. Secrets should not be placed in shared memory.
  """
  @max_bytes 1_000_000
  def get(owner, key, opts \\ []) do
    with :ok <- name(key), {:ok, data} <- list(owner, opts) do
      Map.fetch(data, key)
      |> case do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end
  end

  def list(owner, opts \\ []) do
    with {:ok, path} <- path(owner, opts), do: read(path)
  end

  def put(owner, key, value, opts \\ []),
    do: update(owner, key, nil, fn _ -> {:ok, value} end, opts)

  def update(owner, key, initial, fun, opts \\ []) when is_function(fun, 1) do
    with :ok <- name(key), {:ok, path} <- path(owner, opts) do
      :global.trans(
        {{__MODULE__, path}, self()},
        fn ->
          with {:ok, data} <- read(path),
               {:ok, value} <- fun.(Map.get(data, key, initial)),
               {:ok, encoded} <- encode(Map.put(data, key, value)),
               :ok <- write(path, encoded) do
            {:ok, Jason.decode!(encoded)[key]}
          end
        end,
        [node()]
      )
    end
  end

  def delete(owner, key, opts \\ []) do
    with :ok <- name(key), {:ok, path} <- path(owner, opts) do
      :global.trans(
        {{__MODULE__, path}, self()},
        fn ->
          with {:ok, data} <- read(path),
               {:ok, encoded} <- encode(Map.delete(data, key)),
               :ok <- write(path, encoded),
               do: :ok
        end,
        [node()]
      )
    end
  end

  @doc "Default memory directory alongside the node state directory (isolated in tests)."
  def default_root(),
    do:
      Application.get_env(:nano, :state_dir, "/data/state")
      |> Path.dirname()
      |> Path.join("memory")

  defp name(value) when is_binary(value) and byte_size(value) in 1..512, do: :ok
  defp name(_), do: {:error, :invalid_name}

  defp path(owner, opts) do
    with :ok <- name(owner) do
      hash = Base.encode16(:crypto.hash(:sha256, owner), case: :lower)
      {:ok, Path.expand(Path.join(Keyword.get(opts, :root, default_root()), hash <> ".json"))}
    end
  end

  defp read(path) do
    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %{size: size}} when size > @max_bytes ->
        {:error, :memory_too_large}

      {:ok, _} ->
        with {:ok, text} <- File.read(path), {:ok, data} <- Jason.decode(text) do
          if is_map(data), do: {:ok, data}, else: {:error, :invalid_memory}
        end

      error ->
        error
    end
  end

  defp encode(data) do
    case Jason.encode(data) do
      {:ok, text} when byte_size(text) <= @max_bytes -> {:ok, text}
      {:ok, _} -> {:error, :memory_too_large}
      {:error, _} -> {:error, :not_json_encodable}
    end
  end

  defp write(path, text) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, text, [:binary, :sync]),
           :ok <- File.rename(tmp, path),
           do: :ok
    after
      File.rm(tmp)
    end
  end
end
