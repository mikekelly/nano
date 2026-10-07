defmodule Nano.Delegation.Store do
  @moduledoc """
  Durable record of delegation: which agent started which sub-agent (with its worktree), and the
  reports received. One JSONL file per kind under `<data>/delegation/`:
  `children.jsonl` (one line per start) and `reports.jsonl` (one line per report). Reads are
  served from ETS and reloaded when a file changes.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The ETS cache table (public)."
  def table, do: @table

  @doc "The delegation directory (`<data>/delegation`)."
  def dir, do: Path.join(Nano.Util.data_dir(), "delegation")

  defp children_file, do: Path.join(dir(), "children.jsonl")
  defp reports_file, do: Path.join(dir(), "reports.jsonl")

  @doc "Records that `parent` started sub-agent `name`."
  def remember(name, parent, extra \\ %{}) do
    entry =
      %{name: name, parent: parent, started_at: now()}
      |> Map.merge(stringify(extra))
      |> Map.put(:worktree, extra[:worktree])

    append(children_file(), entry)
    invalidate(:children)
    :ok
  end

  @doc "Records a report that arrived (from, status, message, budget, time)."
  def remember_report(report) do
    append(reports_file(), stringify(report))
    invalidate(:reports)
    :ok
  end

  @doc "Entries for sub-agents started by `parent`, oldest first."
  def children(parent), do: all(:children) |> Enum.filter(&(&1["parent"] == to_string(parent)))

  @doc "Every delegation entry, oldest first."
  def all(kind), do: cached(kind, file(kind))

  @doc "Reports received, newest first, capped."
  def reports(limit \\ 50),
    do: all(:reports) |> Enum.reverse() |> Enum.take(limit)

  @doc "The parent recorded for `name`, or nil."
  def parent_of(name), do: Enum.find_value(all(:children), &if(&1["name"] == to_string(name), do: &1["parent"]))

  defp file(:children), do: children_file()
  defp file(:reports), do: reports_file()

  defp cached(kind, path) do
    mtime = mtime(path)

    case :ets.lookup(@table, kind) do
      [{^kind, ^mtime, entries}] -> entries
      _ ->
        entries = read(path)
        :ets.insert(@table, {kind, mtime, entries})
        entries
    end
  end

  defp invalidate(kind), do: :ets.delete(@table, kind)

  defp append(path, entry) do
    File.mkdir_p!(dir())
    File.write!(path, Jason.encode!(entry) <> "\n", [:append])
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, m} -> [m]
            _ -> []
          end
        end)

      _ -> []
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> 0
    end
  end

  defp stringify(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
  defp stringify(l) when is_list(l), do: Map.new(l, fn {k, v} -> {to_string(k), v} end)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
