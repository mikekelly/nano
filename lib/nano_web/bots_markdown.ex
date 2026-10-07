defmodule NanoWeb.BotsMarkdown do
  @moduledoc "Small safe Markdown subset: fenced code, headings, lists, paragraphs. HTML and links remain escaped text; never raw model HTML."
  use Phoenix.Component

  def blocks(text) do
    {blocks, lines, code} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], [], false}, fn line, {blocks, lines, code} ->
        cond do
          String.starts_with?(line, "```") -> {flush(blocks, lines, code), [], not code}
          not code and line == "" -> {flush(blocks, lines, false), [], false}
          true -> {blocks, lines ++ [line], code}
        end
      end)

    flush(blocks, lines, code)
  end

  defp flush(blocks, [], _), do: blocks

  defp flush(blocks, lines, code) do
    text = Enum.join(lines, "\n")

    kind =
      cond do
        code -> :code
        String.starts_with?(text, "# ") -> :heading
        String.starts_with?(text, "- ") -> :list
        true -> :text
      end

    blocks ++ [%{kind: kind, text: text}]
  end

  def message(assigns) do
    assigns = assign(assigns, :blocks, blocks(assigns.text))

    ~H"""
    <div class="markdown">
      <%= for block <- @blocks do %>
        <%= case block.kind do %>
          <% :code -> %>
            <pre class="code"><code>{block.text}</code></pre>
          <% :heading -> %>
            <h3>{String.trim_leading(block.text, "# ")}</h3>
          <% :list -> %>
            <ul>
              <li :for={line <- String.split(block.text, "\n")}>{String.trim_leading(line, "- ")}</li>
            </ul>
          <% _ -> %>
            <pre>{block.text}</pre>
        <% end %>
      <% end %>
    </div>
    """
  end
end
