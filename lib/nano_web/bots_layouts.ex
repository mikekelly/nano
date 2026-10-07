defmodule NanoWeb.BotsLayouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title>{assigns[:page_title] || "Bots"}</.live_title>
        <link rel="stylesheet" href="/bots.css" />
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script>
        <script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script defer src="/bots.js">
        </script>
      </head>
      <body>
        {@inner_content}
        <div id="bots-disconnected" role="alert">
          Connection lost. Reconnecting — messages may be out of date.
        </div>
      </body>
    </html>
    """
  end
end
