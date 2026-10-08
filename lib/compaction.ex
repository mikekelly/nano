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
          responses ++ [Map.take(response, [:usage, :cost, :provider, :finish_reason])]

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

        retry(model, reasoning, messages, attempt + 1, correction, opts, responses)

      {:error, error} ->
        {:error, error, metrics}
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

  defp event_budget(s, first) do
    window = if s.max_context > 0, do: s.max_context, else: Map.get(s, :context_window) || 272_000
    max(div(window * 4, 5) - Enum.reduce(first, 0, &(byte_size(&1) + &2)), 0)
  end

  def apply_summary(s, text) do
    events =
      for %{"role" => "user", "content" => content} <- s.transcript,
          event <- Regex.scan(~r/<event\b[^>]*>.*?<\/event>/s, content),
          do: hd(event)

    first = Enum.take(events, 1)

    rest =
      events
      |> Enum.drop(1)
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn e, {acc, size} ->
        if size + byte_size(e) < event_budget(s, first),
          do: {[e | acc], size + byte_size(e)},
          else: {acc, size}
      end)
      |> elem(0)

    transcript =
      Enum.map(first ++ rest, &%{"role" => "user", "content" => &1}) ++
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
  end
end
