defmodule Nano.Flywheel.GraphTest do
  use ExUnit.Case, async: false
  alias Nano.Flywheel, as: F

  defp description(id, scopes, deps \\ [], type \\ :code) do
    %{
      id: id,
      title: "Build #{id}",
      why: "Test durable contract",
      acceptance: ["production proof"],
      risks: ["write failures"],
      rollout: "roll forward",
      base_commit: String.duplicate("a", 40),
      type: type,
      priority: 1,
      requirement_leaves: ["PR-fixture-#{id}"],
      dependencies: deps,
      external_blockers: [],
      scopes: scopes
    }
  end

  defp scope(path, kind \\ :exact), do: %{kind: kind, path: path}

  defp start(context, opts \\ []) do
    {:ok, s} =
      F.start_link(
        [
          root: context.root,
          repository: context.repo,
          owner: "altair",
          owner_pid: self(),
          claimant_resolver: fn _, pid -> pid end
        ] ++ opts
      )

    Process.unlink(s)
    on_exit(fn -> if Process.alive?(s), do: GenServer.stop(s) end)
    s
  end

  defp reconcile(s, generation \\ 0) do
    {:ok, a} =
      F.reconcile(s, %{owner: "altair", owner_generation: generation}, %{
        restoration: :roll_forward
      })

    a
  end

  defp import(s, a, units) do
    assert {:ok, _} = F.import(s, a, %{schema_version: 1, units: units}, %{source: :fixture})
  end

  defp claim(s, id, gen \\ 1) do
    F.claim(s, id, "worker-#{id}", "incarnation-1", gen, "claim-#{id}-#{gen}")
  end

  setup do
    root =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "graph-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: Path.join(root, "authority"), repo: repo}
  end

  test "U03-A1 atomic unit/file races, canonical scopes and whole candidate validation", c do
    s = start(c)
    a = reconcile(s)

    import(s, a, [
      description("A", [scope("lib", :prefix)]),
      description("B", [scope("lib/new.ex")])
    ])

    parent = self()

    workers =
      for id <- ["A", "B"] do
        spawn(fn ->
          result = F.claim(s, id, "worker-#{id}", "one", 1, "race-#{id}")
          send(parent, {:race, id, result})

          receive do
            :stop -> :ok
          end
        end)
      end

    results =
      for _ <- workers do
        assert_receive {:race, id, result}
        {id, result}
      end

    assert Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end) == 1
    assert Enum.count(results, fn {_, r} -> match?({:error, :conflict}, r) end) == 1
    {_, {:ok, token}} = Enum.find(results, fn {_, r} -> match?({:ok, _}, r) end)
    assert {:error, :noncanonical_scope} = F.expand(s, token, [scope("lib/../other")])
    File.ln_s!(c.repo, Path.join(c.repo, "alias"))
    assert {:error, :symlink_scope} = F.expand(s, token, [scope("alias/new.ex")])
    assert {:error, :noncanonical_scope} = F.expand(s, token, [scope("./lib/a")])

    assert {:error, :cycle} =
             F.validate(
               %{
                 schema_version: 1,
                 units: [description("A", [], ["B"]), description("B", [], ["A"])]
               },
               c.repo
             )

    assert {:error, :missing_dependency} =
             F.validate(%{schema_version: 1, units: [description("A", [], ["missing"])]}, c.repo)

    bad = %{description("A", []) | requirement_leaves: []}
    assert {:error, :missing_leaves} = F.validate(%{schema_version: 1, units: [bad]}, c.repo)

    assert {:error, :noncanonical_scope} =
             F.validate(%{schema_version: 1, units: [description("A", [scope("a//b")])]}, c.repo)

    Enum.each(workers, &send(&1, :stop))
  end

  test "U03-A2 failed claim, expansion, release and DOWN writes quarantine without reopening",
       c do
    {:ok, control} = Agent.start_link(fn -> false end)

    writer = fn root, data ->
      if Agent.get(control, & &1),
        do: {:error, :injected},
        else: Nano.Flywheel.Store.write(root, data)
    end

    s = start(c, writer: writer)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")])])
    Agent.update(control, fn _ -> true end)
    assert {:error, {:persistence, _}} = claim(s, "A")
    assert {:error, :degraded} = F.readiness(s, "A")
    Agent.update(control, fn _ -> false end)
    a = reconcile(s, a.owner_generation)
    {:ok, token} = claim(s, "A", a.owner_generation)
    Agent.update(control, fn _ -> true end)
    assert {:error, {:persistence, _}} = F.expand(s, token, [scope("new")])
    {:ok, u} = F.unit(s, "A")
    refute Nano.Flywheel.Scopes.covers?(u.scopes, "new")
    Agent.update(control, fn _ -> false end)
    a = reconcile(s, a.owner_generation)
    {:ok, token} = claim(s, "A", a.owner_generation)
    Agent.update(control, fn _ -> true end)
    assert {:error, {:persistence, _}} = F.release(s, token, :test)
    {:ok, u} = F.unit(s, "A")
    assert u.claim != nil
    assert {:error, :degraded} = F.readiness(s, "A")
    Agent.update(control, fn _ -> false end)
    a = reconcile(s, a.owner_generation)
    parent = self()

    worker =
      spawn(fn ->
        send(parent, {:claimed, F.claim(s, "A", "mortal", "one", a.owner_generation, "mortal")})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, {:ok, _}}
    Agent.update(control, fn _ -> true end)
    ref = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    # Barrier: queued DOWN is processed before read after short bounded wait.
    Process.sleep(50)
    assert {:error, :degraded} = F.readiness(s, "A")
    {:ok, u} = F.unit(s, "A")
    assert u.claim != nil
  end

  test "U03-A2 crash after persist before reply recovers operation and advances fencing", c do
    parent = self()

    hook = fn req ->
      if match?({:claim, _, _, _, _, _}, req),
        do:
          (
            send(parent, :persisted)
            exit(:injected_crash)
          )
    end

    s = start(c, after_persist: hook)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")])])

    spawn(fn ->
      try do
        claim(s, "A")
      catch
        :exit, _ -> :ok
      end
    end)

    assert_receive :persisted
    ref = Process.monitor(s)
    assert_receive {:DOWN, ^ref, :process, ^s, _}
    s2 = start(c)
    assert {:error, :degraded} = F.readiness(s2, "A")
    {:ok, snap} = F.snapshot(s2)
    token = snap.operations["claim-A-1"].token
    assert snap.units["A"].claim != nil
    a2 = reconcile(s2, a.owner_generation)
    assert a2.owner_generation == 2
    assert {:error, :stale} = F.submit(s2, token, %{})
    assert {:ok, :ready} = F.readiness(s2, "A")
  end

  defp git(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp dispatch_candidate(s, t, p) do
    git(p.worktree, ["reset", "--hard", p.base_commit])
    run = Path.join(Path.dirname(p.worktree), "dispatch-#{t.unit}-#{t.claim_generation}")
    runtime = Path.join(run, "runtime")
    File.mkdir_p!(runtime)

    dispatch = %{
      base_commit: p.base_commit,
      worktree: p.worktree,
      branch: git(p.worktree, ["branch", "--show-current"]),
      build_root: Path.join(run, "build"),
      deps_root: Path.join(run, "deps"),
      runtime_root: runtime,
      random_tmp_root: Path.join(run, "tmp"),
      unit_path: Path.join(runtime, "unit.json")
    }

    {:ok, u} = F.unit(s, t.unit)

    resolved =
      Map.put(
        u.description,
        :dispatch,
        Map.merge(
          Map.drop(dispatch, [:unit_path]),
          %{
            worker_name: t.claimant,
            incarnation: t.incarnation,
            authority_generation: t.owner_generation,
            dispatch_generation: u.dispatch_generation + 1
          }
        )
      )

    bytes = Jason.encode!(resolved)
    File.write!(dispatch.unit_path, bytes)

    dispatch =
      Map.put(dispatch, :unit_sha256, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))

    dispatch
  end

  defp prepared_proposal(s, a, t, p) do
    dispatch = dispatch_candidate(s, t, p)
    {:ok, prepared} = F.prepare_dispatch(s, a, t, dispatch)
    git(p.worktree, ["reset", "--hard", p.commit])
    Map.merge(p, %{dispatch_generation: prepared.generation, unit_sha256: prepared.unit_sha256})
  end

  defp accept_fixture(s, a, r, p) do
    # Model the owner accepting before cherry-pick, then its actual clean landed HEAD.
    git(p.worktree, ["reset", "--hard", p.base_commit])
    result = F.integration(s, a, r, :accept)
    git(p.worktree, ["reset", "--hard", p.commit])
    result
  end

  test "U03-A3 land verifies pinned repository HEAD parent scope and exact cherry-pick tree", c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    import(s, a, [%{description("A", [scope("new.ex")]) | base_commit: p.base_commit}])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)
    git(c.repo, ["reset", "--hard", p.base_commit])
    File.write!(Path.join(c.repo, "dirty"), "untracked")
    assert {:error, :dirty_integration_repository} = F.integration(s, a, r, :accept)
    File.rm!(Path.join(c.repo, "dirty"))
    # An earlier nonoverlapping integration changes the current base from the dispatch base.
    File.write!(Path.join(c.repo, "prior"), "prior integration")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "prior integration"])
    accepted_base = git(c.repo, ["rev-parse", "HEAD"])
    assert {:ok, :accepted} = F.integration(s, a, r, :accept)
    assert {:error, :already_accepted} = F.integration(s, a, r, :accept)
    {:ok, pinned} = F.unit(s, "A")
    assert pinned.acceptance == %{repository: c.repo, base_commit: accepted_base}

    assert Enum.any?(
             pinned.history,
             &(&1[:kind] == :integration_accept and &1[:pin] == pinned.acceptance)
           )

    assert {:error, :integration_head_mismatch} =
             F.integration(s, a, r, {:land, String.duplicate("f", 40), :proof})

    git(c.repo, ["reset", "--hard", p.commit])

    assert {:error, :integration_parent_mismatch} =
             F.integration(s, a, r, {:land, p.commit, :proof})

    git(c.repo, ["reset", "--hard", accepted_base])
    File.write!(Path.join(c.repo, "new.ex"), "n ew")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "whitespace changes actual content"])
    unrelated = git(c.repo, ["rev-parse", "HEAD"])

    assert {:error, :integration_content_mismatch} =
             F.integration(s, a, r, {:land, unrelated, :proof})

    git(c.repo, ["reset", "--hard", accepted_base])
    File.write!(Path.join(c.repo, "outside"), "not reserved")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "wrong diff"])
    wrong_diff = git(c.repo, ["rev-parse", "HEAD"])
    assert {:error, :diff_mismatch} = F.integration(s, a, r, {:land, wrong_diff, :proof})
    git(c.repo, ["reset", "--hard", accepted_base])
    {:ok, retry} = F.adopt(s, a, "A", p.id)
    assert retry.integration_generation > r.integration_generation
    assert {:error, :stale_reservation} = F.integration(s, a, r, :accept)
    {:ok, retry_unit} = F.unit(s, "A")
    refute retry_unit.accepted
    assert retry_unit.acceptance == nil
    r = retry
    assert {:ok, :accepted} = F.integration(s, a, r, :accept)
    git(c.repo, ["cherry-pick", p.commit])
    candidate = git(c.repo, ["rev-parse", "HEAD"])
    refute candidate == p.commit
    File.write!(Path.join(c.repo, "dirty"), "untracked")

    assert {:error, :dirty_integration_repository} =
             F.integration(s, a, r, {:land, candidate, :proof})

    File.rm!(Path.join(c.repo, "dirty"))
    assert {:ok, :integrated} = F.integration(s, a, r, {:land, candidate, :proof})
    assert {:error, :already_integrated} = F.integration(s, a, r, :accept)
    {:ok, landed} = F.unit(s, "A")
    assert landed.stages.integrated.commit == candidate
    refute landed.done

    for stage <- [:deployed, :live_verified, :announced],
        do: assert({:ok, ^stage} = F.record_stage(s, a, "A", stage, %{revision: candidate}))

    assert {:ok, :integrated} =
             F.integration(s, a, r, {:land, candidate, :same_revision_recovery})

    {:ok, same_revision} = F.unit(s, "A")
    assert same_revision.stages[:deployed] != nil
    git(c.repo, ["commit", "--amend", "-qm", "different integration identity same tree"])
    replacement = git(c.repo, ["rev-parse", "HEAD"])
    refute replacement == candidate
    assert {:ok, :integrated} = F.integration(s, a, r, {:land, replacement, :new_revision})
    {:ok, changed_revision} = F.unit(s, "A")

    for stage <- [:deployed, :live_verified, :announced],
        do: assert(changed_revision.stages[stage] == nil)

    assert Enum.any?(changed_revision.history, &(&1[:kind] == :revision_invalidated))
  end

  defp fixture(c) do
    git(c.repo, ["init", "-q"])
    git(c.repo, ["config", "user.email", "fixture@example.invalid"])
    git(c.repo, ["config", "user.name", "Fixture"])
    File.write!(Path.join(c.repo, "base"), "base")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "base"])
    base = git(c.repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(c.repo, "new.ex"), "new")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "proposal"])
    commit = git(c.repo, ["rev-parse", "HEAD"])

    %{
      id: "proposal-1",
      base_commit: base,
      commit: commit,
      worktree: c.repo,
      changed_files: ["new.ex"],
      evidence: %{tests: :passed}
    }
  end

  test "U03-A3 death retains reservation, adoption fences stale worker and revalidates actual diff twice",
       c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    d = %{description("A", [scope("base")]) | base_commit: p.base_commit}
    import(s, a, [d, description("B", [scope("new.ex")])])
    parent = self()

    worker =
      spawn(fn ->
        {:ok, t} = claim(s, "A")
        send(parent, {:token, t})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:token, t}
    p = prepared_proposal(s, a, t, p)
    assert {:error, :unclaimed_diff} = F.submit(s, t, p)
    {:ok, _} = F.expand(s, t, [scope("new.ex")])
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)
    ref = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    Process.sleep(50)
    assert {:error, {:not_ready, :reserved}} = F.readiness(s, "A")
    assert {:error, :conflict} = F.readiness(s, "B")
    assert {:error, :stale} = F.submit(s, t, p)
    {:ok, adopted} = F.adopt(s, a, "A", p.id)
    assert adopted.integration_generation > r.integration_generation
    assert {:error, :stale_reservation} = F.integration(s, a, r, :accept)
    assert {:ok, :accepted} = accept_fixture(s, a, adopted, p)
    # Replace object repository: actual commit validation fails again at land.
    File.rename!(Path.join(c.repo, ".git"), Path.join(c.repo, ".hidden-git"))

    assert {:error, :git_diff_failed} =
             F.integration(s, a, adopted, {:land, p.commit, %{review: :fresh}})

    File.rename!(Path.join(c.repo, ".hidden-git"), Path.join(c.repo, ".git"))
    assert {:ok, :integrated} = F.integration(s, a, adopted, {:land, p.commit, %{review: :fresh}})
    GenServer.stop(s)
    s2 = start(c)
    {:ok, saved} = F.unit(s2, "A")
    assert saved.reservation == adopted
    assert saved.stages.integrated.commit == p.commit
    refute saved.done
    a2 = reconcile(s2, 1)
    assert {:error, :stale_reservation} = F.integration(s2, a2, adopted, :accept)
    {:ok, adopted2} = F.adopt(s2, a2, "A", p.id)
    assert {:ok, :abandoned} = F.integration(s2, a2, adopted2, {:abandon, :test})
    assert {:ok, :ready} = F.readiness(s2, "B")
  end

  test "U03-A4 code stages and external blockers never falsely release dependents", c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    d = %{description("A", [scope("new.ex")]) | base_commit: p.base_commit}
    import(s, a, [d, description("B", [], ["A"])])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)
    {:ok, :accepted} = accept_fixture(s, a, r, p)
    {:ok, :integrated} = F.integration(s, a, r, {:land, p.commit, %{commit: p.commit}})

    for stage <- [:implemented, :tested, :reviewed, :deployed, :live_verified] do
      assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")
      assert {:error, :missing_stages} = F.close(s, a, "A")
      assert {:ok, ^stage} = F.record_stage(s, a, "A", stage, %{evidence: stage})
    end

    assert {:error, :missing_stages} = F.close(s, a, "A")
    {:ok, :announced} = F.record_stage(s, a, "A", :announced, %{owner: "altair"})

    {:ok, :external_blockers} =
      F.record_stage(s, a, "A", :external_blockers, ["operator activation"])

    assert {:error, :blocked} = F.close(s, a, "A")
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")
    {:ok, :external_blockers} = F.record_stage(s, a, "A", :external_blockers, [])
    assert {:error, :blocked} = F.close(s, a, "A")

    {:ok, :resolved} =
      F.resolve_external(s, a, "A", %{
        blocker: "operator activation",
        outcome: :verified_resolved,
        verification: %{actual_operator_receipt: :fixture},
        owner_decision: :resolve,
        verified_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    assert {:ok, :done} = F.close(s, a, "A")
    assert {:ok, :ready} = F.readiness(s, "B")
  end

  test "U03-A4 artifact requires actual verification not fictitious deployment", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [], [], :artifact), description("B", [], ["A"])])
    prepare_artifact(s, a, "A")

    for stage <- [:implemented, :tested, :reviewed, :announced, :deployed, :live_verified] do
      {:ok, ^stage} = F.record_stage(s, a, "A", stage, %{evidence: stage})
    end

    assert {:error, :missing_stages} = F.close(s, a, "A")
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")

    {:ok, :artifact_verified} =
      F.record_stage(s, a, "A", :artifact_verified, %{
        artifact: "durable-report",
        verification: :reviewed
      })

    assert {:ok, :done} = F.close(s, a, "A")
    assert {:ok, :ready} = F.readiness(s, "B")
  end

  test "U03-A5 immutable bootstrap provenance and roll-forward restoration retain history", c do
    path = Path.join(c.repo, "bootstrap.json")

    bytes =
      Jason.encode!(%{
        unit: "A",
        owner: "original-worker",
        incarnation: "old",
        generation: 7,
        base: String.duplicate("a", 40),
        history: [%{by: "altair", event: "bootstrap"}],
        stage: "submitted"
      })

    File.write!(path, bytes)
    {:ok, records} = Nano.Flywheel.Bootstrap.capture([path])
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")])])
    # Separate project for actual provenance import.
    c2 = %{c | root: c.root <> "-import"}
    s2 = start(c2)
    a2 = reconcile(s2)

    assert {:ok, _} =
             F.import(s2, a2, %{schema_version: 1, units: [description("A", [])]}, %{
               bootstrap: records,
               freeze: "dispatch frozen"
             })

    {:ok, snap} = F.snapshot(s2)
    assert hd(snap.provenance)["bootstrap"] == Nano.Flywheel.Data.normalize(records)
    assert snap.units["A"].claim == nil
    assert snap.units["A"].claim_generation == 0
    {:ok, token} = claim(s, "A")

    event = %{
      id: "account-1",
      by: token.claimant,
      kind: :progress,
      tokens: nil,
      wall_time_ms: nil
    }

    assert {:ok, "account-1"} = F.append(s, token, "A", event)
    assert {:ok, "account-1"} = F.append(s, token, "A", event)
    {:ok, _} = F.expand(s, token, [scope("future", :prefix)])
    GenServer.stop(s)
    s3 = start(c)
    {:ok, restored} = F.unit(s3, "A")
    assert Enum.count(restored.history, &(&1.id == "account-1")) == 1
    assert Nano.Flywheel.Scopes.covers?(restored.scopes, "future/new")
    assert {:error, :degraded} = claim(s3, "A")
    a3 = reconcile(s3, a.owner_generation)
    assert {:error, :stale} = F.expand(s3, token, [scope("stale")])
    assert {:ok, _} = claim(s3, "A", a3.owner_generation)
    assert File.read!(path) == bytes
  end

  test "U03-A1 same-unit race, conflict expansion and idempotent claim identity", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")]), description("B", [scope("b", :prefix)])])
    parent = self()

    workers =
      for n <- 1..2 do
        spawn(fn ->
          send(parent, {:same, F.claim(s, "A", "racer-#{n}", "one", 1, "same-#{n}")})

          receive do
            :stop -> :ok
          end
        end)
      end

    results =
      for _ <- 1..2 do
        assert_receive {:same, r}
        r
      end

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:not_ready, :reserved}}, &1)) == 1
    {:ok, token} = Enum.find(results, &match?({:ok, _}, &1))
    {:ok, b} = claim(s, "B")
    assert {:error, :conflict} = F.expand(s, token, [scope("b/new"), scope("safe")])
    {:ok, u} = F.unit(s, "A")
    refute Nano.Flywheel.Scopes.covers?(u.scopes, "safe")
    assert {:ok, ^b} = claim(s, "B")
    assert {:error, :operation_conflict} = F.claim(s, "A", "other", "one", 1, "claim-B-1")
    Enum.each(workers, &send(&1, :stop))
  end

  test "U03-A2 production stable-name resolver monitors agent not transient eval Task", c do
    owner = self()
    name = "fixture-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    :yes = Nano.Names.register_name({:agent, name}, owner)
    on_exit(fn -> Nano.Names.unregister_name({:agent, name}) end)
    {:ok, s} = F.start_link(root: c.root, repository: c.repo, owner: name)
    Process.unlink(s)
    on_exit(fn -> if Process.alive?(s), do: GenServer.stop(s) end)

    {:ok, a} =
      Task.async(fn -> F.reconcile(s, %{owner: name, owner_generation: 0}, :test) end)
      |> Task.await()

    {:ok, _} =
      Task.async(fn ->
        F.import(s, a, %{schema_version: 1, units: [description("A", [scope("a")])]}, :test)
      end)
      |> Task.await()

    {:ok, token} =
      Task.async(fn -> F.claim(s, "A", name, "one", 1, "named-claim") end) |> Task.await()

    Process.sleep(30)
    {:ok, u} = F.unit(s, "A")
    assert u.claim.pid == owner

    assert {:ok, ^token} =
             Task.async(fn -> F.expand(s, token, [scope("new")]) end) |> Task.await()

    {:ok, :released} = F.release(s, token, :test)
  end

  test "U03-A2 owner death during deployment preserves reservation and blocks readiness", c do
    p = fixture(c)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, s} =
          F.start_link(
            root: c.root,
            repository: c.repo,
            owner: "altair",
            owner_pid: self(),
            claimant_resolver: fn _, pid -> pid end
          )

        Process.unlink(s)
        a = reconcile(s)
        d = %{description("A", [scope("new.ex")]) | base_commit: p.base_commit}
        import(s, a, [d, description("B", [], ["A"])])
        {:ok, t} = claim(s, "A")
        p = prepared_proposal(s, a, t, p)
        {:ok, r} = F.submit(s, t, p)
        {:ok, :accepted} = accept_fixture(s, a, r, p)
        {:ok, :integrated} = F.integration(s, a, r, {:land, p.commit, :test})
        {:ok, :deployed} = F.record_stage(s, a, "A", :deployed, %{revision: p.commit})
        send(parent, {:deploying, s, r})

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:deploying, s, r}, 1000
    ref = Process.monitor(owner)
    send(owner, :die)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    Process.sleep(30)
    assert {:error, :degraded} = F.readiness(s, "B")
    {:ok, u} = F.unit(s, "A")
    assert u.reservation == r
    assert u.stages.deployed["revision"] == p.commit
    refute u.done
    GenServer.stop(s)
    s2 = start(c)
    a2 = reconcile(s2, 1)
    {:ok, adopted} = F.adopt(s2, a2, "A", p.id)
    assert adopted.owner_generation == 2
    assert {:error, :missing_stages} = F.close(s2, a2, "A")
  end

  test "U03-A5 corrupt and unsupported snapshots never silently reset authority", c do
    File.mkdir_p!(c.root)
    File.write!(Path.join(c.root, "state.term"), <<1, 2, 3>>)
    assert {:error, :corrupt_state} = Nano.Flywheel.Store.read(c.root)
    File.write!(Path.join(c.root, "state.term"), :erlang.term_to_binary(%{schema_version: 99}))
    assert {:error, :unsupported_state} = Nano.Flywheel.Store.read(c.root)
  end

  test "U03-A4 fresh artifact attempt cannot inherit released attempt completion proofs", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [], [], :artifact), description("B", [], ["A"])])
    old = prepare_artifact(s, a, "A")

    for stage <- [:implemented, :tested, :reviewed, :artifact_verified, :announced],
        do:
          assert(
            {:ok, ^stage} =
              F.record_stage(s, a, "A", stage, %{
                artifact: "same-report",
                verification: :current_attempt
              })
          )

    {:ok, previous} = F.unit(s, "A")
    {:ok, :released} = F.release(s, old, :interrupted)
    {:ok, fresh} = F.claim(s, "A", "replacement", "fresh", a.owner_generation, "fresh-artifact")
    assert fresh.claim_generation > old.claim_generation
    {:ok, current} = F.unit(s, "A")
    assert current.stages == %{}
    assert current.dispatch == nil
    assert current.stage_bindings == %{}

    assert Enum.any?(
             current.history,
             &(&1[:kind] == :attempt_archived and &1[:prior_stages] == previous.stages)
           )

    assert {:error, :missing_stages} = F.close(s, a, "A")

    assert {:error, :dispatch_required} =
             F.record_stage(s, a, "A", :artifact_verified, %{
               artifact: "same-report",
               verification: :not_yet_prepared
             })

    prepare_artifact(s, a, "A")
    assert {:error, :missing_stages} = F.close(s, a, "A")

    # Explicit fresh owner proof may verify a referenced unchanged artifact, but is never inferred.
    for stage <- [:implemented, :tested, :reviewed, :artifact_verified, :announced],
        do:
          assert(
            {:ok, ^stage} =
              F.record_stage(s, a, "A", stage, %{
                artifact: "same-report",
                verification: :reverified_current_attempt
              })
          )

    {:ok, proof} = F.unit(s, "A")
    assert proof.stage_bindings.artifact_verified.attempt.claim_token == fresh

    assert proof.stage_bindings.artifact_verified.attempt.unit_sha256 ==
             proof.dispatch.unit_sha256

    assert {:ok, :done} = F.close(s, a, "A")
    assert {:ok, :ready} = F.readiness(s, "B")
  end

  test "U03-A5 reconcile rejects semantically corrupt done snapshot without overwriting authority",
       c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", []), description("B", [], ["A"])])
    {:ok, original} = Nano.Flywheel.Store.read(c.root)
    corrupt = put_in(original, [:units, "A", :done], true)
    bytes = :erlang.term_to_binary(corrupt)
    File.write!(Path.join(c.root, "state.term"), bytes)
    assert {:error, :corrupt_state} = F.reconcile(s, a, %{restoration: :must_validate})
    assert File.read!(Path.join(c.root, "state.term")) == bytes
    {:ok, unchanged} = F.snapshot(s)
    assert unchanged.owner_generation == a.owner_generation
    refute unchanged.units["A"].done
    assert {:error, :degraded} = F.readiness(s, "B")

    assert {:error, :degraded} =
             F.claim(s, "B", "worker", "fresh", a.owner_generation, "corrupt-claim")

    assert File.read!(Path.join(c.root, "state.term")) == bytes
    # Explicit roll-forward repair restores the original coherent checkpoint, not a false done.
    assert :ok = Nano.Flywheel.Store.write(c.root, original)
    assert {:ok, _} = F.reconcile(s, a, %{restoration: :coherent_checkpoint})
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")
  end

  test "U03-A3 closed code reopen archives old proposal and permits fresh prepare submit", c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    import(s, a, [%{description("A", [scope("new.ex")]) | base_commit: p.base_commit}])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)
    {:ok, :accepted} = accept_fixture(s, a, r, p)
    {:ok, :integrated} = F.integration(s, a, r, {:land, p.commit, :proof})

    for stage <- [:implemented, :tested, :reviewed, :deployed, :live_verified, :announced],
        do: assert({:ok, ^stage} = F.record_stage(s, a, "A", stage, %{revision: p.commit}))

    assert {:ok, :done} = F.close(s, a, "A")
    {:ok, before} = F.unit(s, "A")
    assert {:ok, _} = F.reopen(s, a, "A", :confirmed_finding, %{review: :fresh})
    {:ok, opened} = F.unit(s, "A")
    assert opened.proposal == nil
    assert opened.dispatch == nil
    assert opened.stages == %{}

    assert Enum.any?(
             opened.history,
             &(&1[:kind] == :reopened and &1[:prior_proposal] == before.proposal and
                 &1[:prior_dispatch] == before.dispatch)
           )

    File.write!(Path.join(c.repo, "new.ex"), "corrected")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "corrective proposal"])

    correction = %{
      p
      | id: "corrective-proposal",
        base_commit: p.commit,
        commit: git(c.repo, ["rev-parse", "HEAD"])
    }

    {:ok, fresh} =
      F.claim(s, "A", "fresh-worker", "correction", a.owner_generation, "corrective-claim")

    correction = prepared_proposal(s, a, fresh, correction)
    assert {:ok, _} = F.submit(s, fresh, correction)
    assert {:error, :stale} = F.submit(s, t, p)
    assert {:error, :missing_stages} = F.close(s, a, "A")
  end

  test "U03-A3 conflicting three-way integration fails closed despite scoped candidate", c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    import(s, a, [%{description("A", [scope("new.ex")]) | base_commit: p.base_commit}])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)
    git(c.repo, ["reset", "--hard", p.base_commit])
    File.write!(Path.join(c.repo, "new.ex"), "conflicting prior integration")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "conflicting integration base"])
    assert {:ok, :accepted} = F.integration(s, a, r, :accept)
    File.write!(Path.join(c.repo, "new.ex"), "new")
    git(c.repo, ["add", "."])
    git(c.repo, ["commit", "-qm", "manual resolved candidate"])
    candidate = git(c.repo, ["rev-parse", "HEAD"])

    assert {:error, :git_diff_failed} =
             F.integration(s, a, r, {:land, candidate, :manual_resolution_not_reviewed})

    {:ok, unchanged} = F.unit(s, "A")
    assert unchanged.stages[:integrated] == nil
    refute unchanged.done
  end

  test "U03-A5 reconcile rejects valid-term mismatched current claim generation", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [])])
    {:ok, _} = claim(s, "A")
    {:ok, coherent} = Nano.Flywheel.Store.read(c.root)
    bad = put_in(coherent, [:units, "A", :claim, :claim_generation], 999)
    assert :ok = Nano.Flywheel.Store.write(c.root, bad)
    bytes = File.read!(Path.join(c.root, "state.term"))
    assert {:ok, _} = Nano.Flywheel.Store.read(c.root)

    assert {:error, :corrupt_state} =
             F.reconcile(s, a, %{restoration: :reject_generation_mismatch})

    assert File.read!(Path.join(c.root, "state.term")) == bytes
    assert {:error, :degraded} = F.readiness(s, "A")
    {:ok, memory} = F.snapshot(s)
    assert memory.owner_generation == a.owner_generation
    assert memory.units["A"].claim.claim_generation != 999
  end

  defp prepare_artifact(s, a, id) do
    repo = :sys.get_state(s).repository
    unless File.dir?(Path.join(repo, ".git")), do: fixture(%{repo: repo})
    {:ok, snapshot} = F.snapshot(s)
    {:ok, u} = F.unit(s, id)

    t =
      if u.claim != nil,
        do: Map.delete(u.claim, :pid),
        else:
          elem(
            F.claim(
              s,
              id,
              "worker-#{id}",
              "artifact-#{u.claim_generation}",
              a.owner_generation,
              "artifact-#{id}-#{u.claim_generation}"
            ),
            1
          )

    p = %{
      worktree: repo,
      base_commit: git(repo, ["rev-parse", "HEAD"]),
      commit: git(repo, ["rev-parse", "HEAD"])
    }

    dispatch = dispatch_candidate(s, t, p)
    # Keep worker private roots separate from already closed artifact dispatch roots.
    {:ok, _} = F.prepare_dispatch(s, a, t, dispatch)
    assert snapshot.owner_generation == a.owner_generation
    t
  end

  defp finish_artifact(s, a, id) do
    prepare_artifact(s, a, id)

    for stage <- [:implemented, :tested, :reviewed, :artifact_verified, :announced],
        do: assert({:ok, ^stage} = F.record_stage(s, a, id, stage, %{fixture: stage}))

    assert {:ok, :done} = F.close(s, a, id)
  end

  test "owner add validates combined graph, preserves authority and traces corrective unit", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")])])
    {:ok, t} = claim(s, "A")
    {:ok, before} = F.unit(s, "A")
    assert {:error, :existing_unit} = F.add_units(s, a, [description("A", [])], :fixture)

    assert {:error, :missing_dependency} =
             F.add_units(s, a, [description("B", [], ["missing"])], :fixture)

    duplicate = %{
      description("B", [])
      | requirement_leaves: before.description.requirement_leaves
    }

    assert {:error, :duplicate_leaf_link} = F.add_units(s, a, [duplicate], :fixture)

    assert {:error, :cycle} =
             F.add_units(
               s,
               a,
               [description("B", [], ["C"]), description("C", [], ["B"])],
               :fixture
             )

    corrective =
      Map.merge(description("B", [], ["A"]), %{
        corrects_unit: "A",
        original_requirement: "PR-fixture-A",
        finding_id: "finding-1"
      })

    assert {:ok, ["B"]} = F.add_units(s, a, [corrective], %{by: "altair", finding: "finding-1"})
    {:ok, after_add} = F.unit(s, "A")
    assert after_add == before
    assert {:ok, ^t} = F.expand(s, t, [])
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")

    assert {:error, :stale_owner} =
             F.add_units(s, %{a | owner_generation: 0}, [description("C", [])], :fixture)
  end

  test "owner reopen refuses busy transitive descendants and preserves prior done history", c do
    s = start(c)
    a = reconcile(s)

    import(s, a, [
      description("A", [], [], :artifact),
      description("B", [], ["A"], :artifact),
      description("C", [], ["B"], :artifact)
    ])

    finish_artifact(s, a, "A")
    {:ok, b} = claim(s, "B")
    assert {:error, :descendant_conflict} = F.reopen(s, a, "A", :finding, :proof)
    {:ok, :released} = F.release(s, b, :quiesce)
    {:ok, reopened} = F.reopen(s, a, "A", :finding, %{review: :fresh})
    assert reopened.claim_generation > 0
    {:ok, u} = F.unit(s, "A")
    refute u.done

    assert Enum.any?(
             u.history,
             &(&1.kind == :reopened and &1.prior_done and
                 &1.prior_stages[:artifact_verified] != nil)
           )

    assert {:error, :missing_stages} = F.close(s, a, "A")
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")
    finish_artifact(s, a, "A")
    finish_artifact(s, a, "B")
    {:ok, ctoken} = claim(s, "C")
    assert {:error, :descendant_conflict} = F.reopen(s, a, "A", :finding, :proof)
    {:ok, :released} = F.release(s, ctoken, :quiesce)
    # Even done descendants require explicit owner policy, never rewind them implicitly.
    assert {:error, :descendant_conflict} = F.reopen(s, a, "A", :finding, :proof)
    assert {:error, :reopen_required} = F.record_stage(s, a, "A", :serious_findings, [:finding])
  end

  test "owner reopen fences worker and reservation without freeing pending integration", c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    d = %{description("A", [scope("new.ex")]) | base_commit: p.base_commit}
    import(s, a, [d, description("B", [scope("new.ex")])])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)
    {:ok, reopened} = F.reopen(s, a, "A", :fresh_finding, %{review: :fresh})
    assert reopened.reservation.integration_generation > r.integration_generation
    assert {:error, :stale} = F.submit(s, t, p)
    assert {:error, :stale_reservation} = F.integration(s, a, r, :accept)
    assert {:error, :conflict} = F.readiness(s, "B")
    {:ok, u} = F.unit(s, "A")
    assert u.proposal.author_token == t
    assert u.proposal.commit == p.commit
  end

  test "owner external resolution requires concrete proof and never erases original blocker", c do
    s = start(c)
    a = reconcile(s)
    blocker = "operator activation"
    d = %{description("A", [], [], :artifact) | external_blockers: [blocker]}
    import(s, a, [d, description("B", [], ["A"])])
    assert {:error, {:not_ready, :external_or_review}} = F.readiness(s, "A")

    assert {:error, :invalid_resolution} =
             F.resolve_external(s, a, "A", %{blocker: blocker, outcome: :unknown})

    resolution = %{
      blocker: blocker,
      outcome: :verified_resolved,
      owner_decision: :resolve,
      verification: %{operator_receipt: :disposable_fixture},
      verified_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:error, :invalid_evidence} =
             F.resolve_external(s, a, "A", %{resolution | verification: nil})

    assert {:error, :unknown_blocker} =
             F.resolve_external(s, a, "A", %{resolution | blocker: "other"})

    assert {:ok, :resolved} = F.resolve_external(s, a, "A", resolution)
    {:ok, u} = F.unit(s, "A")
    assert u.description.external_blockers == [blocker]
    assert hd(u.stages.external_resolutions).by == "altair"
    assert {:ok, :ready} = F.readiness(s, "A")
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")
    finish_artifact(s, a, "A")
    assert {:ok, :ready} = F.readiness(s, "B")
    GenServer.stop(s)
    s2 = start(c)
    a2 = reconcile(s2, 1)
    {:ok, restored} = F.unit(s2, "A")
    assert restored.done
    assert restored.description.external_blockers == [blocker]
    assert restored.stages.external_resolutions == u.stages.external_resolutions
    assert {:error, :already_resolved} = F.resolve_external(s2, a2, "A", resolution)
  end

  test "U03-A5 captured original U01 manual record preserves attribution without fake graph-era claim",
       c do
    fixture_path = "docs/flywheel/u03/bootstrap-u01.json"
    bytes = File.read!(fixture_path)
    {:ok, records} = Nano.Flywheel.Bootstrap.capture([fixture_path])
    [record] = records
    assert record.original_bytes == bytes
    assert record.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert record.record["unit"] == "U01"
    assert record.record["owner"] == "altair-u01-73938543"
    assert record.record["stage"] == "done"
    assert Enum.any?(record.record["history"], &(&1["by"] == "altair"))
    s = start(c)
    a = reconcile(s)

    assert {:ok, ["U01"]} =
             F.import(s, a, %{schema_version: 1, units: [description("U01", [])]}, %{
               bootstrap: records,
               freeze: "original completed U01 exported verbatim"
             })

    {:ok, u} = F.unit(s, "U01")
    assert u.claim == nil
    assert u.claim_generation == 0
    assert u.stages == %{}
    refute u.done
    assert {:error, :degraded} = F.readiness(s, "U01")
    a = reconcile(s, 1)
    assert {:error, :bootstrap_reconciliation} = F.close(s, a, "U01")
    {:ok, snap} = F.snapshot(s)
    assert hd(snap.provenance)["bootstrap"] == Nano.Flywheel.Data.normalize(records)
    assert File.read!(fixture_path) == bytes
  end

  test "U03-A1 hardlink aliases and symlink owner roots cannot evade serialization", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")])])
    {:ok, t} = claim(s, "A")
    File.write!(Path.join(c.repo, "original"), "fixture")
    File.ln!(Path.join(c.repo, "original"), Path.join(c.repo, "hard-alias"))
    assert {:error, :hardlink_scope} = F.expand(s, t, [scope("hard-alias")])
    alias_root = c.root <> "-alias"
    File.ln_s!(c.root, alias_root)

    assert {:error, :alias_root} =
             F.start_link(
               root: alias_root,
               repository: c.repo,
               owner: "altair",
               owner_pid: self()
             )

    assert {:error, {:already_started, ^s}} =
             F.start_link(root: c.root, repository: c.repo, owner: "altair", owner_pid: self())
  end

  test "U03-A2 uncertain post-sync result cannot be overwritten by subsequent DOWN", c do
    {:ok, control} = Agent.start_link(fn -> :normal end)

    writer = fn root, data ->
      :ok = Nano.Flywheel.Store.write(root, data)
      if Agent.get(control, & &1) == :uncertain, do: {:error, :after_persist}, else: :ok
    end

    s = start(c, writer: writer)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")]), description("B", [scope("b")])])
    parent = self()

    worker =
      spawn(fn ->
        send(parent, {:claimed, claim(s, "A")})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, {:ok, _}}
    Agent.update(control, fn _ -> :uncertain end)
    assert {:error, {:persistence, _}} = claim(s, "B")
    {:ok, disk_before} = Nano.Flywheel.Store.read(c.root)
    assert disk_before.units["B"].claim != nil
    send(worker, :stop)
    Process.sleep(30)
    {:ok, disk_after} = Nano.Flywheel.Store.read(c.root)
    assert disk_after == disk_before
    assert {:error, :degraded} = F.readiness(s, "A")
    Agent.update(control, fn _ -> :normal end)
    a2 = reconcile(s, a.owner_generation)
    {:ok, recovered} = F.snapshot(s)
    assert recovered.operations["claim-B-1"] != nil
    assert recovered.owner_generation == a2.owner_generation
    assert recovered.units["A"].claim == nil
    assert recovered.units["B"].claim == nil
  end

  test "owner abandonment after restart requires current authority but not missing Git artifacts",
       c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    d = %{description("A", [scope("new.ex")]) | base_commit: p.base_commit}
    import(s, a, [d, description("B", [scope("new.ex")])])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    {:ok, r} = F.submit(s, t, p)

    {:ok, :external_blockers} =
      F.record_stage(s, a, "A", :external_blockers, ["operator activation"])

    GenServer.stop(s)
    File.rename!(Path.join(c.repo, ".git"), Path.join(c.repo, ".hidden-git"))
    s2 = start(c)
    a2 = reconcile(s2, 1)
    assert {:error, :git_diff_failed} = F.adopt(s2, a2, "A", p.id)
    assert {:error, :stale_owner} = F.abandon(s2, a, "A", p.id, :test)
    assert {:error, :not_reserved} = F.abandon(s2, a2, "A", "wrong", :test)
    assert {:ok, :abandoned} = F.abandon(s2, a2, "A", p.id, %{reason: :proposal_unavailable})
    {:ok, u} = F.unit(s2, "A")
    assert u.reservation == nil
    assert u.stages.external_blockers == ["operator activation"]
    abandoned = Enum.find(u.history, &(&1.kind == :abandoned))
    assert abandoned.proposal.commit == p.commit
    assert abandoned.proposal.author_token == t
    assert abandoned.reservation == r
    assert {:ok, :ready} = F.readiness(s2, "B")
    assert {:error, {:not_ready, :external_or_review}} = F.readiness(s2, "A")
  end

  test "U03-A5 fresh disposable VM restores dynamic evidence atoms and fences old claims", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [scope("a")])])
    {:ok, t} = claim(s, "A")
    name = "evidence_" <> Base.encode16(:crypto.strong_rand_bytes(8))

    event = %{
      id: "fresh-vm-event",
      by: t.claimant,
      kind: :progress,
      marker: String.to_atom(name),
      tokens: nil
    }

    {:ok, _} = F.append(s, t, "A", event)
    {:ok, _} = F.expand(s, t, [scope("expanded", :prefix)])
    File.write!(Path.join(c.root, "unknown-name.txt"), name)
    GenServer.stop(s)

    {out, code} =
      System.cmd(
        "elixir",
        [
          "-pa",
          Path.join(Mix.Project.build_path(), "lib/nano/ebin"),
          "test/flywheel/u03/fresh_vm.exs",
          c.root,
          c.repo
        ],
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "fresh VM restored"
    s2 = start(c)
    {:ok, snap} = F.snapshot(s2)
    assert snap.owner_generation == 2
    assert snap.units["A"].claim.incarnation == "fresh-vm"
    a2 = reconcile(s2, 2)
    assert a2.owner_generation == 3
    assert {:error, :stale} = F.submit(s2, t, %{})
    assert Enum.count(snap.units["A"].history, &(&1.id == "fresh-vm-event")) == 1
  end

  test "pull claim then owner preparation pins evolving base and rejects stale/hash/incarnation dispatch",
       c do
    p = fixture(c)
    s = start(c)
    a = reconcile(s)
    # Immutable design base is historical; exact current integrated base is parent-prepared.
    d = description("A", [scope("new.ex")])
    import(s, a, [d])
    assert {:ok, [%{id: "A", created_at: age}]} = F.ready(s)
    assert is_binary(age)
    {:ok, t} = claim(s, "A")
    assert {:error, :dispatch_required} = F.submit(s, t, p)
    input = dispatch_candidate(s, t, p)
    assert {:error, :stale_owner} = F.prepare_dispatch(s, %{a | owner_generation: 0}, t, input)
    assert {:error, :stale} = F.prepare_dispatch(s, a, %{t | incarnation: "old"}, input)

    assert {:error, :unit_hash_mismatch} =
             F.prepare_dispatch(s, a, t, %{input | unit_sha256: String.duplicate("0", 64)})

    assert {:error, :worktree_base_mismatch} =
             F.prepare_dispatch(s, a, t, %{input | base_commit: p.commit})

    {:ok, dispatch1} = F.prepare_dispatch(s, a, t, input)
    assert dispatch1.claim_token == t
    assert dispatch1.base_commit == p.base_commit
    assert dispatch1.generation == 1
    {:ok, u} = F.unit(s, "A")
    assert u.description.base_commit == d.base_commit
    assert u.dispatch.resolved_unit_bytes == File.read!(input.unit_path)

    old_proposal =
      Map.merge(p, %{
        dispatch_generation: dispatch1.generation,
        unit_sha256: dispatch1.unit_sha256
      })

    assert {:error, :resolved_unit_mismatch} = F.prepare_dispatch(s, a, t, input)
    input2 = dispatch_candidate(s, t, p)
    {:ok, dispatch2} = F.prepare_dispatch(s, a, t, input2)
    assert dispatch2.generation == 2
    refute dispatch2.unit_sha256 == dispatch1.unit_sha256
    git(p.worktree, ["reset", "--hard", p.commit])
    assert {:error, :stale_dispatch} = F.submit(s, t, old_proposal)

    current =
      Map.merge(p, %{
        dispatch_generation: dispatch2.generation,
        unit_sha256: dispatch2.unit_sha256
      })

    assert {:error, :incompatible_base} = F.submit(s, t, %{current | base_commit: d.base_commit})
    {:ok, r} = F.submit(s, t, current)
    assert {:error, :reserved} = F.prepare_dispatch(s, a, t, input2)
    assert {:ok, :accepted} = accept_fixture(s, a, r, p)
    {:ok, u2} = F.unit(s, "A")
    assert Enum.count(u2.history, &(&1.kind == :prepared_dispatch)) == 2
  end

  test "caller information remains inert and durable claims contain no pid", c do
    s = start(c)
    a = reconcile(s)
    d = Map.put(description("A", []), :extra_atom_key, %{dynamic_value: :caller_atom})
    import(s, a, [d])
    {:ok, t} = claim(s, "A")

    assert {:error, :invalid_evidence} =
             F.append(s, t, "A", %{id: "bad", by: t.claimant, payload: fn -> :executed end})

    assert {:error, :invalid_evidence} =
             F.append(s, t, "A", %{id: "bad-pid", by: t.claimant, payload: self()})

    assert {:error, :invalid_evidence} =
             F.append(s, t, "A", %{
               id: "colliding",
               by: t.claimant,
               payload: %{"atom" => 2, atom: 1}
             })

    event = %{
      id: "inert",
      by: t.claimant,
      kind: :progress,
      payload: %{nested: :caller_atom},
      tokens: nil
    }

    assert {:ok, "inert"} = F.append(s, t, "A", event)
    {:ok, disk} = Nano.Flywheel.Store.read(c.root)
    refute Map.has_key?(disk.units["A"].claim, :pid)
    assert disk.units["A"].description["extra_atom_key"] == %{"dynamic_value" => "caller_atom"}
    observed = Enum.find(disk.units["A"].history, &(&1.id == "inert"))
    assert observed.kind == "progress"
    assert observed["payload"] == %{"nested" => "caller_atom"}
    GenServer.stop(s)
    s2 = start(c)
    reconcile(s2, 1)
    {:ok, snap} = F.snapshot(s2)
    assert snap.units["A"].claim == nil
  end

  test "U03-A5 original completed bootstrap reconciles staged code evidence without graph-era claims",
       c do
    {:ok, [record]} = Nano.Flywheel.Bootstrap.capture(["docs/flywheel/u03/bootstrap-u01.json"])

    {:ok, s} =
      F.start_link(root: c.root, repository: File.cwd!(), owner: "altair", owner_pid: self())

    Process.unlink(s)
    on_exit(fn -> if Process.alive?(s), do: GenServer.stop(s) end)
    a = reconcile(s)
    d = %{description("U01", []) | base_commit: record.record["base"]}

    assert {:ok, _} =
             F.import(s, a, %{schema_version: 1, units: [d, description("D", [], ["U01"])]}, %{
               bootstrap: [record],
               freeze: "completed original U01 exported"
             })

    assert {:error, :degraded} = F.readiness(s, "U01")
    a = reconcile(s, 1)
    assert {:error, {:not_ready, :bootstrap_reconciliation}} = F.readiness(s, "U01")
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "D")
    commit = "45d527c0819bbd43dd579781e3b5a154184c4ead"

    stages =
      Map.new(
        [:implemented, :tested, :reviewed, :deployed, :live_verified, :announced],
        &{&1, %{fixture_evidence: Atom.to_string(&1)}}
      )

    stages =
      Map.put(stages, :integrated, %{
        commit: commit,
        evidence: %{fixture: "original real commit existence/ancestry"}
      })

    assert {:error, :bootstrap_provenance_mismatch} =
             F.reconcile_bootstrap(s, a, "U01", String.duplicate("0", 64), stages)

    assert {:error, :missing_stages} =
             F.reconcile_bootstrap(s, a, "U01", record.sha256, Map.delete(stages, :live_verified))

    assert {:ok, :reconciled} = F.reconcile_bootstrap(s, a, "U01", record.sha256, stages)
    assert {:ok, :reconciled} = F.reconcile_bootstrap(s, a, "U01", record.sha256, stages)
    {:ok, u} = F.unit(s, "U01")
    assert u.claim == nil
    assert u.claim_generation == 0
    assert u.integration_generation == 0
    assert u.proposal == nil
    assert u.reservation == nil
    refute u.done
    assert u.bootstrap_reconciled.original_author == record.record["owner"]
    assert u.bootstrap_reconciled.original_generation == record.record["generation"]
    assert u.bootstrap_reconciled.owner_generation == 2
    assert u.stages.integrated.commit == commit
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "D")
    assert {:ok, :done} = F.close(s, a, "U01")
    assert {:ok, :ready} = F.readiness(s, "D")
    GenServer.stop(s)

    {:ok, s2} =
      F.start_link(root: c.root, repository: File.cwd!(), owner: "altair", owner_pid: self())

    Process.unlink(s2)
    on_exit(fn -> if Process.alive?(s2), do: GenServer.stop(s2) end)
    a2 = reconcile(s2, 2)
    {:ok, restored} = F.unit(s2, "U01")
    assert restored.done
    assert restored.bootstrap_reconciled == u.bootstrap_reconciled
    assert {:ok, :reconciled} = F.reconcile_bootstrap(s2, a2, "U01", record.sha256, stages)
    assert Enum.count(restored.history, &(&1.kind == :bootstrap_reconciled)) == 1
  end

  test "ready ordering is safety then longest unblock path then stable ID with visible age", c do
    s = start(c)
    a = reconcile(s)

    units = [
      description("B", []),
      description("A", []),
      description("C", [], ["A"]),
      description("D", [], ["C"]),
      description("F", []),
      %{description("E", []) | priority: 0}
    ]

    import(s, a, units)
    {:ok, rows} = F.ready(s)
    assert Enum.map(rows, & &1.id) == ["E", "A", "B", "F"]
    assert Enum.find(rows, &(&1.id == "A")).path_length == 3
    assert Enum.all?(rows, &is_binary(&1.created_at))
  end

  test "separate worker worktree symlinks are rejected again at actual proposal boundary", c do
    p = fixture(c)
    design_repo = Path.join(Path.dirname(c.repo), "design-repository")
    git(Path.dirname(c.repo), ["clone", "-q", c.repo, design_repo])
    git(design_repo, ["reset", "--hard", p.base_commit])

    {:ok, s} =
      F.start_link(
        root: c.root,
        repository: design_repo,
        owner: "altair",
        owner_pid: self(),
        claimant_resolver: fn _, pid -> pid end
      )

    Process.unlink(s)
    on_exit(fn -> if Process.alive?(s), do: GenServer.stop(s) end)
    a = reconcile(s)
    import(s, a, [%{description("A", [scope("new.ex")]) | base_commit: p.base_commit}])
    {:ok, t} = claim(s, "A")
    p = prepared_proposal(s, a, t, p)
    File.rm!(Path.join(p.worktree, "new.ex"))
    File.ln_s!("base", Path.join(p.worktree, "new.ex"))
    # Committed diff is still p.commit; canonical actual worktree aliases cannot evade the claim.
    assert {:error, :symlink_scope} = F.submit(s, t, p)
    File.rm!(Path.join(p.worktree, "new.ex"))
    git(p.worktree, ["reset", "--hard", p.commit])
    {:ok, r} = F.submit(s, t, p)
    assert {:ok, :accepted} = F.integration(s, a, r, :accept)
    git(design_repo, ["reset", "--hard", p.commit])
    File.rm!(Path.join(p.worktree, "new.ex"))
    File.ln_s!("base", Path.join(p.worktree, "new.ex"))
    assert {:error, :symlink_scope} = F.integration(s, a, r, {:land, p.commit, :proof})
  end

  test "restored malformed authority does not reopen or overwrite persisted snapshot", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [])])
    {:ok, _} = claim(s, "A")
    GenServer.stop(s)
    {:ok, stored} = Nano.Flywheel.Store.read(c.root)
    bad = put_in(stored, [:units, "A", :claim, :claim_generation], 999)
    bytes = :erlang.term_to_binary(bad)
    File.write!(Path.join(c.root, "state.term"), bytes)

    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, :corrupt_state} =
               F.start_link(root: c.root, repository: c.repo, owner: "altair", owner_pid: self())
    after
      Process.flag(:trap_exit, previous)
    end

    assert File.read!(Path.join(c.root, "state.term")) == bytes
  end

  test "U03-A1 future exact parent path cannot evade child-prefix ownership", c do
    s = start(c)
    a = reconcile(s)

    import(s, a, [
      description("A", [scope("future-parent")]),
      description("B", [scope("future-parent/child", :prefix)])
    ])

    {:ok, _} = claim(s, "A")
    assert {:error, :conflict} = claim(s, "B")
    refute Nano.Flywheel.Scopes.covers?([scope("future-parent")], "future-parent/child/new")
  end

  test "U03-A4 empty or false stage proof never permits artifact completion", c do
    s = start(c)
    a = reconcile(s)
    import(s, a, [description("A", [], [], :artifact), description("B", [], ["A"])])

    for ev <- [false, [], %{}, nil, ""],
        stage <- [:implemented, :tested, :reviewed, :artifact_verified, :announced] do
      assert {:error, :invalid_evidence} = F.record_stage(s, a, "A", stage, ev)
    end

    assert {:error, :missing_stages} = F.close(s, a, "A")
    assert {:error, {:not_ready, :dependencies}} = F.readiness(s, "B")
    assert {:ok, :external_blockers} = F.record_stage(s, a, "A", :external_blockers, [])
    finish_artifact(s, a, "A")
  end
end
