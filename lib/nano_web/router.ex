defmodule NanoWeb.Router do
  @moduledoc "Every route on the node: two dashboard LiveViews and the JSON API."
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NanoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", NanoWeb do
    pipe_through :browser

    live "/", ProcessLive
    live "/agents/:name", AgentLive
  end

  pipeline :bots do
    plug :put_root_layout, html: {NanoWeb.BotsLayout, :root}
  end

  scope "/", NanoWeb do
    pipe_through [:browser, :bots]
    live "/bots", BotsLive
    get "/bots/files/:service/:id", BotsFileController, :show
  end

  # No pipeline: the API always answers JSON (or an event stream), whatever the Accept header.
  # Path params arrive URL-decoded, so `/api/processes/%23PID%3C0.231.0%3E` gives "#PID<0.231.0>".
  scope "/api", NanoWeb do
    get "/", ApiController, :index

    get "/processes", ApiController, :processes
    get "/processes/:pid", ApiController, :process

    get "/agents", ApiController, :agents
    post "/agents", ApiController, :start_agent
    get "/agents/:name", ApiController, :agent
    post "/agents/:name/stop", ApiController, :stop_agent
    post "/agents/:name/restart", ApiController, :restart_agent
    post "/agents/:name/resume", ApiController, :resume
    post "/agents/:name/unhalt", ApiController, :unhalt
    get "/agents/:name/log", ApiController, :log
    get "/agents/:name/stream", ApiController, :stream

    post "/users", ApiController, :start_user
    post "/users/:name/say", ApiController, :say
    post "/users/:name/send_raw", ApiController, :send_raw
    get "/users/:name/inbox", ApiController, :inbox

    get "/images/:file", ApiController, :image

    post "/eval", ApiController, :eval

    get "/chatgpt", ApiController, :chatgpt
    post "/chatgpt/login", ApiController, :chatgpt_login
    post "/chatgpt/logout", ApiController, :chatgpt_logout
  end
end
