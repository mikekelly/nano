defmodule NanoWeb.BotAttachmentController do
  @moduledoc "Download-only generic attachments; never serves caller-selected filesystem paths."
  use Phoenix.Controller, formats: [:json]

  def show(conn, %{"id" => id}) do
    opts = conn.private[:bot_attachment_opts] || []

    with {:ok, data, meta} <- Nano.Bots.Attachments.read("attachment:" <> id, opts) do
      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"" <> meta.filename <> "\""
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "Attachment not found")
    end
  end

  def show(conn, _), do: send_resp(conn, 404, "Attachment not found")
end
