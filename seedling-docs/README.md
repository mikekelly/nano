# Seedling docs

Seeding grows a harness: each seeding doc ([../seeding-docs/](../seeding-docs/README.md))
asks an agent on the seed to build one capability, and the harness that grows is a
*seedling* (the branch `seedling/<agent>-<what>`). A *seedling doc* comes after: it is
planted in an agent running on a seedling, and asks it to put the harness it has to work
by a method. Seeding is done first; a seedling doc names at its top the seeding docs it
builds on, and is planted in a seedling that has them.

Like a seeding doc, each states an **outcome**, then **considerations** and
**inspiration**, and says why each part matters, so an agent can decide what to keep, adapt
or drop for its own situation. How to get to the outcome is the agent's decision.
[../seeding-docs/guidance.md](../seeding-docs/guidance.md) still applies to everything it
builds.

| File | Method |
| --- | --- |
| [`staffing.md`](staffing.md) | A short matrix of model-and-effort pairs, chosen for value, in four strata (exec, lead, worker, grunt), from which every delegator staffs its jobs |
| [`planning.md`](planning.md) | Evidenced plans and layered delegation, accounting for orientation overlap, sequencing and staffing, through review and verified completion |

| [`bots.md`](bots.md) | Final integration stage: user–agent liaison, conversational bots and standards-based generative UI over the grown harness |

Bots come last: they bring the capabilities and the planning and staffing methods together
in the person-facing product.

Keep every seedling doc true of the running system: the agent acts on what it reads here.
