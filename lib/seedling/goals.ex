defmodule Seedling.Goals do
  @moduledoc """
  Durable goal trees, readable by any agent. Every goal records its why.

      {:ok, goal} = Seedling.Goals.create(me, "Ship search", "Help agents find sources")
      Seedling.Goals.create(me, "Test", "Evidence before reporting", parent: goal["id"])
      Seedling.Goals.review(me)
      Seedling.Goals.update(me, goal["id"], status: "active")

  Status: open, active, blocked, done, cancelled. A goal cannot be completed while
  children remain open. Reviews are bounded plain text; `list/2` exposes full trees
  without calling the agent, so it is safe on a live dashboard. `configure/2` opts
  into goal bobbing independently of the front-of-mind note.
  """
  alias Seedling.CapabilityStore, as: Store
  @empty %{"goals" => [], "revision" => 0, "bobbing" => false, "threshold" => 8000}
  @statuses ~w(open active blocked done cancelled)
  def list(agent, opts \\ []) do
    with {:ok, doc} <- document(agent, opts), do: {:ok, doc["goals"]}
  end

  def document(agent, opts \\ []), do: Store.get(:goals, Store.agent(agent), @empty, opts)

  def create(agent, title, why, opts \\ []) do
    parent = opts[:parent]

    with :ok <- text(title, 240),
         :ok <- text(why, 1000),
         name when is_binary(name) <- Store.agent(agent) do
      Store.update(
        :goals,
        name,
        @empty,
        fn doc ->
          goals = doc["goals"]

          cond do
            length(goals) >= 500 ->
              {:error, :goal_limit}

            parent &&
                not Enum.any?(
                  goals,
                  &(&1["id"] == parent and &1["status"] not in ["done", "cancelled"])
                ) ->
              {:error, :invalid_parent}

            true ->
              g = %{
                "id" => Store.id(),
                "title" => title,
                "why" => why,
                "parent" => parent,
                "status" => "open",
                "created_at" => Store.now(),
                "updated_at" => Store.now()
              }

              {:ok, %{doc | "goals" => goals ++ [g], "revision" => doc["revision"] + 1}, g}
          end
        end,
        opts
      )
    else
      nil -> {:error, :unknown_agent}
      error -> error
    end
  end

  def update(agent, id, changes, opts \\ []) do
    changes = Map.new(changes, fn {k, v} -> {to_string(k), v} end)

    Store.update(
      :goals,
      Store.agent(agent),
      @empty,
      fn doc ->
        goals = doc["goals"]
        old = Enum.find(goals, &(&1["id"] == id))

        cond do
          is_nil(old) ->
            {:error, :not_found}

          Enum.any?(Map.keys(changes), &(&1 not in ~w(title why status))) ->
            {:error, :invalid_field}

          Map.has_key?(changes, "status") && changes["status"] not in @statuses ->
            {:error, :invalid_status}

          Map.has_key?(changes, "title") && text(changes["title"], 240) != :ok ->
            {:error, :invalid_title}

          Map.has_key?(changes, "why") && text(changes["why"], 1000) != :ok ->
            {:error, :invalid_why}

          changes["status"] == "done" &&
              Enum.any?(
                goals,
                &(&1["parent"] == id and &1["status"] not in ["done", "cancelled"])
              ) ->
            {:error, :unfinished_children}

          true ->
            g = old |> Map.merge(changes) |> Map.put("updated_at", Store.now())

            {:ok,
             %{
               doc
               | "goals" => Enum.map(goals, &if(&1["id"] == id, do: g, else: &1)),
                 "revision" => doc["revision"] + 1
             }, g}
        end
      end,
      opts
    )
  end

  def configure(agent, changes, opts \\ []) do
    enabled = Keyword.get(changes, :bobbing, false)
    threshold = Keyword.get(changes, :threshold, 8000)

    if is_boolean(enabled) and is_integer(threshold) and threshold >= 100 do
      Store.update(
        :goals,
        Store.agent(agent),
        @empty,
        fn d -> {:ok, Map.merge(d, %{"bobbing" => enabled, "threshold" => threshold}), :ok} end,
        opts
      )
    else
      {:error, :invalid_configuration}
    end
  end

  def review(agent, opts \\ []) do
    with {:ok, goals} <- list(agent, opts) do
      open = Enum.reject(goals, &(&1["status"] in ["done", "cancelled"]))

      rows =
        open
        |> Enum.sort_by(&if(&1["status"] == "active", do: 0, else: 1))
        |> Enum.take(Keyword.get(opts, :limit, 8))

      text =
        Enum.map_join(rows, "\n", fn g ->
          "[#{g["status"]}] #{g["id"]}: #{g["title"]} — #{g["why"]}"
        end)

      {:ok,
       String.slice(
         "#{length(open)} open goals\n" <> text,
         0,
         Keyword.get(opts, :max_chars, 1600)
       )}
    end
  end

  defp text(s, max),
    do:
      if(is_binary(s) and String.trim(s) != "" and String.length(s) <= max,
        do: :ok,
        else: {:error, :invalid_text}
      )
end
