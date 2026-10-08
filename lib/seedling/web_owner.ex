defmodule Seedling.Web.Owner do
  @moduledoc false

  # The harness evaluates in a transient Task. Its first $callers PID is the agent.
  # Resolve a registered agent to its stable name so a supervised restart isn't a
  # cancellation. Ordinary process callers remain PID-owned and cancel on death.
  def resolve(owner \\ nil) do
    owner = owner || List.first(Process.get(:"$callers", [])) || self()

    cond do
      is_binary(owner) and Regex.match?(~r/\A[\w.-]+\z/, owner) ->
        {:ok, {:name, owner}}

      is_pid(owner) ->
        case Nano.Ops.owner(owner) do
          name when is_binary(name) -> {:ok, {:name, name}}
          _ -> {:ok, {:pid, owner}}
        end

      true ->
        {:error, %{kind: :invalid_owner}}
    end
  end

  def monitor({:name, _}), do: nil
  def monitor({:pid, pid}), do: Process.monitor(pid)

  def deliver({:pid, pid}, message, _opts), do: send(pid, message)

  def deliver({:name, name}, message, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :delivery_timeout, 300_000)
    deliver_named(name, message, deadline)
  end

  defp deliver_named(name, message, deadline) do
    case NanoAgent.whereis(name) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          deliver_named(name, message, deadline)
        else
          :delivery_timeout
        end

      pid ->
        send(pid, message)
    end
  end
end
