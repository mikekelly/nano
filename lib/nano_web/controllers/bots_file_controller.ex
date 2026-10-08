defmodule NanoWeb.BotsFileController do
  @moduledoc "Chat files are untrusted: opaque IDs, download disposition, nosniff and sandbox."
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def show(conn, %{"id" => id}) do
    case Seedling.BotFiles.get(id) do
      {:ok, meta, path} ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
        |> put_resp_header("cache-control", "no-store")
        |> send_download({:file, path},
          filename: meta["name"],
          content_type: "application/octet-stream"
        )

      _ ->
        send_resp(conn, 404, "File not found")
    end
  end
end
