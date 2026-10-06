defmodule NanoWeb.Error do
  @moduledoc "Renders errors raised outside a controller action (404, 500, …) as JSON or plain text."

  @doc "Called by the endpoint with a template such as `\"404.json\"` or `\"500.html\"`."
  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    if String.ends_with?(template, ".json"), do: %{error: message}, else: message
  end
end
