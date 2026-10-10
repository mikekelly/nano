defmodule Nano.Bots.Store do
  @moduledoc """
  Serialized atomic snapshot store. Start with name: (default this module, nil allowed),
  store_dir: (default configured state_dir/bots), pubsub: (default Nano.PubSub, nil
  disables), notify: {module, function}. Snapshot is synced then renamed atomically;
  incomplete .tmp writes are ignored at recovery. Corrupt committed snapshots fail
  startup explicitly, never silently replace data. Only trusted local term files.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(
      __MODULE__,
      opts,
      if(opts[:name] == nil and Keyword.has_key?(opts, :name),
        do: [],
        else: [name: opts[:name] || __MODULE__]
      )
    )
  end

  def init(opts) do
    dir = opts[:store_dir] || Path.join(Application.fetch_env!(:nano, :state_dir), "bots")
    path = Path.join(dir, "domain.term")

    with :ok <- File.mkdir_p(dir), {:ok, data} <- load(path) do
      {:ok,
       %{
         data: data,
         path: path,
         pubsub: Keyword.get(opts, :pubsub, Nano.PubSub),
         notify: opts[:notify]
       }}
    else
      error -> {:stop, error}
    end
  end

  defp load(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok,
         %{version: 1, bots: %{}, sessions: %{}, messages: %{}, requests: %{}, memories: %{}}}

      {:ok, bytes} ->
        try do
          case :erlang.binary_to_term(bytes, [:safe]) do
            %{version: 1, bots: b, sessions: s, messages: m, requests: r, memories: mm} = data
            when is_map(b) and is_map(s) and is_map(m) and is_map(r) and is_map(mm) ->
              {:ok, data}

            _ ->
              {:error, :corrupt_snapshot}
          end
        rescue
          _ -> {:error, :corrupt_snapshot}
        end

      error ->
        error
    end
  end

  def handle_call({op, args}, _from, state) do
    case execute(op, args, state.data) do
      {:read, reply} ->
        {:reply, reply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:write, record, data, events} ->
        case persist(state.path, data) do
          :ok ->
            Enum.each(events, &emit(state, &1))
            {:reply, {:ok, record}, %{state | data: data}}

          {:error, reason} ->
            {:reply, {:error, {:storage, reason}}, state}
        end
    end
  end

  defp persist(path, data) do
    tmp = path <> ".tmp"

    with {:ok, io} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw]) do
      result =
        with :ok <- :file.write(io, :erlang.term_to_binary(data)), :ok <- :file.sync(io), do: :ok

      :file.close(io)
      with :ok <- result, do: File.rename(tmp, path)
    end
  end

  defp emit(state, {event, record}) do
    message = {:bots, event, record}

    if state.pubsub do
      try do
        Phoenix.PubSub.broadcast(state.pubsub, "bots", message)

        session_id =
          record[:session_id] ||
            if(event in [:session_created, :session_updated, :session_deleted, :session_stopped],
              do: record.id
            )

        if session_id,
          do: Phoenix.PubSub.broadcast(state.pubsub, "bots:session:" <> session_id, message)
      rescue
        _ -> :ok
      end
    end

    if state.notify do
      try do
        {m, f} = state.notify
        apply(m, f, [message])
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  defp record(attrs),
    do:
      Map.merge(attrs, %{
        id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        created_at: System.system_time(:millisecond)
      })

  defp text?(t), do: is_binary(t) and String.trim(t) != "" and byte_size(t) <= 100_000
  defp valid?(attrs), do: is_map(attrs) and durable?(attrs)
  defp durable?(v) when is_pid(v) or is_reference(v) or is_function(v) or is_port(v), do: false
  defp durable?(v) when is_map(v), do: Enum.all?(v, fn {k, x} -> durable?(k) and durable?(x) end)
  defp durable?(v) when is_list(v), do: Enum.all?(v, &durable?/1)
  defp durable?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&durable?/1)
  defp durable?(_), do: true

  defp fetch(data, table, id) do
    case Map.fetch(data[table], id) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, :not_found}
    end
  end

  defp put(data, table, r), do: put_in(data, [table, r.id], r)
  defp write(data, table, r, event), do: {:write, r, put(data, table, r), [{event, r}]}
  defp sorted(table), do: Enum.sort_by(Map.values(table), &{&1.created_at, &1.id})

  defp execute(:create_bot, [a], d) do
    if valid?(a) and text?(a[:name]) do
      r =
        record(
          Map.merge(
            %{face: "circle", color: "#7c83fd", description: "", voice: ""},
            Map.take(a, [:name, :face, :color, :description, :voice])
          )
        )

      if Enum.all?([:face, :color, :description, :voice], &is_binary(r[&1])),
        do: write(d, :bots, r, :bot_created),
        else: {:error, :invalid}
    else
      {:error, :invalid}
    end
  end

  defp execute(:create_session, [a], d) do
    ids = if is_map(a), do: a[:participant_ids], else: nil
    ceiling = if is_map(a), do: Map.get(a, :exchange_ceiling, 12), else: nil

    if valid?(a) and is_list(ids) and ids != [] and Enum.uniq(ids) == ids and
         Enum.all?(ids, &Map.has_key?(d.bots, &1)) and is_integer(ceiling) and ceiling > 0 and
         is_binary(Map.get(a, :title, "")) and is_map(Map.get(a, :notification_prefs, %{})) do
      r =
        record(%{
          participant_ids: ids,
          title: Map.get(a, :title, ""),
          epoch: 0,
          stopped: false,
          exchange_count: 0,
          exchange_ceiling: ceiling,
          notification_prefs: Map.get(a, :notification_prefs, %{})
        })

      write(d, :sessions, r, :session_created)
    else
      {:error, :invalid}
    end
  end

  defp execute(op, [id], d) when op in [:get_bot, :get_session, :get_request] do
    table = %{get_bot: :bots, get_session: :sessions, get_request: :requests}[op]
    {:read, fetch(d, table, id)}
  end

  defp execute(op, [], d) when op in [:list_bots, :list_sessions, :list_requests, :outbox] do
    table =
      %{list_bots: :bots, list_sessions: :sessions, list_requests: :requests, outbox: :requests}[
        op
      ]

    list = sorted(d[table])

    {:read,
     {:ok, if(op == :outbox, do: Enum.filter(list, &(&1.status == :answered)), else: list)}}
  end

  defp execute(op, [id, a], d) when op in [:update_bot, :update_session, :update_memory] do
    {table, event, keys} =
      %{
        update_bot: {:bots, :bot_updated, [:name, :face, :color, :description, :voice]},
        update_session:
          {:sessions, :session_updated, [:title, :notification_prefs, :exchange_ceiling]},
        update_memory: {:memories, :memory_updated, [:text, :provenance]}
      }[op]

    with {:ok, r} <- fetch(d, table, id) do
      cond do
        not valid?(a) ->
          {:error, :invalid}

        Map.has_key?(a, :id) ->
          {:error, :immutable_id}

        Enum.any?(Map.keys(a), &(&1 not in keys)) ->
          {:error, :invalid}

        true ->
          updated = Map.merge(r, a)

          good =
            case table do
              :bots ->
                text?(updated.name) and
                  Enum.all?([:face, :color, :description, :voice], &is_binary(updated[&1]))

              :sessions ->
                is_binary(updated.title) and is_map(updated.notification_prefs) and
                  is_integer(updated.exchange_ceiling) and updated.exchange_ceiling > 0

              :memories ->
                text?(updated.text) and is_map(updated.provenance)
            end

          if good, do: write(d, table, updated, event), else: {:error, :invalid}
      end
    end
  end

  defp execute(op, [id], d) when op in [:delete_bot, :delete_session, :delete_memory] do
    {table, event} =
      %{
        delete_bot: {:bots, :bot_deleted},
        delete_session: {:sessions, :session_deleted},
        delete_memory: {:memories, :memory_deleted}
      }[op]

    with {:ok, r} <- fetch(d, table, id) do
      if table == :bots and Enum.any?(Map.values(d.sessions), &(id in &1.participant_ids)) do
        {:error, :in_use}
      else
        data = Map.update!(d, table, &Map.delete(&1, id))

        data =
          if table == :sessions,
            do: %{
              data
              | messages: Map.reject(data.messages, fn {_, m} -> m.session_id == id end),
                requests: Map.reject(data.requests, fn {_, q} -> q.session_id == id end)
            },
            else: data

        data =
          if table == :bots,
            do: %{data | memories: Map.reject(data.memories, fn {_, m} -> m.bot_id == id end)},
            else: data

        {:write, r, data, [{event, r}]}
      end
    end
  end

  defp execute(:stop_session, [id], d), do: execute(:stop_session, [id, :error], d)

  defp execute(:stop_session, [id, expected], d) do
    with {:ok, s} <- fetch(d, :sessions, id) do
      case expected do
        {:ok, epoch} when not is_integer(epoch) or epoch < 0 -> {:error, :invalid}
        {:ok, epoch} when epoch != s.epoch -> {:error, :stale_epoch}
        _ -> write(d, :sessions, %{s | stopped: true, epoch: s.epoch + 1}, :session_stopped)
      end
    end
  end

  defp execute(op, [id, a], d) when op in [:post_human, :publish] do
    with {:ok, s} <- fetch(d, :sessions, id) do
      if valid?(a) and text?(a[:text]) and is_binary(a[:idempotency_key]) and
           a[:idempotency_key] != "" and is_list(Map.get(a, :attachments, [])) and
           Enum.all?(Map.get(a, :attachments, []), &is_binary/1) do
        actor = if op == :post_human, do: :human, else: a[:actor]

        old =
          Enum.find(
            Map.values(d.messages),
            &(&1.session_id == id and &1.idempotency_key == a.idempotency_key)
          )

        cond do
          String.starts_with?(a.idempotency_key, ["request-answer:", "request-question:"]) ->
            {:error, :reserved_key}

          old != nil ->
            same =
              old.actor == actor and old.text == a.text and
                old.attachments == Map.get(a, :attachments, []) and
                (op == :post_human or old.epoch == a[:epoch])

            if same, do: {:read, {:ok, old}}, else: {:error, :idempotency_conflict}

          op == :publish and a[:epoch] != s.epoch ->
            {:error, :stale_epoch}

          op == :publish and s.stopped ->
            {:error, :stopped}

          op == :publish and
              not (is_tuple(actor) and tuple_size(actor) == 2 and elem(actor, 0) == :bot and
                       elem(actor, 1) in s.participant_ids) ->
            {:error, :invalid_actor}

          op == :publish and s.exchange_count >= s.exchange_ceiling ->
            {:error, :exchange_ceiling}

          true ->
            s =
              if op == :post_human,
                do: %{s | epoch: s.epoch + 1, stopped: false, exchange_count: 0},
                else: %{s | exchange_count: s.exchange_count + 1}

            sequence =
              Enum.reduce(Map.values(d.messages), 0, fn m, n ->
                if m.session_id == id, do: max(m.sequence, n), else: n
              end) + 1

            r =
              record(%{
                session_id: id,
                sequence: sequence,
                actor: actor,
                text: a.text,
                attachments: Map.get(a, :attachments, []),
                epoch: s.epoch,
                idempotency_key: a.idempotency_key
              })

            {:write, r, d |> put(:sessions, s) |> put(:messages, r), [{:message_created, r}]}
        end
      else
        {:error, :invalid}
      end
    end
  end

  defp execute(:list_messages, [id, opts], d) do
    with {:ok, _} <- fetch(d, :sessions, id) do
      cursor = Keyword.get(opts, :after, 0)
      limit = Keyword.get(opts, :limit, 50)
      tail = Keyword.get(opts, :tail, false)
      before = Keyword.get(opts, :before)

      valid =
        is_integer(cursor) and cursor >= 0 and is_integer(limit) and limit in 1..200 and
          is_boolean(tail) and
          (before == nil or (tail and is_integer(before) and before > 0)) and
          not (tail and Keyword.has_key?(opts, :after))

      if valid do
        list =
          d.messages
          |> Map.values()
          |> Enum.filter(fn m ->
            m.session_id == id and
              if(tail, do: before == nil or m.sequence < before, else: m.sequence > cursor)
          end)
          |> Enum.sort_by(& &1.sequence)

        page = Enum.take(list, if(tail, do: -limit, else: limit))

        {:read,
         {:ok,
          %{
            messages: page,
            next_cursor: if(page == [], do: cursor, else: List.last(page).sequence),
            has_more: length(list) > limit
          }}}
      else
        {:error, :invalid}
      end
    end
  end

  defp execute(:request_human, [a], d) do
    if valid?(a) and text?(a[:requester]) and text?(a[:text]) do
      with {:ok, s} <- fetch(d, :sessions, a[:session_id]),
           {:ok, _} <- fetch(d, :bots, a[:bot_id]) do
        if a.bot_id in s.participant_ids do
          r =
            record(
              Map.merge(Map.take(a, [:bot_id, :session_id, :requester, :text]), %{
                status: :pending,
                answer: nil,
                delivery_attempts: 0
              })
            )

          write(d, :requests, r, :request_created)
        else
          {:error, :invalid}
        end
      end
    else
      {:error, :invalid}
    end
  end

  defp execute(:answer_request, [id, text], d) do
    with {:ok, q} <- fetch(d, :requests, id) do
      cond do
        not text?(text) ->
          {:error, :invalid}

        q.status != :pending ->
          if q.answer == text, do: {:read, {:ok, q}}, else: {:error, :already_answered}

        true ->
          with {:ok, s} <- fetch(d, :sessions, q.session_id) do
            s = %{s | epoch: s.epoch + 1, stopped: false, exchange_count: 0}

            m =
              record(%{
                session_id: s.id,
                sequence: next_sequence(d, s.id),
                actor: :human,
                text: text,
                attachments: [],
                epoch: s.epoch,
                idempotency_key: "request-answer:" <> id,
                request_id: id
              })

            q = %{q | status: :answered, answer: text} |> Map.put(:answer_message_id, m.id)

            {:write, q, d |> put(:sessions, s) |> put(:messages, m) |> put(:requests, q),
             [{:message_created, m}, {:request_answered, q}]}
          end
      end
    end
  end

  defp execute(op, [id], d) when op in [:mark_delivery, :ack_request] do
    with {:ok, q} <- fetch(d, :requests, id) do
      cond do
        q.status == :pending ->
          {:error, :not_answered}

        q.status == :acked ->
          {:read, {:ok, q}}

        op == :mark_delivery ->
          write(
            d,
            :requests,
            %{q | delivery_attempts: q.delivery_attempts + 1},
            :request_delivery
          )

        true ->
          write(d, :requests, %{q | status: :acked}, :request_acked)
      end
    end
  end

  defp execute(:create_memory, [bot, a], d) do
    with {:ok, _} <- fetch(d, :bots, bot) do
      if valid?(a) and text?(a[:text]) and is_map(a[:provenance]) do
        sequence =
          Enum.reduce(Map.values(d.memories), 0, fn m, n -> max(Map.get(m, :sequence, 0), n) end) +
            1

        r = record(%{bot_id: bot, text: a.text, provenance: a.provenance, sequence: sequence})
        data = put(d, :memories, r)

        entries =
          data.memories
          |> Map.values()
          |> Enum.filter(&(&1.bot_id == bot))
          |> Enum.sort_by(& &1.sequence)

        evicted = Enum.take(entries, max(0, length(entries) - 200))
        data = %{data | memories: Map.drop(data.memories, Enum.map(evicted, & &1.id))}
        {:write, r, data, Enum.map(evicted, &{:memory_deleted, &1}) ++ [{:memory_created, r}]}
      else
        {:error, :invalid}
      end
    end
  end

  defp execute(:list_memories, [bot, opts], d) do
    with {:ok, _} <- fetch(d, :bots, bot) do
      limit = Keyword.get(opts, :limit, 50)

      if is_integer(limit) and limit in 1..200 do
        list =
          d.memories
          |> Map.values()
          |> Enum.filter(&(&1.bot_id == bot))
          |> Enum.sort_by(& &1.sequence, :desc)
          |> Enum.take(limit)

        {:read, {:ok, list}}
      else
        {:error, :invalid}
      end
    end
  end

  defp execute(_, _, _), do: {:error, :invalid}

  defp next_sequence(d, id),
    do:
      Enum.reduce(Map.values(d.messages), 0, fn m, n ->
        if m.session_id == id, do: max(m.sequence, n), else: n
      end) + 1
end
