# Deneb seedling: operating map

This branch grows every spec in `seeding-docs/README.md`; it is not intended to merge
into the minimal seed. The consumer surface is `/bots`; operator agents, goals,
front-of-mind notes and timelines remain on the existing dashboard. This application
is an unauthenticated computer-control interface, not an Internet-safe multi-tenant
service. Keep the endpoint on a trusted network.

## Library entry points

Read module docs with `Code.fetch_docs(Module)` for signatures and limits.

| Need | Library / further reading |
|---|---|
| Bounded files, search and shell | `Workspace` |
| Detached commands and completion events | `Background` |
| Automatic or voluntary checkpoints | `Compaction`, `NanoAgent` |
| Watched children, isolated worktrees, fitted prompts | `Delegation`, `prompts/partials` |
| Durable keyed knowledge and goal trees | `Memory`, `Goals` |
| Tip-of-context focus note, optional drift checking | `FrontOfMind` |
| Typed fast judgments | `Decision` (node setting `TYPESAFE_API_KEY`) |
| Readable pages and JavaScript browsing | `WebAccess`, `Browser`, `docs/web_access.md` |
| Search, answers and detached research | `Exa`, `Research` (setting `EXA_API_KEY`) |
| External tools, resources, subscriptions | `MCP`, `docs/mcp.md`, `config/mcp.json` |
| Immutable image references and vision input | `Images` |
| Named bots, sessions, human requests | `Bots`, `Bots.Runtime` |

The orientation partial is intentionally only a map, not the complete manual.
Subagents should be composed with the operating-principles partial and only the
flavour/task parts they need. Delegation requires explicit resource limits and a
starting revision. A read-only worktree is a convention, not a sandbox.

## Durable state and resource boundaries

State lives under `/data` by default; tests derive isolated roots for each run.
Keep credentials private. Use the settings/auth APIs rather than rewriting their
files by hand. Runtime references and image IDs are not capabilities that enforce
access control. Disk stores, retained logs, browser downloads and image objects
currently have no general garbage collector: monitor disk usage.

Background commands run in separate process groups and clean up ordinary children
on timeout/cancellation. They are not containers: a process deliberately escaping
its group is not contained, and jobs do not survive node death. Durable job result
records permit polling after a missed best-effort completion notification.

Images validate supported formats structurally and reject excessive dimensions or
bytes; there is no transcoder/resizer or full pixel decoder. Only models advertised
as accepting images receive pixel content. Compaction retains textual provenance,
not pixels: re-view an immutable reference when needed. Bot session transcripts are
separate; cross-session memory is deliberately explicit and bounded.

MCP reconnects without replaying side-effecting calls. Unsupported server features
are errors, not silent emulation; OAuth, sampling and elicitation are not automatic.
Web text extraction is heuristic, not a full browser accessibility tree. Network
helpers bound returned content and deadlines, but do not all impose streaming
limits before download. Treat all fetched text and model-generated Markdown as
untrusted.

## Validation

Run `MIX_ENV=test mix test`, `node --test test/bots_hooks_test.js`, and
`MIX_ENV=test mix compile --warnings-as-errors`. Test mode is important: the image's
normal environment is production and shares the live node's beam directory.
Browser acceptance additionally has an isolated HTTP fixture and CDP script under
`test/`; never run destructive recovery checks against this live node. Real-provider
probes supplement deterministic tests but are not part of the default suite.

## Deployment state and recovery

`Nano.OptionalServices.status()` reports independent MCP/Bots startup failures and
retry deadlines without making those optional services prerequisites for endpoint
boot. Repair corrupt configuration/state deliberately; the manager never discards it.
`retry(Module)` requests another start after repair. A running service supervisor is
not proof that a remote MCP server is connected.

SafetyNet is installed for this deployment, and Settings/Auth saves are transactional
with private write-ahead credential backups. **The current node was not launched by
that supervisor: lockup recovery is inactive until the next ordinary supervised boot.**
`SafetyNet.status()` states this explicitly. Read `docs/safety-net.md` before restarting;
Docker restart policy and persistent mounts must be configured externally. The first
supervised boot must serve a genuine model response before qualifying a known-good
snapshot. No manually forged attestation or destructive live recovery test was used.

Validation at the integrated deployment checkpoint: 624 ExUnit tests, 8 JavaScript
hook tests, production-source compilation with warnings-as-errors, formatting, and
22 isolated external recovery tests passed. Additional followup tests may increase
these counts. Real provider probes exercised checkpoints, both vision entry paths,
Decision, Exa, and Bots chat/group/cross-session memory. Provider behavior is not made
infallible by a transport test; one initial Bots colour-identification answer was wrong
and was explicitly investigated rather than recorded as a passing vision result.
On reinspection the bot correctly identified all four quadrants. An independent audit
verified canonical image hashes and deterministic provider payload bytes against the
source fixture; no delivery corruption was found, but the initial perception error
remains part of the evidence.
