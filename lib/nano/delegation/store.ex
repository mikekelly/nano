defmodule Nano.Delegation.Store do
  @moduledoc """
  Remembers which agent started which sub-agent, and how, so the parent can list its
  sub-agents after a restart and the dashboard's `started_by` story has a durable record.

  One JSONL file, `/data/delegation.jsonl` (`NANO_DATA_DIR`), appended on every start; read
  back with `children/1` and `parent_of/1`. Reads are served from ETS, reloaded when the file
  changes (the same pattern as `Nano.Goals`).
  """

  use GenServer

  @table __MODULE__
  @file_name "delegation.jsonl"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The ETS cache table (public)."
  def table, do: @table

  @doc "Where the delegation log lives (`<data>/delegation.jsonl`)."
  def dir, do: Nano.Util.data_dir()

  @doc "The file delegation entries are appended to."
  def file, do: Path.join(dir(), @file_name)

  @doc "Records that `parent` started sub-agent `name`, with the options used."
  def remember(name, parent, extra \\ %{}) do
    entry =
      Map.merge(
        %{
          name: name,
          parent: parent,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        },
        maps(extra)
      )

    File.mkdir_p!(dir())
    File.write!(file(), Jason.encode!(entry) <> "\n", [:append])
    :ets.delete(@table, :all)
    :ok
  end

  defp maps(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string_key(k), v} end)
  defp maps(list) when is_list(list), do: Map.new(list, fn {k, v} -> {to_string_key(k), v} end)
  defp maps(_), do: %{}

  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: to_string(k)

  @doc "Entries for sub-agents started by `parent`, newest last."
  def children(parent) do
    all() |> Enum.filter(&(&1["parent"] == to_string(parent)))
  end

  @doc "The parent recorded for `name`, or nil."
  def parent_of(name) do
    case Enum.find(all(), &(&1["name"] == to_string(name))) do
      nil -> nil
      entry -> entry["parent"]
    end
  end

  @doc "Every delegation entry, oldest first."
  def all do
    mtime = mtime(file())

    case :ets.lookup(@table, :all) do
      [{:all, ^mtime, entries}] ->
        entries

      _ ->
        entries = read()
        :ets.insert(@table, {:all, mtime, entries})
        entries
    end
  end

  defp read do
    case File.read(file()) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> [map]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> 0
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
