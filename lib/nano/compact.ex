defmodule Nano.Compact do
  @moduledoc ~S"""
  Hand a running agent a smaller conversation, from outside it.

  Nothing in the harness replaces a transcript: `NanoAgent` only ever appends, and the context
  the model is sent is `system_prompt <> transcript`, so a summary written as a reply changes
  nothing. The transcript lives in three places that can all be rewritten at once: the running
  GenServer's state, the `Nano.StateStore` row, and the per-agent state file. This module
  rewrites all three:

      Nano.Compact.transcript("reviewer", &Nano.Compact.keep_ends(&1, 8, 40))

  The caller supplies a function from the current transcript to a shorter one. A transcript is
  valid for the chat API only when every assistant tool_calls is followed by a tool message
  with a matching tool_call_id; `repair/1` enforces that, so a compaction cannot leave the next
  request malformed.

  It is safe on a live agent: the running process is updated with :sys.replace_state/2, so no
  turn is lost and no message is re-sent. An agent cannot do this to itself mid-turn (the
  state it would replace is the state the request was built from) - it is an operator's move.
  """

  @doc ~S"""
  Replaces the transcript of agent `name` with `fun.(current)`, repaired so it stays valid,
  and returns before/after message counts and byte sizes. Raises if there is no stored state.
  """
  def transcript(name, fun) do
    before = current(name)
    after_ = before |> fun.() |> repair()
    write(name, after_)

    %{
      before: length(before),
      after: length(after_),
      bytes_before: bytes(before),
      bytes_after: bytes(after_)
    }
  end

  @doc ~S"""
  The transcript as the running agent will send it: the live process state when it is running,
  else the stored row. Raises if there is no state at all.
  """
  def current(name) do
    case NanoAgent.whereis(name) do
      nil -> state(name).transcript
      pid -> :sys.get_state(pid).transcript
    end
  end

  @doc ~S"""
  Keeps the first `first` and last `last` messages, with one user message in between recording
  how many were dropped. The opening (the task) and the recent work survive.
  """
  def keep_ends(t, first, last), do: keep_ends(t, first, last, "messages dropped")

  def keep_ends(t, first, last, label) do
    n = length(t)

    if n <= first + last do
      t
    else
      note = %{
        "role" => "user",
        "content" => "[" <> Integer.to_string(n - first - last) <> " " <> label <> "]"
      }

      Enum.take(t, first) ++ [note] ++ Enum.take(t, -last)
    end
  end

  @doc ~S"""
  Keeps `head` messages at the front and `tail` at the back, with one user message holding
  `summary` between them. The point of a compaction that keeps the work.
  """
  def summarize(t, head, tail, summary) do
    n = length(t)

    if n <= head + tail do
      t
    else
      Enum.take(t, head) ++ [%{"role" => "user", "content" => summary}] ++ Enum.take(t, -tail)
    end
  end

  @doc ~S"""
  A valid transcript: every assistant tool_calls is followed, in order, by a tool message for
  each call id, and no tool message is left without its call. Drops a half-answered assistant
  message with its partial results, and any orphan tool message. Idempotent.
  """
  def repair(t), do: scan(t, [])

  defp scan([], done), do: Enum.reverse(done)

  defp scan([%{"role" => "assistant", "tool_calls" => calls} = m | rest], done)
       when is_list(calls) and calls != [] do
    ids = Enum.map(calls, & &1["id"])
    {results, rest} = take_tools(rest, ids, [])
    answered = Enum.map(results, & &1["tool_call_id"])

    if Enum.all?(ids, &(&1 in answered)),
      do: scan(rest, Enum.reverse([m | results]) ++ done),
      else: scan(rest, done)
  end

  defp scan([%{"role" => "tool"} | rest], done), do: scan(rest, done)
  defp scan([m | rest], done), do: scan(rest, [m | done])

  # The leading run of tool messages answering `pending`; stops at the first other message.
  defp take_tools([%{"role" => "tool", "tool_call_id" => id} = t | rest], pending, acc) do
    if id in pending,
      do: take_tools(rest, pending, [t | acc]),
      else: {Enum.reverse(acc), [t | rest]}
  end

  defp take_tools(rest, _pending, acc), do: {Enum.reverse(acc), rest}

  defp state(name) do
    case Nano.StateStore.get(name) do
      %{} = s -> s
      _ -> raise ArgumentError, "no stored state for agent " <> inspect(name)
    end
  end

  # The live process (if running), the store row, and so the state file.
  defp write(name, t) do
    case NanoAgent.whereis(name) do
      nil -> :ok
      pid -> :sys.replace_state(pid, &%{&1 | transcript: t})
    end

    Nano.StateStore.put(name, %{state(name) | transcript: t})
  end

  defp bytes(t), do: t |> Enum.map(&byte_size(&1["content"] || "")) |> Enum.sum()
end
