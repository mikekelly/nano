defmodule Seedling.FrontOfMind.Drift do
  @moduledoc """
  Optional drift adapter built on the reusable `Seedling.Decision` Jev client.
  Sends only a bounded note and recent activity. Never changes the note.
  `judge/3` returns `{:ok, %{probability: number, model: string, usage: map}}`
  or an honest error; missing `TYPESAFE_API_KEY` makes no network request.

  Options are those of `Seedling.Decision.evaluate/3`. No retries or spending
  unless drift is explicitly enabled in `Seedling.FrontOfMind.configure/3`.
  Divergence can be justified; only the agent chooses whether to update its note.
  """
  @doc "Judges whether recent activity diverged from the agent's own priorities or constraints."
  def judge(note, activity, opts \\ []) do
    state =
      "Agent's own note:\n#{String.slice(note, 0, 1_000)}\nRecent activity:\n#{String.slice(activity, 0, 2_000)}"

    instructions =
      "Recent activity has diverged from the priorities or constraints in the agent's own note. Judge divergence, not whether changing course is justified."

    Seedling.Decision.probability(state, instructions, opts)
  end
end
