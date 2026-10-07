# Opt-in request-boundary context policy

`NanoAgent.start(context_policy: My.Context, ...)` persists a **module atom**, not a
closure. Agents without this option keep the seed's original context behavior.
The module exposes `before_request(snapshot)`:

```elixir
def before_request(%{estimate: estimate, max_context: limit, transcript: messages}) do
  if estimate > limit * 0.55 do
    # Pure deterministic bounded extraction; no models, IO or other GenServer calls.
    brief = bounded_summary(messages)
    {:replace_transcript, [%{"role" => "user", "content" => brief}]}
  else
    :keep
  end
end
```

Snapshot keys: `:name`, `:system_prompt`, `:transcript`, `:context_used`,
`:max_context`, `:estimate`. The last is the harness's conservative token estimate,
including incoming pending messages on a new turn. This is trusted operator code,
not an isolation or security sandbox. A disposable supervised task enforces a 50 ms
execution deadline. Timeout, exception, missing module/function, invalid/oversized
return, or a replacement that does not fit leaves the original history intact and
normal context safety in force. Callbacks must be deterministic and side-effect-free;
the timeout kills the task, but cannot undo spawned descendants or external effects.

## Safe boundary and validation

The callback runs only before a provider request, with no provider/eval task in
flight, `calls == []`, and all model-returned tool calls already answered. It never
kills or races a provider request. A replacement is a nonempty list of at most 64
**plain text user/assistant messages**, each with exactly string keys `"role"` and
`"content"`. Tool messages, tool-call objects, images, extra fields and system messages
are rejected: summarize those completed interactions into plain text instead of
risking orphaned provider tool IDs. The replacement's encoded JSON is capped at
65,536 bytes (individual text also capped), then the full prompt/tools/replacement
must leave the ordinary 4,096-token reply reserve under the configured context cap.
The system prompt is never changed by this hook.

On success, only transcript and measured context fields change. Lifetime token/turn
counts, costs, request IDs, log history, bindings and all limits remain unchanged.
Only an existing `:context` halt can clear; node, agent-budget, usage, log and other
halts cannot. A recovered generated context-halt notice is removed from pending,
not human/mailbox events. The old complete history remains in the harness log;
`context_compacted` records policy, old/new estimates and replacement message count.
`context_policy_error` records bounded generic failure reasons, not returned payloads.

The callback can prevent a context halt while continuing a tool-driven turn. It is
not semantic memory, a cheap model, a guarantee of no forgetting, or arbitrary-sized
input handling. The owner of the policy must preserve commitments and bound input
injections. A final response with no tools still ends its turn normally; this hook
runs at the next request boundary, not after every response. An already-idle halted
agent is not spontaneously unhalted: there is no polling loop or extra model turn.

## Verification

`MIX_ENV=test mix test test/nano_agent_context_policy_test.exs` covers all-tool-results
boundary, overflow recovery, unchanged no-opt-in safety, orphan/oversize/timeout/crash
fallback, untouched turn budget, invalid option rejection and restart persistence.
All provider traffic uses the seed's scripted localhost fake, never a live service.
