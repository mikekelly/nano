defmodule Seedling.DurableStore do
  @moduledoc """
  Small JSON documents with atomic replacement and a non-blocking dashboard cache.

  `read/4` and `update/5` serialize disk work in a lazily started, unlinked server.
  Successful writes alone update the cache. `peek/3` only reads ETS; on a cold
  cache it requests an asynchronous load and returns `:loading`. Nothing calls
  an agent process. Documents live beneath `state_dir/seedling` by default;
  `root: path` isolates a caller or a test. Names are hashed, never used as paths.

  This is a single-node store (not a distributed database). External file edits
  require `refresh: true`. The server can be supervised using `start_link/1`.
  Invalid JSON and oversized files are reported, never silently overwritten.
  """
  use GenServer
  @table __MODULE__
  @max_bytes 8_000_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reads a document, or the supplied default when no file exists."
  def read(kind, name, default, opts \\ []) do
    with {:ok, key} <- key(kind, name, opts), :ok <- ensure_started() do
      GenServer.call(__MODULE__, {:read, key, default, opts[:refresh] == true}, 30_000)
    end
  end

  @doc "Runs `fun.(document) -> {:ok, new_document, result} | {:error, reason}` atomically."
  def update(kind, name, default, fun, opts \\ []) do
    with {:ok, key} <- key(kind, name, opts), :ok <- ensure_started() do
      GenServer.call(__MODULE__, {:update, key, default, fun}, 30_000)
    end
  end

  @doc "Returns a cached read result or `:loading`, without doing disk IO."
  def peek(kind, name, opts \\ []) do
    with {:ok, key} <- key(kind, name, opts), :ok <- ensure_started() do
      case :ets.lookup(@table, key) do
        [{_, result}] ->
          result

        [] ->
          if :ets.insert_new(@table, {key, :loading}),
            do: GenServer.cast(__MODULE__, {:warm, key})

          :loading
      end
    end
  rescue
    ArgumentError -> :loading
  end

  @doc "Document path, useful for backup or inspection."
  def path(kind, name, opts \\ []) do
    with {:ok, {root, kind, hash}} <- key(kind, name, opts),
         do: {:ok, Path.join([root, kind, hash <> ".json"])}
  end

  defp key(kind, name, opts) when is_binary(kind) and is_binary(name) do
    if Regex.match?(~r/\A[a-z_]+\z/, kind) and byte_size(name) in 1..512 do
      root = opts[:root] || Path.join(Application.fetch_env!(:nano, :state_dir), "seedling")
      {:ok, {Path.expand(root), kind, Base.encode16(:crypto.hash(:sha256, name), case: :lower)}}
    else
      {:error, :invalid_name}
    end
  end

  defp key(_, _, _), do: {:error, :invalid_name}

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:read, key, default, refresh}, _from, state) do
    {:reply, load(key, default, refresh), state}
  end

  def handle_call({:update, key, default, fun}, _from, state) do
    result =
      with {:ok, doc} <- load(key, default, false) do
        case safe_update(fun, doc) do
          {:ok, ^doc, result} ->
            {:ok, result}

          {:ok, new, result} ->
            with :ok <- save(key, new) do
              :ets.insert(@table, {key, {:ok, new}})
              {:ok, result}
            end

          {:error, _} = error ->
            error
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:warm, key}, state) do
    load(key, nil, true)
    {:noreply, state}
  end

  defp load(key, default, refresh) do
    result =
      case if(refresh, do: [], else: :ets.lookup(@table, key)) do
        [{_, {:ok, nil}}] -> {:ok, default}
        [{_, {:ok, _} = result}] -> result
        [{_, {:error, _} = result}] -> result
        _ -> disk_read(file(key))
      end

    :ets.insert(@table, {key, result})

    case result do
      {:ok, nil} -> {:ok, default}
      other -> other
    end
  end

  defp disk_read(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_bytes,
         {:ok, bytes} <- File.read(path),
         {:ok, doc} <- Jason.decode(bytes),
         true <- is_map(doc) do
      {:ok, doc}
    else
      {:error, :enoent} -> {:ok, nil}
      false -> {:error, :invalid_document}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp save(key, doc) do
    path = file(key)
    tmp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    result =
      with {:ok, bytes} <- Jason.encode(doc),
           true <- byte_size(bytes) <= @max_bytes,
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, bytes, [:sync]),
           :ok <- File.rename(tmp, path),
           do: :ok

    File.rm(tmp)

    case result do
      :ok -> :ok
      false -> {:error, :document_too_large}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp safe_update(fun, doc) do
    case fun.(doc) do
      {:ok, new, result} when is_map(new) -> {:ok, new, result}
      {:error, _} = error -> error
      _ -> {:error, :invalid_mutation_result}
    end
  rescue
    _ -> {:error, :mutation_failed}
  catch
    _, _ -> {:error, :mutation_failed}
  end

  defp file({root, kind, hash}), do: Path.join([root, kind, hash <> ".json"])
end
