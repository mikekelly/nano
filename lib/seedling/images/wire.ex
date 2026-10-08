defmodule Seedling.Images.Wire do
  @moduledoc """
  Request-time attachment hydration. The stored transcript is plain text plus `"images"`
  references on user/tool messages; only the provider edge calls these functions. Missing
  or modified objects raise a clear error rather than silently substituting a filename.
  """
  @doc "OpenRouter chat messages, with tool images promoted after the entire contiguous tool batch."
  def openrouter(messages), do: promote(messages, [], [])

  defp promote([], acc, pending), do: Enum.reverse(acc) ++ promoted(pending)

  defp promote([%{"role" => "tool"} = m | rest], acc, pending) do
    promote(rest, [Map.delete(m, "images") | acc], pending ++ Map.get(m, "images", []))
  end

  defp promote([m | rest], acc, pending) do
    # Flush before the next non-tool message, never between function outputs.
    acc = Enum.reverse(promoted(pending)) ++ acc
    refs = Map.get(m, "images", [])
    m = Map.delete(m, "images")

    m =
      if refs == [],
        do: m,
        else: Map.put(m, "content", text(m["content"]) ++ Enum.map(refs, &router_image/1))

    promote(rest, [m | acc], [])
  end

  defp promoted([]), do: []

  defp promoted(refs),
    do: [
      %{
        "role" => "user",
        "content" =>
          text("Images returned by the preceding tool calls:") ++ Enum.map(refs, &router_image/1)
      }
    ]

  defp text(nil), do: []
  defp text(""), do: []
  defp text(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp text(parts) when is_list(parts), do: parts

  defp router_image(ref),
    do: %{"type" => "image_url", "image_url" => %{"url" => url!(ref), "detail" => "high"}}

  @doc "Responses input content for a user message or an image-bearing function_call_output."
  def responses_content(message) do
    [%{type: "input_text", text: message["content"] || ""}] ++
      Enum.map(
        Map.get(message, "images", []),
        &%{type: "input_image", image_url: url!(&1), detail: "high"}
      )
  end

  defp url!(ref) do
    case Seedling.Images.data_url(ref) do
      {:ok, url} -> url
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Remove inline image bytes from raw model logs, while retaining all non-image payload text."
  def redact(body) when is_binary(body) do
    Regex.replace(
      ~r{data:image(?:/|\\/)[a-zA-Z0-9.+-]+;base64,(?:[A-Za-z0-9+/=]|\\/)+},
      body,
      "[image data omitted]"
    )
  end
end
