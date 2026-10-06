defmodule Nano.Log do
  @moduledoc """
  The harness log. Each entry is appended as one JSON line to `<log_dir>/<agent id>.jsonl`
  (the durable record) and broadcast on `Nano.PubSub` topic `"agent:<id>"` as
  `{:nano_log, entry}` (what the dashboard follows).

  An entry is `%{seq, at, agent_id, agent, type, ...fields}`. In-process it has atom keys and
  `type` is an atom; read back from disk it has string keys and `type` is a string. Values
  are made JSON-safe before both: pids, refs, tuples and other terms become `inspect/1`
  strings, so the broadcast and the file always agree.
  """

  require Logger

  @doc """
  Writes one entry for agent (`%{id:, name:}`) and returns it. It is broadcast even if the
  file write fails; it then carries a `log_error` field, and its seq stays used, so the file
  shows a gap where it is missing.
  """
  def write(%{id: id, name: name}, type, fields) do
    entry =
      fields
      |> Map.merge(%{
        seq: Nano.StateStore.next_seq(id),
        at: now(),
        agent_id: id,
        agent: name,
        type: type
      })
      |> jsonable()

    dir = Application.fetch_env!(:nano, :log_dir)
    line = [Jason.encode!(entry), ?\n]

    entry =
      case with(
             :ok <- File.mkdir_p(dir),
             do: File.write(Path.join(dir, id <> ".jsonl"), line, [:append])
           ) do
        :ok ->
          entry

        {:error, reason} ->
          # Also where an operator without the dashboard will see why the agent halted.
          Logger.error("#{name} (#{id}): could not write #{type} to the log: #{inspect(reason)}")
          Map.put(entry, :log_error, inspect(reason))
      end

    # The file is the record; a broadcast that fails (Nano.PubSub was killed) only costs the
    # dashboard this entry.
    try do
      Phoenix.PubSub.broadcast(Nano.PubSub, "agent:" <> id, {:nano_log, entry})
    rescue
      ArgumentError -> :error
    end

    entry
  end

  @doc "Entries with seq > since, read back from the agent's JSONL file (string keys), in seq order."
  def read(id, since \\ 0) do
    path = Path.join(Application.fetch_env!(:nano, :log_dir), id <> ".jsonl")

    if File.exists?(path) do
      # A line being appended concurrently may be incomplete; it is skipped until it is whole.
      for line <- File.stream!(path),
          {:ok, entry} <- [Jason.decode(line)],
          entry["seq"] > since do
        entry
      end
      |> Enum.sort_by(& &1["seq"])
    else
      []
    end
  end

  @doc "Subscribes the caller to `{:nano_log, entry}` messages for an agent id."
  def subscribe(id), do: Phoenix.PubSub.subscribe(Nano.PubSub, "agent:" <> id)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp jsonable(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      {if(is_atom(k) or is_binary(k), do: k, else: inspect(k)), jsonable(v)}
    end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(bin) when is_binary(bin), do: if(String.valid?(bin), do: bin, else: inspect(bin))
  defp jsonable(term) when is_number(term) or is_atom(term), do: term
  defp jsonable(term), do: inspect(term)
end
