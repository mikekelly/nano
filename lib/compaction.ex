defmodule Compaction do
  @moduledoc "Automatic checkpoints for every NanoAgent; voluntary provide_summary(text) takes effect after the eval result."
  def provide_summary(text) when is_binary(text) do
    with :ok <- validate(text), [parent | _] <- Process.get(:"$callers", []) do
      GenServer.cast(parent, {:compact_summary, text})
      :ok
    else
      [] -> {:error, "provide_summary must be called from an agent eval"}
      error -> error
    end
  end

  def validate(text) when is_binary(text) do
    if String.trim(text) != "" and byte_size(text) <= 48000,
      do: :ok,
      else: {:error, "summary must be nonempty and at most 48000 bytes"}
  end

  def validate(_), do: {:error, "summary must be a string"}

  def parse(code) when is_binary(code) and byte_size(code) <= 200_000 do
    with {:ok, {{:., _, [{:__aliases__, _, [:Compaction]}, :provide_summary]}, _, [text]}} <-
           Code.string_to_quoted(code),
         {:ok, text} <- literal(text),
         :ok <- validate(text) do
      {:ok, text}
    else
      _ ->
        {:error,
         "Use exactly Compaction.provide_summary with one literal string of 1..48000 bytes"}
    end
  end

  def parse(_), do: {:error, "summary code must be a bounded string"}

  defp literal(text) when is_binary(text), do: {:ok, text}
  defp literal({:sigil_S, _, [{:<<>>, _, [text]}, []]}) when is_binary(text), do: {:ok, text}
  defp literal(_), do: {:error, :not_literal}

  def run(model, reasoning, messages, attempt \\ 1, reason \\ "") do
    case run_with_usage(model, reasoning, messages, attempt: attempt, reason: reason) do
      {:ok, text, _} -> {:ok, text}
      {:error, error, _} -> {:error, error}
    end
  end

  @doc "Returns {:ok, text, metrics} or {:error, reason, metrics}. Metrics include usage/cost of every response, even refused summaries. timeout defaults to 300000 milliseconds. chat is an optional five-argument test function."
  def run_with_usage(model, reasoning, messages, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)
    timeout = Keyword.get(opts, :timeout, 300_000)

    if attempt in 1..3 and is_integer(timeout) and timeout > 0 do
      retry(model, reasoning, messages, attempt, Keyword.get(opts, :reason, ""), opts, [])
    else
      {:error, "attempt must be 1..3 and timeout positive", %{responses: [], attempts: 0}}
    end
  end

  defp retry(model, reasoning, messages, attempt, reason, opts, responses) do
    note =
      "Automatic compaction: respond with exactly one eval call whose code is Compaction.provide_summary(~S\"\"\"...\"\"\"). Do not execute other code. Summarize in 2000-8000 tokens, at most 48000 bytes, with Goal; Constraints & Preferences; Progress (Done, In Progress, Blocked); Key Decisions and reasons; Next Steps; Critical Context (exact paths, functions, errors). Update any earlier checkpoint. " <>
        reason

    tools = [
      %{
        type: "function",
        function: %{
          name: "eval",
          description: "Provide checkpoint",
          parameters: %{
            type: "object",
            properties: %{code: %{type: "string"}},
            required: ["code"]
          }
        }
      }
    ]

    chat = Keyword.get(opts, :chat, &Nano.Model.chat/5)

    result =
      bounded_call(
        fn ->
          chat.(
            model,
            messages ++ [%{"role" => "user", "content" => note}],
            tools,
            reasoning,
            12000
          )
        end,
        Keyword.get(opts, :timeout, 300_000)
      )

    responses =
      case result do
        {:ok, response} when is_map(response) ->
          responses ++
            [
              Map.take(response, [
                :usage,
                :cost,
                :provider,
                :finish_reason,
                :message,
                :raw,
                :latency_ms
              ])
            ]

        _ ->
          responses
      end

    metrics = %{responses: responses, attempts: attempt}

    case parse_response(result) do
      {:ok, text} ->
        {:ok, text, metrics}

      {:error, error} when attempt < 3 ->
        correction =
          if match?({:ok, _}, result), do: "Previous attempt refused: #{error}", else: reason

        if attempt < Keyword.get(opts, :max_attempts, 3) and within_token_budget?(responses, opts),
          do: retry(model, reasoning, messages, attempt + 1, correction, opts, responses),
          else: {:error, error, metrics}

      {:error, error} ->
        {:error, error, metrics}
    end
  end

  defp within_token_budget?(responses, opts) do
    case Keyword.get(opts, :token_budget) do
      nil ->
        true

      limit ->
        Enum.reduce(responses, 0, fn r, sum ->
          u = r[:usage] || %{}
          sum + (u["prompt_tokens"] || 0) + (u["completion_tokens"] || 0)
        end) < limit
    end
  end

  defp parse_response(
         {:ok,
          %{
            message: %{
              "tool_calls" => [%{"function" => %{"name" => "eval", "arguments" => arguments}}]
            }
          }}
       )
       when is_binary(arguments) do
    with {:ok, %{"code" => code}} when is_binary(code) <- Jason.decode(arguments) do
      parse(code)
    else
      _ -> {:error, "eval arguments must contain string code"}
    end
  end

  defp parse_response({:ok, _}),
    do: {:error, "Use exactly one eval tool call with a literal summary"}

  defp parse_response(error), do: {:error, inspect(error, limit: 10, printable_limit: 1000)}

  defp bounded_call(fun, timeout) do
    owner = self()
    tag = make_ref()
    {pid, ref} = spawn_monitor(fn -> send(owner, {tag, fun.()}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:provider_exit, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        end

        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp retained_events(transcript) do
    Enum.flat_map(transcript, fn
      %{"role" => "user", "content" => content} when is_binary(content) ->
        Enum.map(event_texts(content), &%{"role" => "user", "content" => &1})

      %{"role" => "user", "content" => parts} when is_list(parts) ->
        {events, current} =
          Enum.reduce(parts, {[], nil}, fn
            %{"type" => "text", "text" => text}, {events, current} when is_binary(text) ->
              case event_texts(text) do
                [] ->
                  {events, current}

                texts ->
                  events = flush_event(events, current)
                  {head, [last]} = Enum.split(texts, -1)

                  events =
                    events ++ Enum.map(head, fn text -> [%{"type" => "text", "text" => text}] end)

                  {events, [%{"type" => "text", "text" => last}]}
              end

            %{"type" => "seed_image"} = image, {events, current} when is_list(current) ->
              {events, current ++ [image]}

            _, state ->
              state
          end)

        Enum.map(flush_event(events, current), &%{"role" => "user", "content" => &1})

      _ ->
        []
    end)
  end

  defp event_texts(text), do: Regex.scan(~r/<event\b[^>]*>.*?<\/event>/s, text) |> Enum.map(&hd/1)
  defp flush_event(events, nil), do: events
  defp flush_event(events, current), do: events ++ [current]

  defp event_bytes(%{"content" => content}) when is_binary(content), do: byte_size(content)

  defp event_bytes(%{"content" => parts}) do
    byte_size(Jason.encode!(parts)) +
      Enum.reduce(parts, 0, fn
        %{"type" => "seed_image"}, n -> n + 9600
        _, n -> n
      end)
  end

  defp event_budget(s, first) do
    window = if s.max_context > 0, do: s.max_context, else: Map.get(s, :context_window) || 272_000
    # Match the harness's conservative two-bytes-per-token estimator, including images.
    max(div(window * 2, 5) - Enum.reduce(first, 0, &(event_bytes(&1) + &2)), 0)
  end

  def apply_summary(s, text) do
    events = retained_events(s.transcript)
    first = Enum.take(events, 1)

    rest =
      events
      |> Enum.drop(1)
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn event, {acc, size} ->
        cost = event_bytes(event)

        if size + cost <= event_budget(s, first),
          do: {[event | acc], size + cost},
          else: {acc, size}
      end)
      |> elem(0)

    transcript =
      (first ++ rest) ++
        [
          %{
            "role" => "user",
            "content" =>
              "Your conversation before this point was compacted automatically by the harness using your model. Messages above are received events kept in their own words; this is your summary of everything else. Full record: /data/logs/#{s.id}.jsonl\n\n" <>
                text
          }
        ]

    s
    |> Map.put(:transcript, transcript)
    |> Map.put(:context_used, 0)
    |> Map.put(:measured_bytes, 0)
    |> Map.put(:compaction_pending, nil)
    |> Map.put(:compaction_just_applied, true)
    |> Map.put(:compaction_generation, Map.get(s, :compaction_generation, 0) + 1)
  end
end
