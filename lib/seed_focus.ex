defmodule SeedFocus do
  @moduledoc """
  Experimental context bobbing. `set(agent, note)` (max 1,000 Unicode characters),
  `clear(agent)`, `get(agent)`, `configure(agent, enabled: false)` survive restarts.

  Harness integration: before EVERY model call (including tool continuations), call
  `before_call(agent, cumulative_context_tokens, epoch: compaction_generation)`.
  It returns `{:ok, %{message: nil | text, events: [maps]}}`. Append a non-nil message
  at the conversation tip and log EVERY returned event on timeline and log. Token
  cursor is the size before append, not turns; epoch MUST change after compaction.
  First call, changed note, and changed epoch bob immediately. The persisted cursor
  prevents repeated bobs after process restart. Configure threshold (default 4,000),
  enabled and drift_enabled independently for experimental comparisons.

  Optional `drift: fn note, recent -> {:ok, probability} end` and `recent: text`
  perform an advanced judgement on a due bob only; this must be a cheap bounded
  decision-model adapter, never the agent model. Inputs are capped to 2,000 chars;
  failures are logged, never change the note or suppress a bob. No credentials or
  decision service are assumed. Every judgement and bob includes its trigger data.
  No timers, messages, or model calls are hidden here. Returned events are the
  caller's responsibility; commit and append should be adjacent. A crash between
  them can lose a bob until the next threshold (at-most-once hook).
  """
  alias SeedMemory.Store

  defp initial,
    do: %{
      "note" => nil,
      "enabled" => true,
      "drift_enabled" => false,
      "threshold" => 4000,
      "last" => nil,
      "epoch" => nil
    }

  def get(agent, opts \\ []), do: Store.read(agent, "focus", initial(), opts)

  def set(agent, note, opts \\ []) do
    if Store.text(note, 1000) and note != "" do
      Store.update(agent, "focus", initial(), opts, fn s ->
        next = Map.merge(s, %{"note" => note, "written_at" => Store.now(), "last" => nil})
        {:ok, next, next}
      end)
    else
      {:error, :note_must_be_1_to_1000_characters}
    end
  end

  def clear(agent, opts \\ []) do
    Store.update(agent, "focus", initial(), opts, fn s ->
      {:ok, Map.merge(s, %{"note" => nil, "last" => nil}), :cleared}
    end)
  end

  def configure(agent, settings, opts \\ []) do
    settings = Map.new(settings, fn {k, v} -> {to_string(k), v} end)

    Store.update(agent, "focus", initial(), opts, fn s ->
      next = Map.merge(s, Map.take(settings, ["enabled", "drift_enabled", "threshold"]))

      if is_boolean(next["enabled"]) and is_boolean(next["drift_enabled"]) and
           is_integer(next["threshold"]) and next["threshold"] > 0 do
        next = Map.put(next, "last", nil)

        {:ok, next,
         %{events: [%{type: :focus_configuration, settings: settings, at: Store.now()}]}}
      else
        {:error, :invalid_configuration}
      end
    end)
  end

  def before_call(agent, tokens, opts \\ []) do
    if is_integer(tokens) and tokens >= 0 do
      Store.update(agent, "focus", initial(), opts, fn s ->
        epoch = Keyword.get(opts, :epoch, 0)
        distance = if s["last"], do: max(0, tokens - s["last"]), else: 0

        reason =
          cond do
            s["note"] == nil or not s["enabled"] -> nil
            s["last"] == nil -> :new_note
            s["epoch"] != epoch -> :compaction
            tokens < s["last"] -> :context_reset
            distance >= s["threshold"] -> :threshold
            true -> nil
          end

        if reason do
          {prob, events} = drift(s, opts)

          warning =
            if is_number(prob),
              do: "\nDrift estimate: #{prob} (experimental; choose whether to update your note).",
              else: ""

          message =
            "[Your own front-of-mind note, re-shown by the harness; agent #{inspect(agent)}, written #{s["written_at"]}]\n#{s["note"]}" <>
              warning

          event = %{
            type: :focus_bob,
            reason: reason,
            distance_tokens: distance,
            threshold: s["threshold"],
            at: Store.now(),
            written_at: s["written_at"]
          }

          {:ok, Map.merge(s, %{"last" => tokens, "epoch" => epoch}),
           %{message: message, events: events ++ [event]}}
        else
          {:ok, s, %{message: nil, events: []}}
        end
      end)
    else
      {:error, :invalid_token_cursor}
    end
  end

  defp drift(s, opts) do
    if s["drift_enabled"] do
      result =
        try do
          case Keyword.get(opts, :drift) do
            fun when is_function(fun, 2) ->
              fun.(s["note"], String.slice(Keyword.get(opts, :recent, ""), 0, 2000))

            _ ->
              {:error, :drift_adapter_unavailable}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, _ -> {:error, kind}
        end

      case result do
        {:ok, p} when is_number(p) and p >= 0 and p <= 1 ->
          {p, [%{type: :focus_drift, probability: p, at: Store.now()}]}

        _ ->
          {nil,
           [
             %{
               type: :focus_drift_error,
               error: inspect(result) |> String.slice(0, 300),
               at: Store.now()
             }
           ]}
      end
    else
      {nil, []}
    end
  end
end
