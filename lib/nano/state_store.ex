defmodule Nano.StateStore do
  @moduledoc """
  Serialized lifecycle authority and coherent agent checkpoints. A live agent registers
  its logical identity and process incarnation, then checkpoints metadata and bindings
  together with a monotonically increasing revision. Store recovery invalidates tokens
  and asynchronously requests live resaves; missing bindings are `:unavailable`, not empty.

  Durable v1 envelopes reference immutable identity-bound binding blobs. Lifecycle
  tombstones survive restart. A checkpoint returns `{:ok, acknowledgment}` with
  `:durable` or `:memory_only`, accepted and last durable revisions. Disk failure does
  not halt an otherwise registered agent; simultaneous agent/store loss may lose newer
  memory-only state. See docs/flywheel/u05/schema/migration.md. No synchronous calls
  from this store to agents. ETS reads do not call agents.
  """
  use GenServer
  require Logger
  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def get(name), do: lookup(name, nil)

  def all do
    case call(:all) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp table_all do
    :ets.select(@table, [{{:"$1", :"$2"}, [{:is_binary, :"$1"}], [:"$2"]}])
  rescue
    ArgumentError -> []
  end

  @doc "Register logical identity before saving; token binds lifecycle, process and store epoch."
  def register(name, id, pid, recovery_generation \\ nil),
    do: call({:register, name, id, pid, recovery_generation})

  @doc "Coherently accept a current-token revision and return honest durability status."
  def checkpoint(token, revision, metadata, bindings),
    do: call({:checkpoint, token, revision, metadata, bindings})

  def pid_registered?(pid) do
    availability() == :ok and
      :ets.match_object(@table, {{:registration, :_}, :_})
      |> Enum.any?(fn {_, token} ->
        token.pid == pid and
          match?(
            %{status: status} when status in [:durable, :memory_only],
            durability(token.name)
          )
      end)
  rescue
    ArgumentError -> false
  end

  def recovery_generation, do: lookup(:recovery_generation, :unavailable)

  def availability do
    case lookup(:availability, :unavailable) do
      :ready -> :ok
      reason -> {:error, reason}
    end
  end

  def registered?(token) do
    case token do
      %{name: name} -> lookup({:registration, name}, nil) == token
      _ -> false
    end
  end

  @doc "Binding availability: `{:ok, kept, dropped}` or `:unavailable`. Empty is explicit."
  def binding_status(name), do: lookup({:bindings, name}, :unavailable)

  def bindings(name) do
    case binding_status(name) do
      {:ok, kept, dropped} -> {kept, dropped}
      :unavailable -> :unavailable
    end
  end

  def durability(name), do: lookup({:durability, name}, :unavailable)

  @doc "Bounded-information operator recovery/durability status, including unavailable live rows."
  def status do
    rows = :ets.match_object(@table, {{:durability, :_}, :_})

    %{
      availability: availability(),
      agents: Map.new(rows, fn {{:durability, name}, ack} -> {name, ack} end)
    }
  rescue
    ArgumentError -> %{availability: {:error, :unavailable}, agents: %{}}
  end

  # Compatibility entry points for non-agent fixture/admin callers. Production agents
  # use explicit registration/checkpoint; these never overwrite a registered live agent.
  def put(name, map), do: call({:compat_put, name, map})
  def put_bindings(name, bindings), do: call({:compat_bindings, name, bindings})
  def delete(name), do: call({:delete, name})
  def load, do: call(:load)
  def watch(name, pid), do: call({:watch, name, pid})

  def exit_reason(name, pid) do
    case lookup({:exit, name}, nil) do
      {^pid, reason} -> reason
      _ -> nil
    end
  end

  defp lookup(key, default) do
    case :ets.lookup(@table, key) do
      [{_, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, 15_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Atomic synced term publication, also used for user files. Returns failures, never false success."
  def write_file(name, path, term) do
    case publish(path, term) do
      :ok ->
        :ok

      error ->
        Logger.error("#{name}: could not durably save #{path}: #{inspect(error)}")
        error
    end
  end

  @doc "Atomic synced raw evidence publication; same durability protocol as term envelopes."
  def write_bytes(name, path, bytes) when is_binary(bytes) do
    case publish_bytes(path, bytes) do
      :ok ->
        :ok

      error ->
        Logger.error("#{name}: could not durably save evidence #{path}: #{inspect(error)}")
        error
    end
  end

  defp publish(path, term), do: publish_bytes(path, :erlang.term_to_binary(term))

  defp publish_bytes(path, bytes) do
    tmp =
      path <> ".next-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    result =
      with :ok <- fault(:before_write, path),
           :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, io} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw]) do
        written =
          with :ok <- :file.write(io, bytes),
               :ok <- fault(:before_fsync, path),
               do: :file.sync(io)

        :file.close(io)

        with :ok <- written,
             :ok <- fault(:before_rename, path),
             :ok <- File.rename(tmp, path),
             :ok <- fault(:before_directory_sync, path),
             {_, 0} <- System.cmd("sync", ["-f", Path.dirname(path)], stderr_to_stdout: true),
             :ok <- fault(:after_commit, path) do
          :ok
        else
          {:error, _} = error -> error
          other -> {:error, {:sync, other}}
        end
      end

    File.rm(tmp)
    result
  rescue
    e -> {:error, {:publication, Exception.message(e)}}
  end

  # Disposable-VM fault seam; unset in production. Never receives state/binding bytes.
  defp fault(stage, path) do
    case Application.get_env(:nano, :state_store_fault) do
      nil -> :ok
      fun when is_function(fun, 2) -> fun.(stage, path)
    end
  end

  defp dir, do: Application.fetch_env!(:nano, :state_dir)
  defp authority_path, do: Path.join(dir(), "lifecycle-v1.term")
  defp envelope_path(name), do: Path.join(dir(), name <> ".envelope-v1")

  defp valid_name?(name),
    do: is_binary(name) and name =~ ~r/\A[\w.-]+\z/ and name not in [".", ".."]

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    epoch = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    :ets.insert(@table, {:recovery_generation, epoch})
    {authority, degraded} = read_authority()

    s = %{
      authority: authority,
      degraded: degraded,
      epoch: epoch,
      registrations: %{},
      watched: %{},
      recovering: MapSet.new(),
      binding_refs: %{}
    }

    s = restore_disk(s)
    :ets.insert(@table, {:availability, if(s.degraded, do: :degraded, else: :ready)})
    {:ok, s, {:continue, :resave}}
  end

  defp read_authority do
    case read_term(authority_path()) do
      {:ok, %{version: 1, agents: agents}} when is_map(agents) ->
        if Enum.all?(agents, fn {name, a} ->
             is_map(a) and valid_name?(name) and is_binary(a[:id]) and is_integer(a[:generation]) and
               a.generation > 0 and a[:status] in [:active, :deleted] and
               is_list(Map.get(a, :retired_ids, [])) and
               Enum.all?(Map.get(a, :retired_ids, []), &is_binary/1)
           end), do: {agents, false}, else: {%{}, true}

      {:error, :enoent} ->
        # Missing authority in a v1-bearing directory is lost fencing evidence,
        # not permission to recreate identities or remigrate preserved legacy bytes.
        prior_v1 =
          case File.ls(dir()) do
            {:ok, files} ->
              Enum.any?(
                files,
                &(String.ends_with?(&1, [".envelope-v1", ".bindings-v1"]) or
                    String.starts_with?(&1, "lifecycle-v1.term"))
              )

            {:error, :enoent} ->
              false

            _ ->
              true
          end

        {%{}, prior_v1}

      _ ->
        {%{}, true}
    end
  end

  defp read_term(path) do
    with {:ok, bytes} <- File.read(path), do: {:ok, :erlang.binary_to_term(bytes)}
  rescue
    _ -> {:error, :corrupt}
  end

  @impl true
  def handle_continue(:resave, s) do
    live = for {{:agent, name}, pid} <- Nano.Names.all(), do: {name, pid}

    s =
      Enum.reduce(live, s, fn {name, pid}, acc ->
        :ets.delete(@table, name)
        :ets.delete(@table, {:bindings, name})
        previous = durability(name)

        recovering =
          if is_map(previous),
            do: Map.put(previous, :status, :recovering),
            else: %{status: :recovering}

        :ets.insert(@table, {{:durability, name}, recovering})
        GenServer.cast(pid, {:resave, acc.epoch})

        watched =
          case acc.watched[name] do
            {_, ^pid} -> acc.watched
            _ -> Map.put(acc.watched, name, {Process.monitor(pid), pid})
          end

        %{acc | recovering: MapSet.put(acc.recovering, name), watched: watched}
      end)

    {:noreply, s}
  catch
    _, _ -> {:noreply, s}
  end

  @impl true
  def handle_call({:register, name, id, pid, epoch}, {caller, _}, s) do
    if caller == pid do
      {reply, s} = register_identity(s, name, id, pid, epoch)
      {:reply, reply, s}
    else
      {:reply, {:error, :stale}, s}
    end
  end

  def handle_call({:checkpoint, token, revision, metadata, bindings}, {caller, _}, s) do
    if is_map(token) and token[:pid] == caller do
      {reply, s} = accept(s, token, revision, metadata, bindings)
      {:reply, reply, s}
    else
      {:reply, {:error, :stale}, s}
    end
  end

  def handle_call({:delete, name}, _from, s) do
    cond do
      s.degraded ->
        {:reply, {:error, :degraded}, s}

      not valid_name?(name) ->
        {:reply, {:error, :invalid_name}, s}

      true ->
        old = Map.get(s.authority, name, %{id: name, generation: 0})

        tombstone = %{
          id: old.id,
          generation: old.generation + 1,
          status: :deleted,
          retired_ids: Map.get(old, :retired_ids, [])
        }

        authority = Map.put(s.authority, name, tombstone)

        case persist_authority(authority) do
          :ok ->
            if entry = get(name), do: :ets.delete(@table, {:seq, entry[:id]})

            Enum.each(
              [
                name,
                {:bindings, name},
                {:registration, name},
                {:durability, name},
                {:exit, name}
              ],
              &:ets.delete(@table, &1)
            )

            # Legacy files remain evidence; tombstone, not file absence, prevents resurrection.
            {:reply, :ok,
             %{
               s
               | authority: authority,
                 registrations: Map.delete(s.registrations, name),
                 binding_refs: Map.delete(s.binding_refs, name),
                 recovering: MapSet.delete(s.recovering, name)
             }}

          error ->
            :ets.insert(@table, {:availability, :degraded})
            {:reply, error, %{s | degraded: true}}
        end
    end
  end

  def handle_call(:all, _from, s) do
    # Scan barrier reconciles deaths even when DOWN has not reached this mailbox.
    s = Enum.reduce(s.recovering, s, fn name, acc -> restore_dead_resaver(acc, name) end)
    {:reply, table_all(), s}
  end

  def handle_call(:load, _from, s), do: {:reply, :ok, s}

  def handle_call({:compat_put, name, map}, {caller, _}, s) do
    if not is_map(map) or Map.has_key?(map, :model) or
         (is_map(get(name)) and Map.has_key?(get(name), :model)) or
         (Map.has_key?(s.registrations, name) and s.registrations[name].pid != caller) do
      {:reply, {:error, :stale}, s}
    else
      id = map[:id] || name
      {registered, s} = register_identity(s, name, id, caller, nil)

      case registered do
        {:ok, token} ->
          {kept, _} =
            case bindings(name) do
              :unavailable -> {[], []}
              pair -> pair
            end

          revision =
            case durability(name) do
              %{accepted_revision: r} -> r + 1
              _ -> 1
            end

          {reply, s} = accept(s, token, revision, Map.put(map, :id, id), kept)
          # Preserve legacy fixture map shape, not used by production agents.
          if match?({:ok, _}, reply), do: :ets.insert(@table, {name, map})
          {:reply, if(match?({:ok, _}, reply), do: :ok, else: reply), s}

        error ->
          {:reply, error, s}
      end
    end
  end

  def handle_call({:compat_bindings, name, b}, {caller, _}, s) do
    case s.registrations[name] do
      %{pid: ^caller} = token ->
        revision =
          case durability(name) do
            %{accepted_revision: r} -> r + 1
            _ -> 1
          end

        {reply, s} = accept(s, token, revision, get(name), b)
        {:reply, if(match?({:ok, _}, reply), do: elem(bindings(name), 1), else: reply), s}

      _ ->
        {:reply, {:error, :unavailable}, s}
    end
  end

  def handle_call({:watch, name, pid}, from, s) do
    if MapSet.member?(s.recovering, name) and recovering_other_alive?(s, name, pid) do
      {:reply, {:error, :incarnation_active}, s}
    else
      watch_reply(name, pid, from, s)
    end
  end

  def handle_call(_, _from, s), do: {:reply, {:error, :unknown_call}, s}

  defp watch_reply(name, pid, _from, s) do
    # Record a dead predecessor before attaching, without a synchronous store->agent call.
    s =
      case s.watched[name] do
        {ref, old} when old != pid ->
          receive do
            {:DOWN, ^ref, :process, ^old, reason} -> record(name, old, reason)
          after
            0 ->
              # A queued replacement can arrive before the predecessor consumes
              # its stop. Retain the attached monitor for bounded exact DOWN evidence.
              receive do
                {:DOWN, ^ref, :process, ^old, reason} -> record(name, old, reason)
              after
                5000 -> if not Process.alive?(old), do: record(name, old, :unknown)
              end
          end

          Process.demonitor(ref, [:flush])
          s

        _ ->
          s
      end

    watched =
      case s.watched[name] do
        {ref, ^pid} -> Map.put(s.watched, name, {ref, pid})
        _ -> Map.put(s.watched, name, {Process.monitor(pid), pid})
      end

    {:reply, :ok, %{s | watched: watched}}
  end

  defp register_identity(s, name, id, pid, epoch) do
    # A dead resaver cannot provide its live map. Recover only its last coherent
    # identity/generation-bound pair; never expose another still-live resaver's row.
    s =
      if epoch == nil,
        do: restore_dead_resaver(s, name, pid, id),
        else: restore_dead_resaver(s, name)

    current = s.authority[name]
    registered = s.registrations[name]

    cond do
      s.degraded ->
        {{:error, :degraded}, s}

      not valid_name?(name) or not is_binary(id) or not is_pid(pid) ->
        {{:error, :invalid_identity}, s}

      epoch != nil and epoch != s.epoch ->
        {{:error, :stale}, s}

      registered != nil and registered.pid == pid and registered.id == id ->
        {{:ok, registered}, s}

      registered != nil and Process.alive?(registered.pid) ->
        {{:error, :incarnation_active}, s}

      MapSet.member?(s.recovering, name) and recovering_other_alive?(s, name, pid) ->
        {{:error, :incarnation_active}, s}

      current != nil and current.status == :active and current.id == id and get(name) == nil and
          epoch == nil ->
        {{:error, :recovery_unavailable}, s}

      current != nil and id in Map.get(current, :retired_ids, []) ->
        {{:error, :retired_identity}, s}

      current != nil and current.status == :deleted and current.id == id ->
        {{:error, :deleted}, s}

      true ->
        lifecycle =
          if current != nil and current.status == :active and current.id == id,
            do: current,
            else: %{
              id: id,
              generation: if(current, do: current.generation + 1, else: 1),
              status: :active,
              retired_ids:
                if(current,
                  do: Enum.uniq([current.id | Map.get(current, :retired_ids, [])]),
                  else: []
                )
            }

        authority = Map.put(s.authority, name, lifecycle)
        result = if authority == s.authority, do: :ok, else: persist_authority(authority)

        case result do
          :ok ->
            s =
              if current != lifecycle do
                Enum.each(
                  [name, {:bindings, name}, {:durability, name}],
                  &:ets.delete(@table, &1)
                )

                %{s | binding_refs: Map.delete(s.binding_refs, name)}
              else
                s
              end

            token = %{
              name: name,
              id: id,
              lifecycle_generation: lifecycle.generation,
              incarnation: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
              store_generation: s.epoch,
              pid: pid
            }

            :ets.insert(@table, {{:registration, name}, token})

            {{:ok, token},
             %{s | authority: authority, registrations: Map.put(s.registrations, name, token)}}

          error ->
            :ets.insert(@table, {:availability, :degraded})
            {error, %{s | degraded: true}}
        end
    end
  end

  defp persist_authority(authority),
    do: publish(authority_path(), %{version: 1, agents: authority})

  defp accept(s, token, revision, metadata, bindings) do
    name = if is_map(token), do: token[:name]
    old = durability(name)
    accepted = if is_map(old), do: old[:accepted_revision] || 0, else: 0

    cond do
      s.degraded ->
        {{:error, :degraded}, s}

      s.registrations[name] != token or token == nil ->
        {{:error, :stale}, s}

      bindings == :unchanged and not Map.has_key?(s.binding_refs, name) ->
        {{:error, :bindings_unavailable}, s}

      not is_integer(revision) or revision <= accepted ->
        {{:error, :stale_revision}, s}

      not is_map(metadata) or metadata[:name] != name or metadata[:id] != token.id or
          not (valid_bindings?(bindings) or bindings == :unchanged) ->
        {{:error, :incoherent}, s}

      true ->
        previous = s.binding_refs[name]

        {ref, changed?} =
          if bindings == :unchanged and previous != nil do
            {previous, false}
          else
            {kept, dropped} = keep_bindings(bindings)

            old_dropped =
              case binding_status(name) do
                {:ok, _, d} -> d
                _ -> []
              end

            if dropped -- old_dropped != [] do
              sizes =
                Enum.map_join(dropped -- old_dropped, ", ", fn k ->
                  "#{k} (#{:erlang.external_size(Keyword.fetch!(bindings, k))} bytes)"
                end)

              Logger.warning(
                "#{name}: not saving eval variables #{sizes}: over binding limit; variables remain live but will not survive restart"
              )
            end

            blob = %{
              version: 1,
              name: name,
              id: token.id,
              lifecycle_generation: token.lifecycle_generation,
              kept: kept,
              dropped: dropped
            }

            digest =
              :crypto.hash(:sha256, :erlang.term_to_binary(blob)) |> Base.encode16(case: :lower)

            file = name <> "." <> digest <> ".bindings-v1"
            {%{file: file, dropped: dropped, blob: blob, persisted: false}, true}
          end

        blob_name = ref.file
        dropped = ref.dropped
        path = Path.join(dir(), blob_name)

        blob_commit =
          if ref.persisted and File.regular?(path) do
            :ok
          else
            blob =
              ref.blob ||
                case binding_status(name) do
                  {:ok, kept, dropped} ->
                    %{
                      version: 1,
                      name: name,
                      id: token.id,
                      lifecycle_generation: token.lifecycle_generation,
                      kept: kept,
                      dropped: dropped
                    }

                  _ ->
                    nil
                end

            if blob, do: ensure_blob(path, blob), else: {:error, :bindings_unavailable}
          end

        ref = if blob_commit == :ok, do: %{ref | persisted: true, blob: nil}, else: ref

        envelope = %{
          version: 1,
          name: name,
          id: token.id,
          lifecycle_generation: token.lifecycle_generation,
          revision: revision,
          metadata:
            Map.drop(metadata, [
              :bindings,
              :store_token,
              :durability,
              :bindings_dirty,
              :store_retry_pending
            ]),
          blob: blob_name
        }

        commit = with :ok <- blob_commit, do: publish(envelope_path(name), envelope)
        last = if is_map(old), do: old[:durable_revision] || 0, else: 0

        ack = %{
          status: if(commit == :ok, do: :durable, else: :memory_only),
          accepted_revision: revision,
          durable_revision: if(commit == :ok, do: revision, else: last),
          dropped: dropped,
          warning:
            if(commit == :ok,
              do: nil,
              else:
                "Disk checkpoint failed; simultaneous agent/store/node loss can lose newer state."
            )
        }

        if commit != :ok,
          do:
            Logger.warning(
              "#{name}: memory_only revision #{revision}, last durable #{last}: #{inspect(commit)}"
            )

        rows = [{name, envelope.metadata}, {{:durability, name}, ack}]

        rows =
          if changed? do
            {kept, _} = keep_bindings(bindings)
            [{{:bindings, name}, {:ok, kept, dropped}} | rows]
          else
            rows
          end

        :ets.insert(@table, rows)

        {{:ok, ack},
         %{
           s
           | recovering: MapSet.delete(s.recovering, name),
             binding_refs: Map.put(s.binding_refs, name, ref)
         }}
    end
  end

  defp ensure_blob(path, blob) do
    case read_term(path) do
      {:ok, ^blob} -> :ok
      {:error, :enoent} -> publish(path, blob)
      _ -> {:error, :corrupt_blob}
    end
  end

  defp valid_bindings?(bindings),
    do:
      is_list(bindings) and
        Enum.all?(bindings, fn
          {key, _} when is_atom(key) -> true
          _ -> false
        end)

  defp keep_bindings(bindings) do
    max = Nano.Settings.get(:max_bindings_bytes)

    {kept, dropped, _} =
      bindings
      |> Enum.map(fn {k, v} -> {k, v, :erlang.external_size(v)} end)
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.reduce({[], [], 0}, fn {k, v, n}, {kept, dropped, total} ->
        if total + n <= max,
          do: {[{k, v} | kept], dropped, total + n},
          else: {kept, [k | dropped], total}
      end)

    {Enum.sort(kept), Enum.sort(dropped)}
  end

  defp restore_disk(%{degraded: true} = s), do: s

  defp restore_disk(s) do
    # Legacy migration only before v1 authority exists; retain all original bytes.
    s = if not File.exists?(authority_path()), do: migrate_legacy(s), else: s

    Enum.each(s.authority, fn {name, a} ->
      if a.status == :active do
        case coherent_disk(name, a) do
          {:ok, envelope, blob} ->
            :ets.insert(@table, [
              {name, envelope.metadata},
              {{:bindings, name}, {:ok, blob.kept, blob.dropped}},
              {{:durability, name},
               %{
                 status: :durable,
                 accepted_revision: envelope.revision,
                 durable_revision: envelope.revision,
                 dropped: blob.dropped,
                 warning: nil
               }},
              {{:exit, name}, {envelope.metadata[:pid], :node_restart}}
            ])

          _ ->
            :ets.insert(
              @table,
              {{:durability, name},
               %{status: :unavailable, warning: "No coherent committed recovery pair."}}
            )
        end
      end
    end)

    s
  end

  defp recovering_other_alive?(s, name, claimant) do
    case s.watched[name] do
      {_, pid} when pid != claimant -> Process.alive?(pid)
      _ -> false
    end
  end

  defp restore_dead_resaver(s, name, initializing_pid \\ nil, initializing_id \\ nil) do
    alive =
      case s.watched[name] do
        {_, pid} -> Process.alive?(pid)
        _ -> false
      end

    initializing =
      case {s.watched[name], s.authority[name]} do
        {{_, ^initializing_pid}, %{status: :active, id: ^initializing_id}}
        when initializing_pid != nil ->
          true

        _ ->
          false
      end

    if not s.degraded and MapSet.member?(s.recovering, name) and (not alive or initializing) do
      case s.authority[name] do
        %{status: :active} = a ->
          case coherent_disk(name, a) do
            {:ok, envelope, blob} ->
              :ets.insert(@table, [
                {name, envelope.metadata},
                {{:bindings, name}, {:ok, blob.kept, blob.dropped}},
                {{:durability, name},
                 %{
                   status: :durable,
                   accepted_revision: envelope.revision,
                   durable_revision: envelope.revision,
                   dropped: blob.dropped,
                   warning: nil
                 }}
              ])

              %{
                s
                | recovering: MapSet.delete(s.recovering, name),
                  binding_refs: Map.delete(s.binding_refs, name)
              }

            _ ->
              s
          end

        _ ->
          s
      end
    else
      s
    end
  end

  defp coherent_disk(name, a) do
    with {:ok,
          %{
            version: 1,
            name: ^name,
            id: id,
            lifecycle_generation: generation,
            revision: revision,
            metadata: metadata,
            blob: file
          } = e} <- read_term(envelope_path(name)),
         true <-
           id == a.id and generation == a.generation and is_integer(revision) and revision > 0,
         true <- is_map(metadata) and metadata[:name] == name and metadata[:id] == id,
         true <-
           is_binary(file) and Path.basename(file) == file and
             String.starts_with?(file, name <> "."),
         {:ok,
          %{
            version: 1,
            name: ^name,
            id: ^id,
            lifecycle_generation: ^generation,
            kept: kept,
            dropped: dropped
          } = b} <- read_binding_blob(name, file),
         true <- valid_bindings?(kept) and is_list(dropped) and Enum.all?(dropped, &is_atom/1) do
      {:ok, e, b}
    else
      _ -> {:error, :incoherent}
    end
  end

  # Digest names identify the immutable persisted bytes, not a fresh serialization of
  # the decoded map. Small-map external-term order can change with VM atom layout.
  # Verify before decoding; envelope identity/schema/generation checks remain above.
  defp read_binding_blob(name, file) do
    with {:ok, bytes} <- File.read(Path.join(dir(), file)),
         digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         true <- file == name <> "." <> digest <> ".bindings-v1" do
      {:ok, :erlang.binary_to_term(bytes)}
    else
      _ -> {:error, :incoherent}
    end
  rescue
    _ -> {:error, :incoherent}
  end

  defp migrate_legacy(s) do
    # One cutover authority publication, after all candidate envelopes. A crash before
    # cutover retries read-only legacy migration; after cutover no legacy is reimported.
    authority =
      Path.wildcard(Path.join(dir(), "*.term"))
      |> Enum.reduce(%{}, fn path, acc ->
        name = Path.basename(path, ".term")

        with true <- valid_name?(name),
             {:ok, %{name: ^name, id: id} = metadata} <- read_term(path),
             true <- is_binary(id) do
          binding =
            case metadata do
              %{bindings: b} when is_list(b) -> {:ok, {b, []}}
              _ -> {:error, :unversioned_split_bindings}
            end

          case binding do
            {:ok, {kept, dropped}} when is_list(kept) and is_list(dropped) ->
              blob = %{
                version: 1,
                name: name,
                id: id,
                lifecycle_generation: 1,
                kept: kept,
                dropped: dropped
              }

              digest =
                :crypto.hash(:sha256, :erlang.term_to_binary(blob)) |> Base.encode16(case: :lower)

              file = name <> "." <> digest <> ".bindings-v1"

              with :ok <- publish(Path.join(dir(), file), blob) do
                publish(envelope_path(name), %{
                  version: 1,
                  name: name,
                  id: id,
                  lifecycle_generation: 1,
                  revision: 1,
                  metadata: Map.delete(metadata, :bindings),
                  blob: file
                })
              end

            _ ->
              Logger.warning(
                "#{name}: legacy recovery unavailable: no explicit coherent bindings"
              )
          end

          Map.put(acc, name, %{id: id, generation: 1, status: :active})
        else
          _ ->
            Logger.warning("Nano.StateStore: skipped #{path}: invalid legacy identity")
            acc
        end
      end)

    if map_size(authority) == 0 do
      s
    else
      case persist_authority(authority) do
        :ok -> %{s | authority: authority}
        _ -> %{s | degraded: true}
      end
    end
  end

  @impl true
  def code_change(:pre_u05, watched, {:u05_upgrade, max_agents})
      when is_map(watched) and is_integer(max_agents) and max_agents in 1..10_000 do
    live = for {{:agent, name}, pid} <- Nano.Names.all(), do: {name, pid}
    entries = table_all()
    {authority, degraded} = read_authority()

    cond do
      not Enum.all?(watched, fn
        {name, {ref, pid}} when is_binary(name) and is_reference(ref) and is_pid(pid) -> true
        _ -> false
      end) ->
        {:error, :invalid_legacy_process_state}

      not Enum.all?(entries, fn entry ->
        is_map(entry) and valid_name?(entry[:name]) and is_binary(entry[:id])
      end) ->
        {:error, :invalid_legacy_entry}

      degraded ->
        {:error, :degraded_authority}

      length(live) > max_agents or length(entries) > max_agents ->
        {:error, :upgrade_bound_exceeded}

      not Enum.all?(live, fn {_, pid} ->
        match?(
          {:current_function, {:sys, :suspend_loop, _}},
          Process.info(pid, :current_function)
        )
      end) ->
        {:error, :live_agents_not_quiescent}

      not Enum.all?(live, fn {name, _} ->
        match?(%{name: ^name, id: id} when is_binary(id), get(name))
      end) ->
        {:error, :live_identity_unavailable}

      not Enum.all?(live, fn {name, _} -> model_task_quiescent?(get(name)) end) ->
        {:error, :model_tasks_not_quiescent}

      true ->
        candidate =
          Enum.reduce_while(entries, {:ok, authority}, fn entry, {:ok, acc} ->
            case entry do
              %{name: name, id: id} when is_binary(id) ->
                case acc[name] do
                  nil ->
                    {:cont,
                     {:ok,
                      Map.put(acc, name, %{
                        id: id,
                        generation: 1,
                        status: :active,
                        retired_ids: []
                      })}}

                  %{id: ^id, status: :active} ->
                    {:cont, {:ok, acc}}

                  _ ->
                    {:halt, {:error, :newer_lifecycle_conflict}}
                end

              _ ->
                {:halt, {:error, :invalid_legacy_entry}}
            end
          end)

        with {:ok, authority} <- candidate, :ok <- persist_authority(authority) do
          epoch = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
          # Preserve counters, exits, pending logs and original bytes. Legacy binding rows
          # are not coherent authority: only each suspended live agent's full resave is.
          for entry <- entries do
            :ets.delete(@table, entry.name)
            :ets.delete(@table, {:bindings, entry.name})
          end

          s = %{
            authority: authority,
            degraded: false,
            epoch: epoch,
            registrations: %{},
            watched: watched,
            recovering: MapSet.new(),
            binding_refs: %{}
          }

          s = restore_disk(s)
          :ets.insert(@table, [{:recovery_generation, epoch}, {:availability, :ready}])
          send(self(), :u05_upgrade_resave)
          {:ok, s}
        else
          error -> error
        end
    end
  end

  def code_change(_old, %{authority: _, registrations: _} = s, _extra), do: {:ok, s}
  def code_change(_, _, _), do: {:error, :unsupported_state_upgrade}

  defp model_task_quiescent?(%{task: %{kind: :model, task: %Task{pid: pid}}}) do
    Process.info(pid, :status) in [nil, {:status, :suspended}]
  end

  defp model_task_quiescent?(%{task: %{kind: :model}}), do: false
  defp model_task_quiescent?(_), do: true

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, s} ->
        {:state, %{degraded: s[:degraded], registered_agents: map_size(s[:registrations] || %{})}}

      {:message, _} ->
        {:message, :redacted}

      {:log, _} ->
        {:log, []}

      {:reason, reason} when not is_atom(reason) ->
        {:reason, :redacted}

      item ->
        item
    end)
  end

  @impl true
  def handle_info(:u05_upgrade_resave, s), do: handle_continue(:resave, s)

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case Enum.find(s.watched, fn {_, {r, _}} -> r == ref end) do
      {name, _} ->
        s = restore_dead_resaver(s, name)
        record(name, pid, reason)
        {:noreply, %{s | watched: Map.delete(s.watched, name)}}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def handle_cast(_, s), do: {:noreply, s}

  defp record(name, pid, reason) do
    if match?(%{pid: ^pid}, get(name)), do: :ets.insert(@table, {{:exit, name}, {pid, reason}})
  end

  def next_seq(id) do
    key = {:seq, id}

    unless :ets.member(@table, key) do
      last = id |> Nano.Log.read() |> List.last()
      :ets.insert_new(@table, {key, if(last, do: last["seq"], else: 0)})
    end

    :ets.update_counter(@table, key, 1)
  rescue
    ArgumentError ->
      # Completed task evidence still reaches its durable log during table loss.
      last = id |> Nano.Log.read() |> List.last()
      if last, do: last["seq"] + 1, else: 1
  end

  def add_node_tokens(n) do
    minute = minute()

    :ets.select_delete(@table, [
      {{{:node_tokens, :"$1"}, :_}, [{:"=<", :"$1", minute - 60}], [true]}
    ])

    :ets.update_counter(@table, {:node_tokens, minute}, n, {{:node_tokens, minute}, 0})
    :ok
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def node_tokens_last_hour do
    :ets.select(@table, [{{{:node_tokens, :"$1"}, :"$2"}, [{:>, :"$1", minute() - 60}], [:"$2"]}])
    |> Enum.sum()
  rescue
    ArgumentError -> 0
  end

  defp minute, do: div(System.system_time(:second), 60)
end
