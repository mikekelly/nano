defmodule Compaction do
  @moduledoc "Automatic checkpoints for every NanoAgent; voluntary provide_summary(text) takes effect after the eval result."
  def provide_summary(text) when is_binary(text) do
    with :ok <- validate(text), [parent | _] <- Process.get(:"$callers", []) do
      GenServer.cast(parent, {:compact_summary, text})
      :ok
    else
      error -> error
    end
  end

  def validate(text) do
    if String.trim(text) != "" and byte_size(text) <= 48000,
      do: :ok,
      else: {:error, "summary must be nonempty and at most 48000 bytes"}
  end

  def parse(code) do
    with {:ok, {{:., _, [{:__aliases__, _, [:Compaction]}, :provide_summary]}, _, [text]}} <-
           Code.string_to_quoted(code),
         true <- is_binary(text),
         :ok <- validate(text) do
      {:ok, text}
    else
      _ ->
        {:error,
         "Use exactly Compaction.provide_summary with one literal string of 1..48000 bytes"}
    end
  end

  def run(model, reasoning, messages, attempt \\ 1, reason \\ "") do
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

    result =
      Nano.Model.chat(
        model,
        messages ++ [%{"role" => "user", "content" => note}],
        tools,
        reasoning,
        12000
      )

    parsed =
      with {:ok, %{message: %{"tool_calls" => [call]}}} <- result,
           {:ok, %{"code" => code}} <- Jason.decode(call["function"]["arguments"]),
           "eval" <- call["function"]["name"],
           do: parse(code)

    case parsed do
      {:ok, text} ->
        {:ok, text}

      error when attempt < 3 ->
        run(
          model,
          reasoning,
          messages,
          attempt + 1,
          "Previous attempt refused: #{inspect(error)}"
        )

      error ->
        {:error, inspect(error)}
    end
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
        if size + byte_size(e) < div(s.max_context * 4, 5),
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
