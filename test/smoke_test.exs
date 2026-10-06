defmodule Nano.SmokeTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint NanoWeb.Endpoint

  test "the supervision tree is up and the boot set is recorded" do
    for name <- [
          Nano.PubSub,
          Nano.Registry,
          Nano.StateStore,
          Nano.EvalSupervisor,
          Nano.AgentSupervisor,
          Nano.UserSupervisor,
          NanoWeb.Endpoint
        ] do
      assert is_pid(Process.whereis(name)), "#{inspect(name)} is not running"
    end

    boot_set = Nano.Application.boot_set()
    assert Process.whereis(Nano.StateStore) in boot_set
    refute self() in boot_set
  end

  test "every row of the spec's API table is routed" do
    routes = [
      {"GET", "/api", :index},
      {"GET", "/api/processes", :processes},
      {"GET", "/api/processes/x", :process},
      {"GET", "/api/agents", :agents},
      {"POST", "/api/agents", :start_agent},
      {"GET", "/api/agents/alice", :agent},
      {"POST", "/api/agents/alice/stop", :stop_agent},
      {"POST", "/api/agents/alice/restart", :restart_agent},
      {"POST", "/api/agents/alice/resume", :resume},
      {"POST", "/api/agents/alice/unhalt", :unhalt},
      {"GET", "/api/agents/alice/log", :log},
      {"GET", "/api/agents/alice/stream", :stream},
      {"POST", "/api/users", :start_user},
      {"POST", "/api/users/bob/say", :say},
      {"POST", "/api/users/bob/send_raw", :send_raw},
      {"GET", "/api/users/bob/inbox", :inbox},
      {"POST", "/api/eval", :eval}
    ]

    for {method, path, action} <- routes do
      assert %{plug: NanoWeb.ApiController, plug_opts: ^action} =
               Phoenix.Router.route_info(NanoWeb.Router, method, path, "localhost")
    end
  end

  test "a URL-encoded pid reaches the action decoded" do
    conn = get(build_conn(), "/api/processes/%23PID%3C0.231.0%3E")
    assert conn.path_params == %{"pid" => "#PID<0.231.0>"}
  end

  test "unknown paths answer with a JSON error" do
    assert %{"error" => "Not Found"} = build_conn() |> get("/api/nope") |> json_response(404)
  end

  test "the dashboard pages render" do
    assert build_conn() |> get("/") |> html_response(200) =~ "phoenix_live_view.min.js"
    assert build_conn() |> get("/agents/alice") |> html_response(200) =~ "alice"
  end
end
