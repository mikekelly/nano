defmodule Goals do
  @moduledoc """
  Durable goals in state_dir/goals, separate from agent state. Names survive restarts;
  pids resolve through Nano.Names without agent calls. Reads are cheap local files.
  Mutations serialize per file and atomically rename; failures return {:error, reason}.

      {:ok, goal} = Goals.add("builder", "Ship", why: "Help users", next_step: "Test")
      Goals.update("builder", goal.id, status: :active)
      Goals.tree("builder")
      Goals.review("builder", max_chars: 1200, limit: 8)

  tree returns nested maps with children. review defaults to 4000 characters/20 goals.
  current returns nil or %{text: bounded_string, version: integer, written_at: ISO,
  threshold_tokens: integer}. Configure bobbing (default true) and threshold_tokens
  (default 8000) with configure/2. Missing/unavailable reads are empty.
  """
  @statuses [:pending, :active, :blocked, :done, :cancelled]
  @max_file 2_000_000
  def add(agent, title, opts \\ []) do
    mutate(agent, fn s ->
      g = %{
        id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        title: title,
        why: opts[:why],
        parent: opts[:parent],
        status: opts[:status] || :pending,
        next_step: opts[:next_step],
        created_at: now(),
        updated_at: now()
      }

      with :ok <- valid(g, s.goals), do: {:ok, %{s | goals: s.goals ++ [g]}, g}
    end)
  end

  def update(agent, id, attrs) do
    mutate(agent, fn s ->
      case Enum.find(s.goals, &(&1.id == id)) do
        nil ->
          {:error, :not_found}

        old ->
          attrs = Map.new(attrs)

          if Enum.any?(Map.keys(attrs), &(&1 not in [:title, :why, :parent, :status, :next_step])) do
            {:error, :invalid_attributes}
          else
            g = old |> Map.merge(attrs) |> Map.put(:updated_at, now())

            with :ok <- valid(g, s.goals),
                 do: {:ok, %{s | goals: Enum.map(s.goals, &if(&1.id == id, do: g, else: &1))}, g}
          end
      end
    end)
  end

  def configure(agent, opts) do
    mutate(agent, fn s ->
      c = Map.merge(s.config, Map.new(opts))

      if is_boolean(c.bobbing) and is_integer(c.threshold_tokens) and c.threshold_tokens > 0 and
           Map.keys(c) -- [:bobbing, :threshold_tokens] == [] do
        {:ok, %{s | config: c}, c}
      else
        {:error, :invalid_configuration}
      end
    end)
  end

  def tree(agent), do: children(read(agent).goals, nil)

  def review(agent, opts \\ []) do
    max = bounded(opts[:max_chars], 4000, 1, 16000)
    limit = bounded(opts[:limit], 20, 1, 100)
    goals = Enum.filter(read(agent).goals, &(&1.status not in [:done, :cancelled]))

    text =
      if goals == [],
        do: "No open goals.",
        else:
          Enum.map_join(Enum.take(goals, limit), "\n", &line/1) <>
            if(length(goals) > limit, do: "\n… more goals omitted", else: "")

    truncate(text, max)
  end

  def current(agent) do
    s = read(agent)

    g =
      Enum.find(s.goals, &(&1.status == :active)) ||
        Enum.find(s.goals, &(&1.status in [:pending, :blocked]))

    if s.config.bobbing and g,
      do: %{
        text: truncate(line(g), 1500),
        version: s.version,
        written_at: s.written_at,
        threshold_tokens: s.config.threshold_tokens
      }
  end

  defp line(g),
    do: "[#{g.status}] #{g.title} (#{g.id}) — why: #{g.why}; next: #{g.next_step || g.title}"

  defp truncate(t, n), do: if(String.length(t) > n, do: String.slice(t, 0, n - 1) <> "…", else: t)
  defp bounded(n, _, low, high) when is_integer(n), do: min(max(n, low), high)
  defp bounded(_, default, _, _), do: default

  defp children(gs, p),
    do: for(g <- gs, g.parent == p, do: Map.put(g, :children, children(gs, g.id)))

  defp valid(g, gs) do
    cond do
      not nonempty?(g.title) -> {:error, :title_required}
      not nonempty?(g.why) -> {:error, :why_required}
      g.status not in @statuses -> {:error, :invalid_status}
      g.next_step != nil and not nonempty?(g.next_step) -> {:error, :invalid_next_step}
      g.parent != nil and not Enum.any?(gs, &(&1.id == g.parent)) -> {:error, :parent_not_found}
      cycle?(g.parent, g.id, gs) -> {:error, :cycle}
      true -> :ok
    end
  end

  defp nonempty?(s),
    do: is_binary(s) and String.valid?(s) and String.trim(s) != "" and byte_size(s) <= 16000

  defp cycle?(parent, id, goals),
    do: cycle_walk(parent, Map.new(goals, &{&1.id, &1.parent}), MapSet.new([id]))

  defp cycle_walk(nil, _, _), do: false

  defp cycle_walk(parent, parents, seen) do
    if MapSet.member?(seen, parent),
      do: true,
      else: cycle_walk(Map.get(parents, parent), parents, MapSet.put(seen, parent))
  end

  defp mutate(agent, fun) do
    with {:ok, path} <- path(agent) do
      :global.trans(
        {{__MODULE__, path}, self()},
        fn ->
          with {:ok, s} <- load(path),
               {:ok, s, result} <- fun.(s),
               s = %{s | version: s.version + 1, written_at: now()},
               :ok <- persist(path, s),
               do: {:ok, result}
        end,
        [node()]
      )
    end
  end

  defp read(agent) do
    with {:ok, p} <- path(agent), {:ok, s} <- load(p), do: s, else: (_ -> empty())
  end

  defp empty,
    do: %{
      goals: [],
      version: 0,
      written_at: nil,
      config: %{bobbing: true, threshold_tokens: 8000}
    }

  defp path(pid) when is_pid(pid) do
    case Enum.find(Nano.Names.all(), fn {key, p} -> match?({:agent, _}, key) and p == pid end) do
      {{:agent, name}, _} -> path(name)
      _ -> {:error, :unknown_agent}
    end
  end

  defp path(name) when is_binary(name) do
    if name =~ ~r/^[\w.-]+$/u and name not in [".", ".."],
      do: {:ok, Path.join([Application.fetch_env!(:nano, :state_dir), "goals", name <> ".term"])},
      else: {:error, :invalid_agent}
  end

  defp path(_), do: {:error, :invalid_agent}

  defp load(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_file,
         {:ok, data} <- File.read(path),
         %{goals: gs, version: v, written_at: _, config: %{bobbing: _, threshold_tokens: _}} = s <-
           :erlang.binary_to_term(data, [:safe]),
         true <- is_list(gs) and is_integer(v) and v >= 0,
         true <- valid_state?(s),
         do: {:ok, s},
         else: (
           {:error, :enoent} -> {:ok, empty()}
           _ -> {:error, :corrupt_goals}
         )
  rescue
    _ -> {:error, :corrupt_goals}
  end

  defp valid_state?(s) do
    is_boolean(s.config.bobbing) and is_integer(s.config.threshold_tokens) and
      s.config.threshold_tokens > 0 and
      (s.written_at == nil or match?({:ok, _, _}, DateTime.from_iso8601(s.written_at))) and
      Enum.all?(s.goals, fn g ->
        is_binary(g.id) and nonempty?(g.title) and nonempty?(g.why) and
          g.status in @statuses and (g.parent == nil or is_binary(g.parent)) and
          (g.next_step == nil or nonempty?(g.next_step)) and
          is_binary(g.created_at) and is_binary(g.updated_at)
      end) and
      length(Enum.uniq_by(s.goals, & &1.id)) == length(s.goals)
  end

  defp persist(path, s) do
    data = :erlang.term_to_binary(s)
    temp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    if byte_size(data) > @max_file do
      {:error, :goals_too_large}
    else
      result =
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(temp, data, [:binary, :sync]),
             :ok <- File.rename(temp, path),
             do: :ok

      File.rm(temp)
      result
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
