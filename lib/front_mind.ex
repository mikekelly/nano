defmodule FrontMind do
  @moduledoc """
  An agent's own durable note, at most 1000 Unicode characters (not outside instructions).

      FrontMind.set(me, "Finish tests before reporting; do not load shared modules.")
      FrontMind.configure(me, bobbing: true, threshold_tokens: 8000, drift: false)
      FrontMind.get("worker")
      FrontMind.clear(me)

  Names or registered pids are accepted. Separate atomic files under state_dir survive
  restarts/compaction. Drift is opt-in and sends only note plus bounded recent activity
  to Nano.Decision. Configuration and measurements appear on the timeline.
  """
  @defaults %{
    note: nil,
    written_at: nil,
    version: nil,
    bobbing: true,
    threshold_tokens: 8000,
    drift: false,
    drift_interval_tokens: 16000
  }
  def set(agent, note) when is_binary(note) do
    if String.valid?(note) and String.length(note) <= 1000 and String.trim(note) != "" do
      mutate(
        agent,
        fn data -> Map.merge(data, %{note: note, written_at: now(), version: version()}) end,
        :frontmind_set
      )
    else
      {:error, :note_must_be_1_to_1000_characters}
    end
  end

  def set(_, _), do: {:error, :note_must_be_1_to_1000_characters}

  def clear(agent),
    do:
      mutate(
        agent,
        &Map.merge(&1, %{note: nil, written_at: nil, version: version()}),
        :frontmind_cleared
      )

  def configure(agent, opts) do
    options = Map.new(opts)

    if Enum.all?(options, fn
         {k, v} when k in [:bobbing, :drift] -> is_boolean(v)
         {k, v} when k in [:threshold_tokens, :drift_interval_tokens] -> is_integer(v) and v > 0
         _ -> false
       end),
       do: mutate(agent, &Map.merge(&1, options), :frontmind_configured),
       else: {:error, :invalid_configuration}
  end

  def get(agent) do
    with {:ok, name} <- name(agent), do: read(path(name))
  end

  def name(agent) when is_binary(agent) do
    if Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, agent),
      do: {:ok, agent},
      else: {:error, :invalid_agent}
  end

  def name(pid) when is_pid(pid) do
    case Enum.find(Nano.Names.all(), fn {key, p} -> match?({:agent, _}, key) and p == pid end) do
      {{:agent, name}, _} -> {:ok, name}
      _ -> {:error, :unknown_agent}
    end
  end

  def name(_), do: {:error, :invalid_agent}

  defp mutate(agent, fun, type) do
    with {:ok, name} <- name(agent) do
      :global.trans({{__MODULE__, path(name)}, self()}, fn ->
        with {:ok, old} <- read(path(name)), data = fun.(old), :ok <- persist(path(name), data) do
          log(
            name,
            type,
            Map.take(data, [
              :bobbing,
              :drift,
              :threshold_tokens,
              :drift_interval_tokens,
              :written_at
            ])
          )

          {:ok, data}
        end
      end)
    end
  end

  defp path(name),
    do: Path.join([Application.fetch_env!(:nano, :state_dir), "frontmind", name <> ".json"])

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, @defaults}

      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, data} when is_map(data) ->
            data =
              Map.new(@defaults, fn {k, default} ->
                {k, Map.get(data, Atom.to_string(k), default)}
              end)

            if valid_data?(data), do: {:ok, data}, else: {:error, :invalid_frontmind_file}

          _ ->
            {:error, :invalid_frontmind_file}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_data?(data) do
    (data.note == nil or
       (is_binary(data.note) and String.valid?(data.note) and String.length(data.note) <= 1000)) and
      is_boolean(data.bobbing) and is_boolean(data.drift) and
      is_integer(data.threshold_tokens) and data.threshold_tokens > 0 and
      is_integer(data.drift_interval_tokens) and data.drift_interval_tokens > 0 and
      (data.written_at == nil or is_binary(data.written_at)) and
      (data.version == nil or is_binary(data.version))
  end

  defp persist(path, data) do
    temp = path <> "." <> version()

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, Jason.encode!(data), [:sync]),
           do: File.rename(temp, path)

    File.rm(temp)
    result
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp version, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp log(name, type, fields) do
    case Nano.StateStore.get(name) do
      %{id: _, name: _} = s ->
        Nano.Log.write(
          s,
          :harness_note,
          Map.merge(fields, %{
            kind: type,
            text:
              "Front of mind #{type}: bobbing=#{fields[:bobbing]}, drift=#{fields[:drift]}, threshold_tokens=#{fields[:threshold_tokens]}, drift_interval_tokens=#{fields[:drift_interval_tokens]}"
          })
        )

      _ ->
        :ok
    end
  end
end
