defmodule NanoWeb.ProcessLiveTest do
  # Not async: the dashboard user is node-wide, and agents use the fake OpenRouter.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Nano.FakeOpenRouter, as: Fake

  @endpoint NanoWeb.Endpoint

  setup do
    Fake.start()
    %{model: Fake.model(), conn: build_conn()}
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp start_agent(ctx, opts \\ []) do
    name = unique("agent")
    Fake.listen(ctx.model)
    {:ok, pid} = Nano.Ops.start_agent(name, Fake.opts(ctx.model, opts))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {name, pid}
  end

  # Types a model into the start form's box, as a person would before starting: the model
  # then sets the reasoning level and max context.
  defp choose(view, model),
    do: view |> form("#start", %{model: model}) |> render_change(%{_target: ["model"]})

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

    {:ok, view, html} = live(ctx.conn, "/?view=debug")

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
    # A prior recovery test may have restarted StateStore. The documented standard set
    # is a boot-time PID snapshot, not a permanent whitelist of registered service names.
    refute has_element?(view, row(Process.whereis(:code_server)))
    store = Process.whereis(Nano.StateStore)

    assert has_element?(view, row(store)) ==
             not MapSet.member?(Nano.Application.boot_set(), store)
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

    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    assert has_element?(view, "#{row(spawned)}.spawned a[href='/agents/#{agent}']", agent)
    assert render(view) =~ "spawned by"
  end

  test "refreshes every second; reductions/s is the delta between refreshes", ctx do
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
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
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    assert has_element?(view, "#start input[type=checkbox][name=start_idle][checked]")
    name = unique("started")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    Fake.listen(ctx.model)
    choose(view, ctx.model)

    assert {:error, {:live_redirect, %{to: "/agents/" <> ^name}}} =
             view
             |> form("#start", %{name: name, start_idle: "true"})
             |> render_submit()

    assert %{model: model, status: :idle} = Nano.Ops.agent(name)
    assert model == ctx.model
    refute_receive {:openrouter_request, _, _}, 100
  end

  test "the start form keeps what was typed across the periodic re-render", ctx do
    {:ok, view, _} = live(ctx.conn, "/?view=debug")

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
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    name = unique("busy")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    Fake.listen(ctx.model)
    choose(view, ctx.model)

    view
    |> form("#start", %{name: name, start_idle: "false", max_turns: "3"})
    |> render_submit()

    assert_receive {:openrouter_request, _, _}, 2_000

    assert %{budget: %{max_turns: 3, max_tokens: 0, max_context: 1_000_000}} =
             Nano.Ops.agent(name)
  end

  test "the start form shows why an agent could not start", ctx do
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    html = view |> form("#start", %{name: "no spaces"}) |> render_submit()
    assert html =~ "name must be letters, digits"

    html = view |> form("#start", %{name: "fine"}) |> render_submit()
    assert html =~ "missing model: give a model slug"

    {agent, _} = start_agent(ctx)
    choose(view, ctx.model)
    html = view |> form("#start", %{name: agent}) |> render_submit()
    assert html =~ "already running"

    html =
      view |> form("#start", %{name: unique("agent"), max_context: "1000001"}) |> render_submit()

    assert html =~ "max_context must be a whole number of tokens from 1 to 1000000"
    # What was typed is kept, to be corrected.
    assert has_element?(view, "#start input[name=max_context][value='1000001']")
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

  test "the start form's reasoning level: the model's default preselected, kept across re-renders, passed on",
       ctx do
    level = hd(NanoAgent.reasoning_levels() -- ["off"])
    selected = &"#start select[name=reasoning] option[selected][value='#{&1}']"

    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    choose(view, ctx.model)
    assert has_element?(view, selected.("off"))

    for l <- ["off" | NanoAgent.reasoning_levels()],
        do: assert(has_element?(view, "#start select[name=reasoning] option[value='#{l}']"))

    view |> form("#start", %{name: "typing", reasoning: level}) |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, selected.(level))

    for reasoning <- ["off", level] do
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)
      {:ok, view, _} = live(ctx.conn, "/?view=debug")
      choose(view, ctx.model)

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#start", %{name: name, reasoning: reasoning})
               |> render_submit()

      assert Nano.Ops.agent(name).reasoning == reasoning
    end
  end

  test "the system prompt is default, file or custom: exactly one is shown and sent", ctx do
    file =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "prompt_#{System.unique_integer([:positive])}.txt"
      )

    File.write!(file, "You are {{name}}, from the form's file.")
    on_exit(fn -> File.rm(file) end)

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#start .segmented label.on", "default")
    refute has_element?(view, "#start input[name=system_prompt_file]")
    refute has_element?(view, "#start textarea[name=system_prompt]")

    view |> form("#start", %{name: "typing", prompt: "file"}) |> render_change()
    assert has_element?(view, "#start input[name=system_prompt_file]")
    refute has_element?(view, "#start textarea[name=system_prompt]")
    view |> form("#start", %{prompt: "file", system_prompt_file: file}) |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, "#start input[name=system_prompt_file][value='#{file}']")

    view |> form("#start", %{prompt: "custom"}) |> render_change()
    assert has_element?(view, "#start textarea[name=system_prompt]")
    refute has_element?(view, "#start input[name=system_prompt_file]")

    # The file is sent only when "file" is chosen, the template only when "custom" is.
    assert NanoWeb.StartForm.opts(%{
             "prompt" => "file",
             "system_prompt_file" => file,
             "system_prompt" => "x"
           })[:system_prompt] == nil

    assert NanoWeb.StartForm.opts(%{
             "prompt" => "custom",
             "system_prompt_file" => file,
             "system_prompt" => "x"
           })[:system_prompt_file] == nil

    assert NanoWeb.StartForm.opts(%{
             "prompt" => "default",
             "system_prompt_file" => file,
             "system_prompt" => "x"
           })
           |> Keyword.take([:system_prompt, :system_prompt_file]) == []

    name = unique("agent")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {:ok, view, _} = live(ctx.conn, "/")
    choose(view, ctx.model)
    view |> form("#start", %{prompt: "file"}) |> render_change()

    assert {:error, {:live_redirect, _}} =
             view
             |> form("#start", %{name: name, prompt: "file", system_prompt_file: file})
             |> render_submit()

    assert Nano.Ops.agent(name).system_prompt ==
             "You are #{name}, from the form's file.\n\n" <> Images.prompt(["text"])

    {:ok, view, _} = live(ctx.conn, "/")
    choose(view, ctx.model)
    view |> form("#start", %{prompt: "file"}) |> render_change()

    html =
      view
      |> form("#start", %{
        name: unique("agent"),
        prompt: "file",
        system_prompt_file: "tmp/none.txt"
      })
      |> render_submit()

    assert html =~ "cannot read the system prompt file tmp/none.txt: no such file or directory"
  end

  test "the model box: empty at first, a fuzzy filter over the model list, unlisted slugs refused",
       ctx do
    :persistent_term.erase({Nano.OpenRouter, :models})
    on_exit(fn -> :persistent_term.erase({Nano.OpenRouter, :models}) end)

    Fake.models([
      %{
        "id" => "deepseek/deepseek-v4.1-flash",
        "name" => "DeepSeek V4.1 Flash",
        "context_length" => 163_840
      },
      %{
        "id" => "anthropic/claude-haiku-4.5",
        "name" => "Anthropic: Claude Haiku 4.5",
        "context_length" => 200_000
      },
      %{"id" => "openai/gpt-5-mini", "name" => "OpenAI: GPT-5 Mini", "context_length" => 400_000}
    ])

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#start input[name=model][value='']")
    assert has_element?(view, "#start select[name=reasoning]")
    refute has_element?(view, "#start details")

    # Letters in order are enough: "dsflash" finds deepseek-v4.1-flash only.
    view |> form("#start", %{model: "dsflash"}) |> render_change()
    assert has_element?(view, "#start .matches button", "deepseek/deepseek-v4.1-flash")
    assert has_element?(view, "#start .matches", "163,840 context")
    refute has_element?(view, "#start .matches button", "claude")
    view |> form("#start", %{model: "claude"}) |> render_change()
    assert has_element?(view, "#start .matches button", "anthropic/claude-haiku-4.5")

    view |> element("#start .matches button", "anthropic/claude-haiku-4.5") |> render_click()
    assert has_element?(view, "#start input[name=model][value='anthropic/claude-haiku-4.5']")
    refute has_element?(view, "#start .matches")

    # A slug that is not in the list can be typed, but no agent starts on it.
    name = unique("agent")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    choose(view, "fake/unlisted")
    html = view |> form("#start", %{name: name, max_context: "1000"}) |> render_submit()
    assert html =~ "unknown model fake/unlisted: OpenRouter does not list it"
    assert Nano.Ops.agent(name) == nil
  end

  test "the chosen model sets the reasoning select (its levels, its default) and max context",
       ctx do
    :persistent_term.erase({Nano.OpenRouter, :models})
    on_exit(fn -> :persistent_term.erase({Nano.OpenRouter, :models}) end)
    reasoning = &%{"mandatory" => &1, "supported_efforts" => &2, "default_effort" => &3}

    Fake.models([
      %{
        "id" => "deepseek/deepseek-v4.1-flash",
        "context_length" => 1_048_576,
        "reasoning" => reasoning.(false, ~w(max high low), "high")
      },
      %{
        "id" => "openai/gpt-6.1-sol",
        "context_length" => 400_000,
        "reasoning" => reasoning.(true, ~w(max high medium low), "medium")
      },
      %{"id" => "anthropic/claude-haiku-4.5"}
    ])

    {:ok, view, _} = live(ctx.conn, "/")
    model = &(view |> form("#start", %{model: &1}) |> render_change(%{_target: ["model"]}))

    selected =
      &has_element?(view, "#start select[name=reasoning] option[selected][value='#{&1}']")

    context = &has_element?(view, "#start input[name=max_context][value='#{&1}']")

    # Before a model is chosen: every level, and no max context.
    assert levels(view) == NanoWeb.Components.reasoning_levels()
    assert context.("")

    # The model's own default level.
    model.("deepseek/deepseek-v4.1-flash")
    assert levels(view) == ~w(off low high max)
    assert selected.("high")
    assert context.(1_048_576)
    assert has_element?(view, "#start .hint", "at most 1,048,576, the model's window")

    model.("openai/gpt-6.1-sol")
    assert levels(view) == ~w(low medium high max)
    assert selected.("medium")
    assert context.(400_000)

    # What is chosen then is kept across re-renders and other fields, until the model changes.
    view
    |> form("#start", %{reasoning: "max", max_context: "5000"})
    |> render_change(%{_target: ["reasoning"]})

    view |> form("#start", %{name: "typing"}) |> render_change(%{_target: ["name"]})
    send(view.pid, :refresh)
    assert selected.("max")
    assert context.(5000)

    # No reasoning block: only "off". No context length: nothing to fill in (and the model
    # cannot be started on: its window is not known).
    model.("anthropic/claude-haiku-4.5")
    assert levels(view) == ["off"]
    assert context.("")

    # Picked from the list, the same; a model not in the list offers every level.
    model.("6.1")
    view |> element("#start .matches button", "openai/gpt-6.1-sol") |> render_click()
    assert selected.("medium")
    assert context.(400_000)
    model.(ctx.model)
    assert levels(view) == NanoWeb.Components.reasoning_levels()
    assert context.("")
  end

  defp levels(view) do
    html = view |> element("#start select[name=reasoning]") |> render()
    for [_, level] <- Regex.scan(~r/<option[^>]*value="([^"]+)"/, html), do: level
  end

  test "the start form rejects a limit that is not a whole number in range", ctx do
    for {field, value} <- [max_turns: "abc", max_tokens: "1.5", max_context: "x", max_turns: "-3"] do
      {:ok, view, _} = live(ctx.conn, "/?view=debug")
      choose(view, ctx.model)
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)
      html = view |> form("#start", %{:name => name, field => value}) |> render_submit()
      assert html =~ "#{field} must be a whole number"
      assert Nano.Ops.agent(name) == nil
    end
  end

  test "the start form's limits: turns and tokens 0 (no limit), context the model's window; all passed on",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#start input[name=max_turns][min='0'][value='0']")
    assert has_element?(view, "#start input[name=max_tokens][min='0'][value='0']")
    assert has_element?(view, "#start .hint", "0 = no limit")
    choose(view, ctx.model)
    assert has_element?(view, "#start input[name=max_context][value='1000000']")

    view |> form("#start", %{name: "typing", max_context: "1234"}) |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, "#start input[name=max_context][value='1234']")

    name = unique("agent")
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    limits = %{max_turns: "0", max_tokens: "0", max_context: "4321"}

    assert {:error, {:live_redirect, _}} =
             view |> form("#start", Map.put(limits, :name, name)) |> render_submit()

    assert %{max_turns: 0, max_tokens: 0, max_context: 4321} = Nano.Ops.agent(name).budget
  end

  test "a suspended dashboard user does not take the page down", ctx do
    {name, _} = start_agent(ctx)
    user = Nano.User.pid("dashboard")
    :sys.suspend(user)
    on_exit(fn -> :sys.resume(user) end)

    # Its messages are read from the users' table, never from the user, so the page renders.
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    assert has_element?(view, "#inbox-link")
    view |> element("#{row(Nano.Ops.whereis(name))} button", "send") |> render_click()

    html =
      view
      |> element("#{row(Nano.Ops.whereis(name))} form[id$='-text']")
      |> render_submit(%{text: "hello"})

    assert html =~ "not responding (suspended or flooded?); the message is queued"
  end

  test "any process row has the send form: text via say, terms via send_raw, parse errors shown",
       ctx do
    target = other_process()
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
    dashboard = Nano.User.pid("dashboard")

    refute has_element?(view, "#{row(target)} .send")
    view |> element("#{row(target)} button", "send") |> render_click()
    assert has_element?(view, "#{row(target)} .send")

    view |> element("#{row(target)} form[id$='-text']") |> render_submit(%{text: "hello there"})
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
    {:ok, view, _} = live(ctx.conn, "/?view=debug")
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

  ## Overview (the default view)

  defp card(name), do: "#card-#{name}"

  # Runs one scripted turn of an agent: notify, then wait for the turn to end.
  defp turn(name, model, calls) do
    Nano.Log.subscribe(Nano.Ops.agent(name).id)
    Fake.push(model, calls: calls)
    Fake.push(model, calls: [idle: nil])
    NanoAgent.notify(name, :go)
    assert_receive {:nano_log, %{type: :turn_ended}}, 5_000
  end

  test "the overview is the default; the toggle switches to the table and back", ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "section.overview")
    refute has_element?(view, "table.processes")
    assert has_element?(view, "#start")
    assert has_element?(view, "header.top #inbox-link[href='/messages'] svg")

    view |> element("nav.views a", "debug") |> render_click()
    assert_patch(view, "/?view=debug")
    assert has_element?(view, "table.processes")
    view |> element("nav.views a", "overview") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "section.overview")
  end

  test "with no agents it says so and points at the start form", ctx do
    for name <- NanoAgent.list(), do: Nano.Ops.stop_agent(name)
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, ".overview .empty", "No agents yet. Start one with the form above")
  end

  test "agent cards: status, halt reasons, limits with ∞, cost and what each is doing", ctx do
    {idle, _} = start_agent(ctx, max_turns: 0)
    {suspended, spid} = start_agent(ctx)
    :sys.suspend(spid)
    {halted, _} = start_agent(ctx)
    Nano.StateStore.put(halted, %{Nano.StateStore.get(halted) | halted: :context})
    {thinking, _} = start_agent(ctx)
    NanoAgent.notify(thinking, :hello)
    # The fake holds the request open: the agent stays thinking.
    assert_receive {:openrouter_request, _, _}, 5_000

    {:ok, view, _} = live(ctx.conn, "/")
    eventually(fn -> has_element?(view, "#{card(thinking)}.thinking .now", "thinking") end)

    assert has_element?(view, "#{card(idle)}.idle a[href='/agents/#{idle}']", idle)
    assert has_element?(view, "#{card(idle)} .meter .value", "0 / ∞")
    assert has_element?(view, "#{card(idle)} .meter .value", "0 / 30,000,000")

    assert has_element?(view, card(idle), ctx.model)

    assert has_element?(view, "#{card(idle)} .now", "started")
    assert has_element?(view, "#{card(suspended)}.suspended .badge.suspended")
    assert has_element?(view, "#{card(suspended)} .now", "suspended")
    assert has_element?(view, "#{card(halted)}.halted .halt", "context limit reached")
    assert has_element?(view, "#{card(halted)} .now", "halted: context")
    :sys.resume(spid)
  end

  test "what an agent's evals spawned is a count on its card, not a list", ctx do
    {name, _} = start_agent(ctx)
    turn(name, ctx.model, eval: "spawn(fn -> Process.sleep(:infinity) end)")

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#{card(name)} .spawned", "1 spawned")
    refute has_element?(view, "#{card(name)} details")
    assert has_element?(view, "#{card(name)} .now", "idle, waiting for a message")
  end

  test "an agent started by another follows its starter's card and says so", ctx do
    {parent, _} = start_agent(ctx)
    child = unique("child")
    on_exit(fn -> Nano.Ops.stop_agent(child) end)

    turn(parent, ctx.model,
      eval: "{:ok, _} = NanoAgent.start(#{inspect([name: child] ++ Fake.opts(ctx.model))})"
    )

    assert Nano.Ops.agent(child).started_by == parent

    {:ok, view, _} = live(ctx.conn, "/")
    # Its own card, straight after its starter's, saying who started it.
    assert has_element?(
             view,
             "#{card(parent)} + #{card(child)}.child .started-by a[href='/agents/#{parent}']",
             parent
           )

    refute has_element?(view, "#{card(parent)} .started-by a")
  end

  test "users and other processes are listed; the rest is counted", ctx do
    name = unique("person")
    pid = Nano.User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, pid) end)
    send(pid, :one)
    other = other_process()

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, ".user-card", name)
    assert has_element?(view, ".user-card", "1 message · 1 unread")
    assert has_element?(view, ".user-card a[href='/messages?user=#{name}']")
    send(pid, :two)
    eventually(fn -> has_element?(view, ".user-card", "2 messages") end)
    assert has_element?(view, "ul.others li", inspect(other))
    assert render(view) =~ ~r/\d+ processes of the standard set are not shown/
  end

  test "hostile values do not break the overview", ctx do
    {name, _} = start_agent(ctx)
    %{id: id} = Nano.Ops.agent(name)
    agent = %{id: id, name: name}
    {:ok, view, _} = live(ctx.conn, "/")

    for {type, fields} <- [
          {:model_response, %{text: %{"x" => [1, %{}]}}},
          {:tool_call, %{name: %{"odd" => 1}, arguments: [1]}},
          {:tool_result, %{name: nil, ok: "maybe", duration_ms: %{}}},
          {:turn_ended, %{reason: [1, 2]}},
          {:event_received, %{message: String.duplicate("long ", 500)}},
          {:something_else, %{}}
        ] do
      Nano.Log.write(agent, type, fields)
      assert render(view) =~ name
    end

    tree = NanoWeb.Overview.tree([%{name: "a", started_by: "b"}, %{name: "b", started_by: "a"}])
    assert length(tree) == 1
  end
end
