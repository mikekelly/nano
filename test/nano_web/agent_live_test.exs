defmodule NanoWeb.AgentLiveTest do
  # Not async: the dashboard user's inbox is node-wide, and agents use the fake OpenRouter.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nano.FakeOpenRouter, as: Fake

  @endpoint NanoWeb.Endpoint

  setup do
    Fake.start()
    saved = Application.get_env(:nano, :openrouter_backoff_ms)
    Application.put_env(:nano, :openrouter_backoff_ms, 1)
    on_exit(fn -> Application.put_env(:nano, :openrouter_backoff_ms, saved) end)
    Nano.User.inbox("dashboard", clear: true)
    name = "a#{System.unique_integer([:positive])}"
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    %{model: Fake.model(), name: name, conn: build_conn()}
  end

  defp start!(ctx, opts \\ []) do
    Fake.listen(ctx.model)
    {:ok, pid} = Nano.Ops.start_agent(ctx.name, Fake.opts(ctx.model, opts))
    id = Nano.Ops.agent(ctx.name).id
    Nano.Log.subscribe(id)
    {pid, id}
  end

  # Waits for a log entry of type (from the live broadcast).
  defp await(type, fun \\ fn _ -> true end) do
    receive do
      {:nano_log, %{type: ^type} = entry} ->
        if fun.(entry), do: entry, else: await(type, fun)
    after
      2_000 -> flunk("no #{type} entry")
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp has_entry?(view, type, text),
    do: has_element?(view, "#timeline li.#{type}", text)

  # One scripted turn: an event, a model turn with an eval (code, result, IO), a final model
  # turn with text, then turn_ended.
  defp script_turn(ctx) do
    Fake.push(ctx.model,
      text: "Let me look.",
      calls: [eval: ~s|IO.puts("hello from eval")\nEnum.sum([1, 2, 39]) # answer|],
      usage: {1200, 30, 0},
      cost: 0.0021
    )

    Fake.push(ctx.model, text: "The answer is 42.", usage: {1300, 12, 1100}, cost: 0.0009)
  end

  defp assert_turn_rendered(view) do
    assert has_entry?(view, "event", "{:question, 6, 7}")
    assert has_entry?(view, "request", "model request")
    assert has_entry?(view, "response", "Let me look.")
    assert has_entry?(view, "response", "1,200 in (0 cached) · 30 out · $0.0021")
    # Tool calls collapsed inline in the model turn.
    assert has_element?(view, "#timeline li.response details.calls summary", "1 tool call: eval")
    # The eval: highlighted code, then result, captured IO and duration.
    assert has_element?(view, "#timeline li.eval pre.code span.md", "IO")
    assert has_element?(view, "#timeline li.eval pre.code span.st", ~s|"hello from eval"|)
    assert has_element?(view, "#timeline li.eval pre.code span.cm", "# answer")
    assert has_element?(view, "#timeline li.eval .result pre", "42")
    assert has_element?(view, "#timeline li.eval .io pre", "hello from eval")
    assert has_element?(view, "#timeline li.eval .meta", ~r/\d+ ms · ok/)
    assert has_entry?(view, "response", "The answer is 42.")
    assert has_entry?(view, "turn-ended", "no_tool_call")
  end

  test "renders the backlog: every entry type of a turn, and the header numbers", ctx do
    {_pid, _id} = start!(ctx, start_idle: false)
    Fake.push(ctx.model, text: "Started.")
    await(:turn_ended)
    script_turn(ctx)
    NanoAgent.notify(ctx.name, {:question, 6, 7})
    await(:turn_ended)

    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    assert has_entry?(view, "started", "started")
    assert has_entry?(view, "note", "Your process has just started.")
    assert_turn_rendered(view)

    html = view |> element("section.bar") |> render()
    assert html =~ ctx.model
    assert html =~ ~s(class="badge idle")
    %{max_turns: max_turns, max_tokens: max_tokens} = Nano.Ops.agent(ctx.name).budget
    assert html =~ ~r|<dt>reasoning</dt>\s*<dd>off</dd>|
    assert html =~ "3 / #{max_turns}"
    assert html =~ "2,652 / #{NanoWeb.Components.int(max_tokens)}"
    assert max_tokens == 30_000_000
    assert html =~ "$0.0040"
    # One of the three responses had cached tokens.
    assert html =~ "33%"

    # The system prompt, collapsible at the top.
    assert has_element?(
             view,
             "details#system-prompt pre",
             "I am the GenServer you are running in"
           )
  end

  test "streams entries live as they are logged", ctx do
    {_pid, _id} = start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    assert has_entry?(view, "started", "started")
    refute has_element?(view, "#timeline li.event")

    # Hold the second model call so the eval can be seen before its turn ends.
    Fake.push(ctx.model,
      text: "Let me look.",
      calls: [eval: ~s|IO.puts("hello from eval")\nEnum.sum([1, 2, 39]) # answer|],
      usage: {1200, 30, 0},
      cost: 0.0021
    )

    NanoAgent.notify(ctx.name, {:question, 6, 7})
    await(:tool_result)
    eventually(fn -> has_element?(view, "#timeline li.eval .result pre", "42") end)
    eventually(fn -> has_element?(view, "section.bar .badge.thinking") end)

    Fake.push(ctx.model, text: "The answer is 42.", usage: {1300, 12, 1100}, cost: 0.0009)
    await(:turn_ended)
    eventually(fn -> has_entry?(view, "turn-ended", "no_tool_call") end)
    assert_turn_rendered(view)
    eventually(fn -> view |> element("section.bar") |> render() =~ "2 / 50" end)
  end

  test "an eval in progress shows as running, then gets its result", ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    Fake.push(ctx.model, calls: [eval: "receive do :go -> :went end"])
    NanoAgent.notify(ctx.name, :start)
    await(:tool_call)
    eventually(fn -> has_element?(view, "#timeline li.eval .meta", "running…") end)
    assert has_element?(view, "section.bar .badge.running_tool")

    # The eval runs in a task the agent spawned (once its state is saved); let it finish.
    Fake.push(ctx.model, calls: [idle: 5_000])
    eventually(fn -> match?(%{task: %{task: %Task{}}}, Nano.StateStore.get(ctx.name)) end)

    for %{kind: {:spawned_by, name}, pid: pid} <- Nano.Ops.processes(),
        name == ctx.name,
        do: send(pid, :go)

    eventually(fn -> has_element?(view, "#timeline li.eval .result pre", ":went") end)
    eventually(fn -> has_element?(view, "#timeline li.idle", "wakeup after 5000 ms") end)
  end

  test "failed evals, unknown tools, model errors and budget exhaustion", ctx do
    start!(ctx, max_turns: 2)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    Fake.push(ctx.model, calls: [eval: ~s|raise "boom"|, bogus: %{x: 1}])
    Fake.push(ctx.model, status: 400)
    NanoAgent.notify(ctx.name, :go)
    await(:turn_ended, &(&1.reason == "error"))

    eventually(fn -> has_element?(view, "#timeline li.eval.failed pre.error", "boom") end)
    assert has_element?(view, "#timeline li.eval.failed", ~s|tool call 2: "bogus"|)
    assert has_element?(view, "#timeline li.error", "model error, request 2")
    assert has_element?(view, "#timeline li.error", "status 400")

    NanoAgent.notify(ctx.name, :again)
    await(:budget_exhausted)
    eventually(fn -> has_element?(view, "#timeline li.error", "budget exhausted") end)
    assert has_element?(view, "#timeline li.error", "turns 2 / 2")
  end

  test "shows a model turn's reasoning when the entry carries one", ctx do
    {_, id} = start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")

    Nano.Log.write(%{id: id, name: ctx.name}, :model_response, %{
      request_id: 1,
      text: "Hello.",
      reasoning: "The operator wants a greeting.",
      tool_calls: [],
      prompt_tokens: 10,
      completion_tokens: 2,
      cached_tokens: 0,
      cost: 0.0001
    })

    eventually(fn ->
      has_element?(view, "#timeline li.response .reasoning", "wants a greeting")
    end)

    assert has_element?(view, "#timeline li.response .assistant", "Hello.")
  end

  test "any halt reason is flagged with Un-halt offered", ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    # A halt value this view has no special wording for still shows, with Un-halt.
    state = Nano.StateStore.get(ctx.name)
    Nano.StateStore.put(ctx.name, %{state | halted: :node_budget})
    send(view.pid, :refresh)
    assert has_element?(view, "section.bar .badge.halted", "halted: node_budget")
    assert has_element?(view, ".flag.halted", "node-wide hourly token cap")
    assert has_element?(view, "button", "Un-halt")
  end

  test "the bar's Send message and Advanced message panels: say, send_raw, close on success",
       ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    Fake.push(ctx.model, calls: [idle: nil])
    Fake.push(ctx.model, calls: [idle: nil])
    assert has_element?(view, "section.bar #say-menu.dropdown summary", "Send message")
    assert has_element?(view, "section.bar #raw-menu.dropdown summary", "Advanced message")
    refute has_element?(view, "main > .send")

    view |> element("#send-text") |> render_submit(%{text: "anyone home?"})
    assert_push_event(view, "close", %{id: "say-menu"})
    assert has_element?(view, ".controls .sent.ok", "said")
    entry = await(:event_received)
    assert entry.message =~ ~s(message: "anyone home?")
    assert entry.message =~ inspect(Nano.User.pid("dashboard"))
    await(:turn_ended)

    view
    |> element("#send-raw-term")
    |> render_submit(%{term: ~s|{:hello, Nano.User.pid("dashboard"), "are you there?"}|})

    assert_push_event(view, "close", %{id: "raw-menu"})

    entry = await(:event_received)
    assert entry.message == inspect({:hello, Nano.User.pid("dashboard"), "are you there?"})
    eventually(fn -> has_entry?(view, "event", "are you there?") end)

    # A failed send keeps its panel open with the error in it.
    html = view |> element("#send-raw-term") |> render_submit(%{term: "%{oops"})
    refute_push_event(view, "close", _)
    assert html =~ ~s(class="sent error")
    assert html =~ "MissingError" or html =~ "SyntaxError"
  end

  test "replies that land in the dashboard user's inbox show on the page", ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")

    Fake.push(ctx.model,
      calls: [eval: ~s|send(Nano.User.pid("dashboard"), {:reply, "yes, I am here"})|]
    )

    Fake.push(ctx.model, calls: [idle: nil])

    view
    |> element(".send form", "send term")
    |> render_submit(%{term: ~s|{:hello, Nano.User.pid("dashboard"), "are you there?"}|})

    eventually(fn -> has_element?(view, ".inbox li .summary", ~s|{:reply, "yes, I am here"}|) end)
  end

  test "a suspended agent is labelled suspended and offers Resume", ctx do
    {pid, _} = start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    refute has_element?(view, "button", "Resume")

    :sys.suspend(pid)
    send(view.pid, :refresh)
    assert has_element?(view, "section.bar .badge.suspended")
    assert has_element?(view, ".flag.suspended")

    view |> element("button", "Resume") |> render_click()
    refute Nano.Ops.agent(ctx.name).suspended
    refute has_element?(view, "button", "Resume")
    refute has_element?(view, ".badge.suspended")
  end

  test "an agent suspended by its own eval resumes and finishes its turn", ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    Fake.push(ctx.model, calls: [eval: ":sys.suspend(me); :suspended_myself"])
    Fake.push(ctx.model, text: "back")
    NanoAgent.notify(ctx.name, :go)
    eventually(fn -> Nano.Ops.agent(ctx.name).suspended end)
    send(view.pid, :refresh)
    view |> element("button", "Resume") |> render_click()
    await(:turn_ended)
    eventually(fn -> has_element?(view, "#timeline li.eval .result pre", ":suspended_myself") end)
  end

  test "a halted agent is flagged until un-halted", ctx do
    # The agent halts as soon as its last turn is used, so it needs room for a turn after un-halt.
    start!(ctx, max_turns: 2)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    refute has_element?(view, "button", "Un-halt")
    Fake.push(ctx.model, text: "one")
    NanoAgent.notify(ctx.name, :one)
    await(:turn_ended)
    Fake.push(ctx.model, text: "last")
    NanoAgent.notify(ctx.name, :two)
    await(:budget_exhausted)

    eventually(fn -> Nano.Ops.agent(ctx.name).halted == :budget end)
    send(view.pid, :refresh)
    assert has_element?(view, "section.bar .badge.halted", "halted: budget")
    assert has_element?(view, ".flag.halted", "budget is used up")

    Fake.push(ctx.model, text: "two")
    view |> element("button", "Un-halt") |> render_click()
    await(:turn_ended, &(&1.reason == "no_tool_call"))
    eventually(fn -> not has_element?(view, ".flag.halted") end)
    refute has_element?(view, "button", "Un-halt")
    eventually(fn -> has_entry?(view, "note", "An operator un-halted you.") end)
  end

  test "Restart restarts the agent with its history; the timeline continues", ctx do
    {pid, _} = start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    view |> element("button", "Restart") |> render_click()
    await(:agent_started, & &1.restarted)
    assert Nano.Ops.whereis(ctx.name) != pid
    eventually(fn -> has_entry?(view, "started", "restarted") end)
    assert has_entry?(view, "started", ":operator_restart")

    eventually(fn ->
      view |> element("section.bar") |> render() =~ ~r/restarts<\/dt>\s*<dd>1</
    end)
  end

  test "Stop stops the agent; the page says so and follows a new agent of the same name", ctx do
    {_, old_id} = start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    view |> element("button", "Stop") |> render_click()
    assert Nano.Ops.agent(ctx.name) == nil
    assert has_element?(view, ".flag.down", "it was stopped")
    # The old timeline stays visible.
    assert has_entry?(view, "started", "started")

    {_, new_id} = start!(ctx)
    assert new_id != old_id
    send(view.pid, :refresh)
    assert has_element?(view, "header", new_id)
    refute has_element?(view, ".flag.down")
  end

  test "an unknown agent renders a note" do
    {:ok, _view, html} = live(build_conn(), "/agents/nobody_here")
    assert html =~ ~s(No agent named &quot;nobody_here&quot; is running)
  end

  test "hostile log entries never stop the page from rendering", ctx do
    {_pid, id} = start!(ctx)
    agent = %{id: id, name: ctx.name}

    hostile = [
      {:tool_call, %{name: "eval", call_id: "c1", call_seq: 1, arguments: %{"code" => nil}}},
      {:tool_call, %{name: "idle", call_id: "c2", call_seq: 2, arguments: "nonsense"}},
      {:tool_call, %{name: %{"x" => 1}, call_id: "c3", call_seq: [1], arguments: [1, 2]}},
      {:model_response,
       %{
         request_id: 9,
         text: %{"odd" => 1},
         reasoning: [1, %{}],
         tool_calls: "garbage",
         cost: "free",
         prompt_tokens: nil,
         cached_tokens: "x",
         completion_tokens: %{},
         latency_ms: nil,
         provider: nil,
         finish_reason: 3
       }},
      {:model_response,
       %{request_id: 10, tool_calls: [%{"function" => "x"}, 5, %{"function" => %{"name" => 7}}]}},
      {:event_received, %{event_seq: "x", message: %{"a" => [1, %{}]}, queue_length: nil}},
      {:tool_result, %{name: nil, result: [1, %{}], io: %{"x" => 1}, ok: false}},
      {:model_error, %{request_id: nil, status: %{}, body: [1, 2], attempt: []}},
      {:budget_exhausted, %{scope: nil, turns_used: nil, tokens_used: "x"}},
      {:turn_ended, %{reason: %{}}},
      {:harness_note, %{text: nil}},
      {:something_new, %{nested: %{"deep" => [1, 2]}}}
    ]

    for {type, fields} <- hostile, do: Nano.Log.write(agent, type, fields)

    {:ok, view, html} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    assert html =~ ~s(tool call 1: &quot;eval&quot;)
    assert has_entry?(view, "event", ~s(%{"a" => [1, %{}]}))

    # The reading view, from the backlog and then with the same entries arriving live.
    {:ok, reading, html} = live(ctx.conn, "/agents/#{ctx.name}")
    assert html =~ ~s(tool call &quot;eval&quot;)

    # The same entries arriving live.
    for {type, fields} <- hostile, do: Nano.Log.write(agent, type, fields)
    await(:something_new)
    assert render(view) =~ "something_new"
    assert render(reading) =~ ~s(%{&quot;a&quot; =&gt; [1, %{}]})
  end

  test "a suspended dashboard user does not take the page down", ctx do
    start!(ctx)
    user = Nano.User.pid("dashboard")
    :sys.suspend(user)
    on_exit(fn -> :sys.resume(user) end)

    {:ok, view, html} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    assert html =~ "The dashboard user is not responding"

    assert view |> element("#send-text") |> render_submit(%{text: "hi"}) =~
             "will go out if it resumes"
  end

  test "every halt reason is labelled truthfully, with Un-halt offered", ctx do
    start!(ctx)

    for {reason, text} <- [
          budget: "its own turn or token budget is used up",
          context: "context limit reached",
          node_budget: "the node-wide hourly token cap was reached",
          provider_unavailable: "provider was turned off (OpenRouter&#39;s API key removed)",
          restart_brake: "restart brake: it restarted 3 times within 60 s",
          start_failed: "failed while starting or restoring",
          log_failed: "could not write its log",
          something_else: "reason :something_else"
        ] do
      Nano.StateStore.put(ctx.name, %{Nano.StateStore.get(ctx.name) | halted: reason})
      {:ok, view, html} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
      assert html =~ text
      assert has_element?(view, ".flag.halted")
      assert has_element?(view, "button", "Un-halt")
    end
  end

  test "the header shows turns, tokens and context as used / max, ∞ for no limit", ctx do
    {:ok, _} =
      Nano.Ops.start_agent(ctx.name, Fake.opts(ctx.model, max_turns: 0, max_context: 5000))

    {:ok, _view, html} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")

    assert html =~ ~r|<dt>turns</dt>\s*<dd>0 / ∞</dd>|
    assert html =~ ~r|<dt>context</dt>\s*<dd>0 / 5,000</dd>|
    tokens = NanoWeb.Components.int(30_000_000)
    assert html =~ ~r|<dt>tokens</dt>\s*<dd>0 / #{tokens}</dd>|
  end

  test "an agent whose saved state predates the context limit still renders", ctx do
    start!(ctx)
    old = Map.drop(Nano.StateStore.get(ctx.name), [:max_context, :context_used])
    Nano.StateStore.put(ctx.name, old)

    {:ok, _view, html} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    assert html =~ ~r|<dt>context</dt>\s*<dd>|

    assert %{"budget" => %{}} =
             build_conn() |> get("/api/agents/#{ctx.name}") |> json_response(200)
  end

  test "limit/2 renders used / max, ∞ for 0, – for a missing value" do
    assert NanoWeb.Components.limit(12, 0) == "12 / ∞"
    assert NanoWeb.Components.limit(2652, 3_000_000) == "2,652 / 3,000,000"
    assert NanoWeb.Components.limit(nil, nil) == "– / –"
  end

  test "the system prompt section says where the prompt came from", ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}")
    source = Nano.Ops.agent(ctx.name).prompt_source
    assert has_element?(view, "#system-prompt summary", "from #{source}")
  end

  test "the processes button counts what the agent's evals started and lists them", ctx do
    start!(ctx)
    Fake.push(ctx.model, calls: [eval: "spawn(fn -> Process.sleep(:infinity) end)"])
    Fake.push(ctx.model, calls: [idle: nil])
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}")
    assert has_element?(view, "#procs-menu summary", "0")
    assert has_element?(view, "#procs-menu .panel", "None running.")

    NanoAgent.notify(ctx.name, :go)
    await(:turn_ended)
    [row] = for %{kind: {:spawned_by, n}} = r <- Nano.Ops.processes(), n == ctx.name, do: r
    send(view.pid, :refresh)
    assert has_element?(view, "#procs-menu summary", "1")
    assert has_element?(view, "#procs-menu .panel li", inspect(row.pid))
    assert has_element?(view, "#procs-menu .panel li", "queue 0")
  end

  ## Reading view

  defp reading?(view, selector, text \\ nil),
    do: has_element?(view, "#timeline.reading " <> selector, text)

  test "the reading view is the default; the toggle switches views and is kept in the URL", ctx do
    start!(ctx)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}")
    assert has_element?(view, "#timeline.reading")
    assert has_element?(view, "nav.views a.current", "reading")

    view |> element("nav.views a", "debug") |> render_click()
    assert_patch(view, "/agents/#{ctx.name}?view=debug")
    assert has_element?(view, "#timeline.debug li.started")
    assert has_element?(view, "nav.views a.current", "debug")

    view |> element("nav.views a", "reading") |> render_click()
    assert_patch(view, "/agents/#{ctx.name}")
    assert reading?(view, "li.r.state", "started")
    refute has_element?(view, "#timeline li.entry")

    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}?view=debug")
    assert has_element?(view, "#timeline.debug")
  end

  test "a scripted turn reads as a story, from the backlog and live", ctx do
    {_pid, _id} = start!(ctx, start_idle: false)
    Fake.push(ctx.model, text: "Started.")
    await(:turn_ended)

    {:ok, live_view, _} = live(ctx.conn, "/agents/#{ctx.name}")
    script_turn(ctx)
    NanoAgent.notify(ctx.name, {:question, 6, 7})
    await(:turn_ended)
    {:ok, backlog_view, _} = live(ctx.conn, "/agents/#{ctx.name}")
    # The live view gets the agent's broadcasts on its own schedule.
    eventually(fn -> reading?(live_view, "li.r.says .prose", "The answer is 42.") end)

    for view <- [backlog_view, live_view] do
      assert reading?(view, "li.r.state", "started")
      assert reading?(view, "li.r.note", "Your process has just started.")
      assert reading?(view, "li.r.event pre", "{:question, 6, 7}")
      assert reading?(view, "li.r.says .prose", "Let me look.")
      assert reading?(view, "li.r.says .prose", "The answer is 42.")
      # The code and its result as one unit.
      assert reading?(view, "li.r.eval pre.code span.st", ~s|"hello from eval"|)
      assert reading?(view, "li.r.eval .result pre", "42")
      assert reading?(view, "li.r.eval .io pre", "hello from eval")
      assert reading?(view, "li.r.eval .r-label", ~r/ok · \d+ ms/)
      # The plumbing is left out.
      html = view |> element("#timeline") |> render()
      refute html =~ "model request"
      refute html =~ "turn ended"
      refute html =~ "Used so far"
      refute html =~ ~s(class="seq")
    end
  end

  test "each kind of reading item, from the backlog and live", ctx do
    {_pid, id} = start!(ctx)
    agent = %{id: id, name: ctx.name}

    entries = fn n ->
      [
        {:tool_call,
         %{name: "eval", call_id: "e#{n}", call_seq: 1, arguments: %{"code" => "1 + :a"}}},
        {:tool_result,
         %{
           call_id: "e#{n}",
           name: "eval",
           ok: false,
           duration_ms: 3,
           result: "** (ArithmeticError) bad",
           io: ""
         }},
        {:tool_call,
         %{
           name: "eval",
           call_id: "r#{n}",
           call_seq: 2,
           arguments: %{"code" => "Process.sleep(1)"}
         }},
        {:tool_call, %{name: "idle", call_id: "i#{n}", call_seq: 3, arguments: %{}}},
        {:tool_call,
         %{name: "idle", call_id: "w#{n}", call_seq: 4, arguments: %{"wakeup_after" => 5000}}},
        {:model_response, %{request_id: n, text: "Plain words.", reasoning: "Thinking it over."}},
        {:model_response,
         %{request_id: n, text: nil, tool_calls: [%{"function" => %{"name" => "idle"}}]}},
        {:agent_started, %{restarted: true, exit_reason: ":killed", halted: "restart_brake"}},
        {:harness_note,
         %{text: "Too many restarts, so I have halted you: I will not call the model."}},
        {:harness_note, %{text: "An operator un-halted you."}},
        {:model_error, %{request_id: n, status: 500, body: "upstream broke", retry: false}},
        {:model_error, %{request_id: n, status: 502, body: "retried quietly", retry: true}},
        {:model_request, %{request_id: n, budget_note: "<harness>Used so far: 1 turns</harness>"}}
      ]
    end

    for {type, fields} <- entries.(1), do: Nano.Log.write(agent, type, fields)
    {:ok, view, _} = live(ctx.conn, "/agents/#{ctx.name}")

    check = fn count ->
      n = fn selector, text ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#timeline.reading " <> selector)
        |> Enum.count(&(LazyHTML.text(&1) =~ text))
      end

      assert n.("li.r.eval.failed", "ArithmeticError") == count
      assert n.("li.r.eval.running", "running…") == count
      assert n.("li.r.idle", "idle") == 2 * count
      assert n.("li.r.idle", "wake after 5000 ms") == count
      assert n.("li.r.says details.reasoning", "Thinking it over.") == count
      assert n.("li.r.says .prose", "Plain words.") == count
      assert n.("li.r.state", "restarted") == count
      assert n.("li.r.state .badge.halted", "restart_brake") == count
      assert n.("li.r.note.halt", "so I have halted you") == count
      assert n.("li.r.note.halt", "un-halted you") == count
      assert n.("li.r.state.error", "upstream broke") == count
      assert n.("li", "retried quietly") == 0
      assert n.("li", "Used so far") == 0
    end

    check.(1)
    refute has_element?(view, "li.r.says details.reasoning[open]")

    for {type, fields} <- entries.(2), do: Nano.Log.write(agent, type, fields)
    await(:model_request)
    check.(2)
  end
end
