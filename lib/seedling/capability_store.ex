defmodule Seedling.CapabilityStore do
  @moduledoc """
  Small durable JSON documents, with bounded reads and atomic, serialized updates.
  Default root is `<state_dir>/seedling`; pass `root:` for isolated tests/tools.
  Keys are hashed, never interpreted as paths. Errors are returned, never replaced by
  an empty document (a corrupt file must not silently erase an agent's knowledge).
  """
  @max_bytes 4_000_000
  def root(opts),
    do:
      Keyword.get_lazy(opts, :root, fn ->
        Path.join(Application.fetch_env!(:nano, :state_dir), "seedling")
      end)

  def get(kind, key, default, opts \\ []) do
    path = path(kind, key, opts)

    case File.stat(path) do
      {:error, :enoent} ->
        {:ok, default}

      {:ok, %{size: size}} when size <= @max_bytes ->
        with {:ok, data} <- File.read(path), {:ok, value} <- Jason.decode(data), do: {:ok, value}

      {:ok, _} ->
        {:error, :document_too_large}

      error ->
        error
    end
  end

  def update(kind, key, default, fun, opts \\ []) do
    path = path(kind, key, opts)

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, old} <- get(kind, key, default, opts),
           {:ok, new, result} <- fun.(old),
           {:ok, data} <- Jason.encode(new),
           :ok <- bounded(data),
           :ok <- File.mkdir_p(Path.dirname(path)) do
        tmp = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"

        result =
          with :ok <- File.write(tmp, data, [:sync]),
               :ok <- File.rename(tmp, path),
               do: {:ok, result}

        File.rm(tmp)
        result
      end
    end)
  end

  defp bounded(data),
    do: if(byte_size(data) <= @max_bytes, do: :ok, else: {:error, :document_too_large})

  defp path(kind, key, opts) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({kind, key})) |> Base.encode16(case: :lower)

    Path.join(root(opts), hash <> ".json")
  end

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  def agent(pid) when is_pid(pid) do
    Enum.find_value(Nano.Names.all(), fn
      {{:agent, name}, ^pid} -> name
      _ -> nil
    end)
  end

  def agent(name) when is_binary(name), do: name
  def agent(_), do: nil
end
