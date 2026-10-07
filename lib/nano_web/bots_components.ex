defmodule NanoWeb.BotsComponents do
  use Phoenix.Component
  attr :bot, :map, required: true
  attr :small, :boolean, default: false

  def face(assigns) do
    face = assigns.bot["face"] || %{}

    shape =
      if face["shape"] in ["circle", "square", "diamond", "round", "bean"],
        do: face["shape"],
        else: "circle"

    colour =
      if face["colour"] in [
           "blue",
           "green",
           "purple",
           "pink",
           "orange",
           "yellow",
           "teal",
           "coral",
           "lavender",
           "mint",
           "peach",
           "lilac",
           "sky",
           "rose",
           "gold"
         ], do: face["colour"], else: "blue"

    assigns = assign(assigns, shape: shape, colour: colour)

    ~H"""
    <span
      class={["face", "face-#{@shape}", @small && "face-small"]}
      data-colour={@colour}
      aria-hidden="true"
    ><span class="face-eyes"></span><span class="face-smile"></span></span>
    """
  end

  attr :kind, :string, required: true

  def icon(assigns) do
    ~H"""
    <svg
      class="bots-icon"
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path :if={@kind == "plus"} d="M12 5v14M5 12h14" />
      <g :if={@kind == "microphone"}>
        <rect x="9" y="2" width="6" height="12" rx="3" /><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8" />
      </g>
    </svg>
    """
  end

  attr :text, :string, required: true

  def markdown(assigns) do
    ~H"""
    <div class="markdown">{Vega.Bots.Markdown.render(@text)}</div>
    """
  end
end
