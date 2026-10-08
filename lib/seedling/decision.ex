defmodule Seedling.Decision do
  @moduledoc """
  Reusable, optional Jev System One decision client for small typed judgements.

      Seedling.Decision.probability("A human asked me a question", "This message needs a reply")
      Seedling.Decision.evaluate("Recent activity ...", %{
        drift: %{type: "noul", instructions: "Activity diverged from the stated goal"}
      })

  `evaluate/3` returns `{:ok, %{answers: string_key_map, model: string, usage: map}}`
  or `{:error, reason}`. `probability/3` asks one Noul question and returns
  `{:ok, %{probability: number, model: string, usage: map}}`. Probabilities are
  model judgements, not facts or calibrated evidence of improved performance.
  This client never decides a caller's fallback policy or modifies its state.

  Uses `Nano.Settings.get("TYPESAFE_API_KEY")`; missing credentials are explicit
  and cause no network request. All HTTP/provider failures are honest errors,
  never plausible-looking scores. Options: `api_key`, `url`, `model` (default
  jev-latest), `timeout` (default 3,000ms), `transport` (one-argument request
  function for tests). No retries. Never logs keys or response bodies on errors.
  State is limited to 16,000 Unicode characters and 1..50 typed questions per
  request; callers should supply compact relevant state, never full history.

  Supported question types: Noul, Choice and Score, using Jev's native question
  schema. Answers are checked for requested IDs and corresponding types. Choice
  and Score retain their confidence/probability distributions for caller routing.
  See https://docs.typesafe.ai/introduction/quickstart.md for native schemas.
  """

  @doc "Evaluates typed questions against a compact state; preserves native string-key answers."
  def evaluate(state, questions, opts \\ []) do
    key =
      if Keyword.has_key?(opts, :api_key),
        do: opts[:api_key],
        else: Nano.Settings.get("TYPESAFE_API_KEY")

    cond do
      key in [nil, ""] ->
        {:error, :missing_credentials}

      not is_binary(key) ->
        {:error, :invalid_credentials}

      not is_binary(state) or not String.valid?(state) ->
        {:error, :invalid_state}

      String.length(state) > 16_000 ->
        {:error, :state_too_large}

      true ->
        with {:ok, questions} <- questions(questions) do
          request = [
            url: opts[:url] || "https://api.typesafe.ai/v1/systemone",
            headers: [{"authorization", "Bearer " <> key}],
            json: %{model: opts[:model] || "jev-latest", state: state, questions: questions},
            receive_timeout: opts[:timeout] || 3_000,
            retry: false
          ]

          transport = opts[:transport] || (&Req.post/1)

          case transport.(request) do
            {:ok, %{status: 200, body: %{"answers" => answers, "model" => model} = body}}
            when is_map(answers) and is_binary(model) ->
              if Enum.all?(questions, fn {id, q} -> valid_answer?(answers[id], q["type"]) end) and
                   is_map(body["usage"] || %{}),
                 do: {:ok, %{answers: answers, model: model, usage: body["usage"] || %{}}},
                 else: {:error, :invalid_response}

            {:ok, %{status: status}} when status != 200 ->
              {:error, {:http_status, status}}

            {:ok, _} ->
              {:error, :invalid_response}

            {:error, _} ->
              {:error, :transport_failed}
          end
        end
    end
  rescue
    _ -> {:error, :adapter_failed}
  catch
    _, _ -> {:error, :adapter_failed}
  end

  @doc "One yes/no Noul judgement; returns probability plus model and usage metadata."
  def probability(state, instructions, opts \\ []) do
    with {:ok, result} <-
           evaluate(state, %{judgement: %{type: "noul", instructions: instructions}}, opts) do
      {:ok,
       %{
         probability: result.answers["judgement"]["noul"],
         model: result.model,
         usage: result.usage
       }}
    end
  end

  defp questions(qs) when is_map(qs) and map_size(qs) in 1..50 do
    qs =
      Map.new(qs, fn {id, q} ->
        {to_string(id), Map.new(q, fn {k, v} -> {to_string(k), v} end)}
      end)

    if Enum.all?(qs, fn {id, q} ->
         id != "" and q["type"] in ~w(noul choice score) and is_binary(q["instructions"]) and
           q["instructions"] != ""
       end), do: {:ok, qs}, else: {:error, :invalid_questions}
  rescue
    _ -> {:error, :invalid_questions}
  end

  defp questions(_), do: {:error, :invalid_questions}

  defp valid_answer?(%{"type" => "noul", "noul" => p}, "noul"),
    do: is_number(p) and p >= 0 and p <= 1

  defp valid_answer?(
         %{"type" => "choice", "choice" => choice, "confidence" => c, "probabilities" => ps},
         "choice"
       ),
       do: is_binary(choice) and probability?(c) and probabilities?(ps)

  defp valid_answer?(
         %{"type" => "score", "score" => score, "confidence" => c, "probabilities" => ps},
         "score"
       ),
       do: is_number(score) and probability?(c) and probabilities?(ps)

  defp valid_answer?(_, _), do: false
  defp probability?(p), do: is_number(p) and p >= 0 and p <= 1

  defp probabilities?(ps) when is_map(ps) and map_size(ps) > 0,
    do: Enum.all?(ps, fn {_, p} -> probability?(p) end)

  defp probabilities?(_), do: false
end
