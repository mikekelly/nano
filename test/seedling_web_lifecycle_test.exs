defmodule Seedling.WebLifecycleTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake
  alias Seedling.WebFixture, as: Fixture

  setup do
    Fake.start()
    name = "web-life-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(dir)

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)
      File.rm_rf(dir)
    end)

    %{name: name, dir: dir, model: Fake.model()}
  end

  defp eventually(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3000

    if result = fun.() do
      result
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("lifecycle condition timed out")

      Process.sleep(10)
      eventually(fun, deadline)
    end
  end

  defp eval(ctx, expression) do
    target = inspect(List.to_string(:erlang.pid_to_list(self())))

    code =
      "result = " <>
        expression <>
        "; send(:erlang.list_to_pid(String.to_charlist(#{target})), {:eval_started, self(), result}); result"

    Fake.listen(ctx.model)
    Fake.push(ctx.model, calls: [eval: code])
    Fake.push(ctx.model, calls: [idle: nil])
    {:ok, pid} = NanoAgent.start([name: ctx.name] ++ Fake.opts(ctx.model))
    send(pid, :begin_lifecycle_test)
    assert_receive {:eval_started, task, result}, 3000
    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    refute Process.alive?(task)
    {pid, result}
  end

  defp restart(ctx, old) do
    Fake.push(ctx.model, text: "Restarted; waiting for job")
    Process.exit(old, :kill)

    new =
      eventually(fn ->
        case NanoAgent.whereis(ctx.name) do
          p when is_pid(p) and p != old -> p
          _ -> false
        end
      end)

    eventually(fn -> NanoAgent.info(ctx.name).status == :idle end)
    new
  end

  test "real NanoAgent eval starts research, eval exits, agent restarts, final event reaches new PID",
       ctx do
    {:ok, ready} = Agent.start_link(fn -> false end)

    {http, base} =
      Fixture.start(fn conn ->
        status = if Agent.get(ready, & &1), do: "completed", else: "running"

        Fixture.json(conn, 200, %{
          "id" => "agent_run_lifecycle",
          "status" => status,
          "output" => %{
            "structured" => %{"answer" => "from source"},
            "grounding" => [%{"url" => "https://source.test"}]
          }
        })
      end)

    on_exit(fn -> if Process.alive?(http), do: GenServer.stop(http) end)

    opts = [
      api_key: "not-real",
      base_url: base,
      cache_dir: ctx.dir,
      poll_interval: 10,
      max_wait: 5000
    ]

    {agent, {:ok, run}} =
      eval(ctx, "Seedling.Search.research(\"lifecycle query\", #{inspect(opts)})")

    assert Process.alive?(run.worker)
    new = restart(ctx, agent)
    assert Process.alive?(run.worker)
    Agent.update(ready, fn _ -> true end)
    id = NanoAgent.info(ctx.name).id

    event =
      eventually(fn ->
        Enum.find(Nano.Log.read(id), fn e ->
          e["type"] == "event_received" and Jason.encode!(e) =~ "seedling_research"
        end)
      end)

    assert Jason.encode!(event) =~ "completed"
    assert NanoAgent.whereis(ctx.name) == new
    assert {:ok, page} = Seedling.Search.research_read(run.run_id, opts)
    assert Jason.decode!(page.text)["output"]["structured"] == %{"answer" => "from source"}
  end

  @tag skip: System.find_executable("lightpanda") == nil
  test "real NanoAgent eval CDP server survives eval task and named-agent restart", ctx do
    {agent, {:ok, server}} = eval(ctx, "Seedling.Browser.serve(lifetime: 5000)")
    on_exit(fn -> Seedling.Browser.stop(server) end)
    assert Process.alive?(server.pid)
    restart(ctx, agent)
    assert Process.alive?(server.pid)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, server.port, [:binary, active: false], 1000)
    :gen_tcp.close(socket)
    Seedling.Browser.stop(server)
  end

  @tag skip: System.find_executable("lightpanda") == nil
  test "async browser uses shared detached Background and can be read as bounded page", ctx do
    {http, base} =
      Fixture.start(fn conn ->
        Process.sleep(100)
        Fixture.text(conn, "<p>Detached rendered page</p>")
      end)

    on_exit(fn -> if Process.alive?(http), do: GenServer.stop(http) end)
    opts = [root: Path.join(ctx.dir, "background"), timeout: 3000]

    {_, {:ok, worker, job_id}} =
      eval(ctx, "Seedling.Browser.fetch_async(#{inspect(base)}, #{inspect(opts)})")

    id = NanoAgent.info(ctx.name).id

    event =
      eventually(fn ->
        Enum.find(Nano.Log.read(id), fn e ->
          e["type"] == "event_received" and Jason.encode!(e) =~ job_id and
            Jason.encode!(e) =~ "background"
        end)
      end)

    assert event
    info = if Process.alive?(worker), do: Seedling.Background.info(worker), else: nil
    paths = Path.wildcard(Path.join([ctx.dir, "background", ctx.name, job_id, "output.log"]))
    assert [path] = paths

    assert {:ok, page} =
             Seedling.Browser.read_background(%{status: 0, output: path},
               cache_dir: ctx.dir,
               limit: 12
             )

    assert page.text =~ "Detached"
    assert page.truncated
    if info, do: Seedling.Background.cancel(worker)
  end
end
