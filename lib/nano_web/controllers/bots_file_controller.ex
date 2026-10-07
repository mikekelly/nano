defmodule NanoWeb.BotsFileController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  def show(conn, %{"id" => id}) do
    opts = [server: Application.get_env(:nano, :bots_server, Vega.Bots.Server)]

    case Vega.Bots.download_file(id, opts) do
      {:ok, bytes, ref} ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_resp_header(
          "content-disposition",
          "attachment; filename*=UTF-8''" <> URI.encode(ref["filename"], &URI.char_unreserved?/1)
        )
        |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
        |> Plug.Conn.put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> Plug.Conn.send_resp(200, bytes)

      _ ->
        Plug.Conn.send_resp(conn, 404, "File not found")
    end
  end
end
