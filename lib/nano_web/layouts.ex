defmodule NanoWeb.Layouts do
  @moduledoc "The root HTML layout: stylesheet, Phoenix client JS, and the LiveSocket connection."
  use Phoenix.Component

  @doc "The document around every LiveView."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title>{assigns[:page_title] || "nano"}</.live_title>
        <link rel="stylesheet" href="/app.css" />
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script>
        <script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrf = document.querySelector("meta[name='csrf-token']").content
            window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrf}})
            window.liveSocket.connect()
          })
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
