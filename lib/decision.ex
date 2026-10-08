defmodule Decision do
  @moduledoc """
  Bounded, typed client for TypeSafe's Jev decision model, for small recurring judgments.
  See https://docs.typesafe.ai/api.md (verified 2026-10-08).

      questions = [Decision.noul("drift", "Does recent work depart from the goal?")]
      {:ok, answers} = Decision.ask(%{goal: "Ship tests", recent: "Writing tests"}, questions)
      answers["drift"].value # probability of yes, not a boolean

  `choice/3` selects from a string-keyed map of descriptions (nil allowed), and
  `score/3` rates an ordered list of 2–10 descriptions on the scale 0..(n-1).
  Instructions/descriptions can be strings, JSON objects or arrays. Constructors
  are inert; `ask/3` validates before making any network request. IDs must be unique
  nonempty strings. State must be a JSON string, object or array.

  Results are a map keyed by question ID, containing `Decision.Answer` structs.
  Noul's `value` is a probability; Choice's is an option string; Score's is a
  probability-weighted level index. Choice/Score retain `probabilities` and
  `confidence`; Score also retains `legend`. No strings are converted to atoms.
  Probability distributions must contain exactly the requested keys, values in
  0..1 and sum to 1 within 0.02 (rounding tolerance). Scores must agree with their
  distribution within 0.02 per level; choice must be a highest-probability option.
  Confidence is not a guarantee of correctness. Callers own thresholds/fallbacks.

  Options:
    * `:api_key` — defaults to `Nano.Settings.get("TYPESAFE_API_KEY")`. Never logged.
    * `:model` — defaults to `"jev-latest"`; supply a version for reproducibility.
    * `:timeout` — whole transport deadline in ms, default 15_000, range 1..60_000.
    * `:connect_timeout` — default 5_000, capped by the whole deadline.
    * `:transport` — function receiving `%{url: ..., headers: ..., json: ...,
      timeout: ..., connect_timeout: ...}`, returning `{:ok, %{status: integer,
      body: decoded_json_or_string}}` or `{:error, reason}`. Runs in an isolated
      process killed at the deadline or when its caller dies. This function receives the credential and
      must not log it. Tests should use an explicit dummy `:api_key`.

  No retries or redirects: errors are visible and predictable for latency-sensitive
  routing. Errors include `:missing_api_key`, `{:invalid_input, field}`,
  `{:invalid_question, id}`, `{:http_status, code}`, `{:transport, code}`,
  `:timeout`, and `{:invalid_response, code}`. Arbitrary transport reasons and
  server error bodies are deliberately not returned, to avoid leaking credentials
  or state. Requests are capped at 256 KiB, accepted responses at 1 MiB (checked
  after download), batches at 128.
  The caller should not send secrets in state. This client does not persist judgments
  or return service usage metadata; consumers choose their own logging policy.
  """

  defmodule Question do
    @moduledoc "Typed question built by `Decision.noul/2`, `choice/3`, or `score/3`."
    @enforce_keys [:id, :type, :instructions]
    defstruct [:id, :type, :instructions, :criteria]

    @type t :: %__MODULE__{
            id: String.t(),
            type: :noul | :choice | :score,
            instructions: term(),
            criteria: term()
          }
  end

  defmodule Answer do
    @moduledoc "Validated answer. `value` is a probability, option, or weighted level index."
    @enforce_keys [:type, :value]
    defstruct [:type, :value, :probabilities, :confidence, :legend]

    @type t :: %__MODULE__{
            type: :noul | :choice | :score,
            value: number() | String.t(),
            probabilities: map() | nil,
            confidence: number() | nil,
            legend: map() | nil
          }
  end

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @max_request 262_144
  @max_response 1_048_576
  @options [:api_key, :model, :timeout, :connect_timeout, :transport]

  @doc "Build a yes/no question. Its answer's value is the probability of yes."
  @spec noul(String.t(), term()) :: Question.t()
  def noul(id, instructions), do: %Question{id: id, type: :noul, instructions: instructions}

  @doc "Build a choice question with 1–255 string-keyed option descriptions."
  @spec choice(String.t(), term(), map()) :: Question.t()
  def choice(id, instructions, options),
    do: %Question{id: id, type: :choice, instructions: instructions, criteria: options}

  @doc "Build a score question with 2–10 ordered descriptions, starting at level zero."
  @spec score(String.t(), term(), list()) :: Question.t()
  def score(id, instructions, levels),
    do: %Question{id: id, type: :score, instructions: instructions, criteria: levels}

  @doc "Evaluate a batch atomically: any malformed answer fails the whole batch."
  @spec ask(term(), [Question.t()], keyword()) ::
          {:ok, %{String.t() => Answer.t()}} | {:error, term()}
  def ask(state, questions, opts \\ []) do
    with {:ok, config} <- config(opts),
         {:ok, wire_questions} <- questions(questions),
         true <- description?(state) or {:error, {:invalid_input, :state}},
         {:ok, json} <- encode_request(state, wire_questions, config.model),
         {:ok, key} <- api_key(opts),
         request = %{
           url: @endpoint,
           headers: [{"authorization", "Bearer " <> key}],
           json: json,
           timeout: config.timeout,
           connect_timeout: config.connect_timeout
         },
         {:ok, response} <- bounded_transport(config.transport, request),
         {:ok, body} <- response_body(response),
         {:ok, answers} <- answers(body, questions) do
      {:ok, answers}
    end
  end

  defp config(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in @options)) do
      timeout = Keyword.get(opts, :timeout, 15_000)
      connect = Keyword.get(opts, :connect_timeout, 5_000)
      model = Keyword.get(opts, :model, "jev-latest")
      transport = Keyword.get(opts, :transport, &http/1)

      cond do
        not (is_integer(timeout) and timeout in 1..60_000) ->
          invalid(:timeout)

        not (is_integer(connect) and connect in 1..60_000) ->
          invalid(:connect_timeout)

        not nonempty?(model) ->
          invalid(:model)

        not is_function(transport, 1) ->
          invalid(:transport)

        true ->
          {:ok,
           %{
             timeout: timeout,
             connect_timeout: min(connect, timeout),
             model: model,
             transport: transport
           }}
      end
    else
      invalid(:options)
    end
  end

  defp api_key(opts) do
    key = Keyword.get_lazy(opts, :api_key, fn -> Nano.Settings.get("TYPESAFE_API_KEY") end)
    if nonempty?(key), do: {:ok, key}, else: {:error, :missing_api_key}
  end

  defp questions(qs) when is_list(qs) and length(qs) in 1..128 do
    Enum.reduce_while(qs, {:ok, %{}}, fn
      %Question{} = q, {:ok, acc} ->
        if valid_question?(q) and not Map.has_key?(acc, q.id) do
          wire = %{"type" => Atom.to_string(q.type), "instructions" => q.instructions}
          wire = if q.type == :noul, do: wire, else: Map.put(wire, "criteria", q.criteria)
          {:cont, {:ok, Map.put(acc, q.id, wire)}}
        else
          {:halt, {:error, {:invalid_question, safe_id(q.id)}}}
        end

      _, _ ->
        {:halt, invalid(:questions)}
    end)
  end

  defp questions(_), do: invalid(:questions)

  defp valid_question?(q) do
    nonempty?(q.id) and byte_size(q.id) <= 256 and description?(q.instructions) and
      case q.type do
        :noul ->
          q.criteria == nil

        :choice ->
          is_map(q.criteria) and not is_struct(q.criteria) and
            map_size(q.criteria) in 1..255 and
            Enum.all?(q.criteria, fn {k, v} ->
              nonempty?(k) and (v == nil or description?(v))
            end)

        :score ->
          is_list(q.criteria) and length(q.criteria) in 2..10 and
            Enum.all?(q.criteria, &description?/1)

        _ ->
          false
      end
  end

  defp encode_request(state, qs, model) do
    json = %{"state" => state, "questions" => qs, "model" => model}

    case Jason.encode(json, maps: :strict) do
      {:ok, encoded} when byte_size(encoded) <= @max_request -> {:ok, Jason.decode!(encoded)}
      {:ok, _} -> invalid(:request_too_large)
      _ -> invalid(:json)
    end
  rescue
    _ -> invalid(:json)
  end

  defp description?(value) do
    (is_binary(value) and String.valid?(value) and String.trim(value) != "") or
      (is_map(value) and not is_struct(value)) or is_list(value)
  end

  defp nonempty?(s), do: is_binary(s) and String.valid?(s) and String.trim(s) != ""
  defp safe_id(id), do: if(is_binary(id) and byte_size(id) <= 256, do: id, else: :invalid_id)
  defp invalid(field), do: {:error, {:invalid_input, field}}

  defp bounded_transport(transport, request) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        watch_owner(parent, self())

        result =
          try do
            transport.(request)
          rescue
            _ -> {:error, :exception}
          catch
            _, _ -> {:error, :exception}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        transport_result(result)

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, {:transport, :crashed}}
    after
      request.timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        receive do
          {^ref, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  # The caller may itself be a routing worker with a shorter outer deadline.
  # Start this from the transport worker so even a caller killed during spawn
  # cannot strand a transport that is blocked inside third-party code.
  defp watch_owner(owner, worker) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
      end
    end)
  end

  defp transport_result({:ok, %{status: status, body: _} = r}) when is_integer(status),
    do: {:ok, r}

  defp transport_result({:error, %Req.TransportError{reason: reason}}),
    do: transport_result({:error, reason})

  defp transport_result({:error, reason})
       when reason in [:timeout, :econnrefused, :closed, :nxdomain, :exception],
       do: {:error, {:transport, reason}}

  defp transport_result({:error, _}), do: {:error, {:transport, :failed}}
  defp transport_result(_), do: {:error, {:transport, :invalid_result}}

  defp http(request) do
    Req.post(request.url,
      headers: request.headers,
      json: request.json,
      retry: false,
      redirect: false,
      receive_timeout: request.timeout,
      pool_timeout: request.connect_timeout,
      connect_options: [timeout: request.connect_timeout],
      decode_body: false
    )
  end

  defp response_body(%{status: 200, body: body}) when is_binary(body) do
    cond do
      byte_size(body) > @max_response ->
        bad(:response_too_large)

      true ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          _ -> bad(:json)
        end
    end
  end

  defp response_body(%{status: 200, body: body}) when is_map(body) do
    case Jason.encode(body) do
      {:ok, bytes} when byte_size(bytes) <= @max_response -> {:ok, body}
      {:ok, _} -> bad(:response_too_large)
      _ -> bad(:json)
    end
  rescue
    _ -> bad(:json)
  end

  defp response_body(%{status: 200}), do: bad(:json)
  defp response_body(%{status: status}), do: {:error, {:http_status, status}}

  defp answers(%{"answers" => answers}, qs) when is_map(answers) do
    if MapSet.new(Map.keys(answers)) == MapSet.new(qs, & &1.id) do
      Enum.reduce_while(qs, {:ok, %{}}, fn q, {:ok, acc} ->
        case answer(answers[q.id], q) do
          {:ok, answer} -> {:cont, {:ok, Map.put(acc, q.id, answer)}}
          {:error, {:invalid_response, reason}} -> {:halt, bad({q.id, reason})}
        end
      end)
    else
      bad(:answer_ids)
    end
  end

  defp answers(_, _), do: bad(:answers)

  defp answer(%{"type" => "noul", "noul" => value}, %Question{type: :noul}) do
    if probability?(value), do: {:ok, %Answer{type: :noul, value: value}}, else: bad(:noul)
  end

  defp answer(
         %{
           "type" => "choice",
           "choice" => value,
           "probabilities" => ps,
           "confidence" => confidence
         },
         %Question{type: :choice, criteria: criteria}
       ) do
    with :ok <- distribution(ps, Map.keys(criteria)),
         true <- probability?(confidence) or bad(:confidence),
         true <- Map.has_key?(criteria, value) or bad(:choice),
         true <- ps[value] == Enum.max(Map.values(ps)) or bad(:choice_probability) do
      {:ok, %Answer{type: :choice, value: value, probabilities: ps, confidence: confidence}}
    end
  end

  defp answer(
         %{
           "type" => "score",
           "score" => value,
           "probabilities" => ps,
           "confidence" => confidence,
           "legend" => legend
         },
         %Question{type: :score, criteria: levels}
       ) do
    top = length(levels) - 1
    keys = Enum.map(0..top, &Integer.to_string/1)

    with :ok <- distribution(ps, keys),
         true <- probability?(confidence) or bad(:confidence),
         true <- (is_number(value) and value >= 0 and value <= top) or bad(:score),
         true <-
           (is_map(legend) and Enum.sort(Map.keys(legend)) == Enum.sort(keys) and
              Enum.all?(Map.values(legend), &description?/1)) or bad(:legend),
         expected = Enum.sum(Enum.map(0..top, &(&1 * ps[Integer.to_string(&1)]))),
         true <- abs(expected - value) <= 0.02 * top or bad(:score_probability) do
      {:ok,
       %Answer{
         type: :score,
         value: value,
         probabilities: ps,
         confidence: confidence,
         legend: legend
       }}
    end
  end

  defp answer(_, _), do: bad(:answer_shape)

  defp distribution(ps, keys) when is_map(ps) do
    cond do
      Enum.sort(Map.keys(ps)) != Enum.sort(keys) -> bad(:probability_keys)
      not Enum.all?(Map.values(ps), &probability?/1) -> bad(:probabilities)
      abs(Enum.sum(Map.values(ps)) - 1) > 0.02 -> bad(:probability_sum)
      true -> :ok
    end
  end

  defp distribution(_, _), do: bad(:probabilities)
  defp probability?(n), do: is_number(n) and n >= 0 and n <= 1
  defp bad(reason), do: {:error, {:invalid_response, reason}}
end
