defmodule Vega.Bots.Relevance do
  @moduledoc "Bounded cheap typed relevance judgment for identity memories; provider failure uses disclosed lexical fallback, never a big-model judgment loop."
  def retrieve(bot_id, query, root, opts \\ []) do
    identity = "bot:" <> bot_id

    fallback = fn ->
      Vega.Memory.retrieve(identity, query, root: root, limit: 4, max_bytes: 5000)
    end

    key =
      Keyword.get_lazy(opts, :api_key, fn ->
        Nano.Settings.get("TYPESAFE_API_KEY") || System.get_env("TYPESAFE_API_KEY")
      end)

    if is_binary(key) and key != "" do
      with {:ok, candidates} <-
             Vega.Memory.retrieve(identity, "", root: root, limit: 20, max_bytes: 12000) do
        if candidates == [] do
          {:ok, []}
        else
          questions =
            Map.new(candidates, fn m ->
              {m["id"],
               %{
                 "type" => "noul",
                 "instructions" =>
                   "Probability this memory is relevant and useful to the person's current message; not merely about the same broad topic. Memory: " <>
                     m["content"]
               }}
            end)

          decision = Keyword.get(opts, :decision, Vega.Decision)

          case decision.evaluate(%{"message" => query}, questions, api_key: key, timeout: 3000) do
            {:ok, %{"answers" => answers}} ->
              ranked =
                Enum.filter(candidates, &(answers[&1["id"]]["noul"] >= 0.5))
                |> Enum.sort_by(&answers[&1["id"]]["noul"], :desc)

              {selected, _} =
                Enum.reduce(ranked, {[], 2}, fn m, {acc, used} ->
                  bytes = byte_size(Jason.encode!(m)) + 1

                  if length(acc) < 4 and used + bytes <= 5000,
                    do: {acc ++ [m], used + bytes},
                    else: {acc, used}
                end)

              {:ok, selected}

            _ ->
              fallback.()
          end
        end
      end
    else
      fallback.()
    end
  end
end
