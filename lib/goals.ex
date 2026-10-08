defmodule Goals do
  @moduledoc """
  Durable, shared goals for an explicit agent name (the owner). Any process can read
  another owner's goals without contacting that agent, even when it is stopped.
  Goals live in `Memory` under the reserved key `__goals_v1__`; do not edit that key
  directly. All functions return `{:ok, value}` or `{:error, reason}` and accept
  `root:` (the Memory directory, default `/data/memory`) for isolated stores.

      {:ok, goal} = Goals.create("researcher", %{title: "Check evidence", why: "Avoid stale claims"})
      Goals.create("researcher", %{title: "Read source", why: "Verify the claim", parent_id: goal["id"]})
      Goals.update("researcher", goal["id"], %{status: :in_progress})
      Goals.summary("researcher", limit: 8, bytes: 2000)
      Goals.list("researcher")

  Fields use atom or string keys on input and string keys on output. Required `title`
  and `why` explain what and why (including uncertainties); optional `id` is otherwise
  generated. `parent_id` defaults to nil. Statuses: `open`, `in_progress`, `blocked`,
  `done`, `cancelled` (atoms or strings). Status changes do not cascade: an open child
  remains visible even beneath a completed parent. Cancel rather than delete to retain
  the rationale. Reparenting rejects missing parents and cycles.

  Updates merge only the supplied fields while holding Memory's owner lock, so concurrent
  writers do not lose other edits. Optional `expected_revision:` rejects stale edits of
  the same goal with `:conflict`; otherwise the last edit to a field wins. No batch tree
  replacement API is provided. Storage is bounded to 256 goals and Memory's 1 MB owner
  limit. Reads are lock-free disk snapshots, not GenServer calls. Only one BEAM node may
  write a given root. `summary/2` is the cheap bounded review; `open/2` is for dashboards.
  """
  @key "__goals_v1__"
  @max_goals 256
  @statuses ~w(open in_progress blocked done cancelled)
  @editable ~w(title why parent_id status)
  @fields ~w(id title why parent_id status revision created_at updated_at)

  @doc "Create a goal; optional caller-supplied id must be unique within the owner."
  def create(owner, attrs, opts \\ []) do
    with {:ok, attrs} <- attributes(attrs, ["id" | @editable]) do
      id = Map.get(attrs, "id", Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false))
      now = System.system_time(:millisecond)

      goal =
        Map.merge(
          %{
            "id" => id,
            "parent_id" => nil,
            "status" => "open",
            "revision" => 1,
            "created_at" => now,
            "updated_at" => now
          },
          attrs
        )

      mutate(owner, id, opts, fn goals ->
        cond do
          Map.has_key?(goals, id) -> {:error, :already_exists}
          map_size(goals) >= @max_goals -> {:error, :too_many_goals}
          true -> {:ok, Map.put(goals, id, goal)}
        end
      end)
    end
  end

  @doc "Patch title, why, parent_id or status atomically; id and timestamps are immutable."
  def update(owner, id, attrs, opts \\ []) do
    with {:ok, attrs} <- attributes(attrs, @editable) do
      mutate(owner, id, opts, fn goals ->
        with {:ok, goal} <- fetch(goals, id),
             :ok <- revision(goal, Keyword.get(opts, :expected_revision)) do
          updated =
            goal
            |> Map.merge(attrs)
            |> Map.put("revision", goal["revision"] + 1)
            |> Map.put("updated_at", System.system_time(:millisecond))

          {:ok, Map.put(goals, id, updated)}
        end
      end)
    end
  end

  @doc "Read a complete goal, including its rationale, parent and revision."
  def get(owner, id, opts \\ []) do
    with {:ok, goals} <- read(owner, opts), do: fetch(goals, id)
  end

  @doc "Read all goals, including closed ones, in stable creation/id order (at most 256)."
  def list(owner, opts \\ []) do
    with {:ok, goals} <- read(owner, opts), do: {:ok, ordered(Map.values(goals))}
  end

  @doc "Return %{goals: [...], total: n, omitted: n}; open statuses only, limit 20 (1..100)."
  def open(owner, opts \\ []) do
    with {:ok, limit} <- bound(opts, :limit, 20, 1..100),
         {:ok, goals} <- list(owner, opts) do
      open =
        goals
        |> Enum.reject(&(&1["status"] in ~w(done cancelled)))
        |> Enum.sort_by(&{priority(&1["status"]), &1["created_at"], &1["id"]})

      selected = Enum.take(open, limit)
      {:ok, %{goals: selected, total: length(open), omitted: length(open) - length(selected)}}
    end
  end

  @doc "Bounded UTF-8 review text, with why and parent IDs. Defaults: limit 8, bytes 2000 (256..16000)."
  def summary(owner, opts \\ []) do
    with {:ok, bytes} <- bound(opts, :bytes, 2000, 256..16_000),
         {:ok, result} <- open(owner, Keyword.put_new(opts, :limit, 8)) do
      header =
        "Open goals: #{result.total} (showing #{length(result.goals)}, omitted #{result.omitted})"

      lines =
        Enum.map(result.goals, fn g ->
          "[#{g["status"]}] #{g["id"]} parent=#{g["parent_id"] || "-"}: " <>
            clip(one_line(g["title"]), 160) <> " — why: " <> clip(one_line(g["why"]), 240)
        end)

      {:ok, clip(Enum.join([header | lines], "\n"), bytes, "\n[truncated; use Goals.list/2]")}
    end
  end

  defp mutate(owner, id, opts, fun) do
    with {:ok, tree} <-
           Memory.update(
             owner,
             @key,
             empty(),
             fn tree ->
               with {:ok, goals} <- validate(tree),
                    {:ok, goals} <- fun.(goals),
                    tree = %{"version" => 1, "goals" => goals},
                    {:ok, _} <- validate(tree),
                    do: {:ok, tree}
             end,
             opts
           ) do
      {:ok, tree["goals"][id]}
    end
  end

  defp read(owner, opts) do
    case Memory.get(owner, @key, opts) do
      {:ok, tree} -> validate(tree)
      {:error, :not_found} -> {:ok, %{}}
      error -> error
    end
  end

  defp empty, do: %{"version" => 1, "goals" => %{}}

  defp validate(%{"version" => 1, "goals" => goals})
       when is_map(goals) and map_size(goals) <= @max_goals do
    if Enum.all?(goals, fn {id, goal} -> valid_goal?(id, goal) end) do
      Enum.reduce_while(goals, {:ok, goals}, fn {id, _}, acc ->
        case ancestry(goals, id, MapSet.new()) do
          :ok -> {:cont, acc}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_goal}
    end
  end

  defp validate(_), do: {:error, :invalid_goal_store}

  defp valid_goal?(id, g) when is_map(g) do
    Enum.sort(Map.keys(g)) == Enum.sort(@fields) and
      text?(id, 128) and g["id"] == id and text?(g["title"], 512) and text?(g["why"], 4096) and
      (is_nil(g["parent_id"]) or text?(g["parent_id"], 128)) and g["status"] in @statuses and
      is_integer(g["revision"]) and g["revision"] > 0 and
      is_integer(g["created_at"]) and is_integer(g["updated_at"])
  end

  defp valid_goal?(_, _), do: false

  defp text?(text, max) when is_binary(text),
    do: byte_size(text) in 1..max and String.valid?(text) and String.trim(text) != ""

  defp text?(_, _), do: false

  defp ancestry(_, nil, _), do: :ok

  defp ancestry(goals, id, seen) do
    cond do
      MapSet.member?(seen, id) -> {:error, :cycle}
      not Map.has_key?(goals, id) -> {:error, :parent_not_found}
      true -> ancestry(goals, goals[id]["parent_id"], MapSet.put(seen, id))
    end
  end

  defp attributes(attrs, allowed) when is_map(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      value = if key == "status" and is_atom(value), do: Atom.to_string(value), else: value

      if key in allowed and not Map.has_key?(acc, key),
        do: {:cont, {:ok, Map.put(acc, key, value)}},
        else: {:halt, {:error, :invalid_attributes}}
    end)
  end

  defp attributes(_, _), do: {:error, :invalid_attributes}

  defp fetch(goals, id) do
    case Map.fetch(goals, id) do
      {:ok, goal} -> {:ok, goal}
      :error -> {:error, :not_found}
    end
  end

  defp revision(_, nil), do: :ok
  defp revision(%{"revision" => n}, n), do: :ok
  defp revision(_, _), do: {:error, :conflict}
  defp ordered(goals), do: Enum.sort_by(goals, &{&1["created_at"], &1["id"]})
  defp priority("in_progress"), do: 0
  defp priority("blocked"), do: 1
  defp priority(_), do: 2

  defp bound(opts, key, default, range) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value in range,
      do: {:ok, value},
      else: {:error, {:invalid_option, key}}
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/u, " ")

  defp clip(text, bytes, suffix \\ "…") do
    if byte_size(text) <= bytes,
      do: text,
      else: utf8_prefix(binary_part(text, 0, bytes - byte_size(suffix))) <> suffix
  end

  defp utf8_prefix(text) do
    if String.valid?(text), do: text, else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
