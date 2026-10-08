defmodule Delegation do
  @moduledoc """
  Compose and start isolated children. Example:
  `subagent("scout", task: "Inspect", revision: "HEAD", model: "openai-codex/gpt-6.1-sol", reasoning: "low", max_context: 272000, max_turns: 100, max_tokens: 0)`.
  `worktree: true` creates /tmp/<name>/checkout on seedling/rigel-<name>.
  `pre: [paths]` supplies bounded file contents and SHA256 hashes.
  Parent receives `{:delegation, name, :result, text}`, `:halted` with reason, or `:down` with exit reason.
  Children call `Delegation.report(parent_name, text)`; address by name survives restarts.
  """
  def compose(parts, job) do
    with {:ok, base} <- File.read("/app/priv/system_prompt.txt") do
      loaded = Enum.map(parts, fn part -> File.read!("/app/priv/partials/#{part}.md") end)
      {:ok, Regex.replace(~r/\{\{!.*?\}\}/s, Enum.join([base | loaded] ++ [job], "\n"), "")}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def subagent(name, opts) do
    parent = Keyword.get(opts, :parent) || caller_name()

    with true <- is_binary(opts[:revision]),
         {:ok, cwd} <- checkout(name, opts),
         {:ok, prompt} <-
           compose(
             Keyword.get(opts, :parts, ["operating", "orientation"]),
             "Your parent is #{parent}. Work in #{cwd}, revision #{opts[:revision]}. Own only your task files. Report with Delegation.report(#{inspect(parent)}, text). Task: #{opts[:task]}"
           ),
         {:ok, pre} <- preread(Keyword.get(opts, :pre, [])),
         {:ok, pid} <-
           NanoAgent.start(
             Keyword.take(opts, [:model, :reasoning, :max_turns, :max_tokens, :max_context]) ++
               [name: name, system_prompt: prompt, start_idle: true]
           ) do
      spawn(fn -> watch(name, pid, parent, Process.monitor(pid), nil) end)

      unless opts[:start_idle],
        do: send(pid, %{message: "Task: #{opts[:task]}\n" <> pre, parent_name: parent})

      {:ok, %{name: name, pid: pid, cwd: cwd}}
    else
      false -> {:error, "revision is required, even for read-only jobs"}
      error -> error
    end
  end

  def report(parent, text),
    do: send(NanoAgent.whereis(parent), {:delegation, caller_name(), :result, text})

  defp caller_name do
    [pid | _] = Process.get(:"$callers", [])

    Enum.find_value(Nano.Names.all(), fn {{kind, name}, p} ->
      if kind == :agent and p == pid, do: name
    end)
  end

  defp checkout(name, opts) do
    if opts[:worktree] do
      path = "/tmp/#{name}/checkout"

      case System.cmd(
             "git",
             ["worktree", "add", "-b", "seedling/rigel-#{name}", path, opts[:revision]],
             cd: "/app",
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, path}
        {text, _} -> {:error, text}
      end
    else
      {:ok, "/app"}
    end
  end

  defp preread(paths) do
    Enum.reduce_while(paths, {:ok, ""}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, text} when byte_size(text) <= 24000 ->
          hash = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
          {:cont, {:ok, acc <> "\nFile #{path} sha256=#{hash}\n" <> text}}

        other ->
          {:halt, {:error, {path, "pre-read missing or over 24000 bytes", other}}}
      end
    end)
  end

  defp watch(name, pid, parent, ref, previous) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        if p = NanoAgent.whereis(parent), do: send(p, {:delegation, name, :down, reason})
    after
      1000 ->
        info = NanoAgent.info(name)
        halted = info && info.halted

        if halted && halted != previous do
          if p = NanoAgent.whereis(parent), do: send(p, {:delegation, name, :halted, halted})
        end

        watch(name, pid, parent, ref, halted)
    end
  end
end
