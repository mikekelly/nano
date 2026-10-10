defmodule NanoWeb.OpenRouterController do
  @moduledoc "CSRF-protected browser initiation and GET-only one-use PKCE callback."
  use Phoenix.Controller, formats: [:html]

  def connect(conn, _params) do
    case NanoWeb.ApiGuard.callback_url() do
      {:ok, url} ->
        case Nano.Ops.openrouter_login(url) do
          {:ok, url} -> redirect(conn, external: url)
          {:error, message} -> back(conn, message)
        end

      {:error, _, code} ->
        conn
        |> put_status(503)
        |> Phoenix.Controller.json(%{error: code, message: "OAuth callback policy unavailable."})
    end
  end

  def callback(%{method: "GET"} = conn, params) do
    case Nano.Ops.openrouter_callback(params) do
      :ok -> back(conn, nil)
      {:error, message} -> back(conn, message)
    end
  end

  def callback(conn, _), do: Plug.Conn.send_resp(conn, 405, "GET required")
  defp back(conn, nil), do: redirect(conn, to: "/")
  defp back(conn, error), do: conn |> put_flash(:openrouter_error, error) |> redirect(to: "/")
end
