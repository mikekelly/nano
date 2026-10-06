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

  test "the layout carries a banner that app.css shows only while the page is disconnected" do
    html = build_conn() |> get("/") |> html_response(200)

    # A sibling after the LiveView container, so `[data-phx-main].phx-error ~ #disconnected` matches.
    assert html =~
             ~r/data-phx-main.*<div id="disconnected" role="alert">\s*Disconnected from the node/s

    # LiveView's debug logging stays off unless turned on from the console.
    assert html =~ ~s|sessionStorage.getItem("phx:live-socket:debug") === null|

    css = build_conn() |> get("/app.css") |> response(200)
    assert css =~ "#disconnected {\n  display: none;"
    assert css =~ "[data-phx-main].phx-error ~ #disconnected { display: block; }"
    # No rule on phx-loading, which every initial join and navigation sets briefly.
    refute css =~ ".phx-loading"
  end

  test "the start form's reasoning level: node default preselected, kept across re-renders, passed on",
       ctx do
    level = hd(NanoAgent.reasoning_levels() -- ["off"])
    selected = &"#start select[name=reasoning] option[selected][value='#{&1}']"

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, selected.(Application.fetch_env!(:nano, :reasoning)))

    for l <- ["off" | NanoAgent.reasoning_levels()],
        do: assert(has_element?(view, "#start select[name=reasoning] option[value='#{l}']"))

    view |> form("#start", %{name: "typing", reasoning: level}) |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, selected.(level))

    for reasoning <- ["off", level] do
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)
      {:ok, view, _} = live(ctx.conn, "/")

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#start", %{name: name, model: ctx.model, reasoning: reasoning})
               |> render_submit()

      assert Nano.Ops.agent(name).reasoning == reasoning
    end
  end

  test "the start form's prompt file survives re-renders and is passed on", ctx do
    file = "tmp/prompt_#{System.unique_integer([:positive])}.txt"
    File.mkdir_p!("tmp")
    File.write!(file, "You are {{name}}, from the form's file.")
    on_exit(fn -> File.rm(file) end)

    {:ok, view, _} = live(ctx.conn, "/")

    assert has_element?(
             view,
             "#start input[name=system_prompt_file][placeholder*='priv/system_prompt.txt']"
           )

    view |> form("#start", %{name: "typing", system_prompt_file: file}) |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, "#start input[name=system_prompt_file][value='#{file}']")

    name = unique("agent")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#start", %{name: name, model: ctx.model, system_prompt_file: file})
             |> render_submit()

    assert Nano.Ops.agent(name).system_prompt == "You are #{name}, from the form's file."

    {:ok, view, _} = live(ctx.conn, "/")

    html =
      view
      |> form("#start", %{
        name: unique("agent"),
        model: ctx.model,
        system_prompt_file: "tmp/none.txt"
      })
      |> render_submit()

    assert html =~ "cannot read system_prompt_file: no such file or directory"
  end

  test "the start form rejects a limit that is not a whole number, 0 or more", ctx do
    {:ok, view, _} = live(ctx.conn, "/")

    for {field, value} <- [max_turns: "abc", max_tokens: "1.5", max_context: "x", max_turns: "-3"] do
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)

      html =
        view
        |> form("#start", %{:name => name, :model => ctx.model, field => value})
        |> render_submit()

      assert html =~ "max turns, max tokens and max context must be whole numbers, 0 or more"
      assert Nano.Ops.agent(name) == nil
    end
  end

  test "the start form's three limits accept 0 (no limit), survive re-renders, and are passed on",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/")

    for field <- ~w(max_turns max_tokens max_context) do
      assert has_element?(
               view,
               "#start input[name=#{field}][min='0'][placeholder*='0 = no limit']"
             )
    end

    view |> form("#start", %{name: "typing", max_context: "1234"}) |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, "#start input[name=max_context][value='1234']")

    name = unique("agent")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    limits = %{max_turns: "0", max_tokens: "0", max_context: "4321"}

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#start", Map.merge(%{name: name, model: ctx.model}, limits))
             |> render_submit()

    assert %{max_turns: 0, max_tokens: 0, max_context: 4321} = Nano.Ops.agent(name).budget
  end

  test "a suspended dashboard user does not take the page down", ctx do
    {name, _} = start_agent(ctx)
    user = Nano.User.pid("dashboard")
    :sys.suspend(user)
    on_exit(fn -> :sys.resume(user) end)

    {:ok, view, html} = live(ctx.conn, "/")
    assert html =~ "The dashboard user is not responding"
    view |> element("#{row(Nano.Ops.whereis(name))} button", "send") |> render_click()

    html =
      view
      |> element("#{row(Nano.Ops.whereis(name))} form", "say")
      |> render_submit(%{text: "hello"})

    assert html =~ "not responding (suspended or flooded?); the message is queued"
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

  defp inbox_count(view, selector, text \\ "") do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#inbox-menu " <> selector)
    |> Enum.count(&(LazyHTML.text(&1) =~ text))
  end

  test "the inbox sits behind an icon with a count; messages are made readable", ctx do
    user = Nano.User.pid("dashboard")
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "header.top #inbox-menu summary svg")
    refute has_element?(view, "#inbox-menu summary .count:not(.new)")
    refute has_element?(view, "aside")

    long = String.duplicate("a long reply that keeps going ", 4)
    send(user, "line one\nline two")
    send(user, {:reply, "multi\nline"})
    send(user, %{sender_pid: self(), message: long})
    send(user, {:ping, 42})
    # They arrive live, newest first, and the count follows.
    eventually(fn -> inbox_count(view, "#inbox li") == 4 end)
    assert inbox_count(view, "summary .count", "4") == 1

    # A bare string is just text, with its line break.
    assert inbox_count(view, "li .body", "line one\nline two") == 1
    assert inbox_count(view, "li .summary", "line one") == 0
    # A tuple: the one-line summary, then the readable string and where it sat.
    assert inbox_count(view, "li .summary", ~s|{:reply, "multi\\nline"}|) == 1
    assert inbox_count(view, "li .where", "elem 1") == 1
    assert inbox_count(view, "li .body", "multi\nline") == 1
    # A map: the key labels the text.
    assert inbox_count(view, "li .where", "message:") == 1
    assert inbox_count(view, "li .body", long) == 1
    # Short and structural: the summary alone.
    assert inbox_count(view, "li .summary", "{:ping, 42}") == 1

    [first | _] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#inbox li")
      |> Enum.to_list()

    assert LazyHTML.text(first) =~ "{:ping, 42}"

    view |> element(".inbox button", "clear") |> render_click()
    assert inbox_count(view, "#inbox li") == 0
    refute has_element?(view, "#inbox-menu summary .count:not(.new)")
    _ = ctx
  end

  test "hostile inbox terms render, bounded" do
    user = Nano.User.pid("dashboard")
    deep = Enum.reduce(1..10_000, "a deep string\nat the bottom", fn _, acc -> {acc} end)
    many = for i <- 1..20, do: "string number #{i} is long enough to be shown as text, surely"
    huge = List.duplicate(String.duplicate("z", 70), 100_000)

    for term <- [
          deep,
          <<255, 0, 10, 65>>,
          many,
          huge,
          fn -> :ok end,
          [1, 2 | String.duplicate("t", 80)],
          %{"key" => String.duplicate("v\n", 3000)}
        ],
        do: send(user, term)

    {:ok, view, _} = live(build_conn(), "/")
    eventually(fn -> inbox_count(view, "#inbox li") == 7 end)
    assert inbox_count(view, "li .summary", "#Function<") == 1
    assert inbox_count(view, "li .summary", "<<255, 0, 10, 65>>") == 1
    assert inbox_count(view, "li .where", "tail") == 1
    assert inbox_count(view, "li .where", ~s|"key" =>|) == 1
  end

  test "texts/1 finds long or multi-line strings with where they sat, within limits" do
    alias NanoWeb.Components
    long = String.duplicate("x", 70)

    assert Components.texts({:a, %{message: "two\nlines", other: "short"}}) ==
             [{"elem 1 › message:", "two\nlines"}]

    assert Components.texts([1, long]) == [{"item 1", long}]
    assert length(Components.texts(List.duplicate(long, 50))) == 6
    assert Components.texts(<<255, 10>>) == []
    assert Components.texts({<<255, 10>> <> long}) == []
    [{nil, clipped}] = Components.texts(String.duplicate("y", 10_000))
    assert String.length(clipped) < 4100
    # Deeper than 8 levels is not looked into.
    assert Components.texts(Enum.reduce(1..12, long, fn _, acc -> {acc} end)) == []
  end

  test "suspended agents offer Resume and halted agents Un-halt in their row", ctx do
    {agent, pid} = start_agent(ctx)
    :sys.suspend(pid)
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#{row(pid)} .badge.suspended")
    view |> element("#{row(pid)} button", "Resume") |> render_click()
    refute Nano.Ops.agent(agent).suspended
    refute has_element?(view, "#{row(pid)} .badge.suspended")

    # The agent halts as soon as its last turn is used, so it needs room for a turn after un-halt.
    {halted, hpid} = start_agent(ctx, max_turns: 2)
    Fake.push(ctx.model, text: "first")
    NanoAgent.notify(halted, :wake)
    eventually(fn -> Nano.Ops.agent(halted).budget.turns_used == 1 end)
    Fake.push(ctx.model, text: "last")
    NanoAgent.notify(halted, :again)
    eventually(fn -> Nano.Ops.agent(halted).halted == :budget end)
    send(view.pid, :refresh)
    assert has_element?(view, "#{row(hpid)} .badge.halted", "halted: budget")
    Fake.push(ctx.model, text: "ok")
    view |> element("#{row(hpid)} button", "Un-halt") |> render_click()
    eventually(fn -> Nano.Ops.agent(halted).halted == nil end)
  end
end
