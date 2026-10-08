defmodule Seedling.Tools do
  @moduledoc "Bounded file and shell utilities. All paths explicit; shell output spills under /tmp/orion-tools."
  def read(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      lines = String.split(text, "\n")
      offset = Keyword.get(opts, :offset, 1)
      limit = Keyword.get(opts, :limit, 200)
      if offset < 1 or offset > length(lines), do: {:error, {:offset, length(lines)}}, else:
        {:ok, %{text: lines |> Enum.drop(offset - 1) |> Enum.take(limit) |> Enum.join("\n") |> String.slice(0, 16000), total_lines: length(lines), next_offset: min(offset + limit, length(lines) + 1)}}
    end
  end
  def write(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, text)
  end
  def edit(path, old, new) do
    with {:ok, text} <- File.read(path) do
      case length(:binary.matches(text, old)) do
        1 when old != new -> File.write(path, String.replace(text, old, new, global: false))
        n -> {:error, {:expected_one_changed_match, n}}
      end
    end
  end
  def ls(path), do: File.ls(path)
  def find(glob), do: Path.wildcard(glob, match_dot: true) |> Enum.take(500)
  def grep(pattern, path \\ "/app"), do: sh("grep -RIn --exclude-dir=.git -- " <> quote_arg(pattern) <> " " <> quote_arg(path))
  def quote_arg(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
  def sh(cmd, opts \\ []) do
    dir = "/tmp/orion-tools"
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.unique_integer([:positive])}.log")
    timeout = Keyword.get(opts, :timeout, 60_000)
    start = System.monotonic_time(:millisecond)
    {_, status} = System.cmd("timeout", ["--kill-after=2", "#{timeout / 1000}s", "sh", "-c", "(" <> cmd <> ") > " <> quote_arg(path) <> " 2>&1"], cd: Keyword.get(opts, :cwd, "/app"), stderr_to_stdout: true)
    text = File.read!(path)
    %{status: status, timed_out: status == 124, output: text |> String.split("\n") |> Enum.take(-200) |> Enum.join("\n") |> String.slice(-16000, 16000), truncated: byte_size(text) > 16000 or length(String.split(text, "\n")) > 200, full_output: path, elapsed_ms: System.monotonic_time(:millisecond) - start}
  end
end
