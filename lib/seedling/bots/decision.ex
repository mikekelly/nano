defmodule Seedling.Bots.Decision do
  @moduledoc "Jev Noul judgments following docs.typesafe.ai/introduction/quickstart. Fail-open chat routing; no invented decisions."
  def ask(state, questions, opts \\ []) do
    key = opts[:key] || Nano.Settings.get("TYPESAFE_API_KEY")

    if is_binary(key) and key != "" do
      body = %{
        model: "jev-latest",
        state: state,
        questions:
          Map.new(questions, fn {id, instruction} ->
            {id, %{type: "noul", instructions: instruction}}
          end)
      }

      case Req.post(opts[:url] || "https://api.typesafe.ai/v1/systemone",
             auth: {:bearer, key},
             json: body,
             receive_timeout: 8000,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"answers" => answers}}} ->
          if Enum.all?(questions, fn {id, _} ->
               match?(%{"noul" => n} when is_number(n) and n >= 0 and n <= 1, answers[id])
             end) do
            {:ok, Map.new(answers, fn {id, a} -> {id, a["noul"]} end)}
          else
            {:error, :invalid_answers}
          end

        {:ok, %{status: status}} ->
          {:error, {:http, status}}

        {:error, _} ->
          {:error, :unavailable}
      end
    else
      {:error, :missing_key}
    end
  end

  def relevant([], _query), do: []

  def relevant(memories, query) do
    questions =
      Map.new(
        memories,
        &{&1.id, "Would memory #{inspect(&1.text)} help answer the current user message?"}
      )

    case ask(query, questions) do
      {:ok, scores} ->
        memories
        |> Enum.filter(&(scores[&1.id] >= 0.65))
        |> Enum.sort_by(&scores[&1.id], :desc)
        |> Enum.take(5)

      _ ->
        Enum.take(memories, 5)
    end
  end
end
