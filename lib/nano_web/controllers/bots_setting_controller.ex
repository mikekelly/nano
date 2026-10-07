defmodule NanoWeb.BotsSettingController do
  @moduledoc "Direct JSON credential path: password never traverses a LiveView event or Bots service mailbox."
  use Phoenix.Controller, formats: [:json]

  def create(conn, %{"id" => id} = params) do
    opts = [server: Application.get_env(:nano, :bots_server, Vega.Bots.Server)]
    result = Vega.Bots.answer_setting(id, Map.get(params, "password"), opts)
    # Drop request values before subsequent controller work; route log:false and
    # Phoenix's password filter independently prevent request debug logging.
    conn = %{conn | params: Map.delete(params, "password"), body_params: %{}}

    case result do
      {:ok, metadata} ->
        json(conn, %{ok: true, setting: metadata})

      {:error, _} ->
        conn
        |> put_status(422)
        |> json(%{error: "Credential was not confirmed. Field cleared; re-enter and retry."})
    end
  end
end
