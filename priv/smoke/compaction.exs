# Explicitly spends real provider tokens; never run as part of ExUnit.
# Code.eval_string(File.read!("priv/smoke/compaction.exs"), confirm_spend: true, notify: me)
# Returns a background task/name/report path; sends {:compaction_smoke, report} on completion.
options = binding()

unless options[:confirm_spend] == true,
  do: raise("pass confirm_spend: true to run a real provider smoke test")

model = options[:model] || "openai-codex/gpt-6.1-sol"
notify = options[:notify]
name = "compaction-smoke-#{System.unique_integer([:positive])}"
report_path = Path.join(System.tmp_dir!(), name <> ".txt")

{:ok, task} =
  Task.start(fn ->
    try do
      {:ok, pid} =
        NanoAgent.start(
          name: name,
          model: model,
          reasoning: "low",
          max_turns: 35,
          max_tokens: 250_000,
          max_context: 20_000,
          system_prompt:
            "You are a real harness smoke-test agent. Keep replies short. Initial setup: evaluate sentinel = 73 then reply READY. Padding messages: only reply ACK with no tools. Verification: evaluate the existing sentinel binding, never reassign it, and report its value. Never read or write files or fetch external pages. Continue after automatic harness compaction. Pid {{pid}}, name {{name}}."
        )

      wait = fn wait, predicate, left ->
        cond do
          predicate.() ->
            :ok

          left == 0 ->
            raise("model response timeout")

          NanoAgent.info(name).halted != nil ->
            raise("agent halted: #{inspect(NanoAgent.info(name).halted)}")

          true ->
            Process.sleep(200)
            wait.(wait, predicate, left - 1)
        end
      end

      turn = fn text ->
        before = Nano.StateStore.get(name).responses
        send(pid, text)

        wait.(
          wait,
          fn ->
            s = Nano.StateStore.get(name)
            s.responses > before and s.status == :idle
          end,
          450
        )
      end

      turn.("Initial setup: evaluate sentinel = 73, then say READY.")

      padding = fn padding, n ->
        cond do
          NanoAgent.info(name).compactions > 0 ->
            :ok

          n > 8 ->
            raise("no checkpoint after eight padding turns")

          true ->
            data =
              Enum.map_join(1..350, " ", fn i ->
                :crypto.hash(:sha256, "#{n}-#{i}")
                |> Base.encode16(case: :lower)
                |> String.slice(0, 20)
              end)

            turn.("ACK only, no tools. Keep sentinel=73 commitment. Test padding #{n}:\n" <> data)
            padding.(padding, n + 1)
        end
      end

      padding.(padding, 1)

      turn.(
        "Verification: evaluate the existing sentinel binding, do NOT assign it, then report its value."
      )

      info = NanoAgent.info(name)
      log = Nano.Log.read(info.id)
      checkpoint = Enum.find(log, &(&1["type"] == "compaction_completed"))
      final = Enum.filter(log, &(&1["type"] == "tool_result")) |> List.last()

      unless info.pid == pid and info.restart_count == 0 and info.halted == nil and
               final["result"] == "73",
             do: raise("identity/binding preservation assertion failed")

      report = %{
        result: :passed,
        info: Map.take(info, [:id, :name, :model, :pid, :restart_count, :compactions, :budget]),
        checkpoint:
          Map.take(checkpoint, [
            "seq",
            "context_estimate",
            "prompt_tokens",
            "completion_tokens",
            "record"
          ]),
        final_tool_result: final["result"]
      }

      File.write!(report_path, inspect(report, limit: :infinity, pretty: true))
      if is_pid(notify), do: send(notify, {:compaction_smoke, report_path, report})
    rescue
      error ->
        report = %{result: :failed, error: Exception.message(error), name: name}
        File.write!(report_path, inspect(report))
        if is_pid(notify), do: send(notify, {:compaction_smoke, report_path, report})
    after
      # Stops only this uniquely named test agent. The complete provider log remains on disk.
      Nano.Ops.stop_agent(name)
    end
  end)

%{task: task, name: name, report_path: report_path}
