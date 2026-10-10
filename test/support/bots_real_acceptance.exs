defmodule Nano.Bots.RealAcceptance do
  @moduledoc """
  Opt-in real-provider acceptance driver. Requiring this file does NOT start bots,
  call models, mutate settings or run scenarios. Only the explicit functions below
  act. Use centrally after deployment; costs real model calls through the runtime.

      Code.require_file("test/support/bots_real_acceptance.exs")
      {:ok, run} = Nano.Bots.RealAcceptance.create(requester: "chosen-stable-agent")
      {:ok, run} = Nano.Bots.RealAcceptance.phase(run, :teach)
      Nano.Bots.RealAcceptance.observe(run) # poll explicitly, no sleeps

  Advance phases only after observing completed responses. :recall opens an independent
  private session; :unrelated uses another independent session. :both, :followup and
  :debate share the group thread. :request creates an actual durable human request;
  answer_request/2 associates the human answer atomically. The stable requester must
  observe {:bots_human_answer, %{request_id:, answer:, session_id:}} and acknowledge
  using Runtime.ack_human/2. This driver never impersonates that requester or auto-acks.

  :checkpoint asks for a voluntary checkpoint (not proof of automatic compaction).
  long_turn/3 posts legitimate discussion material one turn at a time; no fabricated
  tokens or lowered context settings. Automatic threshold acceptance requires a real
  compaction model response in the harness log, completed checkpoint, continued useful
  response, and human review of retained preferences/decisions/commitments/questions.
  Snapshots distinguish those observations, not an inferred pass. Browser/notification
  and qualitative voice checks remain human review. stop/1 stops sessions, preserving
  bot records, memory and harness logs for audit. No deletion or settings mutation.
  """
  alias Nano.Bots
  alias Nano.Bots.Runtime

  def template do
    %{
      execution: :not_run,
      reason: "Requiring this module only compiles it",
      checks:
        Map.new(
          [
            :distinct_voices,
            :both_addressed,
            :followup,
            :debate_natural_end,
            :relevant_cross_session_recall,
            :irrelevant_memory_absent,
            :human_delivery_ack,
            :automatic_compaction_and_retention,
            :browser_notifications
          ],
          &{&1, :not_run}
        )
    }
  end

  def create(opts \\ []) do
    prefix =
      Keyword.get(
        opts,
        :prefix,
        "accept-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    requester = Keyword.fetch!(opts, :requester)

    if not (is_binary(requester) and requester != ""),
      do: raise(ArgumentError, "stable requester name required")

    store = Keyword.get(opts, :store, Nano.Bots.Store)
    runtime = Keyword.get(opts, :runtime, Runtime)

    with {:ok, a} <-
           Bots.create_bot(
             %{
               name: prefix <> " Mira",
               voice: "Warm, dry wit; concise and curious, never a protocol narrator."
             },
             server: store
           ),
         {:ok, b} <-
           Bots.create_bot(
             %{
               name: prefix <> " Sol",
               voice: "Thoughtful, playful skeptic; natural chat, distinct from Mira."
             },
             server: store
           ),
         {:ok, private} <-
           Bots.create_session(%{participant_ids: [a.id], title: prefix <> " private"},
             server: store
           ),
         {:ok, group} <-
           Bots.create_session(
             %{participant_ids: [a.id, b.id], title: prefix <> " group", exchange_ceiling: 8},
             server: store
           ) do
      {:ok,
       %{
         prefix: prefix,
         requester: requester,
         store: store,
         runtime: runtime,
         a: a,
         b: b,
         sessions: %{private: private, group: group},
         markers: %{},
         events: [],
         request: nil
       }}
    end
  end

  def phase(run, :teach),
    do:
      post(
        run,
        :teach,
        :private,
        "For future travel planning, please remember that I prefer overnight trains over flights when practical. My unrelated fun fact is that my childhood mug was cobalt blue. For this conversation: we decided to compare two rail routes, you committed to help compare prices when I bring dates, and the open question is which departure city. Please keep those straight."
      )

  def phase(run, :recall) do
    with {:ok, run} <- new_private(run, :recall) do
      post(
        run,
        :recall,
        :recall,
        "Help me plan a weekend trip between two nearby cities. What travel approach would fit me, and what information do you need?"
      )
    end
  end

  def phase(run, :unrelated) do
    with {:ok, run} <- new_private(run, :unrelated) do
      post(
        run,
        :unrelated,
        :unrelated,
        "Explain why the Moon has phases, in two friendly sentences."
      )
    end
  end

  def phase(run, :both),
    do:
      post(
        run,
        :both,
        :group,
        "Both of you: suggest one different idea for a relaxed Saturday, in your own voices. Leave room for each other."
      )

  def phase(run, :followup),
    do:
      post(
        run,
        :followup,
        :group,
        "No takers? I meant something indoors if it rains. What do you think?"
      )

  def phase(run, :debate),
    do:
      post(
        run,
        :debate,
        :group,
        "Please debate whether a rainy Saturday is better spent cooking together or reading separately. Mira, favor cooking; Sol, favor reading. Respond to each other's points, then find a natural stopping point. Keep it friendly and short."
      )

  def phase(run, :checkpoint),
    do:
      post(
        run,
        :checkpoint,
        :private,
        "Please voluntarily checkpoint your context now using the live Compaction capability, retaining my travel preference, our route decision, your price-comparison commitment and the open departure-city question. Then tell me naturally what we still need to settle. This is a voluntary checkpoint test, not automatic threshold evidence."
      )

  def phase(run, :retention),
    do:
      post(
        run,
        :retention,
        :private,
        "Where did we leave our travel planning? Please remind me of my preference, our decision, your commitment and the open question, without discussing any internal machinery."
      )

  def phase(run, :request) do
    with {:ok, request} <-
           Runtime.ask_human(
             run.a.id,
             "Acceptance request: which departure city should we use, Lyon or Paris?",
             server: run.runtime,
             requester: run.requester,
             session_id: run.sessions.private.id
           ) do
      {:ok,
       event(%{run | request: request}, :request_created, %{
         request_id: request.id,
         requester: run.requester
       })}
    end
  end

  def answer_request(%{request: %{id: id}} = run, answer) when is_binary(answer) do
    with {:ok, request} <- Bots.answer_request(id, answer, server: run.store) do
      {:ok,
       event(%{run | request: request}, :request_answered, %{
         request_id: id,
         answer_message_id: request.answer_message_id
       })}
    end
  end

  @doc "One explicit long conversational turn; caller supplies real material and controls cadence."
  def long_turn(run, number, material)
      when is_integer(number) and is_binary(material) and byte_size(material) <= 90000 do
    post(
      run,
      {:long_turn, number},
      :private,
      "Let's continue our trip-planning discussion. Please identify useful tradeoffs in this material and keep our prior preference, decisions, commitments and open questions in mind:\n" <>
        material
    )
  end

  defp new_private(run, key) do
    with {:ok, session} <-
           Bots.create_session(
             %{participant_ids: [run.a.id], title: run.prefix <> " " <> to_string(key)},
             server: run.store
           ) do
      {:ok, %{run | sessions: Map.put(run.sessions, key, session)}}
    end
  end

  defp post(run, phase, session_key, text) do
    session = Map.fetch!(run.sessions, session_key)
    key = run.prefix <> "-" <> inspect(phase)

    with {:ok, message} <-
           Bots.post_human(session.id, %{text: text, idempotency_key: key}, server: run.store) do
      marker = %{session_id: session.id, sequence: message.sequence, message_id: message.id}

      {:ok,
       event(
         %{run | markers: Map.put(run.markers, phase, marker)},
         :human_posted,
         Map.put(marker, :phase, phase)
       )}
    end
  end

  defp event(run, type, fields),
    do: %{
      run
      | events:
          run.events ++
            [%{at: DateTime.utc_now() |> DateTime.to_iso8601(), type: type, fields: fields}]
    }

  @doc "Read-only current facts. Missing replies are pending, not passes; review snippets qualitatively."
  def observe(run) do
    sessions =
      Map.new(run.sessions, fn {key, session} ->
        {:ok, current} = Bots.get_session(session.id, server: run.store)
        {:ok, page} = Bots.list_messages(session.id, server: run.store, limit: 200)

        {key,
         %{
           session: current,
           messages: Enum.map(page.messages, &snippet/1),
           has_more: page.has_more,
           agents: Enum.map(session.participant_ids, &agent_observation(&1, session.id))
         }}
      end)

    phases =
      Map.new(run.markers, fn {phase, marker} ->
        {:ok, page} =
          Bots.list_messages(marker.session_id,
            server: run.store,
            after: marker.sequence,
            limit: 200
          )

        # Bound this phase by the next human post, not by later unrelated bot responses.
        replies =
          page.messages
          |> Enum.take_while(&(&1.actor != :human))
          |> Enum.filter(&match?({:bot, _}, &1.actor))

        speakers = Enum.map(replies, fn m -> elem(m.actor, 1) end) |> Enum.uniq()

        {phase,
         %{
           replies: Enum.map(replies, &snippet/1),
           speakers: speakers,
           both_spoke: run.a.id in speakers and run.b.id in speakers,
           observation: if(replies == [], do: :pending_or_silent, else: :responses_observed)
         }}
      end)

    request =
      if run.request do
        {:ok, current} = Bots.get_request(run.request.id, server: run.store)

        %{
          record: current,
          answer_associated: is_binary(current[:answer_message_id]),
          delivery_attempted: current.delivery_attempts > 0,
          acked: current.status == :acked
        }
      else
        %{observation: :not_run}
      end

    {:ok, memories} = Bots.list_memories(run.a.id, server: run.store, limit: 200)

    %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      prefix: run.prefix,
      bot_ids: [run.a.id, run.b.id],
      requester: run.requester,
      events: run.events,
      sessions: sessions,
      phases: phases,
      memory: Enum.map(memories, &Map.update!(&1, :text, fn t -> String.slice(t, 0, 1000) end)),
      human_request: request,
      qualitative_checks: template().checks,
      caveat:
        "Response presence is not semantic correctness. Review voice, relevance, debate, retention and notification evidence independently."
    }
  end

  defp snippet(m),
    do:
      Map.take(m, [:id, :sequence, :actor, :epoch, :session_id])
      |> Map.put(:text, String.slice(m.text, 0, 1800))

  defp agent_observation(bot, session) do
    name = Nano.Bots.Agent.name(bot, session)

    case NanoAgent.info(name) do
      nil ->
        %{name: name, observation: :not_started}

      info ->
        path = Path.join(Application.fetch_env!(:nano, :log_dir), info.id <> ".jsonl")
        # Stream only selected metadata, never copy raw evals/provider payloads/credentials.
        evidence =
          if File.exists?(path) do
            File.stream!(path)
            |> Enum.reduce(%{automatic_model_responses: 0, completed: 0}, fn line, acc ->
              case Jason.decode(line) do
                {:ok, %{"type" => "compaction_completed"}} ->
                  Map.update!(acc, :completed, &(&1 + 1))

                {:ok, %{"compaction" => true}} ->
                  Map.update!(acc, :automatic_model_responses, &(&1 + 1))

                _ ->
                  acc
              end
            end)
          else
            %{automatic_model_responses: 0, completed: 0}
          end

        Map.take(info, [:id, :status, :halted, :context_window])
        |> Map.merge(%{
          name: name,
          compaction: evidence,
          automatic_threshold_observed: evidence.automatic_model_responses > 0,
          checkpoint_observed: evidence.completed > 0
        })
    end
  end

  @doc "Persist curated observations as an inspect-able term; never writes settings/raw harness payloads."
  def snapshot(run, path) do
    observations = observe(run)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(
             path,
             inspect(observations, limit: :infinity, printable_limit: :infinity, pretty: true)
           ) do
      {:ok, %{path: path, observations: observations}}
    end
  end

  @doc "Stop sessions only; preserve all audit records. Does not terminate shared runtime."
  def stop(run) do
    Map.new(run.sessions, fn {key, session} ->
      {key, Bots.stop_session(session.id, server: run.store)}
    end)
  end
end
