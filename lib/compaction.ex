defmodule Compaction do
  @moduledoc """
  Automatic context checkpoints before NanoAgent's context guard. Same pid, bindings and
  mailbox; full history remains in logs. `provide_summary/1` voluntarily checkpoints at
  the next safe tool boundary. Automatic replies are parsed as data, never executed.

  At most three model attempts, with an unchanged request on transport failure and only
  the tip changed on refusal. All returned usage (including refused replies) is charged.
  A summary is bounded to 24,000 UTF-8 bytes, conservatively estimated at 12,000 tokens;
  this is not a provider tokenizer guarantee. Small windows use a smaller summary budget.
  Events delivered since this version was loaded are preserved from exact message records;
  legacy transcripts use wrapper extraction (including multimodal text blocks). Child reports
  are summarized, not retained. Pixel attachments are dropped: received immutable IDs/refs
  survive as text, with an explicit re-view reminder. Tool-viewed images are summary material.
  The first brief is never dropped; an oversized brief/checkpoint can still halt safely.
  """
  def provide_summary(text) do
    with :ok <- validate(text), [agent | _] <- Process.get(:"$callers", []) do
      GenServer.cast(agent, {:compaction_summary, text})
      :ok
    else
      [] -> {:error, :not_in_agent_eval}
      error -> error
    end
  end

  def validate(text) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "" and byte_size(text) <= 24_000,
      do: :ok,
      else: {:error, "summary must be nonempty UTF-8 and at most 24000 bytes"}
  end

  def validate(_), do: {:error, "summary must be a literal string"}

  def due?(s, estimate),
    do: s.max_context >= 16_384 and estimate >= s.max_context - min(16_384, div(s.max_context, 3))

  def parse(code) when is_binary(code) and byte_size(code) <= 100_000 do
    with {:ok, {{:., _, [{:__aliases__, _, [:Compaction]}, :provide_summary]}, _, [arg]}} <-
           Code.string_to_quoted(code),
         {:ok, text} <- literal(arg),
         :ok <- validate(text) do
      {:ok, text}
    else
      _ ->
        {:error,
         "expected exactly Compaction.provide_summary with one nonempty literal string (at most 24000 bytes)"}
    end
  end

  def parse(_), do: {:error, "eval code must be a string of at most 100000 bytes"}
  defp literal(text) when is_binary(text), do: {:ok, text}
  defp literal({:sigil_S, _, [{:<<>>, _, [text]}, []]}) when is_binary(text), do: {:ok, text}
  defp literal(_), do: {:error, :not_literal}

  @doc false
  def generate(s, call \\ &NanoAgent.compaction_call/4) do
    generate(s, call, 1, nil, %{attempts: 0, responses: [], tokens: 0, cost: 0})
  end

  defp generate(s, call, attempt, refusal, stats) do
    output = Map.get(s, :compaction_output, 12_000)
    max_bytes = min(24_000, max(256, (output - 512) * 2))

    note = """
    <harness>Automatic compaction is starting. Return exactly one eval call with code
    Compaction.provide_summary using a multiline raw sigil_S string, no other code.
    Maximum #{max_bytes} UTF-8 bytes, preferably much shorter. Sections: Goal; Constraints & Preferences;
    Progress (Done, In Progress, Blocked); Key Decisions with reasons; Next Steps;
    Critical Context (exact paths and APIs). Update any earlier checkpoint. Mark guesses.
    Your own turns will be replaced by this summary; received events retained within a budget.
    System prompt, pid, bindings and full durable log remain unchanged.
    #{if refusal, do: "Previous reply refused: #{refusal}", else: ""}</harness>
    """

    messages =
      [%{"role" => "system", "content" => s.system_prompt} | s.transcript] ++
        [%{"role" => "user", "content" => note}]

    stats = %{stats | attempts: attempt}

    case call.(s, messages, output, attempt) do
      {:ok, response} ->
        usage = response[:usage] || %{}

        stats = %{
          stats
          | responses: stats.responses ++ [response],
            tokens:
              stats.tokens + (usage["prompt_tokens"] || 0) + (usage["completion_tokens"] || 0),
            cost: stats.cost + (response[:cost] || 0)
        }

        case parse_response(response, max_bytes) do
          {:ok, text} -> {:ok, text, stats}
          {:error, reason} -> retry(s, call, attempt, reason, stats)
        end

      {:error, error} ->
        if is_map(error) and error[:class] == :transient do
          retry(s, call, attempt, refusal, stats)
        else
          {:error, "model call failed: #{inspect(error, limit: 5, printable_limit: 500)}", stats}
        end
    end
  end

  defp retry(s, call, attempt, refusal, stats) do
    turns_left = s.max_turns == 0 or s.turns_used + attempt < s.max_turns
    tokens_left = s.max_tokens == 0 or s.tokens_used + stats.tokens < s.max_tokens

    if attempt < 3 and turns_left and tokens_left,
      do: generate(s, call, attempt + 1, refusal, stats),
      else: {:error, refusal || "compaction attempts or budget exhausted", stats}
  end

  defp parse_response(%{message: %{"tool_calls" => [call]} = message}, max_bytes)
       when is_map(call) do
    with true <- message["content"] in [nil, ""],
         %{"name" => "eval", "arguments" => args} <- call["function"],
         {:ok, %{"code" => code}} <-
           if(is_binary(args), do: Jason.decode(args), else: {:ok, args}),
         {:ok, text} <- parse(code),
         true <- byte_size(text) <= max_bytes do
      {:ok, text}
    else
      _ -> {:error, "return one eval with a literal summary, at most #{max_bytes} UTF-8 bytes"}
    end
  end

  defp parse_response(_, _), do: {:error, "return exactly one eval tool call"}

  @doc false
  def remember_delivery(s, pending) do
    delivered =
      Enum.filter(pending, &(String.starts_with?(&1, "<event") and not child_report?(&1)))

    events =
      events(s) ++ delivered ++ attachment_metadata(delivered, Map.get(s, :pending_images, []))

    Map.put(s, :compaction_events, select_events(events, s.max_context))
  end

  defp child_report?(event), do: Regex.match?(~r/>\{:delegation, .*?, :result,/s, event)

  defp events(s) do
    Map.get_lazy(s, :compaction_events, fn ->
      Enum.flat_map(s.transcript, fn
        %{"role" => "user", "content" => content} ->
          text = text_content(content)

          events =
            for [event] <-
                  Regex.scan(~r/^<event\b[^>]*>.*?<\/event>(?=\n(?:<event|<harness)|\z)/ms, text),
                not child_report?(event),
                do: event

          refs =
            if is_list(content),
              do: Enum.filter(content, &match?(%{"type" => "image_ref"}, &1)),
              else: []

          events ++ attachment_metadata(events, refs)

        _ ->
          []
      end)
    end)
  end

  defp text_content(text) when is_binary(text), do: text

  defp text_content(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> String.trim_trailing("\n")
  end

  defp text_content(_), do: ""

  # Normally an inspected event already contains its immutable reference metadata.
  # Legacy/transformed multimodal messages may have references only in content blocks.
  defp attachment_metadata([], _), do: []

  defp attachment_metadata(events, refs) do
    text = Enum.join(events, "\n")

    refs =
      Enum.filter(refs, fn ref ->
        is_map(ref) and is_binary(ref["id"]) and not String.contains?(text, ref["id"])
      end)

    if refs == [],
      do: [],
      else: [
        "<harness>Received attachment references (pixels omitted): #{Jason.encode!(refs)}</harness>"
      ]
  end

  defp select_events(events, window) do
    budget = div(window * 2, 5)

    case events do
      [] ->
        []

      [first | rest] ->
        {latest, _} =
          Enum.reduce(Enum.reverse(rest), {[], byte_size(first)}, fn event, {acc, size} ->
            if size + byte_size(event) <= budget,
              do: {[event | acc], size + byte_size(event)},
              else: {acc, size}
          end)

        [first | latest]
    end
  end

  def rebuild(s, summary) do
    kept = select_events(events(s), s.max_context)

    transcript =
      Enum.map(kept, &%{"role" => "user", "content" => &1}) ++
        [
          %{
            "role" => "user",
            "content" =>
              "<harness>Your conversation before this point was compacted by the harness using your own summary. The messages above are received events kept in their own words, plus retained attachment metadata if any. Full record: #{s.id} in the node log directory. Some events may have been omitted to fit. Prior pixel attachments are not retained; use Images.resolve(id) as an eval result to re-view an immutable attachment when needed.\n\n#{summary}</harness>"
          }
        ]

    s
    |> Map.merge(%{
      transcript: transcript,
      context_used: 0,
      measured_bytes: 0,
      compaction_events: kept
    })
    |> Map.delete(:compaction_output)
  end
end
