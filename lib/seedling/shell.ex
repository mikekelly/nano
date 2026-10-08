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
  `:max_bytes`, `:max_lines`. Background adds `:notify` (pid, registered name,
  `{:agent, name}`, or nil; defaults to caller). A pid cannot survive its death:
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
    with {:ok, task} <- background(command, Keyword.put(opts, :notify, nil)) do
      await(task, opts)
    end
  end

  @doc "Start an unlinked task immediately. Returns an opaque handle (a small map)."
  def background(command, opts \\ []) do
    with :ok <- validate(command, opts),
         {:ok, manager} <- Tasks.ensure_started() do
      GenServer.call(manager, {:start, command, opts, self()}, :infinity)
    end
  end

  @doc "Read running or completed metadata. Accepts a task handle, not only a pid."
  def status(%{result_path: path} = task) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          {:ok, :erlang.binary_to_term(binary, [:safe])}
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
        data = scrub(data)
        lines = String.split(data, "\n")
        effective = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
        selected = Enum.take(effective, -max_lines)

        output =
          Enum.join(selected, "\n") <>
            if(data != "" and String.ends_with?(data, "\n"), do: "\n", else: "")

        truncated = size > max_bytes or length(effective) > max_lines

        {:ok,
         %{
           output: output,
           output_path: path,
           bytes: size,
           shown_lines: length(selected),
           truncated: truncated,
           notice:
             if(truncated,
               do:
                 "Tail limited to #{max_bytes} bytes/#{max_lines} lines. Full output: #{path}; use Files.read/2 to page or increase tail limits.",
               else: nil
             )
         }}
      else
        error(:read_failed, "Cannot read output at #{path}: #{inspect(data)}")
      end
    end
  end

  @doc false
  def scrub(binary), do: for(<<c::utf8 <- binary>>, into: "", do: <<c::utf8>>)

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

      not (timeout == :infinity or positive?(timeout)) ->
        error(:invalid_timeout, "timeout must be a positive number of milliseconds or :infinity.")

      not positive?(Keyword.get(opts, :max_bytes, 16_000)) or
          not positive?(Keyword.get(opts, :max_lines, 200)) ->
        error(:invalid_options, "max_bytes and max_lines must be positive integers.")

      not (is_list(env) or is_map(env)) ->
        error(:invalid_env, "env must be key/value pairs; nil unsets a variable.")

      not Enum.all?(env, fn
        {k, v} ->
          (is_binary(k) or is_atom(k)) and (is_binary(v) or is_nil(v)) and
            not String.contains?(to_string(k), ["=", <<0>>]) and
              not (is_binary(v) and String.contains?(v, <<0>>))

        _ ->
          false
      end) ->
        error(
          :invalid_env,
          "Environment keys must be strings/atoms without = or NUL; values must be strings or nil."
        )

      not File.dir?(Keyword.get(opts, :cwd, File.cwd!())) ->
        error(:invalid_cwd, "cwd must name an existing directory.")

      is_nil(System.find_executable("setsid")) ->
        error(
          :missing_dependency,
          "Install util-linux (setsid) to run isolated shell process groups."
        )

      true ->
        :ok
    end
  end

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
