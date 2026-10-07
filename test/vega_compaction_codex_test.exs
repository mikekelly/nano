defmodule Vega.CompactionCodexTest do
  use ExUnit.Case, async: false
  alias Nano.FakeChatGPT, as: Fake
  alias Nano.ChatGPT.Auth

  defp wait(fun, tries \\ 150)
  defp wait(_fun, 0), do: flunk("did not converge")

  defp wait(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait(fun, tries - 1)
        )
  end

  defp req(model) do
    assert_receive {:chatgpt_request, ^model, body, _headers}, 3_000
    body
  end

  setup do
    Fake.start()
    Fake.listen()
    Auth.logout()
    Fake.auth(:poll, [{200, :approved}])
    Fake.auth(:token, [{200, Fake.tokens()}])
    Auth.login()
    wait(fn -> Auth.status().status == :connected end)
    model = Fake.model()
    name = "codex-compact-#{System.unique_integer([:positive])}"
    saved_key = Nano.Settings.get(:openrouter_api_key)
    Nano.Settings.put(:openrouter_api_key, nil)

    {:ok, pid} =
      NanoAgent.start(
        name: name,
        model: "openai-codex/" <> model,
        reasoning: "off",
        max_context: 40_000,
        max_turns: 0,
        max_tokens: 0
      )

    on_exit(fn ->
      if live = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, live)
        NanoAgent.kill_tasks(live)
      end

      Nano.StateStore.delete(name)
      Auth.logout()
      :persistent_term.erase({Nano.ChatGPT, :models})
      Nano.Settings.put(:openrouter_api_key, saved_key)
    end)

    %{pid: pid, model: model, name: name}
  end

  test "Codex-only actual agent compacts across threshold and resumes without OR key", c do
    Fake.push(c.model,
      text: String.duplicate("older memory ", 1_000),
      calls: [idle: nil],
      usage: {25_000, 100, 0}
    )

    send(c.pid, :first)
    req(c.model)
    wait(fn -> :sys.get_state(c.pid).status == :idle end)
    send(c.pid, :second)
    summary_req = req(c.model)
    assert summary_req["instructions"] =~ "at most 5000 tokens"
    refute Map.has_key?(summary_req, "max_output_tokens")
    assert (summary_req["tools"] || []) == []
    Fake.push(c.model, text: "Older memory; continue second task.")
    body = req(c.model)
    assert Jason.encode!(body) =~ "harness automatically compacted"
    Fake.push(c.model, calls: [idle: nil])
    wait(fn -> :sys.get_state(c.pid).status == :idle end)
    assert NanoAgent.whereis(c.name) == c.pid
    assert NanoAgent.info(c.name).halted == nil
    assert hd(Nano.StateStore.get(c.name).transcript)["content"] =~ "Older memory"
  end

  test "Codex completion exceeding cap is rejected even with short visible text", c do
    Fake.push(c.model, text: "short text", usage: {100, 5_001, 0})

    assert {:error, _, _} =
             Vega.Compaction.summarize(
               "openai-codex/" <> c.model,
               [%{"role" => "user", "content" => "history"}],
               40_000
             )

    req(c.model)
  end
end
