defmodule Nano.ImageInput do
  @moduledoc "Reference-only transcript content and conservative image accounting. Unknown capabilities are text-only."
  def notice(modalities) do
    if "image" in modalities do
      "Your model can see attached images. To look at an image file, call Nano.Images.look(path, me) " <>
        "from eval; its immutable attachment reaches you in a user message after tool results. " <>
        "A filename alone is not an image. Image bytes are never stored in your transcript."
    else
      "Your model cannot see images (or image support was not verified). Image attachments " <>
        "will be reported as unavailable, not shown. Do not guess their contents from filenames."
    end
  end

  def event(%{message: message} = term, modalities) when is_map(message) do
    {clean, images, notice} = event(message, modalities)
    {Map.put(term, :message, clean), images, notice}
  end

  def event(%{"message" => message} = term, modalities) when is_map(message) do
    {clean, images, notice} = event(message, modalities)
    {Map.put(term, "message", clean), images, notice}
  end

  def event(term, modalities) when is_map(term) do
    case Map.get(term, :images, Map.get(term, "images")) do
      images when is_list(images) and images != [] ->
        results = Enum.map(images, &Nano.Images.canonicalize/1)
        valid = for {:ok, ref} <- results, do: ref
        invalid = for {:error, _} <- results, do: :invalid
        clean = term |> Map.delete(:images) |> Map.delete("images")

        if "image" in modalities do
          {clean, valid,
           if(invalid == [],
             do: "",
             else: "\n<harness>Invalid image attachments rejected.</harness>"
           )}
        else
          {clean, valid,
           "\n<harness>This model cannot see the #{length(images)} image attachment(s). Do not infer what they show.</harness>"}
        end

      nil ->
        {term, [], ""}

      _ ->
        {term |> Map.delete(:images) |> Map.delete("images"), [],
         "\n<harness>Invalid image attachments rejected.</harness>"}
    end
  end

  def event(term, _), do: {term, [], ""}

  def content(text, []), do: text

  def content(text, refs),
    do: [
      %{"type" => "text", "text" => text}
      | Enum.map(refs, &%{"type" => "image_ref", "image_ref" => &1})
    ]

  # 9,600 synthetic bytes become 4,800 tokens under the harness's byte/2 estimator.
  # Usage from the next provider response replaces this estimate.
  def estimated_bytes(value), do: byte_size(Jason.encode!(value)) + 9_600 * count(value)
  defp count(%{"type" => "image_ref"}), do: 1
  defp count(map) when is_map(map), do: map |> Map.values() |> Enum.map(&count/1) |> Enum.sum()
  defp count(list) when is_list(list), do: list |> Enum.map(&count/1) |> Enum.sum()
  defp count(_), do: 0
end
