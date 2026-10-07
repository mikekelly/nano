defmodule Vega.GoalsView do
  @moduledoc "Lightweight read-only goal summary component. Pass Vega.Goals.review/2's result."
  use Phoenix.Component
  attr :review, :any, required: true

  def panel(assigns) do
    ~H"""
    <div id="agent-goals" class="bar">
      <h3>Open goals</h3>
      <%= case @review do %>
        <% {:ok, review} -> %>
          <p :if={review.goals == []} class="dim">No open goals.</p>
          <ul>
            <li :for={goal <- review.goals}>
              <strong>{goal["title"]}</strong>
              · {goal["status"]}
              <span :if={goal["parent_id"]} class="dim"> · step of {goal["parent_id"]}</span>
              <p :if={goal["why"] != ""} class="dim">Why: {goal["why"]}</p>
            </li>
          </ul>
          <p :if={review.omitted > 0} class="dim">
            {review.omitted} more open goals; read Vega.Goals.tree/1 for details.
          </p>
        <% {:error, _} -> %>
          <p class="dim">Goals unavailable (storage error).</p>
      <% end %>
    </div>
    """
  end
end
