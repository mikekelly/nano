defmodule SeedTools do
  @moduledoc "Bounded filesystem and shell helpers. read(path, offset: 1, limit: 200); sh(command, cwd: \"/app\")."
  def read(path, opts \\ []) do
    with {:ok, text} <- File.read(path) do
      lines = String.split(text, "\n")
      offset = Keyword.get(opts, :offset, 1)
      limit = Keyword.get(opts, :limit, 200)

      body =
        lines
        |> Enum.drop(offset - 1)
        |> Enum.take(limit)
        |> Enum.join("\n")
        |> String.slice(0, 16000)

      {:ok, body <> "\n[#{length(lines)} lines; continue with offset=#{offset + limit}]"}
    end
  end

  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, content)
  end

  def edit(path, old, new) do
    with {:ok, text} <- File.read(path) do
      case length(:binary.matches(text, old)) do
        1 when old != new -> File.write(path, String.replace(text, old, new, global: false))
        n -> {:error, "expected one unique, changing match; found #{n}"}
      end
    end
  end

  def sh(cmd, opts \\ []) do
    {text, status} =
      System.cmd("sh", ["-c", cmd], cd: Keyword.get(opts, :cwd, "/app"), stderr_to_stdout: true)

    File.mkdir_p!("/tmp/rigel")
    path = "/tmp/rigel/output-#{System.unique_integer([:positive])}.txt"
    File.write!(path, text)
    %{status: status, output: String.slice(text, -16000, 16000), full_output: path}
  end

  def ls(path), do: File.ls(path)
  def find(glob), do: Path.wildcard(glob) |> Enum.take(1000)

  def grep(pattern, path \\ "/app"),
    do:
      sh(
        "grep -Rn --exclude-dir=.git --exclude-dir=_build --exclude-dir=deps #{quote_arg(pattern)} #{quote_arg(path)} | head -100"
      )

  defp quote_arg(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
