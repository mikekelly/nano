defmodule Seedling.Compaction do
  @moduledoc """
  Checkpoints for NanoAgent, both automatic (before a model request) and voluntary.

  From an agent's eval call `Seedling.Compaction.provide_summary(text)`. Use the headings
  Goal; Constraints & Preferences; Progress (Done, In Progress, Blocked); Key Decisions
  (with reasons); Next Steps; Critical Context (exact paths, APIs and errors). Aim for
  2,000–8,000 tokens. Empty summaries and summaries over a conservative 12,000-token
  bound are rejected. Bindings, processes, mailbox and disk files are not changed.

  Automatic compaction asks the same model at the cached tip and intercepts exactly one
  eval call containing this API with a literal string. No returned code is executed.
  Invalid responses are logged but never appended; the identical request is retried
  three times. Transport failures retain the normal provider backoff/retry behaviour.

  A voluntary checkpoint is applied only after every tool result in the response has
  been recorded. Only the submitting agent's active eval can submit it. The next model
  call sees external events in their original order, followed by the summary. The first
  external event always survives; newest others fill about one fifth of the window.
  Child reports are summarized, not carried as requests. The first event is never cut,
  even if it exceeds that allowance: the harness's hard context guard still applies.

  `migrate/1`, `extract/1`, `select_events/2`, and `rebuild/3` are pure helpers used by the
  harness and available to other conversation managers. See
  `seeding-docs/compaction-operations.md` for state migration and safe reload guidance.
  """
  @max_summary_tokens 12_000
  @reserve 16_384
  @attempts 3

  @doc "The number of invalid summary responses before halting."
  def attempts, do: @attempts

  @doc "Reserve for compaction; at least 8192 tokens to fit the note and hard reply guard."
  def reserve(window), do: min(@reserve, max(8_192, div(window, 4)))

  @doc "A conservative JSON token estimate (one token per two bytes, including framing)."
  def tokens(value), do: div(byte_size(Jason.encode!(value)) + 1, 2)

  @doc "Validates a checkpoint without executing code."
  def validate(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, "summary must not be empty"}
      tokens(text) > @max_summary_tokens -> {:error, "summary exceeds the 12000-token bound"}
      true -> {:ok, text}
    end
  end

  def validate(_), do: {:error, "summary must be a string"}

  @doc "Queues a voluntary checkpoint from the current agent eval; returns :ok or {:error, reason}."
  def provide_summary(text) do
    with {:ok, text} <- validate(text),
         [agent | _] when is_pid(agent) <- Process.get(:"$callers", []) do
      GenServer.call(agent, {:seedling_compaction_summary, text})
    else
      {:error, _} = error -> error
      _ -> {:error, "provide_summary must be called from an agent eval"}
    end
  end

  @doc "Extracts a literal checkpoint from exactly one eval tool call; never evaluates its AST."
  def extract(%{"tool_calls" => [%{"function" => %{"name" => "eval", "arguments" => raw}}]}) do
    with {:ok, %{"code" => code}} <- arguments(raw),
         true <- is_binary(code),
         {:ok, ast} <- Code.string_to_quoted(code),
         {{:., _, [{:__aliases__, _, [:Seedling, :Compaction]}, :provide_summary]}, _, [text]}
         when is_binary(text) <- ast do
      validate(text)
    else
      _ ->
        {:error,
         "expected exactly Seedling.Compaction.provide_summary(\"literal summary\") in one eval"}
    end
  end

  def extract(_), do: {:error, "expected exactly one eval tool call"}
  defp arguments(raw) when is_map(raw), do: {:ok, raw}
  defp arguments(raw) when is_binary(raw), do: Jason.decode(raw)
  defp arguments(_), do: :error

  @doc "The harness's automatic checkpoint instruction, appended at the conversation tip."
  def instruction do
    """
    The context limit is near: automatic compaction by the harness is starting. Do not ignore
    this. Return exactly one eval tool call, whose entire code is
    Seedling.Compaction.provide_summary("your summary") with a literal string, and no other
    code or tools. The harness extracts the string without running code. Everything above,
    except external messages you received, will be replaced by it. The next reader is you,
    with no memory of anything here except the summary and those messages. Reports from
    your sub-agents are results: carry their findings in the summary. If an earlier checkpoint
    is above, update it: retain relevant facts, move finished work to Done, add new decisions
    and drop what no longer matters.

    Write a fixed checkpoint with these headings:
    ## Goal
    ## Constraints & Preferences
    ## Progress
    ### Done
    ### In Progress
    ### Blocked
    ## Key Decisions (with brief reasons)
    ## Next Steps
    ## Critical Context (exact file paths, function names and error messages)

    Aim for 2000–8000 tokens, NEVER more than 12000 tokens (at most 24000 JSON-encoded bytes).
    Write terse but intelligible whole words. Preserve outstanding commitments, who is
    waiting for your report, goals on disk, and how to resume. You remain the same agent;
    your pid, mailbox, bindings, processes and files are unchanged. The full record stays
    in the harness log. Invalid summaries are discarded and the identical request retried
    up to three times, then the harness halts you for an operator to retry.
    """
  end

  @doc "Fills missing compaction state, including recovering legacy rendered events."
  def migrate(s) do
    s
    |> Map.put_new(
      :input_modalities_source,
      if(Map.has_key?(s, :input_modalities), do: :legacy_saved, else: :legacy_text_only)
    )
    |> Map.put_new(:input_modalities, ["text"])
    |> Map.put_new(:context_refresh, nil)
    |> Map.put_new(:compaction, nil)
    |> Map.put_new(:compaction_summary, nil)
    |> Map.put_new(:compaction_fresh, false)
    |> Map.put_new(:front_of_mind_compacted, false)
    |> Map.put_new_lazy(:compaction_events, fn ->
      for %{"role" => "user"} = message <- s.transcript,
          event <- recover_message_events(message),
          do: event
    end)
    |> Map.put_new_lazy(:compaction_pending_events, fn ->
      Enum.flat_map(s.pending, &recover_events/1)
    end)
  end

  # Before per-event metadata existed, all user attachments belong to the first event in
  # that delivery. This conservatively retains images rather than silently losing them.
  defp recover_message_events(message) do
    case recover_events(message["content"]) do
      [] -> []
      [first | rest] -> [Map.put(first, :images, Map.get(message, "images", [])) | rest]
    end
  end

  # Legacy state cannot identify child senders; retain those messages conservatively.

  defp recover_events(text) when is_binary(text) do
    # Actual headers start a line. Inspected strings escape newlines and quote their
    # contents; literal </event> inside a received term is NOT the wrapper terminator.
    text
    |> then(&Regex.split(~r/(?=^<event seq="\d+" at="[^"]*">)/m, &1, trim: true))
    |> Enum.flat_map(fn part ->
      if String.starts_with?(part, "<event seq=") do
        body = part |> String.split("\n<harness>", parts: 2) |> hd()

        case List.last(:binary.matches(body, "</event>")) do
          {offset, length} -> [%{text: binary_part(body, 0, offset + length), kind: :external}]
          nil -> []
        end
      else
        []
      end
    end)
  end

  defp recover_events(_), do: []

  defp event_tokens(event) do
    images = Map.get(event, :images, [])
    tokens(event.text) + tokens(images) + length(images) * Seedling.Images.limits().tokens
  end

  @doc "Selects the first external event and newest others within a fifth-window token allowance."
  def select_events(events, window) do
    case Enum.reject(events, &(&1.kind == :child_result)) do
      [] ->
        []

      [first | rest] ->
        allowance = max(div(window, 5) - event_tokens(first), 0)

        {selected, _} =
          Enum.reduce(Enum.reverse(rest), {[], allowance}, fn event, {acc, room} ->
            size = event_tokens(event)
            if size <= room, do: {[event | acc], room - size}, else: {acc, room}
          end)

        [first | selected]
    end
  end

  @doc "Returns {transcript, retained_events}; summary is last, external events unmarked and unchanged."
  def rebuild(events, summary, opts) do
    retained = select_events(events, Keyword.fetch!(opts, :window))
    log = Keyword.fetch!(opts, :log)
    source = Keyword.get(opts, :source, :automatic)

    preamble =
      "Your conversation before this point was compacted by the harness (#{source}). " <>
        "The messages above are ones you received, kept in their own words; this is your " <>
        "summary of everything else, written by your own model. The full record is at #{log}. " <>
        "Your pid, mailbox, variable bindings, processes and disk files are unchanged."

    messages =
      Enum.map(retained, fn event ->
        message = %{"role" => "user", "content" => event.text}

        case Map.get(event, :images, []) do
          [] -> message
          images -> Map.put(message, "images", images)
        end
      end)

    {messages ++ [%{"role" => "user", "content" => preamble <> "\n\n" <> summary}], retained}
  end
end
