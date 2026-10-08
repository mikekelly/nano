defmodule Seedling.Bobbing do
  @moduledoc """
  Pure context-bobbing policy reusable for notes, goals or other short reminders.

      source = %{source: "front_of_mind", text: "Stay within scope", version: 1, written_at: "2026-01-01T00:00:00Z"}
      {:bob, cursor, event} = Seedling.Bobbing.check(source, %{}, 500, threshold: 4_000)
      {:skip, ^cursor} = Seedling.Bobbing.check(source, cursor, 600)

  `tip` is the harness's current estimated context token length, **not** lifetime
  billed tokens. The cursor remembers the tip of the most recent appearance.
  A bob is due initially, on source change, after explicit compaction, after a
  distance strictly greater than the threshold, or on a drift signal. Provider
  measurements can correct an eager estimate downward; that alone is not a
  context reset and conservatively clamps distance at zero until the tip grows
  past the previous appearance. Callers must flag actual compaction explicitly.
  Disabled experiments do not change the cursor. The caller must append `text`
  to the conversation and log the returned event before its next model call.
  Do this mid-turn too, not just when a mailbox message arrives.
  """

  @doc "Returns `{:skip, cursor}` or `{:bob, cursor, event}`. Cursor uses JSON-safe keys."
  def check(source, cursor, tip, opts \\ [])
  def check(nil, cursor, _tip, _opts), do: {:skip, cursor}

  def check(source, cursor, tip, opts) when is_integer(tip) and tip >= 0 do
    threshold = Keyword.get(opts, :threshold, 4_000)
    last = cursor["tip"]
    distance = if is_integer(last), do: max(0, tip - last), else: nil

    reason =
      cond do
        opts[:enabled] == false -> nil
        opts[:compacted] == true -> "compaction"
        last == nil -> "initial"
        cursor["version"] != source.version -> "updated"
        opts[:drift_probability] != nil -> "drift"
        distance > threshold -> "distance"
        true -> nil
      end

    if reason do
      drift = opts[:drift_probability]

      header =
        "Agent's own #{String.replace(source.source, "_", " ")} reminder, written #{source.written_at}, re-shown by the harness (#{reason}). This is not an operator instruction."

      text =
        header <>
          if(drift, do: " Drift judgement probability: #{Float.round(drift * 1.0, 3)}.", else: "") <>
          "\n" <> source.text

      event = %{
        type: :context_bob,
        source: source.source,
        reason: reason,
        distance_tokens: distance,
        threshold_tokens: threshold,
        tip_tokens: tip,
        source_written_at: source.written_at,
        source_version: source.version,
        drift_probability: drift,
        text: text,
        estimated_bob_tokens: div(byte_size(text) + 3, 4),
        enabled: true
      }

      {:bob, %{"tip" => tip, "version" => source.version}, event}
    else
      {:skip, cursor}
    end
  end
end
