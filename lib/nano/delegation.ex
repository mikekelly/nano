defmodule Nano.Delegation do
  @moduledoc """
  Sub-agents: start an agent that is set up for a job, hand it work, and get its result back as
  a message, without the parent's context paying for the child's. The seeding is
  `/app/seedings/delegation.md`.

      {:ok, name} = Nano.Delegation.subagent("scout",
        prompt: "Read /app/lib and report each module's job in one line each",
        pre: ["/app/NOTES.md"])
      # carry on with your own work; the report arrives as a mailbox event:
      #   {:nano_report, %{from: "scout", status: :done, message: "...", turns: 6, cost: 0.0}}
      Nano.Delegation.reports()        # reports that have arrived
      Nano.Delegation.wait("scout")    # or block this eval until it arrives
      Nano.Delegation.subagents()      # what I started, with live status
      Nano.Delegation.stop("scout")

  ## Options for `subagent/2`

    * `prompt:` — the first message (default: none; the child starts idle and waits for work)
    * `system_prompt_file:` — a Mustache-style template; `{{>partial}}` includes another file,
      `{{key}}` substitutes `name`, `pid`, `node`, `max_turns`, … (default: the node's own prompt,
      so a sub-agent is a first-class agent here, not a stranger)
    * `pre:` — files added to the child's context before its first turn, as
      `<file path="…" hash="…">…</file>` with a sha256 prefix, so it can tell if one changed
    * `model:`, `reasoning:`, `max_turns:`, `max_tokens:`, `max_context:`
    * `worktree:` — a git SHA; when given, the child gets its own worktree of `/app` at that SHA
      under `/data/worktrees/<name>` and works there
    * `mcp:` — MCP server ids (or `{id, command}` / `{id, url}`) to connect for the child

  ## The message protocol

    * parent -> child: `{:nano_task, %{from: name, text: text}}` — here is work
    * child -> parent: `{:nano_report, %{from:, status:, message:, turns:, cost:, at:}}` — a result.
      `status` is `:done`, `:blocked`, `:note` (a question mid-task) or `:error`. `report_to/3`
      sends it; the child is told to use it in its brief, and told to send an early `:note`
      rather than saving everything for the end.
    * either: `{:nano_note, from, text}` — anything else; not a report.

  ## Waiting cheaply

  A report is an ordinary mailbox event, so a parent can `idle` with a wakeup and be woken by it:
  the parent's context is never charged for the child's. `wait/2` blocks the calling eval when the
  parent would rather have the answer now.

  ## Budgets and honesty

  A sub-agent gets its own budget. Unlike the runs recorded in `RUNS.md`, running out is *reported
  to the parent*: `Nano.Delegation.Watcher` watches each child and sends the parent a
  `{:nano_report, %{status: :budget | :error | :stopped}}` when the child halts, dies, or goes idle
  without ever reporting — so a parent is never left waiting for a report that will not come.
  It also recovers the child's last assistant text, so a child that died mid-task still tells you
  what it found.
  """

  @default_timeout 900_000

  ## Starting

  @doc "Starts a sub-agent; returns `{:ok, name}`. See the module doc for options."
  def subagent(prefix \\ "sub", opts \\ []) do
    parent = Keyword.get(opts, :parent) || Nano.Util.calling_agent()
    name = Keyword.get(opts, :name) || unique_name(prefix)
    worktree = maybe_worktree(name, opts[:worktree])

    with {:ok, template} <- template(opts),
         {:ok, prompt_file} <- write_prompt(name, template),
         {:ok, worktree} <- worktree,
         :ok <- start_mcp(name, opts[:mcp] || []) do
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
          Nano.Delegation.Store.remember(name, parent, %{worktree: worktree})
          if parent, do: Nano.Delegation.Watcher.watch(name, parent)
          send_message(name, {:nano_task, %{from: parent || "operator", text: brief(name, parent, worktree, opts)}})
          {:ok, name}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "`subagent/2`, returning the name or raising."
  def subagent!(prefix \\ "sub", opts \\ []), do: (fn {:ok, n} -> n end).(subagent(prefix, opts))

  defp send_message(name, term) do
    case NanoAgent.whereis(name) do
      nil -> {:error, :no_such_agent}
      pid -> send(pid, term)
    end
  end

  # The brief is the child's first message, so its first event is self-contained.
  defp brief(name, parent, worktree, opts) do
    files = Keyword.get(opts, :pre, [])

    """
    DO THIS FIRST: your parent learns nothing except through a report. Before anything else,
    and as soon as you have anything worth having (not at the end), call from an eval:

        Nano.Delegation.report_to(#{inspect(parent || "operator")}, :done, "what you found")

    Status is :done, :note, :blocked or :error. Text in a response reaches no one. If your budget
    runs out before you report, everything you found is lost.

    You are a sub-agent on the same BEAM node as your parent. Your name is #{name}.
    #{if parent, do: "You were started by " <> parent <> ".", else: ""} You work in #{worktree || "/app"}.

    #{if files != [], do: "These files were put in your context before you started (a hash is given so you can tell if one changed):\\n" <> Enum.map_join(files, "\\n", fn f -> "  * #{f}" end) <> "\\n", else: ""}#{if worktree, do: "Edit only inside #{worktree}; that is your own worktree of /app.\\n", else: ""}#{mcp_line(opts[:mcp])}
    You have the same tools as every agent here (eval and idle) and the same node. What is
    available to call is indexed by Nano.Capabilities.index(). Read only what you need.
    """
  end

  defp mcp_line(nil), do: ""
  defp mcp_line([]), do: ""
  defp mcp_line(mcp), do: "MCP servers connected for you: #{inspect(mcp)} — see Nano.MCP.catalogue/0.\\n"

  ## Reporting (used by the child)

  @doc """
  Sends a report to `parent` (default: the agent whose eval is calling). `status` is `:done`,
  `:note`, `:blocked` or `:error`.
  """
  def report_to(parent \\ nil, status, message) do
    parent = parent || Nano.Util.calling_agent()
    from = Nano.Util.calling_agent() || "unknown"

    case whereis(parent) do
      nil ->
        {:error, :no_such_agent}

      pid ->
        send(pid, {:nano_report, report(from, status, message)})
        if Process.whereis(Nano.Delegation.Watcher), do: Nano.Delegation.Watcher.reported(from)
        :ok
    end
  end

  defp whereis(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp whereis(name), do: NanoAgent.whereis(to_string(name))

  @doc "A report map for `from`, with its budget and cost."
  def report(from, status, message) do
    info = Nano.Ops.agent(from)

    %{
      from: from,
      status: status,
      message: message,
      turns: info && info.budget[:turns_used],
      cost: info && info.cost,
      context_used: info && info.budget[:context_used],
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  ## Working with sub-agents (used by the parent)

  @doc "Sends `text` to a sub-agent as `{:nano_task, …}`."
  def task(to, text, from \\ nil),
    do: send_message(to, {:nano_task, %{from: from || Nano.Util.calling_agent() || "operator", text: text}})

  @doc """
  Blocks this eval for up to `timeout` ms waiting for the next report from `name`;
  `{:ok, report}` or `{:error, :timeout}`. Prefer `idle` with a wakeup when there is other work.
  """
  def wait(name, timeout \\ nil, opts \\ []) do
    timeout = timeout || Keyword.get(opts, :timeout, @default_timeout)
    name = to_string(name)
    await(name, System.monotonic_time(:millisecond) + timeout)
  end

  defp await(name, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {:error, :timeout}
    else
      receive do
        {:nano_report, %{from: ^name} = r} ->
          store_report(r)
          {:ok, r}

        {:nano_report, _other} = other ->
          store_report(elem(other, 1))
          await(name, deadline)

        other ->
          # Not ours: keep it for the caller's own mailbox later.
          send(self(), other)
          await(name, deadline)
      after
        left -> {:error, :timeout}
      end
    end
  end

  @doc """
  Waits for reports from several sub-agents, up to `timeout` ms; returns the reports that
  arrived, and which are still outstanding. One eval, many children.
  """
  def wait_all(names, timeout \\ nil) do
    timeout = timeout || @default_timeout
    deadline = System.monotonic_time(:millisecond) + timeout
    loop_all(Enum.map(names, &to_string/1), [], deadline)
  end

  defp loop_all(waiting, got, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      waiting == [] -> %{reports: Enum.reverse(got), outstanding: []}
      left <= 0 -> %{reports: Enum.reverse(got), outstanding: waiting}
      true ->
        receive do
          {:nano_report, %{from: from} = r} ->
            store_report(r)
            loop_all(List.delete(waiting, from), [r | got], deadline)

          other ->
            send(self(), other)
            loop_all(waiting, got, deadline)
        after
          left -> %{reports: Enum.reverse(got), outstanding: waiting}
        end
    end
  end

  @doc """
  The reports that have arrived recently, newest first, read from `agent`'s own log (a report is an
  ordinary event, and the log is its durable record, so this works after a restart too).
  """
  def reports(agent \\ nil, limit \\ 20) do
    agent = agent || Nano.Util.calling_agent()

    agent
    |> Nano.Util.log(last: 400)
    |> Enum.filter(&String.contains?(&1["message"] || "", "nano_report"))
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.flat_map(fn entry ->
      case Regex.run(~r/from: "([^"]+)", status: :(\w+), message: "(.*?)", at:/s, entry["message"]) do
        [_, from, status, message] -> [%{"from" => from, "status" => status, "message" => message}]
        _ -> []
      end
    end)
  end


  defp store_report(r), do: Nano.Delegation.Store.remember_report(r)

  @doc "The sub-agents `agent` (default: the caller) started, with their live status."
  def subagents(agent \\ nil) do
    agent = agent || Nano.Util.calling_agent()

    Nano.Delegation.Store.children(agent)
    |> Enum.map(fn entry ->
      info = Nano.Ops.agent(entry["name"])

      %{
        name: entry["name"],
        started_at: entry["started_at"],
        worktree: entry["worktree"],
        status: info && info.status,
        halted: info && info.halted,
        turns: info && info.budget[:turns_used],
        cost: info && info.cost
      }
    end)
  end

  @doc "Stops a sub-agent for good."
  def stop(name), do: Nano.Ops.stop_agent(name)

  @doc "Removes a sub-agent's worktree."
  def remove_worktree(name) do
    path = Path.join([Nano.Util.data_dir(), "worktrees", name])
    Nano.Util.sh("git -C /app worktree remove --force " <> Nano.Util.shell_quote(path) <> " 2>&1")
    :ok
  end

  ## Prompt composition

  @doc """
  Renders a template: `{{key}}` from `vars`, `{{>partial}}` includes a file relative to `dir:`.
  Unresolved `{{…}}` are left visible rather than silently dropped.
  """
  def render(template, vars \\ %{}, opts \\ []) do
    dir = Keyword.get(opts, :dir, File.cwd!())
    template = expand_partials(template, dir, 0)
    Enum.reduce(vars, template, fn {k, v}, out -> String.replace(out, "{{#{k}}}", to_string(v)) end)
  end

  defp expand_partials(_text, _dir, depth) when depth > 10, do: ""
  defp expand_partials(text, dir, depth) do
    case Regex.run(~r/\{\{>\s*([^}\s]+)\s*\}\}/, text) do
      [whole, name] ->
        body =
          case partial(name, dir) do
            {:ok, body} -> body
            {:error, _} -> whole
          end

        expand_partials(String.replace(text, whole, body), dir, depth + 1)

      nil ->
        text
    end
  end

  defp partial(name, dir) do
    Enum.find_value([name, name <> ".md", name <> ".txt"], {:error, :not_found}, fn c ->
      path = if Path.type(c) == :absolute, do: c, else: Path.join(dir, c)

      case File.read(path) do
        {:ok, text} -> {:ok, text}
        _ -> nil
      end
    end)
  end

  defp template(opts) do
    cond do
      opts[:system_prompt] -> {:ok, opts[:system_prompt]}
      opts[:system_prompt_file] -> read_template(opts[:system_prompt_file])
      true -> read_template(Application.get_env(:nano, :system_prompt_file, "priv/system_prompt.txt"))
    end
  end

  defp read_template(path) do
    with {:ok, text} <- File.read(path) do
      {:ok, render(text, render_vars(), dir: Path.dirname(Path.expand(path)))}
    end
  end

  defp render_vars do
    %{
      "pid" => "", "name" => "sub-agent", "node" => node(),
      "otp_release" => "OTP #{System.otp_release()}", "elixir_version" => System.version(),
      "os_user" => "root", "os" => "Debian GNU/Linux 13 (trixie)",
      "network_policy" => Application.get_env(:nano, :network_policy, "unrestricted outbound internet access"),
      "max_turns" => "unlimited", "max_tokens" => "unlimited", "max_context" => "1000000",
      "result_max_bytes" => "51200"
    }
  end

  defp write_prompt(name, template) do
    dir = Path.join(Nano.Delegation.Store.dir(), "prompts")
    File.mkdir_p!(dir)
    path = Path.join(dir, name <> ".txt")
    File.write!(path, template)
    {:ok, path}
  end

  ## Worktrees

  @doc "Creates (or reuses) a worktree of `/app` at `sha` under `/data/worktrees/<name>`."
  def worktree(name, sha) do
    root = Path.join(Nano.Util.data_dir(), "worktrees")
    path = Path.join(root, name)
    File.mkdir_p!(root)

    if File.dir?(path) do
      head = Nano.Util.sh("git -C " <> Nano.Util.shell_quote(path) <> " rev-parse HEAD").out |> String.trim()
      if head == sha, do: {:ok, path}, else: {:error, {:worktree_exists, head, sha}}
    else
      r = Nano.Util.sh("git -C /app worktree add --detach --force " <> Nano.Util.shell_quote(path) <> " " <> Nano.Util.shell_quote(sha) <> " 2>&1")
      if r.status == 0, do: {:ok, path}, else: {:error, {:git, r.out}}
    end
  end

  defp maybe_worktree(name, nil), do: {:ok, nil}
  defp maybe_worktree(name, sha), do: worktree(name, sha)

  defp start_mcp(_name, []), do: :ok
  defp start_mcp(name, servers), do: Enum.each(servers, &connect_mcp(name, &1)) && :ok

  defp connect_mcp(name, server) do
    case server do
      {id, command} when is_list(command) -> Nano.MCP.connect(id, command, agent: name)
      {id, url} when is_binary(url) -> Nano.MCP.connect(id, url, agent: name)
      id when is_binary(id) -> Nano.MCP.connect(id, agent: name)
      other -> {:error, {:bad_mcp, other}}
    end
  end

  defp unique_name(prefix) do
    taken = MapSet.new(NanoAgent.list())

    Enum.find_value(1..99, fn n ->
      c = "#{prefix}-#{n}"
      if MapSet.member?(taken, c), do: nil, else: c
    end)
  end
end
