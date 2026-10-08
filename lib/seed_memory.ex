defmodule SeedMemory.Store do
  @moduledoc false
  def path(agent, kind, opts) when is_binary(agent) and byte_size(agent) > 0 do
    key = Base.url_encode64(agent, padding: false)
    Path.join([Keyword.get(opts, :root, "/data/seed-memory"), key, kind <> ".json"])
  end

  def read(agent, kind, default, opts) do
    case File.read(path(agent, kind, opts)) do
      {:ok, text} -> Jason.decode(text)
      {:error, :enoent} -> {:ok, default}
      error -> error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def update(agent, kind, default, opts, fun) do
    path = path(agent, kind, opts)

    :global.trans({{__MODULE__, path}, self()}, fn ->
      with {:ok, state} <- read(agent, kind, default, opts),
           {:ok, next, result} <- fun.(state) do
        if next == state, do: {:ok, result}, else: persist(path, next, result)
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp persist(path, next, result) do
    with {:ok, json} <- Jason.encode(next), :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

      try do
        with :ok <- File.write(tmp, json, [:sync]),
             :ok <- File.rename(tmp, path),
             do: {:ok, result}
      after
        File.rm(tmp)
      end
    end
  end

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  def id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  def text(value, max),
    do: is_binary(value) and String.valid?(value) and String.length(value) <= max
end

defmodule SeedMemory do
  @moduledoc """
  Curated durable facts, independent of conversation compaction. Explicit agent names
  make another agent's knowledge readable. No automatic extraction or hidden model calls.
  `put("scout", "build", "Use MIX_ENV=test", why: "Avoid shared prod builds")`;
  `review("scout")` returns a small list; `get("scout", "build")` reveals detail.
  All functions return `{:ok, value}` or `{:error, reason}`. `root:` overrides the
  default /data/seed-memory for isolated tests. Keys replace existing facts deliberately.
  """
  alias SeedMemory.Store

  def put(agent, key, text, opts \\ []) do
    why = Keyword.get(opts, :why, "")

    if Store.text(key, 200) and key != "" and Store.text(text, 8000) and Store.text(why, 2000) do
      Store.update(agent, "memory", %{}, opts, fn state ->
        item = %{"key" => key, "text" => text, "why" => why, "written_at" => Store.now()}
        {:ok, Map.put(state, key, item), item}
      end)
    else
      {:error, :invalid_memory}
    end
  end

  def get(agent, key, opts \\ []) do
    with {:ok, state} <- Store.read(agent, "memory", %{}, opts), do: fetch(state, key)
  end

  def delete(agent, key, opts \\ []) do
    Store.update(agent, "memory", %{}, opts, fn state ->
      {:ok, Map.delete(state, key), :deleted}
    end)
  end

  def review(agent, opts \\ []) do
    with {:ok, state} <- Store.read(agent, "memory", %{}, opts) do
      limit = Keyword.get(opts, :limit, 5) |> max(0) |> min(20)
      items = state |> Map.values() |> Enum.sort_by(& &1["key"])

      {:ok,
       %{
         items:
           Enum.take(items, limit)
           |> Enum.map(&Map.update!(&1, "text", fn t -> String.slice(t, 0, 240) end)),
         total: length(items),
         truncated: length(items) > limit
       }}
    end
  end

  defp fetch(state, key) do
    case Map.fetch(state, key) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, :not_found}
    end
  end
end
