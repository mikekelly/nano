defmodule Nano.Decision do
  @moduledoc """
  Bounded Jev client; protocol: https://docs.typesafe.ai/api.md.

      Nano.Decision.evaluate("Work is finished", %{
        "drift" => Nano.Decision.noul("Has work drifted from the goal?")
      }, timeout: 2_000)

  Returns {:ok, %{model: string, answers: map, usage: map}} or {:error, reason}.
  Answer fields are atoms; question and probability keys remain strings.
  Options: :timeout (5000ms, 1..30000), :model (jev-latest), :api_key
  (defaults to Nano.Settings TYPESAFE_API_KEY), :transport (function/1).
  Transport receives %{url: ..., headers: ..., body: ..., timeout: ...} and
  returns {:ok, %{status: integer, body: decoded JSON}} or {:error, term}.
  It runs in a monitored process killed on timeout. No retries. Remote error
  bodies and exceptions are never returned or logged. Failed optional judgments
  should fall back to the caller's rules.
  """
  @endpoint "https://api.typesafe.ai/v1/systemone"
  def noul(instructions), do: %{"type" => "noul", "instructions" => instructions}

  def choice(instructions, criteria),
    do: %{"type" => "choice", "instructions" => instructions, "criteria" => criteria}

  def score(instructions, levels),
    do: %{"type" => "score", "instructions" => instructions, "criteria" => levels}

  def evaluate(state, questions, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    key = Keyword.get_lazy(opts, :api_key, fn -> Nano.Settings.get("TYPESAFE_API_KEY") end)
    model = Keyword.get(opts, :model, "jev-latest")
    transport = Keyword.get(opts, :transport, &http/1)

    cond do
      not (is_integer(timeout) and timeout in 1..30_000) ->
        {:error, :invalid_timeout}

      not (is_binary(key) and key != "") ->
        {:error, :missing_api_key}

      not (is_binary(model) and model != "" and is_function(transport, 1)) ->
        {:error, :invalid_request}

      not valid_questions?(questions) ->
        {:error, :invalid_questions}

      true ->
        body = %{"state" => state, "questions" => questions, "model" => model}

        case Jason.encode(body) do
          {:ok, _} ->
            bounded(
              transport,
              %{
                url: @endpoint,
                headers: [{"authorization", "Bearer " <> key}],
                body: body,
                timeout: timeout
              },
              questions
            )

          _ ->
            {:error, :invalid_request}
        end
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  defp valid_questions?(q) when is_map(q) and map_size(q) > 0,
    do:
      Enum.all?(q, fn {id, question} ->
        is_binary(id) and id != "" and valid_question?(question)
      end)

  defp valid_questions?(_), do: false

  defp valid_question?(%{"type" => type, "instructions" => i} = q) do
    (is_binary(i) or is_map(i) or is_list(i)) and
      case {type, q["criteria"]} do
        {"noul", nil} ->
          true

        {"noul", c} ->
          is_map(c)

        {"choice", c} when is_map(c) ->
          map_size(c) in 1..255 and Enum.all?(Map.keys(c), &is_binary/1)

        {"score", c} when is_list(c) ->
          length(c) in 2..10

        _ ->
          false
      end
  end

  defp valid_question?(_), do: false

  defp bounded(transport, request, questions) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            decode(transport.(request), questions)
          rescue
            _ -> {:error, :transport_error}
          catch
            _, _ -> {:error, :transport_error}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :transport_error}
    after
      request.timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp http(r),
    do:
      Req.post(r.url,
        headers: r.headers,
        json: r.body,
        retry: false,
        receive_timeout: r.timeout,
        connect_options: [timeout: r.timeout]
      )

  defp decode({:ok, %{status: 200, body: body}}, questions) when is_map(body) do
    answers = body["answers"]

    if is_binary(body["model"]) and is_map(answers) and
         Enum.sort(Map.keys(answers)) == Enum.sort(Map.keys(questions)) do
      parsed = Enum.map(questions, fn {id, q} -> {id, answer(answers[id], q)} end)

      if Enum.all?(parsed, fn {_, a} -> is_map(a) end),
        do: {:ok, %{model: body["model"], answers: Map.new(parsed), usage: body["usage"] || %{}}},
        else: {:error, :invalid_response}
    else
      {:error, :invalid_response}
    end
  end

  defp decode({:ok, %{status: s}}, _) when is_integer(s) and s != 200,
    do: {:error, {:http_status, s}}

  defp decode({:error, _}, _), do: {:error, :transport_error}
  defp decode(_, _), do: {:error, :invalid_response}

  defp answer(%{"type" => "noul", "noul" => n}, %{"type" => "noul"}) do
    if probability?(n), do: %{type: :noul, noul: n}
  end

  defp answer(%{"type" => "choice"} = a, %{"type" => "choice", "criteria" => c}) do
    if distribution?(a["probabilities"], Map.keys(c)) and probability?(a["confidence"]) and
         is_binary(a["choice"]) and Map.has_key?(c, a["choice"]),
       do: %{
         type: :choice,
         choice: a["choice"],
         probabilities: a["probabilities"],
         confidence: a["confidence"]
       }
  end

  defp answer(%{"type" => "score"} = a, %{"type" => "score", "criteria" => c}) do
    keys = Enum.map(0..(length(c) - 1), &Integer.to_string/1)

    if distribution?(a["probabilities"], keys) and probability?(a["confidence"]) and
         is_number(a["score"]) and a["score"] >= 0 and a["score"] <= length(c) - 1 and
         is_map(a["legend"]) and Enum.sort(Map.keys(a["legend"])) == Enum.sort(keys),
       do: %{
         type: :score,
         score: a["score"],
         probabilities: a["probabilities"],
         confidence: a["confidence"],
         legend: a["legend"]
       }
  end

  defp answer(_, _), do: nil
  defp probability?(n), do: is_number(n) and n >= 0 and n <= 1

  defp distribution?(p, keys) when is_map(p),
    do:
      Enum.sort(Map.keys(p)) == Enum.sort(keys) and Enum.all?(Map.values(p), &probability?/1) and
        abs(Enum.sum(Map.values(p)) - 1) < 0.001

  defp distribution?(_, _), do: false
end
