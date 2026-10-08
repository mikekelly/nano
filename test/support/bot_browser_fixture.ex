defmodule Seedling.Bots.BrowserFixture do
  @moduledoc false
  import Plug.Conn
  def init(html), do: html

  def call(conn, html) do
    if conn.request_path == "/" do
      conn |> put_resp_content_type("text/html") |> send_resp(200, html)
    else
      # LiveSocket is a stub; exercise the app's own JS hooks without opening a
      # second WebSocket server or requesting notification permission from an OS.
      conn
      |> put_resp_content_type("application/javascript")
      |> send_resp(
        200,
        "window.Phoenix={Socket:class{}};window.LiveView={LiveSocket:class{disableDebug(){} connect(){}}};"
      )
    end
  end
end
