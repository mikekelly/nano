defmodule NanoWeb.OpenRouterController do
  @moduledoc """
  The two browser stops of OpenRouter's OAuth PKCE flow (`Nano.OpenRouter.Auth`): `connect`
  sends the browser to OpenRouter to authorize a key for this node, and OpenRouter sends it
  back to `callback`, which stores the key and returns to the dashboard; what went wrong, if
  anything, is shown there in the start form's OpenRouter panel.
  """
  use Phoenix.Controller, formats: [:html]

  def connect(conn, _params) do
    case Nano.Ops.openrouter_login(callback_url(conn)) do
      {:ok, url} -> redirect(conn, external: url)
      {:error, message} -> back(conn, message)
    end
  end

  def callback(conn, params) do
    case Nano.Ops.openrouter_callback(params) do
      :ok -> back(conn, nil)
      {:error, message} -> back(conn, message)
    end
  end

  defp back(conn, nil), do: redirect(conn, to: "/")
  defp back(conn, error), do: conn |> put_flash(:openrouter_error, error) |> redirect(to: "/")

  # Back to the dashboard on the address the browser used. OpenRouter documents localhost
  # callbacks on any port, so a loopback address is given as localhost: the same server.
  defp callback_url(conn) do
    host = if conn.host in ["127.0.0.1", "::1", "[::1]"], do: "localhost", else: conn.host
    "#{conn.scheme}://#{host}:#{conn.port}/openrouter/callback"
  end
end
