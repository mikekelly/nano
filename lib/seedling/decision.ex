defmodule Seedling.Decision do
  @moduledoc """
  Typed TypeSafe/Jev decisions, not text-generation calls.

      Seedling.Decision.evaluate(%{message: "Please help now"}, %{
        "urgent" => Seedling.Decision.noul("Does the message need a human now?")
      })

  Returns `{:ok, %{answers: map, model: string, usage: map}}` or a sanitized
  `{:error, reason}`. Supports noul, choice and score, validates typed answers and
  probabilities, limits input to 64 KB and 64 questions. HTTP timeout 3 seconds,
  no retries, no logging secrets or provider error bodies. Credentials are read
  from TYPESAFE_API_KEY at call time. For tests pass `key:`, `url:` (port 0 fake),
  or `transport:` function receiving the Req options. Call outside a page render
  or service GenServer; a decision is network IO, not a cheap dashboard read.
  """
  def noul(question), do: %{"type" => "noul", "instructions" => question}

  def choice(question, criteria),
    do: %{"type" => "choice", "instructions" => question, "criteria" => criteria}

  def score(question, levels),
    do: %{"type" => "score", "instructions" => question, "criteria" => levels}

  def evaluate(state, questions, opts \\ []) do
    key = Keyword.get_lazy(opts, :key, fn -> Nano.Settings.get("TYPESAFE_API_KEY") end)

    payload = %{
      state: state,
      questions: questions,
      model: Keyword.get(opts, :model, "jev-latest")
    }

    with :ok <- credentials(key),
         :ok <- validate_questions(questions),
         {:ok, encoded} <- Jason.encode(payload),
         :ok <- if(byte_size(encoded) <= 64_000, do: :ok, else: {:error, :input_too_large}) do
      options = [
        url: Keyword.get(opts, :url, "https://api.typesafe.ai/v1/systemone"),
        auth: {:bearer, key},
        json: payload,
        receive_timeout: Keyword.get(opts, :timeout, 3000),
        connect_options: [timeout: Keyword.get(opts, :timeout, 3000)],
        retry: false
      ]

      transport = Keyword.get(opts, :transport, &Req.post/1)

      case transport.(options) do
        {:ok, %{status: 200, body: %{"answers" => answers} = body}} ->
          with :ok <- validate_answers(questions, answers),
               do: {:ok, %{answers: answers, model: body["model"], usage: body["usage"] || %{}}}

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, error} ->
          {:error, {:decision_unavailable, transport_reason(error)}}

        _ ->
          {:error, :invalid_response}
      end
    end
  rescue
    e in [ArgumentError, FunctionClauseError, KeyError, BadMapError, UndefinedFunctionError] ->
      {:error, {:adapter_error, e.__struct__}}

    _ ->
      {:error, :decision_unavailable}
  catch
    :exit, _ -> {:error, :decision_unavailable}
  end

  defp transport_reason(%{reason: reason})
       when reason in [:timeout, :closed, :econnrefused, :nxdomain], do: reason

  defp transport_reason(_), do: :network_error

  defp credentials(key),
    do: if(is_binary(key) and key != "", do: :ok, else: {:error, :missing_typesafe_api_key})

  defp validate_questions(qs) when is_map(qs) and map_size(qs) in 1..64 do
    if Enum.all?(qs, fn {k, q} -> is_binary(k) and valid_question?(q) end),
      do: :ok,
      else: {:error, :invalid_questions}
  end

  defp validate_questions(_), do: {:error, :invalid_questions}

  defp valid_question?(%{"type" => t, "instructions" => i} = q)
       when t in ~w(noul choice score) and not is_nil(i) do
    case t do
      "noul" -> true
      "choice" -> is_map(q["criteria"]) and map_size(q["criteria"]) in 2..255
      "score" -> is_list(q["criteria"]) and length(q["criteria"]) in 2..10
    end
  end

  defp valid_question?(_), do: false
  defp probability?(p), do: is_number(p) and p >= 0 and p <= 1

  defp validate_answers(qs, answers) when is_map(answers) do
    if map_size(qs) == map_size(answers) and
         Enum.all?(qs, fn {k, q} -> valid_answer?(q, answers[k]) end),
       do: :ok,
       else: {:error, :invalid_response}
  end

  defp validate_answers(_, _), do: {:error, :invalid_response}
  defp valid_answer?(%{"type" => "noul"}, %{"type" => "noul", "noul" => p}), do: probability?(p)

  defp valid_answer?(%{"type" => "choice", "criteria" => c}, %{
         "type" => "choice",
         "choice" => chosen,
         "probabilities" => ps,
         "confidence" => confidence
       }) do
    is_map(ps) and Map.has_key?(c, chosen) and Enum.sort(Map.keys(ps)) == Enum.sort(Map.keys(c)) and
      probability?(confidence) and Enum.all?(ps, fn {_, p} -> probability?(p) end)
  end

  defp valid_answer?(%{"type" => "score", "criteria" => c}, %{
         "type" => "score",
         "score" => score,
         "probabilities" => ps,
         "confidence" => confidence
       }) do
    is_number(score) and score >= 0 and score <= length(c) - 1 and probability?(confidence) and
      is_map(ps) and
      Enum.sort(Map.keys(ps)) == Enum.map(0..(length(c) - 1), &to_string/1) |> Enum.sort() and
      Enum.all?(ps, fn {_, p} -> probability?(p) end)
  end

  defp valid_answer?(_, _), do: false
end
