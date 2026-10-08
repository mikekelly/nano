defmodule Seedling.Bots do
  @moduledoc """
  Durable bot identities and shared human chat sessions on the existing Nano node.
  One NanoAgent per bot/session: context windows never cross sessions; explicit
  Seedling.Memory is shared per bot. Human-visible output must use `post/4`, not
  the model's final answer or tool log. All persistence precedes live publication.

      {:ok, bot} = Seedling.Bots.create("Muse", model: "...", reasoning: "low", max_context: 64000)
      {:ok, chat} = Seedling.Bots.session([bot["id"]])
      Seedling.Bots.say(chat["id"], "Plan my trip")
      Seedling.Bots.request_human(bot["id"], "Which dates?", reply_to: me)

  Requests return IDs, answers are durable and correlated. Named-agent reply targets
  are resolved again after restarts; unnamed pids are best-effort only. Poll with
  `request_status/2` if the requester was offline. No harness calls or decision
  model calls occur in a page render. `snapshot/0` is an ETS read; bot delivery,
  memory selection and routing run outside this service's GenServer.
  """
  use GenServer
  alias Seedling.CapabilityStore, as: Store
  @table Seedling.Bots.Table
  @empty %{
    "bots" => %{},
    "sessions" => %{},
    "requests" => %{},
    "notifications" => %{
      "enabled" => false,
      "per_hour" => 3,
      "cooldown_seconds" => 60,
      "quiet_start" => nil,
      "quiet_end" => nil,
      "sent" => []
    }
  }
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def snapshot do
    case :ets.whereis(@table) do
      :undefined ->
        @empty

      table ->
        case :ets.lookup(table, :snapshot) do
          [{:snapshot, d}] -> d
          _ -> @empty
        end
    end
  end

  def snapshot(server), do: GenServer.call(server, :snapshot)
  def create(name, opts \\ []), do: call(opts, {:create, name, opts})
  def session(bots, opts \\ []), do: call(opts, {:session, bots, opts[:title]})

  def say(session, text, opts \\ []),
    do: call(opts, {:message, session, "human", text, opts[:files] || [], nil})

  def post(session, bot, text, opts \\ []),
    do: call(opts, {:message, session, bot, text, opts[:files] || [], caller_agent()})

  def request_human(bot, question, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to, caller_pid())
    target = if is_pid(reply_to), do: Store.agent(reply_to), else: reply_to

    call(
      opts,
      {:request, bot, question, target, if(is_pid(reply_to), do: reply_to),
       caller_agent() || inspect(caller_pid()), opts}
    )
  end

  def answer(request, text, opts \\ []), do: call(opts, {:answer, request, text, opts[:session]})

  def acknowledge(id, opts \\ []),
    do: call(opts, {:acknowledge, id, caller_agent(), caller_pid()})

  def message(session, id, opts \\ []) do
    doc = if opts[:server], do: snapshot(opts[:server]), else: snapshot()
    m = Enum.find(get_in(doc, ["sessions", session, "messages"]) || [], &(&1["id"] == id))

    if m do
      offset = max(Keyword.get(opts, :offset, 0), 0)
      limit = min(max(Keyword.get(opts, :limit, 3000), 1), 6000)

      {:ok,
       Map.merge(m, %{
         "text" => String.slice(m["text"], offset, limit),
         "total_chars" => String.length(m["text"]),
         "next_offset" => offset + limit
       })}
    else
      {:error, :not_found}
    end
  end

  def request_status(id, opts \\ []), do: call(opts, {:request_status, id})
  def cancel_request(id, opts \\ []), do: call(opts, {:cancel, id})

  def notifications(settings, opts \\ []),
    do: call(opts, {:notifications, Map.new(settings, fn {k, v} -> {to_string(k), v} end)})

  def agent_name(session, bot), do: "bot-" <> bot <> "-" <> session
  defp call(opts, msg), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), msg)
  defp caller_pid, do: List.first(Process.get(:"$callers", [])) || self()
  defp caller_agent, do: Store.agent(caller_pid())
  @impl true
  def init(opts) do
    with {:ok, d} <- Store.get(:bots, "catalog", @empty, opts) do
      table =
        if Keyword.get(opts, :name, __MODULE__) == __MODULE__,
          do: :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true]),
          else: :ets.new(@table, [:set, :protected])

      :ets.insert(table, {:snapshot, d})
      Process.send_after(self(), :expire, 30_000)
      send(self(), :schedule)
      send(self(), :outbox)
      send(self(), :restore_watchers)
      {:ok, %{doc: d, table: table, opts: opts, waiters: %{}, watchers: %{}, active: %{}}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, s), do: {:reply, s.doc, s}

  def handle_call({:create, name, opts}, _from, s) do
    cond do
      not text?(name, 80) ->
        {:reply, {:error, :invalid_name}, s}

      map_size(s.doc["bots"]) >= 100 ->
        {:reply, {:error, :bot_limit}, s}

      not is_binary(opts[:model]) or not is_binary(opts[:reasoning]) or
        not is_integer(opts[:max_context]) or opts[:max_context] < 8192 ->
        {:reply, {:error, :model_reasoning_context_required}, s}

      true ->
        id = Store.id()

        color =
          Enum.at(
            ~w(#bfdbfe #ddd6fe #fed7aa #bbf7d0 #fecdd3 #a5f3fc),
            rem(:binary.first(:crypto.hash(:sha256, id)), 6)
          )

        workspace = Path.join([Store.root(s.opts), "bot-computers", id])
        :ok = File.mkdir_p(workspace)

        bot = %{
          "workspace" => workspace,
          "id" => id,
          "name" => name,
          "description" =>
            String.slice(opts[:description] || "A thoughtful, helpful companion.", 0, 500),
          "color" => color,
          "shape" =>
            Enum.at(~w(round square diamond), rem(:binary.first(:crypto.hash(:sha256, name)), 3)),
          "model" => opts[:model],
          "reasoning" => opts[:reasoning],
          "max_context" => opts[:max_context],
          "created_at" => Store.now()
        }

        persist(s, put_in(s.doc, ["bots", id], bot), bot)
    end
  end

  def handle_call({:session, bots, title}, _from, s) do
    bots = if is_list(bots), do: Enum.uniq(bots), else: []

    cond do
      length(bots) not in 1..8 or not Enum.all?(bots, &Map.has_key?(s.doc["bots"], &1)) ->
        {:reply, {:error, :invalid_participants}, s}

      map_size(s.doc["sessions"]) >= 500 ->
        {:reply, {:error, :session_limit}, s}

      true ->
        id = Store.id()

        title =
          if text?(title, 120),
            do: title,
            else: Enum.map_join(bots, ", ", &s.doc["bots"][&1]["name"])

        chat = %{
          "id" => id,
          "bots" => bots,
          "title" => title,
          "messages" => [],
          "pending" => [],
          "status" => %{},
          "updated_at" => Store.now()
        }

        persist(s, put_in(s.doc, ["sessions", id], chat), chat)
    end
  end

  def handle_call({:message, id, speaker, text, files, actor}, _from, s) do
    chat = s.doc["sessions"][id]

    cond do
      is_nil(chat) ->
        {:reply, {:error, :session_not_found}, s}

      speaker != "human" and (speaker not in chat["bots"] or actor != agent_name(id, speaker)) ->
        {:reply, {:error, :not_session_agent}, s}

      not text?(text, 12_000) ->
        {:reply, {:error, :invalid_message}, s}

      not is_list(files) or length(files) > 4 or not Enum.all?(files, &valid_file?(&1, s.opts)) ->
        {:reply, {:error, :invalid_files}, s}

      length(chat["messages"]) >= 1000 ->
        {:reply, {:error, :session_message_limit_start_new_chat}, s}

      true ->
        msg = new_message(speaker, text) |> Map.put("files", files)
        doc = append(s.doc, id, msg)
        doc = if speaker == "human", do: enqueue(doc, id, msg["id"]), else: doc

        doc =
          if speaker == "human",
            do: doc,
            else: put_in(doc, ["sessions", id, "status", speaker], "idle")

        {doc, notify} = if speaker != "human", do: notification(doc), else: {doc, false}

        persist(s, doc, msg, fn new ->
          publish(%{session: id, message: msg, notify: notify})
          if speaker == "human", do: send(self(), :schedule)
          _ = new
        end)
    end
  end

  def handle_call({:request, bot, question, target, pid, requester, opts}, _from, s) do
    chats =
      s.doc["sessions"]
      |> Map.values()
      |> Enum.filter(&(bot in &1["bots"]))
      |> Enum.sort_by(& &1["updated_at"], :desc)

    chat = if opts[:session], do: s.doc["sessions"][opts[:session]], else: List.first(chats)

    cond do
      not Map.has_key?(s.doc["bots"], bot) or is_nil(chat) or bot not in chat["bots"] ->
        {:reply, {:error, :start_a_session_with_this_bot_first}, s}

      not text?(question, 2000) ->
        {:reply, {:error, :invalid_question}, s}

      is_nil(target) and not is_pid(pid) ->
        {:reply, {:error, :reply_target_required}, s}

      map_size(s.doc["requests"]) >= 1000 ->
        {:reply, {:error, :request_limit}, s}

      true ->
        id = Store.id()
        timeout = Keyword.get(opts, :timeout_ms, 3_600_000)

        if is_integer(timeout) and timeout in 1000..86_400_000 do
          request = %{
            "id" => id,
            "bot" => bot,
            "session" => chat["id"],
            "question" => question,
            "requester" => requester,
            "reply_target" => target,
            "state" => "open",
            "answer" => nil,
            "created_at" => Store.now(),
            "expires_at" =>
              DateTime.add(DateTime.utc_now(), timeout, :millisecond) |> DateTime.to_iso8601()
          }

          msg = new_message(bot, question) |> Map.put("request_id", id)
          doc = s.doc |> put_in(["requests", id], request) |> append(chat["id"], msg)
          {doc, notify} = notification(doc)
          s = %{s | waiters: if(pid, do: Map.put(s.waiters, id, pid), else: s.waiters)}

          persist(s, doc, request, fn _ ->
            publish(%{session: chat["id"], message: msg, notify: notify})
          end)
        else
          {:reply, {:error, :invalid_timeout}, s}
        end
    end
  end

  def handle_call({:request_status, id}, _from, s),
    do:
      {:reply,
       if(s.doc["requests"][id], do: {:ok, s.doc["requests"][id]}, else: {:error, :not_found}), s}

  def handle_call({:answer, id, text, session}, _from, s) do
    r = s.doc["requests"][id]

    cond do
      is_nil(r) ->
        {:reply, {:error, :not_found}, s}

      session != r["session"] ->
        {:reply, {:error, :wrong_answer_session}, s}

      r["state"] != "open" ->
        {:reply, {:error, :request_not_open}, s}

      r["expires_at"] <= Store.now() ->
        {:reply, {:error, :request_expired}, s}

      not text?(text, 4000) ->
        {:reply, {:error, :invalid_answer}, s}

      true ->
        r =
          Map.merge(r, %{
            "state" => "answered",
            "answer" => text,
            "answered_at" => Store.now(),
            "delivery_state" => "pending",
            "next_delivery" => 0,
            "delivery_attempts" => 0
          })

        msg = new_message("human", text) |> Map.put("answer_to", id)

        doc =
          s.doc
          |> put_in(["requests", id], r)
          |> append(r["session"], msg)
          |> enqueue(r["session"], msg["id"])

        persist(s, doc, r, fn new ->
          send(self(), :outbox)
          _ = new
          publish(%{session: r["session"], message: msg, notify: false})
          send(self(), :schedule)
        end)
    end
  end

  def handle_call({:cancel, id}, _from, s) do
    case s.doc["requests"][id] do
      %{"state" => "open"} = r ->
        r =
          Map.merge(r, %{
            "state" => "cancelled",
            "delivery_state" => "pending",
            "next_delivery" => 0,
            "delivery_attempts" => 0
          })

        persist(s, put_in(s.doc, ["requests", id], r), r, fn _ -> send(self(), :outbox) end)

      _ ->
        {:reply, {:error, :request_not_open}, s}
    end
  end

  def handle_call({:acknowledge, id, actor, pid}, _from, s) do
    case s.doc["requests"][id] do
      %{"state" => state} = r when state in ["answered", "cancelled", "expired"] ->
        authorized =
          if r["reply_target"], do: actor == r["reply_target"], else: pid == s.waiters[id]

        if authorized do
          r = Map.put(r, "delivery_state", "acknowledged")
          persist(s, put_in(s.doc, ["requests", id], r), :ok)
        else
          {:reply, {:error, :not_reply_target}, s}
        end

      _ ->
        {:reply, {:error, :request_not_completed}, s}
    end
  end

  def handle_call({:notifications, changes}, _from, s) do
    n = Map.merge(s.doc["notifications"], changes)

    valid =
      Enum.all?(
        Map.keys(changes),
        &(&1 in ~w(enabled per_hour cooldown_seconds quiet_start quiet_end))
      ) and is_boolean(n["enabled"]) and is_integer(n["per_hour"]) and n["per_hour"] in 0..30 and
        is_integer(n["cooldown_seconds"]) and n["cooldown_seconds"] in 0..86400 and
        Enum.all?(
          [n["quiet_start"], n["quiet_end"]],
          &(is_nil(&1) or (is_integer(&1) and &1 in 0..23))
        )

    if valid,
      do: persist(s, Map.put(s.doc, "notifications", n), n),
      else: {:reply, {:error, :invalid_notification_limits}, s}
  end

  @impl true
  def handle_cast({:delivery, session, bot, status, agent_id}, s) do
    if agent_id && not Map.has_key?(s.watchers, agent_id), do: Nano.Log.subscribe(agent_id)
    watchers = if agent_id, do: Map.put(s.watchers, agent_id, {session, bot}), else: s.watchers

    if s.doc["sessions"][session] do
      doc = put_in(s.doc, ["sessions", session, "status", bot], status)

      doc =
        if agent_id,
          do:
            update_in(doc, ["sessions", session], fn c ->
              Map.put(c, "agent_ids", Map.put(Map.get(c, "agent_ids", %{}), bot, agent_id))
            end),
          else: doc

      case persist(%{s | watchers: watchers}, doc, :ok) do
        {:reply, _, new} -> {:noreply, new}
      end
    else
      {:noreply, %{s | watchers: watchers}}
    end
  end

  @impl true
  def handle_info({:nano_log, %{type: :turn_ended, agent_id: id}}, s) do
    case s.watchers[id] do
      {session, bot} -> handle_cast({:delivery, session, bot, "idle", id}, s)
      _ -> {:noreply, s}
    end
  end

  def handle_info({:nano_log, _}, s), do: {:noreply, s}

  def handle_info(:expire, s) do
    Process.send_after(self(), :expire, 30_000)
    send(self(), :outbox)

    expired =
      s.doc["requests"]
      |> Map.values()
      |> Enum.filter(&(&1["state"] == "open" and &1["expires_at"] <= Store.now()))

    if expired == [] do
      {:noreply, s}
    else
      doc =
        Enum.reduce(expired, s.doc, fn r, d ->
          put_in(
            d,
            ["requests", r["id"]],
            Map.merge(r, %{
              "state" => "expired",
              "delivery_state" => "pending",
              "next_delivery" => 0,
              "delivery_attempts" => 0
            })
          )
        end)

      case persist(s, doc, :ok, fn _ -> send(self(), :outbox) end) do
        {:reply, _, new} -> {:noreply, new}
      end
    end
  end

  def handle_info(:restore_watchers, s) do
    {doc, watchers} =
      Enum.reduce(s.doc["sessions"], {s.doc, s.watchers}, fn {session, chat}, {doc, watchers} ->
        Enum.reduce(chat["bots"], {doc, watchers}, fn bot, {doc, watchers} ->
          saved = Nano.StateStore.get(agent_name(session, bot))
          id = (saved && saved.id) || get_in(chat, ["agent_ids", bot])

          if id do
            Nano.Log.subscribe(id)

            status =
              cond do
                saved && saved[:halted] ->
                  "paused; operator attention needed"

                saved && saved[:status] in [:thinking, :running_tool, :waiting_retry] ->
                  "thinking"

                true ->
                  "idle"
              end

            {put_in(doc, ["sessions", session, "status", bot], status),
             Map.put(watchers, id, {session, bot})}
          else
            {doc, watchers}
          end
        end)
      end)

    case persist(%{s | watchers: watchers}, doc, :ok) do
      {:reply, _, new} -> {:noreply, new}
    end
  end

  def handle_info(:outbox, s) do
    now = System.system_time(:second)

    due =
      for r <- Map.values(s.doc["requests"]),
          r["delivery_state"] == "pending",
          Map.get(r, "next_delivery", 0) <= now,
          pid =
            if(r["reply_target"],
              do: NanoAgent.whereis(r["reply_target"]),
              else: s.waiters[r["id"]]
            ),
          is_pid(pid) and Process.alive?(pid),
          do: {r, pid}

    if due == [] do
      {:noreply, s}
    else
      doc =
        Enum.reduce(due, s.doc, fn {r, _}, doc ->
          attempts = Map.get(r, "delivery_attempts", 0) + 1
          backoff = min(60 * Integer.pow(2, min(attempts - 1, 6)), 3600)
          r = Map.merge(r, %{"delivery_attempts" => attempts, "next_delivery" => now + backoff})
          put_in(doc, ["requests", r["id"]], r)
        end)

      case persist(s, doc, :ok, fn _ ->
             Enum.each(due, fn {r, pid} -> deliver_answer(pid, r) end)
           end) do
        {:reply, _, new} -> {:noreply, new}
      end
    end
  end

  def handle_info(:schedule, s) do
    active =
      Enum.reduce(s.doc["sessions"], s.active, fn {id, chat}, active ->
        case {Map.get(chat, "pending", []), active[id]} do
          {[message_id | _], nil} ->
            msg = Enum.find(chat["messages"], &(&1["id"] == message_id))

            if msg do
              launch_delivery(s, id, msg["text"], message_id)
              Map.put(active, id, message_id)
            else
              active
            end

          _ ->
            active
        end
      end)

    {:noreply, %{s | active: active}}
  end

  def handle_info({:delivery_done, session, message_id}, s) do
    if s.active[session] == message_id do
      doc =
        update_in(s.doc, ["sessions", session, "pending"], fn ids ->
          List.delete(ids || [], message_id)
        end)

      case persist(%{s | active: Map.delete(s.active, session)}, doc, :ok) do
        {:reply, _, new} ->
          send(self(), :schedule)
          {:noreply, new}
      end
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp persist(s, doc, result, effect \\ fn _ -> :ok end) do
    case Store.update(:bots, "catalog", @empty, fn _ -> {:ok, doc, result} end, s.opts) do
      {:ok, result} ->
        :ets.insert(s.table, {:snapshot, doc})
        new = %{s | doc: doc}
        publish(%{changed: true})
        effect.(new)
        {:reply, {:ok, result}, new}

      error ->
        {:reply, error, s}
    end
  end

  defp append(doc, session, msg) do
    update_in(doc, ["sessions", session], fn c ->
      %{c | "messages" => c["messages"] ++ [msg], "updated_at" => msg["at"]}
    end)
  end

  defp new_message(speaker, text),
    do: %{
      "id" => Store.id(),
      "speaker" => speaker,
      "text" => text,
      "at" => Store.now(),
      "files" => []
    }

  defp text?(s, max), do: is_binary(s) and String.trim(s) != "" and String.length(s) <= max

  defp valid_file?(f, opts) do
    if is_map(f) and is_binary(f["id"]) and f["id"] =~ ~r/^[a-f0-9]{16}$/ and
         text?(f["name"], 160) do
      case Seedling.BotFiles.get(f["id"], opts) do
        {:ok, meta, _} -> f == meta
        _ -> false
      end
    else
      false
    end
  end

  defp publish(event) do
    Phoenix.PubSub.broadcast(Nano.PubSub, "bots", {:bots, event})
  rescue
    ArgumentError -> :ok
  end

  defp notification(doc) do
    n = doc["notifications"]
    now = System.system_time(:second)
    hour = DateTime.utc_now().hour
    sent = Enum.filter(n["sent"], &(&1 > now - 3600))

    quiet =
      if is_integer(n["quiet_start"]) and is_integer(n["quiet_end"]) do
        if n["quiet_start"] <= n["quiet_end"],
          do: hour >= n["quiet_start"] and hour < n["quiet_end"],
          else: hour >= n["quiet_start"] or hour < n["quiet_end"]
      else
        false
      end

    allowed =
      n["enabled"] and not quiet and length(sent) < n["per_hour"] and
        (sent == [] or now - List.last(sent) >= n["cooldown_seconds"])

    n = Map.put(n, "sent", if(allowed, do: sent ++ [now], else: sent))
    {Map.put(doc, "notifications", n), allowed}
  end

  defp deliver_answer(pid, r) do
    send(pid, %{
      type: :bot_human_answer,
      request_id: r["id"],
      bot_id: r["bot"],
      session_id: r["session"],
      state: r["state"],
      answer: r["answer"],
      acknowledge:
        "Call Seedling.Bots.acknowledge(request_id) after processing. Retries are correlated; deduplicate by request_id."
    })
  end

  defp enqueue(doc, session, message_id),
    do:
      update_in(doc, ["sessions", session], fn c ->
        Map.put(c, "pending", Map.get(c, "pending", []) ++ [message_id])
      end)

  defp launch_delivery(s, session, text, message_id) do
    server = self()
    doc = s.doc
    opts = s.opts

    Task.start(fn ->
      try do
        Seedling.BotDelivery.deliver(
          server,
          doc,
          session,
          text,
          Keyword.put(opts, :message_id, message_id)
        )
      after
        send(server, {:delivery_done, session, message_id})
      end
    end)
  end
end
