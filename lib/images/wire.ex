defmodule Images.Wire do
  @moduledoc """
  Request-only expansion of canonical image references. Never persist its return value.
  `openrouter/2` moves tool images after the complete contiguous tool-result batch;
  `codex_content/2` expands user or function-call-output content into Responses parts.
  Both accept an optional reader (`Images.read/1` by default) for isolated testing.
  Missing or corrupt objects become explicit text notices, not poisoned retry loops.
  """

  @doc "Chat messages with user image_url parts; tool results remain text."
  def openrouter(messages, reader \\ &Images.read/1) do
    messages
    |> Enum.chunk_by(&(&1["role"] == "tool"))
    |> Enum.flat_map(fn batch ->
      if hd(batch)["role"] == "tool" do
        {tools, images} = Enum.map_reduce(batch, [], &tool(&1, &2, reader))
        tools ++ if(images == [], do: [], else: [%{"role" => "user", "content" => images}])
      else
        Enum.map(batch, fn
          %{"role" => "user", "content" => parts} = m when is_list(parts) ->
            %{m | "content" => Enum.map(parts, &part(&1, :openrouter, reader))}

          m ->
            m
        end)
      end
    end)
  end

  defp tool(%{"content" => parts} = m, images, reader) when is_list(parts) do
    {text, extra} =
      Enum.reduce(parts, {[], []}, fn
        %{"type" => "image_ref"} = ref, {text, extra} ->
          label = "Image from tool result #{m["tool_call_id"]}:"

          {text ++ ["[Image attached after tool results.]"],
           extra ++ [%{"type" => "text", "text" => label}, part(ref, :openrouter, reader)]}

        %{"type" => "text", "text" => text}, {texts, extra} ->
          {texts ++ [text], extra}
      end)

    {%{m | "content" => Enum.join(text, "\n")}, images ++ extra}
  end

  defp tool(m, images, _reader), do: {m, images}

  @doc "Responses input parts (input_text/input_image), including function_call_output lists."
  def codex_content(content, reader \\ &Images.read/1)

  def codex_content(text, _reader) when is_binary(text),
    do: [%{"type" => "input_text", "text" => text}]

  def codex_content(parts, reader) when is_list(parts),
    do: Enum.map(parts, &part(&1, :codex, reader))

  defp part(%{"type" => "text", "text" => text}, provider, _reader),
    do: text_part(text, provider)

  defp part(%{"type" => "image_ref"} = ref, provider, reader) do
    case read(reader, ref) do
      {:ok, bytes, mime} ->
        url = "data:" <> mime <> ";base64," <> Base.encode64(bytes)

        case provider do
          :openrouter -> %{"type" => "image_url", "image_url" => %{"url" => url}}
          :codex -> %{"type" => "input_image", "image_url" => url}
        end

      {:error, reason} ->
        text_part("[Image unavailable: #{reason}]", provider)
    end
  end

  defp read(reader, ref) do
    case reader.(ref) do
      {:ok, bytes, mime}
      when is_binary(bytes) and mime in ["image/png", "image/jpeg", "image/webp", "image/gif"] ->
        {:ok, bytes, mime}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error, "invalid image object"}
    end
  rescue
    _ -> {:error, "image object could not be read"}
  catch
    _, _ -> {:error, "image object could not be read"}
  end

  defp text_part(text, :openrouter), do: %{"type" => "text", "text" => text}
  defp text_part(text, :codex), do: %{"type" => "input_text", "text" => text}
end
