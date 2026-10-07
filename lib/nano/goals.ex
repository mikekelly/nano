defmodule Nano.Goals do
  @moduledoc """
  Goals an agent sets for itself, kept across turns, restarts and node restarts. The seeding
  is `/app/seedings/goals.md`.

      Nano.Goals.add("grow the seven seedlings", note: "from the operator message")
      Nano.Goals.add("delegation", parent: "g1", note: "sub-agents with composed prompts")
      Nano.Goals.list()                # all goals, newest first
      Nano.Goals.open()                # only open ones (status :open), oldest first: the to-do
      Nano.Goals.tree()                # a goal and its children, as indented text
      Nano.Goals.progress("g3", "wrote Nano.Background")   # note progress, status stays
      Nano.Goals.done("g3", "tests pass")                  # mark done, with a note
      Nano.Goals.block("g4", "no EXA_API_KEY on this node")
      Nano.Goals.abandon("g5", "superseded")
      Nano.Goals.review()              # a short block to read at a wakeup: what is still open

  A goal is `%{id:, agent:, text:, status:, note:, parent:, created:, updated:, events:}`.
  Status is `:open`, `:done`, `:blocked` or `:abandoned`. Goals belong to the agent that
  created them (`agent` is its name), and every goal is readable by any agent, so a
  sub-agent can see what its parent is after: `Nano.Goals.open("gardener")`.

  Persistence: one JSONL file per agent under `/data/goals/<agent>.jsonl` (`NANO_DATA_DIR`),
  appended on every change, so goals survive a node restart; `load/1` reads them back.
  A short review habit, cheap in tokens, is `review/1`; calling it at a wakeup or before an
  `idle` is the agent's own loop, not a harness rule.
  """

  @dir_override "NANO_GOALS_DIR"
  @statuses [:open, :done, :blocked, :abandoned]

  @doc "The goal statuses: `#{inspect(@statuses)}`."
  def statuses, do: @statuses

  @doc """
  Creates a goal. Options: `parent:` (a goal id, for a sub-goal), `note:`, `agent:` (default:
  the calling agent), `id:`. Returns `{:ok, goal}`.
  """
  def add(text, opts \\ []) when is_binary(text) do
    goal = %{
      id: Keyword.get(opts, :id) || new_id(),
      agent: to_string(Keyword.get(opts, :agent) || Nano.Util.calling_agent() || "unknown"),
      text: text,
      status: :open,
      note: Keyword.get(opts, :note),
      parent: Keyword.get(opts, :parent),
      created: now(),
      updated: now(),
      events: []
    }

    {:ok, goal} |> tap(fn {:ok, g} -> append(g, :created, nil) end)
  end

  @doc "`add/2`, returning the goal id."
  def add!(text, opts \\ []) do
    {:ok, goal} = add(text, opts)
    goal.id
  end

  @doc "Records progress: appends a dated event to the goal's history. Status is unchanged."
  def progress(id, note), do: update(id, nil, note, :progress)

  @doc "Marks a goal done, with an optional note."
  def done(id, note \\ nil), do: update(id, :done, note, :done)

  @doc "Marks a goal blocked, with an optional note (what it is waiting on)."
  def block(id, note \\ nil), do: update(id, :blocked, note, :blocked)

  @doc "Abandons a goal, with an optional note."
  def abandon(id, note \\ nil), do: update(id, :abandoned, note, :abandoned)

  @doc "Reopens a goal (`:blocked` or `:done` -> `:open`), with an optional note."
  def reopen(id, note \\ nil), do: update(id, :open, note, :reopened)

  defp update(id, status, note, event) do
    case fetch(id, :all) do
      nil ->
        {:error, :not_found}

      goal ->
        goal =
          goal
          |> Map.put(:status, status || goal.status)
          |> Map.put(:note, note || goal.note)
          |> Map.put(:updated, now())

        append(goal, event, note)
        {:ok, goal}
    end
  end

  @doc """
  Goals, oldest first. `agent:` (default: every agent) restricts to one agent's goals;
  `status:` (a status or list) restricts by status. Reads are cheap: the store is a JSONL
  file per agent, cached in ETS and reloaded when the file changes.
  """
  def list(opts \\ []) do
    goals = all_goals()

    goals
    |> Enum.filter(fn g ->
      Keyword.get(opts, :agent) == nil or g.agent == to_string(Keyword.get(opts, :agent))
    end)
    |> Enum.filter(fn g ->
      Keyword.get(opts, :status) == nil or g.status in List.wrap(Keyword.get(opts, :status))
    end)
    |> Enum.sort_by(& &1.created)
  end

  @doc """
  The open goals (status `:open`), oldest first, for `agent` (default: the calling agent,
  or every agent if there is none). This is the to-do list a review reads.
  """
  def open(agent \\ nil) do
    list(status: :open, agent: agent || Nano.Util.calling_agent())
  end

  @doc """
  A short block of text for a review at a wakeup or before an `idle`: what is open, what is
  blocked, and the last thing done. Reads ~10 lines, deliberately small. `agent` defaults to
  the calling agent.
  """
  def review(agent \\ nil) do
    agent = agent || Nano.Util.calling_agent()
    open = list(agent: agent, status: :open)
    blocked = list(agent: agent, status: :blocked)
    done = list(agent: agent, status: :done) |> Enum.take(-3) |> Enum.reverse()
    mine = list(agent: agent)

    cond do
      mine == [] ->
        "#{agent}: no goals yet. Nano.Goals.add(\"what you are after\") to start one."

      true ->
        [
          "#{agent}: #{length(open)} open, #{length(blocked)} blocked, #{length(mine)} total.",
          Enum.map_join(open, "\n", fn g -> open_line(g) end),
          if(blocked == [],
            do: "",
            else: "blocked:\n" <> Enum.map_join(blocked, "\n", &open_line/1)
          ),
          if(done == [],
            do: "",
            else: "recently done:\n" <> Enum.map_join(done, "\n", &open_line/1)
          )
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
    end
  end

  defp open_line(g),
    do:
      "  [#{g.id}] #{String.slice(g.text, 0, 120)}#{if g.note, do: " — #{String.slice(g.note, 0, 120)}"}"

  @doc """
  A goal and its descendants as indented text, or a list of `{goal, depth}` with `shape: :raw`.
  Root goals default to `agent:`'s (or every agent's).
  """
  def tree(opts \\ []) do
    roots = list(Keyword.take(opts, [:agent, :status])) |> Enum.filter(&(&1.parent == nil))
    shape = shape(roots, 0)
    if Keyword.get(opts, :shape) == :raw, do: shape, else: render_shape(shape)
  end

  defp shape(goals, depth) do
    Enum.flat_map(goals, fn g -> [{g, depth} | shape(children(g.id), depth + 1)] end)
  end

  defp children(id),
    do: all_goals() |> Enum.filter(&(&1.parent == id)) |> Enum.sort_by(& &1.created)

  defp render_shape(shape) do
    Enum.map_join(shape, "\n", fn {g, depth} ->
      "#{String.duplicate("  ", depth)}#{status_mark(g.status)} [#{g.id}] #{g.text}#{if g.note, do: " — #{g.note}"}#{if g.parent, do: ""}"
    end)
  end

  defp status_mark(:open), do: "☐"
  defp status_mark(:done), do: "☑"
  defp status_mark(:blocked), do: "⊘"
  defp status_mark(:abandoned), do: "✗"

  @doc "One goal by id (`status:`/`agent:` filters as in `list/1`), or nil."
  def get(id, opts \\ []) do
    case fetch(id, :all) do
      nil -> nil
      goal -> if Keyword.get(opts, :agent) in [nil, goal.agent], do: goal
    end
  end

  @doc "The audit trail of a goal: `[%{at:, event:, note:, status:}]`, oldest first."
  def history(id) do
    case get(id) do
      nil -> {:error, :not_found}
      goal -> goal.events
    end
  end

  ## Storage

  @doc "The goals directory (`<data>/goals`, overridable with NANO_GOALS_DIR)."
  def dir, do: System.get_env(@dir_override) || Path.join(Nano.Util.data_dir(), "goals")

  @doc "Reloads every agent's goals from disk. Called at boot and by `list/1` when a file changes."
  def load(agent \\ nil) do
    for file <- files(agent) do
      goals = read_file(file)
      stores = Process.whereis(__MODULE__.Store) && __MODULE__.Store
      if stores, do: :ets.insert(Nano.Goals.Store.table(), {Path.basename(file, ".jsonl"), goals})
    end

    :ok
  end

  defp all_goals do
    agent_file_pairs() |> Enum.flat_map(fn {agent, file} -> cached(agent, file) end)
  end

  defp cached(agent, file) do
    table = Nano.Goals.Store.table()
    mtime = mtime(file)

    case :ets.lookup(table, agent) do
      [{^agent, ^mtime, goals}] ->
        goals

      _ ->
        goals = read_file(file)
        :ets.insert(table, {agent, mtime, goals})
        goals
    end
  end

  defp mtime(file) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> [from_map(map)]
            _ -> []
          end
        end)
        |> merge_events()

      _ ->
        []
    end
  end

  # Each line is a full snapshot event; the goal's current value is the last line for its id.
  defp merge_events(entries) do
    entries
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, list} -> list |> Enum.sort_by(& &1.seq) |> then(&apply_events/1) end)
    |> Enum.reject(&is_nil/1)
  end

  defp apply_events([first | rest]) do
    base = Map.put(first, :events, [first.event])

    Enum.reduce(rest, base, fn e, acc ->
      %{
        acc
        | status: e.status,
          note: e.note || acc.note,
          updated: e.at,
          events: acc.events ++ [e.event]
      }
    end)
  end

  defp apply_events([]), do: nil

  defp from_map(map) do
    %{
      id: map["id"],
      seq: map["seq"] || 0,
      agent: map["agent"],
      text: map["text"],
      status: safe_status(map["status"]),
      note: map["note"],
      parent: map["parent"],
      created: map["created"],
      updated: map["updated"],
      at: map["at"],
      event: %{at: map["at"], event: map["event"], note: map["note"], status: map["status"]}
    }
  end

  defp safe_status(text) do
    String.to_existing_atom(text || "open")
  rescue
    ArgumentError -> :open
  end

  defp append(goal, event, note) do
    File.mkdir_p!(dir())
    seq = System.unique_integer([:positive])

    line =
      Jason.encode!(%{
        id: goal.id,
        seq: seq,
        agent: goal.agent,
        text: goal.text,
        status: to_string(goal.status),
        note: goal.note,
        parent: goal.parent,
        created: goal.created,
        updated: goal.updated,
        at: now(),
        event: to_string(event),
        event_note: note
      })

    File.write!(Path.join(dir(), goal.agent <> ".jsonl"), line <> "\n", [:append])
    invalidate(goal.agent)
    :ok
  end

  defp invalidate(agent) do
    if Process.whereis(Nano.Goals.Store), do: :ets.delete(Nano.Goals.Store.table(), agent)
  end

  defp agent_file_pairs do
    dir()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&{Path.basename(&1, ".jsonl"), &1})
  end

  defp files(nil), do: Enum.map(agent_file_pairs(), &elem(&1, 1))
  defp files(agent), do: [Path.join(dir(), to_string(agent) <> ".jsonl")]

  defp fetch(id, _scope) do
    all_goals() |> Enum.find(&(&1.id == id))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp new_id, do: "g" <> Integer.to_string(System.unique_integer([:positive]), 36)
end

defmodule Nano.Goals.Store do
  @moduledoc "An ETS cache of goals per agent, invalidated when the agents' JSONL files change."
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cache table (public, so `Nano.Goals` reads it directly without a call)."
  def table, do: @table

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
