defmodule Nano.Goals do
  @moduledoc """
  Durable goals by stable agent name; no agent process or supervisor needed.

      {:ok, goal} = Nano.Goals.add("alice", "Ship the report", why: "Inform the launch decision")
      Nano.Goals.add("alice", "Check sources", why: "Avoid stale claims", parent: goal["id"])
      Nano.Goals.update("alice", goal["id"], status: :done)
      Nano.Goals.review("alice")

  Mutations return `{:ok, goal}` or `{:error, reason}`. `list/2` returns the
  full flat tree (parent IDs); `review/2` returns a bounded open-goal summary.
  Other agents may read any owner. `:root` overrides `/data/nano-library` for
  isolated tests or another durable volume. See `docs/nova-goals.md`.
  """
  alias Nano.DurableStore, as: Store
  @statuses ~w(open active blocked done cancelled)

  def add(owner, title, opts \\ []) do
    why = Keyword.get(opts, :why)
    parent = Keyword.get(opts, :parent)

    if Store.text?(title, 1000) and Store.text?(why) do
      Store.transact("goals", owner, opts, fn entries ->
        if is_nil(parent) or Map.has_key?(entries, parent) do
          id = Store.id()

          goal = %{
            "id" => id,
            "title" => title,
            "why" => why,
            "parent" => parent,
            "status" => "open",
            "note" => "",
            "created_at" => Store.now(),
            "updated_at" => Store.now()
          }

          {:ok, Map.put(entries, id, goal), goal}
        else
          {:error, :parent_not_found}
        end
      end)
    else
      {:error, :invalid_title_or_why}
    end
  end

  def update(owner, id, changes, opts \\ []) do
    attrs = normalize(changes)

    valid =
      is_map(attrs) and
        Enum.all?(attrs, fn
          {"status", v} -> v in @statuses
          {"title", v} -> Store.text?(v, 1000)
          {"why", v} -> Store.text?(v)
          {"note", v} -> is_binary(v) and String.valid?(v) and byte_size(v) <= 8000
          _ -> false
        end)

    if valid do
      Store.transact("goals", owner, opts, fn entries ->
        case Map.fetch(entries, id) do
          {:ok, goal} ->
            next = goal |> Map.merge(attrs) |> Map.put("updated_at", Store.now())
            {:ok, Map.put(entries, id, next), next}

          :error ->
            {:error, :not_found}
        end
      end)
    else
      {:error, :invalid_changes}
    end
  end

  defp normalize(changes) when is_map(changes) or is_list(changes) do
    Map.new(changes, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      value = if key == "status" and is_atom(v), do: Atom.to_string(v), else: v
      {key, value}
    end)
  rescue
    _ -> nil
  end

  defp normalize(_), do: nil

  def list(owner, opts \\ []) do
    with {:ok, entries} <- Store.read("goals", owner, opts) do
      {:ok, entries |> Map.values() |> Enum.sort_by(&{&1["created_at"], &1["id"]})}
    end
  end

  def review(owner, opts \\ []) do
    with {:ok, limit} <- Store.limit(opts, 12),
         {:ok, goals} <- list(owner, opts) do
      open = Enum.reject(goals, &(&1["status"] in ["done", "cancelled"]))

      summary =
        open
        |> Enum.take(limit)
        |> Enum.map(fn g ->
          Map.take(g, ~w(id parent status))
          |> Map.merge(%{
            "title" => Store.clip(g["title"], 160),
            "why" => Store.clip(g["why"], 240),
            "note" => Store.clip(g["note"], 160)
          })
        end)

      {:ok, %{goals: summary, total: length(open), omitted: max(length(open) - limit, 0)}}
    end
  end
end
