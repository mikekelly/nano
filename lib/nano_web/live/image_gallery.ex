defmodule NanoWeb.ImageGallery do
  @moduledoc "Renders structured image references as lazy thumbnails linked to immutable image endpoints."
  use Phoenix.Component

  attr :term, :any, required: true

  def images(assigns) do
    refs =
      assigns.term
      |> Images.references()
      |> Enum.filter(&NanoWeb.ImageInput.valid_id?(&1["id"]))
      |> Enum.uniq_by(& &1["id"])

    assigns = assign(assigns, refs: refs)

    ~H"""
    <div :if={@refs != []} class="image-attachments">
      <a :for={ref <- @refs} href={"/api/images/" <> ref["id"]} target="_blank" rel="noopener">
        <img
          src={"/api/images/" <> ref["id"]}
          alt="Attached image"
          loading="lazy"
          style="max-width: min(100%, 480px); max-height: 360px; object-fit: contain;"
        />
      </a>
    </div>
    """
  end
end
