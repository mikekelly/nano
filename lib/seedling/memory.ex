defmodule Seedling.Memory do
  @moduledoc """
  Durable per-bot linked facts. `add(bot_id, text, source_session: id, links: [id],
  tags: [string])` returns {:ok, node}; `retrieve(bot_id, query, limit: 5,
  budget: 2000)` returns {:ok, nodes}, bounded by total text bytes. Nodes use string keys.
  `all(bot_id)` inspects the graph. Files are hashed bot IDs under :nano, :memory_dir
  (default /data/state/bot_memory). Atomic writes, serialized per store; no process state.
  Retrieval uses lexical overlap plus one-hop links; optionally `decision: true` asks
  Seedling.Decision to rank a bounded shortlist (decision_opts forwarded). Model errors
  return errors, not guessed rankings. This is a small graph, not an embedding database.
  Do not store credentials; callers control what is remembered and when.
  """
  def add(bot, text, opts \\ []) do
    if valid_id?(bot) and is_binary(text) and String.valid?(text) and byte_size(text) in 1..16_000 and
         valid_ids?(Keyword.get(opts, :links, [])) and valid_ids?(Keyword.get(opts, :tags, [])) and
         (is_nil(opts[:source_session]) or valid_id?(opts[:source_session])) do
      locked(bot, fn path ->
        with {:ok, nodes} <- load(path),
             true <- Enum.all?(Keyword.get(opts, :links, []), &Map.has_key?(nodes, &1)) do
          node = %{
            "id" => Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
            "text" => text,
            "source_session" => opts[:source_session],
            "links" => Enum.uniq(Keyword.get(opts, :links, [])),
            "tags" => Enum.uniq(Keyword.get(opts, :tags, [])),
            "created_at" => DateTime.to_iso8601(DateTime.utc_now())
          }

          with :ok <- persist(path, Map.put(nodes, node["id"], node)), do: {:ok, node}
        else
          false -> {:error, :unknown_link}
          error -> error
        end
      end)
    else
      {:error, :invalid_memory}
    end
  end

  def all(bot) do
    if valid_id?(bot),
      do:
        locked(bot, fn path -> with {:ok, nodes} <- load(path), do: {:ok, Map.values(nodes)} end),
      else: {:error, :invalid_bot}
  end

  def retrieve(bot, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    budget = Keyword.get(opts, :budget, 2000)

    if is_binary(query) and String.valid?(query) and byte_size(query) <= 16_000 and
         is_integer(limit) and limit in 0..50 and is_integer(budget) and budget in 0..32_000 do
      with {:ok, nodes} <- all(bot),
           {:ok, ranked} <- rank(nodes, query, opts) do
        {selected, _} =
          Enum.reduce(ranked, {[], budget}, fn node, {acc, remaining} ->
            size = byte_size(node["text"])

            if length(acc) < limit and size <= remaining,
              do: {[node | acc], remaining - size},
              else: {acc, remaining}
          end)

        {:ok, Enum.reverse(selected)}
      end
    else
      {:error, :invalid_retrieval}
    end
  end

  defp rank(nodes, query, opts) do
    terms = terms(query)

    scores =
      Map.new(nodes, fn n ->
        {n["id"],
         MapSet.size(
           MapSet.intersection(terms, terms(n["text"] <> " " <> Enum.join(n["tags"], " ")))
         )}
      end)

    ranked =
      nodes
      |> Enum.map(fn n ->
        linked =
          Enum.reduce(n["links"], 0, fn id, score -> max(score, Map.get(scores, id, 0)) end)

        incoming =
          Enum.reduce(nodes, 0, fn other, score ->
            if n["id"] in other["links"], do: max(score, scores[other["id"]]), else: score
          end)

        {n, scores[n["id"]] * 10 + max(linked, incoming)}
      end)
      |> Enum.filter(fn {_, score} -> score > 0 end)
      |> Enum.sort_by(fn {n, score} -> {-score, n["id"]} end)
      |> Enum.take(30)
      |> Enum.map(&elem(&1, 0))

    if opts[:decision] == true and ranked != [] do
      with {:ok, result} <-
             Seedling.Decision.decide(
               :memory,
               %{query: query, candidates: ranked},
               Keyword.get(opts, :decision_opts, [])
             ),
           true <-
             Enum.all?(result.data["memory_ids"], fn id ->
               Enum.any?(ranked, &(&1["id"] == id))
             end) do
        {:ok,
         Enum.map(Enum.uniq(result.data["memory_ids"]), fn id ->
           Enum.find(ranked, &(&1["id"] == id))
         end)}
      else
        false -> {:error, :unknown_memory_id}
        error -> error
      end
    else
      {:ok, ranked}
    end
  end

  defp terms(text),
    do:
      Regex.scan(~r/[\p{L}\p{N}_]+/u, String.downcase(text))
      |> List.flatten()
      |> Enum.filter(&(String.length(&1) > 1))
      |> MapSet.new()

  defp valid_id?(id), do: is_binary(id) and String.valid?(id) and byte_size(id) in 1..200
  defp valid_ids?(ids), do: is_list(ids) and length(ids) <= 100 and Enum.all?(ids, &valid_id?/1)

  defp locked(bot, fun) do
    dir =
      Application.get_env(
        :nano,
        :memory_dir,
        Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "bot_memory")
      )

    path = Path.join(dir, Base.encode16(:crypto.hash(:sha256, bot), case: :lower) <> ".json")
    :global.trans({{__MODULE__, path}, self()}, fn -> fun.(path) end)
  end

  defp load(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, nodes} when is_map(nodes) ->
            if Enum.all?(nodes, fn {id, n} ->
                 is_map(n) and n["id"] == id and is_binary(n["text"]) and valid_ids?(n["links"]) and
                   valid_ids?(n["tags"])
               end), do: {:ok, nodes}, else: {:error, :corrupt_memory_store}

          _ ->
            {:error, :corrupt_memory_store}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      error ->
        error
    end
  end

  defp persist(path, nodes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", Jason.encode!(nodes), [:sync]),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end
end
