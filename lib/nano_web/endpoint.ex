defmodule NanoWeb.Endpoint do
  @moduledoc "The HTTP endpoint on port 4000: dashboard LiveViews, JSON API, and static files."
  use Phoenix.Endpoint, otp_app: :nano

  @session_options [store: :cookie, key: "_nano", signing_salt: "nano-session", same_site: "Lax"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # No asset pipeline: our one stylesheet, and the client JS straight from the deps.
  plug Plug.Static, at: "/", from: :nano, only: ~w(app.css)

  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  # JSON bodies only. A form posted by some other web page is therefore never parsed into
  # params, which keeps a stray browser tab from driving the unauthenticated API.
  # Up to 64 MB, for images sent as base64 (POST /api/users/:name/say).
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason, length: 64_000_000
  plug Plug.Head
  plug Plug.Session, @session_options
  plug NanoWeb.Router
end
