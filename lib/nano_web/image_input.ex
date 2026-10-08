defmodule NanoWeb.ImageInput do
  @moduledoc "Validates HTTP image references against the immutable image store; never accepts local paths."

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)

  def message(params) do
    text = Map.get(params, "text", "")
    refs = Map.get(params, "images", [])

    cond do
      not is_binary(text) ->
        {:error, "text must be a string"}

      not is_list(refs) ->
        {:error, "images must be a list of image references"}

      length(refs) > 20 ->
        {:error, "at most 20 images per message"}

      text == "" and refs == [] ->
        {:error, "text or images is required"}

      true ->
        with {:ok, images} <- canonical_refs(refs) do
          {:ok, Images.message(text, images)}
        end
    end
  end

  defp canonical_refs(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case canonical_ref(ref) do
        {:ok, image} -> {:cont, {:ok, acc ++ [image]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_ref(%{"type" => "image_ref", "id" => id}) do
    if valid_id?(id) do
      Images.resolve(id)
    else
      {:error, "invalid image id"}
    end
  end

  defp canonical_ref(_),
    do: {:error, "images must contain image_ref objects returned by POST /api/images"}
end
