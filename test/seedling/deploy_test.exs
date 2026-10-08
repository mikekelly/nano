defmodule Seedling.DeployTest do
  use ExUnit.Case, async: true
  alias Seedling.Deploy
  alias Seedling.Shell

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "atlas-deploy-test-" <> Base.encode16(:crypto.strong_rand_bytes(10))
      )

    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    suffix = System.unique_integer([:positive])
    modules = Enum.map(["A", "B", "C"], &Module.concat(__MODULE__, "Fixture#{&1}#{suffix}"))

    on_exit(fn ->
      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end)

      File.rm_rf(dir)
    end)

    %{dir: dir, ebin: ebin, modules: modules, manifest: Path.join(dir, "plan.term")}
  end

  test "inventory does not load, classifies actual loaded MD5, and pages compact metadata", ctx do
    [a, b, c] = ctx.modules
    load_old(a, 1, ctx.dir)
    load_old(b, 1, ctx.dir)
    beam(a, 1, ctx.ebin)
    beam(b, 2, ctx.ebin)
    beam(c, 1, ctx.ebin)
    assert :code.is_loaded(c) == false
    assert {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest, limit: 1)
    assert :code.is_loaded(c) == false
    assert plan.counts == %{unchanged: 1, changed: 1, added: 1}
    assert plan.changed_modules == [b, c]
    assert plan.truncated
    assert plan.next_offset == 2
    assert plan.notice =~ "offset: 2"
    assert {:ok, second} = Deploy.entries(plan, offset: 2)
    assert Enum.map(second.entries, & &1.module) == [b, c]
    refute second.truncated
    assert hd(second.entries).loaded_md5 != hd(second.entries).md5
    refute File.read!(ctx.manifest) =~ "FOR1"
  end

  test "explicit approval loads only selected modules and persists compact report", ctx do
    [a, b, _] = ctx.modules
    load_old(a, 1, ctx.dir)
    load_old(b, 1, ctx.dir)
    beam(a, 2, ctx.ebin)
    beam(b, 2, ctx.ebin)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)
    assert {:error, %{reason: :approval_required}} = Deploy.deploy(plan)
    assert {:error, %{reason: :approval_required}} = Deploy.deploy(plan, approved_modules: [])
    assert {:error, %{reason: :unplanned_module}} = Deploy.deploy(plan, approved_modules: [Enum])
    assert {:ok, report} = Deploy.deploy(plan, approved_modules: [a])
    assert report.loaded == [a]
    assert report.report_saved
    assert File.exists?(report.report_path)
    assert apply(a, :version, []) == 2
    assert apply(b, :version, []) == 1
  end

  test "artifact and loaded-code changes abort before any module loads", ctx do
    [a, _, _] = ctx.modules
    load_old(a, 1, ctx.dir)
    target = beam(a, 2, ctx.ebin)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)
    File.write!(target, "tampered")
    assert {:error, %{reason: :artifact_changed}} = Deploy.deploy(plan, approved_modules: [a])
    assert apply(a, :version, []) == 1
    beam(a, 2, ctx.ebin)
    load_old(a, 3, ctx.dir)
    assert {:error, %{reason: :loaded_code_changed}} = Deploy.deploy(plan, approved_modules: [a])
    assert apply(a, :version, []) == 3
  end

  test "manifest hash changes and malformed handles are rejected", ctx do
    [a, _, _] = ctx.modules
    beam(a, 1, ctx.ebin)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)
    File.write!(ctx.manifest, "changed")
    assert {:error, %{reason: :manifest_changed}} = Deploy.deploy(plan, approved_modules: [a])
    assert :code.is_loaded(a) == false
    assert {:error, %{reason: :invalid_plan}} = Deploy.entries(%{})
    assert {:error, %{reason: :invalid_options}} = Deploy.entries(plan, offset: 0)
  end

  test "old code in use is refused without force-purging or killing the process", ctx do
    [a, _, _] = ctx.modules
    load_old(a, 1, ctx.dir)
    parent = self()
    pid = spawn(fn -> apply(a, :wait, [parent]) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:ready, ^pid}
    load_old(a, 2, ctx.dir)
    assert :erlang.check_process_code(pid, a)
    beam(a, 3, ctx.ebin)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)

    assert {:error, %{reason: :old_code_in_use, message: message}} =
             Deploy.deploy(plan, approved_modules: [a])

    assert message =~ "No force purge"
    assert Process.alive?(pid)
    assert apply(a, :version, []) == 2
    send(pid, :stop)
  end

  @tag capture_log: true
  test "later on_load failure rolls an earlier module back from exact cached BEAM", ctx do
    [a, b, _] = ctx.modules
    load_old(a, 1, ctx.dir)
    beam(a, 2, ctx.ebin)
    beam(b, 1, ctx.ebin, true)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)

    assert {:error, %{reason: :load_failed, report: report}} =
             Deploy.deploy(plan, approved_modules: [a, b])

    assert apply(a, :version, []) == 1
    assert report.rollback == [%{module: a, status: :restored}]
    assert report.report_saved
    assert :code.is_loaded(b) == false
    assert File.exists?(report.report_path)
  end

  @tag capture_log: true
  test "new modules without prior BEAM are retained and reported after cohort failure", ctx do
    [a, b, _] = ctx.modules
    beam(a, 1, ctx.ebin)
    beam(b, 1, ctx.ebin, true)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)

    assert {:error, %{reason: :load_failed, report: report}} =
             Deploy.deploy(plan, approved_modules: [a, b])

    assert report.rollback == [%{module: a, status: :new_module_retained}]
    assert apply(a, :version, []) == 1
  end

  test "unchanged approved modules are not reloaded", ctx do
    [a, _, _] = ctx.modules
    load_old(a, 1, ctx.dir)
    beam(a, 1, ctx.ebin)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)
    assert {:ok, %{loaded: [], loaded_count: 0}} = Deploy.deploy(plan, approved_modules: [a])
    refute :erlang.check_old_code(a)
  end

  test "inventory errors are actionable and protected paths/symlinks are refused", ctx do
    assert {:error, %{reason: :empty_inventory}} =
             Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)

    File.write!(Path.join(ctx.ebin, "broken.beam"), "not BEAM")
    assert {:error, %{reason: :invalid_beam}} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)

    assert {:error, %{reason: :shared_build}} =
             Deploy.plan(ctx.ebin, manifest_path: "/opt/nano/private/plan.term")

    link = Path.join(ctx.dir, "link")
    File.ln_s!(ctx.dir, link)

    assert {:error, %{reason: :symlink_path}} =
             Deploy.plan(ctx.ebin, manifest_path: Path.join(link, "plan.term"))

    assert {:error, %{reason: :invalid_path}} = Deploy.plan(nil)
    assert {:error, %{reason: :invalid_options}} = Deploy.plan(ctx.ebin, :bad)
  end

  test "private build specification archives only explicit revision and isolates production paths",
       ctx do
    source = Path.join(ctx.dir, "source ' quoted")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(
      Path.join(source, "mix.exs"),
      "defmodule FixtureBuild.MixProject do\n use Mix.Project\n def project, do: [app: :nano, version: \"0.1.0\", deps: []]\nend\n"
    )

    File.write!(
      Path.join(source, "lib/fixture.ex"),
      "defmodule PrivateBuildFixture do\n def value, do: 1\nend\n"
    )

    git(source, ["init", "-q"])
    git(source, ["config", "user.name", "test"])
    git(source, ["config", "user.email", "test@example.invalid"])
    git(source, ["add", "."])
    git(source, ["commit", "-qm", "fixture"])
    revision = git(source, ["rev-parse", "HEAD"]) |> String.trim()
    # Dirty edits are not silently included in a revision-specific build.
    File.write!(
      Path.join(source, "lib/fixture.ex"),
      "defmodule PrivateBuildFixture do\n def value, do: 2\nend\n"
    )

    assert {:ok, spec} =
             Deploy.build_command(source, revision, build_root: Path.join(ctx.dir, "builds"))

    assert spec.shell_opts[:env]["MIX_ENV"] == "prod"
    assert String.starts_with?(spec.shell_opts[:env]["MIX_BUILD_ROOT"], ctx.dir)
    assert {:ok, %{status: :exited, exit_code: 0}} = Shell.sh(spec.command, spec.shell_opts)
    assert File.exists?(Path.join(spec.ebin, "Elixir.PrivateBuildFixture.beam"))
    assert File.read!(Path.join(spec.directory, "source/lib/fixture.ex")) =~ "do: 1"
    refute File.exists?(Path.join(source, "_build"))

    assert {:error, %{reason: :invalid_revision}} =
             Deploy.build_command(source, "HEAD", build_root: ctx.dir)

    assert {:error, %{reason: :shared_build}} =
             Deploy.build_command(source, revision, build_root: "/opt/nano")
  end

  test "stale unchanged approval is also checked rather than skipped", ctx do
    [a, _, _] = ctx.modules
    load_old(a, 1, ctx.dir)
    beam(a, 1, ctx.ebin)
    {:ok, plan} = Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)
    load_old(a, 2, ctx.dir)
    assert {:error, %{reason: :loaded_code_changed}} = Deploy.deploy(plan, approved_modules: [a])
    assert apply(a, :version, []) == 2
  end

  test "malformed manifest entries are errors before any code change", ctx do
    binary = :erlang.term_to_binary(%{version: 1, entries: [%{bogus: true}]})
    File.write!(ctx.manifest, binary)
    digest = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    handle = %{manifest_path: ctx.manifest, manifest_sha256: digest}
    assert {:error, %{reason: :invalid_manifest}} = Deploy.entries(handle)

    assert {:error, %{reason: :invalid_manifest}} =
             Deploy.deploy(handle, approved_modules: [hd(ctx.modules)])
  end

  test "limits and duplicate modules are actionable", ctx do
    [a, b, _] = ctx.modules
    file = beam(a, 1, ctx.ebin)
    beam(b, 1, ctx.ebin)

    assert {:error, %{reason: :inventory_limit}} =
             Deploy.plan(ctx.ebin, manifest_path: ctx.manifest, max_modules: 1)

    assert {:error, %{reason: :invalid_options}} =
             Deploy.plan(ctx.ebin, manifest_path: ctx.manifest, limit: 0)

    File.cp!(file, Path.join(ctx.ebin, "duplicate.beam"))

    assert {:error, %{reason: :duplicate_module}} =
             Deploy.plan(ctx.ebin, manifest_path: ctx.manifest)
  end

  defp git(source, args) do
    {output, 0} = System.cmd("git", args, cd: source, stderr_to_stdout: true)
    output
  end

  defp load_old(module, version, dir) do
    path = beam(module, version, Path.join(dir, "old-#{version}"))
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), File.read!(path))
  end

  defp beam(module, version, dir, fail_on_load \\ false) do
    File.mkdir_p!(dir)

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [version: 0, wait: 1]},
      {:function, 2, :version, 0, [{:clause, 2, [], [], [{:integer, 2, version}]}]},
      {:function, 3, :wait, 1,
       [
         {:clause, 3, [{:var, 3, :Parent}], [],
          [
            {:op, 3, :!, {:var, 3, :Parent},
             {:tuple, 3, [{:atom, 3, :ready}, {:call, 3, {:atom, 3, :self}, []}]}},
            {:receive, 4, [{:clause, 4, [{:atom, 4, :stop}], [], [{:integer, 4, version}]}]}
          ]}
       ]}
    ]

    forms =
      if fail_on_load do
        [hd(forms), {:attribute, 1, :on_load, {:boot, 0}} | tl(forms)] ++
          [
            {:function, 5, :boot, 0, [{:clause, 5, [], [], [{:atom, 5, :error}]}]}
          ]
      else
        forms
      end

    {:ok, ^module, binary, []} =
      :compile.forms(forms, [:binary, :return_errors, :return_warnings])

    path = Path.join(dir, Atom.to_string(module) <> ".beam")
    File.write!(path, binary)
    path
  end
end
