defmodule NanoWeb.Layouts do
  @moduledoc """
  The root HTML layout: stylesheet, Phoenix client JS, the LiveSocket connection, and a banner
  that app.css shows while the page has lost its connection to the node.
  """
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
            // When the server closes the socket (its endpoint restarting), LiveView reloads the page
            // after a random 5-10 s, meant to spread out many clients; one operator needs only ~1 s.
            window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: {_csrf_token: csrf},
              reloadJitterMin: 500,
              reloadJitterMax: 1500
            })
            // LiveView logs debug output on localhost unless told not to. To see it in this tab:
            // liveSocket.enableDebug() in the console, then reload.
            if (sessionStorage.getItem("phx:live-socket:debug") === null) window.liveSocket.disableDebug()
            window.liveSocket.connect()
          })
        </script>
      </head>
      <body>
        {@inner_content}
        <%!-- Shown by app.css while the LiveView above has phx-error: the page is stale. --%>
        <div id="disconnected" role="alert">
          Disconnected from the node — trying to reconnect. What you see here may be out of date.
        </div>
      </body>
    </html>
    """
  end
end
