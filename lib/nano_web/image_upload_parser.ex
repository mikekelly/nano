defmodule NanoWeb.ImageUploadParser do
  @moduledoc "Bounded multipart parsing only for image uploads, guarded against cross-origin HTML forms."
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "POST", request_path: "/api/images"} = conn, _opts) do
    if get_req_header(conn, "x-nano-upload") == ["1"] do
      Plug.Parsers.call(
        conn,
        Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 4_000_000)
      )
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "X-Nano-Upload: 1 header required"}))
      |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
