defmodule NanoWeb.BotsFileController do
  @moduledoc "Opaque registered-artifact downloads only; forced attachment, octet stream, sandbox and nosniff."
  use Phoenix.Controller, formats: [:html]

  def show(conn, %{"service" => service, "id" => id}) do
    with true <- String.match?(service, ~r/^[a-f0-9]{16}$/),
         true <- String.match?(id, ~r/^[a-f0-9]{16}$/),
         [{_, _}] <- Registry.lookup(Nano.Registry, {:bots_service, service}),
         {:ok, file} <- Nano.Bots.file(id, Nano.Bots.service_ref(service)),
         {:ok, %{type: :regular, size: size}} <- File.lstat(file.path),
         true <- size <= 5_000_000 do
      conn
      |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
      |> Plug.Conn.put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> send_download({:file, file.path},
        filename: file.filename,
        content_type: "application/octet-stream",
        disposition: :attachment
      )
    else
      _ -> Plug.Conn.send_resp(conn, 404, "File not found")
    end
  end
end
