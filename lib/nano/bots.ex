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

  def snapshot(server \\ __MODULE__), do: call(server, :snapshot)
  def create_bot(name, opts \\ []), do: call(opts[:server] || __MODULE__, {:bot, name, opts})

  def create_session(ids, opts \\ []),
    do: call(opts[:server] || __MODULE__, {:session, ids, opts})

  def say(sid, text, server \\ __MODULE__), do: call(server, {:say, sid, text})
  def post(sid, bid, text, server \\ __MODULE__), do: call(server, {:post, sid, bid, text})
  def remember(bid, text, opts \\ []), do: call(opts[:server] || __MODULE__, {:memory, bid, text})

  def ask_human(bid, question, opts \\ []),
    do:
      call(
        opts[:server] || __MODULE__,
        {:ask, bid, question, Keyword.put_new(opts, :reply_to, self())}
      )

  def answer(rid, text, server \\ __MODULE__), do: call(server, {:answer, rid, text})

  def set_notifications(enabled, server \\ __MODULE__),
    do: call(server, {:notifications, enabled})

  defp call(server, msg) do
    if server == __MODULE__, do: ensure_started()
    GenServer.call(server, msg, 30_000)
  end

  defp id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
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

    {:ok,
     %{
       data: data,
       path: path,
       runner: opts[:runner] || (&Nano.Bots.Runtime.deliver/4),
       decision: opts[:decision] || (&Nano.Bots.Decision.decide/2),
       last_notification: 0
     }}
  end

  @impl true
  def handle_call(:snapshot, _, s), do: {:reply, s.data, s}

  def handle_call({:bot, name, opts}, _, s) do
    if valid?(name) and byte_size(name) <= 80 do
      bot = %{
        id: id(),
        name: String.trim(name),
        description: opts[:description] || "A thoughtful, helpful companion.",
        color: Enum.at(~w(#a7c7e7 #cdb4db #b7d8ba #f4c7ab), rem(map_size(s.data.bots), 4)),
        shape: rem(map_size(s.data.bots), 3),
        memories: [],
        created_at: now()
      }

      commit(s, put_in(s.data, [:bots, bot.id], bot), {:ok, bot})
    else
      {:reply, {:error, :invalid_name}, s}
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
      chat = append(chat, :human, text) |> compact(s.decision)
      data = put_in(s.data, [:sessions, sid], chat)

      case persist(s.path, data) do
        :ok ->
          for bid <- chat.bots, do: send(self(), {:deliver, sid, bid, text})
          broadcast(%{session: sid})
          {:reply, :ok, %{s | data: data}}

        e ->
          {:reply, e, s}
      end
    else
      _ -> {:reply, {:error, :invalid_message_or_session}, s}
    end
  end

  def handle_call({:post, sid, bid, text}, _, s) do
    with true <- valid?(text),
         %{bots: bots} = chat <- s.data.sessions[sid],
         true <- bid in bots do
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
         true <- bid in bots do
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
  def handle_info({:deliver, sid, bid, text}, s) do
    parent = self()
    bot = s.data.bots[bid]
    chat = s.data.sessions[sid]

    spawn(fn ->
      result =
        try do
          s.runner.(bot, chat, text, relevant(bot.memories, text, s.decision))
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(parent, {:delivery_result, sid, bid, result})
    end)

    data = put_in(s.data, [:sessions, sid, :status, bid], :thinking)
    broadcast(%{session: sid})
    {:noreply, %{s | data: data}}
  end

  def handle_info({:delivery_result, sid, bid, result}, s) do
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

  def handle_info(_, s), do: {:noreply, s}

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
    if chat.context_bytes > 24_000 or runtime_needs_compaction?(chat) or
         decide(decision, :compact, %{bytes: chat.context_bytes}, false) == true do
      recent = chat.messages |> Enum.take(-20) |> Enum.map_join("\n", &"#{&1.who}: #{&1.text}")
      brief = decide(decision, :summary, %{previous: chat.brief, recent: recent}, nil)

      brief =
        if is_binary(brief) and byte_size(brief) <= 12_000,
          do: brief,
          else: String.slice(chat.brief <> "\n" <> recent, -12_000, 12_000)

      %{chat | generation: chat.generation + 1, context_bytes: 0, brief: brief}
    else
      chat
    end
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
      {:ok, result} -> result
      _ -> fallback
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

        {:reply, reply,
         %{s | data: data, last_notification: if(notify?, do: now(), else: s.last_notification)}}

      e ->
        {:reply, e, s}
    end
  end

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
