defmodule NanoWeb.ImageController do
  @moduledoc "Bounded transient base64 uploads and immutable, hash-addressed validated images."
  use Phoenix.Controller, formats: [:json]

  # Below the strict provider's base64 ceiling; the store also validates decoded bytes.
  @max_encoded 5_000_000
  def upload(conn, %{"base64" => encoded})
      when is_binary(encoded) and byte_size(encoded) <= @max_encoded do
    with {:ok, bytes} <- Base.decode64(encoded),
         {:ok, ref} <- Nano.Images.import_bytes(bytes) do
      conn |> put_status(201) |> json(ref)
    else
      _ -> conn |> put_status(422) |> json(%{error: "invalid or unsupported image"})
    end
  end

  def upload(conn, _),
    do:
      conn
      |> put_status(422)
      |> json(%{error: "base64 image required (maximum 5,000,000 encoded bytes)"})

  def show(conn, %{"hash" => hash}) do
    with true <- is_binary(hash) and hash =~ ~r/\A[a-f0-9]{64}\z/,
         {:ok, ref} <- Nano.Images.canonicalize(%{image_ref: hash}),
         {:ok, bytes} <- Nano.Images.read(ref) do
      conn
      |> put_resp_content_type(ref.mime)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", "\"" <> hash <> "\"")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(404) |> json(%{error: "image not found"})
    end
  end
end
