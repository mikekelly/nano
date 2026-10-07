defmodule Seedling.Goals do
  @moduledoc """
  Durable goal trees keyed by stable agent name (not pid). All agents may read/write;
  this sandbox has no access control. No model calls, automatic reviews or harness changes.
  Files live under :nano, :goals_dir (default /data/seedling/goals). Updates are
  serialized on this node and atomically replace JSON files. Reads never call agents.
  """
  @statuses ~w(pending active blocked done cancelled)
  @closed ~w(done cancelled)

  def list(agent, opts \\ []) do
    with {:ok, path} <- path(agent), {:ok, goals} <- read_agent(path, agent) do
      {:ok,
       if(Keyword.get(opts, :open, false),
         do: Enum.reject(goals, &(&1["status"] in @closed)),
         else: goals
       )}
    end
  end

  def get(agent, id) do
    with {:ok, goals} <- list(agent) do
      case Enum.find(goals, &(&1["id"] == id)) do
        nil -> {:error, :not_found}
        goal -> {:ok, goal}
      end
    end
  end

  @doc "Save legacy base64-named goals under the current filename; existing current files take precedence."
  def migrate_legacy(agent), do: mutate(agent, fn goals -> {:ok, goals, goals} end)

  @doc "Create a goal with optional :parent, :why, :status. Returns {:ok, goal}."
  def add(agent, title, opts \\ []) do
    attrs = %{
      "title" => title,
      "why" => Keyword.get(opts, :why, ""),
      "status" => to_string(Keyword.get(opts, :status, :pending)),
      "parent" => Keyword.get(opts, :parent)
    }

    mutate(agent, fn goals ->
      with :ok <- validate(attrs),
           true <- attrs["parent"] == nil or Enum.any?(goals, &(&1["id"] == attrs["parent"])) do
        now = DateTime.to_iso8601(DateTime.utc_now())

        goal =
          Map.merge(attrs, %{
            "id" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
            "created_at" => now,
            "updated_at" => now,
            "note" => ""
          })

        {:ok, goals ++ [goal], goal}
      else
        false -> {:error, :parent_not_found}
        error -> error
      end
    end)
  end

  @doc "Update title, why, status or note. Parentage is immutable; completion is explicit, never cascaded."
  def update(agent, id, attrs) when is_map(attrs) or is_list(attrs) do
    attrs =
      Map.new(attrs, fn {k, v} ->
        {to_string(k), if(k in [:status, "status"], do: to_string(v), else: v)}
      end)

    mutate(agent, fn goals ->
      with true <- Enum.all?(Map.keys(attrs), &(&1 in ~w(title why status note))),
           goal when not is_nil(goal) <- Enum.find(goals, &(&1["id"] == id)),
           updated = Map.merge(goal, attrs),
           :ok <- validate(updated) do
        updated = Map.put(updated, "updated_at", DateTime.to_iso8601(DateTime.utc_now()))
        {:ok, Enum.map(goals, &if(&1["id"] == id, do: updated, else: &1)), updated}
      else
        false -> {:error, :invalid_fields}
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def complete(agent, id, note \\ ""), do: update(agent, id, status: :done, note: note)

  @doc "Compact review: counts and at most :limit open goals (default 8), text capped at :chars (default 2000)."
  def review(agent, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    chars = Keyword.get(opts, :chars, 2000)

    if is_integer(limit) and limit >= 0 and is_integer(chars) and chars >= 0 do
      with {:ok, goals} <- list(agent) do
        open = Enum.reject(goals, &(&1["status"] in @closed))
        counts = Enum.frequencies_by(goals, & &1["status"])

        lines =
          Enum.take(open, limit)
          |> Enum.map_join("\n", fn g ->
            "#{g["id"]} [#{g["status"]}] #{g["title"]}" <>
              if(g["parent"], do: " (parent #{g["parent"]})", else: "") <>
              if(g["why"] != "", do: " — #{g["why"]}", else: "")
          end)

        text = "Goals: #{length(open)} open / #{length(goals)} total\n" <> lines

        {:ok,
         %{
           counts: counts,
           open: length(open),
           total: length(goals),
           text: String.slice(text, 0, chars),
           truncated: length(open) > limit or String.length(text) > chars
         }}
      end
    else
      {:error, :invalid_limits}
    end
  end

  defp validate(g) do
    cond do
      not is_binary(g["title"]) or String.trim(g["title"]) == "" or byte_size(g["title"]) > 2000 ->
        {:error, :invalid_title}

      g["status"] not in @statuses ->
        {:error, :invalid_status}

      not is_binary(g["why"]) or byte_size(g["why"]) > 8000 ->
        {:error, :invalid_why}

      Map.has_key?(g, "note") and (not is_binary(g["note"]) or byte_size(g["note"]) > 8000) ->
        {:error, :invalid_note}

      true ->
        :ok
    end
  end

  defp path(agent) when is_binary(agent) and byte_size(agent) > 0 and byte_size(agent) <= 200 do
    {:ok,
     Path.join(
       Application.get_env(:nano, :goals_dir, "/data/seedling/goals"),
       Base.encode16(:crypto.hash(:sha256, agent), case: :lower) <> ".json"
     )}
  end

  defp path(_), do: {:error, :invalid_agent}

  # Legacy live-loaded versions used base64 names; upgrade on the next update.
  defp read_agent(path, agent) do
    if File.exists?(path) or byte_size(agent) > 180 do
      read(path)
    else
      legacy = Path.join(Path.dirname(path), Base.url_encode64(agent, padding: false) <> ".json")
      read(legacy)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:storage, reason}}

      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"version" => 1, "goals" => goals}} when is_list(goals) ->
            if Enum.all?(goals, fn g ->
                 is_map(g) and validate(g) == :ok and is_binary(g["id"]) and
                   Map.has_key?(g, "parent")
               end), do: {:ok, goals}, else: {:error, :corrupt_storage}

          _ ->
            {:error, :corrupt_storage}
        end
    end
  end

  defp mutate(agent, fun) do
    with {:ok, path} <- path(agent) do
      :global.trans(
        {{__MODULE__, path}, self()},
        fn ->
          with {:ok, goals} <- read_agent(path, agent),
               {:ok, next, result} <- fun.(goals),
               :ok <- write(path, next) do
            {:ok, result}
          end
        end,
        [node()]
      )
    end
  end

  defp write(path, goals) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, Jason.encode!(%{version: 1, goals: goals}), [:sync]),
           :ok <- File.rename(tmp, path),
           do: :ok

    File.rm(tmp)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end
end
