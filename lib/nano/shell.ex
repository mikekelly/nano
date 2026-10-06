defmodule Nano.Shell do
  @moduledoc """
  A persistent shell for an agent: one command line at a time, run with `bash -c`,
  returning its combined output and exit status. The working directory and the
  environment carry over from call to call; other shell state does not.

  There is no live shell process. State is just a map, so it is saved with the
  agent's own state and survives an agent restart:

      %{cwd: String.t(), env: [{String.t(), String.t()}], timeout: pos_integer}

  Every call writes its state to private scratch files before and after running the
  command, so a fresh bash picks up the previous call's `cd` and `export` without
  needing to stay alive between calls.
  """

  @default_timeout 120_000
  @max_output 200_000

  @doc "Default state: the cwd the agent runs in, and this node's environment."
  def new(opts \\ []) do
    env = opts[:env] || (System.get_env() |> Enum.reject(fn {_, v} -> is_nil(v) end))

    %{
      cwd: opts[:cwd] || File.cwd!(),
      env: env,
      timeout: opts[:timeout] || @default_timeout
    }
  end

  @doc "The command's default timeout in milliseconds."
  def default_timeout, do: @default_timeout

  @doc """
  Runs `command` in the shell described by `state`. Returns `{result, new_state}`,
  where `result` is `{:ok, output, exit_status}` or `{:error, message}`.

  `opts` may override `:timeout` (ms) for this call only.
  """
  def run(command, state, opts \\ []) when is_binary(command) do
    timeout = opts[:timeout] || state.timeout
    dir = dir()
    File.mkdir_p!(dir)

    out_file = Path.join(dir, "out")
    cwd_file = Path.join(dir, "cwd")
    env_file = Path.join(dir, "env")
    status_file = Path.join(dir, "status")

    # Seed cwd/env from the state passed in, so this call starts where the last one ended.
    File.write!(cwd_file, state.cwd)
    File.write!(env_file, encode_env(state.env))
    File.write!(out_file, "")
    File.rm(status_file)

    # The user's command runs in a brace group so `cd` and `export` affect this shell, whose
    # cwd and environment are then snapshotted. The status is written last: its presence is
    # how the runner knows the command finished rather than being killed.
    script = """
    { #{command}
    } > #{shq(out_file)} 2>&1
    __nano_status=$?
    pwd > #{shq(cwd_file)} 2>>#{shq(out_file)}
    env -0 > #{shq(env_file)} 2>>#{shq(out_file)}
    printf '%s' "$__nano_status" > #{shq(status_file)}
    exit 0
    """

    port =
      Port.open({:spawn_executable, bash()}, [
        :binary,
        :exit_status,
        :hide,
        :nouse_stdio,
        args: ["-c", script],
        cd: state.cwd,
        env: Enum.map(state.env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
      ])

    case await(port, timeout, status_file) do
      {:ok, shell_status} ->
        close(port)
        read_back(out_file, cwd_file, env_file, status_file, shell_status, state)

      :timeout ->
        kill(port)
        {{:error, "Timed out after #{timeout} ms."}, state}
    end
  end

  # {:ok, shell_exit_status | nil} once the command is done, or :timeout. A command normally
  # writes the status file; one that calls `exit` closes the port first. Whichever happens,
  # we return at once.
  defp await(port, timeout, status_file) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(port, deadline, status_file)
  end

  defp await_loop(port, deadline, status_file) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      File.exists?(status_file) ->
        {:ok, nil}

      remaining <= 0 ->
        :timeout

      true ->
        receive do
          {^port, {:exit_status, code}} -> {:ok, code}
          {:EXIT, ^port, _reason} -> {:ok, nil}
        after
          min(max(remaining, 1), 20) -> await_loop(port, deadline, status_file)
        end
    end
  end

  # The command is killed with its whole process group, so anything it spawned goes too.
  defp kill(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      sh("kill", ["-TERM", "--", "-#{os_pid}"])
      sh("kill", ["-TERM", Integer.to_string(os_pid)])
      Process.sleep(100)
      sh("kill", ["-KILL", "--", "-#{os_pid}"])
      sh("kill", ["-KILL", Integer.to_string(os_pid)])
    end

    close(port)
  end

  defp close(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp sh(cmd, args), do: System.cmd(cmd, args, stderr_to_stdout: true)

  defp read_back(out_file, cwd_file, env_file, status_file, shell_status, state) do
    output = read(out_file) |> clip()
    cwd = read(cwd_file) |> String.trim() |> empty_to(state.cwd)
    env = read(env_file) |> decode_env()

    status =
      case read(status_file) |> String.trim() |> parse_status() do
        nil -> shell_status
        n -> n
      end

    # An empty env means the snapshot did not happen (the shell exited early); keep the old one.
    new_state = %{state | cwd: cwd, env: if(env == [], do: state.env, else: env)}
    {{:ok, output, status}, new_state}
  end

  defp clip(text) when byte_size(text) <= @max_output, do: text

  defp clip(text) do
    head =
      case :unicode.characters_to_binary(binary_part(text, 0, @max_output)) do
        {_, valid, _} -> valid
        valid -> valid
      end

    head <> "\n[output truncated at #{@max_output} bytes]"
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp empty_to("", default), do: default
  defp empty_to(s, _), do: s

  defp parse_status(""), do: nil

  defp parse_status(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp encode_env(env), do: Enum.map_join(env, "\0", fn {k, v} -> "#{k}=#{v}" end)

  defp decode_env(""), do: []

  defp decode_env(text) do
    text
    |> String.split("\0", trim: true)
    |> Enum.map(fn entry ->
      case String.split(entry, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  defp dir, do: Path.join(System.tmp_dir!(), "nano_shell")

  defp bash, do: System.find_executable("bash") || "/bin/bash"

  # Single-quote a string for POSIX sh.
  defp shq(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
