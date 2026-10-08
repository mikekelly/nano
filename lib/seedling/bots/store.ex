defmodule Seedling.Bots.Store do
  @moduledoc false
  use GenServer
  alias Seedling.Bots.{Runtime, Gate}
  @colors ["#8b7bd8", "#67a99b", "#e0a164", "#668eb8", "#ca7da1"]

  def start_link(opts),
    do:
      GenServer.start_link(__MODULE__, opts,
        name: {:global, {__MODULE__, Path.expand(Keyword.fetch!(opts, :root))}}
      )

  def init(opts) do
    root = Path.expand(Keyword.fetch!(opts, :root))
    path = Path.join(root, "store.json")

    with :ok <- File.mkdir_p(root), {:ok, data} <- load(path) do
      state = %{
        root: root,
        path: path,
        data: data,
        runtime: opts[:runtime] || Runtime,
        gate: opts[:gate] || Gate,
        topic: "bots:" <> Base.url_encode64(:crypto.hash(:sha256, root), padding: false),
        statuses: %{}
      }

      Process.send_after(self(), :retry_answers, 1_000)
      {:ok, state}
    else
      error -> {:stop, error}
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, %{"version" => 1} = data} <- Jason.decode(bytes),
             true <- Seedling.Bots.Schema.valid?(data) do
          {:ok, data}
        else
          _ -> {:error, :invalid_store}
        end

      {:error, :enoent} ->
        {:ok,
         %{
           "version" => 1,
           "bots" => %{},
           "sessions" => %{},
           "memories" => %{},
           "requests" => %{},
           "attachments" => %{},
           "config" => %{}
         }}

      error ->
        error
    end
  end

  def handle_call(:topic, _, s), do: {:reply, {:ok, %{topic: s.topic}}, s}

  def handle_call({:snapshot, opts}, _, s) do
    sessions =
      s.data["sessions"]
      |> Map.values()
      |> Enum.sort_by(& &1["updated_at"], :desc)
      |> Enum.take(opts[:limit] || 200)
      |> include_session(s.data["sessions"][opts[:session]])
      |> Enum.map(fn session ->
        Map.drop(session, ["messages"])
        |> Map.put(
          "preview",
          String.slice(
            (List.last(session["messages"]) || %{})["text"] || "No messages yet",
            0,
            120
          )
        )
      end)

    requests =
      expire(s.data["requests"])
      |> Map.values()
      |> Enum.filter(fn r -> opts[:session] == nil or r["session"] == opts[:session] end)
      |> Enum.sort_by(& &1["created_at"], :desc)
      |> Enum.take(200)
      |> Enum.map(&Map.drop(&1, ["reply_to"]))

    {:reply,
     {:ok,
      %{
        bots: Map.values(s.data["bots"]),
        sessions: sessions,
        requests: requests,
        statuses: s.statuses,
        config: s.data["config"],
        truncated: map_size(s.data["sessions"]) > length(sessions),
        notice:
          if(map_size(s.data["sessions"]) > length(sessions),
            do: "Recent chats limited; increase snapshot limit up to 1000.",
            else: nil
          ),
        session_count: map_size(s.data["sessions"]),
        requests_truncated: map_size(s.data["requests"]) > length(requests),
        request_count: map_size(s.data["requests"]),
        requests_notice:
          if(map_size(s.data["requests"]) > length(requests),
            do: "Requests limited to latest 200; answer via the request id or open its session.",
            else: nil
          )
      }}, s}
  end

  def handle_call({:configure, config}, _, s) when is_map(config) do
    keys = ~w(model reasoning max_context max_turns max_tokens exchange_ceiling)
    c = Map.new(config, fn {k, v} -> {to_string(k), v} end)

    if Enum.all?(Map.keys(c), &(&1 in keys)) and valid_config?(c) do
      commit(s, put_in(s.data, ["config"], Map.merge(s.data["config"], c)), c)
    else
      fail(s, "Set model/reasoning strings and positive budgets; exchange_ceiling must be 1..50.")
    end
  end

  def handle_call({:configure, _}, _, s), do: fail(s, "Configuration must be a map.")

  def handle_call({:create_bot, name, opts}, _, s) do
    if text?(name, 80) and optional_text?(opts[:description], 500) and
         optional_text?(opts[:voice], 500) and map_size(s.data["bots"]) < 100 do
      bot = %{
        "id" => id(),
        "name" => String.trim(name),
        "description" => default_text(opts[:description], "A friendly, thoughtful helper"),
        "voice" => default_text(opts[:voice], "Warm, clear and honest. Ask when uncertain."),
        "color" => Enum.at(@colors, rem(map_size(s.data["bots"]), length(@colors))),
        "shape" => rem(map_size(s.data["bots"]), 3),
        "created_at" => now()
      }

      commit(s, put_in(s.data, ["bots", bot["id"]], bot), bot)
    else
      fail(s, "Give a name of 1–80 characters; at most 100 bots are supported.")
    end
  end

  def handle_call({:create_session, bots, title}, _, s) do
    if is_list(bots) and length(bots) in 1..8 and length(Enum.uniq(bots)) == length(bots) and
         Enum.all?(bots, &Map.has_key?(s.data["bots"], &1)) and
         map_size(s.data["sessions"]) < 1000 do
      session = new_session(s, bots, title)
      commit(s, put_in(s.data, ["sessions", session["id"]], session), session)
    else
      fail(s, "Choose 1–8 distinct existing bots; at most 1000 sessions are supported.")
    end
  end

  def handle_call({:history, sid, opts}, _, s) do
    with {:ok, session} <- session(s, sid) do
      limit = opts[:limit] || 100

      if is_integer(limit) and limit in 1..500 do
        messages = session["messages"]
        before = opts[:before]

        index =
          if before, do: Enum.find_index(messages, &(&1["id"] == before)), else: length(messages)

        if index do
          older = Enum.take(messages, index)
          selected = Enum.take(older, -limit)

          {:reply,
           {:ok,
            %{
              messages: selected,
              truncated: length(older) > limit,
              before: (List.first(selected) || %{})["id"],
              notice:
                if(length(older) > limit,
                  do: "Earlier messages available using before.",
                  else: nil
                )
            }}, s}
        else
          fail(s, "The before message does not belong to this session.")
        end
      else
        fail(s, "History limit must be 1..500.")
      end
    else
      {:error, e} -> fail(s, e)
    end
  end

  def handle_call({kind, sid, text, attachments}, _, s) when kind == :say do
    with {:ok, session} <- session(s, sid), :ok <- valid_message(s, text, attachments) do
      session =
        session
        |> Map.put("exchanges", 0)
        |> Map.put("paused", false)
        |> Map.update!("epoch", &(&1 + 1))

      msg = message("human", "You", text, attachments)
      {data, msg} = append(s.data, session, msg)
      commit(s, data, msg, {:route, sid, msg})
    else
      {:error, e} -> fail(s, e)
    end
  end

  def handle_call({:post, bid, sid, text, attachments}, {caller, _}, s) do
    with {:ok, session} <- session(s, sid),
         :ok <- participant(s, bid, session, caller),
         :ok <- valid_message(s, text, attachments) do
      cond do
        session["paused"] ->
          fail(s, "This conversation is stopped. Wait for the person to speak.")

        session["exchanges"] >= ceiling(s) ->
          fail(s, "Bot exchange ceiling reached. Wait for the person.")

        true ->
          msg = message(bid, s.data["bots"][bid]["name"], text, attachments)
          increment = if length(session["bots"]) > 1, do: 1, else: 0
          session = Map.update!(session, "exchanges", &(&1 + increment))
          {data, msg} = append(s.data, session, msg)
          data = maybe_ceiling(data, sid, ceiling(s))
          statuses = Map.put(s.statuses, {sid, bid}, "quiet")
          commit(%{s | statuses: statuses}, data, msg, {:route, sid, msg})
      end
    else
      {:error, e} -> fail(s, e)
    end
  end

  def handle_call({:quiet, bid, sid}, {caller, _}, s),
    do: set_status(s, bid, sid, caller, "quiet")

  def handle_call({:status, bid, sid, text}, {caller, _}, s) do
    if text?(text, 160),
      do: set_status(s, bid, sid, caller, text),
      else: fail(s, "Status must be 1–160 characters.")
  end

  def handle_call({:stop, sid}, _, s) do
    with {:ok, session} <- session(s, sid) do
      session = session |> Map.put("paused", true) |> Map.update!("epoch", &(&1 + 1))

      {data, msg} =
        append(
          s.data,
          session,
          message("system", "Conversation", "Paused. Send a message to continue.", [])
        )

      commit(%{s | statuses: Map.reject(s.statuses, fn {{id, _}, _} -> id == sid end)}, data, msg)
    else
      {:error, e} -> fail(s, e)
    end
  end

  def handle_call({:remember, bid, text, opts}, _, s) do
    tags = opts[:tags] || []
    memories = s.data["memories"][bid] || []

    if Map.has_key?(s.data["bots"], bid) and text?(text, 2000) and is_list(tags) and
         length(tags) <= 12 and Enum.all?(tags, &text?(&1, 80)) and length(memories) < 2000 do
      mem = %{
        "id" => id(),
        "text" => text,
        "tags" => tags,
        "at" => now(),
        "source_session" => opts[:session]
      }

      commit(s, put_in(s.data, ["memories", bid], memories ++ [mem]), mem)
    else
      fail(
        s,
        "Choose an existing bot, memory text of 1–2000 characters and up to 12 short tags; limit 2000 memories."
      )
    end
  end

  def handle_call({:memories, bid, query, opts}, from, s) do
    if Map.has_key?(s.data["bots"], bid) and text?(query, 2000) do
      limit = opts[:limit] || 5

      if is_integer(limit) and limit in 1..10 do
        candidates = relevant_candidates(s.data["memories"][bid] || [], query)

        gate = s.gate
        bot = s.data["bots"][bid]

        spawn(fn ->
          selected =
            try do
              apply(gate, :memories, [bot, %{"text" => query}, candidates, [limit: limit]])
            rescue
              _ -> []
            catch
              _, _ -> []
            end

          GenServer.reply(
            from,
            {:ok,
             %{
               memories: Enum.take(selected, limit),
               truncated: length(candidates) > length(selected),
               notice:
                 "Selective retrieval; at most #{limit} memories from 50 candidates, not the full memory store."
             }}
          )
        end)

        {:noreply, s}
      else
        fail(s, "Memory limit must be 1..10.")
      end
    else
      fail(s, "Choose an existing bot and a query of 1–2000 characters.")
    end
  end

  def handle_call({:forget, bid, mid}, _, s) do
    memories = s.data["memories"][bid] || []

    if Enum.any?(memories, &(&1["id"] == mid)),
      do:
        commit(
          s,
          put_in(s.data, ["memories", bid], Enum.reject(memories, &(&1["id"] == mid))),
          mid
        ),
      else: fail(s, "Memory not found.")
  end

  def handle_call({:preferences, sid, prefs}, _, s) do
    with {:ok, session} <- session(s, sid) do
      prefs = Map.new(prefs, fn {k, v} -> {to_string(k), v} end)
      prefs = Map.merge(session["notifications"], prefs)

      if is_boolean(prefs["enabled"]) and is_integer(prefs["per_hour"]) and
           prefs["per_hour"] in 0..30 and is_integer(prefs["cooldown_seconds"]) and
           prefs["cooldown_seconds"] in 0..86400 and
           Enum.all?(Map.keys(prefs), &(&1 in ~w(enabled per_hour cooldown_seconds))) do
        commit(s, put_in(s.data, ["sessions", sid, "notifications"], prefs), prefs)
      else
        fail(
          s,
          "Notification preferences: enabled boolean, per_hour 0..30, cooldown_seconds 0..86400."
        )
      end
    else
      {:error, e} -> fail(s, e)
    end
  end

  def handle_call({:ask, bid, question, opts, caller}, _, s) do
    target = opts[:reply_to] || caller
    encoded = encode_target(target)
    expiry = opts[:expires_in] || 86400

    if Map.has_key?(s.data["bots"], bid) and text?(question, 4000) and encoded != nil and
         is_integer(expiry) and expiry in 1..604_800 and
         (opts[:correlation] == nil or text?(opts[:correlation], 200)) do
      case request_session(s, bid, opts[:session]) do
        {:ok, session} ->
          req = %{
            "id" => id(),
            "bot" => bid,
            "session" => session["id"],
            "question" => question,
            "reply_to" => encoded,
            "correlation" => opts[:correlation],
            "state" => "pending",
            "expires_at" => now() + expiry * 1000,
            "created_at" => now()
          }

          msg =
            message(bid, s.data["bots"][bid]["name"], question, [])
            |> Map.put("request", req["id"])

          {data, msg} = append(s.data, session, msg)
          public = req |> Map.put("message", msg["id"]) |> Map.put("notify", msg["notify"])
          commit(s, put_in(data["requests"][req["id"]], req), public)

        {:error, e} ->
          fail(s, e)
      end
    else
      fail(
        s,
        "Choose an existing bot, question <=4000 characters, named agent/pid reply target, short correlation and expiry 1..604800 seconds."
      )
    end
  end

  def handle_call({:answer, rid, text}, _, s) do
    req = expire(s.data["requests"])[rid]

    cond do
      not text?(text, 4000) ->
        fail(s, "Answer must be 1–4000 characters.")

      req == nil ->
        fail(s, "Request not found.")

      req["state"] != "pending" ->
        fail(s, "This request is #{req["state"]}; it cannot be answered again.")

      true ->
        req =
          req
          |> Map.put("state", "answered")
          |> Map.put("answer", text)
          |> Map.put("answered_at", now())

        msg = message("human", "You", text, []) |> Map.put("answer_to", rid)

        sess =
          s.data["sessions"][req["session"]]
          |> Map.put("exchanges", 0)
          |> Map.put("paused", false)
          |> Map.update!("epoch", &(&1 + 1))

        {data, msg} = append(s.data, sess, msg)

        commit(
          s,
          put_in(data["requests"][rid], req),
          Map.drop(req, ["reply_to"]),
          {:answer, req, msg}
        )
    end
  end

  def handle_call({action, rid}, {caller, _}, s) when action in [:cancel, :ack] do
    req = s.data["requests"][rid]

    cond do
      req == nil ->
        fail(s, "Request not found.")

      action == :ack and req["state"] != "answered" ->
        fail(s, "Only an answered request can be acknowledged.")

      action == :ack and not reply_caller?(caller, req["reply_to"]) ->
        fail(s, "Only the reply recipient can acknowledge.")

      action == :cancel and req["state"] != "pending" ->
        fail(s, "Only a pending request can be cancelled.")

      true ->
        commit(
          s,
          put_in(
            s.data,
            ["requests", rid, "state"],
            if(action == :ack, do: "delivered", else: "cancelled")
          ),
          rid
        )
    end
  end

  def handle_call({:attach, path, name}, _, s) do
    with true <- text?(name, 180),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 10_000_000 <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      if byte_size(bytes) <= 10_000_000 and map_size(s.data["attachments"]) < 10000 do
        aid = id()
        dir = Path.join(s.root, "attachments")

        attachment = %{
          "id" => aid,
          "name" => Path.basename(name),
          "bytes" => byte_size(bytes),
          "type" => mime(bytes)
        }

        with :ok <- File.mkdir_p(dir), :ok <- File.write(Path.join(dir, aid), bytes) do
          attachment = preview(attachment, bytes)
          commit(s, put_in(s.data, ["attachments", aid], attachment), attachment)
        else
          _ -> fail(s, "Cannot save attachment. Check storage permissions.")
        end
      else
        fail(s, "Attachment limit: 10 MB per file, 10000 files.")
      end
    else
      _ -> fail(s, "Choose a regular file of at most 10 MB and a short filename.")
    end
  end

  def handle_call({:attachment, aid}, _, s) do
    case s.data["attachments"][aid] do
      nil -> fail(s, "Attachment not found.")
      item -> {:reply, {:ok, Map.put(item, "path", Path.join([s.root, "attachments", aid]))}, s}
    end
  end

  def handle_call({:claim, sid, bid, epoch}, _, s) do
    sess = s.data["sessions"][sid]

    if sess && sess["epoch"] == epoch && not sess["paused"] && sess["exchanges"] < ceiling(s) do
      s = %{s | statuses: Map.put(s.statuses, {sid, bid}, "thinking")}
      broadcast(s, %{kind: :status})
      {:reply, :ok, s}
    else
      {:reply, :stale, s}
    end
  end

  def handle_info({:route, sid, msg}, s) do
    sess = s.data["sessions"][sid]

    s =
      if sess && not sess["paused"] do
        statuses =
          Enum.reduce(sess["bots"], s.statuses, fn bid, statuses ->
            if bid != msg["from"] and statuses[{sid, bid}] in [nil, "quiet"],
              do: Map.put(statuses, {sid, bid}, "Considering whether to respond"),
              else: statuses
          end)

        s = %{s | statuses: statuses}
        broadcast(s, %{kind: :status})
        store = self()

        for bid <- sess["bots"], bid != msg["from"] do
          bot = s.data["bots"][bid]
          candidates = relevant_candidates(s.data["memories"][bid] || [], msg["text"])
          runtime = s.runtime
          gate = s.gate
          config = s.data["config"]
          root = s.root

          spawn(fn ->
            try do
              decision = gate.reply?(bot, sess, msg)

              if decision and GenServer.call(store, {:claim, sid, bid, sess["epoch"]}) == :ok do
                memories = gate.memories(bot, msg, Enum.take(candidates, 30)) |> Enum.take(5)
                result = runtime.deliver(bot, sess, msg, memories, config, root)
                send(store, {:routed, sid, bid, sess["epoch"], result})
              else
                if not decision, do: send(store, {:routed, sid, bid, sess["epoch"], :quiet})
              end
            rescue
              _ ->
                send(
                  store,
                  {:routed, sid, bid, sess["epoch"], {:error, "Routing unavailable; try again."}}
                )
            catch
              _, _ ->
                send(
                  store,
                  {:routed, sid, bid, sess["epoch"], {:error, "Routing unavailable; try again."}}
                )
            end
          end)
        end

        s
      else
        s
      end

    {:noreply, s}
  end

  def handle_info({:routed, sid, bid, epoch, :quiet}, s) do
    if s.data["sessions"][sid]["epoch"] == epoch and
         s.statuses[{sid, bid}] == "Considering whether to respond" do
      s = %{s | statuses: Map.put(s.statuses, {sid, bid}, "quiet")}
      broadcast(s, %{kind: :status})
      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  def handle_info({:routed, sid, bid, epoch, {:error, error}}, s) do
    if s.data["sessions"][sid]["epoch"] == epoch do
      s = %{
        s
        | statuses:
            Map.put(
              s.statuses,
              {sid, bid},
              "Unable to reply: " <> String.slice(to_string(error), 0, 180)
            )
      }

      broadcast(s, %{kind: :status})
      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  def handle_info({:routed, _, _, _, _}, s), do: {:noreply, s}

  def handle_info(:retry_answers, s) do
    for {_, r} <- s.data["requests"], r["state"] == "answered", do: deliver_answer(r)
    Process.send_after(self(), :retry_answers, 30_000)
    {:noreply, s}
  end

  defp commit(s, data, result, after_message \\ nil) do
    tmp = s.path <> ".tmp"

    with {:ok, json} <- Jason.encode(data),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, s.path) do
      s = %{s | data: data}
      broadcast(s, %{kind: :changed, result: public_event(result)})

      case after_message do
        {:route, sid, msg} ->
          send(self(), {:route, sid, msg})

        {:answer, req, msg} ->
          deliver_answer(req)
          send(self(), {:route, req["session"], msg})

        _ ->
          :ok
      end

      {:reply, {:ok, result}, s}
    else
      _ ->
        fail(
          s,
          "Cannot persist bots state. Check disk space and permissions; nothing was accepted."
        )
    end
  end

  defp public_event(%{"reply_to" => _} = r), do: Map.drop(r, ["reply_to"])
  defp public_event(r), do: r
  defp broadcast(s, event), do: Phoenix.PubSub.broadcast(Nano.PubSub, s.topic, {:bots, event})
  defp include_session(sessions, nil), do: sessions

  defp include_session(sessions, session),
    do:
      if(Enum.any?(sessions, &(&1["id"] == session["id"])),
        do: sessions,
        else: sessions ++ [session]
      )

  defp fail(s, text), do: {:reply, {:error, text}, s}
  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp now, do: System.system_time(:millisecond)

  defp text?(v, max),
    do:
      is_binary(v) and String.valid?(v) and String.trim(v) != "" and String.length(v) <= max and
        byte_size(v) <= max * 4

  defp optional_text?(nil, _), do: true
  defp optional_text?("", _), do: true
  defp optional_text?(value, limit), do: text?(value, limit)

  defp default_text(value, default),
    do: if(is_binary(value) and String.trim(value) != "", do: value, else: default)

  defp ceiling(s), do: s.data["config"]["exchange_ceiling"] || 8

  defp valid_config?(c) do
    Enum.all?(c, fn
      {k, v} when k in ["model", "reasoning"] -> text?(v, 160)
      {"exchange_ceiling", v} -> is_integer(v) and v in 1..50
      {_, v} -> is_integer(v) and v > 0
    end)
  end

  defp session(s, id) do
    case s.data["sessions"][id] do
      nil -> {:error, "Session not found."}
      sess -> {:ok, sess}
    end
  end

  defp new_session(s, bots, title) do
    %{
      "id" => id(),
      "bots" => bots,
      "title" =>
        if(text?(title, 120),
          do: title,
          else: Enum.map_join(bots, ", ", &s.data["bots"][&1]["name"])
        ),
      "messages" => [],
      "created_at" => now(),
      "updated_at" => now(),
      "exchanges" => 0,
      "epoch" => 0,
      "paused" => false,
      "notifications" => %{"enabled" => false, "per_hour" => 3, "cooldown_seconds" => 60},
      "notification_times" => []
    }
  end

  defp message(from, name, text, attachments),
    do: %{
      "id" => id(),
      "from" => from,
      "name" => name,
      "text" => text,
      "attachments" => attachments,
      "at" => now(),
      "notify" => false
    }

  defp append(data, session, msg) do
    msg = Map.put(msg, "session", session["id"])
    {session, msg} = notification(session, msg)

    session =
      session |> Map.update!("messages", &(&1 ++ [msg])) |> Map.put("updated_at", msg["at"])

    {put_in(data["sessions"][session["id"]], session), msg}
  end

  defp notification(session, msg) do
    prefs = session["notifications"]
    times = Enum.filter(session["notification_times"], &(&1 > now() - 3600_000))

    allowed =
      msg["from"] not in ["human", "system"] and prefs["enabled"] and
        length(times) < prefs["per_hour"] and
        (times == [] or now() - List.last(times) >= prefs["cooldown_seconds"] * 1000)

    {Map.put(session, "notification_times", if(allowed, do: times ++ [now()], else: times)),
     Map.put(msg, "notify", allowed)}
  end

  defp maybe_ceiling(data, sid, ceiling) do
    sess = data["sessions"][sid]

    if sess["exchanges"] >= ceiling do
      sess = Map.put(sess, "paused", true)

      {data, _} =
        append(
          data,
          sess,
          message(
            "system",
            "Conversation",
            "Bot exchange limit reached. Send a message to continue.",
            []
          )
        )

      data
    else
      data
    end
  end

  defp participant(s, bid, session, caller) do
    if bid in session["bots"] and s.runtime.authorized?(caller, bid, session["id"], s.root),
      do: :ok,
      else: {:error, "Only this bot's session agent may post as it."}
  end

  defp set_status(s, bid, sid, caller, text) do
    with {:ok, sess} <- session(s, sid), :ok <- participant(s, bid, sess, caller) do
      s = %{s | statuses: Map.put(s.statuses, {sid, bid}, text)}
      broadcast(s, %{kind: :status})
      {:reply, {:ok, text}, s}
    else
      {:error, e} -> fail(s, e)
    end
  end

  defp valid_message(s, text, attachments) do
    cond do
      not text?(text, 8000) ->
        {:error, "Message must be 1–8000 characters (32 KB)."}

      not is_list(attachments) or length(attachments) > 5 ->
        {:error, "Attach at most five files."}

      not Enum.all?(attachments, &Map.has_key?(s.data["attachments"], &1)) ->
        {:error, "An attachment was not found; upload it first."}

      true ->
        :ok
    end
  end

  defp relevant_candidates(memories, query) do
    words =
      query
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) > 2))
      |> MapSet.new()

    memories
    |> Enum.map(fn m ->
      terms =
        (m["text"] <> " " <> Enum.join(m["tags"], " "))
        |> String.downcase()
        |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
        |> MapSet.new()

      {MapSet.intersection(words, terms) |> MapSet.size(), m}
    end)
    |> Enum.sort_by(fn {score, m} -> {score, m["at"]} end, :desc)
    |> Enum.take(50)
    |> Enum.map(&elem(&1, 1))
  end

  defp request_session(s, bid, nil) do
    case s.data["sessions"]
         |> Map.values()
         |> Enum.filter(&(bid in &1["bots"]))
         |> Enum.max_by(& &1["updated_at"], fn -> nil end) do
      nil -> {:ok, new_session(s, [bid], nil)}
      sess -> {:ok, sess}
    end
  end

  defp request_session(s, bid, sid) do
    with {:ok, sess} <- session(s, sid) do
      if bid in sess["bots"],
        do: {:ok, sess},
        else: {:error, "Requested bot is not in that session."}
    end
  end

  defp encode_target({:agent, name}) when is_binary(name),
    do: %{"kind" => "agent", "name" => name}

  defp encode_target(pid) when is_pid(pid), do: %{"kind" => "pid", "pid" => inspect(pid)}
  defp encode_target(_), do: nil
  defp target_pid(%{"kind" => "agent", "name" => name}), do: NanoAgent.whereis(name)

  defp target_pid(%{"kind" => "pid", "pid" => pid}) do
    try do
      parsed = pid |> String.trim_leading("#PID") |> String.to_charlist() |> :erlang.list_to_pid()
      if Process.alive?(parsed), do: parsed, else: nil
    rescue
      _ -> nil
    end
  end

  defp reply_caller?(caller, %{"kind" => "agent", "name" => name}),
    do: Runtime.authorized_agent?(caller, name)

  defp reply_caller?(caller, target), do: Runtime.caller?(caller, target_pid(target))

  defp deliver_answer(req) do
    if pid = target_pid(req["reply_to"]),
      do: send(pid, {:bots_human_answer, req["id"], req["correlation"], req["answer"]})
  end

  defp expire(requests),
    do:
      Map.new(requests, fn {id, r} ->
        {id,
         if(r["state"] == "pending" and r["expires_at"] < now(),
           do: Map.put(r, "state", "expired"),
           else: r
         )}
      end)

  defp preview(attachment, bytes) do
    if attachment["type"] in ["image/png", "image/jpeg"] and Code.ensure_loaded?(Seedling.Images) do
      case apply(Seedling.Images, :store, [bytes]) do
        {:ok, ref} ->
          Map.put(attachment, "image", ref)

        {:error, _} ->
          Map.put(
            attachment,
            "image_notice",
            "Image cannot be previewed or sent to vision; use download."
          )
      end
    else
      attachment
    end
  end

  defp mime(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: "image/png"
  defp mime(<<255, 216, 255, _::binary>>), do: "image/jpeg"
  defp mime(<<"%PDF-", _::binary>>), do: "application/pdf"

  defp mime(bytes),
    do:
      if(String.valid?(bytes) and not String.contains?(bytes, <<0>>),
        do: "text/plain",
        else: "application/octet-stream"
      )
end
