defmodule Vega.Bots.Server do
  @moduledoc "Supervised durable bot/session service. Disk acceptance precedes dispatch and PubSub. No calls into an agent process on the UI read path."
  use GenServer
  alias Vega.Store
  @colours ~w(lilac sky peach mint rose gold)
  @shapes ~w(round square bean)
  @settings %{
    "notifications_enabled" => false,
    "notification_interval_seconds" => 60,
    "notification_max_per_hour" => 6,
    "notification_requests_only" => true,
    "notification_preview" => false
  }
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Nonblocking bounded public snapshot from service-owned ETS, even during a durable write."
  def snapshot(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         table when not is_nil(table) <- :persistent_term.get({__MODULE__, pid}, nil),
         [{:snapshot, data}] <- :ets.lookup(table, :snapshot) do
      {:ok, data}
    else
      _ -> {:error, :not_started}
    end
  rescue
    ArgumentError -> {:error, :not_started}
  end

  def session(server, sid, opts) do
    if opts[:before] == nil and Keyword.get(opts, :limit, 80) == 80 do
      with pid when is_pid(pid) <- GenServer.whereis(server),
           table when not is_nil(table) <- :persistent_term.get({__MODULE__, pid}, nil) do
        case :ets.lookup(table, {:session, sid}) do
          [{_, page}] -> {:ok, page}
          _ -> {:error, :not_found}
        end
      else
        _ -> {:error, :not_started}
      end
    else
      GenServer.call(server, {:session, sid, opts}, 10_000)
    end
  rescue
    ArgumentError -> {:error, :not_started}
  catch
    :exit, _ -> {:error, :service_unavailable}
  end

  @impl true
  def init(opts) do
    root = Keyword.get(opts, :root, "/data/vega")

    with {:ok, saved} <- Vega.Bots.Persistence.load(root) do
      data =
        saved ||
          %{
            "bots" => [],
            "sessions" => [],
            "requests" => [],
            "settings" => @settings,
            "outbox" => []
          }

      table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
      :persistent_term.put({__MODULE__, self()}, table)
      cache(table, data)
      send(self(), :tick)

      {:ok,
       %{
         table: table,
         root: root,
         data: data,
         runtime: Keyword.get(opts, :runtime, Vega.Bots.Runtime),
         topic: "vega:bots:" <> Path.expand(root),
         tasks: %{},
         tick_ms: Keyword.get(opts, :tick_ms, 1000),
         answer_retry_ms: Keyword.get(opts, :answer_retry_ms, 30_000),
         delivered: %{}
       }}
    end
  end

  @impl true
  def handle_call(:snapshot, _, s) do
    {:reply, snapshot(self()), s}
  end

  def handle_call({:session, sid, opts}, _, s) do
    result =
      with {:ok, session} <- find(s.data, "sessions", sid) do
        limit = opts[:limit] || 80

        if is_integer(limit) and limit in 1..200 do
          messages = session["messages"]

          stop =
            if opts[:before],
              do: Enum.find_index(messages, &(&1["id"] == opts[:before])),
              else: length(messages)

          if is_integer(stop) do
            start = max(0, stop - limit)
            page = Enum.slice(messages, start, stop - start)

            history = %{
              "total" => length(messages),
              "start" => start,
              "has_more" => start > 0,
              "next_before" =>
                case page do
                  [first | _] -> first["id"]
                  _ -> nil
                end
            }

            {:ok, session |> Map.put("messages", page) |> Map.put("history", history)}
          else
            {:error, :invalid_cursor}
          end
        else
          {:error, :invalid_page_limit}
        end
      end

    {:reply, result, s}
  end

  def handle_call(:root, _, s), do: {:reply, {:ok, s.root}, s}
  def handle_call(:topic, _, s), do: {:reply, {:ok, s.topic}, s}

  def handle_call(command, _, s) do
    command =
      case command do
        {:message, sid, author, text, opts} ->
          {:message, sid, author, text, Keyword.put(opts, :root, s.root)}

        other ->
          other
      end

    case safe_mutate(command, s.data) do
      {:ok, result, next, event} ->
        case persist(s, next) do
          :ok ->
            cache(s.table, next)
            Phoenix.PubSub.broadcast(Nano.PubSub, s.topic, {:vega_bots, event})
            send(self(), :dispatch)
            {:reply, {:ok, result}, %{s | data: next}}

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  defp safe_mutate(command, data) do
    mutate(command, data)
  rescue
    _ -> {:error, :invalid_command}
  end

  defp mutate({:create_bot, name, opts}, d) do
    attrs = %{
      "id" => id(),
      "name" => name,
      "description" => opts[:description] || "A thoughtful, helpful companion.",
      "voice" => opts[:voice] || "Warm, clear and practical.",
      "model" => opts[:model],
      "reasoning" => opts[:reasoning],
      "max_context" => opts[:max_context],
      "max_turns" => opts[:max_turns],
      "max_tokens" => opts[:max_tokens],
      "created_at" => Store.now(),
      "face" => %{
        "colour" => Enum.at(@colours, rem(length(d["bots"]), length(@colours))),
        "shape" => Enum.at(@shapes, rem(length(d["bots"]), length(@shapes)))
      }
    }

    with :ok <- validate_bot(attrs) do
      {:ok, attrs, Map.update!(d, "bots", &(&1 ++ [attrs])), event("bot_created")}
    end
  end

  defp mutate({:update_bot, id, attrs}, d) do
    attrs = Store.attrs(attrs)

    with {:ok, old} <- find(d, "bots", id),
         true <-
           Enum.all?(
             Map.keys(attrs),
             &(&1 in ~w(name description voice model reasoning max_context max_turns max_tokens))
           ),
         next = Map.merge(old, attrs),
         :ok <- validate_bot(next) do
      {:ok, next, replace(d, "bots", next), event("bot_updated")}
    else
      false -> {:error, :invalid_fields}
      error -> error
    end
  end

  defp mutate({:create_session, ids, opts}, d) do
    if is_list(ids) and length(ids) in 1..12 and Enum.uniq(ids) == ids and
         Enum.all?(ids, fn id -> match?({:ok, _}, find(d, "bots", id)) end) do
      title =
        opts[:title] ||
          Enum.map_join(ids, ", ", fn id ->
            {:ok, b} = find(d, "bots", id)
            b["name"]
          end)

      if text?(title, 200) do
        session = %{
          "id" => id(),
          "title" => title,
          "bot_ids" => ids,
          "messages" => [],
          "statuses" => %{},
          "created_at" => Store.now(),
          "updated_at" => Store.now()
        }

        {:ok, session, Map.update!(d, "sessions", &[session | &1]),
         event("session_created", session["id"])}
      else
        {:error, :invalid_title}
      end
    else
      {:error, :invalid_participants}
    end
  end

  defp mutate({:update_session, sid, attrs}, d) do
    attrs = Store.attrs(attrs)

    with {:ok, old} <- find(d, "sessions", sid),
         true <- Map.keys(attrs) == ["title"] and text?(attrs["title"], 200) do
      next = Map.merge(old, attrs)
      {:ok, next, replace(d, "sessions", next), event("session_updated", sid)}
    else
      false -> {:error, :invalid_title}
      error -> error
    end
  end

  defp mutate({:message, sid, author, text, opts}, d) do
    with {:ok, session} <- find(d, "sessions", sid),
         true <- author == "person" or author in session["bot_ids"],
         true <-
           text?(text, 32_000) or
             (text == "" and (opts[:images] not in [nil, []] or opts[:files] not in [nil, []])),
         {:ok, images} <- validate_images(opts[:images] || []),
         {:ok, files} <- Vega.Bots.Files.validate(opts[:files] || [], opts[:root]),
         true <-
           is_nil(opts[:reply_to]) or
             (author != "person" and
                Enum.any?(
                  session["messages"],
                  &(&1["id"] == opts[:reply_to] and &1["author_id"] == "person")
                )) do
      existing =
        if opts[:reply_to],
          do:
            Enum.find(
              session["messages"],
              &(&1["author_id"] == author and &1["reply_to"] == opts[:reply_to])
            ),
          else: nil

      if existing do
        {:ok, existing, d, event("message_existing", sid)}
      else
        message = %{
          "id" => id(),
          "author_id" => author,
          "text" => text,
          "at" => Store.now(),
          "images" => images,
          "files" => files,
          "reply_to" => opts[:reply_to]
        }

        next = append(d, session, message)

        next =
          if author == "person" do
            queue(next, session, message)
          else
            next |> put_status(sid, author, "idle", "") |> acknowledge_input(sid, author, opts)
          end

        {:ok, message, next,
         Map.merge(event("message", sid), %{"message_id" => message["id"], "author_id" => author})}
      end
    else
      false -> {:error, :invalid_message_or_author}
      error -> error
    end
  end

  defp mutate({:status, sid, bid, state, opts}, d) do
    with {:ok, session} <- find(d, "sessions", sid),
         true <- bid in session["bot_ids"] and state in ~w(thinking idle error),
         true <- is_binary(opts[:detail] || "") and byte_size(opts[:detail] || "") <= 500 do
      next = put_status(d, sid, bid, state, opts[:detail] || "")
      {:ok, state, next, event("status", sid)}
    else
      false -> {:error, :invalid_status}
      error -> error
    end
  end

  defp mutate({:request, bid, question, opts}, d) do
    with {:ok, _} <- find(d, "bots", bid),
         true <- text?(question, 8000),
         true <- is_binary(opts[:requester]) and Regex.match?(~r/^[\w.-]+$/, opts[:requester]),
         {:ok, session, d} <- request_session(d, bid, opts[:session_id]) do
      rid = opts[:request_id] || id()

      if not is_binary(rid) or byte_size(rid) > 128 do
        {:error, :invalid_request_id}
      else
        case Enum.find(d["requests"], &(&1["id"] == rid)) do
          nil ->
            r = %{
              "id" => rid,
              "bot_id" => bid,
              "session_id" => session["id"],
              "question" => question,
              "requester" => opts[:requester],
              "status" => "pending",
              "created_at" => Store.now(),
              "answer" => nil,
              "acknowledged" => false
            }

            m = %{
              "id" => id(),
              "author_id" => bid,
              "text" => question,
              "at" => Store.now(),
              "images" => [],
              "request_id" => rid
            }

            next = append(d, session, m) |> Map.update!("requests", &(&1 ++ [r]))
            {:ok, r, next, Map.put(event("request", session["id"]), "request_id", rid)}

          existing ->
            if existing["requester"] == opts[:requester] and existing["question"] == question,
              do: {:ok, existing, d, event("request_existing", session["id"])},
              else: {:error, :request_id_conflict}
        end
      end
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp mutate({:answer, rid, text}, d) do
    with {:ok, r} <- find(d, "requests", rid), true <- text?(text, 8000) do
      if r["status"] == "answered" do
        if r["answer"] == text,
          do: {:ok, r, d, event("answer_existing", r["session_id"])},
          else: {:error, :already_answered}
      else
        {:ok, session} = find(d, "sessions", r["session_id"])

        answer =
          Map.merge(r, %{"status" => "answered", "answer" => text, "answered_at" => Store.now()})

        m = %{
          "id" => id(),
          "author_id" => "person",
          "text" => text,
          "at" => Store.now(),
          "images" => [],
          "request_id" => rid
        }

        next = append(d, session, m) |> replace("requests", answer)
        {:ok, answer, next, Map.put(event("answer", session["id"]), "request_id", rid)}
      end
    else
      false -> {:error, :invalid_answer}
      error -> error
    end
  end

  defp mutate({:ack, rid, requester}, d) do
    with {:ok, r} <- find(d, "requests", rid),
         true <- r["requester"] == requester and r["status"] == "answered" do
      next = Map.put(r, "acknowledged", true)
      {:ok, next, replace(d, "requests", next), event("acknowledged", r["session_id"])}
    else
      false -> {:error, :invalid_acknowledgement}
      error -> error
    end
  end

  defp mutate({:settings, attrs}, d) do
    attrs = Store.attrs(attrs)
    next = Map.merge(d["settings"], attrs)

    valid =
      Enum.all?(Map.keys(attrs), &Map.has_key?(@settings, &1)) and
        Enum.all?(
          ~w(notifications_enabled notification_requests_only notification_preview),
          &is_boolean(next[&1])
        ) and
        is_integer(next["notification_interval_seconds"]) and
        next["notification_interval_seconds"] in 10..86400 and
        is_integer(next["notification_max_per_hour"]) and
        next["notification_max_per_hour"] in 0..60

    if valid,
      do: {:ok, next, Map.put(d, "settings", next), event("settings")},
      else: {:error, :invalid_settings}
  end

  defp mutate({:retry, sid}, d) do
    with {:ok, _} <- find(d, "sessions", sid) do
      outbox =
        Enum.map(d["outbox"], fn x ->
          if x["session_id"] == sid, do: Map.put(x, "retry_at", 0), else: x
        end)

      {:ok, :retrying, Map.put(d, "outbox", outbox), event("retry", sid)}
    end
  end

  defp mutate(_, _), do: {:error, :invalid_command}

  defp request_session(d, bid, nil) do
    case Enum.find(d["sessions"], &(bid in &1["bot_ids"])) do
      nil ->
        case mutate({:create_session, [bid], []}, d) do
          {:ok, s, next, _} -> {:ok, s, next}
          error -> error
        end

      s ->
        {:ok, s, d}
    end
  end

  defp request_session(d, bid, sid) do
    with {:ok, s} <- find(d, "sessions", sid),
         true <- bid in s["bot_ids"],
         do: {:ok, s, d},
         else: (
           false -> {:error, :wrong_session}
           error -> error
         )
  end

  defp validate_bot(b) do
    valid =
      text?(b["name"], 80) and text?(b["description"], 1000) and text?(b["voice"], 1000) and
        text?(b["model"], 200) and text?(b["reasoning"], 40) and is_integer(b["max_context"]) and
        b["max_context"] >= 8192 and
        Enum.all?(~w(max_turns max_tokens), &(is_integer(b[&1]) and b[&1] >= 0))

    if valid, do: :ok, else: {:error, :explicit_identity_model_and_limits_required}
  end

  defp validate_images(xs) when is_list(xs) and length(xs) <= 4, do: Vega.Images.validate_refs(xs)
  defp validate_images(_), do: {:error, :invalid_images}

  defp text?(s, cap), do: Store.text?(s, cap) and String.trim(s) != ""
  defp id, do: Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
  defp event(type, sid \\ nil), do: %{"type" => type, "session_id" => sid}

  defp find(d, key, id) do
    case Enum.find(d[key], &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      x -> {:ok, x}
    end
  end

  defp replace(d, key, record),
    do:
      Map.update!(
        d,
        key,
        &Enum.map(&1, fn x -> if x["id"] == record["id"], do: record, else: x end)
      )

  defp append(d, session, message) do
    next =
      Map.merge(session, %{
        "messages" => session["messages"] ++ [message],
        "updated_at" => message["at"]
      })

    replace(d, "sessions", next)
    |> Map.update!("sessions", &Enum.sort_by(&1, fn s -> {s["updated_at"], s["id"]} end, :desc))
  end

  defp put_status(d, sid, bid, state, detail) do
    {:ok, session} = find(d, "sessions", sid)

    next =
      Map.update!(session, "statuses", &Map.put(&1, bid, %{"state" => state, "detail" => detail}))

    replace(d, "sessions", next)
  end

  defp queue(d, session, message) do
    items =
      Enum.map(
        session["bot_ids"],
        &%{
          "id" => id(),
          "session_id" => session["id"],
          "bot_id" => &1,
          "message_id" => message["id"],
          "retry_at" => 0
        }
      )

    next = Map.update!(d, "outbox", &(&1 ++ items))
    Enum.reduce(session["bot_ids"], next, &put_status(&2, session["id"], &1, "thinking", ""))
  end

  # A cast is not proof of receipt. Keep accepted inputs until the bot visibly posts.
  # Explicit reply_to acknowledges preceding inputs for that pair; default is oldest.
  defp acknowledge_input(d, sid, bid, opts) do
    if opts[:proactive] do
      d
    else
      pair = Enum.filter(d["outbox"], &(&1["session_id"] == sid and &1["bot_id"] == bid))

      target =
        opts[:reply_to] ||
          case pair do
            [first | _] -> first["message_id"]
            _ -> nil
          end

      {done, rest} = Enum.split_while(pair, &(&1["message_id"] != target))
      acknowledged = if target && rest != [], do: done ++ [hd(rest)], else: []
      ids = MapSet.new(Enum.map(acknowledged, & &1["id"]))
      Map.update!(d, "outbox", &Enum.reject(&1, fn x -> MapSet.member?(ids, x["id"]) end))
    end
  end

  defp persist(s, data), do: Vega.Bots.Persistence.save(s.root, data)

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, s.tick_ms)
    {:noreply, s |> dispatch() |> relay_answers() |> sync_statuses()}
  end

  def handle_info(:dispatch, s), do: {:noreply, s |> dispatch() |> relay_answers()}

  def handle_info({ref, result}, s) when is_reference(ref) do
    case Map.pop(s.tasks, ref) do
      {nil, _} ->
        {:noreply, s}

      {item, tasks} ->
        Process.demonitor(ref, [:flush])

        next =
          case result do
            :ok ->
              Map.update!(
                s.data,
                "outbox",
                &Enum.map(&1, fn x ->
                  if x["id"] == item["id"],
                    do: Map.put(x, "retry_at", System.system_time(:millisecond) + 60_000),
                    else: x
                end)
              )

            {:error, _} ->
              failed(s.data, item)

            _ ->
              failed(s.data, item)
          end

        {:noreply,
         save_background(%{s | tasks: tasks}, next, event("status", item["session_id"]))}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.pop(s.tasks, ref) do
      {nil, _} ->
        {:noreply, s}

      {item, tasks} ->
        {:noreply,
         save_background(
           %{s | tasks: tasks},
           failed(s.data, item),
           event("status", item["session_id"])
         )}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp failed(d, item) do
    next =
      Map.update!(
        d,
        "outbox",
        &Enum.map(&1, fn x ->
          if x["id"] == item["id"],
            do: Map.put(x, "retry_at", System.system_time(:millisecond) + 30_000),
            else: x
        end)
      )

    put_status(
      next,
      item["session_id"],
      item["bot_id"],
      "error",
      "Could not reach the bot. Check its model connection, then retry."
    )
  end

  defp dispatch(s) do
    busy = Map.values(s.tasks) |> Enum.map(&{&1["session_id"], &1["bot_id"]}) |> MapSet.new()

    {tasks, _} =
      Enum.reduce(s.data["outbox"], {s.tasks, busy}, fn item, {tasks, busy} ->
        pair = {item["session_id"], item["bot_id"]}

        if MapSet.member?(busy, pair) or item["retry_at"] > System.system_time(:millisecond) do
          {tasks, busy}
        else
          {:ok, bot} = find(s.data, "bots", item["bot_id"])
          {:ok, session} = find(s.data, "sessions", item["session_id"])
          message = Enum.find(session["messages"], &(&1["id"] == item["message_id"]))

          task =
            Task.Supervisor.async_nolink(Nano.EvalSupervisor, fn ->
              s.runtime.deliver(bot, session, message, s.root)
            end)

          {Map.put(tasks, task.ref, item), MapSet.put(busy, pair)}
        end
      end)

    %{s | tasks: tasks}
  end

  defp relay_answers(s) do
    now = System.monotonic_time(:millisecond)

    delivered =
      Enum.reduce(s.data["requests"], s.delivered, fn r, delivered ->
        if r["status"] == "answered" and not r["acknowledged"] and
             now - Map.get(delivered, r["id"], now - s.answer_retry_ms) >= s.answer_retry_ms do
          case s.runtime.notify(r["requester"], {:vega_human_answer, r["id"], r["answer"]}) do
            :ok -> Map.put(delivered, r["id"], now)
            _ -> delivered
          end
        else
          delivered
        end
      end)

    %{s | delivered: delivered}
  end

  defp sync_statuses(s) do
    next =
      Enum.reduce(s.data["sessions"], s.data, fn session, d ->
        Enum.reduce(session["bot_ids"], d, fn bid, d ->
          case s.runtime.info(Vega.Bots.agent_name(bid, session["id"])) do
            %{halted: reason} when not is_nil(reason) ->
              put_status(
                d,
                session["id"],
                bid,
                "error",
                "The bot paused (#{reason}). Check connection or limits on the operator dashboard."
              )

            %{status: status} when status in [:thinking, :running_tool, :compacting] ->
              put_status(d, session["id"], bid, "thinking", "")

            %{status: :idle} ->
              {:ok, current} = find(d, "sessions", session["id"])

              awaiting =
                Enum.any?(
                  d["outbox"],
                  &(&1["session_id"] == session["id"] and &1["bot_id"] == bid and
                      &1["retry_at"] > 0)
                )

              if awaiting do
                put_status(
                  d,
                  session["id"],
                  bid,
                  "error",
                  "The bot finished without a visible reply. Retry to ask it again."
                )
              else
                if get_in(current, ["statuses", bid, "state"]) == "thinking",
                  do: put_status(d, session["id"], bid, "idle", ""),
                  else: d
              end

            _ ->
              d
          end
        end)
      end)

    if next == s.data, do: s, else: save_background(s, next, event("status"))
  end

  defp cache(table, data) do
    sessions =
      Enum.map(data["sessions"], fn s ->
        total = length(s["messages"])
        page = Enum.take(s["messages"], -80)

        history = %{
          "total" => total,
          "start" => max(0, total - 80),
          "has_more" => total > 80,
          "next_before" =>
            case page do
              [first | _] -> first["id"]
              _ -> nil
            end
        }

        :ets.insert(
          table,
          {{:session, s["id"]}, s |> Map.put("messages", page) |> Map.put("history", history)}
        )

        preview =
          Enum.map(
            Enum.take(s["messages"], -1),
            &Map.update!(&1, "text", fn text -> String.slice(text, 0, 512) end)
          )

        s |> Map.put("message_count", total) |> Map.put("messages", preview)
      end)

    requests =
      data["requests"]
      |> Enum.sort_by(fn r -> {r["status"] == "pending", r["created_at"]} end, :desc)
      |> Enum.take(200)

    public =
      data
      |> Map.take(~w(bots settings))
      |> Map.put("sessions", sessions)
      |> Map.put("requests", requests)
      |> Map.put("request_count", length(data["requests"]))
      |> Map.put("requests_truncated", length(data["requests"]) > 200)

    :ets.insert(table, {:snapshot, public})
  end

  @impl true
  def terminate(_, s) do
    :persistent_term.erase({__MODULE__, self()})
    Enum.each(s.tasks, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    :ok
  end

  defp save_background(s, next, e) do
    case persist(s, next) do
      :ok ->
        cache(s.table, next)
        Phoenix.PubSub.broadcast(Nano.PubSub, s.topic, {:vega_bots, e})
        %{s | data: next}

      _ ->
        s
    end
  end
end
