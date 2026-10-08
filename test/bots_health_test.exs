defmodule BotsHealthTest do
  use ExUnit.Case, async: true

  defmodule Runtime do
    def dispatch(_bot, _session, context, opts) do
      send(opts[:observer], {:grant, context.token})
      {:ok, opts[:agent]}
    end

    def status(_bot, _session, opts) do
      send(opts[:observer], {:health_probe, self()})

      case Agent.get(opts[:agent], & &1) do
        :blocked -> Process.sleep(:infinity)
        value -> value
      end
    end

    def stop(_, _, _), do: :ok
  end

  defmodule Router do
    def select([bot | _], _, %{"kind" => "human"}, _), do: {:ok, [bot["id"]]}
    def select(_, _, _, _), do: {:ok, []}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "bots-health-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    agent = start_supervised!({Agent, fn -> {:ok, %{halted: nil}} end})

    server =
      start_supervised!(
        {Bots,
         name: nil,
         root: root,
         runtime: Runtime,
         router: Router,
         agent: agent,
         observer: self(),
         health_interval: 20,
         health_timeout: 40}
      )

    on_exit(fn -> File.rm_rf(root) end)
    opts = [server: server]
    {:ok, bot} = Bots.create_bot(%{name: "Mira"}, opts)
    {:ok, chat} = Bots.create_session([bot["id"]], opts)
    %{agent: agent, opts: opts, sid: chat["id"]}
  end

  defp eventually(fun, left \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end

  test "live process halted after dispatch is surfaced promptly and its grant fenced", ctx do
    Bots.say(ctx.sid, "hello", ctx.opts)
    assert_receive {:grant, token}
    assert_receive {:health_probe, _}
    Agent.update(ctx.agent, fn _ -> {:error, {:agent_halted, :node_budget}} end)
    eventually(fn -> Bots.session(ctx.sid, ctx.opts)["status"] == "error" end)
    text = List.last(Bots.session(ctx.sid, ctx.opts)["messages"])["text"]
    assert text =~ "hourly token budget"
    assert text =~ "operator"
    assert Process.alive?(ctx.agent)
    assert {:error, :stale_token} = Bots.post(token, "late reply", ctx.opts)
    assert Agent.get(ctx.agent, & &1) == {:error, {:agent_halted, :node_budget}}
  end

  test "provider and operator suspension are distinct from timeout", ctx do
    for {reason, expected} <- [
          {{:agent_halted, :provider_unavailable}, "provider is unavailable"},
          {:agent_suspended, "suspended by an operator"},
          {{:agent_halted, :operator}, "bot halted"}
        ] do
      Agent.update(ctx.agent, fn _ -> {:error, reason} end)
      Bots.say(ctx.sid, "retry", ctx.opts)
      assert_receive {:grant, _}
      eventually(fn -> Bots.session(ctx.sid, ctx.opts)["status"] == "error" end)
      assert List.last(Bots.session(ctx.sid, ctx.opts)["messages"])["text"] =~ expected
    end
  end

  test "blocked status probes are bounded and never block product interactions", ctx do
    Agent.update(ctx.agent, fn _ -> :blocked end)
    Bots.say(ctx.sid, "hello", ctx.opts)
    assert_receive {:grant, _}
    assert_receive {:health_probe, worker}
    assert is_map(Bots.snapshot(ctx.opts))
    eventually(fn -> not Process.alive?(worker) end)
    assert Bots.session(ctx.sid, ctx.opts)["status"] == "thinking"
    assert {:ok, _} = Bots.stop(ctx.sid, ctx.opts)
    assert Bots.session(ctx.sid, ctx.opts)["status"] == "stopped"
  end

  test "obsolete health result cannot invalidate a fresh human grant", ctx do
    Agent.update(ctx.agent, fn _ -> :blocked end)
    Bots.say(ctx.sid, "old", ctx.opts)
    assert_receive {:grant, old}
    assert_receive {:health_probe, worker}
    Bots.say(ctx.sid, "new", ctx.opts)
    assert_receive {:grant, fresh}
    Agent.update(ctx.agent, fn _ -> {:ok, %{halted: nil}} end)
    eventually(fn -> not Process.alive?(worker) end)
    assert {:error, :stale_token} = Bots.post(old, "stale", ctx.opts)
    assert {:ok, _} = Bots.post(fresh, "fresh reply", ctx.opts)
    eventually(fn -> Bots.session(ctx.sid, ctx.opts)["status"] == "idle" end)

    refute Enum.any?(
             Bots.session(ctx.sid, ctx.opts)["messages"],
             &(&1["text"] =~ "could not respond")
           )
  end
end
