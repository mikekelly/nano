defmodule Compaction do
  @moduledoc """
  Automatic checkpoints are requested by NanoAgent before its context reserve is spent.
  Voluntarily checkpoint with an eval containing only
  `Compaction.provide_summary(~S\"\"\"...\"\"\")`. The harness parses this call without executing
  it, and replaces history only after answering the tool. Bindings, identity and mailbox
  are untouched. Automatic reserve is 16,384 tokens (one quarter of smaller windows).
  Without a provider tokenizer, the summary cap is 12,000 UTF-8 bytes, a strict
  conservative upper bound of 12,000 byte-level tokens. First brief is pinned; newer received events fit a fifth
  of the window. Explicitly attributed reports from own children are summarized rather
  than retained. Unattributed messages cannot reliably be classified as child reports.
  Checkpoints use Goal; Constraints & Preferences; Progress (Done, In Progress,
  Blocked); Key Decisions with reasons; Next Steps; Critical Context. Mark guesses
  as unverified. Update previous checkpoints, do not repeat received messages.
  Full history remains in Nano.Log under the node's logs directory.
  """
  @reserve 16_384
  def reserve, do: @reserve

  @doc "This call is intercepted by the harness; it cannot be used inside other code."
  def provide_summary(_),
    do:
      {:error, "Use a standalone eval call to Compaction.provide_summary with a literal string."}

  @doc false
  def parse(code) do
    with {:ok, {{:., _, [{:__aliases__, _, [:Compaction]}, :provide_summary]}, _, [literal]}} <-
           Code.string_to_quoted(code),
         {:ok, text} <- literal_text(literal),
         :ok <- validate(text) do
      {:ok, text}
    else
      {:error, reason} ->
        {:error, inspect(reason)}

      _ ->
        {:error,
         "Expected exactly Compaction.provide_summary with one literal string and no other code."}
    end
  end

  defp literal_text(text) when is_binary(text), do: {:ok, text}
  defp literal_text({:sigil_S, _, [{:<<>>, _, [text]}, []]}) when is_binary(text), do: {:ok, text}
  defp literal_text(_), do: {:error, "Summary must be a literal string (use ~S)."}

  def validate(text)
      when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:error, "The summary is empty."}

      byte_size(text) > 12_000 ->
        {:error,
         "The summary exceeds the 12,000 UTF-8 byte bound (at most 12,000 byte-level tokens)."}

      true ->
        :ok
    end
  end

  def note(reason \\ nil) do
    "<harness>Automatic compaction is starting because the context limit is near. " <>
      "Do not run other code. Reply with exactly one eval call: Compaction.provide_summary(~S\"\"\"\n...\n\"\"\"). " <>
      "Write a structured checkpoint: Goal; Constraints & Preferences; Progress (Done, In Progress, Blocked); " <>
      "Key Decisions with reasons; Next Steps; Critical Context (exact paths, functions and errors). " <>
      "Update any previous summary. Mark unverified guesses explicitly. Do not repeat the system prompt or received messages. " <>
      "Use at most 12,000 tokens and 12,000 UTF-8 bytes; shorter when possible. " <>
      "Your own model writes this summary; the harness will replace your work history, preserving received events. " <>
      if(reason, do: "Previous reply refused: #{reason}</harness>", else: "</harness>")
  end

  @doc false
  def rebuild(transcript, text, window, log_path, excluded \\ []) do
    events =
      transcript
      |> Enum.flat_map(fn
        %{"role" => "user", "content" => content} -> received(content, excluded)
        _ -> []
      end)

    budget = div(max(window, 0), 5) * 2
    first = pin_first(List.first(events), budget)

    {kept, _} =
      events
      |> Enum.drop(1)
      |> Enum.reverse()
      |> Enum.reduce({[], cost(first)}, fn event, {acc, size} ->
        if size + cost(event) <= budget,
          do: {[event | acc], size + cost(event)},
          else: {acc, size}
      end)

    kept = if first, do: [first | kept], else: kept

    Enum.map(kept, &%{"role" => "user", "content" => &1}) ++
      [
        %{
          "role" => "user",
          "content" =>
            "Your conversation before this point was compacted by the harness using your own summary. The messages above are ones you received, kept in their own words; this is your summary of everything else. Full record: #{log_path}.\n\n#{text}"
        }
      ]
  end

  # Historic image deliveries batch several events into one text block followed by refs,
  # without per-event attribution. Keep that delivery atomically, never attach its refs
  # to every regex match or to unrelated retained text. A mixed child-report bundle keeps
  # its attribution too; an entirely excluded bundle can be dropped as a whole.
  defp received(content, excluded) do
    {text, images} = text_and_images(content)

    events =
      for [event] <- Regex.scan(~r/<event\b[^>]*>.*?<\/event>(?=\n<(?:event|harness)\b|$)/s, text),
          do: event

    cond do
      images == [] -> Enum.reject(events, &(&1 in excluded))
      events == [] -> [bundle(text, images)]
      Enum.all?(events, &(&1 in excluded)) -> []
      true -> [bundle(Enum.join(events, "\n"), images)]
    end
  end

  defp text_and_images(text) when is_binary(text), do: {text, []}

  defp text_and_images(parts) when is_list(parts) do
    text = for %{"type" => "text", "text" => text} <- parts, is_binary(text), do: text
    images = for %{"type" => "image_ref"} = image <- parts, do: image
    {Enum.join(text, "\n"), images}
  end

  defp text_and_images(_), do: {"", []}
  defp bundle(text, images), do: [%{"type" => "text", "text" => text} | images]
  # The brief's words stay pinned, but pixels must not bypass the retention budget.
  # Keep an honest, durable notice inside the event rather than pretending the model
  # still has the image. Semantic observations belong in the model's summary.
  defp pin_first(parts, budget) when is_list(parts) do
    if cost(parts) <= budget do
      parts
    else
      {text, images} = text_and_images(parts)

      hashes =
        Enum.map_join(images, ", ", fn %{"image_ref" => ref} ->
          ref[:image_ref] || ref["image_ref"] || "unknown"
        end)

      notice =
        "<harness>Image attachments omitted by compaction because the pinned brief exceeds the image/event retention budget. Pixels are no longer available; do not infer their contents. Omitted image hashes: " <>
          hashes <> ". Full image references remain in the original log.</harness>"

      if String.ends_with?(text, "</event>"),
        do: String.replace_suffix(text, "</event>", "\n" <> notice <> "</event>"),
        else: text <> "\n" <> notice
    end
  end

  defp pin_first(first, _budget), do: first

  defp cost(nil), do: 0
  defp cost(text) when is_binary(text), do: byte_size(text)
  defp cost(parts), do: Nano.ImageInput.estimated_bytes(parts)
end
