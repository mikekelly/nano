defmodule NanoWeb.Router do
  @moduledoc """
  Every route on the node: two dashboard LiveViews, OpenRouter's OAuth stops, and the JSON API.
  """
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
    get "/openrouter/connect", OpenRouterController, :connect
    get "/openrouter/callback", OpenRouterController, :callback
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

    post "/eval", ApiController, :eval

    get "/chatgpt", ApiController, :chatgpt
    post "/chatgpt/login", ApiController, :chatgpt_login
    post "/chatgpt/logout", ApiController, :chatgpt_logout

    get "/settings", ApiController, :settings
    put "/settings/:key", ApiController, :put_setting
    delete "/settings/:key", ApiController, :delete_setting
  end
end
