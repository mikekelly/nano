defmodule Nano.Tools do
  @moduledoc ~S"""
  Small file and shell helpers for working on this repository, callable from evals, the
  dashboard or the shell: read a slice of a file, grep, find files, make an exact-text
  edit, write a file, run a command. The point is to turn each of these into one short
  call instead of a fresh piece of code each time.

      Nano.Tools.read("lib/nano_agent.ex", from: 1, to: 40)
      Nano.Tools.grep("Process.exit", "lib/**/*.ex")
      Nano.Tools.find("**/*.exs")
      Nano.Tools.edit("lib/x.ex", "old text", "new text")
      Nano.Tools.shell("mix format --check-formatted")

  Paths are relative to the app directory (`NANO_APP_DIR`, default `/app`) unless absolute.
  Reading and running commands are bounded: output is cut at `max` bytes, and a shell
  command is killed after `timeout` ms. Nothing here links to the caller, so a failed
  command cannot take the caller down.
  """

  @app_dir System.get_env("NANO_APP_DIR") || "/app"
  @max_read 40_000

  @doc "The app directory helpers resolve relative paths against."
  def app_dir, do: @app_dir

  @doc "Absolute path for `path`, resolving relative paths against `app_dir/0`."
  def path(path) when is_binary(path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(@app_dir, path)
  end

  @doc """
  Reads a file, or a slice of it. `from:`/`to:` are 1-based inclusive line numbers
  (default: the whole file). Returns `{:ok, text}` or `{:error, reason}`. Output is cut
  at `max:` bytes (default 40,000) with a marker, so a huge file cannot flood a context.
  """
  def read(path, opts \\ []) do
    max = Keyword.get(opts, :max, @max_read)

    case File.read(path(path)) do
      {:ok, text} -> {:ok, text |> slice(opts) |> clip(max)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slice(text, opts) do
    case {opts[:from], opts[:to]} do
      {nil, nil} ->
        text

      _ ->
        lines = String.split(text, "\n")
        first = max(Keyword.get(opts, :from, 1), 1)
        last = min(Keyword.get(opts, :to, length(lines)), length(lines))

        lines
        |> Enum.slice((first - 1)..max(last - 1, 0)//1)
        |> Enum.with_index(first)
        |> Enum.map_join("\n", fn {line, n} -> Integer.to_string(n) <> "\t" <> line end)
    end
  end

  @doc """
  A file's lines containing `pattern` (a string or a compiled `Regex`), as
  `path:line: text`, at most `limit:` (default 100) matches. `glob` defaults to every
  file under `app_dir`.
  """
  def grep(pattern, glob \\ "**/*", opts \\ []) do
    regex = if is_struct(pattern, Regex), do: pattern, else: Regex.compile!(Regex.escape(pattern))
    limit = Keyword.get(opts, :limit, 100)

    glob
    |> files()
    |> Enum.flat_map(fn file ->
      case File.read(path(file)) do
        {:ok, text} ->
          text
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {line, n} ->
            file <> ":" <> Integer.to_string(n) <> ": " <> String.slice(line, 0, 300)
          end)

        _ ->
          []
      end
    end)
    |> Enum.take(limit)
  end

  @doc "Paths under `app_dir` matching the glob, sorted."
  def find(glob \\ "**/*"), do: files(glob)

  defp files(glob) do
    @app_dir
    |> Path.join(glob)
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&Path.relative_to(&1, @app_dir))
    |> Enum.sort()
  end

  @doc """
  Replaces the first occurrence of the exact `old` text in `path` with `new`. The edit
  is atomic (write to a temp file, rename). Returns `{:ok, path}` or
  `{:error, :no_match | :ambiguous | reason}`; `:ambiguous` when `old` appears twice or
  more.
  """
  def edit(path, old, new) do
    at = path(path)

    with {:ok, text} <- File.read(at),
         :ok <- unique(text, old) do
      write(path, String.replace(text, old, new, global: false))
    end
  end

  defp unique(text, old) do
    case length(String.split(text, old)) do
      1 -> {:error, :no_match}
      2 -> :ok
      _ -> {:error, :ambiguous}
    end
  end

  @doc "Writes `text` to `path` (absolute or relative to `app_dir`), atomically."
  def write(path, text) do
    at = path(path)
    tmp = at <> ".nano-tmp"

    with :ok <- File.mkdir_p(Path.dirname(at)),
         :ok <- File.write(tmp, text),
         :ok <- File.rename(tmp, at) do
      {:ok, path}
    end
  end

  @doc """
  Runs a shell command in `app_dir` (or `cd:`), returning `{output, exit_status}`.
  Output is cut at `max:` bytes (default 40,000); the command is killed after
  `timeout:` ms (default 60,000), reported as `{"timed out", :timeout}`. stderr is
  merged into stdout, so a failure's reason comes back with it.
  """
  def shell(command, opts \\ []) do
    cd = Keyword.get(opts, :cd, @app_dir)
    max = Keyword.get(opts, :max, @max_read)
    timeout = Keyword.get(opts, :timeout, 60_000)

    task =
      Task.Supervisor.async_nolink(Nano.EvalSupervisor, fn ->
        System.cmd("sh", ["-c", command], cd: path(cd), stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {clip(output, max), status}
      nil -> {"timed out after " <> Integer.to_string(timeout) <> " ms", :timeout}
      {:exit, reason} -> {inspect({:exit, reason}), :error}
    end
  end

  defp clip(text, max) do
    if byte_size(text) <= max,
      do: text,
      else: binary_part(text, 0, max) <> "\n[cut: " <> Integer.to_string(max) <> " bytes]"
  end
end
