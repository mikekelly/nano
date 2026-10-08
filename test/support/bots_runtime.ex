defmodule Seedling.Bots.TestRuntime do
  @moduledoc false
  def deliver(bot, session, message, memories, _config, root) do
    owner = root |> Path.join("test-owner") |> File.read!() |> :erlang.binary_to_term()
    name = {:bots_test, root, bot["id"], session["id"]}

    pid =
      case :global.whereis_name(name) do
        :undefined ->
          candidate =
            spawn(fn ->
              :global.register_name(name, self())
              ref = Process.monitor(owner)
              loop(ref)
            end)

          await(name, candidate)

        pid ->
          pid
      end

    send(owner, {:delivered, bot["id"], session["id"], message, memories, pid})
    {:ok, "scripted"}
  end

  def authorized?(caller, bot, session, root),
    do: :global.whereis_name({:bots_test, root, bot, session}) == caller

  defp await(name, pid) do
    if :global.whereis_name(name) == pid,
      do: pid,
      else:
        (
          Process.sleep(1)
          await(name, pid)
        )
  end

  defp loop(ref) do
    receive do
      {:post, owner, bot, session, text, opts} ->
        send(owner, {:posted, Seedling.Bots.post(bot, session, text, opts)})
        loop(ref)

      {:quiet, owner, bot, session, opts} ->
        send(owner, {:quieted, Seedling.Bots.quiet(bot, session, opts)})
        loop(ref)

      {:DOWN, ^ref, _, _, _} ->
        :ok
    end
  end
end

defmodule Seedling.Bots.TestGate do
  @moduledoc false
  def reply?(_, _, message), do: message["text"] != "silent"

  def memories(bot, message, candidates, opts \\ []),
    do:
      Seedling.Bots.Gate.memories(
        bot,
        message,
        candidates,
        Keyword.put(opts, :decision, __MODULE__)
      )

  def evaluate(_, _, _), do: {:error, :missing_credentials}
end
