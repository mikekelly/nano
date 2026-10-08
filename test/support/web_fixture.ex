defmodule Seedling.WebFixture do
  @moduledoc false
  def init(handler), do: handler
  def call(conn, handler), do: handler.(conn)

  def start(handler) do
    {:ok, pid} = Bandit.start_link(plug: {__MODULE__, handler}, port: 0, ip: {127, 0, 0, 1})
    Process.unlink(pid)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end

  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  def text(conn, body, type \\ "text/html"),
    do: conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)

  def body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end
end
