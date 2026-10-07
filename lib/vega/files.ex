defmodule Vega.Files do
  @moduledoc "Bounded file/shell helpers: read(path, offset: 1, limit: 200), write, edit, ls, find, grep, sh. Errors are values."
  def read(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      lines = String.split(text, "\n")
      offset = Keyword.get(opts, :offset, 1)
      chosen = lines |> Enum.drop(offset - 1) |> Enum.take(Keyword.get(opts, :limit, 200))
      if offset < 1 or offset > length(lines), do: {:error, {:offset, length(lines)}}, else: {:ok, %{text: Enum.join(chosen, "\n") |> String.slice(0, 16000), next: offset + length(chosen), total: length(lines)}}
    end
  end
  def write(path, text), do: with(:ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, text))
  def edit(path, old, new) do
    with {:ok, text} <- File.read(path) do
      case length(:binary.matches(text, old)) do
        1 when old != new -> File.write(path, String.replace(text, old, new, global: false))
        n -> {:error, "expected one unique changed match, got #{n}"}
      end
    end
  end
  def ls(path \\ "."), do: with({:ok, xs} <- File.ls(path), do: {:ok, Enum.take(Enum.sort(xs), 500)})
  def find(glob), do: Enum.take(Path.wildcard(glob, match_dot: true), 1000)
  def grep(pattern, glob \\ "/app/lib/**/*.ex") do
    (for p <- find(glob), {:ok, t} <- [File.read(p)], {l,n} <- Enum.with_index(String.split(t,"\n"),1), String.contains?(l,pattern), do: {p,n,String.slice(l,0,500)}) |> Enum.take(100)
  end
  def sh(cmd, opts \\ []) do
    File.mkdir_p("/tmp/vega-shell")
    path = "/tmp/vega-shell/" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    {_, status} = System.cmd("timeout", ["--kill-after=2", "#{Keyword.get(opts,:timeout,20000)/1000}s", "sh", "-c", "(" <> cmd <> ") >" <> path <> " 2>&1"], cd: Keyword.get(opts,:cwd,"/app"), env: Keyword.get(opts,:env,[]), stderr_to_stdout: true)
    {:ok,t} = File.read(path)
    tail = t |> String.split("\n") |> Enum.take(-100) |> Enum.join("\n") |> String.slice(-16000,16000)
    %{status: status, output: tail, path: path, bytes: byte_size(t), truncated: byte_size(tail)<byte_size(t)}
  end
end
