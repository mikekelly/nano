defmodule Nano.Memory do
  @moduledoc """
  Durable, named knowledge by agent. Explicit recall, not hidden prompt injection.

      Nano.Memory.put("alice", "release-check", "Run the smoke test", why: "Caught a regression", tags: ["release"])
      Nano.Memory.get("alice", "release-check")
      Nano.Memory.review("alice", query: "release", limit: 5)

  Entries preserve creation time on replacement. `review/2` searches key, text,
  rationale and tags case-insensitively, newest first, returning bounded excerpts.
  All calls accept `root: path`; default `/data/nano-library`.
  """
  alias Nano.DurableStore, as: Store

  def put(owner, key, text, opts \\ []) do
    why = Keyword.get(opts, :why, "")
    tags = Keyword.get(opts, :tags, [])

    if Store.text?(key, 200) and Store.text?(text, 32_000) and is_binary(why) and
         String.valid?(why) and byte_size(why) <= 8000 and is_list(tags) and length(tags) <= 20 and
         Enum.all?(tags, &Store.text?(&1, 100)) do
      Store.transact("memory", owner, opts, fn entries ->
        old = Map.get(entries, key, %{})

        entry = %{
          "key" => key,
          "text" => text,
          "why" => why,
          "tags" => tags,
          "created_at" => Map.get(old, "created_at", Store.now()),
          "updated_at" => Store.now()
        }

        {:ok, Map.put(entries, key, entry), entry}
      end)
    else
      {:error, :invalid_memory}
    end
  end

  def get(owner, key, opts \\ []) do
    with {:ok, entries} <- Store.read("memory", owner, opts) do
      case Map.fetch(entries, key) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, :not_found}
      end
    end
  end

  def forget(owner, key, opts \\ []) do
    Store.transact("memory", owner, opts, fn entries ->
      if Map.has_key?(entries, key),
        do: {:ok, Map.delete(entries, key), :deleted},
        else: {:error, :not_found}
    end)
  end

  def review(owner, opts \\ []) do
    query = Keyword.get(opts, :query, "")

    if is_binary(query) and String.valid?(query) do
      with {:ok, limit} <- Store.limit(opts, 8),
           {:ok, entries} <- Store.read("memory", owner, opts) do
        query = String.downcase(query)

        matches =
          entries
          |> Map.values()
          |> Enum.filter(fn e ->
            String.contains?(
              String.downcase(Enum.join([e["key"], e["text"], e["why"] | e["tags"]], "\n")),
              query
            )
          end)
          |> Enum.sort_by(&{&1["updated_at"], &1["key"]}, :desc)

        excerpts =
          matches
          |> Enum.take(limit)
          |> Enum.map(fn e ->
            Map.take(e, ~w(key tags updated_at))
            |> Map.merge(%{
              "text" => Store.clip(e["text"], 320),
              "why" => Store.clip(e["why"], 160)
            })
          end)

        {:ok,
         %{memories: excerpts, total: length(matches), omitted: max(length(matches) - limit, 0)}}
      end
    else
      {:error, :invalid_query}
    end
  end
end
