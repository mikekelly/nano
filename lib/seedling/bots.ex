defmodule Seedling.Bots do
  @moduledoc """
  Durable consumer identities, isolated sessions and a human-request channel.
  `create_bot/2`, `create_session/1`, `say/2`, `post/3`, `remember/3`.
  Agents must explicitly publish with `post`; harness/tool output never enters chat.
  `request_human/3` returns an id; `answer/2` delivers {:human_answer, id, text}
  to the requesting pid. Persisted answers remain available via `snapshot/0` after restart.
  Single trusted-node household, like the operator dashboard; not multi-tenant auth.
  """
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  defp server do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  def snapshot, do: GenServer.call(server(), :snapshot)

  def create_bot(name, description \\ "A thoughtful, helpful companion", opts \\ []),
    do: call({:bot, name, description, opts})

  def create_session(ids), do: call({:session, ids})

  def post(session, bot, text) do
    result = call({:post, session, bot, text})

    if bot != "human" and match?({:ok, _}, result) do
      {:ok, message} = result
      chat = snapshot().sessions[session]

      for peer <- chat.bots, peer != bot do
        if pid = NanoAgent.whereis("bot-" <> peer <> "-" <> session) do
          send(pid, %{
            chat: session,
            observation: true,
            text: message.text,
            author: bot,
            instruction:
              "Shared conversation update. Observe; do not reply unless the person asks you."
          })
        end
      end
    end

    result
  end

  def remember(bot, text, tags \\ []), do: call({:remember, bot, text, tags})
  def memories(bot, query), do: call({:memories, bot, query})

  def request_human(bot, question, opts \\ []) do
    call(
      {:request, bot, question, opts[:session],
       opts[:reply_to] || List.first(Process.get(:"$callers", [])) || self()}
    )
  end

  def answer(id, text), do: call({:answer, id, text})
  defp call(msg), do: GenServer.call(server(), msg)
  def subscribe, do: Phoenix.PubSub.subscribe(Nano.PubSub, "seedling:bots")

  def say(session, text), do: call({:say, session, text})
  def delivered(session, message, bot), do: call({:delivered, session, message, bot})

  def init(opts) do
    path = opts[:path] || Path.join(Application.fetch_env!(:nano, :state_dir), "bots.json")

    data =
      case File.read(path) do
        {:ok, json} -> decode(Jason.decode!(json))
        _ -> %{bots: %{}, sessions: %{}, requests: %{}, memories: %{}}
      end

    # IDs are dynamic map keys: keep them strings; atom decoding is only used for fixed fields.
    data =
      case File.read(path) do
        {:ok, json} -> decode(Jason.decode!(json))
        _ -> data
      end

    Process.send_after(self(), :retry_answers, 1000)
    send(self(), :restore_dispatch)
    {:ok, %{path: path, data: data, waiters: %{}, queues: %{}}}
  end

  defp decode(raw) do
    for key <- [:bots, :sessions, :requests, :memories], into: %{} do
      value = raw[Atom.to_string(key)] || %{}
      {key, Map.new(value, fn {id, v} -> {id, fields(v)} end)}
    end
  end

  defp fields(v) when is_list(v), do: Enum.map(v, &fields/1)

  defp fields(v) when is_map(v),
    do: Map.new(v, fn {k, v} -> {String.to_existing_atom(k), fields(v)} end)

  defp fields(v), do: v
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  defp now, do: System.system_time(:millisecond)
  def handle_call(:snapshot, _, s), do: {:reply, s.data, s}

  def handle_call({:bot, name, description, opts}, _, s) do
    if valid?(name, 80) and valid?(description, 2000) and
         (is_nil(opts[:model]) or valid?(opts[:model], 200)) and
         (is_nil(opts[:max_context]) or
            (is_integer(opts[:max_context]) and opts[:max_context] >= 2048)) do
      bot = %{
        id: id(),
        name: String.trim(name),
        description: description,
        model: opts[:model],
        max_context: opts[:max_context],
        color: Enum.random(~w(#bc8ce2 #74bbaa #e5ad70 #81abe0)),
        face: Enum.random(~w(● ◆ ✦)),
        created: now()
      }

      save(s, put_in(s.data, [:bots, bot.id], bot), {:ok, bot})
    else
      {:reply, {:error, :invalid_identity}, s}
    end
  end

  def handle_call({:session, ids}, _, s) do
    ids = Enum.uniq(ids)

    if ids != [] and Enum.all?(ids, &Map.has_key?(s.data.bots, &1)) do
      session = %{
        id: id(),
        bots: ids,
        title: Enum.map_join(ids, ", ", &s.data.bots[&1].name),
        messages: [],
        updated: now()
      }

      save(s, put_in(s.data, [:sessions, session.id], session), {:ok, session})
    else
      {:reply, {:error, :unknown_bot}, s}
    end
  end

  def handle_call({:say, sid, text}, _, s), do: append_message(s, sid, "human", text, true)
  def handle_call({:post, sid, bot, text}, _, s), do: append_message(s, sid, bot, text, false)

  def handle_call({:delivered, sid, mid, bot}, _, s) do
    session = s.data.sessions[sid]

    messages =
      Enum.map(session.messages, fn m ->
        if m.id == mid,
          do: Map.put(m, :pending, List.delete(Map.get(m, :pending, []), bot)),
          else: m
      end)

    save(s, put_in(s.data, [:sessions, sid, :messages], messages), :ok)
  end

  def handle_call({:remember, bot, text, tags}, _, s) do
    if s.data.bots[bot] && valid?(text, 4000) && is_list(tags) && Enum.all?(tags, &is_binary/1) do
      memory = %{id: id(), text: text, tags: tags, created: now()}

      data =
        put_in(s.data, [:memories, bot], Enum.take([memory | s.data.memories[bot] || []], 500))

      save(s, data, {:ok, memory})
    else
      {:reply, {:error, :invalid_memory}, s}
    end
  end

  def handle_call({:memories, bot, query}, _, s) do
    words = String.downcase(query) |> String.split(~r/\W+/, trim: true) |> MapSet.new()

    found =
      (s.data.memories[bot] || [])
      |> Enum.map(fn m ->
        score =
          String.downcase(m.text <> " " <> Enum.join(m.tags, " "))
          |> String.split(~r/\W+/, trim: true)
          |> MapSet.new()
          |> MapSet.intersection(words)
          |> MapSet.size()

        {score, m}
      end)
      |> Enum.filter(fn {score, _} -> score > 0 end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(5)
      |> Enum.map(&elem(&1, 1))

    {:reply, found, s}
  end

  def handle_call({:request, bot, question, sid, pid}, _, s) do
    session =
      if sid,
        do: s.data.sessions[sid],
        else:
          s.data.sessions
          |> Map.values()
          |> Enum.filter(&(bot in &1.bots))
          |> Enum.max_by(& &1.updated, fn -> nil end)

    if session && bot in session.bots && valid?(question, 4000) &&
         (is_pid(pid) or (is_binary(pid) and valid?(pid, 200))) do
      request = %{
        id: id(),
        bot: bot,
        session: session.id,
        question: question,
        status: "pending",
        answer: nil,
        reply_to: requester_name(pid),
        delivered: false,
        created: now()
      }

      s = %{s | waiters: Map.put(s.waiters, request.id, pid)}
      msg = %{id: id(), author: bot, text: question, request: request.id, created: now()}

      data =
        s.data
        |> put_in([:requests, request.id], request)
        |> put_in([:sessions, session.id, :messages], session.messages ++ [msg])

      save(s, data, {:ok, request.id})
    else
      {:reply, {:error, :no_session}, s}
    end
  end

  def handle_call({:answer, rid, text}, _, s) do
    r = s.data.requests[rid]

    if r && r.status == "pending" && valid?(text, 8000) do
      data = put_in(s.data, [:requests, rid], %{r | status: "answered", answer: text})

      case persist(s.path, data) do
        :ok ->
          send(self(), :deliver_answers)
          broadcast()
          {:reply, :ok, %{s | data: data}}

        error ->
          {:reply, error, s}
      end
    else
      {:reply, {:error, :invalid_request}, s}
    end
  end

  defp enqueue(s, session, message) do
    pid = Seedling.Bots.Queue.enqueue(session, message)
    queues = Map.get(s, :queues, %{})

    queues =
      if Map.has_key?(queues, session.id),
        do: queues,
        else: Map.put(queues, session.id, Process.monitor(pid))

    Map.put(s, :queues, queues)
  end

  def handle_info(:restore_dispatch, s) do
    s =
      Enum.reduce(s.data.sessions, s, fn {_, session}, s ->
        Enum.reduce(session.messages, s, fn msg, s ->
          if Map.get(msg, :pending, []) != [], do: enqueue(s, session, msg), else: s
        end)
      end)

    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    queues = Map.get(s, :queues, %{})
    sid = Enum.find_value(queues, fn {id, r} -> if r == ref, do: id end)
    s = Map.put(s, :queues, Map.delete(queues, sid))

    s =
      if sid do
        session = s.data.sessions[sid]

        Enum.reduce(session.messages, s, fn msg, s ->
          if Map.get(msg, :pending, []) != [], do: enqueue(s, session, msg), else: s
        end)
      else
        s
      end

    {:noreply, s}
  end

  def handle_info(:retry_answers, s) do
    Process.send_after(self(), :retry_answers, 5000)
    handle_info(:deliver_answers, s)
  end

  def handle_info(:deliver_answers, s) do
    {data, waiters} =
      Enum.reduce(s.data.requests, {s.data, s.waiters}, fn {id, r}, {data, waiters} ->
        name = Map.get(r, :reply_to)
        target = if name, do: NanoAgent.whereis(name), else: waiters[id]
        replay? = is_binary(name) and is_pid(target) and target != waiters[id]

        if r.status == "answered" and (not Map.get(r, :delivered, false) or replay?) do
          if is_pid(target) and Process.alive?(target) do
            send(target, {:human_answer, id, r.answer})

            {put_in(data, [:requests, id], Map.put(r, :delivered, true)),
             if(name, do: Map.put(waiters, id, target), else: Map.delete(waiters, id))}
          else
            {data, waiters}
          end
        else
          {data, waiters}
        end
      end)

    if data != s.data or waiters != s.waiters do
      case persist(s.path, data) do
        :ok -> {:noreply, %{s | data: data, waiters: waiters}}
        _ -> {:noreply, s}
      end
    else
      {:noreply, s}
    end
  end

  defp append_message(s, sid, bot, text, dispatch?) do
    session = s.data.sessions[sid]

    if session && (bot == "human" or bot in session.bots) && valid?(text, 32000) do
      msg = %{
        id: id(),
        author: bot,
        text: text,
        created: now(),
        pending: if(dispatch?, do: session.bots, else: [])
      }

      session = %{session | messages: session.messages ++ [msg], updated: now()}

      case save(s, put_in(s.data, [:sessions, sid], session), {:ok, msg}) do
        {:reply, {:ok, _} = result, updated} ->
          updated = if dispatch?, do: enqueue(updated, session, msg), else: updated
          {:reply, result, updated}

        other ->
          other
      end
    else
      {:reply, {:error, :invalid_message}, s}
    end
  end

  defp requester_name(name) when is_binary(name), do: name

  defp requester_name(pid) do
    Enum.find_value(Nano.Names.all(), fn
      {{:agent, name}, ^pid} -> name
      _ -> nil
    end)
  end

  defp valid?(v, max), do: is_binary(v) and String.trim(v) != "" and byte_size(v) <= max

  defp save(s, data, result) do
    case persist(s.path, data) do
      :ok ->
        broadcast()
        {:reply, result, %{s | data: data}}

      error ->
        {:reply, error, s}
    end
  end

  defp persist(path, data) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", Jason.encode!(data)),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end

  defp broadcast, do: Phoenix.PubSub.broadcast(Nano.PubSub, "seedling:bots", :bots_updated)
end
