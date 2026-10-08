defmodule NanoWeb.SettingsPanel do
  @moduledoc """
  The dashboard's Settings view (`/?view=settings`): every setting `Nano.Ops.settings/0`
  lists, with what it does, whether a change applies live or to agents started afterwards,
  and its value. A secret (a key, or any value of the operators' own) shows only whether it
  is set, and its input is masked and starts empty. Each setting saves and clears on its own,
  and a value of the operators' own can be added by name. Above them, the providers
  (`Nano.Ops.providers/0`), each connected or not, with disconnect; they are connected from
  the start form. `NanoWeb.ProcessLive` handles the events (`Nano.Ops.put_setting/2`,
  `Nano.Ops.delete_setting/1`, the providers' logouts) and keeps what they refuse, shown
  beside the setting.
  """
  use Phoenix.Component

  import NanoWeb.Components

  attr :settings, :list, required: true, doc: "Nano.Ops.settings/0"
  attr :providers, :list, required: true, doc: "Nano.Ops.providers/0"
  attr :errors, :map, required: true, doc: "refusals, by setting name (\"\" for a new one)"
  attr :saves, :integer, required: true, doc: "counts changes, so inputs start over after one"

  def settings_panel(assigns) do
    ~H"""
    <section id="settings" class="settings">
      <h2><.icon name="sliders" /> Settings</h2>
      <p class="dim">
        Kept on the node, in effect as soon as they are saved: <b>live</b>
        ones at once, <b>new agents</b>
        ones for agents started afterwards (their system prompt states them, so
        a running agent keeps its own). Keys are never shown.
      </p>
      <div :for={p <- @providers} id={"provider-#{p.id}"} class="setting">
        <div class="name"><b>{p.name}</b> <span class="dim">provider</span></div>
        <div class="row">
          <span class="state">
            {case p.status do
              :connected -> "connected#{if p.detail, do: " #{p.detail}"}"
              :pending -> "connecting"
              _ -> "not connected: connect it from Start agent, above"
            end}
          </span>
          <button
            :if={p.status != :disconnected}
            type="button"
            class="small"
            phx-click={"#{p.id}_logout"}
            data-confirm={
              p.status == :connected &&
                "Disconnect #{p.name}? Agents on its models stop working until it is connected again."
            }
          >
            {if p.status == :pending, do: "cancel", else: "disconnect"}
          </button>
        </div>
      </div>
      <form
        :for={s <- @settings}
        id={"setting-#{s.key}"}
        class="setting"
        phx-submit="save_setting"
      >
        <input type="hidden" name="key" value={s.key} />
        <div class="name">
          <code>{s.key}</code>
          <span class="dim">{if s.applies == :live, do: "live", else: "new agents"}</span>
        </div>
        <div class="row">
          <input
            id={"setting-#{s.key}-value-#{@saves}"}
            type={if s.secret, do: "password", else: "text"}
            name="value"
            value={if s.secret, do: "", else: s.value}
            autocomplete="off"
            placeholder={if s.secret, do: "type a new value"}
          />
          <button class="small">save</button>
          <button
            :if={s.set}
            type="button"
            class="small"
            phx-click="clear_setting"
            phx-value-key={s.key}
          >
            {if s.default == nil, do: "clear", else: "reset to default"}
          </button>
          <span class="state">{state(s)}</span>
        </div>
        <p class="dim about">{s.about}</p>
        <p :if={@errors[to_string(s.key)]} class="error">{@errors[to_string(s.key)]}</p>
      </form>
      <form id="setting-new" class="setting" phx-submit="add_setting">
        <div class="name"><span>a value of your own</span></div>
        <div class="row">
          <input
            id={"setting-new-name-#{@saves}"}
            type="text"
            name="name"
            placeholder="NAME, e.g. SOME_SERVICE_KEY"
            autocomplete="off"
          />
          <input
            id={"setting-new-value-#{@saves}"}
            type="password"
            name="value"
            placeholder="value"
            autocomplete="off"
          />
          <button class="small">add</button>
        </div>
        <p class="dim about">
          For whatever needs it, such as a seedling's service; the seed never reads it. Kept as a
          secret, under its name.
        </p>
        <p :if={@errors[""]} class="error">{@errors[""]}</p>
      </form>
    </section>
    """
  end

  defp state(%{secret: true, set: true, last4: nil}), do: "set"
  defp state(%{secret: true, set: true, last4: last4}), do: "set, ends …#{last4}"
  defp state(%{secret: true}), do: "not set"
  defp state(%{set: true, default: default}), do: "set (default #{default})"
  defp state(_), do: "default"
end
