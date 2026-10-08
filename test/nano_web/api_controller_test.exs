defmodule NanoWeb.ApiControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint NanoWeb.Endpoint

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp start_user do
    name = unique("u")
    pid = Nano.User.start(name)
    on_exit(fn -> DynamicSupervisor.terminate_child(Nano.UserSupervisor, pid) end)
    {name, pid}
  end

  defp start_agent do
    name = unique("agent")
    {:ok, pid} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(fake_model()))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    {name, pid}
  end

  defp fake_model do
    Nano.FakeOpenRouter.start()
    Nano.FakeOpenRouter.model()
  end

  # A POST /api/agents body with every required field, for a listed model.
  defp agent_body(name, fields \\ %{}),
    do: fake_model() |> Nano.FakeOpenRouter.opts(name: name) |> Map.new() |> Map.merge(fields)

  defp path_pid(pid), do: URI.encode_www_form(inspect(pid))

  test "GET /api describes every API route" do
    body = build_conn() |> get("/api") |> json_response(200)
    assert body["conventions"] =~ "#PID<0.231.0>"

    described =
      for e <- body["endpoints"], do: {e["method"], e["path"] |> String.split("?") |> hd()}

    for %{plug: NanoWeb.ApiController, verb: verb, path: path} <-
          Phoenix.Router.routes(NanoWeb.Router) do
      path = String.replace(path, ":pid", ":target")

      assert {verb |> to_string() |> String.upcase(), String.trim_trailing(path, "/")} in described
    end
  end

  describe "processes" do
    test "GET /api/processes lists non-standard processes with the dashboard's columns" do
      {name, pid} = start_user()
      rows = build_conn() |> get("/api/processes") |> json_response(200)
      row = Enum.find(rows, &(&1["pid"] == inspect(pid)))

      assert %{"name" => ^name, "kind" => "user", "spawned_by" => nil, "agent" => nil} = row
      assert row["current_function"] =~ "{:gen_server, :loop,"

      assert is_integer(row["message_queue_len"]) and is_integer(row["memory"]) and
               is_integer(row["reductions"])

      refute Enum.any?(rows, &(&1["pid"] == inspect(Process.whereis(Nano.StateStore))))
    end

    test "agents are listed first, with their info" do
      {name, pid} = start_agent()
      rows = build_conn() |> get("/api/processes") |> json_response(200)
      {agents, rest} = Enum.split_while(rows, &(&1["kind"] == "agent"))
      refute Enum.any?(rest, &(&1["kind"] == "agent"))

      assert %{"name" => ^name, "agent" => %{"status" => "idle"}} =
               Enum.find(agents, &(&1["pid"] == inspect(pid)))
    end

    test "GET /api/processes/:pid gives Process.info for a pid string or a name" do
      {name, pid} = start_user()
      body = build_conn() |> get("/api/processes/#{path_pid(pid)}") |> json_response(200)
      assert %{"pid" => pid_string, "kind" => "user", "status" => _, "links" => [_ | _]} = body
      assert pid_string == inspect(pid)
      assert body["current_function"] =~ ":gen_server"

      assert %{"pid" => ^pid_string} =
               build_conn() |> get("/api/processes/#{name}") |> json_response(200)

      assert %{"registered_name" => "Nano.StateStore", "kind" => "standard"} =
               build_conn() |> get("/api/processes/Nano.StateStore") |> json_response(200)
    end

    test "unknown processes are 404" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      for target <- [path_pid(dead), "nothing_here", "%23PID%3C9.9.9%3E"] do
        assert %{"error" => "no such process: " <> _} =
                 build_conn() |> get("/api/processes/#{target}") |> json_response(404)
      end
    end
  end

  describe "users" do
    test "POST /api/users starts a user and is idempotent" do
      name = unique("u")

      %{"name" => ^name, "pid" => pid} =
        post_json("/api/users", %{name: name}) |> json_response(200)

      on_exit(fn ->
        DynamicSupervisor.terminate_child(Nano.UserSupervisor, Nano.User.pid(name))
      end)

      assert pid == inspect(Nano.User.pid(name))
      assert %{"pid" => ^pid} = post_json("/api/users", %{name: name}) |> json_response(200)
    end

    test "bad bodies are 422, malformed JSON is 400" do
      assert %{"error" => "name is required" <> _} =
               post_json("/api/users", %{}) |> json_response(422)

      assert %{"error" => "name is required" <> _} =
               post_json("/api/users", %{name: 7}) |> json_response(422)

      conn = build_conn() |> put_req_header("content-type", "application/json")
      assert_error_sent 400, fn -> post(conn, "/api/users", "{nope") end
    end

    test "say sends %{sender_pid, message} from the user" do
      {name, user} = start_user()
      {target, _} = start_user()

      assert %{"ok" => true} =
               post_json("/api/users/#{name}/say", %{to: target, text: "hello"})
               |> json_response(200)

      assert [%{"term" => term, "at" => at}] =
               build_conn() |> get("/api/users/#{target}/inbox") |> json_response(200)

      assert term == inspect(%{sender_pid: user, message: "hello"})
      assert {:ok, _, 0} = DateTime.from_iso8601(at)
    end

    test "say to a pid string" do
      {name, user} = start_user()

      assert %{"ok" => true} =
               post_json("/api/users/#{name}/say", %{to: inspect(self()), text: "hi"})
               |> json_response(200)

      assert_receive %{sender_pid: ^user, message: "hi"}
    end

    test "send_raw parses and evaluates the term, and sends it as is" do
      {name, _} = start_user()
      to = inspect(self())

      assert %{"ok" => true} =
               post_json("/api/users/#{name}/send_raw", %{to: to, term: "{:ping, 42}"})
               |> json_response(200)

      assert_receive {:ping, 42}

      assert %{"ok" => true} =
               post_json("/api/users/#{name}/send_raw", %{to: to, term: ~s|%{note: "hi"}|})
               |> json_response(200)

      assert_receive %{note: "hi"}
    end

    test "send_raw parse and eval failures are 422 with the exception message" do
      {name, _} = start_user()
      to = inspect(self())

      assert %{"error" => "could not evaluate term", "message" => "** (TokenMissingError)" <> _} =
               post_json("/api/users/#{name}/send_raw", %{to: to, term: "{:ping"})
               |> json_response(422)

      assert %{"message" => "** (RuntimeError) boom"} =
               post_json("/api/users/#{name}/send_raw", %{to: to, term: ~s|raise "boom"|})
               |> json_response(422)
    end

    test "inbox?clear=true empties the inbox" do
      {name, user} = start_user()
      send(user, :one)
      send(user, {:two, 2})
      # The inbox request below is a call from this same process, so it arrives after both.

      assert [%{"term" => ":one"}, %{"term" => "{:two, 2}"}] =
               build_conn() |> get("/api/users/#{name}/inbox?clear=true") |> json_response(200)

      assert [] = build_conn() |> get("/api/users/#{name}/inbox") |> json_response(200)
    end

    test "GET /api/users, a user's threads and one thread: both directions, in order" do
      {name, user} = start_user()
      agent = unique("agent")
      test = self()

      agent_pid =
        spawn_link(fn ->
          Nano.Names.register_name({:agent, agent}, self())
          send(test, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      post_json("/api/users/#{name}/say", %{to: agent, text: "hi"}) |> json_response(200)
      send(user, {:reply, agent_pid, "back"})
      # A call to the user, so it has handled the reply.
      assert [_] = build_conn() |> get("/api/users/#{name}/inbox") |> json_response(200)

      users = build_conn() |> get("/api/users") |> json_response(200)

      assert %{"pid" => pid, "messages" => 2, "unread" => 1} =
               Enum.find(users, &(&1["name"] == name))

      assert pid == inspect(user)

      assert [
               %{
                 "agent" => ^agent,
                 "messages" => 2,
                 "unread" => 1,
                 "last" => last,
                 "last_at" => at
               }
             ] =
               build_conn() |> get("/api/users/#{name}/threads") |> json_response(200)

      assert last == inspect({:reply, agent_pid, "back"})
      assert {:ok, _, 0} = DateTime.from_iso8601(at)

      assert [
               %{"dir" => "sent", "term" => sent},
               %{"dir" => "received", "term" => received, "at" => _}
             ] = build_conn() |> get("/api/users/#{name}/threads/#{agent}") |> json_response(200)

      assert sent == inspect(%{sender_pid: user, message: "hi"}, pretty: true)
      assert received == inspect({:reply, agent_pid, "back"})
      assert [] = build_conn() |> get("/api/users/#{name}/threads/nobody") |> json_response(200)

      for path <- ["threads", "threads/#{agent}"] do
        assert %{"error" => "no such user: " <> _} =
                 build_conn()
                 |> get("/api/users/#{unique("nobody")}/#{path}")
                 |> json_response(404)
      end

      index = build_conn() |> get("/api") |> json_response(200)
      paths = for e <- index["endpoints"], do: e["path"]
      assert "/api/users/:name/threads/:agent" in paths and "/api/users" in paths
    end

    test "a user that does not answer is 503" do
      {name, pid} = start_user()
      :sys.suspend(pid)
      on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)
      to = inspect(self())

      assert %{"error" => "user " <> _} =
               post_json("/api/users/#{name}/say", %{to: to, text: "x"}) |> json_response(503)

      assert %{"error" => "user " <> _} =
               post_json("/api/users/#{name}/send_raw", %{to: to, term: ":x"})
               |> json_response(503)

      assert %{"error" => "user " <> _} =
               build_conn() |> get("/api/users/#{name}/inbox") |> json_response(503)
    end

    test "unknown users and targets are 404, missing fields 422" do
      {name, _} = start_user()
      nobody = unique("nobody")

      assert %{"error" => "no such user: " <> _} =
               post_json("/api/users/#{nobody}/say", %{to: name, text: "x"}) |> json_response(404)

      assert %{"error" => "no such user: " <> _} =
               post_json("/api/users/#{nobody}/send_raw", %{to: name, term: "1"})
               |> json_response(404)

      assert %{"error" => "no such user: " <> _} =
               build_conn() |> get("/api/users/#{nobody}/inbox") |> json_response(404)

      assert %{"error" => "no such target: " <> _} =
               post_json("/api/users/#{name}/say", %{to: nobody, text: "x"}) |> json_response(404)

      assert %{"error" => "no such target: " <> _} =
               post_json("/api/users/#{name}/send_raw", %{to: nobody, term: "1"})
               |> json_response(404)

      assert %{"error" => "text is required" <> _} =
               post_json("/api/users/#{name}/say", %{to: name}) |> json_response(422)

      assert %{"error" => "to is required" <> _} =
               post_json("/api/users/#{name}/send_raw", %{term: "1"}) |> json_response(422)
    end
  end

  describe "eval" do
    test "returns the inspected result and printed output" do
      assert %{"result" => "2", "output" => ""} =
               post_json("/api/eval", %{code: "1 + 1"}) |> json_response(200)

      assert %{"result" => ":ok", "output" => "hi\n"} =
               post_json("/api/eval", %{code: ~s|IO.puts("hi")|}) |> json_response(200)
    end

    test "failures are 422 with the exception message" do
      assert %{"error" => "eval failed", "message" => "** (ArithmeticError)" <> _} =
               post_json("/api/eval", %{code: "1 + :a"}) |> json_response(422)

      assert %{"error" => "eval failed", "message" => "** (SyntaxError)" <> _} =
               post_json("/api/eval", %{code: "1 +* 2"}) |> json_response(422)

      assert %{"error" => "code is required" <> _} =
               post_json("/api/eval", %{}) |> json_response(422)
    end
  end

  describe "agents" do
    test "POST /api/agents starts an agent; duplicates are 409, bad names 422" do
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)
      request = agent_body(name, %{start_idle: true})
      body = post_json("/api/agents", request) |> json_response(201)
      model = request.model

      assert %{
               "name" => ^name,
               "model" => ^model,
               "status" => "idle",
               "pid" => "#PID<" <> _,
               "context_window" => 1_000_000
             } = body

      assert %{
               "budget" => %{"max_turns" => 500, "turns_used" => 0},
               "halted" => nil,
               "suspended" => false
             } = body

      assert %{"error" => "agent already started: " <> _} =
               post_json("/api/agents", request) |> json_response(409)

      assert %{"error" => "could not start agent: name must be letters, digits, _ . or -" <> _} =
               post_json("/api/agents", %{request | name: "a b"}) |> json_response(422)

      assert %{"error" => "name is required" <> _} =
               post_json("/api/agents", %{}) |> json_response(422)
    end

    test "every field but the name is required too, and a refusal says what to give" do
      body = agent_body(unique("agent"))

      for {key, start} <- [
            model: "missing model: give a model slug",
            reasoning: "missing reasoning: #{body.model} supports off, minimal",
            max_turns: "missing max_turns: ",
            max_tokens: "missing max_tokens: ",
            max_context: "missing max_context: #{body.model}'s context window is 1000000"
          ] do
        assert %{"error" => "could not start agent: " <> message} =
                 post_json("/api/agents", Map.delete(body, key)) |> json_response(422)

        assert String.starts_with?(message, start)
      end

      assert %{"error" => "could not start agent: unknown model nobody/nothing: " <> _} =
               post_json("/api/agents", %{body | model: "nobody/nothing"}) |> json_response(422)
    end

    test "reasoning is a level of the model's, passed through as given" do
      level = hd(NanoAgent.reasoning_levels() -- ["off"])

      for expected <- ["off", level] do
        name = unique("agent")
        on_exit(fn -> Nano.Ops.stop_agent(name) end)

        assert %{"reasoning" => ^expected} =
                 post_json("/api/agents", agent_body(name, %{reasoning: expected}))
                 |> json_response(201)

        assert %{"reasoning" => ^expected} =
                 build_conn() |> get("/api/agents/#{name}") |> json_response(200)
      end

      for bad <- ["turbo", true, false] do
        assert %{"error" => "could not start agent: reasoning " <> _} =
                 post_json("/api/agents", agent_body(unique("agent"), %{reasoning: bad}))
                 |> json_response(422)
      end

      %{"endpoints" => endpoints} = build_conn() |> get("/api") |> json_response(200)
      start = Enum.find(endpoints, &(&1["method"] == "POST" and &1["path"] == "/api/agents"))

      for l <- ["off" | NanoAgent.reasoning_levels()],
          do: assert(start["description"] =~ inspect(l))
    end

    test "system_prompt_file is passed through; a missing file is 422 with the reason" do
      file =
        Path.join(
          Application.fetch_env!(:nano, :test_dir),
          "prompt_#{System.unique_integer([:positive])}.txt"
        )

      File.write!(file, "You are {{name}}, read from a file.")
      on_exit(fn -> File.rm(file) end)
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)

      assert %{"system_prompt" => "You are " <> rest} =
               post_json("/api/agents", agent_body(name, %{system_prompt_file: file}))
               |> json_response(201)

      assert String.starts_with?(rest, "#{name}, read from a file.\n")

      assert %{
               "error" =>
                 "could not start agent: cannot read the system prompt file " <>
                   "tmp/no_such_prompt.txt: no such file or directory"
             } =
               post_json(
                 "/api/agents",
                 agent_body(unique("agent"), %{system_prompt_file: "tmp/no_such_prompt.txt"})
               )
               |> json_response(422)

      %{"endpoints" => endpoints} = build_conn() |> get("/api") |> json_response(200)
      start = Enum.find(endpoints, &(&1["method"] == "POST" and &1["path"] == "/api/agents"))
      assert start["description"] =~ "system_prompt_file"
      assert start["description"] =~ "priv/system_prompt.txt"
    end

    test "the three limits are passed through; 0 means no limit, a negative is 422" do
      name = unique("agent")
      on_exit(fn -> Nano.Ops.stop_agent(name) end)
      limits = %{max_turns: 0, max_tokens: 0, max_context: 777}
      body = post_json("/api/agents", agent_body(name, limits)) |> json_response(201)

      assert %{"max_turns" => 0, "max_tokens" => 0, "max_context" => 777, "context_used" => 0} =
               body["budget"]

      for key <- [:max_turns, :max_tokens, :max_context] do
        assert %{"error" => "could not start agent: " <> message} =
                 post_json("/api/agents", agent_body(unique("agent"), %{key => -1}))
                 |> json_response(422)

        assert message =~ "#{key} must be a whole number"
      end

      # No unlimited context: the model's window is the ceiling.
      assert %{"error" => "could not start agent: max_context must be" <> _} =
               post_json("/api/agents", agent_body(unique("agent"), %{max_context: 0}))
               |> json_response(422)

      %{"endpoints" => endpoints} = build_conn() |> get("/api") |> json_response(200)
      start = Enum.find(endpoints, &(&1["method"] == "POST" and &1["path"] == "/api/agents"))
      assert start["description"] =~ "max_context"
      assert start["description"] =~ "0 means no limit"
      unhalt = Enum.find(endpoints, &(&1["path"] == "/api/agents/:name/unhalt"))
      assert unhalt["description"] =~ "context"
    end

    test "options of the wrong type are 422, not a silently ignored budget" do
      for {key, value} <- [
            max_turns: "1",
            max_tokens: "100",
            max_context: "9",
            start_idle: "false"
          ] do
        name = unique("agent")
        on_exit(fn -> Nano.Ops.stop_agent(name) end)

        assert %{"error" => "could not start agent: " <> message} =
                 post_json("/api/agents", agent_body(name, %{key => value}))
                 |> json_response(422)

        assert message =~ "#{key} must be"
      end
    end

    test "GET /api/agents and /api/agents/:name" do
      {name, pid} = start_agent()
      list = build_conn() |> get("/api/agents") |> json_response(200)
      assert %{"pid" => pid_string} = Enum.find(list, &(&1["name"] == name))
      assert pid_string == inspect(pid)

      body = build_conn() |> get("/api/agents/#{name}") |> json_response(200)

      assert %{
               "name" => ^name,
               "restart_count" => 0,
               "system_prompt" => "I am the GenServer" <> _,
               "id" => _
             } = body

      assert %{"error" => "no such agent: nobody"} =
               build_conn() |> get("/api/agents/nobody") |> json_response(404)
    end

    test "lifecycle verbs" do
      {name, pid} = start_agent()

      :sys.suspend(pid)

      assert build_conn()
             |> get("/api/agents/#{name}")
             |> json_response(200)
             |> Map.fetch!("suspended")

      assert %{"ok" => true} = post_json("/api/agents/#{name}/resume", %{}) |> json_response(200)

      refute build_conn()
             |> get("/api/agents/#{name}")
             |> json_response(200)
             |> Map.fetch!("suspended")

      assert %{"ok" => true} = post_json("/api/agents/#{name}/unhalt", %{}) |> json_response(200)

      ref = Process.monitor(pid)
      assert %{"ok" => true} = post_json("/api/agents/#{name}/restart", %{}) |> json_response(200)
      assert_receive {:DOWN, ^ref, _, _, :operator_restart}

      # Stopped even while the supervisor may still be restarting it.
      assert %{"ok" => true} = post_json("/api/agents/#{name}/stop", %{}) |> json_response(200)

      assert %{"error" => "no such agent: " <> _} =
               build_conn() |> get("/api/agents/#{name}") |> json_response(404)

      for verb <- ~w(stop restart resume unhalt) do
        assert %{"error" => "no such agent: nobody"} =
                 post_json("/api/agents/nobody/#{verb}", %{}) |> json_response(404)
      end
    end

    test "GET /api/agents/:name/log?since=" do
      {name, _} = start_agent()
      %{id: id} = Nano.Ops.agent(name)
      Nano.Log.write(%{id: id, name: name}, :note, %{text: "second"})

      assert [
               %{"type" => "agent_started", "seq" => 1},
               %{"type" => "note", "seq" => 2, "text" => "second"}
             ] =
               build_conn() |> get("/api/agents/#{name}/log") |> json_response(200)

      assert [%{"seq" => 2}] =
               build_conn() |> get("/api/agents/#{name}/log?since=1") |> json_response(200)

      assert [] = build_conn() |> get("/api/agents/#{name}/log?since=2") |> json_response(200)

      assert %{"error" => "since must be" <> _} =
               build_conn() |> get("/api/agents/#{name}/log?since=x") |> json_response(400)

      assert %{"error" => "no such agent: nobody"} =
               build_conn() |> get("/api/agents/nobody/log") |> json_response(404)

      assert %{"error" => "no such agent: nobody"} =
               build_conn() |> get("/api/agents/nobody/stream") |> json_response(404)

      assert %{"error" => "since must be" <> _} =
               build_conn() |> get("/api/agents/#{name}/stream?since=-1") |> json_response(400)
    end
  end

  describe "SSE stream (over a real socket)" do
    setup do
      {:ok, server} =
        start_supervised({
          Bandit,
          # Streams whose client has gone are only noticed at the next write.
          plug: NanoWeb.Endpoint,
          ip: :loopback,
          port: 0,
          startup_log: false,
          thousand_island_options: [shutdown_timeout: 100]
        })

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      %{port: port}
    end

    defp open_stream(port, path, headers \\ "") do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET #{path} HTTP/1.1\r\nhost: localhost\r\n#{headers}\r\n")
      socket
    end

    # Reads from the socket until `pattern` has been seen; returns everything read.
    defp read_until(socket, pattern, acc \\ "") do
      if acc =~ pattern do
        acc
      else
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        read_until(socket, pattern, acc <> data)
      end
    end

    defp not_received?(ref) do
      receive do
        {:DOWN, ^ref, _, _, _} = down -> send(self(), down) && false
      after
        100 -> true
      end
    end

    defp subscribers(id), do: Registry.lookup(Nano.PubSub, "agent:" <> id)

    test "sends the backlog, then live entries, and stops when the client goes away", %{
      port: port
    } do
      {name, _} = start_agent()
      %{id: id} = Nano.Ops.agent(name)
      socket = open_stream(port, "/api/agents/#{name}/stream")

      head = read_until(socket, ~r/"agent_started".*\n\n/)
      assert head =~ "HTTP/1.1 200"
      assert head =~ "content-type: text/event-stream"
      assert head =~ "id: 1\ndata: {"

      Nano.Log.write(%{id: id, name: name}, :note, %{text: "live"})
      live = read_until(socket, ~r/"live".*\n\n/)
      [_, json] = Regex.run(~r/id: 2\ndata: (.*)\n\n/, live)
      assert %{"seq" => 2, "type" => "note", "text" => "live"} = Jason.decode!(json)
      # The same entry the log endpoint returns.
      assert Jason.decode!(json) == List.last(Nano.Log.read(id))

      [{handler, _}] = subscribers(id)
      ref = Process.monitor(handler)
      :gen_tcp.close(socket)

      # A write after the peer has closed fails (the first may still be buffered), and the
      # handler process ends.
      for n <- 1..20, not_received?(ref) do
        Nano.Log.write(%{id: id, name: name}, :note, %{text: "unread #{n}"})
      end

      # Its PubSub subscription goes with it (PubSub's Registry is linked to subscribers).
      assert_receive {:DOWN, ^ref, _, _, _}, 2_000
    end

    test "since and Last-Event-ID skip entries already seen", %{port: port} do
      {name, _} = start_agent()
      %{id: id} = Nano.Ops.agent(name)
      for n <- 1..2, do: Nano.Log.write(%{id: id, name: name}, :note, %{n: n})

      socket = open_stream(port, "/api/agents/#{name}/stream?since=2")
      body = read_until(socket, ~r/id: 3\ndata: .*\n\n/)
      refute body =~ "id: 1\n"
      refute body =~ "id: 2\n"
      :gen_tcp.close(socket)

      socket = open_stream(port, "/api/agents/#{name}/stream", "last-event-id: 1\r\n")
      body = read_until(socket, ~r/id: 3\ndata: .*\n\n/)
      assert body =~ "id: 2\n"
      refute body =~ "id: 1\n"
      :gen_tcp.close(socket)
    end
  end
end
