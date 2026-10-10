defmodule Nano.Flywheel do
  @moduledoc """
  Serialized version-1 durable work graph. See `docs/flywheel/u03/api.md`.
  Start explicitly with root/repository/owner; application startup does not create
  authority. Restart is read-only until owner reconciliation advances generation.
  All mutations persist before success; failures quarantine claims. Worker death
  fences worker authority but preserves submitted integration reservations.
  Claims are cooperation, not a sandbox or exactly-once arbitrary effects.
  """
  use GenServer
  alias Nano.Flywheel.{Data, Scopes, Store}

  def start_link(opts) do
    root = Path.expand(Keyword.fetch!(opts, :root))

    with :ok <- Scopes.safe_root(root),
         :ok <- Scopes.safe_root(Keyword.fetch!(opts, :repository)) do
      GenServer.start_link(__MODULE__, Keyword.put(opts, :root, root),
        name: {:global, {__MODULE__, root}}
      )
    end
  end

  def snapshot(server), do: GenServer.call(server, :snapshot)
  def unit(server, id), do: GenServer.call(server, {:unit, id})
  def readiness(server, id), do: GenServer.call(server, {:readiness, id})
  def ready(server), do: GenServer.call(server, :ready)

  def import(server, authority, description, provenance),
    do: call(server, {:import, authority, description, provenance})

  def reconcile(server, authority, evidence), do: call(server, {:reconcile, authority, evidence})

  def claim(server, id, name, incarnation, generation, operation_id),
    do: call(server, {:claim, id, name, incarnation, generation, operation_id})

  def expand(server, token, scopes), do: call(server, {:expand, token, scopes})
  def append(server, authority, id, event), do: call(server, {:append, authority, id, event})
  def submit(server, token, proposal), do: call(server, {:submit, token, proposal})
  def release(server, token, reason), do: call(server, {:release, token, reason})

  def adopt(server, authority, id, proposal_id),
    do: call(server, {:adopt, authority, id, proposal_id})

  def integration(server, authority, reservation, action),
    do: call(server, {:integration, authority, reservation, action})

  def record_stage(server, authority, id, stage, evidence),
    do: call(server, {:stage, authority, id, stage, evidence})

  def close(server, authority, id), do: call(server, {:close, authority, id})

  def add_units(server, authority, units, provenance),
    do: call(server, {:add_units, authority, units, provenance})

  def reopen(server, authority, id, reason, evidence),
    do: call(server, {:reopen, authority, id, reason, evidence})

  def resolve_external(server, authority, id, resolution),
    do: call(server, {:resolve_external, authority, id, resolution})

  def abandon(server, authority, id, proposal_id, reason),
    do: call(server, {:abandon, authority, id, proposal_id, reason})

  def prepare_dispatch(server, authority, token, dispatch),
    do: call(server, {:prepare_dispatch, authority, token, dispatch})

  def reconcile_bootstrap(server, authority, id, record_sha256, stages),
    do: call(server, {:reconcile_bootstrap, authority, id, record_sha256, stages})

  defp call(s, req), do: GenServer.call(s, req, 30_000)

  @impl true
  def init(opts) do
    case Store.read(opts[:root]) do
      {:ok, saved} ->
        data =
          saved ||
            %{
              schema_version: 1,
              owner: opts[:owner] || "altair",
              owner_generation: 0,
              units: %{},
              history: [],
              provenance: [],
              revision: 0,
              operations: %{}
            }

        if restored_valid?(data, Keyword.fetch!(opts, :repository)) do
          {:ok,
           %{
             data: data,
             root: opts[:root],
             repository: Path.expand(Keyword.fetch!(opts, :repository)),
             owner_pid: opts[:owner_pid],
             claimant_resolver:
               opts[:claimant_resolver] || fn name, _ -> NanoAgent.whereis(name) end,
             writer: opts[:writer] || (&Store.write/2),
             after_persist: opts[:after_persist],
             mode: :reconciliation_required,
             monitors: %{},
             owner_monitor: monitor_owner(opts[:owner_pid] || NanoAgent.whereis(data.owner)),
             owner_observed: opts[:owner_pid] || NanoAgent.whereis(data.owner)
           }}
        else
          {:stop, :corrupt_state}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _, s), do: {:reply, {:ok, Map.put(s.data, :mode, s.mode)}, s}
  def handle_call({:unit, id}, _, s), do: {:reply, fetch(s.data, id), s}
  def handle_call({:readiness, id}, _, s), do: {:reply, readiness_result(s, id), s}

  def handle_call(:ready, _, s) do
    rows =
      for {id, u} <- s.data.units,
          readiness_result(s, id) == {:ok, :ready},
          do: %{
            id: id,
            priority: u.description.priority,
            path_length: depth(s.data, id),
            created_at: u.created_at
          }

    rows = Enum.sort_by(rows, &{&1.priority, -&1.path_length, &1.id})
    {:reply, {:ok, rows}, s}
  end

  def handle_call(req, {pid, _}, s) do
    result =
      try do
        transition(req, pid, s)
      rescue
        _ -> {:error, :invalid_request}
      catch
        :restart_required -> {:error, :restart_required}
        :corrupt_state -> {:error, :corrupt_state}
        :git_diff_failed -> {:error, :git_diff_failed}
        :invalid_evidence -> {:error, :invalid_evidence}
      end

    case result do
      {:ok, data, reply, mode} ->
        data = %{data | revision: max(data.revision, s.data.revision) + 1}
        data = record_transition(req, data)

        case persist(s, data) do
          :ok ->
            if s.after_persist, do: s.after_persist.(req)
            s = %{s | data: data, mode: mode} |> monitor_claims()

            s =
              if s.owner_monitor == nil or elem(req, 0) == :reconcile do
                if s.owner_monitor, do: Process.demonitor(s.owner_monitor, [:flush])
                observed = s.owner_pid || NanoAgent.whereis(s.data.owner)
                %{s | owner_monitor: monitor_owner(observed), owner_observed: observed}
              else
                s
              end

            {:reply, {:ok, reply}, s}

          error ->
            {:reply, {:error, {:persistence, error}}, %{s | mode: :degraded}}
        end

      {:replay, reply} ->
        {:reply, {:ok, reply}, s}

      {:error, :corrupt_state} = e ->
        {:reply, e, %{s | mode: :degraded}}

      {:error, _} = e ->
        {:reply, e, s}
    end
  end

  defp restored_valid?(d, repo) do
    candidate = %{schema_version: 1, units: Enum.map(d.units, fn {_, u} -> u.description end)}
    descriptions_ok = map_size(d.units) == 0 or match?({:ok, _}, validate(candidate, repo))

    descriptions_ok and
      Enum.all?(d.units, fn {id, u} ->
        is_boolean(u[:accepted]) and is_integer(u[:dispatch_generation]) and
          u.dispatch_generation >= 0 and
          match?({:ok, _}, Scopes.normalize(u.scopes, repo)) and
          (u.claim == nil or
             (valid_token?(u.claim, d, id) and u.claim.claim_generation == u.claim_generation)) and
          (u.dispatch == nil or
             (is_map(u.dispatch) and u.dispatch.generation == u.dispatch_generation and
                valid_token?(u.dispatch.claim_token, d, id))) and
          (u.reservation == nil or
             (is_map(u.proposal) and u.reservation.unit == id and
                u.reservation.proposal_id == u.proposal.id and u.reservation.owner == d.owner and
                u.reservation.owner_generation <= d.owner_generation and
                u.reservation.integration_generation == u.integration_generation and
                u.dispatch != nil and
                u.proposal[:dispatch_generation] == u.dispatch.generation and
                u.proposal[:unit_sha256] == u.dispatch.unit_sha256 and
                valid_token?(u.proposal.author_token, d, id))) and
          (not u.done or
             (u.claim == nil and u.reservation == nil and done_gate(u) == :ok and
                Enum.all?(u.description.dependencies, &d.units[&1].done)))
      end) and
      Enum.all?(d.operations, fn {op, record} ->
        is_binary(op) and op != "" and is_map(record) and
          valid_token?(record.token, d, record.token.unit) and
          record.request == {record.token.unit, record.token.claimant, record.token.incarnation}
      end)
  rescue
    _ -> false
  end

  defp valid_token?(t, d, id) do
    is_map(t) and Map.has_key?(d.units, id) and t[:unit] == id and
      is_binary(t[:claimant]) and t.claimant != "" and is_binary(t[:incarnation]) and
      t.incarnation != "" and
      is_integer(t[:owner_generation]) and t.owner_generation <= d.owner_generation and
      t.owner_generation > 0 and
      is_integer(t[:claim_generation]) and t.claim_generation > 0 and
      t.claim_generation <= d.units[id].claim_generation and
      not Map.has_key?(t, :pid)
  end

  defp monitor_owner(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_owner(_), do: nil

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = s) do
    {:noreply, %{s | mode: :reconciliation_required, owner_monitor: nil, owner_observed: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{mode: mode} = s)
      when mode != :active do
    # Never overwrite a possibly newer disk generation after an uncertain write.
    {:noreply, %{s | monitors: Map.delete(s.monitors, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) do
    case Map.pop(s.monitors, ref) do
      {nil, _} ->
        {:noreply, s}

      {{id, generation}, monitors} ->
        s = %{s | monitors: monitors}

        case fetch(s.data, id) do
          {:ok, %{claim: %{claim_generation: ^generation}} = u} ->
            data = put_unit(s.data, id, interrupt(u, {:death, reason}))
            data = %{data | revision: s.data.revision + 1}

            case persist(s, data) do
              :ok -> {:noreply, %{s | data: data}}
              _ -> {:noreply, %{s | mode: :degraded}}
            end

          _ ->
            {:noreply, s}
        end
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp transition({:reconcile, a, evidence}, pid, s) do
    evidence = Data.normalize(evidence)

    with :ok <- owner(s, a, pid), :ok <- evidence(evidence) do
      # Read disk again after uncertain persistence, never roll back newer authority.
      with {:ok, saved} <- Store.read(s.root) do
        d = saved || s.data
        if not restored_valid?(d, s.repository), do: throw(:corrupt_state)
        if d.owner_generation != a.owner_generation, do: throw(:restart_required)

        units =
          Map.new(d.units, fn {id, u} ->
            {id, if(u.claim, do: interrupt(u, :owner_restart), else: u)}
          end)

        d = %{d | units: units, owner_generation: d.owner_generation + 1}

        d =
          history(d, %{
            id: "reconcile-#{d.owner_generation}",
            by: d.owner,
            kind: :reconcile,
            evidence: evidence
          })

        {:ok, d, %{owner: d.owner, owner_generation: d.owner_generation}, :active}
      end
    end
  end

  defp transition({:import, a, description, provenance}, pid, s) do
    provenance = Data.normalize(provenance)

    with :ok <- owner(s, a, pid),
         :ok <- active(s),
         true <- map_size(s.data.units) == 0 || {:error, :already_imported},
         {:ok, units} <- validate(description, s.repository),
         :ok <- evidence(provenance) do
      records = if is_map(provenance), do: provenance["bootstrap"] || [], else: []
      if not is_list(records), do: throw(:invalid_evidence)
      ids = Enum.map(records, & &1["record"]["unit"])
      if Enum.any?(ids, &(not Map.has_key?(units, &1))), do: throw(:invalid_evidence)
      units = Map.new(units, fn {id, u} -> {id, Map.put(u, :bootstrap_pending, id in ids)} end)
      d = %{s.data | units: units, provenance: [provenance]}
      d = history(d, %{id: "import", by: s.data.owner, kind: :import, provenance: provenance})
      {:ok, d, Map.keys(units), if(records == [], do: :active, else: :reconciliation_required)}
    end
  end

  defp transition({:add_units, a, list, provenance}, pid, s) do
    provenance = Data.normalize(provenance)

    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         :ok <- evidence(provenance),
         true <- (is_list(list) and list != []) || {:error, :invalid_units},
         true <-
           Enum.all?(list, fn d -> is_map(d) and not Map.has_key?(s.data.units, d[:id]) end) ||
             {:error, :existing_unit},
         descriptions = Enum.map(s.data.units, fn {_, u} -> u.description end),
         {:ok, combined} <-
           validate(%{schema_version: 1, units: descriptions ++ list}, s.repository) do
      added = Map.take(combined, Enum.map(list, & &1.id))

      d = %{
        s.data
        | units: Map.merge(s.data.units, added),
          provenance: s.data.provenance ++ [provenance]
      }

      {:ok, d, Map.keys(added), :active}
    end
  end

  defp transition({:reopen, a, id, reason, ev}, pid, s) do
    reason = Data.normalize(reason)
    ev = Data.normalize(ev)

    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         :ok <- evidence(reason),
         :ok <- evidence(ev),
         true <- not descendants_busy?(s.data, id) || {:error, :descendant_conflict} do
      u =
        unit_history(u, %{
          id: "reopen-#{s.data.revision}",
          kind: :reopened,
          by: a.owner,
          reason: reason,
          evidence: ev,
          prior_done: u.done,
          prior_stages: u.stages,
          prior_proposal: u.proposal,
          prior_dispatch: u.dispatch,
          prior_attempt: u[:attempt],
          at: now()
        })

      u = interrupt(u, :owner_reopen)

      r =
        if u.reservation,
          do: %{u.reservation | integration_generation: u.integration_generation + 1},
          else: nil

      stages = Map.take(u.stages, [:external_blockers, :external_resolutions, :serious_findings])

      u = %{
        u
        | done: false,
          stages: stages,
          accepted: false,
          reservation: r,
          integration_generation: u.integration_generation + 1
      }

      u = if r == nil, do: clear_attempt(u, :reopened, a.owner), else: u

      {:ok, put_unit(s.data, id, u),
       %{unit: id, claim_generation: u.claim_generation, reservation: r}, :active}
    end
  end

  defp transition({:resolve_external, a, id, resolution}, pid, s) do
    raw = resolution

    resolution =
      Data.fields(raw, [:blocker, :outcome, :verification, :owner_decision, :verified_at])

    resolution =
      Map.merge(resolution, %{outcome: raw[:outcome], owner_decision: raw[:owner_decision]})

    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         :ok <- valid_resolution(u, resolution) do
      resolutions = u.stages[:external_resolutions] || []

      case Enum.find(resolutions, &(&1.blocker == resolution.blocker)) do
        nil ->
          resolution = Map.put(resolution, :by, a.owner)
          u = %{u | stages: Map.put(u.stages, :external_resolutions, resolutions ++ [resolution])}
          {:ok, put_unit(s.data, id, u), :resolved, :active}

        _ ->
          {:error, :already_resolved}
      end
    end
  end

  defp transition({:prepare_dispatch, a, token, dispatch}, pid, s) do
    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- worker(s, token),
         true <- (u.reservation == nil and u.proposal == nil) || {:error, :reserved},
         true <-
           (not blockers(u) and Enum.all?(u.description.dependencies, &s.data.units[&1].done)) ||
             {:error, {:not_ready, :dependencies_or_blockers}},
         {:ok, dispatch} <- valid_dispatch(s, token, dispatch),
         :ok <- dispatch_isolated(s.data, token.unit, dispatch) do
      dispatch =
        Map.merge(dispatch, %{
          claim_token: token,
          generation: u.dispatch_generation + 1,
          prepared_by: a.owner
        })

      u =
        unit_history(u, %{
          id: "dispatch-#{dispatch.generation}",
          kind: :prepared_dispatch,
          by: a.owner,
          dispatch: dispatch,
          at: now()
        })

      u = %{u | dispatch: dispatch, dispatch_generation: dispatch.generation}

      u =
        Map.put(u, :attempt, %{
          claim_token: dispatch.claim_token,
          dispatch_generation: dispatch.generation,
          unit_sha256: dispatch.unit_sha256
        })

      {:ok, put_unit(s.data, token.unit, u), dispatch, :active}
    end
  end

  defp transition({:reconcile_bootstrap, a, id, sha, stages}, pid, s) do
    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         {:ok, record} <- original_bootstrap(s.data, id, sha),
         {:ok, stages} <- bootstrap_stages(u, stages) do
      case u[:bootstrap_reconciled] do
        %{record_sha256: ^sha, stages: ^stages} ->
          {:replay, :reconciled}

        nil ->
          with true <-
                 (u.claim == nil and u.proposal == nil and u.reservation == nil and
                    u.claim_generation == 0 and u.integration_generation == 0) ||
                   {:error, :graph_authority_exists},
               :ok <- bootstrap_commit(s.repository, record, stages) do
            reconciliation = %{
              record_sha256: sha,
              original_author: record["record"]["owner"],
              original_generation: record["record"]["generation"],
              by: a.owner,
              owner_generation: a.owner_generation,
              stages: stages
            }

            u =
              %{u | stages: Map.merge(u.stages, stages)}
              |> Map.put(:bootstrap_reconciled, reconciliation)
              |> Map.put(:bootstrap_pending, false)

            u =
              unit_history(u, %{
                id: "bootstrap-reconcile-#{sha}",
                kind: :bootstrap_reconciled,
                by: a.owner,
                provenance: reconciliation,
                at: now()
              })

            {:ok, put_unit(s.data, id, u), :reconciled, :active}
          end

        _ ->
          {:error, :already_reconciled}
      end
    end
  end

  defp transition({:claim, id, name, incarnation, generation, op}, pid, s) do
    with :ok <- active(s),
         true <- generation == s.data.owner_generation || {:error, :stale},
         true <-
           (is_binary(name) and name != "" and is_binary(incarnation) and incarnation != "" and
              is_binary(op) and op != "") || {:error, :invalid_claim} do
      case Map.get(s.data.operations, op) do
        %{request: {^id, ^name, ^incarnation}, token: token} ->
          with {:ok, _} <- worker(s, token), do: {:replay, token}

        nil ->
          with {:ok, :ready} <- readiness_result(s, id),
               {:ok, u} <- fetch(s.data, id),
               {:ok, _} <- Scopes.normalize(u.scopes, s.repository),
               claimant_pid = s.claimant_resolver.(name, pid),
               true <-
                 (is_pid(claimant_pid) and Process.alive?(claimant_pid) and
                    caller_matches?(pid, claimant_pid)) ||
                   {:error, :claimant_unavailable} do
            token = %{
              unit: id,
              claimant: name,
              incarnation: incarnation,
              owner_generation: generation,
              claim_generation: u.claim_generation + 1
            }

            u = clear_attempt(u, :fresh_claim, name)

            u = %{
              u
              | claim: Map.put(token, :pid, claimant_pid),
                claim_generation: token.claim_generation
            }

            d =
              put_unit(
                s.data,
                id,
                unit_history(u, %{id: op, by: name, kind: :claim, token: token})
              )

            d = %{
              d
              | operations:
                  Map.put(d.operations, op, %{request: {id, name, incarnation}, token: token})
            }

            {:ok, d, token, :active}
          end

        _ ->
          {:error, :operation_conflict}
      end
    end
  end

  defp transition({:expand, token, scopes}, _, s) do
    with :ok <- active(s),
         {:ok, u} <- worker(s, token),
         {:ok, scopes} <- Scopes.normalize(scopes, s.repository),
         :ok <- worker_worktree_scopes(u, token, scopes),
         :ok <- no_conflict(s.data, token.unit, scopes) do
      u = %{u | scopes: Enum.uniq(u.scopes ++ scopes)}
      {:ok, put_unit(s.data, token.unit, u), token, :active}
    end
  end

  defp transition({:append, authority, id, event}, pid, s) do
    event = Data.fields(event, [:id, :by, :tokens, :wall_time_ms, :kind])

    with :ok <- active(s),
         {:ok, u} <- fetch(s.data, id),
         :ok <- author(s, authority, id, pid),
         :ok <- valid_event(event, authority) do
      case Enum.find(u.history, &(&1.id == event.id)) do
        ^event -> {:replay, event.id}
        nil -> {:ok, put_unit(s.data, id, unit_history(u, event)), event.id, :active}
        _ -> {:error, :event_conflict}
      end
    end
  end

  defp transition({:submit, token, proposal}, _, s) do
    proposal =
      Data.fields(proposal, [
        :id,
        :base_commit,
        :commit,
        :worktree,
        :changed_files,
        :evidence,
        :dispatch_generation,
        :unit_sha256
      ])

    with :ok <- active(s),
         {:ok, u} <- worker(s, token),
         true <- u.reservation == nil || {:error, :reserved},
         :ok <- proposal(s, u, proposal) do
      r = %{
        unit: token.unit,
        proposal_id: proposal.id,
        integration_generation: u.integration_generation + 1,
        owner_generation: s.data.owner_generation,
        owner: s.data.owner
      }

      u = %{
        u
        | proposal: Map.put(proposal, :author_token, token),
          reservation: r,
          integration_generation: r.integration_generation
      }

      {:ok, put_unit(s.data, token.unit, u), r, :active}
    end
  end

  defp transition({:release, token, reason}, _, s) do
    with :ok <- active(s), {:ok, u} <- worker(s, token), :ok <- evidence(reason) do
      {:ok, put_unit(s.data, token.unit, interrupt(u, reason)), :released, :active}
    end
  end

  defp transition({:adopt, a, id, proposal_id}, pid, s) do
    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         true <-
           (u.reservation != nil and u.proposal.id == proposal_id) || {:error, :not_reserved},
         :ok <- proposal(s, u, u.proposal) do
      r = %{
        u.reservation
        | integration_generation: u.integration_generation + 1,
          owner_generation: s.data.owner_generation
      }

      u = interrupt(u, :adopted)

      u =
        %{u | reservation: r, integration_generation: r.integration_generation, accepted: false}
        |> Map.put(:acceptance, nil)

      {:ok, put_unit(s.data, id, u), r, :active}
    end
  end

  defp transition({:integration, a, r, action}, pid, s) do
    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- reservation(s, r),
         :ok <- integration_diff(s, u, action) do
      case action do
        :accept ->
          with true <- u.stages[:integrated] == nil || {:error, :already_integrated},
               true <- not u.accepted || {:error, :already_accepted},
               {:ok, pin} <- acceptance_pin(s),
               {:ok, _} <-
                 git_read(s.repository, [
                   "merge-base",
                   "--is-ancestor",
                   u.proposal.base_commit,
                   pin.base_commit
                 ]),
               {:ok, original} <-
                 git_read(s.repository, ["rev-parse", u.proposal.commit <> "^{commit}"]),
               true <- original == u.proposal.commit || {:error, :invalid_commit} do
            u = %{u | accepted: true} |> Map.put(:acceptance, pin)

            u =
              unit_history(u, %{
                id: "accept-#{r.integration_generation}",
                kind: :integration_accept,
                by: a.owner,
                at: now(),
                pin: pin,
                tokens: nil,
                wall_time_ms: nil
              })

            data = put_unit(s.data, r.unit, u)

            {:ok, data, :accepted, :active}
          end

        {:land, commit, ev} ->
          with true <- u.accepted || {:error, :not_accepted},
               :ok <- hash(commit),
               :ok <- evidence(ev),
               :ok <- landed_candidate(s, u, commit) do
            ev = Data.normalize(ev)

            u =
              if u.stages[:integrated] != nil and u.stages.integrated.commit != commit,
                do: invalidate_deployment(u),
                else: u

            u = %{u | stages: Map.put(u.stages, :integrated, %{commit: commit, evidence: ev})}

            u =
              Map.put(
                u,
                :stage_bindings,
                Map.put(u[:stage_bindings] || %{}, :integrated, stage_binding(u, :integrated))
              )

            {:ok, put_unit(s.data, r.unit, u), :integrated, :active}
          end

        {:abandon, reason} ->
          with :ok <- evidence(reason) do
            u = abandon_unit(u, a, reason)
            {:ok, put_unit(s.data, r.unit, u), :abandoned, :active}
          end

        _ ->
          {:error, :invalid_action}
      end
    end
  end

  defp transition({:abandon, a, id, proposal_id, reason}, pid, s) do
    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         true <-
           (u.reservation != nil and u.proposal.id == proposal_id) || {:error, :not_reserved},
         :ok <- evidence(reason) do
      u = abandon_unit(u, a, reason)
      {:ok, put_unit(s.data, id, u), :abandoned, :active}
    end
  end

  defp transition({:stage, a, id, stage, ev}, pid, s) do
    ev = Data.normalize(ev)

    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         true <- not u.done || {:error, :reopen_required},
         true <-
           (stage not in [:external_blockers, :serious_findings] or is_list(ev)) ||
             {:error, :invalid_evidence},
         true <-
           stage in [
             :implemented,
             :tested,
             :reviewed,
             :deployed,
             :live_verified,
             :announced,
             :artifact_verified,
             :external_blockers,
             :serious_findings
           ] || {:error, :invalid_stage},
         :ok <-
           if(stage in [:external_blockers, :serious_findings] and ev == [],
             do: :ok,
             else: evidence(ev)
           ),
         :ok <- proof_attempt(u, stage) do
      ev =
        if stage == :external_blockers,
          do: Enum.uniq((u.stages[:external_blockers] || []) ++ ev),
          else: ev

      u = %{u | stages: Map.put(u.stages, stage, ev)}

      u =
        if stage in [:external_blockers, :serious_findings],
          do: u,
          else:
            Map.put(
              u,
              :stage_bindings,
              Map.put(u[:stage_bindings] || %{}, stage, stage_binding(u, stage))
            )

      {:ok,
       put_unit(
         s.data,
         id,
         unit_history(u, %{
           id: "stage-#{stage}-#{s.data.revision}",
           by: a.owner,
           kind: :stage,
           stage: stage,
           evidence: ev
         })
       ), stage, :active}
    end
  end

  defp transition({:close, a, id}, pid, s) do
    with :ok <- active(s),
         :ok <- owner(s, a, pid),
         {:ok, u} <- fetch(s.data, id),
         :ok <- done_gate(u),
         true <-
           Enum.all?(u.description.dependencies, &s.data.units[&1].done) ||
             {:error, :dependencies_not_done} do
      u = interrupt(u, :closed)
      u = %{u | done: true, reservation: nil}
      {:ok, put_unit(s.data, id, u), :done, :active}
    end
  end

  defp transition(_, _, _), do: {:error, :invalid_request}

  defp integration_diff(_, _, {:abandon, _}), do: :ok
  defp integration_diff(s, u, _), do: proposal(s, u, u.proposal)

  defp abandon_unit(u, a, reason) do
    reason = Data.normalize(reason)

    u =
      unit_history(u, %{
        id: "abandon-#{u.integration_generation + 1}",
        kind: :abandoned,
        by: a.owner,
        reason: reason,
        proposal: u.proposal,
        reservation: u.reservation,
        prior_stages: u.stages,
        at: now()
      })

    u = interrupt(u, {:abandoned, reason})

    %{
      u
      | reservation: nil,
        proposal: nil,
        accepted: false,
        integration_generation: u.integration_generation + 1,
        stages: Map.take(u.stages, [:external_blockers, :external_resolutions, :serious_findings])
    }
  end

  defp active(%{mode: :active, owner_observed: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: :ok, else: {:error, :degraded}
  end

  defp active(_), do: {:error, :degraded}

  defp owner(s, %{owner: name, owner_generation: g}, pid) do
    authorized = s.owner_pid || NanoAgent.whereis(s.data.owner)

    if name == s.data.owner and g == s.data.owner_generation and caller_matches?(pid, authorized),
      do: :ok,
      else: {:error, :stale_owner}
  end

  defp owner(_, _, _), do: {:error, :stale_owner}

  defp caller_matches?(pid, authorized) when is_pid(authorized) do
    Process.alive?(authorized) and
      (pid == authorized or
         case Process.info(pid, :dictionary) do
           {:dictionary, dictionary} ->
             case Keyword.get(dictionary, :"$callers", []) do
               [^authorized | _] -> true
               _ -> false
             end

           _ ->
             false
         end)
  end

  defp caller_matches?(_, _), do: false

  defp author(s, %{unit: id} = t, id, _) do
    case worker(s, t) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp author(s, a, _, pid), do: owner(s, a, pid)

  defp worker(s, %{unit: id} = token) do
    with {:ok, u} <- fetch(s.data, id),
         true <-
           (u.claim != nil and Process.alive?(u.claim.pid) and Map.delete(u.claim, :pid) == token and
              token.owner_generation == s.data.owner_generation) || {:error, :stale} do
      {:ok, u}
    end
  end

  defp worker(_, _), do: {:error, :stale}

  defp reservation(s, %{unit: id} = r) do
    with {:ok, u} <- fetch(s.data, id),
         true <-
           (u.reservation == r and r.owner_generation == s.data.owner_generation) ||
             {:error, :stale_reservation},
         do: {:ok, u}
  end

  defp reservation(_, _), do: {:error, :stale_reservation}

  defp fetch(d, id) do
    case Map.fetch(d.units, id) do
      {:ok, u} -> {:ok, u}
      :error -> {:error, :not_found}
    end
  end

  defp put_unit(d, id, u), do: %{d | units: Map.put(d.units, id, u)}
  defp history(d, ev), do: %{d | history: d.history ++ [Map.put(ev, :at, now())]}
  defp unit_history(u, ev), do: %{u | history: u.history ++ [ev]}

  defp interrupt(u, reason) do
    reason = Data.normalize(reason)
    u = %{u | claim: nil, claim_generation: u.claim_generation + 1}

    unit_history(u, %{
      id: "interrupt-#{u.claim_generation}",
      kind: :interrupted,
      by: "graph-owner",
      reason: reason,
      at: now()
    })
  end

  defp persist(s, d) do
    try do
      s.writer.(s.root, d)
    rescue
      _ -> {:error, :write_exception}
    catch
      _, _ -> {:error, :write_exception}
    end
  end

  defp monitor_claims(s) do
    current =
      Map.new(s.monitors, fn {ref, {id, generation}} ->
        u = s.data.units[id]

        if u == nil or u.claim == nil or u.claim_generation != generation,
          do: Process.demonitor(ref, [:flush])

        {ref, {id, generation}}
      end)
      |> Enum.filter(fn {_, {id, generation}} ->
        u = s.data.units[id]
        u != nil and u.claim != nil and u.claim_generation == generation
      end)
      |> Map.new()

    s = %{s | monitors: current}

    Enum.reduce(s.data.units, s, fn {id, u}, acc ->
      if u.claim &&
           not Enum.any?(acc.monitors, fn {_, pair} -> pair == {id, u.claim_generation} end) do
        %{
          acc
          | monitors:
              Map.put(acc.monitors, Process.monitor(u.claim.pid), {id, u.claim_generation})
        }
      else
        acc
      end
    end)
  end

  defp record_transition(req, d) do
    kind = elem(req, 0)

    {id, by} =
      case req do
        {:claim, id, name, _, _, _} -> {id, name}
        {k, t, _} when k in [:expand, :submit, :release] -> {t.unit, t.claimant}
        {:append, a, id, _} -> {id, a[:claimant] || a[:owner]}
        {:adopt, a, id, _} -> {id, a.owner}
        {:integration, a, r, _} -> {r.unit, a.owner}
        {:stage, a, id, _, _} -> {id, a.owner}
        {:close, a, id} -> {id, a.owner}
        {:reopen, a, id, _, _} -> {id, a.owner}
        {:abandon, a, id, _, _} -> {id, a.owner}
        {:resolve_external, a, id, _} -> {id, a.owner}
        {:prepare_dispatch, a, token, _} -> {token.unit, a.owner}
        {:reconcile_bootstrap, a, id, _, _} -> {id, a.owner}
        _ -> {nil, d.owner}
      end

    ev = %{
      id: "transition-#{d.owner_generation}-#{d.revision}",
      kind: kind,
      by: by,
      at: now(),
      owner_generation: d.owner_generation,
      tokens: nil,
      wall_time_ms: nil
    }

    if id, do: put_unit(d, id, unit_history(d.units[id], ev)), else: history(d, ev)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp hash(h),
    do:
      if(is_binary(h) and Regex.match?(~r/\A[0-9a-f]{40}\z/, h),
        do: :ok,
        else: {:error, :invalid_commit}
      )

  defp evidence(e),
    do:
      if(e not in [nil, "", %{}, [], false] and :erlang.external_size(e) <= 128_000,
        do: :ok,
        else: {:error, :invalid_evidence}
      )

  defp valid_event(%{id: id, by: by} = e, a) when is_binary(id) and id != "" do
    if by == (a[:claimant] || a[:owner]) and
         (e[:tokens] == nil or (is_integer(e.tokens) and e.tokens >= 0)),
       do: evidence(e),
       else: {:error, :invalid_event}
  end

  defp valid_event(_, _), do: {:error, :invalid_event}

  defp readiness_result(s, id) do
    with :ok <- active(s),
         {:ok, u} <- fetch(s.data, id),
         {:ok, _} <- Scopes.normalize(u.scopes, s.repository) do
      cond do
        u.done ->
          {:error, {:not_ready, :done}}

        u[:bootstrap_pending] == true ->
          {:error, {:not_ready, :bootstrap_reconciliation}}

        u.claim != nil or u.reservation != nil ->
          {:error, {:not_ready, :reserved}}

        blockers(u) ->
          {:error, {:not_ready, :external_or_review}}

        Enum.any?(u.description.dependencies, fn dep -> not s.data.units[dep].done end) ->
          {:error, {:not_ready, :dependencies}}

        true ->
          with :ok <- no_conflict(s.data, id, u.scopes), do: {:ok, :ready}
      end
    end
  end

  defp worker_worktree_scopes(%{dispatch: %{claim_token: token} = dispatch}, token, scopes) do
    case Scopes.normalize(scopes, dispatch.worktree) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp worker_worktree_scopes(_, _, _), do: :ok

  defp no_conflict(d, id, scopes) do
    if Enum.any?(d.units, fn {other, u} ->
         other != id and (u.claim != nil or u.reservation != nil) and
           Scopes.conflicts?(scopes, u.scopes)
       end), do: {:error, :conflict}, else: :ok
  end

  defp blockers(u) do
    original = Enum.uniq(u.description.external_blockers ++ (u.stages[:external_blockers] || []))
    resolved = Enum.map(u.stages[:external_resolutions] || [], & &1.blocker)
    Enum.any?(original, &(&1 not in resolved)) or u.stages[:serious_findings] not in [nil, []]
  end

  defp valid_resolution(u, %{
         blocker: blocker,
         outcome: :verified_resolved,
         verification: verification,
         owner_decision: :resolve,
         verified_at: at
       }) do
    with true <-
           blocker in (u.description.external_blockers ++ (u.stages[:external_blockers] || [])) ||
             {:error, :unknown_blocker},
         :ok <- evidence(verification),
         true <- is_binary(at) || {:error, :invalid_resolution},
         {:ok, _, _} <- DateTime.from_iso8601(at),
         do: :ok
  end

  defp valid_resolution(_, _), do: {:error, :invalid_resolution}

  defp descendants_busy?(d, id) do
    Enum.any?(d.units, fn {other, u} ->
      other != id and depends_on?(d, other, id) and
        (u.claim != nil or u.reservation != nil or u.done)
    end)
  end

  defp depends_on?(d, id, target) do
    target in d.units[id].description.dependencies or
      Enum.any?(d.units[id].description.dependencies, &depends_on?(d, &1, target))
  end

  defp clear_attempt(u, reason, by) do
    u =
      unit_history(u, %{
        id: "attempt-archive-#{u.claim_generation}-#{reason}",
        kind: :attempt_archived,
        by: by,
        at: now(),
        reason: reason,
        prior_proposal: u.proposal,
        prior_dispatch: u.dispatch,
        prior_stages: u.stages,
        prior_attempt: u[:attempt],
        prior_bindings: u[:stage_bindings],
        prior_bootstrap: u[:bootstrap_reconciled]
      })

    %{
      u
      | proposal: nil,
        dispatch: nil,
        accepted: false,
        stages: Map.take(u.stages, [:external_blockers, :external_resolutions, :serious_findings])
    }
    |> Map.put(:acceptance, nil)
    |> Map.put(:attempt, nil)
    |> Map.put(:stage_bindings, %{})
    |> Map.put(:bootstrap_reconciled, nil)
  end

  defp proof_attempt(_, stage) when stage in [:external_blockers, :serious_findings], do: :ok

  defp proof_attempt(u, _) do
    if is_map(u[:attempt]) and u.dispatch != nil, do: :ok, else: {:error, :dispatch_required}
  end

  defp stage_binding(u, stage) do
    revision =
      if stage in [:deployed, :live_verified, :announced],
        do: get_in(u, [:stages, :integrated, :commit]),
        else: nil

    %{attempt: u[:attempt], integrated_commit: revision}
  end

  defp current_proofs?(u, required) do
    if u[:attempt] == nil do
      is_map(u[:bootstrap_reconciled]) and
        Enum.all?(required, &(u.bootstrap_reconciled.stages[&1] == u.stages[&1]))
    else
      Enum.all?(required, &((u[:stage_bindings] || %{})[&1] == stage_binding(u, &1)))
    end
  end

  defp invalidate_deployment(u) do
    u =
      unit_history(u, %{
        id: "revision-invalidated-#{u.integration_generation}",
        kind: :revision_invalidated,
        by: "graph-owner",
        at: now(),
        prior_stages: Map.take(u.stages, [:deployed, :live_verified, :announced])
      })

    %{u | stages: Map.drop(u.stages, [:deployed, :live_verified, :announced])}
    |> Map.put(
      :stage_bindings,
      Map.drop(u[:stage_bindings] || %{}, [:deployed, :live_verified, :announced])
    )
  end

  defp done_gate(u) do
    required =
      if u.description.type == :code,
        do: [:implemented, :tested, :reviewed, :integrated, :deployed, :live_verified, :announced],
        else: [:implemented, :tested, :reviewed, :artifact_verified, :announced]

    cond do
      u[:bootstrap_pending] == true ->
        {:error, :bootstrap_reconciliation}

      blockers(u) ->
        {:error, :blocked}

      Enum.any?(required, &(u.stages[&1] in [nil, "", %{}, [], false])) ->
        {:error, :missing_stages}

      not current_proofs?(u, required) ->
        {:error, :stale_stage_proof}

      true ->
        :ok
    end
  end

  defp depth(d, id) do
    children = for {other, u} <- d.units, id in u.description.dependencies, do: depth(d, other)
    1 + Enum.max(children, fn -> 0 end)
  end

  defp proposal(s, u, p) do
    with :ok <- hash(p.commit),
         :ok <- hash(p.base_commit),
         true <- u.dispatch != nil || {:error, :dispatch_required},
         true <-
           (p[:dispatch_generation] == u.dispatch.generation and
              p[:unit_sha256] == u.dispatch.unit_sha256) || {:error, :stale_dispatch},
         true <-
           (p[:author_token] || Map.delete(u.claim || %{}, :pid)) == u.dispatch.claim_token ||
             {:error, :stale_dispatch},
         true <- p.base_commit == u.dispatch.base_commit || {:error, :incompatible_base},
         true <- (is_binary(p.id) and p.id != "") || {:error, :invalid_proposal},
         true <-
           Enum.all?(u.description.dependencies, &s.data.units[&1].done) ||
             {:error, {:not_ready, :dependencies}},
         :ok <- evidence(p.evidence),
         {:ok, _} <- Scopes.normalize(u.scopes, s.repository),
         {:ok, _} <- Scopes.normalize(u.scopes, p.worktree),
         true <- Path.expand(p.worktree) == u.dispatch.worktree || {:error, :wrong_worktree},
         {:ok, paths} <- actual_diff(p),
         {:ok, _} <- Scopes.normalize(Enum.map(paths, &%{kind: :exact, path: &1}), s.repository),
         {:ok, _} <- Scopes.normalize(Enum.map(paths, &%{kind: :exact, path: &1}), p.worktree),
         true <- Enum.all?(paths, &Scopes.covers?(u.scopes, &1)) || {:error, :unclaimed_diff},
         :ok <- no_conflict(s.data, u.description.id, u.scopes) do
      :ok
    end
  end

  defp original_bootstrap(d, id, sha) do
    records =
      Enum.flat_map(d.provenance, fn p ->
        if is_map(p), do: List.wrap(p["bootstrap"]), else: []
      end)

    record =
      Enum.find(records, fn record ->
        is_map(record) and record["sha256"] == sha and is_map(record["record"]) and
          record["record"]["unit"] == id and record["record"]["stage"] == "done" and
          is_binary(record["original_bytes"]) and
          Base.encode16(:crypto.hash(:sha256, record["original_bytes"]), case: :lower) == sha and
          Jason.decode(record["original_bytes"]) == {:ok, record["record"]}
      end)

    if record, do: {:ok, record}, else: {:error, :bootstrap_provenance_mismatch}
  end

  defp bootstrap_stages(u, input) when is_map(input) do
    required =
      if u.description.type == :code,
        do: [:implemented, :tested, :reviewed, :integrated, :deployed, :live_verified, :announced],
        else: [:implemented, :tested, :reviewed, :artifact_verified, :announced]

    with true <- Enum.sort(Map.keys(input)) == Enum.sort(required) || {:error, :missing_stages},
         true <-
           Enum.all?(input, fn {_, ev} -> evidence(ev) == :ok end) || {:error, :invalid_evidence} do
      stages =
        Map.new(input, fn {stage, ev} ->
          if stage == :integrated do
            if hash(ev[:commit]) != :ok or evidence(ev[:evidence]) != :ok,
              do: throw(:invalid_evidence)

            {stage, %{commit: ev.commit, evidence: Data.normalize(ev.evidence)}}
          else
            {stage, Data.normalize(ev)}
          end
        end)

      {:ok, stages}
    end
  end

  defp bootstrap_stages(_, _), do: {:error, :invalid_evidence}

  defp bootstrap_commit(repo, record, %{integrated: %{commit: commit}}) do
    case System.cmd(
           "git",
           ["-C", repo, "merge-base", "--is-ancestor", record["record"]["base"], commit],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> {:error, :bootstrap_commit_mismatch}
    end
  end

  defp bootstrap_commit(_, _, _), do: :ok

  @dispatch_paths [
    :worktree,
    :build_root,
    :deps_root,
    :runtime_root,
    :random_tmp_root,
    :unit_path
  ]
  defp valid_dispatch(s, token, input) do
    fields = [:base_commit, :branch, :unit_sha256 | @dispatch_paths]
    dispatch = Data.fields(input, fields)

    with :ok <- hash(dispatch[:base_commit]),
         true <-
           (is_binary(dispatch[:branch]) and dispatch.branch != "") || {:error, :invalid_dispatch},
         true <-
           (is_binary(dispatch[:unit_sha256]) and
              Regex.match?(~r/\A[0-9a-f]{64}\z/, dispatch.unit_sha256)) ||
             {:error, :invalid_dispatch},
         true <-
           Enum.all?(@dispatch_paths, fn key ->
             is_binary(dispatch[key]) and dispatch[key] != "/" and
               Path.type(dispatch[key]) == :absolute and
               dispatch[key] == Path.expand(dispatch[key])
           end) || {:error, :invalid_dispatch_paths},
         true <-
           Enum.all?(@dispatch_paths, &(Scopes.safe_root(dispatch[&1]) == :ok)) ||
             {:error, :alias_root},
         {base, 0} <-
           System.cmd("git", ["-C", dispatch.worktree, "rev-parse", "HEAD"],
             stderr_to_stdout: true
           ),
         true <- String.trim(base) == dispatch.base_commit || {:error, :worktree_base_mismatch},
         {branch, 0} <-
           System.cmd("git", ["-C", dispatch.worktree, "branch", "--show-current"],
             stderr_to_stdout: true
           ),
         true <- String.trim(branch) == dispatch.branch || {:error, :worktree_branch_mismatch},
         {:ok, bytes} <- File.read(dispatch.unit_path),
         true <-
           (byte_size(bytes) <= 32_768 and
              Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == dispatch.unit_sha256) ||
             {:error, :unit_hash_mismatch},
         {:ok, unit} <- Jason.decode(bytes),
         true <-
           (unit["id"] == token.unit and is_map(unit["dispatch"])) ||
             {:error, :resolved_unit_mismatch},
         true <-
           (unit["dispatch"]["worker_name"] == token.claimant and
              unit["dispatch"]["incarnation"] == token.incarnation and
              unit["dispatch"]["authority_generation"] == token.owner_generation and
              unit["dispatch"]["dispatch_generation"] ==
                s.data.units[token.unit].dispatch_generation + 1) ||
             {:error, :resolved_unit_mismatch},
         true <-
           Enum.all?([:base_commit, :branch | @dispatch_paths -- [:unit_path]], fn key ->
             unit["dispatch"][Atom.to_string(key)] == dispatch[key]
           end) || {:error, :resolved_unit_mismatch},
         {:ok, _} <- Scopes.normalize(s.data.units[token.unit].scopes, dispatch.worktree),
         :ok <- no_conflict(s.data, token.unit, s.data.units[token.unit].scopes) do
      {:ok, Map.put(dispatch, :resolved_unit_bytes, bytes)}
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_dispatch}
    end
  end

  defp dispatch_isolated(data, id, dispatch) do
    roots = Enum.map(@dispatch_paths -- [:unit_path], &dispatch[&1])

    conflict =
      Enum.any?(data.units, fn {other, u} ->
        other != id and (u.claim != nil or u.reservation != nil) and u.dispatch != nil and
          Enum.any?(roots, fn root ->
            Enum.any?(@dispatch_paths -- [:unit_path], fn key ->
              path = u.dispatch[key]

              root == path or String.starts_with?(root, path <> "/") or
                String.starts_with?(path, root <> "/")
            end)
          end)
      end)

    if conflict, do: {:error, :dispatch_path_conflict}, else: :ok
  end

  defp git_read(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:error, :git_diff_failed}
    end
  end

  defp acceptance_pin(s) do
    with :ok <- Scopes.safe_root(s.repository),
         {:ok, top} <- git_read(s.repository, ["rev-parse", "--show-toplevel"]),
         true <- top == s.repository || {:error, :integration_repository_mismatch},
         {:ok, status} <-
           git_read(s.repository, ["status", "--porcelain", "--untracked-files=all"]),
         true <- status == "" || {:error, :dirty_integration_repository},
         {:ok, base} <- git_read(s.repository, ["rev-parse", "HEAD^{commit}"]),
         :ok <- hash(base) do
      {:ok, %{repository: s.repository, base_commit: base}}
    end
  end

  defp landed_candidate(s, u, commit) do
    pin = u[:acceptance]

    with true <- is_map(pin) || {:error, :acceptance_required},
         true <- pin.repository == s.repository || {:error, :integration_repository_mismatch},
         {:ok, current} <- acceptance_pin(s),
         true <- current.base_commit == commit || {:error, :integration_head_mismatch},
         {:ok, parents} <- git_read(s.repository, ["rev-list", "--parents", "-n", "1", commit]),
         true <-
           String.split(parents) == [commit, pin.base_commit] ||
             {:error, :integration_parent_mismatch},
         {:ok, paths} <-
           actual_diff(%{
             worktree: s.repository,
             base_commit: pin.base_commit,
             commit: commit,
             changed_files: u.proposal.changed_files
           }),
         {:ok, _} <- Scopes.normalize(Enum.map(paths, &%{kind: :exact, path: &1}), s.repository),
         true <- Enum.all?(paths, &Scopes.covers?(u.scopes, &1)) || {:error, :unclaimed_diff},
         {:ok, merged} <-
           git_read(s.repository, [
             "merge-tree",
             "--write-tree",
             "--merge-base=" <> u.proposal.base_commit,
             pin.base_commit,
             u.proposal.commit
           ]),
         {:ok, tree} <- git_read(s.repository, ["rev-parse", commit <> "^{tree}"]),
         true <- merged == tree || {:error, :integration_content_mismatch} do
      :ok
    end
  end

  defp actual_diff(p) do
    # Git output is NUL separated, includes both sides of renames by disabling rename detection.
    {_, ancestor} =
      System.cmd(
        "git",
        ["-C", p.worktree, "merge-base", "--is-ancestor", p.base_commit, p.commit],
        stderr_to_stdout: true
      )

    if ancestor != 0, do: throw(:git_diff_failed)

    case System.cmd(
           "git",
           [
             "-C",
             p.worktree,
             "diff",
             "--no-ext-diff",
             "--no-textconv",
             "--no-renames",
             "--name-only",
             "-z",
             p.base_commit,
             p.commit,
             "--"
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        paths = String.split(out, <<0>>, trim: true) |> Enum.sort()

        if paths == Enum.sort(p.changed_files) and paths != [],
          do: {:ok, paths},
          else: {:error, :diff_mismatch}

      _ ->
        {:error, :git_diff_failed}
    end
  end

  @doc "Validate a complete candidate without changing authority. Atom-keyed version 1 API."
  def validate(%{schema_version: 1, units: list}, repo) when is_list(list) and list != [] do
    with true <- Enum.all?(list, &is_map/1) || {:error, :invalid_units},
         ids = Enum.map(list, & &1[:id]),
         true <-
           (Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
              length(ids) == length(Enum.uniq(ids))) || {:error, :duplicate_id},
         leaves = Enum.flat_map(list, &List.wrap(&1[:requirement_leaves])),
         true <- length(leaves) == length(Enum.uniq(leaves)) || {:error, :duplicate_leaf_link},
         {:ok, units} <- validate_units(list, repo),
         true <-
           Enum.all?(units, fn {_, u} ->
             Enum.all?(u.description.dependencies, &Map.has_key?(units, &1))
           end) || {:error, :missing_dependency},
         true <- not Enum.any?(ids, &cycle?(units, &1, [])) || {:error, :cycle} do
      {:ok, units}
    end
  rescue
    _ -> {:error, :invalid_description}
  catch
    :invalid_evidence -> {:error, :invalid_evidence}
  end

  def validate(_, _), do: {:error, :invalid_schema}

  defp validate_units(list, repo) do
    Enum.reduce_while(list, {:ok, %{}}, fn d, {:ok, acc} ->
      result =
        with true <-
               Enum.all?(
                 [:title, :why, :acceptance, :risks, :rollout],
                 &(d[&1] not in [nil, "", []])
               ) || {:error, :incomplete_unit},
             :ok <- hash(d[:base_commit]),
             true <-
               (d[:type] in [:code, :artifact] and is_integer(d[:priority]) and d.priority >= 0) ||
                 {:error, :invalid_type_priority},
             true <-
               (is_list(d[:requirement_leaves]) and d.requirement_leaves != [] and
                  Enum.all?(d.requirement_leaves, &is_binary/1)) || {:error, :missing_leaves},
             true <-
               (is_list(d[:dependencies]) and is_list(d[:external_blockers])) ||
                 {:error, :invalid_dependencies},
             {:ok, scopes} <- Scopes.normalize(d[:scopes], repo) do
          {:ok,
           %{
             description:
               Data.fields(d, [
                 :id,
                 :title,
                 :why,
                 :base_commit,
                 :type,
                 :priority,
                 :requirement_leaves,
                 :dependencies,
                 :external_blockers,
                 :scopes,
                 :acceptance,
                 :risks,
                 :rollout,
                 :worktree
               ])
               |> Map.put(:type, d.type)
               |> Map.put(:scopes, scopes),
             scopes: scopes,
             claim: nil,
             claim_generation: 0,
             integration_generation: 0,
             dispatch: nil,
             dispatch_generation: 0,
             reservation: nil,
             proposal: nil,
             accepted: false,
             stages: %{},
             done: false,
             history: [],
             created_at: now()
           }}
        end

      case result do
        {:ok, u} -> {:cont, {:ok, Map.put(acc, d.id, u)}}
        e -> {:halt, e}
      end
    end)
  end

  defp cycle?(units, id, path),
    do:
      id in path or Enum.any?(units[id].description.dependencies, &cycle?(units, &1, [id | path]))
end
