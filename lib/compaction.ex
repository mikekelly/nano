defmodule Compaction do
  @moduledoc """
  Automatic context checkpoints before NanoAgent's context guard. Same pid, bindings and
  mailbox; full history remains in logs. `provide_summary/1` voluntarily checkpoints at
  the next safe tool boundary. Automatic replies are parsed as data, never executed.
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
    if String.trim(text) != "" and byte_size(text) <= 48_000,
      do: :ok,
      else: {:error, "summary must be nonempty and at most 48000 bytes"}
  end

  def validate(_), do: {:error, "summary must be a literal string"}

  def due?(s, estimate),
    do: s.max_context >= 16_384 and estimate >= s.max_context - min(16_384, div(s.max_context, 3))

  def parse(code) do
    with {:ok, {{:., _, [{:__aliases__, _, [:Compaction]}, :provide_summary]}, _, [arg]}} <-
           Code.string_to_quoted(code),
         {:ok, text} <- literal(arg),
         :ok <- validate(text) do
      {:ok, text}
    else
      error ->
        {:error,
         "expected exactly Compaction.provide_summary with one nonempty literal string: #{inspect(error, limit: 3)}"}
    end
  end

  defp literal(text) when is_binary(text), do: {:ok, text}
  defp literal({:sigil_S, _, [{:<<>>, _, [text]}, []]}) when is_binary(text), do: {:ok, text}
  defp literal(_), do: {:error, :not_literal}

  def generate(s, attempt \\ 1, refusal \\ nil) do
    note = """
    <harness>Automatic compaction is starting. Return exactly one eval call with code
    Compaction.provide_summary using a multiline raw sigil_S string, no other code.
    Maximum 48000 bytes, preferably much shorter. Sections: Goal; Constraints & Preferences;
    Progress (Done, In Progress, Blocked); Key Decisions with reasons; Next Steps;
    Critical Context (exact paths and APIs). Update any earlier checkpoint. Mark guesses.
    Your own turns will be replaced by this summary; received events retained within a budget.
    System prompt, pid, bindings and full durable log remain unchanged.
    #{if refusal, do: "Previous reply refused: #{refusal}", else: ""}</harness>
    """

    messages =
      [%{"role" => "system", "content" => s.system_prompt} | s.transcript] ++
        [%{"role" => "user", "content" => note}]

    result =
      NanoAgent.call_model(
        self(),
        make_ref(),
        {s.model, s.reasoning, 12_000, nil},
        messages,
        s.request_id + 1
      )

    parsed =
      case result do
        {:ok, %{message: %{"tool_calls" => [call]}} = response} ->
          args = call["function"]["arguments"]
          args = if is_binary(args), do: Jason.decode(args), else: {:ok, args}

          with "eval" <- call["function"]["name"],
               {:ok, %{"code" => code}} <- args,
               {:ok, text} <- parse(code),
               do: {:ok, text, response},
               else: (e -> {:error, inspect(e)})

        other ->
          {:error, inspect(other, limit: 5, printable_limit: 500)}
      end

    case parsed do
      {:ok, _, _} -> parsed
      {:error, reason} when attempt < 3 -> generate(s, attempt + 1, reason)
      error -> error
    end
  end

  def rebuild(s, summary) do
    events =
      for %{"role" => "user", "content" => text} <- s.transcript,
          is_binary(text),
          [event] <- Regex.scan(~r/<event\b[^>]*>.*?<\/event>/s, text),
          do: event

    budget = div(s.max_context * 2, 5)

    kept =
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

    transcript =
      Enum.map(kept, &%{"role" => "user", "content" => &1}) ++
        [
          %{
            "role" => "user",
            "content" =>
              "<harness>Your conversation before this point was compacted by the harness using your own summary. The messages above are received events kept in their own words. Full record: #{s.id} in the node log directory. Some events may have been omitted to fit.\n\n#{summary}</harness>"
          }
        ]

    %{s | transcript: transcript, context_used: 0, measured_bytes: 0}
  end
end
