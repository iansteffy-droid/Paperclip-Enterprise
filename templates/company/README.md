# Company templates

`scripts/new-client` reads these three files to provision a client's company on the control plane. `scripts/validate-templates.sh` checks them (it runs on every commit).

| File | What it is |
| --- | --- |
| `roster.json` | The agents: folder (`dir`), display name, title, role, model tier (`opus` or `sonnet`), manager, skills, extra env, run limits, instructions file. |
| `routines.json` | The routines created for the company, each with its assignee (by folder) and variables. All are triggered by hand or by the server. |
| `blueprint.json` | The company's workflow: who takes intake, which review chains the server attaches, when the operator can halt, and the retro and merge routines. |

Agents are named by folder everywhere (`"dir": "hops"`, `"intake_agent": "data"`). The files carry no ids: `new-client` resolves each folder to the company's agent id when it writes the blueprint.

## blueprint.json, field by field
- `mode`: always `standard` (one feature at a time per client).
- `intake_agent`: the agent new top-level issues start with. While an issue is assigned to it, no chain is attached; the first assignment to anyone else attaches the feature chain.
- `subtask_stages`: the review chain for a subtask (an issue with a parent). Today one stage, Hops. It runs on each subtask every time its author hands it off, while the feature waits.
- `feature_stages`: the review chain for a feature, which means any top-level issue, bugs included. It runs once, after all subtasks are done and the dispatcher submits the feature, and must end with the board's approval stage.
- `gated_subtask_kinds`: which subtasks get the subtask chain, by their `kind:` label. The server knows only `impl`, `tests` and `repro`; a subtask with none of those labels counts as `impl`. A kind left out of this list gets no review at all.
- `halt_phrases`: a board comment whose first line is one of these holds the issue's chain until the board resumes it.
- `retro`: the retrospective routine by title (`routineName`), whether the server fires it on its own (`autoTrigger`), after how many review bounces in one issue tree (`bounceThreshold`), and how long it waits before firing again for the same tree (`cooldownHours`).
- `prepare_for_merge_routineName`: the routine, by title, that prepares a finished feature branch for the human's merge.
- `labels`: labels created in the company: the three `kind:` labels and `security-relevant`.

## What changing blueprint.json changes, and what it does not
It changes the server's routing: which agents review a subtask or a feature and in which order, which subtask kinds are reviewed, who takes intake, the halt phrases and the retro settings.

It does not change how Riker slices work, what any agent's `AGENTS.md` says, or the hooks (the git guard, the hand-off gate, the completion gate). Moving a reviewer without updating the prose leaves agents describing a chain that no longer exists: change both together.

## Applying an edit to an existing company
Re-run `new-client` with the same arguments as the first run (`scripts/new-client --name <client> --repo <url>`; add `--dry-run` first to see the steps). It is idempotent and only acts where the result differs:
- **blueprint.json**: compared with the live blueprint and written with one PUT when different (`updated blueprint`). Every blueprint field applies this way.
- **labels**: missing ones are created; existing ones are never changed or deleted.
- **routines.json**: a routine whose title is missing is created; existing routines are never changed or deleted, so a routine removed from the template stays in the company until you delete it.
- **roster.json**: agents are matched by exact display name. A missing name creates a new agent; an existing agent's model, title, role, instructions and limits are left as they are. Manager, skills, hook settings and env are re-synced.

So for an existing company:
- **Renaming an agent** (the `Data` entry, for example): first rename the live agent with `PATCH /api/agents/<id>` and body `{"name": "<new name>"}` (the ids are in `clients/<client>/client.yaml`), then re-run `new-client`. Re-running first creates a duplicate agent.
- **Changing a tier**: `new-client` does not update an existing agent's model. Set it with `PATCH /api/agents/<id>` on `adapterConfig.model`, keeping the rest of `adapterConfig`.
