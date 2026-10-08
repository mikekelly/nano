defmodule Seedling.Files do
  @moduledoc "Bounded file utilities. read(path, offset: 1, limit: 200, bytes: 16000); write/2; edit/3; ls/2; find/2; grep/3. Errors are values."
  def read(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      lines = String.split(text, "\n")
      offset = Keyword.get(opts, :offset, 1)
      limit = Keyword.get(opts, :limit, 200)
      cap = Keyword.get(opts, :bytes, 16000)
      if offset < 1 or offset > length(lines) do
        {:error, "offset outside file: #{length(lines)} lines"}
      else
        chosen = Enum.slice(lines, offset - 1, limit)
        {kept, _} = Enum.reduce_while(chosen, {[], 0}, fn line, {acc, n} ->
          if n + byte_size(line) + 1 > cap, do: {:halt, {acc, n}}, else: {:cont, {[line | acc], n + byte_size(line) + 1}}
        end)
        next = offset + length(kept)
        {:ok, %{text: Enum.reverse(kept) |> Enum.join("\n"), next_offset: if(next <= length(lines), do: next), total_lines: length(lines), warning: if(kept == [], do: "Single line exceeds byte cap; raise bytes")}}
      end
    end
  end
  def write(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, text)
  end
  def edit(path, old, new) do
    with {:ok, text} <- File.read(path) do
      case length(:binary.matches(text, old)) do
        1 when old != new -> File.write(path, String.replace(text, old, new, global: false))
        n -> {:error, "Expected exactly one match and a change, found #{n}; add unique exact context"}
      end
    end
  end
  def ls(path, opts \\ []) do
    with {:ok, entries} <- File.ls(path) do
      limit = Keyword.get(opts, :limit, 500)
      {:ok, %{entries: entries |> Enum.sort() |> Enum.take(limit) |> Enum.map(fn p -> p <> if(File.dir?(Path.join(path,p)), do: "/", else: "") end), truncated: length(entries) > limit}}
    end
  end
  def find(glob, opts \\ []) do
    paths = Path.wildcard(glob, match_dot: true)
    limit = Keyword.get(opts, :limit, 1000)
    {:ok, %{paths: Enum.take(paths, limit), truncated: length(paths) > limit}}
  end
  def grep(pattern, path \\ "/app", opts \\ []) do
    args = ["--hidden", "-n", "--max-count", to_string(Keyword.get(opts,:limit,100))] ++ if(Keyword.get(opts,:literal,false), do: ["-F"], else: []) ++ [pattern,path]
    try do
      {out, status} = System.cmd("rg",args, stderr_to_stdout: true)
      {:ok, %{text: out |> String.split("\n") |> Enum.take(Keyword.get(opts,:limit,100)) |> Enum.map(&String.slice(&1,0,500)) |> Enum.join("\n"), status: status, notice: "Capped matches and lines; refine or use read/2"}}
    rescue e -> {:error, Exception.message(e)} end
  end
end
