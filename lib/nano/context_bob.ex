defmodule Nano.ContextBob do
  @moduledoc """
  Reusable append-only token-distance bobbing. `apply/4` returns `{transcript, cursors,
  measurements}` for sources `%{key:, text:, version:, threshold_tokens:}`. A cursor holds
  the exact last message; distance is JSON bytes / 2 in its suffix, not turns. Missing
  anchors (including compaction) bob immediately. No cached prefix is rewritten.
  """
  def apply(transcript, cursors, sources, force \\ false) do
    Enum.reduce(sources, {transcript, cursors, []}, fn source, {t, c, events} ->
      previous = c[source.key]
      distance = distance(t, previous)

      reason =
        cond do
          force -> :compaction
          previous == nil -> :first
          previous.version != source.version -> :changed
          distance == nil -> :missing_anchor
          distance >= source.threshold_tokens -> :distance
          true -> nil
        end

      if reason do
        message = %{"role" => "user", "content" => source.text}
        cursor = %{message: message, version: source.version}

        event = %{
          source: source.key,
          reason: reason,
          distance_tokens: distance,
          threshold_tokens: source.threshold_tokens,
          text: source.text
        }

        {t ++ [message], Map.put(c, source.key, cursor), events ++ [event]}
      else
        {t, c, events}
      end
    end)
  end

  def distance(_, nil), do: nil

  def distance(transcript, %{message: message}) do
    case transcript
         |> Enum.with_index()
         |> Enum.filter(fn {m, _} -> m == message end)
         |> List.last() do
      nil ->
        nil

      {_, index} ->
        transcript |> Enum.drop(index + 1) |> Enum.reduce(0, fn m, n -> n + tokens(m) end)
    end
  end

  def tokens(message), do: div(byte_size(Jason.encode!(message)) + 1, 2)
end
