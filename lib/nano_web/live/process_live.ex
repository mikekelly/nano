defmodule NanoWeb.ProcessLive do
  @moduledoc "STUB (owner: dashboard). Home page: the process view."
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "nano")}

  def render(assigns) do
    ~H"""
    <h1>nano</h1>
    <p>Process view placeholder. Node {node()}, {length(Process.list())} processes.</p>
    """
  end
end
