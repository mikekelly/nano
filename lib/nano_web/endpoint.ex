defmodule NanoWeb.Endpoint do
  @moduledoc "The HTTP endpoint on port 4000: dashboard LiveViews, JSON API, and static files."
  use Phoenix.Endpoint, otp_app: :nano

  @session_options [store: :cookie, key: "_nano", signing_salt: "nano-session", same_site: "Lax"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # No asset pipeline: our one stylesheet, and the client JS straight from the deps.
  plug Plug.Static, at: "/", from: :nano, only: ~w(app.css bots.css bots.js)

  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  # The guard sees raw method, headers and body before normalization or parameter merge.
  plug NanoWeb.ApiGuard
  # Browser OAuth forms must be parsed before the router's CSRF check. API bodies have
  # already been validated and installed by the guard. LiveView keeps its own protocol.
  plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason
  plug Plug.Head
  plug Plug.Session, @session_options
  plug NanoWeb.Router
end
