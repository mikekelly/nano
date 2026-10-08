defmodule Seedling.Bobbing do
  @moduledoc """
  Reusable append-only context bobbing for notes and goals. Called before *each* model
  request. Tracks the transcript index of the last appearance, estimating distance
  as ceil(JSON bytes / 2) plus 4,800 tokens per immutable image, the same conservative byte/token ratio as the harness.
  No turns-based approximation. Provider tokenization is not claimed to be exact.
  `reset/1` forces every source to reappear after compaction. Tracking lives in the
  agent's saved map and therefore survives restarts; no process or timer is needed.
  """
  def reset(s), do: Map.put(s, :seedling_bobs, %{})

  def bob(s, key, text, revision, threshold, fields \\ %{}) do
    tracking = Map.get(s, :seedling_bobs, %{})
    previous = tracking[key]

    recent = if previous, do: Enum.drop(s.transcript, previous.index), else: []

    images =
      Enum.sum(
        for m <- recent,
            do: Enum.count(List.wrap(m["content"]), &match?(%{"type" => "nano_image"}, &1))
      )

    distance =
      if previous, do: div(byte_size(Jason.encode!(recent)) + 1, 2) + images * 4800, else: 0

    changed =
      is_nil(previous) or previous.revision != revision or previous.index > length(s.transcript)

    if changed or distance >= threshold do
      body = "<agent-own-reminder>" <> text <> "</agent-own-reminder>"

      entry =
        Nano.Log.write(
          s,
          :context_bob,
          Map.merge(fields, %{
            source: key,
            text: text,
            distance_tokens: distance,
            threshold_tokens: threshold,
            reason: if(changed, do: "new_or_compacted", else: "distance"),
            distance_method: "json_bytes_div_2_plus_images"
          })
        )

      if entry[:log_error] do
        s
      else
        transcript = s.transcript ++ [%{"role" => "user", "content" => body}]
        tracking = Map.put(tracking, key, %{index: length(transcript), revision: revision})
        s |> Map.put(:transcript, transcript) |> Map.put(:seedling_bobs, tracking)
      end
    else
      s
    end
  end
end
