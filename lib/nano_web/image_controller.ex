defmodule NanoWeb.ImageController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  def create(conn, %{"name" => name, "base64" => encoded} = params) when is_binary(encoded) do
    result =
      with {:ok, bytes} <- Base.decode64(encoded),
           do: Nano.Images.send(name, params["text"] || "Image attachment", bytes)

    case result do
      {:ok, ref} -> conn |> put_status(201) |> json(%{image: ref})
      {:error, error} -> conn |> put_status(422) |> json(%{error: inspect(error)})
    end
  end

  def create(conn, _),
    do: conn |> put_status(422) |> json(%{error: "give base64 image bytes and optional text"})

  def show(conn, %{"id" => id}) do
    case Nano.Images.fetch(id) do
      {:ok, bytes, mime} ->
        conn
        |> put_resp_content_type(mime)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, bytes)

      _ ->
        send_resp(conn, 404, "Image not found")
    end
  end
end
