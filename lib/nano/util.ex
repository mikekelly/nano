defmodule Nano.Util do
  @moduledoc """
  Small utilities for agents and for code that lives in `/app/lib`: read and write files,
  edit text by exact match, search files, run shell commands, inspect the node.

  Everything here is plain functions callable from `eval`; nothing calls into an agent
  process. Start from `Nano.Capabilities.index/0` to see everything the node can do.

      read("/app/NOTES.md")                     # => {:ok, text} | {:error, reason}
      write("/tmp/a.txt", "hi")
      edit("/tmp/a.txt", "hi", "bye")           # exact-match replace, one occurrence
      sh("git status")                          # => %{out: ..., status: 0}
      grep("def start", path: "/app/lib")       # => [%{file: ..., line: 7, text: ...}]

  Bounds are in `limits/0`: `read/2` returns the *tail* of a file when `max:` is given, so
  a log can be followed without loading it all. `sh/2` caps output the same way and returns
  a map, never raises. For a long command, use `Nano.Background.start/2` instead.
  """

  @limits %{read_bytes: 40_000, grep_matches: 50, sh_bytes: 20_000, sh_timeout: 30_000}

  @doc "The default bounds this module applies, as a map."
  def limits, do: @limits

  ## Files

  @doc """
  Reads a file. `{:ok, text}`, or `{:error, reason}` (`:enoent` for a missing file,
  `:eisdir` for a directory). Options:

    * `max:` — keep at most this many bytes; the beginning by default, the end if `tail: true`;
      a marker says the text was cut.
    * `tail:` — keep the end instead of the beginning.
  """
  def read(path, opts \\ []) do
    case File.read(path) do
      {:ok, text} -> {:ok, clip(text, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads a file and raises on failure; see `read/2`."
  def read!(path, opts \\ []), do: clip(File.read!(path), opts)

  @doc """
  Reads an agent's log (`Nano.Log.read/2`) as entries with string keys; `since:` is a seq.
  `last: n` keeps only the last `n` entries: the way to look at a long agent's log.
  """
  def log(id_or_name, opts \\ []) do
    entries =
      case agent_id(id_or_name) do
        nil -> []
        id -> Nano.Log.read(id, Keyword.get(opts, :since, 0))
      end

    case Keyword.get(opts, :last) do
      nil -> entries
      n -> Enum.take(entries, -n)
    end
  end

  @doc "The last `n` log entries of an agent, or `[]` if it is unknown."
  def log_last(id_or_name, n \\ 20), do: log(id_or_name, last: n)

  @doc "Log entries after `seq`."
  def log_since(id_or_name, seq), do: log(id_or_name, since: seq)

  @doc "Writes a file, creating parent directories. Returns `{:ok, path}` or `{:error, reason}`."
  def write(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(path))),
         :ok <- File.write(path, text),
         do: {:ok, path}
  end

  @doc "`write/2`, then returns the byte size."
  def write!(path, text) do
    {:ok, _} = write(path, text)
    byte_size(text)
  end

  @doc """
  Replaces the first occurrence of `old` in a file with `new`. Fails, returning
  `{:error, :not_found}` or `{:error, :ambiguous}`, rather than writing something
  surprising: unless `all: true`, `old` must appear exactly once. Literal text, not a regex.
  """
  def edit(path, old, new, opts \\ []) do
    all? = Keyword.get(opts, :all, false)

    with {:ok, text} <- read(path),
         :ok <- count_ok(text, old, all?) do
      write(path, String.replace(text, old, new, global: all?))
    end
  end

  defp count_ok(text, old, false) do
    case length(String.split(text, old)) do
      1 -> {:error, :not_found}
      2 -> :ok
      _ -> {:error, :ambiguous}
    end
  end

  defp count_ok(text, old, true),
    do: if(String.contains?(text, old), do: :ok, else: {:error, :not_found})

  @doc """
  The files under `dir` whose path matches the glob `pattern` (`"**/*.ex"`);
  `Path.wildcard/1` under the hood, so `*`, `**`, `?` and `[abc]` work.
  """
  def find(pattern, dir \\ "."), do: Path.wildcard(Path.join(dir, pattern))

  @doc """
  Searches files for a string or regex, returning `[%{file:, line:, text:}]` capped at
  `max:` (default `limits().grep_matches`). Options: `path:` (file or directory, default
  `/app/lib`), `kind:` a glob (default `"**/*"`), `ignore_case: true`, `limit:` matches per
  file, `max:` entries returned.
  """
  def grep(pattern, opts \\ []) do
    re = regex(pattern, opts)
    path = Keyword.get(opts, :path, "/app/lib")
    kind = Keyword.get(opts, :kind, "**/*")
    per_file = Keyword.get(opts, :limit, 5)
    max = Keyword.get(opts, :max, @limits.grep_matches)

    files =
      cond do
        File.dir?(path) -> find(kind, path)
        File.regular?(path) -> [path]
        true -> []
      end

    files
    |> Enum.take(500)
    |> Enum.flat_map(&grep_file(&1, re, per_file))
    |> Enum.take(max)
  end

  defp grep_file(path, re, limit) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(re, line) end)
        |> Enum.take(limit)
        |> Enum.map(fn {line, n} -> %{file: path, line: n, text: String.slice(line, 0, 400)} end)

      {:error, _} ->
        []
    end
  end

  defp regex(pattern, opts) do
    text = if is_struct(pattern, Regex), do: Regex.source(pattern), else: to_string(pattern)
    Regex.compile!(text, if(Keyword.get(opts, :ignore_case, false), do: "i", else: ""))
  end

  ## Shell

  @doc """
  Runs a shell command with `sh -c` in `dir` (default the app directory). Returns

      %{out: String.t(), status: integer | nil, timeout: boolean, command: binary, ms: integer}

  Output is capped at `limits().sh_bytes` (the *tail* is kept, and a marker says so) and
  the command is killed after `timeout:` ms (default `limits().sh_timeout`). Never raises.
  For a long command use `Nano.Background.start/2` instead, which reports by event.
  """
  def sh(command, opts \\ []) do
    dir = Keyword.get(opts, :dir, app_dir())
    timeout = Keyword.get(opts, :timeout, @limits.sh_timeout)
    env = Keyword.get(opts, :env, [])
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], cd: dir, stderr_to_stdout: true, env: env)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, status}} ->
        %{
          out: clip_tail(out, @limits.sh_bytes),
          status: status,
          timeout: false,
          command: command,
          ms: System.monotonic_time(:millisecond) - started
        }

      nil ->
        %{
          out: "",
          status: nil,
          timeout: true,
          command: command,
          ms: System.monotonic_time(:millisecond) - started
        }
    end
  end

  @doc "`sh/2`, returning just the output."
  def sh!(command, opts \\ []), do: sh(command, opts).out

  @doc "Runs a program with a list of arguments (each shell-quoted); same result as `sh/2`."
  def cmd(program, args, opts \\ []) do
    sh(Enum.map_join([program | args], " ", &shell_quote/1), opts)
  end

  @doc "Shell-quotes a string with single quotes."
  def shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  ## Node

  @doc "The app checkout (`/app`): the working directory of the node."
  def app_dir, do: File.cwd!()

  @doc "The data directory (`/data` in the container, where logs, state, goals and tasks live)."
  def data_dir, do: System.get_env("NANO_DATA_DIR", "/data")

  @doc """
  A one-screen look at the node: agents, users, process and ETS counts, memory in MB, and
  the running release.
  """
  def node_info do
    %{
      node: node(),
      otp: System.otp_release(),
      elixir: System.version(),
      agents: for(a <- Nano.Ops.agents(), do: Map.take(a, [:name, :status, :halted, :model])),
      users: Nano.User.list(),
      processes: length(Process.list()),
      ets: length(:ets.all()),
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      ports: length(Port.list()),
      uptime_s: div(elem(:erlang.statistics(:wall_clock), 0), 1000)
    }
  end

  @doc "A `Nano.Ops.agents/0` row for one agent, or nil."
  def agent(name), do: Nano.Ops.agent(to_string(name))

  @doc "The latest log entry of an agent, or nil."
  def latest(name \\ :status) do
    case log(name, last: 1) do
      [entry] -> entry
      _ -> nil
    end
  end

  @doc """
  A short human-readable status line for one agent: status, halt, budget, and its last log
  entry types. `name` defaults to the agent whose eval is calling.
  """
  def status(name \\ nil) do
    name = name || calling_agent() || :status

    case agent(name) do
      nil ->
        "no agent #{inspect(name)}"

      a ->
        budget = a.budget

        last =
          case log(name, last: 20) |> Enum.reverse() do
            [] -> "no log"
            entries -> "last: " <> Enum.map_join(Enum.take(entries, 3), " | ", & &1["type"])
          end

        "#{a.name} (#{a.id}) #{a.status}" <>
          "#{if a.halted, do: " HALTED #{a.halted}", else: ""}" <>
          "#{if a.suspended, do: " SUSPENDED", else: ""} " <>
          "turns #{budget.turns_used}#{if budget.max_turns > 0, do: "/#{budget.max_turns}"} " <>
          "tokens #{budget.tokens_used}#{if budget.max_tokens > 0, do: "/#{budget.max_tokens}"} " <>
          "ctx #{budget.context_used} #{last}"
    end
  end

  @doc "Status lines for every agent on the node, the calling agent first."
  def everyone do
    me = calling_agent()

    ([if(me, do: status(me))] ++ for(a <- Nano.Ops.agents(), a.name != me, do: status(a.name)))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The name of the agent whose eval is calling this function, or nil. Found through
  `$callers`: the eval Task is called by the agent process.
  """
  def calling_agent do
    with [pid | _] <- Process.get(:"$callers", []),
         [{:agent, name} | _] <- Registry.keys(Nano.Registry, pid),
         do: name,
         else: (_ -> nil)
  end

  @doc "An agent's id from its name (or the id itself); nil if unknown."
  def agent_id(name_or_id) do
    case Nano.Ops.agent(to_string(name_or_id)) do
      %{id: id} -> id
      nil -> nil
    end
  end

  @doc "Sends a message to an agent as an event. `to:` defaults to the agent whose eval is calling."
  def notify(term, opts \\ []) do
    case Keyword.get(opts, :to) || calling_agent() do
      nil -> {:error, :no_agent}
      target -> NanoAgent.notify(target, term)
    end
  end

  @doc """
  Sends `term` to agent `to` and waits for a reply, up to `timeout:` ms (default 600_000).
  `match:` is a predicate the reply must satisfy (default: the first message to arrive).
  Returns `{:ok, message}` or `{:error, :timeout | :no_such_agent}`.

  Blocks the calling eval, so use it only when the caller has nothing else to do; the
  non-blocking alternative is `Nano.Delegation` (start a sub-agent, idle, get its report as
  an event).
  """
  def ask(to, term, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 600_000)
    match = Keyword.get(opts, :match, fn _ -> true end)

    case NanoAgent.whereis(to) do
      nil ->
        {:error, :no_such_agent}

      pid ->
        send(pid, term)
        await(match, System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp await(match, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, :timeout}
    else
      receive do
        msg -> if match.(msg), do: {:ok, msg}, else: await(match, deadline)
      after
        left -> {:error, :timeout}
      end
    end
  end

  ## Text

  @doc "Caps text with a marker; used by `read/2` and `sh/2`."
  def clip(text, opts) do
    max = Keyword.get(opts, :max)

    cond do
      max == nil ->
        text

      byte_size(text) <= max ->
        text

      Keyword.get(opts, :tail, false) ->
        clip_tail(text, max)

      true ->
        String.slice(text, 0, max) <>
          "\n[… truncated at #{max} bytes; text is #{byte_size(text)} bytes]"
    end
  end

  @doc "Keeps the last `max` bytes of a string, with a marker at the front."
  def clip_tail(text, max) do
    if byte_size(text) <= max do
      text
    else
      " [… truncated; kept the last #{max} of #{byte_size(text)} bytes]\n" <>
        String.slice(text, -max, max)
    end
  end

  @doc "A compact `inspect/2`: bounded by default, so terms in results stay small."
  def show(term, opts \\ []),
    do: inspect(term, Keyword.merge([limit: 50, printable_limit: 400], opts))
end
