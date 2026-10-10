defmodule Nano.User do
  @moduledoc """
  A named identity on the node for a person or an outside agent (Claude Code on the host, say).

  Each send is a `GenServer.call` that performs the `send/2` inside the user process, so the
  user is the real sender: an agent that traces who messaged it finds this process. Any other
  message the process receives goes into its inbox.

  A user keeps the last 500 messages it sent and received, each with the agent it went to
  or came from, so they read as one conversation per agent (`threads/1`). Erlang messages
  carry no sender, so for one received that is a guess (`Nano.Ops.sender/1`): the agent a pid
  in it belongs to, else the one agent running an eval as it arrives, else none. These are
  read from a public ETS table, never by calling the user, so a suspended user can still be read.

  Users outlive the node: each one's messages are written to
  `<state_dir>/users/<name, hex-encoded>.term` whenever they change, and `revive/0` starts every
  saved user at boot. A pid does not outlive its process: one an agent kept from before a
  restart names nothing, so an agent should look a user up by name each time it sends, with
  `Nano.User.pid(name)` (or send to `{:via, Nano.Names, {:user, name}}`).

  Everything sent and received is broadcast on `Nano.PubSub`, on topic `"user:<name>"` and on
  `"users"` (all users), as `{:nano_user, %{user, dir: :sent | :received, at, to, agent, term}}`.
  `"users"` also carries `{:nano_user, %{user, dir: :read}}` after `mark_read/2`.
  """
  use GenServer
  require Logger

  @table __MODULE__
  @keep 500

  @doc "Creates the table of users' messages; called once by `Nano.Application.start/2`, whose process owns it."
  def create_table, do: :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

  @doc "Starts and registers a user process; returns its pid (the existing one if already started)."
  def start(name) when is_binary(name) do
    case DynamicSupervisor.start_child(Nano.UserSupervisor, {__MODULE__, name}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Starts the `dashboard` user and every user saved in the state directory, with the messages
  it had. Called at boot and when `Nano.UserSupervisor` restarts. A file that cannot be read
  is logged, and its user starts with none.
  """
  def revive do
    start("dashboard")
    dir = users_dir()

    for file <- with({:ok, files} <- File.ls(dir), do: files, else: (_ -> [])),
        Path.extname(file) == ".term",
        {:ok, name} <- [Base.decode16(Path.rootname(file), case: :lower)],
        do: start(name)

    :ok
  end

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  @doc """
  Sends `%{sender_pid: user_pid, message: payload}` to a pid, agent, user or registered name.
  Payload is plain text or `%{text: text, images: [refs]}`. Image references are verified
  against the immutable store and reduced to canonical metadata before delivery or storage.
  """

  def say(name, to, %{text: text, images: images}) when is_binary(text) and is_list(images) do
    with {:ok, refs} <- Nano.Ops.image_refs(images) do
      deliver(name, to, {:say, %{text: text, images: refs}})
    end
  end

  def say(name, to, text) when is_binary(text), do: deliver(name, to, {:say, text})
  def say(_, _, _), do: {:error, :invalid_message}

  @doc "Sends `term` to `to` exactly as given, with no sender added."
  def send_raw(name, to, term), do: deliver(name, to, {:raw, term})

  @doc """
  Received messages as `%{at: DateTime, term: term}`, oldest first. `clear: true` empties the
  inbox (the messages stay in `threads/1`). `say/3`, `send_raw/3`, `inbox/2` and `mark_read/2`
  return `{:error, :unknown_user}` for a user that is not running and `{:error, :unresponsive}`
  for one that does not answer within a second. The request is then still in the user's
  mailbox and is carried out if the user resumes: a send goes out late, so retrying it would
  deliver it twice.
  """
  def inbox(name, opts \\ []), do: call(name, {:inbox, Keyword.get(opts, :clear, false)})

  @doc """
  The user's conversations, the most recently active first: `%{agent, messages, unread}`, where
  agent is the agent's name, or nil for messages that name no agent; messages are
  `%{at, dir: :sent | :received, agent, term}`, oldest first; and unread counts those received
  since `mark_read/2`. `{:error, :unknown_user}` for a user never started.
  """
  def threads(name) do
    case :ets.lookup(@table, name) do
      [{_, s}] ->
        s.messages
        |> Enum.group_by(& &1.agent)
        |> Enum.map(fn {agent, [last | _] = messages} ->
          read = Map.get(s.read, agent, 0)

          {last.n,
           %{
             agent: agent,
             messages: messages |> Enum.reverse() |> Enum.map(&Map.delete(&1, :n)),
             unread: Enum.count(messages, &(&1.dir == :received and &1.n > read))
           }}
        end)
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.map(&elem(&1, 1))

      [] ->
        {:error, :unknown_user}
    end
  rescue
    ArgumentError -> {:error, :unknown_user}
  end

  @doc "Marks the user's conversation with an agent (nil: with no agent) as read, up to now."
  def mark_read(name, agent), do: call(name, {:read, agent})

  @doc "The user's pid, or nil."
  def pid(name) do
    with :undefined <- Nano.Names.whereis_name({:user, name}), do: nil
  end

  @doc "Names of all users."
  def list, do: for({{:user, name}, _} <- Nano.Names.all(), do: name)

  @doc "Every user, by name: `%{name, pid, messages, unread}`, counted from `threads/1`."
  def counts do
    for name <- Enum.sort(list()), threads when is_list(threads) <- [threads(name)] do
      %{
        name: name,
        pid: pid(name),
        messages: threads |> Enum.map(&length(&1.messages)) |> Enum.sum(),
        unread: threads |> Enum.map(& &1.unread) |> Enum.sum()
      }
    end
  end

  defp deliver(name, to, message) do
    case Nano.Ops.resolve(to) do
      nil -> if pid(name), do: {:error, :unknown_target}, else: {:error, :unknown_user}
      target -> call(name, {:send, target, message})
    end
  end

  # Anyone can suspend or flood a user (agents are handed its pid), so a call that gets no
  # answer within a second is an error, not a crash in the caller. The request stays queued.
  defp call(name, request) do
    case pid(name) do
      nil -> {:error, :unknown_user}
      pid -> GenServer.call(pid, request, 1_000)
    end
  catch
    :exit, _ -> {:error, :unresponsive}
  end

  defp via(name), do: {:via, Nano.Names, {:user, name}}

  defp users_dir, do: Path.join(Application.fetch_env!(:nano, :state_dir), "users")
  defp file(name), do: Path.join(users_dir(), Base.encode16(name, case: :lower) <> ".term")

  @impl true
  # n numbers the messages; cleared is the last n the inbox was emptied at; read, per agent,
  # the last n seen there. Messages are kept newest first.
  def init(name) do
    fresh = %{name: name, n: 0, messages: [], cleared: 0, read: %{}}

    state =
      case :ets.lookup(@table, name) do
        [{_, saved}] -> saved
        [] -> Map.merge(fresh, load(name))
      end

    # Saved at once, so a user that has no messages yet is revived too.
    {:ok, save(state)}
  end

  # A process restarted on this node finds its row; after a node restart, only its file.
  defp load(name) do
    case File.read(file(name)) do
      {:error, :enoent} ->
        %{}

      read ->
        {:ok, binary} = read
        %{name: ^name, messages: messages} = saved = :erlang.binary_to_term(binary)
        true = is_list(messages)
        Map.take(saved, [:n, :messages, :cleared, :read])
    end
  rescue
    e ->
      Logger.error("Nano.User #{name}: starting with no messages: #{Exception.message(e)}")
      %{}
  end

  @impl true
  def handle_call({:send, target, {:say, text}}, _from, state) when is_pid(target),
    do: deliver_now(state, target, %{sender_pid: self(), message: text})

  def handle_call({:send, target, {:raw, term}}, _from, state) when is_pid(target),
    do: deliver_now(state, target, term)

  def handle_call({:inbox, clear?}, _from, state) do
    inbox =
      for %{dir: :received, n: n} = m <- Enum.reverse(state.messages),
          n > state.cleared,
          do: Map.take(m, [:at, :term])

    {:reply, inbox, if(clear?, do: save(%{state | cleared: state.n}), else: state)}
  end

  def handle_call({:read, agent}, _from, state) when is_binary(agent) or agent == nil do
    state = save(%{state | read: Map.put(state.read, agent, state.n)})
    Phoenix.PubSub.broadcast(Nano.PubSub, "users", {:nano_user, %{user: state.name, dir: :read}})
    {:reply, :ok, state}
  end

  # Any other call or cast (an agent replying with GenServer.call/cast, say) is a message
  # like any other, kept in the raw form it arrived in, as NanoAgent does. A call gets no reply.
  def handle_call(msg, from, state), do: handle_info({:"$gen_call", from, msg}, state)

  @impl true
  def handle_cast(msg, state), do: handle_info({:"$gen_cast", msg}, state)

  @impl true
  def handle_info(term, state),
    do: {:noreply, record(state, :received, self(), Nano.Ops.sender(term), term)}

  defp deliver_now(state, target, term) do
    send(target, term)
    {:reply, :ok, record(state, :sent, target, Nano.Ops.owner(target), term)}
  end

  defp record(state, dir, to, agent, term) do
    n = state.n + 1
    entry = %{n: n, dir: dir, at: DateTime.utc_now(), agent: agent, term: term}
    broadcast = {:nano_user, Map.merge(entry, %{user: state.name, to: to})}
    Phoenix.PubSub.broadcast(Nano.PubSub, "user:" <> state.name, broadcast)
    Phoenix.PubSub.broadcast(Nano.PubSub, "users", broadcast)
    save(%{state | n: n, messages: Enum.take([entry | state.messages], @keep)})
  end

  defp save(state) do
    :ets.insert(@table, {state.name, state})
    Nano.StateStore.write_file("user " <> state.name, file(state.name), state)
    state
  end
end
