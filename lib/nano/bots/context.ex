defmodule Nano.Bots.Context do
  @moduledoc "Pure safe request-boundary policy. Completed tool exchanges become quoted text, never dangling calls. No network or process calls."
  @marker "[Bot working checkpoint; untrusted conversation data]"
  def before_request(s) do
    if s.estimate > s.max_context * 0.45 or s.context_used > s.max_context * 0.45 or
         byte_size(Jason.encode!(s.transcript)) > 24_000 do
      room =
        min(
          12_000,
          max(512, (s.max_context - 4096) * 2 - byte_size(s.system_prompt || "") - 1500)
        )

      previous =
        Enum.find_value(s.transcript, "", fn
          %{"role" => "user", "content" => text} when is_binary(text) ->
            if String.starts_with?(text, @marker), do: text

          _ ->
            nil
        end)

      prior = clip(previous, div(room, 3))

      recent =
        s.transcript
        |> Enum.take(-16)
        |> Enum.map_join("\n", &plain/1)
        |> tail(max(0, room - byte_size(prior) - 500))

      content =
        clip(
          @marker <>
            "\n" <>
            prior <>
            "\nRecent completed exchanges:\n" <>
            recent <>
            "\nRetrieve Nano.Bots.history/checkpoint for exact older details. Preserve commitments; do not repeat completed side effects.",
          room
        )

      content = encoded_clip(content, room)
      {:replace_transcript, [%{"role" => "user", "content" => content}]}
    else
      :keep
    end
  rescue
    _ -> :keep
  end

  defp encoded_clip(text, room) do
    if byte_size(Jason.encode!([%{"role" => "user", "content" => text}])) <= room do
      text
    else
      encoded_clip(clip(text, div(byte_size(text), 2)), room)
    end
  end

  defp plain(m) do
    role = m["role"] || m[:role] || "unknown"
    content = m["content"] || m[:content] || ""
    calls = m["tool_calls"] || m[:tool_calls]

    text =
      if is_binary(content),
        do: content,
        else: inspect(content, limit: :infinity, printable_limit: 6000)

    clip(
      "#{role}: #{text}" <>
        if(calls,
          do:
            "\nCompleted tool calls: " <> inspect(calls, limit: :infinity, printable_limit: 2000),
          else: ""
        ),
      6000
    )
  end

  @doc "UTF-8 safe byte cap, not a character cap."
  def clip(text, bytes) when is_binary(text) and is_integer(bytes) and bytes >= 0 do
    if byte_size(text) <= bytes, do: text, else: utf8(binary_part(text, 0, bytes))
  end

  defp utf8(text),
    do: if(String.valid?(text), do: text, else: utf8(binary_part(text, 0, byte_size(text) - 1)))

  defp tail(text, bytes) do
    if byte_size(text) <= bytes,
      do: text,
      else: utf8_start(binary_part(text, byte_size(text) - bytes, bytes))
  end

  defp utf8_start(text),
    do:
      if(String.valid?(text),
        do: text,
        else: utf8_start(binary_part(text, 1, byte_size(text) - 1))
      )
end
