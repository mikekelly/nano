defmodule Nano.Delegation do
  @moduledoc """
  Start sub-agents that are set up for a job, hand them work, and get results back as
  messages — without the parent's context paying for the child's. The seeding is
  `/app/seedings/delegation.md`.

      {:ok, name} = Nano.Delegation.subagent("scout", prompt: "Read /app/lib and report what each module does")
      # ... carry on; the report arrives in your mailbox as
      # {:nano_report, %{from: "scout", status: :done | :error | :budget, message: "...", turns: 5, cost: 0.001}}
      Nano.Delegation.wait("scout", 600_000)   # or block an eval until it arrives
      Nano.Delegation.subagents()             # every sub-agent I started, with status
      Nano.Delegation.report("scout")         # ask it for a status line without waiting
      Nano.Delegation.stop("scout")

  ## Options for `subagent/2`

    * `prompt:` — the first message the sub-agent receives (default: none, it starts idle
      and waits). The message shape is documented in `message/3`; a plain string is sent as
      `{:task, from_name, text}`.
    * `system_prompt_file:` — a Mustache-style template path. `{{>partial}}` includes another
      file (relative to the template's directory, or absolute); `{{key}}` is substituted
      from the same facts the harness renders into its own prompt (`{{name}}`, `{{pid}}`,
      `{{node}}`, `{{max_turns}}`, … see `render/2`). Default: the node's own prompt
      template, so a sub-agent knows what it is.
    * `pre:` — a list of file paths added to the sub-agent's context before its first turn,
      as `<file path="..." hash="...">…</file>` (hash: sha256 of the contents, first 12 hex
      characters, so the sub-agent can tell whether a file changed).
    * `model:` — an OpenRouter slug (default: the node default).
    * `reasoning:` — `"off"`, `"minimal"`, `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`.
    * `worktree:` — a git SHA. When given, the sub-agent gets its own git worktree of `/app`
      checked out at that SHA under `/data/worktrees/<name>` and its prompt says so; when
      not given it works in `/app` like everyone else.
    * `mcp:` — a list of MCP servers (ids in `/app/mcp.json`, or `{name, command}`
      tuples/`{name, url}`) to connect for the sub-agent (see `Nano.MCP`).
    * `max_turns:`, `max_tokens:`, `max_context:` — the sub-agent's own budget (defaults:
      the node's); running out is reported to the parent, not just logged.

  ## The message protocol

  Between a parent and its sub-agent:

    * parent -> child: `{:task, from_name, text}` — here is work. The child does it and
      replies with a report. (`prompt:` sends one of these as the first message.)
    * child -> parent: `{:report, %{from:, status:, message:, turns:, cost:, context_used:}}`
      — a result. `status` is `:done`, `:error`, `:budget`, `:stopped` or `:no_tool_call`
      (the child ended a turn without calling a tool, which for a sub-agent means it is
      waiting for instructions). This is what `wait/2` matches on.
    * either -> either: `{:note, from_name, text}` — anything else, a bare string for
      instance. Not a report; `wait/2` ignores it unless asked.

  The sub-agent is told all of this in its first message (`brief/2`), so it knows to reply
  with `Nano.Delegation.report_to/2`.

  ## Waiting without spending turns

  The parent can `idle` with a wakeup: the report is an ordinary mailbox event and wakes it.
  `wait/2` blocks the calling eval instead (a few hundred ms of eval time) when the parent
  would rather have the answer in the same turn.

  Sub-agents are ordinary agents: they are listed by `Nano.Ops.agents/0` with
  `started_by` set to the parent's name, so the dashboard shows the tree, and `who
  started which` stays true.
  """

  @default_report_timeout 900_000

  ## Starting

  @doc """
  Starts a sub-agent and returns `{:ok, name}` (see the module doc for options). The name
  is generated from `prefix` and checked for uniqueness unless `name:` is given.
  """
  def subagent(prefix \\ "sub", opts \\ []) do
    parent = Keyword.get(opts, :parent) || Nano.Util.calling_agent()
    name = Keyword.get(opts, :name) || unique_name(prefix)

    with {:ok, template} <- template(opts),
         {:ok, prompt_file} <- write_template(name, template),
         {:ok, worktree} <- maybe_worktree(name, opts[:worktree]),
         {:pre, files} <- {:pre, pre_reading(opts[:pre] || [])} do
      agent_opts =
        [
          name: name,
          start_idle: true,
          system_prompt_file: prompt_file,
          model: opts[:model],
          reasoning: opts[:reasoning],
          max_turns: opts[:max_turns],
          max_tokens: opts[:max_tokens],
          max_context: opts[:max_context]
        ]
        |> Enum.reject(fn {_, v} -> is_nil(v) end)

      case NanoAgent.start(agent_opts) do
        {:ok, _pid} ->
          boot(name, parent, files, worktree, opts)
          {:ok, name}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "`subagent/2`, returning the name or raising."
  def subagent!(prefix \\ "sub", opts \\ []) do
    {:ok, name} = subagent(prefix, opts)
    name
  end

  # The brief: who the child is, who sent it, what it should read first, where it works,
  # which MCP servers it has, and the message protocol. Rendered by plain substitution so
  # the child's very first event is self-contained.
  defp boot(name, parent, files, worktree, opts) do
    mcp = Keyword.get(opts, :mcp, [])
    if mcp != [] and Code.ensure_loaded?(Nano.MCP), do: Enum.each(mcp, &connect_mcp(name, &1))

    text = brief(name, parent, files, worktree, mcp)
    message = {:task, parent || "operator", text}

    if parent do
      Nano.Delegation.Store.remember(name, parent)
      Nano.Delegation.Watcher.watch(name, parent)
    end

    send(NanoAgent.whereis(name), message)
    :ok
  end

  defp connect_mcp(name, server) do
    case server do
      {id, command} when is_list(command) -> Nano.MCP.connect(id, command, agent: name)
      {id, url} when is_binary(url) -> Nano.MCP.connect(id, url, agent: name)
      id when is_binary(id) -> Nano.MCP.connect(id, agent: name)
      other -> {:error, {:bad_mcp, other}}
    end
  end

  @doc false
  def brief(name, parent, files, worktree, mcp) do
    """
    #{if parent, do: "You are a sub-agent started by #{parent}.", else: "You are a sub-agent."} \
    Your name is #{name}. You work in #{worktree || "/app"}, on the same BEAM node as your parent.

    Reply to a task by calling, from an eval:

        Nano.Delegation.report_to(#{inspect(parent || "operator")}, :done, "what you found")

    `report_to/3` sends `{:report, %{from: #{inspect(name)}, status: :done, message: ...}}` to
    your parent's mailbox, which is how it learns you are finished; status is `:done`,
    `:error` or `:budget`. A plain reply written as text reaches no one. If you need to ask a
    question instead of finishing, report with `:note` — `report_to(#{inspect(parent || "operator")}, :note, "question")` —
    and then `idle`.

    #{if files != [], do: "Before you start, these files were added to your context:\\n" <> Enum.map_join(files, "\\n", fn {path, hash} -> "  * #{path} (sha256 #{hash})" end) <> "\\n", else: ""}#{if mcp != [], do: "MCP servers connected for you: #{inspect(mcp)}. See `Nano.MCP.catalogue/0`.\\n", else: ""}#{if worktree, do: "Do all your editing inside #{worktree} (that is your worktree of /app at the SHA your parent chose).\\n", else: ""}
    Nothing you write in a response reaches your parent or anyone else; only `eval` does
    anything. You have the same tools as every agent here: `eval` and `idle`, and the same
    node. `Nano.Capabilities.index()` lists what is available to call.
    """
  end

  ## Reporting (used by the child)

  @doc """
  Sends a report to `parent`. `status` is `:done`, `:error`, `:budget`, `:note` or `:stopped`.
  With no parent, reports to the agent whose eval is calling (a child reporting to its
  parent by default).
  """
  def report_to(parent \\ nil, status, message) do
    parent = parent || Nano.Util.calling_agent()
    from = Nano.Util.calling_agent() || "unknown"

    case resolve(parent) do
      nil ->
        {:error, :no_such_agent}

      pid ->
        send(pid, {:report, report_map(from, status, message)})
        # The watcher need not follow up on a child that has reported.
        if Process.whereis(Nano.Delegation.Watcher), do: Nano.Delegation.Watcher.reported(from)
        :ok
    end
  end

  # A parent named by its registry name, or by pid; anything else does not resolve.
  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp resolve(name), do: NanoAgent.whereis(to_string(name))

  @doc """
  Sends `parent` a one-line status of the calling agent without waiting for it to ask:
  `Nano.Delegation.status_to/2`. Useful for a long job's progress.
  """
  def status_to(parent, message) do
    from = Nano.Util.calling_agent() || "unknown"

    case NanoAgent.whereis(parent) do
      nil -> {:error, :no_such_agent}
      pid -> send(pid, {:note, from, message}) && :ok
    end
  end

  @doc "A report map for `from` with its current budget, cost and status."
  def report_map(from, status, message) do
    info = Nano.Ops.agent(from)

    %{
      from: from,
      status: status,
      message: message,
      turns: info && info.budget[:turns_used],
      cost: info && info.cost,
      context_used: info && info.budget[:context_used],
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  ## Working with sub-agents (used by the parent)

  @doc """
  Sends `text` as a task to a sub-agent: `{:task, from, text}`.
  """
  def task(to, text, from \\ nil) do
    case NanoAgent.whereis(to) do
      nil -> {:error, :no_such_agent}
      pid -> send(pid, {:task, from || Nano.Util.calling_agent() || "operator", text}) && :ok
    end
  end

  @doc """
  Waits for a report from a sub-agent. Blocks the calling eval for up to `timeout:` ms
  (default 900_000) and returns `{:ok, report}` or `{:error, :timeout}`. Use `idle` with a
  wakeup instead when the parent has other work to do; the report is an ordinary event.
  """
  def wait(name, timeout \\ nil, opts \\ []) do
    timeout = timeout || Keyword.get(opts, :timeout, @default_report_timeout)
    name = to_string(name)
    deadline = System.monotonic_time(:millisecond) + timeout
    await_report(name, deadline)
  end

  defp await_report(name, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, :timeout}
    else
      receive do
        {:report, %{from: from} = report} ->
          if from == name, do: {:ok, report}, else: await_report(name, deadline)
      after
        left -> {:error, :timeout}
      end
    end
  end

  @doc """
  Asks a sub-agent for a status line by message, without waiting: `{:task, from, :status}`.
  The sub-agent's answer arrives like any other message.
  """
  def status(to) do
    case NanoAgent.whereis(to) do
      nil -> {:error, :no_such_agent}
      pid -> send(pid, {:task, Nano.Util.calling_agent() || "operator", :status}) && :ok
    end
  end

  @doc """
  The sub-agents that `agent` (default: the calling agent) started, from the delegation
  store: `[%{name:, parent:, started_at:, worktree:, status:, halted:, turns:}]`.
  """
  def subagents(agent \\ nil) do
    agent = agent || Nano.Util.calling_agent()

    Nano.Delegation.Store.children(agent)
    |> Enum.map(fn entry ->
      name = entry["name"]
      info = Nano.Ops.agent(name)

      %{
        name: name,
        parent: entry["parent"],
        started_at: entry["started_at"],
        worktree: entry["worktree"],
        status: info && info.status,
        halted: info && info.halted,
        turns: info && info.budget[:turns_used],
        cost: info && info.cost
      }
    end)
  end

  @doc "Stops a sub-agent for good (`Nano.Ops.stop_agent/1`)."
  def stop(name), do: Nano.Ops.stop_agent(name)

  ## Prompt composition (Mustache-style, partials by `{{>name}}`)

  @doc """
  Renders a template: `{{key}}` from `vars`, `{{>partial}}` includes a file (relative to
  `dir:` or the template's directory), `{{key}}` inside a partial uses the same vars.
  Unresolved `{{…}}` are left as-is so a mistake is visible rather than silent.
  """
  def render(template, vars \\ %{}, opts \\ []) do
    dir = Keyword.get(opts, :dir, File.cwd!())
    template = expand_partials(template, dir, Keyword.get(opts, :depth, 0))

    Enum.reduce(vars, template, fn {k, v}, out ->
      String.replace(out, "{{#{k}}}", to_string(v))
    end)
  end

  defp expand_partials(text, _dir, depth) when depth > 10, do: text

  defp expand_partials(text, dir, depth) do
    case Regex.run(~r/\{\{>\s*([^}\s]+)\s*\}\}/, text) do
      [whole, name] ->
        body =
          case partial(name, dir) do
            {:ok, body} -> body
            {:error, _} -> whole
          end

        text
        |> String.replace(whole, expand_partials(body, dir, depth + 1))
        |> then(&expand_partials(&1, dir, depth + 1))

      nil ->
        text
    end
  end

  defp partial(name, dir) do
    candidates = [name, name <> ".md", name <> ".txt"]

    Enum.find_value(candidates, {:error, :not_found}, fn c ->
      path = if Path.type(c) == :absolute, do: c, else: Path.join(dir, c)

      case File.read(path) do
        {:ok, text} -> {:ok, text}
        _ -> nil
      end
    end)
  end

  defp template(opts) do
    cond do
      opts[:system_prompt] ->
        {:ok, opts[:system_prompt]}

      opts[:system_prompt_file] ->
        read_template(opts[:system_prompt_file])

      true ->
        read_template(Application.get_env(:nano, :system_prompt_file, "priv/system_prompt.txt"))
    end
  end

  defp read_template(path) do
    with {:ok, text} <- File.read(path) do
      {:ok, render(text, render_vars(), dir: Path.dirname(Path.expand(path)))}
    end
  end

  # The same facts the harness renders into its own prompt (see NanoAgent.render/1).
  defp render_vars do
    %{
      "pid" => "",
      "name" => "",
      "node" => node(),
      "otp_release" => "OTP #{System.otp_release()}",
      "elixir_version" => System.version(),
      "os_user" => System.get_env("USER") || "root",
      "os" => os_name(),
      "network_policy" =>
        Application.get_env(:nano, :network_policy, "unrestricted outbound internet access"),
      "max_turns" => "unlimited",
      "max_tokens" => "unlimited",
      "max_context" => "1000000"
    }
  end

  defp os_name do
    with {:ok, text} <- File.read("/etc/os-release"),
         [_, name] <- Regex.run(~r/^PRETTY_NAME="?([^"\n]+)/m, text) do
      name
    else
      _ -> "unknown"
    end
  end

  @doc """
  The contents of files as `<file path="…" hash="…">…</file>` blocks, capped per file
  (`max_bytes:`, default 20_000). Used for a sub-agent's pre-reading.
  """
  def file_blocks(paths, opts \\ []) do
    max = Keyword.get(opts, :max_bytes, 20_000)

    Enum.map_join(paths, "\n\n", fn path ->
      case File.read(path) do
        {:ok, text} ->
          hash =
            text
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)
            |> binary_part(0, 12)

          body =
            if byte_size(text) <= max,
              do: text,
              else: String.slice(text, 0, max) <> "\n[… truncated at #{max} bytes]"

          ~s(<file path="#{path}" hash="#{hash}">\n#{body}\n</file>)

        {:error, reason} ->
          ~s(<file path="#{path}" hash="unreadable">\nCould not read: #{inspect(reason)}\n</file>)
      end
    end)
  end

  defp pre_reading(paths),
    do: paths |> Enum.uniq() |> Enum.map(fn path -> {path, hash_of(path)} end)

  defp hash_of(path) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      _ ->
        "unreadable"
    end
  end

  # The sub-agent gets the file contents in its context before its first turn: written to a
  # file and named in the brief, so the first event carries a pointer, not the whole text.
  defp write_template(name, template) do
    dir = Path.join(Nano.Delegation.Store.dir(), "prompts")
    File.mkdir_p!(dir)
    path = Path.join(dir, name <> ".txt")
    File.write!(path, template)
    {:ok, path}
  end

  @doc """
  Writes the pre-reading blocks to `<goals>/prompts/<name>.files.txt` and returns the path,
  for the agent to read. Sub-agents are given the contents by `pre_read/2` directly; this
  is for callers that want only the pointer.
  """
  def pre_read(name, paths) do
    dir = Path.join(Nano.Delegation.Store.dir(), "prompts")
    File.mkdir_p!(dir)
    path = Path.join(dir, name <> ".files.txt")
    File.write!(path, file_blocks(paths))
    path
  end

  ## Worktrees

  @doc """
  Creates a git worktree of `/app` at `sha` under `/data/worktrees/<name>`, reusing it if it
  is already checked out at that commit. Returns `{:ok, path}` or `{:error, reason}`.
  """
  def worktree(name, sha) do
    root = Path.join(Nano.Util.data_dir(), "worktrees")
    path = Path.join(root, name)
    File.mkdir_p!(root)

    case File.dir?(path) do
      true ->
        head = Nano.Util.sh("git -C #{path} rev-parse HEAD").out |> String.trim()
        if head == sha, do: {:ok, path}, else: {:error, {:worktree_exists, head, sha}}

      false ->
        result = Nano.Util.sh("git -C /app worktree add --detach --force #{path} #{sha} 2>&1")
        if result.status == 0, do: {:ok, path}, else: {:error, {:git, result.out}}
    end
  end

  defp maybe_worktree(_name, nil), do: {:ok, nil}
  defp maybe_worktree(name, sha), do: worktree(name, sha)

  @doc """
  Removes a sub-agent's worktree (`git worktree remove --force`). `:ok`.
  """
  def remove_worktree(name) do
    path = Path.join([Nano.Util.data_dir(), "worktrees", name])
    Nano.Util.sh("git -C /app worktree remove --force #{path} 2>&1")
    :ok
  end

  ## Names

  defp unique_name(prefix) do
    taken = NanoAgent.list() |> MapSet.new()

    Enum.find_value(1..99, fn n ->
      candidate = "#{prefix}-#{n}"
      if MapSet.member?(taken, candidate), do: nil, else: candidate
    end)
  end
end
