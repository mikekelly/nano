defmodule Seedling.Files.Edit do
  @moduledoc false
  alias Seedling.Files

  def apply(original, replacements, opts) do
    cond do
      not String.valid?(original) or String.contains?(original, <<0>>) ->
        Files.error(:binary_file, "Editing requires a UTF-8 text file without NUL bytes.")

      replacements == [] ->
        Files.error(:no_changes, "Supply at least one {old, new} replacement.")

      not Enum.all?(replacements, fn
        {old, new} ->
          is_binary(old) and is_binary(new) and old != "" and String.valid?(old) and
              String.valid?(new)

        _ ->
          false
      end) ->
        Files.error(
          :invalid_replacement,
          "Each replacement must be {nonempty old_text, new_text}, both valid UTF-8 strings."
        )

      true ->
        endings =
          if String.contains?(original, "\r\n") and
               not String.contains?(String.replace(original, "\r\n", ""), "\n"),
             do: :crlf,
             else: :lf

        ranges =
          Enum.reduce_while(replacements, {:ok, []}, fn {old, new}, {:ok, ranges} ->
            old = line_endings(old, endings)
            new = line_endings(new, endings)

            case locate(original, old, Keyword.get(opts, :tolerant, true)) do
              {:ok, {start, len}, tolerant} ->
                new = preserve_local_endings(new, original, start, len)

                if binary_part(original, start, len) == new do
                  {:halt,
                   Files.error(
                     :no_changes,
                     "Replacement changes nothing; provide different new text."
                   )}
                else
                  {:cont, {:ok, [{start, len, new, tolerant} | ranges]}}
                end

              error ->
                {:halt, error}
            end
          end)

        with {:ok, ranges} <- ranges,
             ranges <- Enum.sort(ranges),
             :ok <- disjoint(ranges) do
          changed =
            Enum.reduce(Enum.reverse(ranges), original, fn {start, len, new, _}, text ->
              binary_part(text, 0, start) <>
                new <> binary_part(text, start + len, byte_size(text) - start - len)
            end)

          {:ok, changed, preview(original, ranges), Enum.any?(ranges, &elem(&1, 3))}
        end
    end
  end

  defp locate(original, old, tolerant) do
    case occurrences(original, old) do
      [range] ->
        {:ok, range, false}

      [] when tolerant ->
        {normalized, index} = normalize(original)
        {needle, _} = normalize(old)

        case if(needle == "", do: [], else: occurrences(normalized, needle)) do
          [{start, len}] ->
            {orig_start, _} = Map.fetch!(index, start)
            {_, orig_end} = Map.fetch!(index, start + len - 1)
            {:ok, {orig_start, orig_end - orig_start}, true}

          [] ->
            not_found()

          matches ->
            ambiguous(length(matches))
        end

      [] ->
        not_found()

      matches ->
        ambiguous(length(matches))
    end
  end

  defp not_found,
    do:
      Files.error(
        :not_found,
        "Old text not found; it must match exactly, including whitespace and newlines. Read the file and add the correct context."
      )

  defp ambiguous(n),
    do:
      Files.error(:ambiguous_match, "Old text occurs #{n} times; add context to make it unique.")

  # Include overlapping occurrences ("aa" in "aaa" is ambiguous).
  defp occurrences(text, needle), do: occurrences(text, needle, 0, [])

  defp occurrences(text, needle, offset, acc)
       when offset <= byte_size(text) - byte_size(needle) do
    case :binary.match(text, needle, scope: {offset, byte_size(text) - offset}) do
      :nomatch -> Enum.reverse(acc)
      {start, len} -> occurrences(text, needle, start + 1, [{start, len} | acc])
    end
  end

  defp occurrences(_text, _needle, _offset, acc), do: Enum.reverse(acc)

  defp disjoint([a, b | rest]) do
    if elem(a, 0) + elem(a, 1) > elem(b, 0),
      do:
        Files.error(
          :overlapping_edits,
          "Replacement ranges overlap; combine them into one replacement or add disjoint context."
        ),
      else: disjoint([b | rest])
  end

  defp disjoint(_), do: :ok

  defp line_endings(text, :crlf),
    do: text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")

  defp line_endings(text, :lf), do: text

  defp preserve_local_endings(new, original, start, len) do
    matched = binary_part(original, start, len)
    suffix = binary_part(original, start, byte_size(original) - start)

    style =
      cond do
        String.contains?(matched, "\r\n") and
            not String.contains?(String.replace(matched, "\r\n", ""), "\n") ->
          :crlf

        String.contains?(matched, "\n") ->
          :lf

        true ->
          case :binary.match(suffix, "\n") do
            {pos, 1} when pos > 0 ->
              if binary_part(suffix, pos - 1, 1) == "\r", do: :crlf, else: :lf

            _ ->
              :lf
          end
      end

    new = String.replace(new, "\r\n", "\n")
    line_endings(new, style)
  end

  defp normalize(text) do
    tokens =
      Regex.scan(~r/\r\n|[\s\S]/u, text, return: :index)
      |> Enum.map(fn [{start, len}] ->
        token = binary_part(text, start, len)

        normalized =
          case token do
            "\r\n" -> "\n"
            c when c in ["‘", "’"] -> "'"
            c when c in ["“", "”"] -> "\""
            c when c in ["‐", "‑", "‒", "–", "—", "−"] -> "-"
            c -> c
          end

        {normalized, start, start + len}
      end)

    # Trim whitespace before newlines and at EOF, preserving a byte-to-original map.
    {all, current} =
      Enum.reduce(tokens, {[], []}, fn {token, _, _} = entry, {all, current} ->
        if token == "\n" do
          trimmed = Enum.drop_while(current, fn {t, _, _} -> t in [" ", "\t"] end)
          {[entry | trimmed ++ all], []}
        else
          {all, [entry | current]}
        end
      end)

    tokens = Enum.reverse(Enum.drop_while(current, fn {t, _, _} -> t in [" ", "\t"] end) ++ all)

    {iodata, index, _} =
      Enum.reduce(tokens, {[], %{}, 0}, fn {token, start, ending}, {data, index, offset} ->
        index =
          Enum.reduce(offset..(offset + byte_size(token) - 1), index, fn pos, map ->
            Map.put(map, pos, {start, ending})
          end)

        {[token | data], index, offset + byte_size(token)}
      end)

    {iodata |> Enum.reverse() |> IO.iodata_to_binary(), index}
  end

  defp preview(original, ranges) do
    text =
      Enum.map_join(ranges, "\n", fn {start, len, new, _} ->
        line = original |> binary_part(0, start) |> String.split("\n") |> length()
        old = binary_part(original, start, len)
        "@@ line #{line} @@\n" <> marked(old, "- ") <> "\n" <> marked(new, "+ ")
      end)

    cap = 8_000
    truncated = byte_size(text) > cap
    text = if truncated, do: text |> binary_part(0, cap) |> Seedling.Shell.scrub(), else: text

    %{
      text: text,
      truncated: truncated,
      notice:
        if(truncated,
          do: "Edit preview truncated to #{cap} bytes. Use read/2 to inspect the changed file.",
          else: nil
        )
    }
  end

  defp marked(text, prefix), do: prefix <> String.replace(text, "\n", "\n" <> prefix)
end
