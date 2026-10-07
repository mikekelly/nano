defmodule Vega.Memory do
  @moduledoc """
  Disk-backed memories per named identity. `put(identity, content, provenance: %{...}, tags: [...])`
  records explicit provenance, timestamps and revision. `retrieve(identity, query, limit: 5,
  max_bytes: 8000)` is bounded lexical retrieval, NOT semantic inference. Empty query
  returns most recently updated memories. Updates replace fields; delete permanently removes
  an entry. All functions return {:ok, value}/{:error, reason}. `root:` defaults /data/vega.
  """
  alias Vega.Store

  def put(identity, content, opts \\ []) do
    Store.transact("memory", identity, opts, fn entries ->
      entry = %{
        "id" => Store.id(),
        "content" => content,
        "tags" => Keyword.get(opts, :tags, []),
        "provenance" => Keyword.get(opts, :provenance, %{}),
        "created_at" => Store.now(),
        "updated_at" => Store.now(),
        "revision" => 1
      }

      with :ok <- validate(entry), do: {:ok, entry, entries ++ [entry]}
    end)
  end

  def list(identity, opts \\ []), do: Store.read("memory", identity, opts)

  def get(identity, id, opts \\ []) do
    with {:ok, entries} <- list(identity, opts) do
      case Enum.find(entries, &(&1["id"] == id)) do
        nil -> {:error, :not_found}
        e -> {:ok, e}
      end
    end
  end

  def update(identity, id, attrs, opts \\ []) do
    attrs = Store.attrs(attrs)

    Store.transact("memory", identity, opts, fn entries ->
      with true <- Enum.all?(Map.keys(attrs), &(&1 in ~w(content tags provenance))),
           %{} = old <- Enum.find(entries, &(&1["id"] == id)),
           next =
             old
             |> Map.merge(attrs)
             |> Map.put("updated_at", Store.now())
             |> Map.put("revision", old["revision"] + 1),
           :ok <- validate(next) do
        {:ok, next, Enum.map(entries, fn e -> if e["id"] == id, do: next, else: e end)}
      else
        false -> {:error, :invalid_fields}
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def delete(identity, id, opts \\ []) do
    Store.transact("memory", identity, opts, fn entries ->
      if Enum.any?(entries, &(&1["id"] == id)),
        do: {:ok, :deleted, Enum.reject(entries, &(&1["id"] == id))},
        else: {:error, :not_found}
    end)
  end

  @doc "Rank by unique query-word overlap, then recency. Entire records fit within JSON byte budget."
  def retrieve(identity, query, opts \\ []) when is_binary(query) do
    with {:ok, entries} <- list(identity, opts) do
      terms = words(query)
      limit = Keyword.get(opts, :limit, 5) |> max(0) |> min(50)
      budget = Keyword.get(opts, :max_bytes, 8000) |> max(2) |> min(100_000)

      ranked =
        entries
        |> Enum.map(fn e ->
          corpus = words(e["content"] <> " " <> Enum.join(e["tags"], " "))
          {e, MapSet.intersection(terms, corpus) |> MapSet.size()}
        end)
        |> Enum.filter(fn {_, score} -> MapSet.size(terms) == 0 or score > 0 end)
        |> Enum.sort_by(fn {e, score} -> {score, e["updated_at"], e["id"]} end, :desc)

      {selected, _} =
        Enum.reduce(ranked, {[], 2}, fn {e, _}, {selected, used} ->
          size = byte_size(Jason.encode!(e)) + if(selected == [], do: 0, else: 1)

          if length(selected) < limit and used + size <= budget,
            do: {selected ++ [e], used + size},
            else: {selected, used}
        end)

      {:ok, selected}
    end
  end

  defp words(text),
    do: Regex.scan(~r/[\p{L}\p{N}_]+/u, String.downcase(text)) |> List.flatten() |> MapSet.new()

  defp validate(e) do
    cond do
      not Store.text?(e["content"], 32_000) or String.trim(e["content"]) == "" ->
        {:error, :invalid_content}

      not is_list(e["tags"]) or length(e["tags"]) > 32 or
          not Enum.all?(e["tags"], &Store.text?(&1, 100)) ->
        {:error, :invalid_tags}

      not is_map(e["provenance"]) ->
        {:error, :invalid_provenance}

      true ->
        case Jason.encode(e["provenance"]) do
          {:ok, data} when byte_size(data) <= 8000 -> :ok
          _ -> {:error, :invalid_provenance}
        end
    end
  end
end
