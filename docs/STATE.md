# State reference

`.ocean/state.json` is the run's machine-readable heart. **It is mutated only via
`ocean.sh`** — every subcommand performs an atomic write (temp file + `mv`), so state
can never be half-written. This page documents the schema and the other `.ocean/`
file formats.

## state.json schema

```json
{
  "run_id": "ocean-20260713-104500",
  "created_at": 1783840500,
  "spec_path": "docs/SPEC.md",
  "goal": "ship v1 of the todo API",
  "status": "running",
  "current_sprint": 3,
  "sprints": [
    { "id": 1, "title": "Database schema + migrations", "status": "done", "commit": "a1b2c3d" },
    { "id": 2, "title": "Auth module",                  "status": "done", "commit": "e4f5a6b" },
    { "id": 3, "title": "CRUD endpoints",               "status": "in_progress", "commit": "" },
    { "id": 4, "title": "Frontend",                     "status": "todo", "commit": "" }
  ],
  "verify_cmd": "npm test",
  "iteration": 7,
  "reopen_count": 0,
  "last_checkpoint": 1783862100,
  "heartbeat": 1783862100,
  "blockers": [],
  "notes": "sp3: GET/POST done; next worker: PATCH handler in src/routes/todos.js, failing test is todos.patch.spec"
}
```

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `run_id` | string | `init` | Unique id, `ocean-YYYYMMDD-HHMMSS` |
| `created_at` | epoch | `init` | Run creation time |
| `spec_path` | string | `init` | The spec file the run executes |
| `goal` | string | `init --goal` | One-line intent, shown in reports |
| `status` | enum | lifecycle cmds | `planning` → `running` → `complete` (or `blocked` / `paused` / `aborted`) |
| `current_sprint` | int | `sprint-start` | Sprint currently in progress |
| `sprints[]` | array | `sprint-add/start/done` | `status`: `todo` → `in_progress` → `done`; `commit` records the sprint's sha |
| `verify_cmd` | string | `init --verify-cmd` | The daemon's independent completion gate |
| `iteration` | int | daemon | Worker launches so far (budget guard) |
| `reopen_count` | int | `reopen` | Times the verify gate bounced a completion claim (blocks at 2) |
| `last_checkpoint` | epoch | `checkpoint`, `sprint-done`, … | Freshness signal for the Stop guard |
| `heartbeat` | epoch | most commands | Last state activity of any kind |
| `blockers[]` | array | `block`, `reopen` | Human-readable reasons, append-only |
| `notes` | string | `checkpoint --notes` | **The handoff** — the next worker's first instruction |

### Status semantics

| Status | Meaning | Daemon behavior |
|---|---|---|
| `planning` | Spec read, plan being written | launches workers |
| `running` | Executing sprints | launches workers |
| `complete` | Worker claims done | runs verify gate → done or reopen |
| `blocked` | Human input needed (reason in `blockers`) | notifies, exits |
| `paused` | Manual hold (`ocean set-status paused`) | exits |
| `aborted` | Manual kill of the run | exits |

## ocean.sh command surface

```
ocean init <spec> [--verify-cmd CMD] [--goal TEXT]   create a run (refuses if one exists)
ocean sprint-add "<title>"                           register a sprint (planning phase)
ocean plan-done                                      lock the plan → status running
ocean sprint-start <id>                              mark sprint in_progress
ocean sprint-done <id> [--commit SHA]                mark sprint done (+ checkpoint)
ocean checkpoint [--notes "<handoff>"]               record a clean handoff point
ocean block "<reason>"                               → blocked (human needed)
ocean unblock                                        blocked → running
ocean reopen "<note>"                                verify-gate bounce (daemon calls this)
ocean set-status <status>                            explicit transition (validated)
ocean iteration                                      increment + print iteration (daemon)
ocean heartbeat                                      touch heartbeat only
ocean stop                                           create the STOP file
ocean status | ocean json                            human table | raw state
```

## The markdown files

### PLAN.md — written once, in planning

Per sprint: goal, files touched, acceptance criteria, dependencies on earlier sprints.
Amendments after `plan-done` require a DECISIONS.md entry explaining why.

### DECISIONS.md — append-only journal

Seeded by `init` with the entry template:

```markdown
## D4: Storage engine
- **Sprint:** 3  **Date:** 2026-07-13
- **Options:** Postgres / SQLite
- **Chose:** SQLite behind a repository layer
- **Why:** spec implies single-node deploy; local-first beats ops burden; adapter keeps the door open
- **Cost to reverse:** low-medium — swap adapter + run migration script
```

Two-way doors get one line; one-way doors get the full block and are re-flagged in
REPORT.md.

### REPORT.md — written at completion

What shipped (sprint → commit table), decisions worth human review, known limitations,
how to run/verify. This is the file you read first the morning after.

## Concurrency and integrity

- **Atomic writes**: `jq → mktemp → mv` — readers always see a complete document.
- **Single writer per moment**: the daemon lock (`daemon.lock/`, an atomic `mkdir`
  stamped with the pid) guarantees one daemon; workers mutate state only through
  `ocean.sh` at well-defined protocol points.
- **`STOP`**: presence of the file (not content) signals shutdown — the cheapest
  possible cross-process flag.
- **Commit `.ocean/` to git.** It's the audit trail; state history rides along with
  the sprint commits it describes.
