defmodule Seedling.Shell do
  @moduledoc """
  Bounded synchronous shell output; long work should use Seedling.Background.start/2.

      Seedling.Shell.sh("printf hello", cwd: "/tmp", timeout: 5_000)

  Returns {:ok, metadata} even for nonzero exits/timeouts. Full output is retained
  at output_path. Tail defaults to 200 lines / 16 KB. Background options are accepted.
  """
  def sh(command, opts \\ []) do
    with {:ok, task} <- Seedling.Background.start(command, Keyword.put(opts, :owner, self())) do
      receive do
        {:seedling_background, %{id: id} = result} when id == task.id ->
          with {:ok, tail} <- tail(result.output_path, opts), do: {:ok, Map.merge(result, tail)}
      end
    end
  end

  @doc "Reads a bounded tail without reading an entire large log into memory."
  def tail(path, opts \\ []) do
    bytes = Keyword.get(opts, :max_bytes, 16_000)
    lines = Keyword.get(opts, :max_lines, 200)

    with {:ok, stat} <- File.stat(path),
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      offset = max(0, stat.size - bytes)

      data =
        case :file.pread(file, offset, bytes) do
          {:ok, data} -> data
          :eof -> ""
        end

      :file.close(file)
      split = :binary.split(data, "\n", [:global])
      output = split |> Enum.take(-lines) |> Enum.join("\n")

      {:ok,
       %{
         output: output,
         truncated: offset > 0 or length(split) > lines,
         total_bytes: stat.size,
         output_path: path
       }}
    end
  end
end
