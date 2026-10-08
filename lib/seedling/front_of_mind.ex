defmodule Seedling.FrontOfMind do
  @moduledoc """
  Experimental short durable note and measured, independently switchable bobbing.

      Seedling.FrontOfMind.set("alice", "Do not change shared production modules.")
      Seedling.FrontOfMind.configure("alice", threshold: 4_000, bobbing: true)
      Seedling.FrontOfMind.get("alice")
      Seedling.FrontOfMind.clear("alice")

  At most 1,000 Unicode characters (not bytes). Setting replaces the note and
  records UTC written_at; clearing removes it. Notes, toggles and bob cursors
  survive restarts and compactions in their own JSON document, not conversation.
  Name is explicit so reusable libraries and operators can inspect another agent.

  Harness integration: call `before_call/3` immediately before **every** model call,
  passing estimated context tokens. Append `result.messages` as user/harness
  notes and log each `result.events` using Nano.Log. After compaction pass
  `compacted: true` once; a note then appears immediately regardless of threshold.
  Returned messages plainly identify the agent's own words, not operator orders.
  Use a single caller per agent; a hook failure must not silently claim a bob.

  Note bobbing defaults on, goals bobbing and drift default off. Configure
  `goals: true` to bob the current goal/next step from `Seedling.Goals`, reusing
  the same policy. Drift is occasional (token interval), bounded, no retries;
  the default adapter uses Jev, returning `:missing_credentials` without a key.
  `recent_activity:` must be a short text summary, never the entire history.
  `drift_adapter:` accepts a `(note, activity) -> {:ok, judgement} | {:error, reason}`
  function; `drift_options:` configures the default HTTP adapter.
  Every bob and judgement returns structured timeline/log metadata. Configuration
  changes enqueue an experiment event for the next hook, including on/off toggles,
  permitting comparisons. This measures interventions, not improved performance.
  All APIs accept `root: path` for isolated storage.
  """
  alias Seedling.{Bobbing, DurableStore, Goals}

  @config %{
    "bobbing" => true,
    "goals" => false,
    "drift" => false,
    "threshold" => 4_000,
    "drift_interval" => 2_000,
    "drift_threshold" => 0.65
  }
  @default %{
    "version" => 1,
    "revision" => 0,
    "note" => nil,
    "written_at" => nil,
    "config" => @config,
    "cursors" => %{},
    "drift_tip" => nil,
    "pending_events" => []
  }

  @doc "Replaces the note (1..1,000 nonblank Unicode characters), returning its metadata."
  def set(agent, note, opts \\ []) do
    cond do
      not is_binary(note) or not String.valid?(note) ->
        {:error, :invalid_note}

      String.length(note) > 1_000 ->
        {:error, :note_too_long}

      String.trim(note) == "" ->
        {:error, :empty_note}

      true ->
        change(agent, opts, fn doc ->
          new = %{
            doc
            | "note" => note,
              "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "revision" => doc["revision"] + 1,
              "drift_tip" => nil
          }

          {:ok, new, note_view(new)}
        end)
    end
  end

  @doc "Clears the note and its cursor; goals and experiment settings are retained."
  def clear(agent, opts \\ []) do
    change(agent, opts, fn doc ->
      new = %{
        doc
        | "note" => nil,
          "written_at" => nil,
          "revision" => doc["revision"] + 1,
          "cursors" => Map.delete(doc["cursors"], "front_of_mind"),
          "drift_tip" => nil
      }

      {:ok, new, nil}
    end)
  end

  @doc "Reads note, timestamp, revision and settings; a cleared note is nil."
  def get(agent, opts \\ []) do
    with {:ok, doc} <- DurableStore.read("front_of_mind", agent, @default, opts),
         :ok <- validate(doc),
         do: {:ok, note_view(doc)}
  end

  @doc "Sets experiment dials: bobbing, goals, drift booleans; threshold/interval tokens; drift_threshold 0..1."
  def configure(agent, attrs, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    change(agent, opts, fn doc ->
      config = Map.merge(doc["config"], attrs)

      with :ok <- validate_config(config) do
        event = %{
          "type" => "bobbing_config",
          "config" => config,
          "changed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        # Bound the experiment change queue if a halted agent is repeatedly configured.
        new = %{
          doc
          | "config" => config,
            "pending_events" => Enum.take(doc["pending_events"] ++ [event], -20)
        }

        {:ok, new, config}
      end
    end)
  end

  @doc "Produces messages and measured events to append before a model call, advancing persisted cursors."
  def before_call(agent, tip, opts \\ [])

  def before_call(agent, tip, opts) when is_integer(tip) and tip >= 0 do
    # Read goals before entering the serialized store: never call it recursively.
    goals = Goals.bobbing_source(agent, opts)

    with {:ok, snapshot} <- DurableStore.read("front_of_mind", agent, @default, opts),
         :ok <- validate(snapshot) do
      # Decision requests must not occupy the shared disk worker (or deadlock an
      # adapter that uses another library). Check freshness when committing below.
      {judged, drift_events, probability} = drift(snapshot, tip, opts)

      change(agent, opts, fn doc ->
        config = doc["config"]
        fresh = Enum.all?(~w(revision config drift_tip), &(doc[&1] == snapshot[&1]))

        {doc, drift_events, probability} =
          if fresh do
            {%{doc | "drift_tip" => judged["drift_tip"]}, drift_events, probability}
          else
            {doc, Enum.map(drift_events, &Map.put(&1, :status, "superseded")), nil}
          end

        note =
          if doc["note"],
            do: %{
              source: "front_of_mind",
              text: doc["note"],
              version: doc["revision"],
              written_at: doc["written_at"]
            }

        sources = [{note, config["bobbing"], probability}]

        {sources, errors} =
          case goals do
            {:ok, source} ->
              {sources ++ [{source, config["goals"], nil}], []}

            {:error, reason} ->
              {sources,
               if(config["goals"],
                 do: [%{type: :bobbing_error, source: "goals", reason: inspect(reason)}],
                 else: []
               )}
          end

        {cursors, bobs} =
          Enum.reduce(sources, {doc["cursors"], []}, fn
            {nil, _, _}, acc ->
              acc

            {source, enabled, p}, {cursors, events} ->
              cursor = Map.get(cursors, source.source, %{})

              case Bobbing.check(source, cursor, tip,
                     enabled: enabled,
                     threshold: config["threshold"],
                     compacted: opts[:compacted],
                     drift_probability: p
                   ) do
                {:skip, _} -> {cursors, events}
                {:bob, new, event} -> {Map.put(cursors, source.source, new), events ++ [event]}
              end
          end)

        pending =
          Enum.map(doc["pending_events"], fn event ->
            %{type: :bobbing_config, config: event["config"], changed_at: event["changed_at"]}
          end)

        events = pending ++ drift_events ++ errors ++ bobs
        new = %{doc | "cursors" => cursors, "pending_events" => []}
        {:ok, new, %{messages: Enum.map(bobs, & &1.text), events: events}}
      end)
    end
  end

  def before_call(_, _, _), do: {:error, :invalid_token_tip}

  defp drift(doc, tip, opts) do
    config = doc["config"]
    last = doc["drift_tip"]
    distance = if is_integer(last), do: max(0, tip - last), else: nil

    due =
      config["drift"] and doc["note"] != nil and
        (last == nil or opts[:compacted] == true or tip < last or
           distance > config["drift_interval"])

    if due do
      activity = opts[:recent_activity] || ""
      started = System.monotonic_time(:millisecond)

      result =
        if is_binary(activity) and String.trim(activity) != "" do
          adapter =
            opts[:drift_adapter] ||
              fn note, activity ->
                Seedling.FrontOfMind.Drift.judge(note, activity, opts[:drift_options] || [])
              end

          safe_judge(adapter, doc["note"], String.slice(activity, 0, 2_000))
        else
          {:error, :missing_recent_activity}
        end

      base = %{
        type: :drift_judgement,
        source: "front_of_mind",
        tip_tokens: tip,
        distance_tokens: distance,
        interval_tokens: config["drift_interval"],
        threshold_probability: config["drift_threshold"],
        enabled: true,
        latency_ms: System.monotonic_time(:millisecond) - started,
        source_version: doc["revision"],
        source_written_at: doc["written_at"]
      }

      {event, p} =
        case result do
          {:ok, %{probability: p} = judgement} when is_number(p) and p >= 0 and p <= 1 ->
            {Map.merge(base, %{
               probability: p,
               model: judgement[:model],
               usage: judgement[:usage] || %{},
               status: "ok"
             }), if(p >= config["drift_threshold"], do: p)}

          {:error, reason} ->
            {Map.merge(base, %{status: "unavailable", reason: inspect(reason)}), nil}

          _ ->
            {Map.merge(base, %{status: "unavailable", reason: "invalid_judgement"}), nil}
        end

      {%{doc | "drift_tip" => tip}, [event], p}
    else
      {doc, [], nil}
    end
  end

  defp safe_judge(adapter, note, activity) do
    adapter.(note, activity)
  rescue
    _ -> {:error, :adapter_failed}
  catch
    _, _ -> {:error, :adapter_failed}
  end

  defp change(agent, opts, fun) do
    DurableStore.update(
      "front_of_mind",
      agent,
      @default,
      fn doc ->
        with :ok <- validate(doc), do: fun.(doc)
      end,
      opts
    )
  end

  defp note_view(doc),
    do: %{
      note: doc["note"],
      written_at: doc["written_at"],
      revision: doc["revision"],
      config: doc["config"]
    }

  defp validate(%{
         "version" => 1,
         "revision" => revision,
         "note" => note,
         "written_at" => written,
         "config" => config,
         "cursors" => cursors,
         "drift_tip" => drift_tip,
         "pending_events" => pending
       }) do
    valid =
      is_integer(revision) and revision >= 0 and valid_cursors?(cursors) and
        valid_pending?(pending) and
        (drift_tip == nil or (is_integer(drift_tip) and drift_tip >= 0)) and
        ((note == nil and written == nil) or
           (is_binary(note) and String.valid?(note) and String.length(note) in 1..1_000 and
              is_binary(written)))

    if valid, do: validate_config(config), else: {:error, :invalid_note_document}
  end

  defp validate(_), do: {:error, :invalid_note_document}

  defp valid_cursors?(cursors) when is_map(cursors) do
    Enum.all?(cursors, fn {source, cursor} ->
      source in ~w(front_of_mind goals) and is_map(cursor) and is_integer(cursor["tip"]) and
        cursor["tip"] >= 0 and
        is_integer(cursor["version"]) and cursor["version"] >= 0
    end)
  end

  defp valid_cursors?(_), do: false

  defp valid_pending?(pending) when is_list(pending) and length(pending) <= 20 do
    Enum.all?(pending, fn event ->
      is_map(event) and event["type"] == "bobbing_config" and
        validate_config(event["config"]) == :ok and is_binary(event["changed_at"])
    end)
  end

  defp valid_pending?(_), do: false

  defp validate_config(config) when is_map(config) do
    valid =
      Enum.sort(Map.keys(config)) == Enum.sort(Map.keys(@config)) and
        Enum.all?(~w(bobbing goals drift), &is_boolean(config[&1])) and
        Enum.all?(~w(threshold drift_interval), &(is_integer(config[&1]) and config[&1] > 0)) and
        is_number(config["drift_threshold"]) and config["drift_threshold"] >= 0 and
        config["drift_threshold"] <= 1

    if valid, do: :ok, else: {:error, :invalid_config}
  end

  defp validate_config(_), do: {:error, :invalid_config}
end
