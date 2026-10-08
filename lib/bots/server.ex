defmodule Bots.Server do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      opts,
      if(Keyword.get(opts, :name, __MODULE__),
        do: [name: Keyword.get(opts, :name, __MODULE__)],
        else: []
      )
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    root =
      Path.expand(
        Keyword.get(
          opts,
          :root,
          Application.get_env(
            :nano,
            :bots_dir,
            Path.join(Application.fetch_env!(:nano, :state_dir), "bots")
          )
        )
      )

    with :yes <- :global.register_name({__MODULE__, root}, self()),
         {:ok, data} <- Bots.Store.load(root) do
      state = %{
        root: root,
        data: data,
        opts: opts,
        runtime: Keyword.get(opts, :runtime, Bots.Runtime),
        router: Keyword.get(opts, :router, Bots.Router),
        server: Keyword.get(opts, :name, __MODULE__) || self(),
        topic: "bots:" <> Base.url_encode64(:crypto.hash(:sha256, root), padding: false),
        pubsub: Keyword.get(opts, :pubsub, Nano.PubSub),
        grants: %{},
        jobs: %{}
      }

      send(self(), :recover)
      Process.send_after(self(), :outbox, Keyword.get(opts, :outbox_interval, 5_000))
      {:ok, state}
    else
      :no -> {:stop, :bots_root_in_use}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:topic, _, s), do: {:reply, s.topic, s}

  def handle_call(:snapshot, _, s) do
    snapshot = %{
      "bots" => s.data["bots"] |> Map.values() |> Enum.sort_by(&{&1["created_at"], &1["id"]}),
      "sessions" => s.data["sessions"] |> Map.values() |> Enum.sort_by(& &1["updated_at"], :desc),
      "preferences" => s.data["preferences"]
    }

    {:reply, snapshot, s}
  end

  def handle_call({:session, id}, _, s), do: {:reply, s.data["sessions"][id], s}
  def handle_call({:request_status, id}, _, s), do: {:reply, s.data["requests"][id], s}

  def handle_call({:create_bot, attrs}, _, s) do
    attrs = attrs(attrs)
    name = attrs["name"]

    if text?(name, 80) do
      bot = %{
        "id" => id(),
        "name" => String.trim(name),
        "description" => bounded(attrs["description"], 2000),
        "color" => color(attrs["color"]),
        "shape" => shape(attrs["shape"]),
        "created_at" => now()
      }

      commit(s, put_in(s.data, ["bots", bot["id"]], bot), bot, nil)
    else
      {:reply, {:error, :invalid_name}, s}
    end
  end

  def handle_call({:create_session, ids, opts}, _, s) do
    case new_session(s.data, ids, opts) do
      {:ok, session} -> commit(s, put_session(s.data, session), session, session["id"])
      error -> {:reply, error, s}
    end
  end

  def handle_call({:preferences, values}, _, s) do
    values = attrs(values)

    prefs =
      Map.merge(
        s.data["preferences"],
        Map.take(values, ["notifications", "cooldown_seconds", "max_per_hour"])
      )

    if is_boolean(prefs["notifications"]) and is_integer(prefs["cooldown_seconds"]) and
         prefs["cooldown_seconds"] >= 60 and is_integer(prefs["max_per_hour"]) and
         prefs["max_per_hour"] in 0..60 do
      commit(s, Map.put(s.data, "preferences", prefs), prefs, nil)
    else
      {:reply, {:error, :invalid_preferences}, s}
    end
  end

  def handle_call({:say, sid, text, opts}, _, s) do
    with {:ok, session} <- fetch_session(s, sid),
         :ok <- validate_text(text),
         {:ok, attachments} <- attachments(opts) do
      message = message("human", text, nil, nil, attachments)

      session =
        session
        |> append(message)
        |> Map.put("status", "thinking")
        |> Map.put("epoch", session["epoch"] + 1)
        |> Map.put("bot_exchanges", 0)
        |> Map.put("ceiling_noted", false)
        |> Map.update!("pending_human_ids", &(&1 ++ [message["id"]]))

      case save(s, put_session(s.data, session), sid) do
        {:ok, next} ->
          next = cancel_session(next, sid)
          send(self(), {:route, sid, session["epoch"], message})
          {:reply, {:ok, message}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:stop, sid}, _, s) do
    with {:ok, session} <- fetch_session(s, sid) do
      session =
        session
        |> Map.put("status", "stopped")
        |> Map.put("epoch", session["epoch"] + 1)
        |> Map.put("pending_human_ids", [])
        |> append(message("system", "Conversation stopped. Send a message to continue.", nil))

      case save(s, put_session(s.data, session), sid) do
        {:ok, next} ->
          next = cancel_session(next, sid)

          for bid <- session["bot_ids"] do
            bot = s.data["bots"][bid]
            spawn(fn -> safe(fn -> s.runtime.stop(bot, session, runtime_opts(s)) end) end)
          end

          {:reply, {:ok, session}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:post, token, text, opts}, _, s) do
    with {:ok, grant, session} <- grant(s, token),
         :ok <- validate_text(text),
         {:ok, attachments} <- attachments(opts) do
      msg = message("bot", text, grant.bot_id, nil, attachments)
      session = session |> append(msg) |> Map.put("pending_human_ids", [])
      remaining = Map.delete(s.grants, token)
      status = if active?(remaining, session["id"]), do: "thinking", else: "idle"
      session = Map.put(session, "status", status)
      {data, notification} = notification(s, put_session(s.data, session), session, msg)

      case save(s, data, session["id"]) do
        {:ok, next} ->
          next = %{next | grants: remaining}
          cancel_timer(grant.timer)
          broadcast_notification(next, notification)
          if status == "idle", do: send(self(), {:route, session["id"], session["epoch"], msg})
          {:reply, {:ok, msg}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:remember, token, key, value}, _, s) do
    with {:ok, g, _session} <- grant(s, token) do
      result = Bots.Memory.remember(g.bot_id, g.sid, key, value, runtime_opts(s))
      {:reply, result, s}
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:finish, token}, _, s) do
    with {:ok, g, session} <- grant(s, token) do
      next = %{s | grants: Map.delete(s.grants, token)}
      cancel_timer(g.timer)

      if active?(next.grants, session["id"]) do
        {:reply, {:ok, session}, next}
      else
        {session, follow} = finish_session(session)

        case save(next, put_session(next.data, session), session["id"]) do
          {:ok, next} ->
            if follow, do: send(self(), {:route, session["id"], session["epoch"], follow})
            {:reply, {:ok, session}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end
      end
    else
      error -> {:reply, error, s}
    end
  end

  def handle_call({:request, bid, text, opts}, _, s) do
    key = opts[:idempotency_key]

    existing =
      if is_binary(key),
        do:
          Enum.find(
            Map.values(s.data["requests"]),
            &(&1["bot_id"] == bid and &1["idempotency_key"] == key)
          )

    if existing do
      {:reply, {:ok, existing}, s}
    else
      with true <- Map.has_key?(s.data["bots"], bid),
           :ok <- validate_text(text),
           {:ok, requester} <- requester(opts[:requester]),
           {:ok, session} <- request_session(s, bid, opts) do
        rid = id()

        request = %{
          "id" => rid,
          "bot_id" => bid,
          "session_id" => session["id"],
          "text" => text,
          "status" => "pending",
          "answer" => nil,
          "requester" => requester,
          "created_at" => now(),
          "idempotency_key" => key
        }

        msg = message("request", text, bid, rid)
        session = append(session, msg)
        data = s.data |> put_session(session) |> put_in(["requests", rid], request)
        {data, notification} = notification(s, data, session, msg)

        case save(s, data, session["id"]) do
          {:ok, next} ->
            broadcast_notification(next, notification)
            {:reply, {:ok, request}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end
      else
        false -> {:reply, {:error, :unknown_bot}, s}
        error -> {:reply, error, s}
      end
    end
  end

  def handle_call({:reply, rid, text}, _, s) do
    with %{"status" => "pending"} = request <- s.data["requests"][rid],
         :ok <- validate_text(text) do
      request =
        Map.merge(request, %{"status" => "answered", "answer" => text, "answered_at" => now()})

      session =
        s.data["sessions"][request["session_id"]]
        |> append(message("human", text, nil, rid))

      data = s.data |> put_session(session) |> put_in(["requests", rid], request)

      case save(s, data, session["id"]) do
        {:ok, next} ->
          deliver(request)
          {:reply, {:ok, request}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, s}
      end
    else
      nil -> {:reply, {:error, :unknown_request}, s}
      %{} -> {:reply, {:error, :already_answered}, s}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:ack, rid}, _, s) do
    case s.data["requests"][rid] do
      %{"status" => status} = request when status in ["answered", "delivered"] ->
        request = Map.put(request, "status", "delivered")
        commit(s, put_in(s.data, ["requests", rid], request), request, request["session_id"])

      nil ->
        {:reply, {:error, :unknown_request}, s}

      _ ->
        {:reply, {:error, :not_answered}, s}
    end
  end

  @impl true
  def handle_info(:recover, s) do
    data =
      Map.update!(s.data, "sessions", fn sessions ->
        Map.new(sessions, fn {sid, session} ->
          session = Map.put(session, "epoch", session["epoch"] + 1)

          session =
            if session["status"] == "thinking",
              do: Map.put(session, "status", "idle"),
              else: session

          {sid, session}
        end)
      end)

    case save(s, data, nil) do
      {:ok, next} ->
        for {sid, session} <- data["sessions"],
            session["pending_human_ids"] != [],
            session["status"] != "stopped" do
          msg = Enum.find(Enum.reverse(session["messages"]), &(&1["kind"] == "human"))
          send(self(), {:route, sid, session["epoch"], msg})
        end

        for {_id, req} <- data["requests"], req["status"] == "answered", do: deliver(req)
        {:noreply, next}

      {:error, reason} ->
        {:stop, {:persistence, reason}, s}
    end
  end

  def handle_info(:outbox, s) do
    for {_id, req} <- s.data["requests"], req["status"] == "answered", do: deliver(req)
    Process.send_after(self(), :outbox, Keyword.get(s.opts, :outbox_interval, 5_000))
    {:noreply, s}
  end

  def handle_info({:route, sid, epoch, message}, s) do
    session = s.data["sessions"][sid]

    cond do
      not current?(session, epoch) or is_nil(message) ->
        {:noreply, s}

      active?(s.grants, sid) or routing?(s, sid) ->
        {:noreply, s}

      message["kind"] == "bot" and session["bot_exchanges"] >= max_exchanges(s) ->
        {:noreply, ceiling(s, session)}

      true ->
        bots = Enum.map(session["bot_ids"], &s.data["bots"][&1])
        job = %{type: :route, sid: sid, epoch: epoch, message: message}
        session = Map.put(session, "status", "thinking")

        case save(s, put_session(s.data, session), sid) do
          {:ok, next} ->
            {:noreply,
             spawn_job(
               next,
               job,
               fn -> s.router.select(bots, session, message, s.opts) end,
               Keyword.get(s.opts, :routing_timeout, 3_000)
             )}

          {:error, _} ->
            {:noreply, s}
        end
    end
  end

  def handle_info({:job_result, ref, result}, s), do: complete_job(s, ref, result)

  def handle_info({:job_timeout, ref}, s) do
    if job = s.jobs[ref], do: Process.exit(job.pid, :kill)
    complete_job(s, ref, {:error, :timeout})
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, s) do
    case Enum.find(s.jobs, fn {_ref, job} -> job.monitor == monitor end) do
      {ref, _} -> complete_job(s, ref, {:error, {:worker_exit, reason}})
      nil -> {:noreply, s}
    end
  end

  def handle_info({:grant_timeout, token}, s) do
    case s.grants[token] do
      nil ->
        {:noreply, s}

      grant ->
        {:noreply,
         runtime_error(%{s | grants: Map.delete(s.grants, token)}, grant, :response_timeout)}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    for {_ref, job} <- s.jobs, do: Process.exit(job.pid, :shutdown)
    :ok
  end

  defp complete_job(s, ref, result) do
    case Map.pop(s.jobs, ref) do
      {nil, _} ->
        {:noreply, s}

      {job, jobs} ->
        cancel_timer(job.timer)
        Process.demonitor(job.monitor, [:flush])
        s = %{s | jobs: jobs}

        if current?(s.data["sessions"][job.sid], job.epoch) do
          case job.type do
            :route ->
              {:noreply, selected(s, job, result)}

            :dispatch ->
              case result do
                :ok ->
                  {:noreply, s}

                {:ok, _} ->
                  {:noreply, s}

                error ->
                  case Map.pop(s.grants, job.token) do
                    {nil, _} ->
                      {:noreply, s}

                    {g, grants} ->
                      cancel_timer(g.timer)
                      {:noreply, runtime_error(%{s | grants: grants}, g, error)}
                  end
              end
          end
        else
          {:noreply, s}
        end
    end
  end

  defp selected(s, job, result) do
    session = s.data["sessions"][job.sid]

    ids =
      case result do
        {:ok, ids} when is_list(ids) -> Enum.filter(Enum.uniq(ids), &(&1 in session["bot_ids"]))
        _ -> []
      end

    # Human messages never lose their turn to a classifier outage or abstention.
    ids = if ids == [] and job.message["kind"] == "human", do: [hd(session["bot_ids"])], else: ids

    ids =
      if job.message["kind"] == "bot",
        do: Enum.reject(ids, &(&1 == job.message["bot_id"])),
        else: ids

    available = max(0, max_exchanges(s) - session["bot_exchanges"])
    ids = if job.message["kind"] == "bot", do: Enum.take(ids, available), else: ids

    if ids == [] do
      session = Map.put(session, "status", "idle")
      persist_or_original(s, put_session(s.data, session), job.sid)
    else
      count = if job.message["kind"] == "bot", do: length(ids), else: 0
      session = Map.update!(session, "bot_exchanges", &(&1 + count))
      s = persist_or_original(s, put_session(s.data, session), job.sid)
      Enum.reduce(ids, s, fn bid, acc -> dispatch(acc, session, job.message, bid) end)
    end
  end

  defp dispatch(s, session, message, bid) do
    token = id()

    timer =
      Process.send_after(
        self(),
        {:grant_timeout, token},
        Keyword.get(s.opts, :response_timeout, 120_000)
      )

    grant = %{bot_id: bid, sid: session["id"], epoch: session["epoch"], timer: timer}
    s = %{s | grants: Map.put(s.grants, token, grant)}
    bot = s.data["bots"][bid]

    context = %{
      server: s.server,
      token: token,
      message: message,
      conversation: session["messages"],
      memories: [],
      epoch: session["epoch"]
    }

    job = %{type: :dispatch, sid: session["id"], epoch: session["epoch"], token: token}

    spawn_job(
      s,
      job,
      fn ->
        memories = Bots.Memory.recall(bot, message["text"], runtime_opts(s))
        s.runtime.dispatch(bot, session, %{context | memories: memories}, runtime_opts(s))
      end,
      Keyword.get(s.opts, :dispatch_timeout, 15_000)
    )
  end

  defp runtime_error(s, grant, reason) do
    session = s.data["sessions"][grant.sid]

    if current?(session, grant.epoch) do
      msg =
        message(
          "system",
          "A bot could not respond (#{error_label(reason)}). Send a message to retry.",
          nil
        )

      session =
        session
        |> append(msg)
        |> Map.put("status", if(active?(s.grants, grant.sid), do: "thinking", else: "error"))

      persist_or_original(s, put_session(s.data, session), grant.sid)
    else
      s
    end
  end

  defp error_label(:response_timeout), do: "response timed out"
  defp error_label(_), do: "runtime unavailable"

  defp finish_session(session) do
    if session["pending_human_ids"] != [] do
      {session
       |> append(
         message("system", "The bot ended its turn without a reply. Please try again.", nil)
       )
       |> Map.put("status", "error"), nil}
    else
      last = List.last(session["messages"])
      {Map.put(session, "status", "idle"), if(last && last["kind"] == "bot", do: last)}
    end
  end

  defp ceiling(s, session) do
    if session["ceiling_noted"] do
      s
    else
      session =
        session
        |> Map.put("ceiling_noted", true)
        |> Map.put("status", "idle")
        |> append(
          message("system", "Bot discussion limit reached. Send a message to continue.", nil)
        )

      persist_or_original(s, put_session(s.data, session), session["id"])
    end
  end

  defp spawn_job(s, job, fun, timeout) do
    ref = make_ref()
    owner = self()

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(owner, {:job_result, ref, safe(fun)}) end, [:link, :monitor])

    timer = Process.send_after(self(), {:job_timeout, ref}, timeout)
    %{s | jobs: Map.put(s.jobs, ref, Map.merge(job, %{pid: pid, monitor: monitor, timer: timer}))}
  end

  defp safe(fun) do
    try do
      fun.()
    rescue
      _ -> {:error, :exception}
    catch
      _, _ -> {:error, :exit}
    end
  end

  defp cancel_session(s, sid) do
    {removed, kept} = Enum.split_with(s.grants, fn {_t, g} -> g.sid == sid end)
    for {_t, g} <- removed, do: cancel_timer(g.timer)
    {removed_jobs, jobs} = Enum.split_with(s.jobs, fn {_r, job} -> job.sid == sid end)

    for {_r, job} <- removed_jobs do
      Process.exit(job.pid, :kill)
      Process.demonitor(job.monitor, [:flush])
      cancel_timer(job.timer)
    end

    %{s | grants: Map.new(kept), jobs: Map.new(jobs)}
  end

  defp grant(s, token) do
    case s.grants[token] do
      nil ->
        {:error, :stale_token}

      g ->
        session = s.data["sessions"][g.sid]
        if current?(session, g.epoch), do: {:ok, g, session}, else: {:error, :stale_token}
    end
  end

  defp active?(grants, sid), do: Enum.any?(grants, fn {_t, g} -> g.sid == sid end)

  defp routing?(s, sid),
    do: Enum.any?(s.jobs, fn {_r, j} -> j.sid == sid and j.type == :route end)

  defp current?(nil, _), do: false
  defp current?(session, epoch), do: session["epoch"] == epoch and session["status"] != "stopped"
  defp max_exchanges(s), do: Keyword.get(s.opts, :max_bot_exchanges, 6)
  defp runtime_opts(s), do: Keyword.put(s.opts, :root, s.root)
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp new_session(data, ids, opts) do
    if is_list(ids) and ids != [] and length(ids) <= 12 and
         Enum.all?(ids, &Map.has_key?(data["bots"], &1)) do
      ids = Enum.uniq(ids)
      title = bounded(opts[:title], 200)
      title = if title == "", do: Enum.map_join(ids, ", ", &data["bots"][&1]["name"]), else: title

      {:ok,
       %{
         "id" => id(),
         "title" => title,
         "bot_ids" => ids,
         "updated_at" => now(),
         "messages" => [],
         "status" => "idle",
         "epoch" => 0,
         "bot_exchanges" => 0,
         "pending_human_ids" => [],
         "ceiling_noted" => false
       }}
    else
      {:error, :invalid_participants}
    end
  end

  defp request_session(s, bid, opts) do
    if opts[:session_id] do
      with {:ok, session} <- fetch_session(s, opts[:session_id]),
           true <- bid in session["bot_ids"] do
        {:ok, session}
      else
        false -> {:error, :bot_not_in_session}
        error -> error
      end
    else
      session =
        s.data["sessions"]
        |> Map.values()
        |> Enum.filter(&(&1["bot_ids"] == [bid]))
        |> Enum.max_by(& &1["updated_at"], fn -> nil end)

      if session, do: {:ok, session}, else: new_session(s.data, [bid], [])
    end
  end

  defp requester(pid) when is_pid(pid),
    do:
      {:ok,
       %{
         "kind" => "pid",
         "value" => inspect(pid),
         "node" => Atom.to_string(node()),
         "boot" => :erlang.system_info(:start_time)
       }}

  defp requester(name) when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 200,
    do: {:ok, %{"kind" => "agent", "value" => name}}

  defp requester(_), do: {:error, :invalid_requester}

  defp deliver(request) do
    payload = {:bots_answer, request["id"], request["answer"]}

    case request["requester"] do
      %{"kind" => "agent", "value" => name} ->
        NanoAgent.notify(name, payload)

      %{"kind" => "pid", "value" => value, "node" => n, "boot" => boot} ->
        if n == Atom.to_string(node()) and boot == :erlang.system_info(:start_time) do
          try do
            pid =
              value
              |> String.trim_leading("#PID")
              |> String.to_charlist()
              |> :erlang.list_to_pid()

            if Process.alive?(pid), do: send(pid, payload)
          rescue
            _ -> :ok
          end
        end

      _ ->
        :ok
    end
  end

  defp notification(s, data, session, msg) do
    now = System.system_time(:second)
    prefs = data["preferences"]
    times = Enum.filter(data["notification_times"], &(&1 > now - 3600))

    allowed =
      prefs["notifications"] and length(times) < prefs["max_per_hour"] and
        Enum.all?(times, &(now - &1 >= prefs["cooldown_seconds"]))

    if allowed do
      bot = data["bots"][msg["bot_id"]]

      notice = %{
        title: if(bot, do: bot["name"], else: "Bots"),
        body: String.slice(msg["text"], 0, 240),
        session_id: session["id"],
        id: msg["id"]
      }

      {Map.put(data, "notification_times", [now | times]), notice}
    else
      _ = s
      {Map.put(data, "notification_times", times), nil}
    end
  end

  defp broadcast_notification(_, nil), do: :ok

  defp broadcast_notification(s, notice),
    do: Phoenix.PubSub.broadcast(s.pubsub, s.topic, {:bots_notification, notice})

  defp commit(s, data, entity, sid) do
    case save(s, data, sid) do
      {:ok, next} -> {:reply, {:ok, entity}, next}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp save(s, data, sid) do
    case Bots.Store.save(s.root, data) do
      :ok ->
        Phoenix.PubSub.broadcast(s.pubsub, s.topic, {:bots_changed, sid})
        {:ok, %{s | data: data}}

      {:error, reason} ->
        {:error, {:persistence, reason}}
    end
  end

  defp persist_or_original(s, data, sid) do
    case save(s, data, sid) do
      {:ok, next} -> next
      {:error, _} -> s
    end
  end

  defp fetch_session(s, sid) do
    case s.data["sessions"][sid] do
      nil -> {:error, :unknown_session}
      session -> {:ok, session}
    end
  end

  defp put_session(data, session), do: put_in(data, ["sessions", session["id"]], session)

  defp append(session, msg),
    do:
      session
      |> Map.update!("messages", &(&1 ++ [msg]))
      |> Map.put("updated_at", msg["created_at"])

  defp message(kind, text, bid, rid \\ nil, attachments \\ []) do
    %{
      "id" => id(),
      "kind" => kind,
      "bot_id" => bid,
      "text" => text,
      "created_at" => now(),
      "request_id" => rid,
      "attachments" => attachments
    }
  end

  defp attachments(opts) do
    attachments = Keyword.get(opts, :attachments, [])

    if is_list(attachments) and length(attachments) <= 10 and
         Enum.all?(attachments, fn a ->
           is_map(a) and
             Enum.all?(a, fn {k, v} -> is_binary(k) and is_binary(v) and byte_size(v) <= 2000 end)
         end) do
      {:ok, attachments}
    else
      {:error, :invalid_attachments}
    end
  end

  defp attrs(map) when is_map(map),
    do:
      Map.new(Enum.filter(map, fn {k, _} -> is_atom(k) or is_binary(k) end), fn {k, v} ->
        {to_string(k), v}
      end)

  defp attrs(list) when is_list(list),
    do: if(Keyword.keyword?(list), do: list |> Map.new() |> attrs(), else: %{})

  defp attrs(_), do: %{}
  defp validate_text(text), do: if(text?(text, 50_000), do: :ok, else: {:error, :invalid_text})

  defp text?(text, max),
    do:
      is_binary(text) and String.valid?(text) and byte_size(text) <= max and
        String.trim(text) != ""

  defp bounded(text, max) when is_binary(text),
    do: if(String.valid?(text), do: String.slice(text, 0, max), else: "")

  defp bounded(_, _), do: ""

  defp color(value) when is_binary(value),
    do: if(value =~ ~r/^#[a-fA-F0-9]{6}$/, do: value, else: "#7C83FD")

  defp color(_), do: Enum.random(["#7C83FD", "#EF8354", "#62B6A8", "#C284D9", "#E4B85B"])
  defp shape(value) when value in ["circle", "square", "squircle", "triangle"], do: value
  defp shape(_), do: Enum.random(["circle", "square", "squircle", "triangle"])
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
