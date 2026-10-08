defmodule Seedling.Goals do
  @moduledoc """
  Durable goal trees owned by an agent name, readable by any agent.

      {:ok, goal} = Seedling.Goals.create("alice", title: "Ship search", why: "Find sources")
      {:ok, step} = Seedling.Goals.create("alice", title: "Test errors", why: "Trust results", parent_id: goal["id"])
      Seedling.Goals.focus("alice", goal["id"])
      Seedling.Goals.set_status("alice", step["id"], :done)
      Seedling.Goals.review("alice")

  Reads and mutations return `{:ok, value} | {:error, reason}`. Goals have stable
  string IDs, `title`, `why`, `status`, `parent_id` and UTC timestamps. Statuses
  are `open`, `active`, `blocked`, `done`, `cancelled`. Finishing a parent requires
  finishing its descendants first; status never silently cascades. Reparenting
  rejects cycles. `delete/3` explicitly removes a whole subtree.

  `review/2` gives bounded text plus counts and truncation metadata, not the whole
  tree. `focus/3` chooses what to bob; `bobbing_source/2` supplies current goal and
  next unfinished step to the reusable bobbing hook. No automatic LLM calls.
  The agent decides when to review. `dashboard/2` is a direct cache read with an
  asynchronous cold load (it never calls the agent or waits on disk).

  State is JSON in `state_dir/seedling/goals`, independent of conversation,
  compaction and agent lifetime. All APIs accept `root: path` for isolation and
  reads accept `refresh: true` to reload disk. Maximum 1,000 goals per agent,
  title 240 characters and why 2,000 characters. Mutations are single-node atomic.
  """
  alias Seedling.DurableStore, as: Store
  @statuses ~w(open active blocked done cancelled)
  @terminal ~w(done cancelled)
  @default %{"version" => 1, "revision" => 0, "current" => nil, "goals" => []}

  @doc "Adds a goal; `title` and `why` are required, `parent_id` and `status` optional."
  def create(agent, attrs, opts \\ []) do
    attrs = attrs_map(attrs)

    mutate(agent, opts, fn doc ->
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      goal =
        Map.merge(
          %{
            "id" => id(),
            "parent_id" => nil,
            "status" => "open",
            "created_at" => now,
            "updated_at" => now
          },
          attrs
        )

      with true <-
             Enum.all?(Map.keys(attrs), &(&1 in ~w(title why status parent_id))) or
               {:error, :invalid_attributes},
           true <- length(doc["goals"]) < 1_000 or {:error, :goal_limit},
           :ok <- validate_goal(goal),
           :ok <- validate_parent(doc["goals"], goal),
           :ok <- validate_open_parent(doc["goals"], goal) do
        {:ok, %{doc | "goals" => doc["goals"] ++ [goal]}, goal}
      end
    end)
  end

  @doc "Changes title, why, status or parent_id; other attributes are rejected."
  def update(agent, goal_id, attrs, opts \\ []) do
    attrs = attrs_map(attrs)

    mutate(agent, opts, fn doc ->
      with {:ok, old} <- find(doc, goal_id),
           true <-
             Enum.all?(Map.keys(attrs), &(&1 in ~w(title why status parent_id))) or
               {:error, :invalid_attributes},
           goal =
             old
             |> Map.merge(attrs)
             |> Map.put("updated_at", DateTime.to_iso8601(DateTime.utc_now())),
           :ok <- validate_goal(goal),
           :ok <- validate_parent(doc["goals"], goal),
           :ok <- validate_completion(doc["goals"], goal),
           :ok <- validate_open_parent(doc["goals"], goal) do
        goals = Enum.map(doc["goals"], fn g -> if g["id"] == goal_id, do: goal, else: g end)
        {:ok, %{doc | "goals" => goals}, goal}
      end
    end)
  end

  @doc "Sets a goal's status, without cascading to children."
  def set_status(agent, goal_id, status, opts \\ []),
    do: update(agent, goal_id, %{status: status}, opts)

  @doc "Chooses the current goal (`nil` clears focus); terminal goals cannot be focused."
  def focus(agent, goal_id, opts \\ []) do
    mutate(agent, opts, fn doc ->
      with :ok <- focus_valid(doc, goal_id), do: {:ok, %{doc | "current" => goal_id}, goal_id}
    end)
  end

  @doc "Deletes a goal and all descendants; returns the number removed."
  def delete(agent, goal_id, opts \\ []) do
    mutate(agent, opts, fn doc ->
      with {:ok, _} <- find(doc, goal_id) do
        removed = [goal_id | descendants(doc["goals"], goal_id)]
        goals = Enum.reject(doc["goals"], &(&1["id"] in removed))
        current = if doc["current"] in removed, do: nil, else: doc["current"]
        {:ok, %{doc | "goals" => goals, "current" => current}, length(removed)}
      end
    end)
  end

  @doc "Reads all goals in creation order, including completed goals."
  def list(agent, opts \\ []),
    do: with({:ok, doc} <- document(agent, opts), do: {:ok, doc["goals"]})

  @doc "Reads a goal by stable ID."
  def get(agent, goal_id, opts \\ []),
    do: with({:ok, doc} <- document(agent, opts), do: find(doc, goal_id))

  @doc "Reads nested roots; each goal has a `children` list."
  def tree(agent, opts \\ []) do
    with {:ok, doc} <- document(agent, opts), do: {:ok, children(doc["goals"], nil)}
  end

  @doc "Bounded review (defaults: 5 open goals, 1,000 characters); returns counts and `truncated`."
  def review(agent, opts \\ []) do
    with {:ok, doc} <- document(agent, opts), do: {:ok, summarize(doc, opts)}
  end

  @doc "Non-blocking open-goal snapshot for live rendering; `:loading` until the first load."
  def dashboard(agent, opts \\ []) do
    case Store.peek("goals", agent, opts) do
      {:ok, nil} -> {:ok, dashboard_doc(@default)}
      {:ok, doc} -> with(:ok <- validate(doc), do: {:ok, dashboard_doc(doc)})
      other -> other
    end
  end

  @doc "A short reusable bobbing source, or nil if there are no open goals."
  def bobbing_source(agent, opts \\ []) do
    with {:ok, doc} <- document(agent, opts) do
      case current(doc) do
        nil ->
          {:ok, nil}

        goal ->
          descendants = MapSet.new(descendants(doc["goals"], goal["id"]))

          next =
            Enum.find(
              doc["goals"],
              &(MapSet.member?(descendants, &1["id"]) and &1["status"] not in @terminal)
            )

          text =
            "Current goal: #{goal["title"]} [#{goal["status"]}]. Why: #{String.slice(goal["why"], 0, 400)}" <>
              if(next, do: "\nNext step: #{next["title"]} [#{next["status"]}].", else: "")

          {:ok,
           %{
             text: String.slice(text, 0, 1_000),
             version: doc["revision"],
             written_at: goal["updated_at"],
             source: "goals"
           }}
      end
    end
  end

  defp document(agent, opts) do
    with {:ok, doc} <- Store.read("goals", agent, @default, opts),
         :ok <- validate(doc),
         do: {:ok, doc}
  end

  defp mutate(agent, opts, fun) do
    Store.update(
      "goals",
      agent,
      @default,
      fn doc ->
        with :ok <- validate(doc), {:ok, new, result} <- fun.(doc) do
          new = %{new | "revision" => doc["revision"] + 1}

          new =
            if Enum.any?(
                 new["goals"],
                 &(&1["id"] == new["current"] and &1["status"] in @terminal)
               ), do: %{new | "current" => nil}, else: new

          {:ok, new, result}
        end
      end,
      opts
    )
  end

  defp attrs_map(attrs) when is_list(attrs), do: attrs |> Map.new() |> attrs_map()

  defp attrs_map(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, if(key == "status" and is_atom(v), do: Atom.to_string(v), else: v)}
    end)
  end

  defp attrs_map(_), do: %{"invalid" => true}
  defp id, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp find(doc, id) do
    case Enum.find(doc["goals"], &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  defp validate(%{"version" => 1, "revision" => revision, "goals" => goals, "current" => focus})
       when is_integer(revision) and revision >= 0 and is_list(goals) and length(goals) <= 1_000 do
    valid =
      if Enum.all?(goals, &(validate_goal(&1) == :ok)) do
        index = Map.new(goals, &{&1["id"], &1})

        map_size(index) == length(goals) and
          valid_graph?(index) and
          (focus == nil or Map.has_key?(index, focus))
      else
        false
      end

    if valid, do: :ok, else: {:error, :invalid_goal_document}
  end

  defp validate(_), do: {:error, :invalid_goal_document}

  # Memoized ancestor traversal: even a long chain is checked once, not once per node.
  defp valid_graph?(index) do
    Enum.reduce_while(index, MapSet.new(), fn {id, goal}, resolved ->
      parent = index[goal["parent_id"]]

      open_under_closed =
        (goal["status"] not in @terminal and parent) && parent["status"] in @terminal

      if open_under_closed do
        {:halt, :invalid}
      else
        case resolve(index, id, resolved, MapSet.new()) do
          {:ok, resolved} -> {:cont, resolved}
          :invalid -> {:halt, :invalid}
        end
      end
    end) != :invalid
  end

  defp resolve(_index, nil, resolved, path), do: {:ok, MapSet.union(resolved, path)}

  defp resolve(index, id, resolved, path) do
    cond do
      MapSet.member?(resolved, id) -> {:ok, MapSet.union(resolved, path)}
      MapSet.member?(path, id) -> :invalid
      not Map.has_key?(index, id) -> :invalid
      true -> resolve(index, index[id]["parent_id"], resolved, MapSet.put(path, id))
    end
  end

  defp validate_goal(goal) when is_map(goal) do
    cond do
      not Enum.all?(
        Map.keys(goal),
        &(&1 in ~w(id title why status parent_id created_at updated_at))
      ) ->
        {:error, :invalid_attributes}

      not text?(goal["id"], 128) ->
        {:error, :invalid_id}

      not text?(goal["title"], 240) ->
        {:error, :invalid_title}

      not text?(goal["why"], 2_000) ->
        {:error, :invalid_why}

      goal["status"] not in @statuses ->
        {:error, :invalid_status}

      not is_nil(goal["parent_id"]) and not is_binary(goal["parent_id"]) ->
        {:error, :invalid_parent}

      not text?(goal["created_at"], 64) or not text?(goal["updated_at"], 64) ->
        {:error, :invalid_timestamp}

      true ->
        :ok
    end
  end

  defp validate_goal(_), do: {:error, :invalid_goal}

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        String.length(value) <= max

  defp validate_parent(goals, goal),
    do: walk_parent(Map.new(goals, &{&1["id"], &1}), goal["parent_id"], MapSet.new([goal["id"]]))

  defp walk_parent(_, nil, _), do: :ok

  defp walk_parent(goals, parent, seen) do
    cond do
      MapSet.member?(seen, parent) ->
        {:error, :cycle}

      true ->
        case Map.get(goals, parent) do
          nil ->
            {:error, :parent_not_found}

          p ->
            walk_parent(goals, p["parent_id"], MapSet.put(seen, parent))
        end
    end
  end

  defp validate_open_parent(goals, goal) do
    parent = Enum.find(goals, &(&1["id"] == goal["parent_id"]))

    if (goal["status"] not in @terminal and parent) && parent["status"] in @terminal,
      do: {:error, :parent_closed},
      else: :ok
  end

  defp validate_completion(goals, goal) do
    descendants = MapSet.new(descendants(goals, goal["id"]))

    if goal["status"] in @terminal and
         Enum.any?(
           goals,
           &(MapSet.member?(descendants, &1["id"]) and &1["status"] not in @terminal)
         ), do: {:error, :unfinished_children}, else: :ok
  end

  defp focus_valid(_, nil), do: :ok

  defp focus_valid(doc, id) do
    with {:ok, goal} <- find(doc, id),
         do: if(goal["status"] in @terminal, do: {:error, :goal_closed}, else: :ok)
  end

  defp descendants(goals, id) do
    direct = for g <- goals, g["parent_id"] == id, do: g["id"]
    direct ++ Enum.flat_map(direct, &descendants(goals, &1))
  end

  defp children(goals, parent),
    do:
      for(
        g <- goals,
        g["parent_id"] == parent,
        do: Map.put(g, "children", children(goals, g["id"]))
      )

  defp open(doc), do: Enum.reject(doc["goals"], &(&1["status"] in @terminal))

  defp current(doc),
    do: Enum.find(open(doc), &(&1["id"] == doc["current"])) || List.first(open(doc))

  defp summarize(doc, opts) do
    goals = open(doc)
    limit = bounded(opts[:limit], 5, 1, 50)
    max_chars = bounded(opts[:max_chars], 1_000, 80, 4_000)
    focus = current(doc)
    selected = if focus, do: [focus | Enum.reject(goals, &(&1["id"] == focus["id"]))], else: []

    lines =
      selected
      |> Enum.take(limit)
      |> Enum.map_join("\n", &"[#{&1["status"]}] #{&1["id"]}: #{&1["title"]} — why: #{&1["why"]}")

    text = "Goals: #{length(goals)} open / #{length(doc["goals"])} total.\n" <> lines
    cut = String.length(text) > max_chars or length(goals) > limit
    text = if cut, do: String.slice(text, 0, max_chars - 17) <> "\n[review limited]", else: text

    %{
      text: text,
      open: length(goals),
      total: length(doc["goals"]),
      current_id: if(focus, do: focus["id"]),
      truncated: cut
    }
  end

  defp dashboard_doc(doc) do
    goals = open(doc)

    %{
      goals: Enum.take(goals, 50),
      open: length(goals),
      total: length(doc["goals"]),
      current_id: doc["current"],
      truncated: length(goals) > 50
    }
  end

  defp bounded(n, _default, min, max) when is_integer(n),
    do: n |> Kernel.max(min) |> Kernel.min(max)

  defp bounded(_, default, _, _), do: default
end
