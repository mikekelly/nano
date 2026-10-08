defmodule Seedling.Bots.Text do
  @moduledoc "Safe Markdown subset. Parsing produces data; Phoenix escapes every model-supplied string. No raw HTML, images, unsafe URLs or script-capable artifacts."
  def blocks(text) do
    text
    |> String.split("```", trim: false)
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, i} ->
      if rem(i, 2) == 1 do
        case String.split(part, "\n", parts: 2) do
          [language, code] ->
            [%{type: :code, text: code, language: String.slice(language, 0, 30)}]

          [code] ->
            [%{type: :code, text: code, language: ""}]
        end
      else
        String.split(part, "\n\n", trim: true)
        |> Enum.map(&%{type: :paragraph, text: &1, language: ""})
      end
    end)
  end
end
