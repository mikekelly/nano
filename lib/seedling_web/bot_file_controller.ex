defmodule SeedlingWeb.BotFileController do
  @moduledoc "Inert attachment downloads; never serves model HTML on the eval origin."
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def download(conn, %{"id" => id}) do
    case Seedling.Bots.attachment(id) do
      {:ok, file} ->
        name = file["name"] |> String.replace(~r/[^\p{L}\p{N}._ -]/u, "_") |> String.slice(0, 120)

        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{name}\"")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
        |> send_file(200, file["path"])

      {:error, _} ->
        send_resp(conn, 404, "Attachment not found")
    end
  end
end
