defmodule Seedling.FrontOfMind do
  @moduledoc """
  Experimental durable agent-owned reminders (maximum 1,000 characters).

      Seedling.FrontOfMind.set(me, "Keep the user's budget below £200.")
      Seedling.FrontOfMind.configure(me, enabled: true, threshold: 8000, drift: true)
      Seedling.FrontOfMind.clear(me)

  Harness hooks: `before_request(state)` at every model request, including between
  tool calls; `after_compaction(state)` after replacing the transcript. Notes are
  explicitly attributed to their author and writing time, never operator authority.
  Drift is optional, advisory, and never changes the note. All bobs and judgements
  use Nano.Log and the existing timeline PubSub. Both interventions can be disabled
  independently for controlled comparisons. See docs/bots-goals.md for limitations.
  """
  alias Seedling.{CapabilityStore, Bobbing, Goals}

  @empty %{
    "note" => nil,
    "written_at" => nil,
    "revision" => 0,
    "enabled" => true,
    "threshold" => 8000,
    "drift" => false
  }
  def get(agent, opts \\ []),
    do: CapabilityStore.get(:front_of_mind, CapabilityStore.agent(agent), @empty, opts)

  def set(agent, note, opts \\ []) do
    if is_binary(note) and String.length(note) <= 1000 and String.trim(note) != "" do
      change(
        agent,
        fn d ->
          Map.merge(d, %{
            "note" => note,
            "written_at" => CapabilityStore.now(),
            "revision" => d["revision"] + 1
          })
        end,
        opts
      )
    else
      {:error, :note_must_be_1_to_1000_characters}
    end
  end

  def clear(agent, opts \\ []),
    do: change(agent, fn d -> %{d | "note" => nil, "revision" => d["revision"] + 1} end, opts)

  def configure(agent, settings, opts \\ []) do
    with {:ok, old} <- get(agent, opts) do
      d = Map.merge(old, Map.new(settings, fn {k, v} -> {to_string(k), v} end))

      if Enum.all?(Map.keys(Map.new(settings)), &(to_string(&1) in ~w(enabled threshold drift))) and
           is_boolean(d["enabled"]) and is_boolean(d["drift"]) and is_integer(d["threshold"]) and
           d["threshold"] >= 100 do
        change(
          agent,
          fn old -> Map.merge(old, Map.take(d, ~w(enabled threshold drift))) end,
          opts
        )
      else
        {:error, :invalid_configuration}
      end
    end
  end

  defp change(agent, fun, opts) do
    case CapabilityStore.agent(agent) do
      nil ->
        {:error, :unknown_agent}

      name ->
        case CapabilityStore.update(
               :front_of_mind,
               name,
               @empty,
               fn d ->
                 new = fun.(d)
                 {:ok, new, new}
               end,
               opts
             ) do
          {:ok, doc} ->
            if info = NanoAgent.info(name),
              do:
                Nano.Log.write(info, :front_of_mind_updated, %{
                  configuration: Map.take(doc, ~w(enabled threshold drift revision written_at)),
                  note_characters: if(doc["note"], do: String.length(doc["note"]), else: 0)
                })

            {:ok, :ok}

          error ->
            error
        end
    end
  end

  def after_compaction(s), do: s |> Bobbing.reset() |> before_request()

  def before_request(s, opts \\ []) do
    s =
      case get(s.name, opts) do
        {:ok, %{"enabled" => true, "note" => note} = d} when is_binary(note) ->
          {s, drift} = maybe_drift(s, d)

          Bobbing.bob(
            s,
            "front_of_mind",
            "#{s.name}'s own note, written #{d["written_at"]}, re-shown by the harness (not an outside instruction):\n#{note}" <>
              drift,
            d["revision"],
            d["threshold"],
            %{written_at: d["written_at"]}
          )

        _ ->
          s
      end

    case Goals.document(s.name, opts) do
      {:ok, %{"bobbing" => true} = d} ->
        case Goals.review(s.name, Keyword.put(opts, :max_chars, 1000)) do
          {:ok, text} ->
            Bobbing.bob(
              s,
              "goals",
              "#{s.name}'s own open goals, re-shown by the harness:\n#{text}",
              d["revision"],
              d["threshold"]
            )

          _ ->
            s
        end

      _ ->
        s
    end
  end

  # At most one compact judgement every five model requests. The adapter is optional;
  # missing credentials/services are logged as blocked, never replaced by invented scores.
  defp maybe_drift(s, %{"drift" => true} = d) do
    request = Map.get(s, :request_id, 0)
    last = Map.get(s, :seedling_drift_request, -5)

    if request - last >= 5 or Map.get(s, :seedling_drift_revision) != d["revision"] do
      activity =
        s.transcript
        |> Enum.take(-6)
        |> Enum.map_join("\n", fn m ->
          content = m["content"] || ""
          text = if is_binary(content), do: content, else: Jason.encode!(content)
          String.slice(text, 0, 400)
        end)

      result = Seedling.Judgement.ask(:drift, %{note: d["note"], activity: activity})

      Nano.Log.write(s, :drift_judgement, %{
        result: result,
        note_revision: d["revision"],
        enabled: true
      })

      hint =
        case result do
          {:ok, %{probability: p}} when p >= 0.65 ->
            "\nAdvisory: a small decision model estimated drift probability #{Float.round(p * 1.0, 3)}. Return to this note or deliberately update it."

          _ ->
            ""
        end

      {s
       |> Map.put(:seedling_drift_request, request)
       |> Map.put(:seedling_drift_hint, hint)
       |> Map.put(:seedling_drift_revision, d["revision"]), hint}
    else
      {s, Map.get(s, :seedling_drift_hint, "")}
    end
  end

  defp maybe_drift(s, _), do: {s, ""}
end
