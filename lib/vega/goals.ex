defmodule Vega.Goals do
  @moduledoc """
  Durable named-agent goals. No process or startup hook required.
  `add("alice", "Ship parser", why: "Unblock imports")`, then `update/4`, `tree/2`,
  `review/2`. Returns {:ok, value}/{:error, reason}; records have string keys.
  `root:` defaults to /data/vega. See docs/vega-goals-memory.md.
  """
  alias Vega.Store
  @statuses ~w(pending active blocked done cancelled)
  @fields ~w(title why status parent_id)
  def add(identity, title, opts \\ []) do
    Store.transact("goals", identity, opts, fn entries ->
      goal = %{
        "id" => Store.id(),
        "title" => title,
        "why" => Keyword.get(opts, :why, ""),
        "status" => Keyword.get(opts, :status, "pending"),
        "parent_id" => Keyword.get(opts, :parent_id),
        "created_at" => Store.now(),
        "updated_at" => Store.now()
      }

      with :ok <- validate(goal, entries), do: {:ok, goal, entries ++ [goal]}
    end)
  end

  def update(identity, id, attrs, opts \\ []) do
    attrs = Store.attrs(attrs)

    Store.transact("goals", identity, opts, fn entries ->
      with true <- Enum.all?(Map.keys(attrs), &(&1 in @fields)),
           %{} = old <- Enum.find(entries, &(&1["id"] == id)),
           goal = old |> Map.merge(attrs) |> Map.put("updated_at", Store.now()),
           :ok <- validate(goal, entries) do
        {:ok, goal, Enum.map(entries, fn e -> if e["id"] == id, do: goal, else: e end)}
      else
        false -> {:error, :invalid_fields}
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def list(identity, opts \\ []) do
    with {:ok, entries} <- Store.read("goals", identity, opts) do
      {:ok,
       Enum.filter(entries, fn e ->
         not Keyword.get(opts, :open_only, false) or e["status"] not in ~w(done cancelled)
       end)}
    end
  end

  def get(identity, id, opts \\ []) do
    with {:ok, entries} <- list(identity, opts) do
      case Enum.find(entries, &(&1["id"] == id)) do
        nil -> {:error, :not_found}
        goal -> {:ok, goal}
      end
    end
  end

  def delete(identity, id, opts \\ []) do
    Store.transact("goals", identity, opts, fn entries ->
      cond do
        not Enum.any?(entries, &(&1["id"] == id)) ->
          {:error, :not_found}

        Enum.any?(entries, &(&1["parent_id"] == id)) and not Keyword.get(opts, :cascade, false) ->
          {:error, :has_children}

        true ->
          {:ok, :deleted,
           Enum.reject(entries, fn e ->
             e["id"] == id or ancestor?(e["parent_id"], id, entries)
           end)}
      end
    end)
  end

  def tree(identity, opts \\ []) do
    with {:ok, entries} <- list(identity, opts), do: {:ok, children(entries, nil)}
  end

  defp children(entries, parent),
    do:
      for(
        e <- entries,
        e["parent_id"] == parent,
        do: Map.put(e, "steps", children(entries, e["id"]))
      )

  @doc "Bounded open-goal summary including why. Counts cover the entire tree."
  def review(identity, opts \\ []) do
    with {:ok, entries} <- list(identity, Keyword.delete(opts, :open_only)) do
      open = Enum.reject(entries, &(&1["status"] in ~w(done cancelled)))
      limit = Keyword.get(opts, :limit, 8) |> max(0) |> min(50)

      summary =
        open
        |> Enum.take(limit)
        |> Enum.map(fn e ->
          Map.take(e, ~w(id parent_id status))
          |> Map.merge(%{
            "title" => String.slice(e["title"], 0, 160),
            "why" => String.slice(e["why"], 0, 240)
          })
        end)

      {:ok,
       %{
         goals: summary,
         counts: Enum.frequencies_by(entries, & &1["status"]),
         omitted: max(length(open) - limit, 0)
       }}
    end
  end

  defp validate(goal, entries) do
    cond do
      not Store.text?(goal["title"], 1000) or String.trim(goal["title"]) == "" ->
        {:error, :invalid_title}

      not Store.text?(goal["why"], 8000) ->
        {:error, :invalid_why}

      goal["status"] not in @statuses ->
        {:error, :invalid_status}

      goal["parent_id"] == goal["id"] ->
        {:error, :cycle}

      goal["parent_id"] != nil and not Enum.any?(entries, &(&1["id"] == goal["parent_id"])) ->
        {:error, :parent_not_found}

      ancestor?(goal["parent_id"], goal["id"], entries) ->
        {:error, :cycle}

      true ->
        :ok
    end
  end

  defp ancestor?(nil, _, _), do: false
  defp ancestor?(id, id, _), do: true

  defp ancestor?(parent, id, entries) do
    case Enum.find(entries, &(&1["id"] == parent)) do
      nil -> false
      e -> ancestor?(e["parent_id"], id, entries)
    end
  end
end
