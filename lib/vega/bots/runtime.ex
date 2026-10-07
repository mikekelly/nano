defmodule Vega.Bots.Runtime do
  @moduledoc "Agent adapter: each stable bot/session pair has its own restored NanoAgent and bounded identity memories."
  def deliver(bot, session, message, root) do
    name = Vega.Bots.agent_name(bot["id"], session["id"])

    with :ok <- ensure_agent(name, bot, session),
         {:ok, memories} <-
           Vega.Bots.Relevance.retrieve(bot["id"], message["text"], root) do
      event = %{
        bot_session: session["id"],
        bot_identity: bot["id"],
        message_id: message["id"],
        message: message["text"],
        author: "person",
        images: message["images"],
        files: message["files"] || [],
        relevant_memories: memories,
        instructions:
          "Reply visibly via Vega.Bots.post(#{inspect(session["id"])}, #{inspect(bot["id"])}, markdown). Do not repeat an already posted reply for this message_id. Final prose is only an operator log, not a chat reply."
      }

      notify(name, event)
    end
  end

  def info(name), do: NanoAgent.info(name)

  def notify(name, event) do
    if NanoAgent.whereis(name) do
      NanoAgent.notify(name, event)
      :ok
    else
      {:error, :not_found}
    end
  end

  defp ensure_agent(name, bot, session) do
    case NanoAgent.info(name) do
      %{pid: pid, halted: nil} when is_pid(pid) ->
        :ok

      %{pid: pid} when is_pid(pid) ->
        {:error, :agent_halted}

      %{id: id} ->
        case DynamicSupervisor.start_child(Nano.AgentSupervisor, {NanoAgent, name: name, id: id}) do
          {:ok, _} -> :ok
          error -> error
        end

      nil ->
        opts = [
          name: name,
          system_prompt: prompt(bot, session),
          start_idle: true,
          model: bot["model"],
          reasoning: bot["reasoning"],
          max_context: bot["max_context"],
          max_turns: bot["max_turns"],
          max_tokens: bot["max_tokens"]
        ]

        case NanoAgent.start(opts) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp prompt(bot, session) do
    File.read!(Path.join(:code.priv_dir(:nano), "system_prompt.txt")) <>
      "\n\n" <>
      """
      You are #{bot["name"]}, a stable companion bot. Identity: #{bot["id"]}.
      Description: #{bot["description"]}
      Voice: #{bot["voice"]}
      Your conversation is session #{session["id"]}, titled #{session["title"]}.
      Never read other session agents' transcripts. Identity memories may be relevant,
      but never invent what you remember. Person messages include small retrieved memories.
      Other bots in this shared conversation: #{inspect(session["bot_ids"])}.
      Act as yourself, do not impersonate another participant. Each bot has its own context.
      To speak to the person run eval:
      Vega.Bots.post(#{inspect(session["id"])}, #{inspect(bot["id"])}, "your Markdown message")
      Prose responses and eval output only reach the operator log, NEVER the person.
      Use Vega.Bots.status(session_id, bot_id, "thinking", detail: "brief safe activity")
      for brief progress (no hidden reasoning, secrets, evals or tools in chat).
      To retain a lasting preference/fact/commitment, use
      Vega.Bots.remember(#{inspect(bot["id"])}, "fact", provenance: %{session: #{inspect(session["id"])}}).
      Never automatically memorize every message. Avoid storing secrets/credentials.
      Memory retrieve/get/update/delete are Vega.Memory functions under identity
      #{inspect("bot:" <> bot["id"])}; root defaults /data/vega.
      In compaction preserve the person's preferences, decisions, commitments, open
      questions, latest message IDs handled and pending human requests; the durable chat
      remains available through Vega.Bots.get_session(session_id). Post once per input.
      When handling human answers, correlate request IDs and acknowledge only after
      safely recording the answer; requester names, not pids, survive restarts.
      For files you produce, use Vega.Bots.attach_file(path) then post(..., files: [ref]).
      Downloads are immutable safe attachments, not inline HTML.
      Attachments use Vega.Images references and the harness native images event.
      Never claim to see an image if your model lacks vision. Never expose secret keys.
      If another bot should weigh in, ask the person instead of creating bot ping-pong.
      """
  end
end
