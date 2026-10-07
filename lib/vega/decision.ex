defmodule Vega.Decision do
  @moduledoc """
  Optional Jev typed-decision adapter. Never silently replaces service answers with heuristics.
  `evaluate(state, questions, api_key: key)` accepts documented noul/choice/score questions,
  returns validated answers/probabilities plus model and usage. Key defaults to
  TYPESAFE_API_KEY environment variable; no node settings changed or key logged.
  See docs/vega-decision.md. No credentials means {:error, :missing_api_key}.
  """
  def evaluate(state, questions, opts \\ []) do
    key = Keyword.get(opts, :api_key, System.get_env("TYPESAFE_API_KEY"))

    with true <- is_binary(key) and key != "",
         true <- valid_questions?(questions),
         {:ok, body} <-
           Jason.encode(%{
             state: state,
             questions: questions,
             model: Keyword.get(opts, :model, "jev-latest")
           }),
         true <- byte_size(body) <= 200_000 do
      options = [
        url: "https://api.typesafe.ai/v1/systemone",
        body: body,
        headers: [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}],
        receive_timeout: Keyword.get(opts, :timeout, 15_000),
        retry: false
      ]

      case Req.post(Keyword.merge(options, Keyword.get(opts, :req_options, []))) do
        {:ok, %{status: 200, body: %{"answers" => answers} = response}} ->
          if valid_answers?(answers, questions),
            do: {:ok, Map.take(response, ~w(model answers usage))},
            else: {:error, :invalid_response}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, _} ->
          {:error, :transport_error}
      end
    else
      false ->
        if(is_binary(key) and key != "",
          do: {:error, :invalid_request},
          else: {:error, :missing_api_key}
        )

      {:error, _} ->
        {:error, :invalid_request}
    end
  end

  defp valid_questions?(questions) do
    is_map(questions) and map_size(questions) in 1..64 and
      Enum.all?(questions, fn {id, q} ->
        is_binary(id) and is_map(q) and is_binary(q["instructions"]) and
          case q["type"] do
            "noul" -> true
            "choice" -> is_map(q["criteria"]) and map_size(q["criteria"]) > 0
            "score" -> is_list(q["criteria"]) and length(q["criteria"]) > 0
            _ -> false
          end
      end)
  end

  defp probability?(v), do: is_number(v) and v >= 0 and v <= 1

  defp probabilities?(p, keys) do
    is_map(p) and Enum.sort(Map.keys(p)) == Enum.sort(keys) and
      Enum.all?(Map.values(p), &probability?/1) and
      abs(Enum.sum(Map.values(p)) - 1) < 0.02
  end

  defp valid_answers?(answers, questions) do
    is_map(answers) and Enum.sort(Map.keys(answers)) == Enum.sort(Map.keys(questions)) and
      Enum.all?(questions, fn {id, q} ->
        a = answers[id]

        is_map(a) and a["type"] == q["type"] and
          case q["type"] do
            "noul" ->
              probability?(a["noul"])

            "choice" ->
              Map.has_key?(q["criteria"], a["choice"]) and probability?(a["confidence"]) and
                probabilities?(a["probabilities"], Map.keys(q["criteria"]))

            "score" ->
              is_number(a["score"]) and a["score"] >= 0 and
                a["score"] <= length(q["criteria"]) - 1 and
                probability?(a["confidence"]) and
                probabilities?(
                  a["probabilities"],
                  Enum.map(0..(length(q["criteria"]) - 1), &to_string/1)
                )
          end
      end)
  end
end
