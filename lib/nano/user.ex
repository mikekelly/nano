defmodule Nano.User do
  @moduledoc """
  A named identity on the node for a person or an outside agent (Claude Code on the host, say).

  Each send is a `GenServer.call` that performs the `send/2` inside the user process, so the
  user is the real sender: an agent that traces who messaged it finds this process. Any other
  message the process receives goes into its inbox. Everything sent and received is broadcast
  on `Nano.PubSub`, topic `"user:<name>"`, as `{:nano_user, %{dir: :sent | :received, at, to, term}}`.
  """
  use GenServer

  @doc "Starts and registers a user process; returns its pid (the existing one if already started)."
  def start(name) when is_binary(name) do
    case DynamicSupervisor.start_child(Nano.UserSupervisor, {__MODULE__, name}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  @doc """
  Sends `%{sender_pid: user_pid, message: text}` to `to`: a pid, agent name, user name, or
  registered name. Given images (`%Nano.Image{}` values, from `Nano.Image.new/1`), the message
  also carries them, as `images:`; an agent whose model can see images is shown them.
  """
  def say(name, to, text, images \\ []), do: deliver(name, to, {:say, text, images})

  @doc "Sends `term` to `to` exactly as given, with no sender added."
  def send_raw(name, to, term), do: deliver(name, to, {:raw, term})

  @doc """
  Received messages as `%{at: DateTime, term: term}`, oldest first. `clear: true` empties the
  inbox. `say/3`, `send_raw/3` and `inbox/2` return `{:error, :unknown_user}` for a user that is
  not running and `{:error, :unresponsive}` for one that does not answer within a second. The
  request is then still in the user's mailbox and is carried out if the user resumes: a send
  goes out late, so retrying it would deliver it twice.
  """
  def inbox(name, opts \\ []), do: call(name, {:inbox, Keyword.get(opts, :clear, false)})

  @doc "The user's pid, or nil."
  def pid(name) do
    case Registry.lookup(Nano.Registry, {:user, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Names of all users."
  def list, do: Registry.select(Nano.Registry, [{{{:user, :"$1"}, :_, :_}, [], [:"$1"]}])

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

  defp via(name), do: {:via, Registry, {Nano.Registry, {:user, name}}}

  @impl true
  def init(name), do: {:ok, %{name: name, inbox: []}}

  @impl true
  def handle_call({:send, target, {:say, text, images}}, _from, state) when is_pid(target) do
    message = %{sender_pid: self(), message: text}
    message = if images == [], do: message, else: Map.put(message, :images, images)
    deliver_now(state, target, message)
  end

  def handle_call({:send, target, {:raw, term}}, _from, state) when is_pid(target),
    do: deliver_now(state, target, term)

  def handle_call({:inbox, clear?}, _from, state) do
    {:reply, Enum.reverse(state.inbox), if(clear?, do: %{state | inbox: []}, else: state)}
  end

  # Any other call or cast (an agent replying with GenServer.call/cast, say) is a message
  # like any other, kept in the raw form it arrived in, as NanoAgent does. A call gets no reply.
  def handle_call(msg, from, state), do: handle_info({:"$gen_call", from, msg}, state)

  @impl true
  def handle_cast(msg, state), do: handle_info({:"$gen_cast", msg}, state)

  @impl true
  def handle_info(term, state) do
    entry = publish(state, :received, self(), term)
    {:noreply, %{state | inbox: [Map.take(entry, [:at, :term]) | state.inbox]}}
  end

  defp deliver_now(state, target, term) do
    send(target, term)
    publish(state, :sent, target, term)
    {:reply, :ok, state}
  end

  defp publish(state, dir, to, term) do
    entry = %{dir: dir, at: DateTime.utc_now(), to: to, term: term}
    Phoenix.PubSub.broadcast(Nano.PubSub, "user:" <> state.name, {:nano_user, entry})
    entry
  end
end
