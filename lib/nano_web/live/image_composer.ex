defmodule NanoWeb.ImageComposer do
  @moduledoc "Dashboard image attachment composer. Uploads become references before notifying an agent."
  use Phoenix.LiveComponent

  def mount(socket) do
    {:ok,
     socket
     |> assign(text: "", notice: nil, images: [])
     |> allow_upload(:pictures,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: 20,
       max_file_size: 3_750_000
     )}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  def handle_event("validate", %{"text" => text}, socket),
    do: {:noreply, assign(socket, text: text, notice: nil)}

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :pictures, ref)}

  def handle_event("send", %{"text" => text}, socket) do
    {complete, pending} = uploaded_entries(socket, :pictures)

    if pending != [] or upload_errors(socket.assigns.uploads.pictures) != [] or
         Enum.any?(complete, &(upload_errors(socket.assigns.uploads.pictures, &1) != [])) do
      {:noreply, assign(socket, notice: "Wait for uploads to finish, or remove invalid files.")}
    else
      results =
        consume_uploaded_entries(socket, :pictures, fn %{path: path}, _entry ->
          {:ok, Images.ingest(path)}
        end)

      images = socket.assigns.images ++ for {:ok, ref} <- results, do: ref
      socket = assign(socket, images: images, text: text)

      case Enum.find(results, &match?({:error, _}, &1)) do
        {:error, reason} -> {:noreply, assign(socket, notice: reason)}
        nil -> deliver(socket, text, images)
      end
    end
  end

  def handle_event("clear", _, socket), do: {:noreply, assign(socket, images: [])}

  defp deliver(socket, text, images) do
    with {:ok, message} <- NanoWeb.ImageInput.message(%{"text" => text, "images" => images}),
         %{pid: pid} when is_pid(pid) <- Nano.Ops.agent(socket.assigns.name) do
      NanoAgent.notify(pid, message)
      {:noreply, assign(socket, images: [], text: "", notice: "Message sent")}
    else
      {:error, reason} -> {:noreply, assign(socket, notice: reason)}
      _ -> {:noreply, assign(socket, notice: "Agent is not running; attachments retained.")}
    end
  end

  def render(assigns) do
    ~H"""
    <details id={@id} class="prompt">
      <summary>Send images</summary>
      <form id={@id <> "-form"} phx-change="validate" phx-submit="send" phx-target={@myself}>
        <label>Message <textarea name="text">{@text}</textarea></label>
        <.live_file_input upload={@uploads.pictures} />
        <p class="dim">
          PNG, JPEG, GIF or WebP. Up to 20 images; each under 3.75 MB. Content and dimensions are validated before sending.
        </p>
        <p :for={error <- upload_errors(@uploads.pictures)} role="alert">{upload_error(error)}</p>
        <div :for={entry <- @uploads.pictures.entries}>
          {entry.client_name} — {entry.progress}%
          <button type="button" phx-click="cancel" phx-value-ref={entry.ref} phx-target={@myself}>Remove</button>
          <p :for={error <- upload_errors(@uploads.pictures, entry)} role="alert">
            {upload_error(error)}
          </p>
        </div>
        <NanoWeb.ImageGallery.images term={@images} />
        <button :if={@images != []} type="button" phx-click="clear" phx-target={@myself}>Clear retained attachments</button>
        <button type="submit" phx-disable-with="Sending…">Send message with images</button>
        <p :if={@notice} role="status">{@notice}</p>
      </form>
    </details>
    """
  end

  defp upload_error(:too_large), do: "Image is too large"
  defp upload_error(:too_many_files), do: "Too many images (maximum 20)"
  defp upload_error(:not_accepted), do: "Unsupported image extension"
  defp upload_error(_), do: "Upload failed; remove the file and try again"
end
