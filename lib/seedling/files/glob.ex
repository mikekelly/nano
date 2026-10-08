defmodule Seedling.Files.Glob do
  @moduledoc false
  alias Seedling.Files

  def compile(glob) when is_binary(glob) do
    if glob == "" or String.contains?(glob, <<0>>) do
      Files.error(:invalid_glob, "Glob must be a nonempty string without NUL bytes.")
    else
      case translate(String.graphemes(String.trim_leading(glob, "./")), false, []) do
        {:ok, parts, []} ->
          case Regex.compile("^(?:" <> IO.iodata_to_binary(parts) <> ")$", "u") do
            {:ok, regex} ->
              {:ok, {regex, not String.contains?(glob, "/")}}

            {:error, {reason, _}} ->
              Files.error(:invalid_glob, "Invalid glob: #{reason}; use *, **, ?, [], or {a,b}.")
          end

        _ ->
          Files.error(
            :invalid_glob,
            "Glob has unmatched braces/brackets; use *, **, ?, [], or {a,b}."
          )
      end
    end
  end

  def compile(_), do: Files.error(:invalid_glob, "Glob must be a string.")

  def match?(nil, _), do: true

  def match?({regex, basename}, path) do
    path = String.trim_leading(path, "./")
    Regex.match?(regex, if(basename, do: Path.basename(path), else: path))
  end

  defp translate([], false, acc), do: {:ok, Enum.reverse(acc), []}
  defp translate([], true, _), do: :error
  defp translate(["}" | rest], true, acc), do: {:ok, Enum.reverse(acc), rest}
  defp translate(["}" | _], false, _), do: :error
  defp translate(["," | rest], true, acc), do: translate(rest, true, ["|" | acc])

  defp translate(["{" | rest], inside, acc) do
    case translate(rest, true, []) do
      {:ok, group, rest} -> translate(rest, inside, [["(?:", group, ")"] | acc])
      _ -> :error
    end
  end

  defp translate(["[" | rest], inside, acc) do
    {chars, tail} = Enum.split_while(rest, &(&1 != "]"))

    case tail do
      ["]" | remaining] when chars != [] ->
        chars =
          case chars do
            ["!" | more] -> ["^" | more]
            chars -> chars
          end

        translate(remaining, inside, [["[", chars, "]"] | acc])

      _ ->
        :error
    end
  end

  defp translate(["*", "*", "/" | rest], inside, acc),
    do: translate(rest, inside, ["(?:.*/)?" | acc])

  defp translate(["*", "*" | rest], inside, acc), do: translate(rest, inside, [".*" | acc])
  defp translate(["*" | rest], inside, acc), do: translate(rest, inside, ["[^/]*" | acc])
  defp translate(["?" | rest], inside, acc), do: translate(rest, inside, ["[^/]" | acc])

  defp translate(["\\", c | rest], inside, acc),
    do: translate(rest, inside, [Regex.escape(c) | acc])

  defp translate([c | rest], inside, acc), do: translate(rest, inside, [Regex.escape(c) | acc])
end
