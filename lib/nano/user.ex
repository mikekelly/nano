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

  @doc "Sends `%{sender_pid: user_pid, message: text}` to `to`: a pid, agent name, user name, or registered name."
  def say(name, to, text), do: deliver(name, to, {:say, text})

  @doc "Sends `term` to `to` exactly as given, with no sender added."
  def send_raw(name, to, term), do: deliver(name, to, {:raw, term})

  @doc "Received messages as `%{at: DateTime, term: term}`, oldest first. `clear: true` empties the inbox."
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

  defp call(name, request) do
    case pid(name) do
      nil -> {:error, :unknown_user}
      pid -> GenServer.call(pid, request)
    end
  end

  defp via(name), do: {:via, Registry, {Nano.Registry, {:user, name}}}

  @impl true
  def init(name), do: {:ok, %{name: name, inbox: []}}

  @impl true
  def handle_call({:send, target, message}, _from, state) do
    term =
      case message do
        {:say, text} -> %{sender_pid: self(), message: text}
        {:raw, term} -> term
      end

    send(target, term)
    publish(state, :sent, target, term)
    {:reply, :ok, state}
  end

  def handle_call({:inbox, clear?}, _from, state) do
    {:reply, Enum.reverse(state.inbox), if(clear?, do: %{state | inbox: []}, else: state)}
  end

  @impl true
  def handle_info(term, state) do
    entry = publish(state, :received, self(), term)
    {:noreply, %{state | inbox: [Map.take(entry, [:at, :term]) | state.inbox]}}
  end

  defp publish(state, dir, to, term) do
    entry = %{dir: dir, at: DateTime.utc_now(), to: to, term: term}
    Phoenix.PubSub.broadcast(Nano.PubSub, "user:" <> state.name, {:nano_user, entry})
    entry
  end
end
