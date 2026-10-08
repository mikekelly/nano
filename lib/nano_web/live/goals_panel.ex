defmodule NanoWeb.GoalsPanel do
  @moduledoc "Cheap bounded goal/note reads and measured context-bob timeline components for operators."
  use Phoenix.Component
  attr :name, :string, required: true

  def goals(assigns) do
    {open, error} =
      case Seedling.Goals.list(assigns.name) do
        {:ok, goals} -> {Enum.reject(goals, &(&1["status"] in ["done", "cancelled"])), nil}
        {:error, _} -> {[], "Goals could not be read; durable state was not overwritten."}
      end

    front =
      case Seedling.FrontOfMind.get(assigns.name) do
        {:ok, d} -> d
        _ -> nil
      end

    assigns =
      assign(assigns,
        open: open |> Enum.sort_by(&if(&1["status"] == "active", do: 0, else: 1)) |> Enum.take(8),
        count: length(open),
        error: error,
        front: front
      )

    ~H"""
    <section
      id="agent-goals"
      aria-label="Agent goals"
      style="padding:16px;border:1px solid #e2e8f0;border-radius:12px;margin:16px 0"
    >
      <h2 style="font-size:16px;margin:0 0 10px">Open goals · {@count}</h2>
      <p :if={@error} role="status">{@error}</p>
      <p :if={@count == 0 && !@error} class="dim">No open goals.</p>
      <ul style="padding-left:20px">
        <li :for={g <- @open} id={"goal-" <> g["id"]} style="margin-bottom:8px">
          <strong>{g["title"]}</strong> <span class="dim">· {g["status"]}</span>
          <div>{g["why"]}</div><small :if={g["parent"]} class="dim">Step of {g["parent"]}</small>
        </li>
      </ul>
      <p :if={@count > 8} class="dim">Showing 8. Full tree: Seedling.Goals.list({inspect(@name)}).</p>
      <div
        :if={@front && @front["note"]}
        id="agent-front-of-mind"
        style="border-top:1px solid #e2e8f0;padding-top:12px"
      >
        <strong>Agent's own front-of-mind note</strong>
        <p style="white-space:pre-wrap">{@front["note"]}</p>
        <small class="dim">Written {@front["written_at"]} · bobbing {if @front["enabled"],
          do: "on",
          else: "off"} · threshold {@front["threshold"]} estimated tokens · drift {if @front["drift"],
          do: "on",
          else: "off"}</small>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :e, :map, required: true

  def bob(assigns) do
    ~H"""
    <li id={@id} class="r context-bob">
      <div class="r-label">{String.replace(@e["type"], "_", " ")} · <time>{@e["at"]}</time></div>
      <p :if={@e["type"] == "context_bob"}>
        Agent's own {@e["source"]} re-shown · {@e["distance_tokens"]} estimated tokens since last appearance / threshold {@e[
          "threshold_tokens"
        ]} · {@e["reason"]}
      </p>
      <pre :if={@e["type"] == "context_bob"}>{@e["text"]}</pre>
      <pre :if={@e["type"] != "context_bob"}>{inspect(Map.take(@e, ~w(result note_revision configuration note_characters)), pretty: true)}</pre>
    </li>
    """
  end
end
