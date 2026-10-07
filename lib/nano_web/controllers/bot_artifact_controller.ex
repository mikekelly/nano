defmodule NanoWeb.BotArtifactController do
  use Phoenix.Controller, formats: [:html]

  def download(conn, %{"id" => id}) do
    artifact =
      if Seedling.BotArtifacts.valid_id?(id) do
        Enum.find_value(Seedling.Bots.sessions(), fn session ->
          Enum.find_value(session["messages"], fn msg ->
            case msg["artifact"] do
              %{"id" => ^id} = artifact -> artifact
              _ -> nil
            end
          end)
        end)
      end

    with %{"filename" => filename} <- artifact,
         {:ok, bytes} <- Seedling.BotArtifacts.fetch(id) do
      # Metadata is durable but still untrusted for HTTP header purposes.
      filename =
        if is_binary(filename) and Regex.match?(~r/\A[a-zA-Z0-9._ -]{1,120}\z/, filename),
          do: filename,
          else: "download"

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.send_resp(200, bytes)
    else
      _ -> Plug.Conn.send_resp(conn, 404, "Not found")
    end
  end
end
