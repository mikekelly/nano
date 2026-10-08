defmodule SeedTools do
  @moduledoc """
  Bounded filesystem and shell helpers. `read(path, offset: 1, limit: 200)`
  returns a page and an exact continuation. `sh(command, cwd: "/app", timeout: 30_000)`
  streams combined output to a unique file, retaining only its tail in memory.
  Shell timeout is milliseconds; status 124 indicates a timeout. Errors are returned.
  """
  @cap 16_000
  def read(path, opts \\ []) do
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, 200)

    if is_integer(offset) and offset > 0 and is_integer(limit) and limit > 0 do
      with {:ok, io} <- File.open(path, [:read, :binary]) do
        try do
          {parts, _bytes, count, shown, stopped} =
            IO.binstream(io, :line)
            |> Enum.reduce({[], 0, 0, 0, false}, fn line, {parts, bytes, count, shown, stopped} ->
              count = count + 1

              cond do
                count < offset -> {parts, bytes, count, shown, stopped}
                stopped or shown >= min(limit, 2000) -> {parts, bytes, count, shown, true}
                bytes + byte_size(line) > @cap -> {parts, bytes, count, shown, true}
                true -> {[line | parts], bytes + byte_size(line), count, shown + 1, false}
              end
            end)

          cond do
            offset > count and count > 0 ->
              {:error, "offset #{offset} is past EOF (#{count} lines)"}

            stopped and shown == 0 ->
              {:error, "line #{offset} exceeds #{@cap} bytes; use a byte-oriented reader"}

            true ->
              body = parts |> Enum.reverse() |> IO.iodata_to_binary()

              note =
                if stopped,
                  do:
                    "[Showing #{shown} lines of #{count}; continue with offset=#{offset + shown}]",
                  else: "[EOF; #{count} lines]"

              {:ok, body <> "\n" <> note}
          end
        after
          File.close(io)
        end
      end
    else
      {:error, "offset and limit must be positive integers"}
    end
  end

  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, content)
  end

  def edit(path, old, new) when is_binary(old) and is_binary(new) do
    cond do
      old == "" ->
        {:error, "old text must not be empty"}

      old == new ->
        {:error, "replacement must change the file"}

      true ->
        with {:ok, text} <- File.read(path) do
          case length(:binary.matches(text, old)) do
            1 -> File.write(path, String.replace(text, old, new, global: false))
            0 -> {:error, "text not found; match exactly including whitespace and newlines"}
            n -> {:error, "found #{n} matches; add context to make it unique"}
          end
        end
    end
  end

  def sh(cmd, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    if is_binary(cmd) and is_integer(timeout) and timeout > 0 do
      dir =
        Path.join(
          System.tmp_dir!(),
          "seed-tools-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
        )

      with :ok <- File.mkdir_p(dir),
           {:ok, io} <- File.open(Path.join(dir, "output.txt"), [:write, :binary]) do
        try do
          executable = System.find_executable("timeout") || raise "GNU timeout is required"

          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:cd, Keyword.get(opts, :cwd, "/app")},
              {:args, ["--signal=TERM", "--kill-after=1s", "#{timeout / 1000}s", "sh", "-c", cmd]}
            ])

          {status, tail, bytes} = collect(port, io, "", 0)

          %{
            status: status,
            output: tail,
            full_output: Path.join(dir, "output.txt"),
            timed_out: status in [124, 137],
            truncated: bytes > byte_size(tail)
          }
        after
          File.close(io)
        end
      end
    else
      {:error, "command must be a string and timeout a positive integer in milliseconds"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp collect(port, io, tail, bytes) do
    receive do
      {^port, {:data, data}} ->
        :ok = IO.binwrite(io, data)
        text = tail <> data

        text =
          if byte_size(text) > @cap,
            do: binary_part(text, byte_size(text) - @cap, @cap),
            else: text

        collect(port, io, text, bytes + byte_size(data))

      {^port, {:exit_status, status}} ->
        {status, tail, bytes}
    end
  end

  def ls(path) do
    with {:ok, entries} <- File.ls(path), do: {:ok, entries |> Enum.sort() |> Enum.take(500)}
  end

  def find(glob), do: Path.wildcard(glob) |> Enum.take(1000)

  def grep(pattern, path \\ "/app") do
    sh(
      "grep -Rn --exclude-dir=.git --exclude-dir=_build --exclude-dir=deps -- #{quote_arg(pattern)} #{quote_arg(path)}"
    )
  end

  defp quote_arg(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
