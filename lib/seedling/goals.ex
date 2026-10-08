defmodule Seedling.Goals do
  @moduledoc """
  Durable, agent-owned goal trees. Others may read any named agent's goals.

      {:ok, goal} = Seedling.Goals.add("lyra", "Build capability", why: "Survive restarts")
      Seedling.Goals.add("lyra", "Test it", parent: goal.id, why: "Verify behavior")
      Seedling.Goals.update("lyra", goal.id, status: :done)
      Seedling.Goals.review("lyra")

  State is atomically replaced JSON under `/data/seedling/goals`; `root:` isolates
  tests or projects. Names are hashed, never interpreted as paths. Mutations are
  serialized on this node. Reads never call an agent. Statuses: open, active,
  blocked, done, cancelled. Review is bounded; `list/2` returns the full flat tree.
  Marking a parent done does not silently complete its children. Review timing is
  the caller's choice (e.g. before idle). No harness hooks are installed.
  """
  @statuses ~w(open active blocked done cancelled)
  @max_bytes 262_144

  def list(agent, opts \\ []) do
    case read_bounded(path(agent, opts)) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, data} when byte_size(data) <= @max_bytes ->
        case Jason.decode(data, keys: :strings) do
          {:ok, %{"version" => 1, "goals" => goals}} when is_list(goals) ->
            if Enum.all?(goals, &valid?/1),
              do: {:ok, Enum.map(goals, &decode/1)},
              else: {:error, :corrupt}

          _ ->
            {:error, :corrupt}
        end

      {:ok, _} ->
        {:error, :too_large}

      error ->
        error
    end
  end

  def add(agent, title, opts \\ []) do
    mutate(agent, opts, fn goals ->
      parent = Keyword.get(opts, :parent)
      why = Keyword.get(opts, :why, "")

      cond do
        not text?(title) or not text?(why) ->
          {:error, :invalid_text}

        length(goals) >= 1000 ->
          {:error, :too_many_goals}

        parent != nil and not Enum.any?(goals, &(&1.id == parent)) ->
          {:error, :parent_not_found}

        true ->
          goal = %{
            id: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
            parent: parent,
            title: title,
            why: why,
            status: "open",
            updated_at: DateTime.to_iso8601(DateTime.utc_now())
          }

          {:ok, goal, goals ++ [goal]}
      end
    end)
  end

  def update(agent, id, changes, opts \\ []) do
    mutate(agent, opts, fn goals ->
      case Enum.find(goals, &(&1.id == id)) do
        nil ->
          {:error, :not_found}

        goal ->
          attrs = Map.new(changes)

          attrs =
            if Map.has_key?(attrs, :status),
              do: Map.update!(attrs, :status, &to_string/1),
              else: attrs

          updated = Map.merge(goal, attrs)

          cond do
            Enum.any?(Map.keys(attrs), &(&1 not in [:title, :why, :status])) ->
              {:error, :invalid_fields}

            not text?(updated.title) or not text?(updated.why) or updated.status not in @statuses ->
              {:error, :invalid_goal}

            true ->
              updated = %{updated | updated_at: DateTime.to_iso8601(DateTime.utc_now())}
              {:ok, updated, Enum.map(goals, fn g -> if g.id == id, do: updated, else: g end)}
          end
      end
    end)
  end

  def tree(agent, opts \\ []) do
    with {:ok, goals} <- list(agent, opts), do: {:ok, children(goals, nil)}
  end

  def review(agent, opts \\ []) do
    with {:ok, goals} <- list(agent, opts) do
      open = Enum.reject(goals, &(&1.status in ["done", "cancelled"]))
      limit = Keyword.get(opts, :limit, 8) |> max(0) |> min(50)

      lines =
        open
        |> Enum.take(limit)
        |> Enum.map_join("\n", fn g ->
          "[#{g.status}] #{g.id}: #{String.slice(g.title, 0, 160)} — why: #{String.slice(g.why, 0, 160)}"
        end)

      {:ok,
       "#{length(open)} open / #{length(goals)} total goals" <>
         if(lines == "", do: "", else: "\n" <> lines) <>
         if(length(open) > limit, do: "\n… #{length(open) - limit} more (list/2)", else: "")}
    end
  end

  @doc "Bounded plain dashboard rows; unreadable stores are reported, not hidden."
  def dashboard(agent, opts \\ []) do
    case list(agent, opts) do
      {:ok, goals} ->
        %{
          goals: Enum.reject(goals, &(&1.status in ["done", "cancelled"])) |> Enum.take(50),
          error: nil
        }

      {:error, reason} ->
        %{goals: [], error: inspect(reason)}
    end
  end

  defp children(goals, parent),
    do: for(g <- goals, g.parent == parent, do: Map.put(g, :children, children(goals, g.id)))

  defp text?(s), do: is_binary(s) and String.valid?(s) and byte_size(s) <= 4096

  defp valid?(g) when is_map(g),
    do:
      Enum.all?(~w(id title why status updated_at), &is_binary(g[&1])) and
        (is_nil(g["parent"]) or is_binary(g["parent"])) and g["status"] in @statuses

  defp valid?(_), do: false

  defp decode(g),
    do: %{
      id: g["id"],
      parent: g["parent"],
      title: g["title"],
      why: g["why"],
      status: g["status"],
      updated_at: g["updated_at"]
    }

  defp read_bounded(file) do
    case File.open(file, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @max_bytes + 1) do
            :eof -> {:ok, ""}
            {:error, _} = error -> error
            data -> {:ok, data}
          end
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp path(agent, opts) do
    name = :crypto.hash(:sha256, to_string(agent)) |> Base.encode16(case: :lower)
    Path.join(Keyword.get(opts, :root, "/data/seedling/goals"), name <> ".json")
  end

  defp mutate(agent, opts, fun) do
    file = path(agent, opts)

    :global.trans({{__MODULE__, file}, self()}, fn ->
      with {:ok, goals} <- list(agent, opts),
           {:ok, result, next} <- fun.(goals),
           data = Jason.encode!(%{version: 1, goals: next}),
           true <- byte_size(data) <= @max_bytes,
           :ok <- File.mkdir_p(Path.dirname(file)) do
        tmp = file <> "." <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"

        try do
          with :ok <- File.write(tmp, data, [:sync]),
               :ok <- File.rename(tmp, file),
               do: {:ok, result}
        after
          File.rm(tmp)
        end
      else
        false -> {:error, :too_large}
        error -> error
      end
    end)
  end
end
