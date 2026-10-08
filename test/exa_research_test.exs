defmodule Exa.ResearchTest do
  use ExUnit.Case, async: true

  defp opts(transport, extra \\ []) do
    Keyword.merge(
      [
        transport: transport,
        notify: self(),
        poll_interval_ms: 1,
        poll_timeout_ms: 500,
        delivery_interval_ms: 1,
        delivery_timeout_ms: 100
      ],
      extra
    )
  end

  test "creates low-effort run with current API fields and delivers authoritative output" do
    owner = self()

    output = %{
      "text" => "answer",
      "structured" => %{"ok" => true},
      "grounding" => [%{"field" => "text", "citations" => [%{"url" => "https://example.org"}]}]
    }

    transport = fn method, path, body, _ ->
      send(owner, {:request, method, path, body})

      case method do
        :post -> {:ok, %{"id" => "agent_run_1", "status" => "queued"}}
        :get -> {:ok, %{"id" => "agent_run_1", "status" => "completed", "output" => output}}
      end
    end

    assert {:ok, %{id: "agent_run_1", poller: pid}} =
             Exa.Research.start("question", opts(transport, output_schema: %{"type" => "object"}))

    assert is_pid(pid)

    assert_receive {:request, :post, "/agent/runs",
                    %{
                      "query" => "question",
                      "effort" => "low",
                      "outputSchema" => %{"type" => "object"}
                    }}

    assert_receive {:request, :get, "/agent/runs/agent_run_1", nil}

    assert_receive {:exa_research, "agent_run_1",
                    {:ok, %{data: %{"output" => ^output}, truncated: false}}}
  end

  test "resuming polls queued and running before completion without creating a run" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    transport = fn :get, "/agent/runs/existing", nil, _ ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      {:ok, %{"status" => Enum.at(["queued", "running", "completed"], min(n, 2))}}
    end

    assert {:ok, %{id: "existing"}} = Exa.Research.resume("existing", opts(transport))
    assert_receive {:exa_research, "existing", {:ok, %{data: %{"status" => "completed"}}}}, 500
    assert Agent.get(counter, & &1) == 3
  end

  test "failed and cancelled terminal states are bounded error events" do
    for status <- ["failed", "cancelled"] do
      transport = fn :get, _, nil, _ ->
        {:ok, %{"status" => status, "error" => %{"message" => "no output"}}}
      end

      assert {:ok, _} = Exa.Research.resume(status, opts(transport))

      assert_receive {:exa_research, ^status,
                      {:error, %{data: %{"status" => ^status}, truncated: false}}}
    end
  end

  test "get and cancel are snapshots; cancellation uses POST and terminal response is preserved" do
    owner = self()

    transport = fn method, path, body, _ ->
      send(owner, {method, path, body})
      {:ok, %{"status" => "cancelled"}}
    end

    assert {:ok, %{data: %{"status" => "cancelled"}}} = Exa.Research.get("id", opts(transport))
    assert_receive {:get, "/agent/runs/id", nil}
    assert {:ok, %{data: %{"status" => "cancelled"}}} = Exa.Research.cancel("id", opts(transport))
    assert_receive {:post, "/agent/runs/id/cancel", nil}
    refute_receive {:exa_research, _, _}, 10
  end

  test "poller is unlinked and name is re-resolved after original caller dies" do
    owner = self()
    {:ok, current} = Agent.start_link(fn -> nil end)
    resolver = fn "restartable" -> Agent.get(current, & &1) end
    transport = fn :get, _, nil, _ -> {:ok, %{"status" => "completed"}} end

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, result} =
          Exa.Research.resume(
            "restart",
            opts(transport,
              notify: "restartable",
              resolve_name: resolver,
              delivery_timeout_ms: 500
            )
          )

        send(owner, {:launched, result.poller})
      end)

    assert_receive {:launched, poller}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert Process.alive?(poller)

    replacement =
      spawn(fn ->
        receive do
          event -> send(owner, {:forwarded, event})
        end
      end)

    Agent.update(current, fn _ -> replacement end)
    assert_receive {:forwarded, {:exa_research, "restart", {:ok, _}}}, 500
  end

  test "missing name delivery is bounded" do
    transport = fn _, _, _, _ -> {:ok, %{"status" => "completed"}} end

    assert {:ok, %{poller: pid}} =
             Exa.Research.resume(
               "missing",
               opts(transport,
                 notify: "missing",
                 resolve_name: fn _ -> nil end,
                 delivery_timeout_ms: 30
               )
             )

    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
  end

  test "deadline kills a stuck polling transport and emits timeout without cancelling remote run" do
    owner = self()

    transport = fn :get, _, nil, _ ->
      send(owner, {:transport_pid, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, _} = Exa.Research.resume("slow", opts(transport, poll_timeout_ms: 30))
    assert_receive {:transport_pid, pid}
    monitor = Process.monitor(pid)

    assert_receive {:exa_research, "slow", {:error, %{data: %{code: :poll_timeout, id: "slow"}}}},
                   500

    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 500
  end

  test "HTTP and transport exceptions are error values, not crashed pollers" do
    transport = fn _, _, _, _ -> {:error, %{code: :http, status: 429}} end
    assert {:error, %{data: %{status: 429}}} = Exa.Research.start("q", opts(transport))
    assert {:ok, _} = Exa.Research.resume("http", opts(transport))
    assert_receive {:exa_research, "http", {:error, %{data: %{status: 429}}}}
    raising = fn _, _, _, _ -> raise "secret transport details" end
    assert {:ok, _} = Exa.Research.resume("raise", opts(raising))
    assert_receive {:exa_research, "raise", {:error, bound}}
    refute inspect(bound) =~ "secret transport details"
  end

  test "invalid inputs never hit transport" do
    never = fn _, _, _, _ -> flunk("must not request") end
    assert {:error, _} = Exa.Research.start(" ", opts(never))
    assert {:error, _} = Exa.Research.get("../bad", opts(never))
    assert {:error, _} = Exa.Research.resume("id", opts(never, notify: nil))
    assert {:error, _} = Exa.Research.resume("id", opts(never, poll_interval_ms: 0))
    assert {:error, _} = Exa.Research.cancel("id", :invalid)
  end

  test "malformed create response and unknown statuses are explicit errors" do
    no_id = fn _, _, _, _ -> {:ok, %{"status" => "queued"}} end
    assert {:error, _} = Exa.Research.start("q", opts(no_id))
    unknown = fn _, _, _, _ -> {:ok, %{"status" => "new_status"}} end
    assert {:ok, _} = Exa.Research.resume("unknown", opts(unknown))
    assert_receive {:exa_research, "unknown", {:error, %{data: %{code: :unexpected_status}}}}
  end

  test "large completed output and error payloads are bounded" do
    large = String.duplicate("text", 10_000)

    transport = fn _, _, _, _ ->
      {:ok, %{"status" => "completed", "output" => %{"text" => large}}}
    end

    assert {:ok, _} = Exa.Research.resume("large", opts(transport, max_bytes: 256))
    assert_receive {:exa_research, "large", {:ok, %{truncated: true} = bound}}, 500
    assert byte_size(Jason.encode!(bound)) < 1024
    errors = fn _, _, _, _ -> {:error, %{"message" => large}} end

    assert {:error, %{truncated: true} = bound} =
             Exa.Research.get("large", opts(errors, max_bytes: 256))

    assert byte_size(Jason.encode!(bound)) < 1024
  end
end
