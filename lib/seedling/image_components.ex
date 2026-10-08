defmodule Seedling.ImageComponents do
  @moduledoc "Reusable immutable attachment rendering for dashboard messages and agent timeline logs."
  use Phoenix.Component

  attr :refs, :list, default: []

  @doc "Render reference maps (or ids) through the safe image API, never inline base64 or arbitrary paths."
  def images(assigns) do
    refs =
      for ref <- assigns.refs,
          id = if(is_map(ref), do: ref["id"], else: ref),
          is_binary(id) and id =~ ~r/\A[0-9a-f]{64}\z/,
          do: %{
            id: id,
            width: if(is_map(ref), do: ref["width"], else: nil),
            height: if(is_map(ref), do: ref["height"], else: nil)
          }

    assigns = assign(assigns, :safe_refs, refs)

    ~H"""
    <div :if={@safe_refs != []} class="image-attachments">
      <a
        :for={ref <- @safe_refs}
        href={"/api/images/" <> ref.id}
        target="_blank"
        rel="noopener noreferrer"
      >
        <img
          src={"/api/images/" <> ref.id}
          alt="Attached image"
          loading="lazy"
          width={ref.width}
          height={ref.height}
          style="max-width: 100%; max-height: 24rem; width: auto; height: auto; object-fit: contain;"
        />
      </a>
    </div>
    """
  end
end

defmodule Seedling.ImageSender do
  @moduledoc """
  Self-contained LiveComponent for validated PNG/JPEG upload plus caption. Used by the shared
  dashboard send form, so the host LiveView needs no image events or upload state. Stored
  references are retained after a failed delivery for retry; raw upload bytes never enter
  a message or log. Type/dimension checks happen in `Seedling.Images`, not in the browser.
  """
  use Phoenix.LiveComponent

  def mount(socket) do
    {:ok,
     socket
     |> assign(caption: "", refs: [], notice: nil)
     |> allow_upload(:image,
       accept: ~w(.png .jpg .jpeg),
       max_entries: 4,
       max_file_size: Seedling.Images.limits().bytes
     )}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  def handle_event("change", params, socket),
    do: {:noreply, assign(socket, caption: params["caption"] || "", notice: nil)}

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :image, ref)}

  def handle_event("send", params, socket) do
    {_, uploading} = uploaded_entries(socket, :image)

    if uploading != [] do
      {:noreply, assign(socket, notice: "Wait for the image upload to finish.")}
    else
      results =
        consume_uploaded_entries(socket, :image, fn %{path: path}, _entry ->
          {:ok, Seedling.Images.view(path)}
        end)

      errors = for {:error, reason} <- results, do: reason
      refs = socket.assigns.refs ++ for {:ok, ref} <- results, do: ref
      socket = assign(socket, refs: refs, caption: params["caption"] || "")

      cond do
        errors != [] ->
          {:noreply, assign(socket, notice: Enum.join(errors, "; "))}

        refs == [] ->
          {:noreply, assign(socket, notice: "Choose a PNG or JPEG image first.")}

        true ->
          case Nano.User.say(socket.assigns.from, socket.assigns.to, socket.assigns.caption, refs) do
            :ok ->
              {:noreply, assign(socket, refs: [], caption: "", notice: "Image message sent.")}

            {:error, reason} ->
              {:noreply,
               assign(socket,
                 notice:
                   "Image message not confirmed: #{inspect(reason)}. An unresponsive user's queued send may still arrive; do not retry it."
               )}
          end
      end
    end
  end

  def render(assigns) do
    ~H"""
    <section id={@id} class="image-send">
      <form id={@id <> "-form"} phx-change="change" phx-submit="send" phx-target={@myself}>
        <label>Attach PNG/JPEG (up to 2000 pixels/side)</label>
        <.live_file_input upload={@uploads.image} />
        <input
          name="caption"
          type="text"
          value={@caption}
          placeholder="Image caption (optional)"
          autocomplete="off"
        />
        <button type="submit">send image</button>
        <div :for={entry <- @uploads.image.entries}>
          <.live_img_preview entry={entry} width="120" />
          <span>{entry.progress}%</span>
          <button type="button" phx-click="cancel" phx-value-ref={entry.ref} phx-target={@myself}>remove</button>
          <span :for={error <- upload_errors(@uploads.image, entry)}>{upload_error(error)}</span>
        </div>
        <span :for={error <- upload_errors(@uploads.image)}>{upload_error(error)}</span>
      </form>
      <Seedling.ImageComponents.images refs={@refs} />
      <p :if={@notice} role="status">{@notice}</p>
    </section>
    """
  end

  defp upload_error(:too_large), do: "Image exceeds 3,750,000 bytes."
  defp upload_error(:not_accepted), do: "Only PNG/JPEG files are accepted."
  defp upload_error(:too_many_files), do: "Choose at most four images at once."
  defp upload_error(_), do: "Image upload failed."
end
