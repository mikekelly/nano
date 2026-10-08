defmodule SeedGoals do
  @moduledoc """
  Durable goal trees with rationale and explicit next actions. Names are stable agent
  identities, not pids. `add("scout", "Ship parser", why: "Unlock import", next: "Write tests")`
  returns a goal including its id; pass `parent: id` to add a step. `update/4` accepts
  title, why, next, status (open/active/blocked/done/cancelled). Completing a parent
  requires all its children closed; reopening a child reopens closed ancestors.
  `review/2` is the cheap wakeup/dashboard entry point; `list/2` reveals the tree.
  `SeedMemory` stores lessons; `SeedFocus` holds the one thing to keep at the tip.
  Persistence and errors follow SeedMemory; use `root:` for isolation.
  """
  alias SeedMemory.Store
  @closed ["done", "cancelled"]
  def add(agent, title, opts \\ []) do
    item = %{
      "id" => Store.id(),
      "title" => title,
      "why" => Keyword.get(opts, :why, ""),
      "next" => Keyword.get(opts, :next, ""),
      "parent" => Keyword.get(opts, :parent),
      "status" => "open",
      "written_at" => Store.now()
    }

    Store.update(agent, "goals", %{}, opts, fn goals ->
      cond do
        not valid?(item) ->
          {:error, :invalid_goal}

        item["parent"] != nil and not Map.has_key?(goals, item["parent"]) ->
          {:error, :parent_not_found}

        item["parent"] != nil and goals[item["parent"]]["status"] in @closed ->
          {:error, :parent_closed}

        true ->
          {:ok, Map.put(goals, item["id"], item), item}
      end
    end)
  end

  def update(agent, id, changes, opts \\ []) do
    changes = Map.new(changes, fn {k, v} -> {to_string(k), to_string(v)} end)

    Store.update(agent, "goals", %{}, opts, fn goals ->
      with {:ok, old} <- Map.fetch(goals, id) do
        item = Map.merge(old, Map.take(changes, ["title", "why", "next", "status"]))

        cond do
          not valid?(item) ->
            {:error, :invalid_goal}

          item["status"] in @closed and
              Enum.any?(goals, fn {_, g} -> g["parent"] == id and g["status"] not in @closed end) ->
            {:error, :open_children}

          true ->
            item = Map.put(item, "written_at", Store.now())
            goals = Map.put(goals, id, item)
            goals = if item["status"] in @closed, do: goals, else: reopen(goals, item["parent"])
            {:ok, goals, item}
        end
      else
        :error -> {:error, :not_found}
      end
    end)
  end

  def list(agent, opts \\ []) do
    with {:ok, goals} <- Store.read(agent, "goals", %{}, opts),
         do: {:ok, goals |> Map.values() |> Enum.sort_by(&{&1["written_at"], &1["id"]})}
  end

  def review(agent, opts \\ []) do
    with {:ok, goals} <- list(agent, opts) do
      open =
        Enum.reject(goals, &(&1["status"] in @closed))
        |> Enum.sort_by(
          &{if(&1["status"] == "active", do: 0, else: 1), &1["written_at"], &1["id"]}
        )

      limit = Keyword.get(opts, :limit, 5) |> max(0) |> min(20)

      items =
        Enum.take(open, limit)
        |> Enum.map(fn g ->
          Map.new(g, fn {k, v} ->
            {k, if(k in ["title", "why", "next"], do: String.slice(v, 0, 200), else: v)}
          end)
        end)

      {:ok,
       %{items: items, open: length(open), total: length(goals), truncated: length(open) > limit}}
    end
  end

  defp valid?(g),
    do:
      Store.text(g["title"], 500) and g["title"] != "" and Store.text(g["why"], 2000) and
        Store.text(g["next"], 1000) and
        g["status"] in ["open", "active", "blocked", "done", "cancelled"]

  defp reopen(goals, nil), do: goals

  defp reopen(goals, id) do
    g = goals[id]

    goals =
      if g["status"] in @closed, do: Map.put(goals, id, Map.put(g, "status", "open")), else: goals

    reopen(goals, g["parent"])
  end
end
