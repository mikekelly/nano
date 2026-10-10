defmodule Nano.Bots.Runtime do
  @moduledoc """
  Durable routing and human conduit, independent of harness logs.
  Start with name:, store:, state_dir:, pubsub: (nil disables), adapter: module.
  Adapter implements ensure(bot, session, opts), deliver(stable_name, batch),
  notify(stable_requester, term), status(name). Delivery is at-least-once; acknowledge
  delivery_id before responding. Cursor advances only on acknowledgment. Pages are
  bounded (default 50), never silently skip posts. Pending pages survive restart.
  Human answers arrive as {:bots_human_answer, %{request_id:, answer:, session_id:}};
  requester deduplicates by request_id and calls ack_human(id). Retry until acknowledged.
  Status events: {:bots, :runtime_status, %{session_id:, bot_id:, status:}}.
  Stop notices: {:bots, :runtime_notice, %{session_id:, epoch:, text:}}; notices are
  persisted in runtime state and available through notices/1 for UI reconciliation.
  """
  use GenServer
  alias Nano.Bots

  def start_link(opts \\ []) do
    if (opts[:adapter] || Nano.Bots.Agent) == Nano.Bots.Agent and Keyword.has_key?(opts, :name) and
         is_nil(opts[:name]) do
      {:error, :stable_runtime_name_required}
    else
      GenServer.start_link(
        __MODULE__,
        opts,
        if(opts[:name] == nil and Keyword.has_key?(opts, :name),
          do: [],
          else: [name: opts[:name] || __MODULE__]
        )
      )
    end
  end

  def post(session, bot, text, opts), do: call({:post, session, bot, text, opts}, opts)
  def ask_human(bot, text, opts), do: call({:ask, bot, text, opts}, opts)
  def ack_human(id, opts \\ []), do: call({:ack_human, id}, opts)
  def ack_delivery(id, opts \\ []), do: call({:ack, id}, opts)

  def finished(session, bot, opts),
    do: call({:finished, session, bot, opts[:epoch], opts[:delivery_id]}, opts)

  def reconcile(opts \\ []), do: call(:reconcile, opts)
  def notices(opts \\ []), do: call(:notices, opts)
  defp call(msg, opts), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), msg, 30_000)

  def init(opts) do
    adapter = opts[:adapter] || Nano.Bots.Agent

    if adapter == Nano.Bots.Agent and Keyword.has_key?(opts, :name) and is_nil(opts[:name]),
      do: raise(ArgumentError, "production bot adapter requires a stable registered runtime name")

    dir = opts[:state_dir] || Path.join(Application.fetch_env!(:nano, :state_dir), "bots-runtime")
    File.mkdir_p!(dir)
    path = Path.join(dir, "runtime.term")

    data =
      case File.read(path) do
        {:error, :enoent} ->
          %{cursors: %{}, routed: %{}, pending: %{}, selected: %{}, notices: []}

        {:ok, bytes} ->
          :erlang.binary_to_term(bytes, [:safe])

        {:error, why} ->
          raise File.Error, reason: why, action: "read", path: path
      end

    pubsub = Keyword.get(opts, :pubsub, Nano.PubSub)
    if pubsub, do: Phoenix.PubSub.subscribe(pubsub, "bots")

    data =
      data
      |> Map.put_new(:offsets, %{})
      |> Map.put_new(:turns, %{})
      |> Map.put_new(:routing_batches, %{})
      |> Map.put_new(:stop_intents, %{})
      |> Map.put_new(:agents, %{})

    state = %{
      data: data,
      path: path,
      store: opts[:store] || Nano.Bots.Store,
      pubsub: pubsub,
      adapter: opts[:adapter] || Nano.Bots.Agent,
      runtime: opts[:name] || __MODULE__,
      page_size: opts[:page_size] || 50,
      router_opts: opts[:router_opts] || [],
      retry_ms: opts[:retry_ms] || 1000,
      memory_opts: opts[:memory_opts] || [],
      agent_parent: opts[:agent_parent] || "bots-runtime-owner",
      sent: %{}
    }

    send(self(), :tick)
    {:ok, state}
  end

  def handle_call({:post, session, bot, text, opts}, _, s) do
    result =
      Bots.publish(
        session,
        %{
          actor: {:bot, bot},
          text: text,
          epoch: opts[:epoch],
          idempotency_key: opts[:idempotency_key],
          attachments: Keyword.get(opts, :attachments, [])
        },
        server: s.store
      )

    {:reply, result, s}
  end

  def handle_call({:ask, bot, text, opts}, _, s) do
    result =
      with {:ok, _} <- Bots.get_bot(bot, server: s.store),
           {:ok, session} <- human_session(s, bot, opts[:session_id]),
           do:
             Bots.request_human(
               %{bot_id: bot, session_id: session.id, requester: opts[:requester], text: text},
               server: s.store
             )

    {:reply, result, s}
  end

  def handle_call({:ack_human, id}, _, s), do: {:reply, Bots.ack_request(id, server: s.store), s}

  def handle_call({:ack, id}, _, s) do
    case s.data.pending[id] do
      nil ->
        {:reply, :ok, s}

      p ->
        d =
          s.data
          |> Map.put(:pending, Map.delete(s.data.pending, id))
          |> Map.put(:cursors, Map.put(s.data.cursors, p.key, p.batch.next_cursor))
          |> Map.put(
            :offsets,
            Map.put(s.data.offsets, p.key, Map.get(p.batch, :next_text_offset, 0))
          )

        {:reply, :ok, persist(%{s | data: d}) |> continue_delivery(p.key)}
    end
  end

  def handle_call({:finished, sid, bid, epoch, delivery_id}, _, s) do
    key = {sid, bid}

    d =
      if match?(%{epoch: ^epoch}, s.data.selected[key]) and
           is_binary(delivery_id) and s.data.turns[key] == delivery_id and
           s.data.selected[key].target <= Map.get(s.data.cursors, key, 0) and
           not Enum.any?(s.data.pending, fn {_, p} -> p.key == key end),
         do: %{s.data | selected: Map.delete(s.data.selected, key)},
         else: s.data

    if not Map.has_key?(d.selected, key), do: status(s, sid, bid, :idle)
    {:reply, :ok, persist(%{s | data: d})}
  end

  def handle_call(:notices, _, s), do: {:reply, {:ok, s.data.notices}, s}
  def handle_call(:reconcile, _, s), do: {:reply, :ok, run(s)}

  def handle_info(:tick, s) do
    s = run(s)
    Process.send_after(self(), :tick, s.retry_ms)
    {:noreply, s}
  end

  def handle_info({:bots, event, _}, s)
      when event in [:message_created, :session_stopped, :session_deleted, :request_answered],
      do: {:noreply, run(s)}

  def handle_info(:reconcile_once, s), do: {:noreply, run(s)}
  def handle_info(_, s), do: {:noreply, s}

  defp human_session(s, bot, nil) do
    {:ok, sessions} = Bots.list_sessions(server: s.store)

    case sessions
         |> Enum.filter(&(bot in &1.participant_ids and not &1.stopped))
         |> Enum.sort_by(& &1.created_at, :desc) do
      [latest | _] -> {:ok, latest}
      [] -> Bots.create_session(%{participant_ids: [bot]}, server: s.store)
    end
  end

  defp human_session(s, bot, id) do
    with {:ok, session} <- Bots.get_session(id, server: s.store),
         true <- bot in session.participant_ids and not session.stopped,
         do: {:ok, session},
         else: (_ -> {:error, :invalid_session})
  end

  defp run(s) do
    {:ok, sessions} = Bots.list_sessions(server: s.store)
    valid_ids = MapSet.new(Enum.map(sessions, & &1.id))

    d =
      Enum.reduce([:selected, :cursors, :offsets, :turns], s.data, fn field, d ->
        Map.put(
          d,
          field,
          Map.filter(d[field], fn {{sid, _}, _} -> MapSet.member?(valid_ids, sid) end)
        )
      end)

    d =
      Enum.reduce([:routed, :routing_batches, :stop_intents], d, fn field, d ->
        Map.put(d, field, Map.filter(d[field], fn {sid, _} -> MapSet.member?(valid_ids, sid) end))
      end)

    d = %{
      d
      | pending: Map.filter(d.pending, fn {_, p} -> MapSet.member?(valid_ids, elem(p.key, 0)) end)
    }

    s = persist(%{s | data: d})
    s = Enum.reduce(Map.values(s.data.stop_intents), s, &complete_stop(&2, &1))
    {:ok, sessions} = Bots.list_sessions(server: s.store)
    s = Enum.reduce(sessions, s, &route/2)
    retry_ids = MapSet.new(Map.keys(s.data.pending))
    now = System.monotonic_time(:millisecond)
    s = Enum.reduce(Map.keys(s.data.selected), s, &continue_delivery(&2, &1))

    attempts =
      Map.filter(s.data.pending, fn {id, p} ->
        MapSet.member?(retry_ids, id) and
          (not Map.has_key?(s.sent, id) or
             (now - s.sent[id] >= s.retry_ms and
                safe(fn -> s.adapter.status(p.name) end) != :thinking))
      end)

    Enum.each(attempts, fn {_, p} ->
      with {:ok, session} <- Bots.get_session(elem(p.key, 0), server: s.store),
           false <- session.stopped,
           true <- session.epoch == p.batch.epoch,
           {:ok, bot} <- Bots.get_bot(elem(p.key, 1), server: s.store),
           {:ok, _} <-
             safe(fn ->
               s.adapter.ensure(bot, session,
                 store: s.store,
                 runtime: s.runtime,
                 workspace_root: Path.join(Path.dirname(s.path), "workspaces"),
                 parent: s.agent_parent
               )
             end) do
        safe(fn -> s.adapter.deliver(p.name, p.batch) end)
      end

      st = safe(fn -> s.adapter.status(p.name) end)

      status(
        s,
        elem(p.key, 0),
        elem(p.key, 1),
        if(st in [:thinking, :idle, :error], do: st, else: :error)
      )
    end)

    sent = Map.filter(s.sent, fn {id, _} -> Map.has_key?(s.data.pending, id) end)
    sent = Enum.reduce(attempts, sent, fn {id, _}, sent -> Map.put(sent, id, now) end)
    s = %{s | sent: sent}

    Enum.each(s.data.selected, fn {{sid, bid}, _} ->
      with {:ok, session} <- Bots.get_session(sid, server: s.store),
           {:ok, bot} <- Bots.get_bot(bid, server: s.store),
           {:ok, name} <-
             safe(fn ->
               s.adapter.ensure(bot, session,
                 store: s.store,
                 runtime: s.runtime,
                 workspace_root: Path.join(Path.dirname(s.path), "workspaces"),
                 parent: s.agent_parent
               )
             end) do
        st = safe(fn -> s.adapter.status(name) end)
        status(s, sid, bid, if(st in [:thinking, :idle, :error], do: st, else: :error))
      else
        _ -> status(s, sid, bid, :error)
      end
    end)

    Enum.each(s.data.agents, fn {{sid, bid}, name} ->
      if function_exported?(s.adapter, :lifecycle, 1) and
           function_exported?(s.adapter, :ack_lifecycle, 1) do
        case safe(fn -> s.adapter.lifecycle(name) end) do
          events when is_list(events) ->
            Enum.each(events, fn event ->
              case event.delegation do
                :halted ->
                  broadcast(s, :runtime_status, %{
                    session_id: sid,
                    bot_id: bid,
                    status: :error,
                    error: :agent_halted
                  })

                :death ->
                  broadcast(s, :runtime_status, %{
                    session_id: sid,
                    bot_id: bid,
                    status: :error,
                    error: :agent_died
                  })

                _ ->
                  :ok
              end

              safe(fn -> s.adapter.ack_lifecycle(event.event_id) end)
            end)

          _ ->
            :ok
        end
      end
    end)

    {:ok, outbox} = Bots.outbox(server: s.store)

    Enum.each(outbox, fn r ->
      if safe(fn ->
           s.adapter.notify(
             r.requester,
             {:bots_human_answer,
              Map.take(r, [:session_id, :answer]) |> Map.put(:request_id, r.id)}
           )
         end) == :ok, do: Bots.mark_delivery(r.id, server: s.store)
    end)

    s
  end

  defp route(session, s) do
    sid = session.id
    # New epochs fence pending turns; the store independently fences publication.
    selected =
      Enum.reject(s.data.selected, fn {{id, _}, e} ->
        id == sid and (e.epoch != session.epoch or session.stopped)
      end)
      |> Map.new()

    if session.stopped do
      Enum.each(s.data.selected, fn {{id, bid}, _} ->
        if id == sid, do: status(s, sid, bid, :idle)
      end)
    end

    pending =
      Enum.reject(s.data.pending, fn {_, p} ->
        elem(p.key, 0) == sid and (p.batch.epoch != session.epoch or session.stopped)
      end)
      |> Map.new()

    s = persist(%{s | data: %{s.data | selected: selected, pending: pending}})
    cursor = Map.get(s.data.routed, sid, 0)
    {:ok, page} = Bots.list_messages(sid, server: s.store, after: cursor, limit: s.page_size)
    {:ok, latest} = Bots.get_session(sid, server: s.store)

    cond do
      latest.epoch != session.epoch or latest.exchange_count != session.exchange_count ->
        route(latest, s)

      page.messages == [] ->
        s

      session.stopped ->
        persist(%{s | data: %{s.data | routed: Map.put(s.data.routed, sid, page.next_cursor)}})

      session.exchange_count >= session.exchange_ceiling ->
        notice(s, session, :ceiling)

      page.has_more ->
        previous = Map.get(s.data.routing_batches, sid, %{epoch: session.epoch, human: false})

        previous =
          if previous.epoch == session.epoch,
            do: previous,
            else: %{epoch: session.epoch, human: false}

        batch = %{
          previous
          | human: previous.human or Enum.any?(page.messages, &(&1.actor == :human))
        }

        send(self(), :reconcile_once)

        persist(%{
          s
          | data: %{
              s.data
              | routed: Map.put(s.data.routed, sid, page.next_cursor),
                routing_batches: Map.put(s.data.routing_batches, sid, batch)
            }
        })

      true ->
        {:ok, context} =
          Bots.list_messages(sid,
            server: s.store,
            after: max(0, page.next_cursor - s.page_size),
            limit: s.page_size
          )

        bots =
          Enum.map(session.participant_ids, fn id ->
            {:ok, b} = Bots.get_bot(id, server: s.store)
            b
          end)

        # Routing includes recent context, but fallback is based on the new batch.
        opts =
          Keyword.put(
            s.router_opts,
            :human_batch,
            Enum.any?(page.messages, &(&1.actor == :human)) or
              (get_in(s.data.routing_batches, [sid, :epoch]) == session.epoch and
                 get_in(s.data.routing_batches, [sid, :human]) == true)
          )

        case Nano.Bots.Router.select(bots, session, context.messages, opts) do
          {:ok, ids} ->
            selected =
              Enum.reduce(
                ids,
                s.data.selected,
                &Map.put(&2, {sid, &1}, %{epoch: session.epoch, target: page.next_cursor})
              )

            persist(%{
              s
              | data: %{
                  s.data
                  | selected: selected,
                    routed: Map.put(s.data.routed, sid, page.next_cursor),
                    routing_batches: Map.delete(s.data.routing_batches, sid)
                }
            })

          {:stop, reason} ->
            notice(s, session, reason)
        end
    end
  end

  defp continue_delivery(s, {sid, bid} = key) do
    cond do
      not Map.has_key?(s.data.selected, key) ->
        s

      Enum.any?(s.data.pending, fn {_, p} -> p.key == key end) ->
        s

      true ->
        with {:ok, session} <- Bots.get_session(sid, server: s.store),
             false <- session.stopped,
             true <- session.epoch == s.data.selected[key].epoch,
             true <- Map.get(s.data.cursors, key, 0) < s.data.selected[key].target,
             {:ok, bot} <- Bots.get_bot(bid, server: s.store),
             {:ok, page} <-
               Bots.list_messages(sid,
                 server: s.store,
                 after: Map.get(s.data.cursors, key, 0),
                 limit: s.page_size
               ),
             true <- page.messages != [],
             {:ok, name} <-
               safe(fn ->
                 s.adapter.ensure(bot, session,
                   store: s.store,
                   runtime: s.runtime,
                   workspace_root: Path.join(Path.dirname(s.path), "workspaces"),
                   parent: s.agent_parent
                 )
               end),
             true <- is_binary(name) do
          id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

          messages = Enum.take_while(page.messages, &(&1.sequence <= s.data.selected[key].target))

          page = %{
            page
            | messages: messages,
              has_more: List.last(messages).sequence < s.data.selected[key].target
          }

          page =
            bound_page(page, Map.get(s.data.cursors, key, 0), Map.get(s.data.offsets, key, 0))

          batch =
            Map.merge(page, %{session_id: sid, bot_id: bid, epoch: session.epoch, delivery_id: id})

          query =
            batch.messages |> Enum.map(& &1.text) |> Enum.join("\n") |> String.slice(0, 3000)

          memories =
            if batch.has_more do
              []
            else
              case Nano.Bots.Memory.retrieve(
                     bid,
                     query,
                     Keyword.put(s.memory_opts, :server, s.store)
                   ) do
                {:ok, records} -> records
                _ -> []
              end
            end

          identity = Map.take(bot, [:id, :name, :face, :color, :voice, :description])

          identity = %{
            bot: identity,
            version:
              Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(identity)), case: :lower)
          }

          batch = batch |> Map.put(:memories, memories) |> Map.put(:identity, identity)
          p = %{key: key, name: name, batch: batch}

          s =
            persist(%{
              s
              | data: %{
                  s.data
                  | pending: Map.put(s.data.pending, id, p),
                    turns: Map.put(s.data.turns, key, id),
                    agents: Map.put(s.data.agents, key, name)
                }
            })

          status(s, sid, bid, :thinking)
          safe(fn -> s.adapter.deliver(name, batch) end)
          %{s | sent: Map.put(s.sent, id, System.monotonic_time(:millisecond))}
        else
          {:error, _} ->
            status(s, sid, bid, :error)
            s

          _ ->
            s
        end
    end
  end

  defp bound_page(page, cursor, offset) do
    first = hd(page.messages)

    if offset > 0 or byte_size(first.text) > 12_000 do
      text = String.slice(first.text, offset, 3000)
      next_offset = offset + String.length(text)
      more_text = next_offset < String.length(first.text)
      message = Map.merge(first, %{text: text, text_offset: offset, text_continues: more_text})

      %{
        page
        | messages: [message],
          next_cursor: if(more_text, do: cursor, else: first.sequence),
          has_more: more_text or length(page.messages) > 1 or page.has_more
      }
      |> Map.put(:next_text_offset, if(more_text, do: next_offset, else: 0))
    else
      {messages, _} =
        Enum.reduce_while(page.messages, {[], 0}, fn m, {acc, bytes} ->
          size = byte_size(inspect(m, limit: :infinity, printable_limit: :infinity))

          image_count =
            Enum.reduce(acc ++ [m], 0, fn message, n ->
              n + Enum.count(message.attachments, &String.starts_with?(&1, "image:"))
            end)

          if (bytes + size > 16_000 or image_count > 10) and acc != [],
            do: {:halt, {acc, bytes}},
            else: {:cont, {acc ++ [m], bytes + size}}
        end)

      %{
        page
        | messages: messages,
          next_cursor: List.last(messages).sequence,
          has_more: length(messages) < length(page.messages) or page.has_more
      }
    end
  end

  defp notice(s, session, reason) do
    text =
      if reason == :ceiling,
        do: "The bots have reached the conversation limit. Send a message to continue.",
        else: "The bots paused because routing is unavailable. Send a message to continue."

    n = %{session_id: session.id, epoch: session.epoch, text: text, reason: reason}

    if Enum.any?(s.data.notices, &(&1.session_id == session.id and &1.epoch == session.epoch)) do
      s
    else
      s =
        persist(%{
          s
          | data: %{s.data | stop_intents: Map.put(s.data.stop_intents, session.id, n)}
        })

      complete_stop(s, n)
    end
  end

  defp complete_stop(s, n) do
    {:ok, session} = Bots.get_session(n.session_id, server: s.store)

    result =
      if session.stopped and session.epoch == n.epoch + 1,
        do: {:ok, session},
        else: Bots.stop_session(n.session_id, expected_epoch: n.epoch, server: s.store)

    case result do
      {:ok, _} ->
        selected =
          Enum.reject(s.data.selected, fn {{sid, _}, _} -> sid == n.session_id end) |> Map.new()

        pending =
          Enum.reject(s.data.pending, fn {_, p} -> elem(p.key, 0) == n.session_id end)
          |> Map.new()

        s =
          persist(%{
            s
            | data: %{
                s.data
                | selected: selected,
                  pending: pending,
                  notices: Enum.take([n | s.data.notices], 200),
                  stop_intents: Map.delete(s.data.stop_intents, n.session_id)
              }
          })

        broadcast(s, :runtime_notice, n)
        s

      {:error, :stale_epoch} ->
        persist(%{
          s
          | data: %{s.data | stop_intents: Map.delete(s.data.stop_intents, n.session_id)}
        })

      _ ->
        s
    end
  end

  defp status(s, sid, bid, st),
    do: broadcast(s, :runtime_status, %{session_id: sid, bot_id: bid, status: st})

  defp broadcast(s, event, record) do
    if s.pubsub do
      Phoenix.PubSub.broadcast(s.pubsub, "bots", {:bots, event, record})

      Phoenix.PubSub.broadcast(
        s.pubsub,
        "bots:session:" <> record.session_id,
        {:bots, event, record}
      )
    end

    :ok
  end

  defp persist(s) do
    tmp = s.path <> ".tmp"
    {:ok, io} = :file.open(String.to_charlist(tmp), [:write, :binary, :raw])

    try do
      :ok = :file.write(io, :erlang.term_to_binary(s.data))
      :ok = :file.sync(io)
    after
      :file.close(io)
    end

    :ok = File.rename(tmp, s.path)
    s
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :adapter_error}
  catch
    _, _ -> {:error, :adapter_error}
  end
end
