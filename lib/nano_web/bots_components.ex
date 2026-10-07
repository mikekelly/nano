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
    ><span class="face-eyes">••</span><span class="face-smile">⌣</span></span>
    """
  end

  attr :text, :string, required: true

  def markdown(assigns) do
    ~H"""
    <div class="markdown">{Vega.Bots.Markdown.render(@text)}</div>
    """
  end
end
