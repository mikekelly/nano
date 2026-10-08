defmodule NanoWeb.ImageController do
  @moduledoc "Validated immutable image upload/delivery and same-origin image display."
  use Phoenix.Controller, formats: [:json]

  def upload(conn, %{"name" => name, "base64" => data} = params) when is_binary(data) do
    text = Map.get(params, "text", "")

    if is_binary(text) and byte_size(text) <= 16_000 do
      case Nano.Ops.upload_image(name, data, text) do
        {:ok, ref} -> json(conn, %{image: ref})
        {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(422) |> json(%{error: "text must be a string of at most 16000 bytes"})
    end
  end

  def upload(conn, _),
    do: conn |> put_status(422) |> json(%{error: "base64 must contain a validated image"})

  def show(conn, %{"id" => id}) do
    case Nano.Ops.image(id) do
      {:ok, bytes, mime} ->
        conn
        |> put_resp_content_type(mime)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, bytes)

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "image not found"})
    end
  end
end
