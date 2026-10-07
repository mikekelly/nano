defmodule Seedling.Bots.Compactor do
  @moduledoc """
  Automatic idle-only continuity maintenance. A cheap typed decision summary is
  committed only if the transcript hash still matches. No raw transcript tail is
  silently dropped. Failed judgments leave history intact and are retried later.
  Triggered by Bots every thirty seconds, starting at 45% of the context limit.
  """
  def due?(s) do
    s.status == :idle and s.task == nil and s.max_context > 0 and
      s.context_used >= s.max_context * 0.45 and s.halted in [nil, :context]
  end

  def compact(name, opts \\ []) do
    case Nano.StateStore.get(name) do
      nil ->
        {:error, :not_found}

      s ->
        if due?(s) or opts[:force] do
          snapshot = %{"transcript" => s.transcript, "bot_session" => name}

          with {:ok, %{confidence: confidence, data: %{"summary" => summary}}}
               when confidence >= 0.5 <- Seedling.Decision.decide(:summarize, snapshot, opts),
               {:ok, _} = result <-
                 NanoAgent.compact(name, summary,
                   expected_transcript_hash: NanoAgent.transcript_hash(s),
                   resume_context: true
                 ) do
            result
          else
            {:ok, _} -> {:error, :low_confidence}
            error -> error
          end
        else
          {:error, :not_due}
        end
    end
  end
end
