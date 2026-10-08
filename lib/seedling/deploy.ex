defmodule Seedling.Deploy do
  @moduledoc """
  Explicit, operator-owned build and code-loading helpers. Nothing deploys automatically.

      {:ok, build} = Seedling.Deploy.build_command("/app", full_commit_sha,
        build_root: "/tmp/atlas-deploy")
      Seedling.Shell.background(build.command, build.shell_opts)
      # Only after the build succeeds:
      {:ok, plan} = Seedling.Deploy.plan(build.ebin,
        manifest_path: build.manifest_path)
      plan.changed_modules                    # inspect and decide, never blindly approve
      Seedling.Deploy.deploy(plan, approved_modules: [Seedling.Files, Seedling.Shell])

  `build_command/3` creates a command specification, not a build or a deployment.
  It archives an explicit full Git commit into a fresh private directory and sets
  MIX_ENV=prod, MIX_BUILD_ROOT, MIX_DEPS_PATH, MIX_HOME and HEX_HOME there. Build
  paths beneath `/opt/nano` are refused. Installed Mix archives/Rebar are copied
  read-only from `:tool_home` (default ~/.mix) into the private tool cache, or
  bootstrapped privately when missing. Dependencies are fetched in the private
  tree; the live code path and shared production build are never rewritten by this
  helper. The source is trusted: arbitrary Mix aliases/macros are not sandboxed.

  `plan/2` inventories one application's ebin (normally nano), using BEAM code MD5
  versus the **actually loaded** module MD5, plus full-file SHA-256 for artifact
  integrity. It does not load modules. The full plan is saved as a term manifest;
  the returned handle has a bounded preview and changed module names. `entries/2`
  pages the inventory. Missing/new modules are distinguished from unchanged ones.

  `deploy/2` requires an explicit nonempty `:approved_modules` atom list. It checks
  artifact hashes and loaded-code freshness before changing code, soft-purges only
  approved modules, refuses old code still in use, caches exact matching old BEAMs
  where available, then loads in the approved order. On load failure it attempts
  rollback in reverse order and reports every rollback result. Reports are written
  next to the plan (`:report_path` can override). No forced purge, process kill,
  application restart, code-path mutation or process-state migration is performed.

  Code loading is not a transactional upgrade of process state. The caller must
  serialize deployment decisions, approve a coherent cohort and coordinate any
  required GenServer migration. Processes may enter old/new code between checks.
  Rollback may be blocked by old code in use or unavailable BEAMs; that is reported,
  never disguised as success. New modules have no prior BEAM and are left loaded on rollback (reported explicitly),
  rather than deleting code that another process may already be using.
  Return shapes are `{:ok, map}` / `{:error, %{reason:, message:, ...}}`.
  """
  alias Seedling.Shell

  @doc "Return a private production build command and its shell options; does not execute it."
  def build_command(source, revision, opts \\ []) do
    with :ok <- keyword_options(opts),
         :ok <- path_option(source, :source),
         :ok <- path_option(Keyword.get(opts, :build_root), :build_root),
         :ok <- valid_timeout(Keyword.get(opts, :timeout, 300_000)),
         :ok <- path_option(Keyword.get(opts, :tool_home, System.user_home!()), :tool_home),
         :ok <-
           if(
             is_binary(revision) and
               Regex.match?(~r/\A[0-9a-fA-F]{40}([0-9a-fA-F]{24})?\z/, revision),
             do: :ok,
             else:
               error(
                 :invalid_revision,
                 "Pass an explicit full Git commit SHA (40 or 64 hex characters), not HEAD or a branch."
               )
           ),
         root <- Path.expand(Keyword.fetch!(opts, :build_root)),
         :ok <- private_path(root),
         {:ok, check} <-
           Shell.sh("git -C #{quote_arg(Path.expand(source))} cat-file -t #{quote_arg(revision)}",
             spool_dir: Path.join(root, "logs")
           ),
         :ok <-
           if(check.exit_code == 0 and String.trim(check.output) == "commit",
             do: :ok,
             else:
               error(
                 :invalid_revision,
                 "Commit #{revision} is not available in #{source}; fetch/commit it first. #{check.output}"
               )
           ) do
      dir = Path.join(root, String.slice(revision, 0, 12) <> "-" <> nonce())
      snapshot = Path.join(dir, "source")
      build = Path.join(dir, "build")
      archive = Path.join(dir, "source.tar")

      tools =
        build_tools(dir, Keyword.get(opts, :tool_home, Path.join(System.user_home!(), ".mix")))

      command =
        Enum.join(
          [
            "mkdir -p #{quote_arg(snapshot)}",
            "git -C #{quote_arg(Path.expand(source))} archive --format=tar #{quote_arg(revision)} > #{quote_arg(archive)}",
            "tar -xf #{quote_arg(archive)} -C #{quote_arg(snapshot)}",
            "cd #{quote_arg(snapshot)}",
            tools,
            "mix deps.get",
            "mix compile --warnings-as-errors"
          ],
          " && "
        )

      env = %{
        "MIX_ENV" => "prod",
        "MIX_BUILD_ROOT" => build,
        "MIX_DEPS_PATH" => Path.join(dir, "deps"),
        "MIX_HOME" => Path.join(dir, "mix"),
        "HEX_HOME" => Path.join(dir, "hex")
      }

      {:ok,
       %{
         source: Path.expand(source),
         revision: String.downcase(revision),
         directory: dir,
         command: command,
         shell_opts: [
           cwd: Path.expand(source),
           env: env,
           timeout: Keyword.get(opts, :timeout, 300_000),
           spool_dir: Path.join(dir, "logs")
         ],
         ebin: Path.join([build, "prod", "lib", "nano", "ebin"]),
         manifest_path: Path.join(dir, "deployment-plan.term")
       }}
    end
  end

  @doc "Inventory compiled beams without loading them; save a bounded-preview plan handle."
  def plan(ebin, opts \\ []) do
    with :ok <- keyword_options(opts),
         :ok <- path_option(ebin, :ebin),
         :ok <- path_option(Keyword.get(opts, :manifest_path), :manifest_path),
         :ok <-
           if(positive?(Keyword.get(opts, :limit, 25)),
             do: :ok,
             else: error(:invalid_options, "limit must be positive.")
           ),
         path <- Path.expand(Keyword.fetch!(opts, :manifest_path)),
         :ok <- private_path(path),
         {:ok, names} <- File.ls(ebin),
         beams <- names |> Enum.filter(&String.ends_with?(&1, ".beam")) |> Enum.sort(),
         :ok <- inventory_limit(beams, Keyword.get(opts, :max_modules, 256)),
         {:ok, entries} <-
           collect(beams, fn name -> inspect_beam(Path.join(Path.expand(ebin), name)) end),
         :ok <- unique_modules(entries),
         full <- %{
           version: 1,
           ebin: Path.expand(ebin),
           revision: Keyword.get(opts, :revision),
           entries: entries
         },
         {:ok, digest} <- save_term(path, full) do
      handle = %{
        manifest_path: path,
        manifest_sha256: digest,
        changed_modules: for(e <- entries, e.status != :unchanged, do: e.module),
        counts: Enum.frequencies_by(entries, & &1.status)
      }

      with {:ok, preview} <- entries(handle, limit: Keyword.get(opts, :limit, 25)) do
        {:ok, Map.merge(handle, preview)}
      end
    else
      {:error, %{reason: _}} = error ->
        error

      {:error, reason} ->
        error(
          reason,
          "Cannot inventory #{inspect(ebin)}: #{inspect(reason, limit: 20, printable_limit: 500)}. Check ebin and manifest paths."
        )
    end
  end

  @doc "Read a page from a plan handle (1-based offset, default 25 entries)."
  def entries(handle, opts \\ []) do
    with :ok <- keyword_options(opts),
         offset <- Keyword.get(opts, :offset, 1),
         limit <- Keyword.get(opts, :limit, 25),
         :ok <-
           if(positive?(offset) and positive?(limit),
             do: :ok,
             else: error(:invalid_options, "offset and limit must be positive integers.")
           ),
         {:ok, full} <- read_plan(handle) do
      entries = Enum.slice(full.entries, offset - 1, limit)
      cut = offset - 1 + length(entries) < length(full.entries)

      {:ok,
       %{
         entries: entries,
         total_modules: length(full.entries),
         offset: offset,
         truncated: cut,
         next_offset: if(cut, do: offset + length(entries), else: nil),
         notice:
           if(cut,
             do:
               "Inventory page limited to #{limit} entries; call entries/2 with offset: #{offset + length(entries)}. Full manifest: #{handle.manifest_path}",
             else: nil
           )
       }}
    end
  end

  @doc "Load only the explicitly approved cohort; the caller authorizes and invokes this."
  def deploy(handle, opts \\ []) do
    with :ok <- keyword_options(opts),
         approved <- Keyword.get(opts, :approved_modules),
         :ok <- approval(approved),
         {:ok, full} <- read_plan(handle),
         {:ok, selected} <- select(full.entries, approved),
         report_path <-
           Keyword.get(opts, :report_path, handle.manifest_path <> ".deployment.term"),
         :ok <- path_option(report_path, :report_path),
         :ok <- private_path(Path.expand(report_path)),
         {:ok, checked} <- collect(selected, &prepare_entry/1),
         prepared <- Enum.reject(checked, &(&1.status == :unchanged)),
         :ok <- soft_purge_all(prepared) do
      result = load_cohort(prepared, [])

      report =
        case result do
          {:ok, loaded} ->
            %{status: :loaded, loaded: Enum.reverse(Enum.map(loaded, & &1.module)), rollback: []}

          {:error, failed, reason, loaded} ->
            %{
              status: :load_failed,
              failed_module: failed,
              load_error: inspect(reason, limit: 20, printable_limit: 500),
              loaded: Enum.reverse(Enum.map(loaded, & &1.module)),
              rollback: Enum.map(loaded, &rollback/1)
            }
        end

      report =
        Map.merge(report, %{
          approved_modules: approved,
          report_path: Path.expand(report_path),
          manifest_path: handle.manifest_path,
          unavailable_rollback: for(e <- prepared, e.old_md5 && is_nil(e.old_beam), do: e.module)
        })

      persisted = save_term(report.report_path, report)
      compact = compact_report(report, persisted)

      case report.status do
        :loaded ->
          if match?({:ok, _}, persisted),
            do: {:ok, compact},
            else:
              error(
                :report_write_failed,
                "Code loaded but report could not be written; inspect the report in this result.",
                %{report: compact}
              )

        :load_failed ->
          error(
            :load_failed,
            "Loading #{inspect(report.failed_module)} failed; inspect rollback outcomes and report_path before retrying.",
            %{report: compact}
          )
      end
    end
  end

  defp build_tools(dir, home) do
    private = Path.join(dir, "mix")

    copies =
      for name <- ["archives", "elixir"],
          File.dir?(Path.join(home, name)),
          do: "cp -a #{quote_arg(Path.join(home, name))} #{quote_arg(private)}"

    hex = if File.dir?(Path.join(home, "archives")), do: [], else: ["mix local.hex --force"]

    rebar =
      if Path.wildcard(Path.join(home, "elixir/*/rebar3")) != [],
        do: [],
        else: ["mix local.rebar --force"]

    Enum.join(["mkdir -p #{quote_arg(private)}"] ++ copies ++ hex ++ rebar, " && ")
  end

  defp inspect_beam(path) do
    with {:ok, binary} <- File.read(path), {:ok, {module, md5}} <- beam_md5(binary) do
      old = loaded_md5(module)

      {:ok,
       %{
         module: module,
         beam_path: path,
         sha256: sha256(binary),
         md5: hex(md5),
         loaded_md5: if(old, do: hex(old), else: nil),
         status:
           cond do
             is_nil(old) -> :added
             old == md5 -> :unchanged
             true -> :changed
           end
       }}
    else
      {:error, reason} ->
        error(
          :invalid_beam,
          "Cannot inspect BEAM #{path}: #{inspect(reason, limit: 20, printable_limit: 500)}"
        )
    end
  end

  defp prepare_entry(entry) do
    with {:ok, binary} <- File.read(entry.beam_path),
         :ok <-
           if(sha256(binary) == entry.sha256,
             do: :ok,
             else:
               error(
                 :artifact_changed,
                 "#{entry.beam_path} changed since planning; rebuild/replan."
               )
           ),
         {:ok, {module, md5}} <- beam_md5(binary),
         :ok <-
           if(module == entry.module and hex(md5) == entry.md5,
             do: :ok,
             else: error(:artifact_changed, "BEAM module/hash does not match the plan; replan.")
           ),
         old <- loaded_md5(module),
         :ok <-
           if(if(old, do: hex(old), else: nil) == entry.loaded_md5,
             do: :ok,
             else:
               error(
                 :loaded_code_changed,
                 "#{inspect(module)} was loaded/changed since planning; replan before deploying."
               )
           ) do
      {:ok, Map.merge(entry, %{binary: binary, old_md5: old, old_beam: cached_beam(module, old)})}
    else
      {:error, %{reason: _}} = error ->
        error

      {:error, reason} ->
        error(
          reason,
          "Cannot prepare #{entry.beam_path}: #{inspect(reason, limit: 20, printable_limit: 500)}"
        )
    end
  end

  defp select(entries, approved) do
    by_module = Map.new(entries, &{&1.module, &1})
    unknown = Enum.reject(approved, &Map.has_key?(by_module, &1))

    if unknown == [],
      do: {:ok, Enum.map(approved, &by_module[&1])},
      else:
        error(
          :unplanned_module,
          "Approved modules are not in this plan: #{inspect(unknown, limit: 10)}"
        )
  end

  defp soft_purge_all(entries) do
    collect(entries, fn entry ->
      if :code.soft_purge(entry.module),
        do: {:ok, entry.module},
        else:
          error(
            :old_code_in_use,
            "Old code for #{inspect(entry.module)} is still in use; let those processes return/restart safely, then retry. No force purge was performed."
          )
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp load_cohort([], loaded), do: {:ok, loaded}

  defp load_cohort([entry | rest], loaded) do
    case :code.load_binary(entry.module, String.to_charlist(entry.beam_path), entry.binary) do
      {:module, _} -> load_cohort(rest, [entry | loaded])
      {:error, reason} -> {:error, entry.module, reason, loaded}
    end
  end

  defp rollback(%{old_md5: nil} = entry),
    do: %{module: entry.module, status: :new_module_retained}

  defp rollback(%{old_beam: nil} = entry), do: %{module: entry.module, status: :beam_unavailable}

  defp rollback(entry) do
    status =
      if :code.soft_purge(entry.module) do
        {file, binary} = entry.old_beam

        case :code.load_binary(entry.module, file, binary) do
          {:module, _} -> :restored
          {:error, reason} -> {:failed, reason}
        end
      else
        :old_code_in_use
      end

    %{module: entry.module, status: status}
  end

  defp cached_beam(_module, nil), do: nil

  defp cached_beam(module, md5) do
    loaded_file =
      case :code.is_loaded(module) do
        {:file, file} when is_list(file) -> [file]
        _ -> []
      end

    object =
      case :code.get_object_code(module) do
        {^module, binary, file} -> [{file, binary}]
        _ -> []
      end

    candidates =
      Enum.flat_map(loaded_file, fn file ->
        case File.read(file) do
          {:ok, bin} -> [{file, bin}]
          _ -> []
        end
      end) ++ object

    Enum.find(candidates, fn {_file, binary} -> beam_md5(binary) == {:ok, {module, md5}} end)
  end

  defp loaded_md5(module) do
    if :code.is_loaded(module) != false do
      try do
        :erlang.get_module_info(module, :md5)
      rescue
        ArgumentError -> nil
      end
    end
  end

  defp beam_md5(binary) do
    case :beam_lib.md5(binary) do
      {:ok, {_module, _md5}} = result -> result
      other -> {:error, other}
    end
  end

  defp read_plan(%{manifest_path: path, manifest_sha256: digest})
       when is_binary(path) and is_binary(digest) do
    with {:ok, binary} <- File.read(path),
         true <- sha256(binary) == digest,
         %{version: 1, entries: entries} = full when is_list(entries) <-
           :erlang.binary_to_term(binary, [:safe]) do
      if Enum.all?(entries, &valid_entry?/1),
        do: {:ok, full},
        else: error(:invalid_manifest, "Plan entries are malformed; create a new plan.")
    else
      false ->
        error(:manifest_changed, "Plan manifest changed; create a new plan before deployment.")

      _ ->
        error(:invalid_manifest, "Cannot read/validate plan at #{path}; create a new plan.")
    end
  rescue
    _ -> error(:invalid_manifest, "Plan manifest at #{path} is corrupt; create a new plan.")
  end

  defp read_plan(_), do: error(:invalid_plan, "Pass the handle returned by plan/2.")

  defp valid_entry?(%{
         module: module,
         beam_path: path,
         sha256: sha,
         md5: md5,
         loaded_md5: old,
         status: status
       }) do
    is_atom(module) and is_binary(path) and is_binary(sha) and is_binary(md5) and
      (is_nil(old) or is_binary(old)) and status in [:added, :changed, :unchanged]
  end

  defp valid_entry?(_), do: false

  defp save_term(path, value) do
    binary = :erlang.term_to_binary(value)
    temp = path <> "." <> nonce() <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, binary, [:exclusive]),
         :ok <- File.rename(temp, path) do
      {:ok, sha256(binary)}
    else
      {:error, reason} ->
        File.rm(temp)

        error(
          reason,
          "Cannot persist manifest/report at #{path}: #{inspect(reason, limit: 20, printable_limit: 500)}"
        )
    end
  end

  defp compact_report(report, persisted) do
    preview = %{
      status: report.status,
      loaded: Enum.take(report.loaded, 30),
      loaded_count: length(report.loaded),
      rollback: Enum.take(report.rollback, 30),
      report_path: report.report_path,
      unavailable_rollback: Enum.take(report.unavailable_rollback, 30),
      report_saved: match?({:ok, _}, persisted),
      truncated:
        length(report.loaded) > 30 or length(report.rollback) > 30 or
          length(report.unavailable_rollback) > 30,
      notice:
        if(
          length(report.loaded) > 30 or length(report.rollback) > 30 or
            length(report.unavailable_rollback) > 30,
          do: "Report preview limited to 30 modules; full report at #{report.report_path}.",
          else: nil
        )
    }

    Map.merge(preview, Map.take(report, [:failed_module, :load_error]))
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp unique_modules(entries) do
    modules = Enum.map(entries, & &1.module)

    if Enum.uniq(modules) == modules,
      do: :ok,
      else: error(:duplicate_module, "Two BEAM files name the same module; rebuild a clean ebin.")
  end

  defp inventory_limit(beams, limit) do
    cond do
      not positive?(limit) ->
        error(:invalid_options, "max_modules must be positive.")

      beams == [] ->
        error(:empty_inventory, "No BEAMs found; point plan/2 at the built nano ebin.")

      length(beams) > limit ->
        error(
          :inventory_limit,
          "Inventory exceeds #{limit} modules; increase max_modules explicitly."
        )

      true ->
        :ok
    end
  end

  defp approval(modules) do
    if is_list(modules) and modules != [] and Enum.all?(modules, &is_atom/1) and
         Enum.uniq(modules) == modules,
       do: :ok,
       else:
         error(
           :approval_required,
           "Pass an explicit nonempty, unique approved_modules: [Module, ...] list. Nothing is inferred as approval."
         )
  end

  defp keyword_options(opts),
    do:
      if(is_list(opts) and Keyword.keyword?(opts),
        do: :ok,
        else: error(:invalid_options, "Options must be a keyword list.")
      )

  defp path_option(path, name),
    do:
      if(is_binary(path) and path != "" and not String.contains?(path, <<0>>),
        do: :ok,
        else:
          error(
            :invalid_path,
            "#{name} must be an explicit nonempty path string without NUL bytes."
          )
      )

  defp private_path(path) do
    cond do
      path == "/" or path == "/opt/nano" or String.starts_with?(path, "/opt/nano/") ->
        error(
          :shared_build,
          "Refusing to write to / or beneath /opt/nano; use a task-owned private directory."
        )

      symlink_ancestor?(path) ->
        error(
          :symlink_path,
          "Write paths must not traverse symlinks; use the explicit real task directory, not #{path}."
        )

      true ->
        :ok
    end
  end

  defp symlink_ancestor?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> if path == "/", do: false, else: symlink_ancestor?(Path.dirname(path))
    end
  end

  defp valid_timeout(timeout) do
    if timeout == :infinity or (positive?(timeout) and timeout <= 4_294_967_295),
      do: :ok,
      else: error(:invalid_timeout, "timeout must be 1..4_294_967_295 milliseconds or :infinity.")
  end

  defp positive?(n), do: is_integer(n) and n > 0
  defp nonce, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp hex(binary), do: Base.encode16(binary, case: :lower)
  defp sha256(binary), do: binary |> then(&:crypto.hash(:sha256, &1)) |> hex()
  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp error(reason, message, extra \\ %{}),
    do: {:error, Map.merge(%{reason: reason, message: message}, extra)}
end
