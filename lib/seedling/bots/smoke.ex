defmodule Seedling.Bots.Smoke do
  @moduledoc """
  Reproducible, opt-in, bounded real-provider acceptance smoke. Never runs automatically.

      Seedling.Bots.Smoke.start(%{
        model: "explicit/connected-model", reasoning: "explicit-supported-level",
        max_context: 64000, max_turns: 8, max_tokens: 40000
      }, notify: {:agent, "atlas"}, timeout: 45000)

  These spending limits apply **per bot/session agent** (four pairs may start), not
  to the whole smoke. The configured providers/decision service may charge normally;
  this helper never reads, exports or changes credentials. Passing a config is an
  explicit choice to spend. A new private root is generated; `root:` must not exist.
  Consumer defaults and other agents are never reconfigured or stopped.

  Starts two identities; asks one to remember a hotel preference; checks a separate
  session's recall and a two-bot greeting; then exercises a clearly scripted human
  request, correlation, answer and acknowledgement. It reports **observed replies**,
  not a claim that their contents are correct. Inspect the snippets and durable root.

  Returns `{:ok, %{pid:, root:}}` immediately. Completion is
  `{:bots_smoke, root, {:ok, evidence} | {:error, text}}`. `notify:` may be a pid or
  `{:agent, name}` (resolved on completion); default is the calling eval's agent or
  ordinary caller. Each phase waits at most `timeout:` milliseconds (default 45000,
  allowed 100..120000). All smoke sessions are stopped and their harness agents/tasks
  terminated, including on errors/timeouts; saved harness entries are removed to
  avoid reviving work at reboot. Bot identities, memories, messages and normal harness
  logs remain for audit. Remove the private root/logs when no longer needed.

  Stop and cleanup are best effort if the node itself is down. No actual OS browser
  notification display is claimed here; browser hooks are tested separately.
  """
  alias Seedling.Bots

  def start(config, opts \\ []) do
    if valid?(config, opts) do
      root =
        Path.expand(
          opts[:root] ||
            Path.join(
              System.tmp_dir!(),
              "atlas-bots-smoke-" <> Base.encode16(:crypto.strong_rand_bytes(8))
            )
        )

      if File.exists?(root) do
        {:error,
         "Smoke root must be a new private directory; existing identities are never touched."}
      else
        notify = opts[:notify] || List.first(Process.get(:"$callers", [])) || self()

        config =
          Map.new(config, fn {k, v} -> {to_string(k), v} end) |> Map.put("exchange_ceiling", 2)

        timeout = opts[:timeout] || 45000

        pid =
          spawn(fn ->
            result =
              try do
                run(config, root, timeout)
              rescue
                _ -> {:error, "Smoke failed; inspect this private root's saved messages/status."}
              catch
                _, _ -> {:error, "Smoke process unavailable; inspect this private root."}
              end

            logs = cleanup(root)

            result =
              case result do
                {:ok, evidence} -> {:ok, Map.put(evidence, :logs, logs)}
                error -> error
              end

            deliver(notify, {:bots_smoke, root, result})
          end)

        {:ok, %{pid: pid, root: root}}
      end
    else
      {:error,
       "Supply explicit model/reasoning and positive per-pair max_context/max_turns/max_tokens; timeout 100..120000, root path and pid or named-agent notify."}
    end
  rescue
    _ ->
      {:error, "Invalid smoke config/options. See Seedling.Bots.Smoke docs; nothing was started."}
  end

  defp valid?(config, opts) do
    is_map(config) and is_list(opts) and Keyword.keyword?(opts) and
      Enum.all?(Map.keys(config), &(is_binary(&1) or is_atom(&1))) and
      (config[:model] || config["model"]) not in [nil, ""] and
      is_binary(config[:model] || config["model"]) and
      is_binary(config[:reasoning] || config["reasoning"]) and
      Enum.all?(~w(max_context max_turns max_tokens), fn key ->
        value = config[key] || config[String.to_existing_atom(key)]
        is_integer(value) and value > 0
      end) and
      (opts[:timeout] == nil or (is_integer(opts[:timeout]) and opts[:timeout] in 100..120_000)) and
      (opts[:root] == nil or is_binary(opts[:root])) and notify?(opts[:notify])
  end

  defp notify?(nil), do: true
  defp notify?(pid) when is_pid(pid), do: true
  defp notify?({:agent, name}), do: is_binary(name)
  defp notify?(_), do: false

  defp run(config, root, timeout) do
    opts = [root: root]

    with {:ok, _} <- Bots.configure(config, opts),
         {:ok, muse} <- Bots.create_bot("Muse smoke", opts),
         {:ok, dots} <- Bots.create_bot("Dots smoke", opts),
         {:ok, one} <- Bots.create_session([muse["id"]], opts),
         {:ok, _} <-
           Bots.say(
             one["id"],
             "Please remember in durable bot memory: I prefer quiet hotels. Acknowledge in one short sentence using Bots.post.",
             opts
           ),
         {:ok, first} <- wait(one["id"], 1, opts, timeout),
         {:ok, two} <- Bots.create_session([muse["id"]], opts),
         {:ok, _} <-
           Bots.say(
             two["id"],
             "What hotel noise preference do I have? Answer in one sentence using Bots.post.",
             opts
           ),
         {:ok, second} <- wait(two["id"], 1, opts, timeout),
         {:ok, group} <- Bots.create_session([muse["id"], dots["id"]], opts),
         {:ok, _} <-
           Bots.say(
             group["id"],
             "Muse and Dots: each say hello in fewer than ten words using Bots.post. Do not answer each other's greeting.",
             opts
           ),
         {:ok, both} <- wait(group["id"], 2, opts, timeout),
         {:ok, request} <-
           Bots.ask_human(
             muse["id"],
             "Scripted smoke request: choose a city.",
             opts ++ [session: one["id"], correlation: "smoke-city", reply_to: self()]
           ),
         {:ok, _} <- Bots.answer(request["id"], "Kyoto", opts),
         :ok <- receive_answer(request["id"], opts, timeout) do
      {:ok,
       %{
         root: root,
         identities: [muse["id"], dots["id"]],
         sessions: [one["id"], two["id"], group["id"]],
         request: request["id"],
         replies:
           Enum.map(first ++ second ++ both, fn m ->
             %{speaker: m["name"], text: String.slice(m["text"], 0, 300)}
           end)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected smoke result; inspect the private root."}
    end
  end

  defp receive_answer(id, opts, timeout) do
    receive do
      {:bots_human_answer, ^id, "smoke-city", "Kyoto"} ->
        case Bots.ack(id, opts) do
          {:ok, _} -> :ok
          error -> error
        end
    after
      timeout -> {:error, "Scripted human answer did not arrive before timeout."}
    end
  end

  defp wait(sid, count, opts, timeout),
    do: poll(sid, count, opts, System.monotonic_time(:millisecond) + timeout)

  defp poll(sid, count, opts, deadline) do
    with {:ok, page} <- Bots.history(sid, opts) do
      replies = Enum.filter(page.messages, &(&1["from"] not in ["human", "system"]))

      cond do
        length(replies) >= count ->
          {:ok, replies}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error,
           "No bot post before timeout. All smoke sessions/agents will be stopped; inspect retained messages and logs."}

        true ->
          Process.sleep(50)
          poll(sid, count, opts, deadline)
      end
    end
  end

  defp cleanup(root) do
    case Bots.snapshot(root: root, limit: 1000) do
      {:ok, snapshot} ->
        for session <- snapshot.sessions, do: Bots.stop(session["id"], root: root)

        for session <- snapshot.sessions,
            bid <- session["bots"],
            name = Bots.Runtime.name(bid, session["id"], root),
            info = NanoAgent.info(name),
            info != nil do
          if pid = NanoAgent.whereis(name) do
            DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
            NanoAgent.kill_tasks(pid)
          end

          Nano.StateStore.delete(name)

          %{
            agent: name,
            path:
              Path.join(Application.get_env(:nano, :log_dir, "/data/logs"), info.id <> ".jsonl")
          }
        end

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp deliver({:agent, name}, message),
    do: if(pid = NanoAgent.whereis(name), do: send(pid, message))

  defp deliver(pid, message) when is_pid(pid), do: send(pid, message)
end
