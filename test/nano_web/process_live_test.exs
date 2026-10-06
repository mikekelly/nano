defmodule NanoWeb.ProcessLiveTest do
  # Not async: the dashboard user's inbox is node-wide, and agents use the fake OpenRouter.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nano.FakeOpenRouter, as: Fake

  @endpoint NanoWeb.Endpoint

  setup do
    Fake.start()
    Nano.User.inbox("dashboard", clear: true)
    %{model: Fake.model(), conn: build_conn()}
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp start_agent(ctx, opts \\ []) do
    name = unique("agent")
    Fake.listen(ctx.model)
    {:ok, pid} = Nano.Ops.start_agent(name, [model: ctx.model] ++ opts)
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {name, pid}
  end

  # A process of kind :other that forwards whatever it receives to the test.
  defp other_process do
    test = self()

    %Task{pid: pid} =
      Task.Supervisor.async_nolink(Nano.EvalSupervisor, fn -> forward(test) end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp forward(test) do
    receive do
      msg -> send(test, {:forwarded, msg})
    end

    forward(test)
  end

  defp row(pid), do: "#p-" <> String.replace(inspect(pid), ~r/\D+/, "-")

  defp esc(pid),
    do: pid |> inspect() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  test "lists agents first with name and status, then users and other processes, in the spec's columns",
       ctx do
    {agent, agent_pid} = start_agent(ctx)
    user = unique("user")
    user_pid = Nano.User.start(user)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, user_pid) end)
    other = other_process()

    {:ok, view, html} = live(ctx.conn, "/")

    for column <- [
          "PID",
          "Name",
          "Kind",
          "Current function",
          "Msg queue",
          "Memory",
          "Reductions/s"
        ],
        do: assert(html =~ "<th>#{column}</th>" or html =~ ~s(<th class="num">#{column}</th>))

    assert has_element?(view, "#{row(agent_pid)}.agent a[href='/agents/#{agent}']", agent)
    assert has_element?(view, "#{row(agent_pid)} .badge.idle", "idle")
    assert has_element?(view, "#{row(agent_pid)} td.mono", ~r/^:gen_server\./)
    assert has_element?(view, "#{row(user_pid)}.user td", user)
    assert has_element?(view, "#{row(other)}.other td", "other")

    # Agents come first.
    {agent_at, _} = :binary.match(html, esc(agent_pid))
    {user_at, _} = :binary.match(html, esc(user_pid))
    assert agent_at < user_at

    # The standard set is excluded. (Under LiveViewTest the view is not under the endpoint,
    # so it is listed here, unlike in a browser.)
    refute html =~ esc(Process.whereis(Nano.StateStore))
  end

  test "processes spawned by an agent's eval are tagged with the agent", ctx do
    {agent, _} = start_agent(ctx)
    Fake.push(ctx.model, calls: [eval: "Task.start(fn -> Process.sleep(:infinity) end)"])
    Fake.push(ctx.model, text: "spawned")
    NanoAgent.notify(agent, :go)

    eventually(fn ->
      Enum.any?(Nano.Ops.processes(), &(&1.kind == {:spawned_by, agent}))
    end)

    %{pid: spawned} = Enum.find(Nano.Ops.processes(), &(&1.kind == {:spawned_by, agent}))
    on_exit(fn -> Process.exit(spawned, :kill) end)

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#{row(spawned)}.spawned a[href='/agents/#{agent}']", agent)
    assert render(view) =~ "spawned by"
  end

  test "refreshes every second; reductions/s is the delta between refreshes", ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    other = other_process()
    refute has_element?(view, row(other))

    # The interval timer delivers :refresh; sending it directly does the same without waiting.
    send(view.pid, :refresh)
    assert has_element?(view, row(other))
    assert has_element?(view, "#{row(other)} td.num:nth-child(7)", "–")

    for _ <- 1..50, do: send(other, :work)
    send(view.pid, :refresh)
    rate = view |> element("#{row(other)} td.num:nth-child(7)") |> render()
    assert rate =~ ~r/>[\d,]+</

    # And the real timer fires on its own.
    Process.exit(other, :kill)
    eventually(fn -> not has_element?(view, row(other)) end, 150)
  end

  test "the start form defaults to start idle and opens the new agent", ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#start input[type=checkbox][name=start_idle][checked]")
    name = unique("started")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    Fake.listen(ctx.model)

    assert {:error, {:live_redirect, %{to: "/agents/" <> ^name}}} =
             view
             |> form("#start", %{name: name, model: ctx.model, start_idle: "true"})
             |> render_submit()

    assert %{model: model, status: :idle} = Nano.Ops.agent(name)
    assert model == ctx.model
    refute_receive {:openrouter_request, _, _}, 100
  end

  test "the start form keeps what was typed across the periodic re-render", ctx do
    {:ok, view, _} = live(ctx.conn, "/")

    view
    |> form("#start", %{name: "half_typed", start_idle: "false", max_turns: "4"})
    |> render_change()

    send(view.pid, :refresh)
    assert has_element?(view, "#start input[name=name][value=half_typed]")
    assert has_element?(view, "#start input[name=max_turns][value='4']")
    refute has_element?(view, "#start input[type=checkbox][checked]")
    _ = ctx
  end

  test "the start form can start an agent busy, with a budget", ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    name = unique("busy")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    Fake.listen(ctx.model)

    view
    |> form("#start", %{name: name, model: ctx.model, start_idle: "false", max_turns: "3"})
    |> render_submit()

    assert_receive {:openrouter_request, _, _}, 2_000
    assert %{budget: %{max_turns: 3}} = Nano.Ops.agent(name)
  end

  test "the start form shows why an agent could not start", ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    html = view |> form("#start", %{name: "no spaces"}) |> render_submit()
    assert html =~ "name must be letters, digits"

    {agent, _} = start_agent(ctx)
    html = view |> form("#start", %{name: agent}) |> render_submit()
    assert html =~ "already running"
  end

  test "any process row has the send form: text via say, terms via send_raw, parse errors shown",
       ctx do
    target = other_process()
    {:ok, view, _} = live(ctx.conn, "/")
    dashboard = Nano.User.pid("dashboard")

    refute has_element?(view, "#{row(target)} .send")
    view |> element("#{row(target)} button", "send") |> render_click()
    assert has_element?(view, "#{row(target)} .send")

    view |> element("#{row(target)} form", "say") |> render_submit(%{text: "hello there"})
    assert_receive {:forwarded, %{sender_pid: ^dashboard, message: "hello there"}}
    assert render(view) =~ "said &quot;hello there&quot; to #{esc(target)}"

    view
    |> element("#{row(target)} form", "send term")
    |> render_submit(%{term: ~s|{:ping, 42, %{note: "hi"}}|})

    assert_receive {:forwarded, {:ping, 42, %{note: "hi"}}}

    html =
      view |> element("#{row(target)} form", "send term") |> render_submit(%{term: "{:ping,"})

    assert html =~ "SyntaxError" or html =~ "TokenMissingError"
    assert html =~ ~s(class="sent error")
    refute_receive {:forwarded, _}, 50

    html =
      view
      |> element("#{row(target)} form", "send term")
      |> render_submit(%{term: ~s|raise "nope"|})

    assert html =~ "nope"

    # The box keeps a failed term for fixing; a successful send empties it.
    view |> element("#{row(target)} form", "send term") |> render_change(%{term: ":ok"})
    assert has_element?(view, "#{row(target)} input[name=term][value=':ok']")
    view |> element("#{row(target)} form", "send term") |> render_submit(%{term: ":ok"})
    assert_receive {:forwarded, :ok}
    assert has_element?(view, "#{row(target)} input[name=term][value='']")
  end

  test "replies to the dashboard user show in its inbox", ctx do
    {:ok, view, html} = live(ctx.conn, "/")
    assert html =~ "Nothing received yet"
    assert html =~ esc(Nano.User.pid("dashboard"))

    send(Nano.User.pid("dashboard"), {:reply, "yes, I am here"})
    eventually(fn -> render(view) =~ "{:reply, &quot;yes, I am here&quot;}" end)

    view |> element(".inbox button", "clear") |> render_click()
    assert render(view) =~ "Nothing received yet"
    assert Nano.User.inbox("dashboard") == []
    _ = ctx
  end

  test "suspended agents offer Resume and halted agents Un-halt in their row", ctx do
    {agent, pid} = start_agent(ctx)
    :sys.suspend(pid)
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#{row(pid)} .badge.suspended")
    view |> element("#{row(pid)} button", "Resume") |> render_click()
    refute Nano.Ops.agent(agent).suspended
    refute has_element?(view, "#{row(pid)} .badge.suspended")

    {halted, hpid} = start_agent(ctx, max_turns: 1)
    Fake.push(ctx.model, text: "first and last")
    NanoAgent.notify(halted, :wake)
    eventually(fn -> Nano.Ops.agent(halted).budget.turns_used == 1 end)
    NanoAgent.notify(halted, :again)
    eventually(fn -> Nano.Ops.agent(halted).halted == :budget end)
    send(view.pid, :refresh)
    assert has_element?(view, "#{row(hpid)} .badge.halted", "halted: budget")
    Fake.push(ctx.model, text: "ok")
    view |> element("#{row(hpid)} button", "Un-halt") |> render_click()
    eventually(fn -> Nano.Ops.agent(halted).halted == nil end)
  end
end
