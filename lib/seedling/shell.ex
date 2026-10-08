defmodule Seedling.Shell do
  @moduledoc """
  Bounded shell commands and restart-safe background jobs (Linux, `setsid`, `/bin/sh`).

      {:ok, result} = Seedling.Shell.sh("mix test", cwd: "/tmp/project", timeout: 30_000)
      {:ok, task} = Seedling.Shell.background("make", notify: {:agent, "atlas"})
      Seedling.Shell.status(task)
      Seedling.Shell.tail(task, max_bytes: 8_000, max_lines: 100)
      Seedling.Shell.cancel(task)

  Results use `{:ok, map}` or `{:error, %{reason: reason, message: actionable_text}}`.
  Nonzero exits and timeouts are **command results**, not API errors. Output merges
  stdout/stderr, is always spooled, and `sh/2` keeps only its tail (16 KB/200 lines
  by default). `output_path` holds the full output. No automatic log deletion occurs;
  callers own retention. The spool directory defaults to `/tmp/seedling-shell`.

  Options: `:cwd`, `:env` (map or keyword/string-key pairs; nil unsets a variable),
  `:timeout` (milliseconds, default 30_000; `:infinity` allowed), `:spool_dir`,
  `:max_bytes`, `:max_lines`. Output controls/invalid UTF-8 are sanitized for display with a notice; logs retain
  raw bytes. Background adds `:notify` (pid, registered name,
  `{:agent, name}`, or nil; defaults to the owning named agent when discoverable, otherwise caller). A pid cannot survive its death:
  **use `notify: {:agent, name}` for agent restarts**. Completion is
  `{:seedling_task, id, result}` containing metadata, never command output.

  Workers are unlinked from evals. Named agent delivery is retried while the agent
  is absent, even after an eval/agent restart. Jobs survive agent restarts, **not
  BEAM/container restarts**. Result files can be read through `status/1` after the
  in-memory manager has gone. A manager monitor kills the command's process group
  if a worker is stopped from the dashboard. Descendants that deliberately detach
  into a new session are outside this guarantee.
  """

  alias Seedling.Shell.Tasks

  @doc "Run a command and return its bounded output tail and completion metadata."
  def sh(command, opts \\ []) do
    with :ok <- options(opts),
         {:ok, task} <- background(command, Keyword.put(opts, :notify, nil)) do
      await(task, opts)
    end
  end

  @doc "Start an unlinked task immediately. Returns an opaque handle (a small map)."
  def background(command, opts \\ []) do
    with :ok <- options(opts),
         :ok <- validate(command, opts),
         {:ok, manager} <- Tasks.ensure_started() do
      GenServer.call(manager, {:start, command, opts, self()}, :infinity)
    end
  end

  @doc "Read running or completed metadata. Accepts a task handle, not only a pid."
  def status(%{result_path: path, output_path: output} = task)
      when is_binary(path) and is_binary(output) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          case :erlang.binary_to_term(binary, [:safe]) do
            %{status: status, bytes: bytes, output_path: log, result_path: result} = metadata
            when status in [:exited, :timeout, :cancelled, :error] and is_integer(bytes) and
                   bytes >= 0 and is_binary(log) and is_binary(result) ->
              {:ok, metadata}

            _ ->
              error(:invalid_result, "Result metadata has an invalid shape at #{path}.")
          end
        rescue
          _ -> error(:invalid_result, "Result metadata is corrupt: #{path}")
        end

      {:error, :enoent} ->
        if is_pid(task[:pid]) and Process.alive?(task.pid),
          do: {:ok, Map.merge(task, %{status: :running, bytes: file_size(task.output_path)})},
          else: error(:missing_result, "Task is not running and has no result at #{path}.")

      {:error, reason} ->
        error(reason, "Cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  def status(_), do: error(:invalid_task, "Pass the task handle returned by background/2.")

  @doc "Kill a running command's process group. Completed tasks are unchanged."
  def cancel(%{pid: pid} = task) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, :cancel)
      :ok
    else
      case status(task) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  def cancel(_), do: error(:invalid_task, "Pass the task handle returned by background/2.")

  @doc "Read a bounded tail from a log path or handle, also while a job is running."
  def tail(task_or_path, opts \\ []) do
    with :ok <- options(opts), do: do_tail(task_or_path, opts)
  end

  defp do_tail(task_or_path, opts) do
    path = if is_map(task_or_path), do: task_or_path[:output_path], else: task_or_path
    max_bytes = Keyword.get(opts, :max_bytes, 16_000)
    max_lines = Keyword.get(opts, :max_lines, 200)

    if is_binary(path) and positive?(max_bytes) and positive?(max_lines) do
      with {:ok, io} <- File.open(path, [:read, :binary]),
           result <- read_tail(io, path, max_bytes, max_lines) do
        File.close(io)
        result
      else
        {:error, reason} -> error(reason, "Cannot tail #{path}: #{:file.format_error(reason)}")
      end
    else
      error(:invalid_options, "Pass a log path/handle and positive max_bytes/max_lines.")
    end
  end

  defp read_tail(io, path, max_bytes, max_lines) do
    with {:ok, size} <- :file.position(io, :eof),
         {:ok, _} <- :file.position(io, max(0, size - max_bytes)) do
      data =
        case IO.binread(io, max_bytes) do
          :eof -> ""
          data -> data
        end

      if is_binary(data) do
        # Remove a partial UTF-8 codepoint at the byte boundary; shell output may be binary.
        raw = data
        data = display(data)
        transformed = raw != data
        rendered_cut = byte_size(data) > max_bytes

        data =
          if rendered_cut,
            do: data |> binary_part(byte_size(data) - max_bytes, max_bytes) |> scrub(),
            else: data

        lines =
          String.split(data, "\n")

        effective = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
        selected = Enum.take(effective, -max_lines)

        output =
          Enum.join(selected, "\n") <>
            if(data != "" and String.ends_with?(data, "\n"), do: "\n", else: "")

        truncated = size > max_bytes or length(effective) > max_lines or rendered_cut

        notices =
          [
            if(truncated,
              do:
                "Tail limited to #{max_bytes} bytes/#{max_lines} lines. Full output: #{path}; use Files.read/2 to page or increase tail limits."
            ),
            if(transformed,
              do:
                "Invalid UTF-8 omitted and control bytes escaped for display; raw bytes remain in the log."
            )
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        {:ok,
         %{
           output: output,
           output_path: path,
           bytes: size,
           shown_lines: length(selected),
           truncated: truncated,
           transformed: transformed,
           notice: if(notices == "", do: nil, else: notices)
         }}
      else
        error(:read_failed, "Cannot read output at #{path}: #{inspect(data)}")
      end
    end
  end

  @doc false
  def scrub(binary), do: scrub(binary, [])
  defp scrub(<<c::utf8, rest::binary>>, acc), do: scrub(rest, [<<c::utf8>> | acc])
  defp scrub(<<_invalid, rest::binary>>, acc), do: scrub(rest, acc)
  defp scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  def display(binary) do
    binary
    |> scrub()
    |> String.replace(~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/u, fn <<byte>> ->
      "\\x" <> Base.encode16(<<byte>>)
    end)
  end

  defp await(task, opts) do
    case status(task) do
      {:ok, %{status: :running}} ->
        Process.sleep(10)
        await(task, opts)

      {:ok, result} ->
        with {:ok, tail} <- tail(task, opts), do: {:ok, Map.merge(result, tail)}

      error ->
        error
    end
  end

  defp validate(command, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    env = Keyword.get(opts, :env, [])

    cond do
      not is_binary(command) or command == "" or String.contains?(command, <<0>>) ->
        error(:invalid_command, "Command must be a nonempty string without NUL bytes.")

      not (timeout == :infinity or (positive?(timeout) and timeout <= 4_294_967_295)) ->
        error(:invalid_timeout, "timeout must be 1..4_294_967_295 milliseconds or :infinity.")

      not positive?(Keyword.get(opts, :max_bytes, 16_000)) or
          not positive?(Keyword.get(opts, :max_lines, 200)) ->
        error(:invalid_options, "max_bytes and max_lines must be positive integers.")

      not (is_list(env) or is_map(env)) ->
        error(:invalid_env, "env must be key/value pairs; nil unsets a variable.")

      not Enum.all?(env, fn
        {k, v} ->
          (is_binary(k) or is_atom(k)) and (is_binary(v) or is_nil(v)) and to_string(k) != "" and
            not String.contains?(to_string(k), ["=", <<0>>]) and
              not (is_binary(v) and String.contains?(v, <<0>>))

        _ ->
          false
      end) ->
        error(
          :invalid_env,
          "Environment keys must be strings/atoms without = or NUL; values must be strings or nil."
        )

      not valid_path?(Keyword.get(opts, :cwd, File.cwd!())) or
          not File.dir?(Keyword.get(opts, :cwd, File.cwd!())) ->
        error(:invalid_cwd, "cwd must name an existing directory.")

      not valid_path?(Keyword.get(opts, :spool_dir, System.tmp_dir!())) ->
        error(
          :invalid_spool_dir,
          "spool_dir must be a nonempty directory path without NUL bytes."
        )

      not valid_notify?(Keyword.get(opts, :notify)) ->
        error(
          :invalid_notify,
          "notify must be a local pid, registered atom, {:agent, name}, or nil."
        )

      is_nil(System.find_executable("setsid")) ->
        error(
          :missing_dependency,
          "Install util-linux (setsid) to run isolated shell process groups."
        )

      true ->
        :ok
    end
  end

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: :ok,
      else: error(:invalid_options, "Options must be a keyword list.")
  end

  defp valid_path?(path), do: is_binary(path) and path != "" and not String.contains?(path, <<0>>)
  defp valid_notify?({:agent, name}), do: is_binary(name) and name != ""
  defp valid_notify?(pid) when is_pid(pid), do: node(pid) == node()
  defp valid_notify?(name) when is_atom(name), do: true
  defp valid_notify?(_), do: false

  defp positive?(n), do: is_integer(n) and n > 0

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  @doc false
  def error(reason, message), do: {:error, %{reason: reason, message: message}}
end
