# Architecture

How boil-the-ocean turns "one giant task" into "a series of small, resumable,
verified sessions" — and why each piece is shaped the way it is.

## The core idea: memory in files, not conversations

An agent session dies with its context window. A file does not. Everything the run
needs to continue — plan, progress, decisions, the next step — lives in `.ocean/`:

```
.ocean/
├── state.json        # machine state (schema: docs/STATE.md) — ocean.sh is the only writer
├── SPEC.md           # the spec, if it arrived as pasted text (immutable)
├── PLAN.md           # per-sprint goals, files, acceptance criteria (written once)
├── DECISIONS.md      # append-only decision journal
├── REPORT.md         # final report (written at completion)
├── STOP              # touch this file → daemon exits before next iteration
├── prompt-override.md# optional: replaces the default worker prompt
├── daemon.lock/      # pid-stamped mkdir lock (one daemon per run)
└── logs/
    ├── daemon.log    # the scheduler's journal
    └── iter-NNN.log  # full output of worker session N
```

Because the whole run state is ~2 KB of JSON plus three markdown files, *any* fresh
session — relaunched by the daemon, opened by a human, driven by a different agent
entirely — can reconstruct exactly where the run stands in one read.

## Components

### 1. The protocol — `skills/boil-ocean/SKILL.md`

A single markdown file that is simultaneously:

- a **Claude Code skill** (auto-triggers on "boil the ocean", "build the whole spec",
  resuming `.ocean/` repos), and
- the **binding instruction document** for every other agent — the daemon's worker
  prompt says *"your protocol is defined in `<path>/SKILL.md` — read it now and follow
  it exactly."*

This is the key portability decision: the protocol is words, not code, so supporting a
new agent requires zero porting of the behavioral layer.

The protocol's discipline features were built test-first against observed failure
modes (an agent offered "scoped options" when asked for everything; agents ask
questions mid-run; agents stop without handoffs). It contains a rationalization table
and red-flags list targeting those exact behaviors, plus the decision protocol and
only-stop list described in the README.

### 2. The state manager — `scripts/ocean.sh`

A ~250-line bash CLI, the **only writer** of `state.json`.

- **Atomic writes**: every mutation is `jq → temp file → mv`. A worker killed
  mid-write (timeout, OOM, Ctrl-C) can never leave half-written JSON.
- **Validated transitions**: `set-status` rejects unknown states; `sprint-start`
  rejects unknown ids; `init` refuses to clobber an existing run.
- **Self-documenting**: `ocean status` renders the run as a human-readable table.

Why bash + jq and not Python/Node? Zero install friction on the machines agents
actually run on, and trivially auditable — an unattended tool should be readable in
one sitting.

### 3. The scheduler — `scripts/ocean-daemon.sh`

The daemon owns the *between-sessions* problem. One loop iteration:

```
STOP file?  ──yes──▶ exit 0
status?
  ├─ complete ──▶ verify gate ──pass──▶ notify, exit 0
  │                    └──fail──▶ reopen (≤2) or block
  ├─ blocked/paused/aborted ──▶ notify, exit 0
  └─ planning/running ──▶ continue
iteration++  > OCEAN_MAX_ITERATIONS? ──▶ block (budget guard)
launch worker (agent adapter) with watchdog timeout
  ├─ output matches limit patterns ──▶ backoff (reset-timestamp or exponential), retry
  ├─ nonzero exit ──▶ failure counter (block at OCEAN_MAX_FAILURES)
  └─ success ──▶ sprint-progress notification, stall check
stall: state fingerprint unchanged × OCEAN_STALL_LIMIT ──▶ block
loop
```

Design decisions worth knowing:

- **Fresh session per iteration, never `--resume`.** Resuming a bloated session
  re-pays its entire context and inherits its confusion. A fresh worker reading a
  2 KB state file is cheaper *and* more reliable. The checkpoint notes are the
  contract between consecutive workers.
- **Deliberate exits are exit-code 0.** launchd's `KeepAlive.SuccessfulExit=false`
  restarts only non-zero exits — so crashes respawn the daemon, while
  complete/blocked/stopped stay down.
- **The verify gate is independent.** The worker *claims* completion; the daemon
  *checks* it by running `verify_cmd` itself. Claims that don't survive the gate
  reopen the run (bounded at 2 reopens, then block). Trust, but verify.
- **Stall detection fingerprints state, not output.** `{status, current_sprint,
  sprint statuses, last_checkpoint}` — if that tuple doesn't move across N successful
  worker runs, the run is spinning and gets blocked rather than draining budget.
- **The lock is a `mkdir`** (atomic on every POSIX filesystem) stamped with the
  daemon's pid; stale locks from dead daemons are reaped automatically.

### 4. Agent adapters

One `case` statement maps `OCEAN_AGENT` to a worker invocation:

| Agent | Invocation | Permission mapping |
|---|---|---|
| `claude` | `claude -p "$prompt" <flags>` | `safe`→acceptEdits, `standard`→acceptEdits+allowedTools, `yolo`→skip-permissions |
| `codex` | `codex exec <flags> "$prompt"` | `safe`→workspace-write sandbox, `standard`→--full-auto, `yolo`→bypass |
| `gemini` | `gemini <flags> -p "$prompt"` | `safe`→auto_edit, `standard`/`yolo`→--yolo |
| `custom` | `bash -c "$OCEAN_WORKER_CMD"` with `$OCEAN_PROMPT` | yours |

Every worker gets `OCEAN_WORKER=1` and `OCEAN_DIR` in its environment (that's how the
Claude Stop hook distinguishes workers from humans; other agents simply ignore it).
Limit detection is a union of Claude/Codex/Gemini phrasings (`usage limit`,
`rate limit`, `429`, `quota exceeded`, `resource exhausted`, …).

### 5. The hooks (Claude Code)

- **Stop guard** (`ocean-stop-guard.sh`): when a *worker* session tries to end while
  the run is active and no checkpoint was written in the last
  `OCEAN_CHECKPOINT_GRACE` seconds, the stop is blocked once with instructions to
  commit + checkpoint + optionally block. It honors `stop_hook_active` so it can never
  loop, and it never fires for interactive sessions (`OCEAN_WORKER` unset).
- **Announcer** (`ocean-announce.sh`): SessionStart hook that prints a three-line
  notice about the active run — so a human opening the repo mid-run doesn't collide
  with the current sprint. Silent (zero context cost) when no run exists.

Other agents don't have hook systems, so these are *belt-and-braces* there rather than
enforced — the protocol file still instructs the checkpoint discipline, and the stall
detector catches workers that ignore it.

## The state machine

```
                 init
                  │
              ┌───▼────┐   plan-done    ┌─────────┐
              │planning├───────────────▶│ running │◀────────────┐
              └────────┘                └─┬─┬─┬───┘             │
                                          │ │ │                 │ unblock /
                        set-status        │ │ │ block           │ reopen
                        complete          │ │ └──────▶┌────────┐│
                       ┌──────────────────┘ │         │blocked ├┘
                       ▼                    │         └────────┘
                 ┌──────────┐  verify fails │
                 │ complete │───────────────┘ (reopen, ≤2)
                 └────┬─────┘
                      │ verify passes
                      ▼
                    done ✔        (paused / aborted: manual set-status, daemon exits)
```

## Worker lifecycle (one iteration)

1. Daemon builds the prompt: protocol path + state paths + resume instructions
   (override with `.ocean/prompt-override.md`).
2. Worker reads protocol → state → plan → decisions → `git log`.
3. Worker reconciles any uncommitted leftovers from a predecessor that died mid-edit.
4. Worker executes sprint work: tests → implementation → verify green → docs → commit
   → `sprint-done` → `checkpoint --notes "<next step>"`.
5. Worker exits (voluntarily on low context, or killed by the watchdog).
6. Daemon inspects the aftermath: log patterns, exit code, state fingerprint.

## Failure-mode coverage

| Failure | Detector | Response |
|---|---|---|
| Context exhaustion | worker exits | relaunch fresh |
| Usage/rate limit | log pattern match | sleep until reset timestamp, else exponential backoff |
| Worker hang | watchdog timeout | kill, relaunch |
| Worker crash-loop | consecutive-failure counter | block at `OCEAN_MAX_FAILURES` |
| No progress (spinning) | state fingerprint | block at `OCEAN_STALL_LIMIT` |
| False completion claim | verify gate | reopen (≤2), then block |
| Budget runaway | iteration counter | block at `OCEAN_MAX_ITERATIONS` |
| Corrupt state write | atomic mv | impossible by construction |
| Two daemons | mkdir lock | second exits immediately |
| Machine reboot | launchd KeepAlive | daemon respawns, resumes from state |
