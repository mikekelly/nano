# No application startup: only explicitly private graph fixture root supplied by test.
[root, repo] = System.argv()
name = File.read!(Path.join(root, "unknown-name.txt"))

absent =
  try do
    String.to_existing_atom(name)
    false
  rescue
    ArgumentError -> true
  end

unless absent, do: raise("fixture atom was unexpectedly interned before restore")

{:ok, s} =
  Nano.Flywheel.start_link(
    root: root,
    repository: repo,
    owner: "altair",
    owner_pid: self(),
    claimant_resolver: fn _, pid -> pid end
  )

{:ok, snap} = Nano.Flywheel.snapshot(s)
if snap.mode != :reconciliation_required, do: raise("restart reopened claims")
u = snap.units["A"]
event = Enum.find(u.history, &(&1.id == "fresh-vm-event"))
if event["marker"] != name, do: raise("lost normalized evidence atom text")

absent_after =
  try do
    String.to_existing_atom(name)
    false
  rescue
    ArgumentError -> true
  end

unless absent_after, do: raise("artifact evidence interned an atom")
if not Nano.Flywheel.Scopes.covers?(u.scopes, "expanded/new"), do: raise("lost expansion")
token = snap.operations["claim-A-1"].token

{:ok, authority} =
  Nano.Flywheel.reconcile(s, %{owner: "altair", owner_generation: 1}, %{
    restoration: :roll_forward
  })

if authority.owner_generation != 2, do: raise("lost fencing")
{:error, :stale} = Nano.Flywheel.expand(s, token, [%{kind: :exact, path: "stale"}])
{:ok, _} = Nano.Flywheel.claim(s, "A", "fresh", "fresh-vm", 2, "fresh-vm-claim")
{:ok, after_state} = Nano.Flywheel.snapshot(s)

if Enum.count(after_state.units["A"].history, &(&1.id == "fresh-vm-event")) != 1,
  do: raise("duplicate accounting")

GenServer.stop(s)
IO.puts("U03 fresh VM restored evidence/scopes/generations; stale token rejected")
