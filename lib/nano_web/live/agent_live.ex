defmodule NanoWeb.AgentLive do
  @moduledoc "STUB (owner: dashboard). One agent's live timeline."
  use Phoenix.LiveView

  def mount(%{"name" => name}, _session, socket) do
    {:ok, assign(socket, page_title: name, name: name)}
  end

  def render(assigns) do
    ~H"""
    <h1>{@name}</h1>
    <p>Agent view placeholder. <a href="/">Processes</a></p>
    """
  end
end
