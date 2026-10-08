defmodule NanoWeb.ImageController do
  @moduledoc "Upload validated images, retrieve immutable bytes by digest, and notify agents with references."
  use Phoenix.Controller, formats: [:json]

  def create(conn, %{"file" => %Plug.Upload{path: path}}) do
    case Images.ingest(path) do
      {:ok, ref} -> conn |> put_status(201) |> json(ref)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  def create(conn, _), do: error(conn, 422, "file must be a multipart image upload")

  def show(conn, %{"id" => id}) do
    if NanoWeb.ImageInput.valid_id?(id) do
      case Images.read(id) do
        {:ok, bytes, mime} ->
          conn
          |> put_resp_content_type(mime)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-security-policy", "sandbox")
          |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
          |> send_resp(200, bytes)

        {:error, _} ->
          error(conn, 404, "image not found")
      end
    else
      error(conn, 404, "image not found")
    end
  end

  def message(conn, %{"name" => name} = params) do
    with {:ok, message} <- NanoWeb.ImageInput.message(params),
         %{pid: pid} when is_pid(pid) <- Nano.Ops.agent(name) do
      NanoAgent.notify(pid, message)
      json(conn, %{ok: true})
    else
      {:error, reason} -> error(conn, 422, reason)
      _ -> error(conn, 404, "no running agent: #{name}")
    end
  end

  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: reason})
end
