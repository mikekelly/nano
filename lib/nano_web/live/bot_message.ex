defmodule NanoWeb.BotMessage do
  @moduledoc """
  Small block-only Markdown renderer for chat. Text is always HEEx-escaped.

  Supports unindented headings (# through ###), unordered lists (-, * or +),
  paragraphs and backtick/tilde fences. Fence info strings are ignored. No inline
  syntax, links, images, HTML, nesting or full CommonMark interpretation.
  """
  use Phoenix.Component

  attr :text, :string, required: true

  def message(assigns) do
    assigns = assign(assigns, :blocks, parse(assigns.text))

    ~H"""
    <div class="bot-message" style="overflow-wrap:anywhere">
      <%= for block <- @blocks do %>
        <%= case block do %>
          <% {:heading, 1, text} -> %>
            <h1>{text}</h1>
          <% {:heading, 2, text} -> %>
            <h2>{text}</h2>
          <% {:heading, 3, text} -> %>
            <h3>{text}</h3>
          <% {:paragraph, text} -> %>
            <p style="white-space:pre-wrap">{text}</p>
          <% {:code, text} -> %>
            <pre style="white-space:pre-wrap;overflow-wrap:anywhere"><code>{text}</code></pre>
          <% {:list, items} -> %>
            <ul>
              <li :for={text <- items} style="white-space:pre-wrap">{text}</li>
            </ul>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :artifact, :any, default: nil

  def attachment(assigns) do
    artifact =
      case assigns.artifact do
        %{"id" => id, "filename" => filename} = artifact when is_binary(filename) ->
          if Seedling.BotArtifacts.valid_id?(id) and String.valid?(filename), do: artifact

        _ ->
          nil
      end

    assigns = assign(assigns, :safe_artifact, artifact)

    ~H"""
    <a :if={@safe_artifact} href={"/bots/artifacts/" <> @safe_artifact["id"]} download>
      Download {@safe_artifact["filename"]}
    </a>
    """
  end

  @doc "Parses bounded chat text into plain data; never produces HTML."

  def parse(text) when is_binary(text) do
    text
    |> String.split(~r/\r\n|\n|\r/)
    |> blocks([])
    |> Enum.reverse()
  end

  defp blocks([], acc), do: acc

  defp blocks([line | rest] = lines, acc) do
    case kind(line) do
      :blank ->
        blocks(rest, acc)

      {:heading, level, text} ->
        blocks(rest, [{:heading, level, text} | acc])

      {:fence, marker} ->
        {code, rest} = code_lines(rest, marker, [])
        blocks(rest, [{:code, Enum.join(code, "\n")} | acc])

      {:item, _} ->
        {items, rest} = Enum.split_while(lines, &match?({:item, _}, kind(&1)))

        items =
          Enum.map(items, fn line ->
            {:item, text} = kind(line)
            text
          end)

        blocks(rest, [{:list, items} | acc])

      :text ->
        {paragraph, rest} = Enum.split_while(lines, &(kind(&1) == :text))
        blocks(rest, [{:paragraph, Enum.join(paragraph, "\n")} | acc])
    end
  end

  defp kind(line) do
    cond do
      String.trim(line) == "" ->
        :blank

      match = Regex.run(~r/^(\#{1,3})[\t ]+(.+)$/, line) ->
        [_, hashes, text] = match
        {:heading, byte_size(hashes), text}

      match = Regex.run(~r/^(`{3,}|~{3,})(.*)$/, line) ->
        [_, marker, _info] = match
        {:fence, marker}

      match = Regex.run(~r/^[-*+][\t ]+(.*)$/, line) ->
        [_, text] = match
        {:item, text}

      true ->
        :text
    end
  end

  defp code_lines([], _marker, acc), do: {Enum.reverse(acc), []}

  defp code_lines([line | rest], marker, acc) do
    trimmed = String.trim_trailing(line)
    char = binary_part(marker, 0, 1)

    if byte_size(trimmed) >= byte_size(marker) and
         String.replace(trimmed, char, "") == "" do
      {Enum.reverse(acc), rest}
    else
      code_lines(rest, marker, [line | acc])
    end
  end
end
