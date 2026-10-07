defmodule Nano.Bots do
  @moduledoc "Persistent consumer identities, isolated conversations and human requests. See docs/nova-bots.md."
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def ensure_started do
    if Process.whereis(__MODULE__) == nil do
      case Supervisor.start_child(Nano.Supervisor, {__MODULE__, []}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} -> Supervisor.restart_child(Nano.Supervisor, __MODULE__)
        e -> e
      end
    end
  end

  def attach(sid, bid, source, opts \\ []),
    do: call(opts[:server] || __MODULE__, {:attach, sid, bid, source, opts, caller_agent()})

  def file(id, server \\ __MODULE__), do: call(server, {:file, id})
  def service_ref(id), do: {:via, Registry, {Nano.Registry, {:bots_service, id}}}

  def usage(sid, bid, server \\ __MODULE__), do: call(server, {:usage, sid, bid})

  def archive(sid, generation, server \\ __MODULE__),
    do: call(server, {:archive, sid, generation})

  def history(sid, opts \\ []), do: call(opts[:server] || __MODULE__, {:history, sid, opts})

  def checkpoint(sid, generation, opts \\ []),
    do: call(opts[:server] || __MODULE__, {:checkpoint, sid, generation, opts})

  def message(sid, index, opts \\ []),
    do: call(opts[:server] || __MODULE__, {:message, sid, index, opts})

  def snapshot(server \\ __MODULE__), do: call(server, :snapshot)
  def create_bot(name, opts \\ []), do: call(opts[:server] || __MODULE__, {:bot, name, opts})

  def create_session(ids, opts \\ []),
    do: call(opts[:server] || __MODULE__, {:session, ids, opts})

  def configure(bid, opts), do: call(opts[:server] || __MODULE__, {:configure, bid, opts})

  def say(sid, text, server \\ __MODULE__), do: call(server, {:say, sid, text})

  def post(sid, bid, text, server \\ __MODULE__),
    do: call(server, {:post, sid, bid, text, caller_agent()})

  def remember(bid, text, opts \\ []), do: call(opts[:server] || __MODULE__, {:memory, bid, text})

  def ask_human(bid, question, opts \\ []),
    do:
      call(
        opts[:server] || __MODULE__,
        {:ask, bid, question,
         opts
         |> Keyword.put_new(:reply_to, caller_agent() || self())
         |> Keyword.put(:actor, caller_agent())}
      )

  def answer(rid, text, server \\ __MODULE__), do: call(server, {:answer, rid, text})

  def set_notifications(enabled, server \\ __MODULE__),
    do: call(server, {:notifications, enabled})

  defp call(server, msg) do
    if server == __MODULE__, do: ensure_started()
    GenServer.call(server, msg, 30_000)
  end

  @doc "Stable registered agent identity from an eval task's caller chain, or nil."
  def caller_agent do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      if Process.whereis(Nano.Registry) do
        Enum.find_value(Registry.keys(Nano.Registry, pid), fn
          {:agent, name} -> name
          _ -> nil
        end)
      end
    end)
  end

  defp current_actor?(nil, _, _, _), do: true

  defp current_actor?("bot-" <> _ = actor, bid, sid, generation),
    do: actor == "bot-#{bid}-#{sid}-#{generation}"

  defp current_actor?(_, _, _, _), do: true

  defp safe_agent_options(opts) do
    Keyword.take(opts, [:model, :reasoning, :max_context, :max_tokens, :max_turns])
  end

  defp id,
    do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp now, do: System.system_time(:millisecond)
  defp valid?(s), do: is_binary(s) and String.trim(s) != "" and byte_size(s) <= 32_000
  @impl true
  def init(opts) do
    path =
      opts[:path] ||
        Path.join(Application.get_env(:nano, :state_dir, "/data/state"), "bots/state.term")

    data =
      case File.read(path) do
        {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe])
        {:error, :enoent} -> %{bots: %{}, sessions: %{}, requests: %{}, notifications: false}
        {:error, reason} -> raise "bots state unreadable: #{inspect(reason)}"
      end

    data = data |> Map.put_new(:service_id, id()) |> Map.put_new(:artifacts, %{})
    server = {:via, Registry, {Nano.Registry, {:bots_service, data.service_id}}}
    {:ok, _} = Registry.register(Nano.Registry, {:bots_service, data.service_id}, nil)
    Process.send_after(self(), :monitor, 500)

    {:ok,
     %{
       data: data,
       server: server,
       path: path,
       runner: opts[:runner] || (&Nano.Bots.Runtime.deliver/4),
       decision:
         opts[:decision] ||
           fn task, state ->
             Nano.Bots.Decision.decide(task, state, opts[:decision_options] || [])
           end,
       last_notification: 0,
       group_budget: %{},
       work_queues: %{},
       preparing: MapSet.new(),
       subscriptions: MapSet.new(),
       compacting: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:attach, sid, bid, source, opts, actor}, _, s) do
    caption = opts[:caption] || "Attached file"

    with true <- valid?(caption),
         %{bots: bots} = chat <- s.data.sessions[sid],
         true <- bid == :human or bid in bots,
         true <- current_actor?(actor, bid, sid, chat.generation),
         {:ok, file, path} <-
           Nano.Bots.Files.store(
             Path.join(Path.dirname(s.path), "files"),
             source,
             opts[:filename]
           ) do
      file = Map.merge(file, %{service: s.data.service_id, session: sid, who: bid})
      chat = append(chat, bid, caption)
      messages = List.update_at(chat.messages, -1, &Map.put(&1, :files, [file]))
      chat = %{chat | messages: messages}
      chat = if bid == :human, do: chat, else: put_in(chat, [:status, bid], :idle)
      data = s.data |> put_in([:sessions, sid], chat) |> put_in([:artifacts, file.id], file)

      case commit(s, data, {:ok, file}, %{session: sid, bot: bid, text: caption}) do
        {:reply, {:error, _} = error, state} ->
          File.rm(path)
          {:reply, error, state}

        reply ->
          reply
      end
    else
      {:error, _} = error -> {:reply, error, s}
      _ -> {:reply, {:error, :invalid_file_or_participant}, s}
    end
  end

  def handle_call({:file, id}, _, s) do
    case s.data.artifacts[id] do
      nil ->
        {:reply, {:error, :not_found}, s}

      file ->
        path = Path.join([Path.dirname(s.path), "files", file.id <> ".data"])
        {:reply, {:ok, Map.put(file, :path, path)}, s}
    end
  end

  def handle_call({:usage, sid, bid}, _, s) do
    case s.data.sessions[sid] do
      %{generation: generation, bots: bots} when generation > 0 ->
        if bid in bots do
          usage =
            Enum.reduce(0..(generation - 1), %{turns: 0, tokens: 0}, fn gen, acc ->
              case File.read(checkpoint_path(s.path, sid, gen)) do
                {:ok, bytes} ->
                  state =
                    bytes
                    |> :erlang.binary_to_term([:safe])
                    |> Enum.find(&(&1.name == "bot-#{bid}-#{sid}-#{gen}"))

                  if state,
                    do: %{
                      turns: acc.turns + state.turns_used,
                      tokens: acc.tokens + state.tokens_used
                    },
                    else: acc

                _ ->
                  acc
              end
            end)

          {:reply, usage, s}
        else
          {:reply, %{turns: 0, tokens: 0}, s}
        end

      _ ->
        {:reply, %{turns: 0, tokens: 0}, s}
    end
  end

  def handle_call({:archive, sid, generation}, _, s) do
    case s.data.sessions[sid] do
      nil ->
        {:reply, {:error, :unknown_session}, s}

      chat ->
        states =
          Enum.map(chat.bots, &Nano.StateStore.get("bot-#{&1}-#{sid}-#{generation}"))
          |> Enum.reject(&is_nil/1)

        result =
          if states != [],
            do: persist(checkpoint_path(s.path, sid, generation), states),
            else: :ok

        {:reply, result, s}
    end
  end

  def handle_call({:history, sid, opts}, _, s) do
    case s.data.sessions[sid] do
      nil ->
        {:reply, {:error, :unknown_session}, s}

      chat ->
        offset = max(0, opts[:offset] || 0)
        limit = min(50, max(1, opts[:limit] || 20))
        budget = min(12_000, max(1000, opts[:max_bytes] || 6000))
        per_message = min(budget, max(256, opts[:message_bytes] || 1000))

        {messages, _} =
          chat.messages
          |> Enum.slice(offset, limit)
          |> Enum.reduce_while({[], budget - 100}, fn m, {acc, left} ->
            fragment =
              text_page(
                m.text,
                0,
                min(
                  per_message,
                  max(256, left - byte_size(Jason.encode!(Map.delete(m, :text))) - 160)
                )
              )

            entry =
              Map.merge(m, %{
                text: fragment.text,
                text_bytes: fragment.total_bytes,
                next_byte: fragment.next_offset,
                truncated: fragment.next_offset != nil
              })

            cost = byte_size(Jason.encode!(entry))

            if cost <= left,
              do: {:cont, {acc ++ [entry], left - cost}},
              else: {:halt, {acc, left}}
          end)

        next = offset + length(messages)

        {:reply,
         {:ok,
          %{
            messages: messages,
            total: length(chat.messages),
            next_offset: if(next < length(chat.messages), do: next, else: nil)
          }}, s}
    end
  end

  def handle_call({:message, sid, index, opts}, _, s) do
    with %{messages: messages} <- s.data.sessions[sid],
         true <- is_integer(index) and index >= 0,
         m when not is_nil(m) <- Enum.at(messages, index) do
      {:reply, {:ok, text_page(m.text, opts[:offset] || 0, opts[:max_bytes] || 6000)}, s}
    else
      _ -> {:reply, {:error, :unknown_message}, s}
    end
  end

  def handle_call({:checkpoint, sid, generation, opts}, _, s) do
    if Map.has_key?(s.data.sessions, sid) and is_integer(generation) and generation >= 0 do
      path = checkpoint_path(s.path, sid, generation)

      result =
        with {:ok, bytes} <- File.read(path) do
          text =
            inspect(
              Enum.map(
                :erlang.binary_to_term(bytes, [:safe]),
                &Map.take(&1, [:name, :transcript, :pending])
              ),
              limit: :infinity,
              printable_limit: :infinity
            )

          offset = max(0, opts[:offset] || 0)
          limit = min(12_000, max(1, opts[:limit] || 6000))

          {:ok, text_page(text, offset, limit)}
        end

      {:reply, result, s}
    else
      {:reply, {:error, :invalid_checkpoint}, s}
    end
  end

  def handle_call(:snapshot, _, s), do: {:reply, s.data, s}

  def handle_call({:bot, name, opts}, _, s) do
    if valid?(name) and byte_size(name) <= 80 do
      bot = %{
        id: id(),
        name: String.trim(name),
        description: opts[:description] || "A thoughtful, helpful companion.",
        color: Enum.at(~w(#a7c7e7 #cdb4db #b7d8ba #f4c7ab), rem(map_size(s.data.bots), 4)),
        shape: rem(map_size(s.data.bots), 3),
        agent_options: safe_agent_options(opts[:agent_options] || []),
        memories: [],
        created_at: now()
      }

      commit(s, put_in(s.data, [:bots, bot.id], bot), {:ok, bot})
    else
      {:reply, {:error, :invalid_name}, s}
    end
  end

  def handle_call({:configure, bid, opts}, _, s) do
    case s.data.bots[bid] do
      nil ->
        {:reply, {:error, :unknown_bot}, s}

      bot ->
        bot = Map.put(bot, :agent_options, safe_agent_options(opts[:agent_options] || []))
        commit(s, put_in(s.data, [:bots, bid], bot), :ok)
    end
  end

  def handle_call({:session, ids, opts}, _, s) do
    ids = Enum.uniq(ids)

    if ids != [] and Enum.all?(ids, &Map.has_key?(s.data.bots, &1)) do
      chat = %{
        id: id(),
        bots: ids,
        title: opts[:title] || Enum.map_join(ids, ", ", &s.data.bots[&1].name),
        messages: [],
        brief: "",
        generation: 0,
        context_bytes: 0,
        updated_at: now(),
        status: %{}
      }

      commit(s, put_in(s.data, [:sessions, chat.id], chat), {:ok, chat})
    else
      {:reply, {:error, :invalid_participants}, s}
    end
  end

  def handle_call({:say, sid, text}, _, s) do
    with true <- valid?(text), %{} = chat <- s.data.sessions[sid] do
      chat = append(chat, :human, text) |> compact(nil)
      data = put_in(s.data, [:sessions, sid], chat)

      case persist(s.path, data) do
        :ok ->
          broadcast(%{session: sid})
          s = %{s | data: data, group_budget: Map.put(s.group_budget, sid, 2)}
          {:reply, :ok, enqueue(s, sid, text)}

        e ->
          {:reply, e, s}
      end
    else
      _ -> {:reply, {:error, :invalid_message_or_session}, s}
    end
  end

  def handle_call({:post, sid, bid, text, actor}, _, s) do
    with true <- valid?(text),
         %{bots: bots} = chat <- s.data.sessions[sid],
         true <- bid in bots,
         true <- current_actor?(actor, bid, sid, chat.generation) do
      chat = append(chat, bid, text) |> put_in([:status, bid], :idle)

      commit(s, put_in(s.data, [:sessions, sid], chat), :ok, %{session: sid, bot: bid, text: text})
    else
      _ -> {:reply, {:error, :invalid_message_or_participant}, s}
    end
  end

  def handle_call({:memory, bid, text}, _, s) do
    with true <- valid?(text), %{} = bot <- s.data.bots[bid] do
      bot = %{bot | memories: Enum.take([%{text: text, at: now()} | bot.memories], 200)}
      commit(s, put_in(s.data, [:bots, bid], bot), :ok)
    else
      _ -> {:reply, {:error, :invalid_memory}, s}
    end
  end

  def handle_call({:ask, bid, question, opts}, _, s) do
    latest =
      s.data.sessions
      |> Map.values()
      |> Enum.filter(&(bid in &1.bots))
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> List.first()

    sid = opts[:session] || (latest && latest.id)

    with true <- valid?(question),
         %{bots: bots} = chat <- s.data.sessions[sid],
         true <- bid in bots,
         true <- current_actor?(opts[:actor], bid, sid, chat.generation) do
      req = %{
        id: id(),
        bot: bid,
        session: sid,
        question: question,
        reply_to: opts[:reply_to],
        status: :pending,
        created_at: now()
      }

      data =
        s.data
        |> put_in([:sessions, sid], append(chat, bid, question, req.id))
        |> put_in([:requests, req.id], req)

      commit(s, data, {:ok, req.id}, %{session: sid, bot: bid, text: question, request: req.id})
    else
      _ -> {:reply, {:error, :no_matching_session}, s}
    end
  end

  def handle_call({:answer, rid, text}, _, s) do
    with true <- valid?(text), %{status: :pending} = req <- s.data.requests[rid] do
      data =
        s.data
        |> put_in([:requests, rid, :status], :answered)
        |> put_in([:requests, rid, :answer], text)
        |> update_in([:sessions, req.session], &append(&1, :human, text, rid))

      case persist(s.path, data) do
        :ok ->
          deliver_answer(req.reply_to, rid, text)
          broadcast(%{session: req.session})
          {:reply, :ok, %{s | data: data}}

        e ->
          {:reply, e, s}
      end
    else
      _ -> {:reply, {:error, :invalid_or_answered_request}, s}
    end
  end

  def handle_call({:notifications, enabled}, _, s) when is_boolean(enabled),
    do: commit(s, %{s.data | notifications: enabled}, :ok)

  def handle_call(_, _, s), do: {:reply, {:error, :unknown_call}, s}
  @impl true
  def handle_info(:monitor, s) do
    Process.send_after(self(), :monitor, 500)
    {:noreply, monitor(s)}
  end

  def handle_info({:nano_log, %{type: type}}, s)
      when type in [:response, :tool_result, :turn_ended, :halted] do
    {:noreply, monitor(s)}
  end

  def handle_info({:paused_for_compaction, sid, generation, worker, transcript, _active}, s) do
    chat = s.data.sessions[sid]

    if chat.generation == generation do
      brief =
        Nano.Bots.Context.tail(
          chat.brief <> "\nRuntime continuation (untrusted):\n" <> transcript,
          12_000
        )

      chat = compact(%{chat | brief: brief, context_bytes: 24_001}, nil)
      data = put_in(s.data, [:sessions, sid], chat)

      case persist(s.path, data) do
        :ok ->
          send(worker, :proceed)
          broadcast(%{session: sid})
          {:noreply, %{s | data: data}}

        _ ->
          send(worker, :abort)
          {:noreply, %{s | compacting: MapSet.delete(s.compacting, sid)}}
      end
    else
      send(worker, :abort)
      {:noreply, %{s | compacting: MapSet.delete(s.compacting, sid)}}
    end
  end

  def handle_info({:compaction_finished, sid, active}, s) do
    s = %{s | compacting: MapSet.delete(s.compacting, sid)}

    text =
      "Resume the unfinished work using the session brief and recent conversation. Do not repeat an already posted answer. If nothing is pending, idle."

    {:noreply, if(active, do: enqueue(s, sid, text), else: s)}
  end

  def handle_info({:compaction_aborted, sid}, s),
    do: {:noreply, %{s | compacting: MapSet.delete(s.compacting, sid)}}

  def handle_info({:prepared, sid, generation, prepared, text}, s) do
    current = s.data.sessions[sid]

    chat =
      if current.generation == generation and
           (prepared.generation == generation or rotation_safe?(current)) do
        %{
          current
          | generation: prepared.generation,
            brief: prepared.brief,
            context_bytes:
              if(prepared.generation != generation, do: 0, else: current.context_bytes)
        }
      else
        current
      end

    data = put_in(s.data, [:sessions, sid], chat)

    case persist(s.path, data) do
      :ok ->
        for bid <- chat.bots, do: send(self(), {:deliver, sid, bid, text})
        s = %{s | data: data, preparing: MapSet.delete(s.preparing, sid)}
        {:noreply, start_preparation(s, sid)}

      _ ->
        {:noreply, %{s | preparing: MapSet.delete(s.preparing, sid)}}
    end
  end

  def handle_info({:deliver, sid, bid, text}, s) do
    parent = self()
    bot = Map.put(s.data.bots[bid], :server, s.server)
    chat = s.data.sessions[sid]

    spawn(fn ->
      result =
        try do
          s.runner.(bot, chat, text, relevant(bot.memories, text, s.decision))
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(parent, {:delivery_result, sid, bid, chat.generation, result})
    end)

    data = put_in(s.data, [:sessions, sid, :status, bid], :thinking)
    broadcast(%{session: sid})
    {:noreply, %{s | data: data}}
  end

  def handle_info({:delivery_result, sid, bid, generation, result}, s) do
    if s.data.sessions[sid].generation != generation or
         s.data.sessions[sid].status[bid] != :thinking do
      {:noreply, s}
    else
      status =
        case result do
          {:ok, _} -> :thinking
          :ok -> :thinking
          _ -> :unavailable
        end

      data = put_in(s.data, [:sessions, sid, :status, bid], status)
      persist(s.path, data)
      broadcast(%{session: sid})
      {:noreply, %{s | data: data}}
    end
  end

  def handle_info({:route_group, sid, source, text}, s) do
    chat = s.data.sessions[sid]

    if Map.get(s.group_budget, sid, 0) > 0 and length(chat.bots) > 1 do
      parent = self()

      for bid <- chat.bots -- [source] do
        bot = s.data.bots[bid]

        spawn(fn ->
          respond =
            decide(
              s.decision,
              :respond,
              %{
                bot: Map.take(bot, [:name, :description]),
                source: s.data.bots[source].name,
                message: text,
                recent: Enum.take(chat.messages, -6)
              },
              false
            )

          send(parent, {:group_decision, sid, bid, source, text, chat.generation, respond})
        end)
      end
    end

    {:noreply, s}
  end

  def handle_info({:group_decision, sid, bid, source, text, generation, true}, s) do
    if Map.get(s.group_budget, sid, 0) > 0 and s.data.sessions[sid].generation == generation do
      send(self(), {:deliver, sid, bid, "Peer bot #{s.data.bots[source].name} said: #{text}"})
      {:noreply, %{s | group_budget: Map.update!(s.group_budget, sid, &(&1 - 1))}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp reconcile_status(s, sid, bid, name) do
    case Nano.StateStore.get(name) do
      %{status: :idle, task: nil, calls: [], pending: [], turns_used: turns, halted: halted}
      when turns > 0 ->
        current = s.data.sessions[sid].status[bid]

        status =
          cond do
            halted != nil -> :paused
            current == :thinking -> :no_reply
            true -> current
          end

        if status != current do
          data = put_in(s.data, [:sessions, sid, :status, bid], status)
          persist(s.path, data)
          broadcast(%{session: sid})
          %{s | data: data}
        else
          s
        end

      _ ->
        s
    end
  end

  defp monitor(s) do
    Enum.reduce(s.data.sessions, s, fn {sid, chat}, s ->
      s =
        Enum.reduce(chat.bots, s, fn bid, s ->
          name = "bot-#{bid}-#{sid}-#{chat.generation}"
          s = reconcile_status(s, sid, bid, name)

          case NanoAgent.info(name) do
            %{id: id} ->
              if MapSet.member?(s.subscriptions, id) do
                s
              else
                Nano.Log.subscribe(id)
                %{s | subscriptions: MapSet.put(s.subscriptions, id)}
              end

            _ ->
              s
          end
        end)

      if runtime_needs_compaction?(chat) and not MapSet.member?(s.compacting, sid) and
           not MapSet.member?(s.preparing, sid) do
        parent = self()
        spawn(fn -> pause_for_compaction(parent, chat, s.path) end)
        %{s | compacting: MapSet.put(s.compacting, sid)}
      else
        s
      end
    end)
  end

  defp pause_for_compaction(parent, chat, path) do
    names = Enum.map(chat.bots, &"bot-#{&1}-#{chat.id}-#{chat.generation}")

    paused =
      Enum.reduce(names, [], fn name, acc ->
        case NanoAgent.whereis(name) do
          nil ->
            acc

          pid ->
            try do
              :ok = :sys.suspend(pid, :infinity)
              [{name, pid} | acc]
            catch
              _, _ -> acc
            end
        end
      end)

    try do
      states = Enum.map(paused, fn {name, _} -> Nano.StateStore.get(name) end)

      safe =
        Enum.all?(states, fn state ->
          state && state.halted in [nil, :context] &&
            state.status == :idle && state.task == nil && state.calls == []
        end)

      if safe and paused != [] do
        checkpoint = checkpoint_path(path, chat.id, chat.generation)
        :ok = persist(checkpoint, states)

        transcript =
          states
          |> Enum.map(&Map.take(&1, [:name, :transcript, :pending]))
          |> inspect(limit: :infinity, printable_limit: :infinity)
          |> Nano.Bots.Context.tail(12_000)

        active = Enum.any?(states, &(&1.status != :idle or &1.halted == :context))

        send(
          parent,
          {:paused_for_compaction, chat.id, chat.generation, self(), transcript, active}
        )

        proceed =
          receive do
            :proceed -> true
            :abort -> false
          after
            5000 -> false
          end

        if proceed do
          Enum.each(paused, fn {name, _} -> Nano.Ops.stop_agent(name) end)
          send(parent, {:compaction_finished, chat.id, active})
        else
          resume_paused(paused)
          send(parent, {:compaction_aborted, chat.id})
        end
      else
        resume_paused(paused)
        send(parent, {:compaction_aborted, chat.id})
      end
    after
      resume_paused(paused)
    end
  rescue
    _ -> send(parent, {:compaction_aborted, chat.id})
  end

  defp resume_paused(paused) do
    Enum.each(paused, fn {_, pid} ->
      try do
        :sys.resume(pid, :infinity)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp enqueue(s, sid, text) do
    queue = Map.get(s.work_queues, sid, []) ++ [text]
    start_preparation(%{s | work_queues: Map.put(s.work_queues, sid, queue)}, sid)
  end

  defp start_preparation(s, sid) do
    case {MapSet.member?(s.preparing, sid), Map.get(s.work_queues, sid, [])} do
      {false, [text | rest]} ->
        parent = self()
        chat = s.data.sessions[sid]

        spawn(fn ->
          prepared = compact(chat, s.decision)
          # Hard rollover already installed an excerpt. Upgrade it semantically in
          # this worker before dispatch, never blocking the state owner/UI.
          prepared =
            if chat.generation > 0 and chat.context_bytes == 0 do
              recent =
                Enum.take(chat.messages, -20) |> Enum.map_join("\n", &"#{&1.who}: #{&1.text}")

              brief = decide(s.decision, :summary, %{previous: chat.brief, recent: recent}, nil)

              if is_binary(brief) and byte_size(brief) <= 12_000,
                do: %{prepared | brief: brief},
                else: prepared
            else
              prepared
            end

          send(parent, {:prepared, sid, chat.generation, prepared, text})
        end)

        %{
          s
          | work_queues: Map.put(s.work_queues, sid, rest),
            preparing: MapSet.put(s.preparing, sid)
        }

      _ ->
        s
    end
  end

  defp deliver_answer(pid, rid, text) when is_pid(pid),
    do: send(pid, {:nano_human_answer, rid, text})

  defp deliver_answer(name, rid, text) when is_binary(name),
    do: NanoAgent.notify(name, {:nano_human_answer, rid, text})

  defp deliver_answer(_, _, _), do: :ok

  defp append(chat, who, text, request \\ nil),
    do: %{
      chat
      | messages:
          chat.messages ++ [%{id: id(), who: who, text: text, request: request, at: now()}],
        context_bytes: chat.context_bytes + byte_size(text),
        updated_at: now()
    }

  @doc "Bounded memory selection; optional typed cheap-model callback receives :memories and state."
  def relevant(memories, query, decision) do
    chosen = decide(decision, :memories, %{memories: memories, query: query}, nil)

    if is_list(chosen) and Enum.all?(chosen, &(&1 in memories)) do
      Enum.take(chosen, 6)
    else
      words =
        query
        |> String.downcase()
        |> String.split(~r/\W+/u, trim: true)
        |> Enum.filter(&(String.length(&1) > 3))

      memories
      |> Enum.filter(fn m -> Enum.any?(words, &String.contains?(String.downcase(m.text), &1)) end)
      |> Enum.take(6)
    end
  end

  defp compact(chat, decision) do
    if rotation_safe?(chat) and
         (chat.context_bytes > 24_000 or runtime_needs_compaction?(chat) or
            decide(
              decision,
              :compact,
              %{
                bytes: chat.context_bytes,
                context: runtime_context(chat),
                recent: Enum.take(chat.messages, -8),
                brief: chat.brief
              },
              false
            ) == true) do
      recent = chat.messages |> Enum.take(-20) |> Enum.map_join("\n", &"#{&1.who}: #{&1.text}")
      brief = decide(decision, :summary, %{previous: chat.brief, recent: recent}, nil)

      brief =
        if is_binary(brief) and byte_size(brief) <= 12_000,
          do: brief,
          else:
            Nano.Bots.Context.clip(
              Nano.Bots.Context.tail(chat.brief <> "\n" <> recent, 12_000),
              12_000
            )

      %{chat | generation: chat.generation + 1, context_bytes: 0, brief: brief}
    else
      chat
    end
  end

  defp rotation_safe?(chat) do
    Enum.all?(chat.bots, fn bid ->
      case Nano.StateStore.get("bot-#{bid}-#{chat.id}-#{chat.generation}") do
        nil ->
          true

        %{status: status, halted: halted} = state ->
          halted in [nil, :context] and status == :idle and state.task == nil and
            state.calls == []

        _ ->
          false
      end
    end)
  end

  defp runtime_context(chat) do
    Enum.map(chat.bots, fn bid ->
      case NanoAgent.info("bot-#{bid}-#{chat.id}-#{chat.generation}") do
        %{budget: budget} -> Map.take(budget, [:max_context, :context_used])
        _ -> %{max_context: nil, context_used: nil}
      end
    end)
  end

  defp runtime_needs_compaction?(chat) do
    Enum.any?(chat.bots, fn bid ->
      name = "bot-#{bid}-#{chat.id}-#{chat.generation}"

      case Nano.StateStore.get(name) do
        %{max_context: limit, context_used: used, transcript: transcript} ->
          limit > 0 and max(used, :erlang.external_size(transcript)) > limit * 0.55

        _ ->
          false
      end
    end)
  end

  defp decide(nil, _, _, fallback), do: fallback

  defp decide(fun, task, state, fallback) do
    case fun.(task, state) do
      {:ok, %{value: value, probability: probability, confidence: confidence}}
      when probability >= 0.6 and confidence >= 0.6 ->
        value

      {:ok, %{value: _}} ->
        fallback

      {:ok, result} ->
        result

      _ ->
        fallback
    end
  rescue
    _ -> fallback
  end

  defp commit(s, data, reply, event \\ %{}) do
    case persist(s.path, data) do
      :ok ->
        notify? =
          data.notifications and Map.has_key?(event, :text) and
            now() - s.last_notification > 60_000

        broadcast(Map.put(event, :notify, notify?))

        if event[:bot] && event[:bot] != :human && event[:text] && !event[:request],
          do: send(self(), {:route_group, event.session, event.bot, event.text})

        {:reply, reply,
         %{s | data: data, last_notification: if(notify?, do: now(), else: s.last_notification)}}

      e ->
        {:reply, e, s}
    end
  end

  # Offsets are UTF-8 byte boundaries returned by the preceding page. The
  # encoded text as well as raw bytes is bounded (controls can expand sixfold).
  defp text_page(text, offset, requested) do
    cap = min(12_000, max(256, requested))
    offset = min(byte_size(text), max(0, offset))
    rest = binary_part(text, offset, byte_size(text) - offset)

    if String.valid?(rest) do
      fragment = fit_encoded(Nano.Bots.Context.clip(rest, cap), cap)
      next = offset + byte_size(fragment)

      %{
        text: fragment,
        total_bytes: byte_size(text),
        next_offset: if(next < byte_size(text), do: next, else: nil)
      }
    else
      %{text: "", total_bytes: byte_size(text), next_offset: offset, error: :invalid_utf8_offset}
    end
  end

  defp fit_encoded(text, cap) do
    if byte_size(Jason.encode!(text)) <= max(2, cap),
      do: text,
      else:
        fit_encoded(
          Nano.Bots.Context.clip(text, max(0, byte_size(text) - max(1, div(byte_size(text), 4)))),
          cap
        )
  end

  defp checkpoint_path(path, sid, generation),
    do: Path.join(Path.dirname(path), "checkpoints/#{sid}-#{generation}.term")

  defp persist(path, data) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", :erlang.term_to_binary(data)),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end

  defp broadcast(event) do
    if Process.whereis(Nano.PubSub),
      do: Phoenix.PubSub.broadcast(Nano.PubSub, "nano:bots", {:bots_changed, event})
  end
end
