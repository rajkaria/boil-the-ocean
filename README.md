# Boil the Ocean 🌊

**Hand your AI agent an entire spec and walk away. Come back to shipped, tested, documented work.**

Boil the Ocean turns "don't boil the ocean" on its head: it is an autonomous
multi-sprint execution harness for coding agents — **Claude Code, OpenAI Codex,
Gemini CLI, or any headless agent CLI** — that plans a whole spec once, executes it
sprint by sprint with tests and commits, takes every decision itself *on the record*,
and keeps a scheduler running that relaunches fresh agent sessions whenever a context
window fills or a usage limit hits — until the work is **done and independently
verified**.

```
you:    "Here's the spec. Build all of it. Don't stop until it's done."
ocean:  plans 6 sprints → ships sprint 1 → hits a session limit → relaunches →
        ships sprints 2–6 → survives a usage-limit window → runs your test suite
        as a final gate → writes a report of everything it decided → notifies you.
```

---

## Table of contents

- [Why this exists](#why-this-exists)
- [How it works](#how-it-works)
- [Install](#install)
  - [Claude Code](#claude-code)
  - [OpenAI Codex CLI](#openai-codex-cli)
  - [Gemini CLI](#gemini-cli)
  - [Any other agent](#any-other-agent)
- [Quickstart](#quickstart)
- [A run, end to end](#a-run-end-to-end)
- [Session limits are the whole point](#session-limits-are-the-whole-point)
- [The decision protocol](#the-decision-protocol)
- [Permission modes — read this before unattended runs](#permission-modes--read-this-before-unattended-runs)
- [Configuration](#configuration)
- [The paper trail](#the-paper-trail)
- [Watching and controlling a run](#watching-and-controlling-a-run)
- [Safety model](#safety-model)
- [Cost](#cost)
- [FAQ](#faq)
- [Documentation index](#documentation-index)

---

## Why this exists

Big tasks die in single agent sessions for three predictable reasons:

1. **Scope-flinching.** Ask for everything, and the agent proposes "let's start with a
   scoped sprint 1 and see how it goes." You didn't ask for a negotiation.
2. **Decision stalls.** The run halts at 2 a.m. to ask you *Postgres or SQLite?* By
   morning you've paid for an idle night and still have to answer.
3. **Session limits.** The context window fills, or the usage window closes, and the
   work evaporates with the conversation that held it.

Boil the Ocean fixes all three structurally, not with vibes:

| Failure | Fix |
|---|---|
| Scope-flinching | A written contract ([SKILL.md](skills/boil-ocean/SKILL.md)) that defines scoping down as failure, with a rationalization table targeting the exact excuses agents make |
| Decision stalls | A decision protocol: decide → journal it in `DECISIONS.md` → move on. A short *only-stop list* covers the calls that genuinely need a human |
| Session limits | The run's memory is a directory (`.ocean/`), not a conversation. A scheduler relaunches fresh workers until the state file says `complete` — and a verify gate makes sure `complete` is true |

## How it works

```
            ┌────────────────────────── .ocean/ (the run's ONLY memory) ─────┐
            │ state.json   PLAN.md   DECISIONS.md   SPEC.md   REPORT.md      │
            └───────▲──────────────────────────────────────────▲─────────────┘
                    │ ocean.sh (atomic writes)                  │ reads
┌───────────┐   ┌───┴────────┐  relaunch on exit  ┌─────────────┴──────────┐
│ launchd / │──▶│ ocean-     │───────────────────▶│ fresh worker session   │
│ cron      │   │ daemon.sh  │◀───────────────────│ claude -p / codex exec │
│ (optional)│   │ scheduler  │  limit? → backoff  │ gemini -p / custom     │
└───────────┘   └────────────┘  stall? → block    └────────────────────────┘
```

Four pieces, each doing one job:

- **The protocol** ([skills/boil-ocean/SKILL.md](skills/boil-ocean/SKILL.md)) governs
  behavior *inside* each session: plan everything once, one commit per sprint, tests
  green before "done", every decision journaled, checkpoint before every exit. On
  Claude Code it's a native skill; on every other agent, each worker is told to read
  and follow the file — same protocol, zero per-agent porting.
- **The state manager** ([scripts/ocean.sh](scripts/ocean.sh)) is the only writer of
  `state.json` — every mutation is an atomic write, so a worker killed mid-session can
  never corrupt the run.
- **The scheduler** ([scripts/ocean-daemon.sh](scripts/ocean-daemon.sh)) loops fresh
  headless workers until the run is `complete` or `blocked`. It detects usage/rate
  limits (parsing the reset timestamp when the CLI provides one), backs off, retries,
  detects stalls, caps iterations, and independently re-runs your test command before
  accepting completion.
- **The hooks** (Claude Code only, optional elsewhere): a `Stop` hook prevents a worker
  from ending its session without writing a handoff checkpoint; a `SessionStart` hook
  announces an active run to any session that opens the repo.

A deeper walkthrough lives in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install

```bash
git clone https://github.com/rajkaria/boil-the-ocean.git
cd boil-the-ocean
```

Requirements: `bash`, `git`, `jq` (macOS ships it; Linux: `apt install jq`), and at
least one agent CLI. Every install is a symlink to your clone — `git pull` upgrades in
place. `./uninstall.sh` removes everything cleanly.

### Claude Code

```bash
./install.sh            # skill + /ocean commands + hooks + `ocean` CLI
```

Richest integration: native skill triggering ("boil the ocean", "build the whole
spec"), `/ocean`, `/ocean-status`, `/ocean-stop` slash commands, the Stop-hook
checkpoint guard, and the SessionStart announcer. The repo also works directly as a
Claude Code **plugin** (`.claude-plugin/` + `hooks/hooks.json` are wired for
`CLAUDE_PLUGIN_ROOT`). Details: [docs/agents/CLAUDE-CODE.md](docs/agents/CLAUDE-CODE.md).

### OpenAI Codex CLI

```bash
./install.sh codex      # ~/.codex/AGENTS.md pointer + `ocean` CLI
```

Workers run via `codex exec` with sandbox flags mapped from `OCEAN_PERMISSIONS`. The
installer appends a four-line pointer to `~/.codex/AGENTS.md` so interactive Codex
sessions recognize active runs too. Details: [docs/agents/CODEX.md](docs/agents/CODEX.md).

### Gemini CLI

```bash
./install.sh gemini     # ~/.gemini/GEMINI.md pointer + `ocean` CLI
```

Workers run via `gemini -p` with approval flags mapped from `OCEAN_PERMISSIONS`.
Details: [docs/agents/GEMINI-CLI.md](docs/agents/GEMINI-CLI.md).

### Any other agent

```bash
./install.sh bin        # just the `ocean` + `ocean-daemon` CLI
```

Then point the daemon at any headless agent command — the prompt arrives in
`$OCEAN_PROMPT`:

```bash
OCEAN_AGENT=custom \
OCEAN_WORKER_CMD='my-agent --autonomous "$OCEAN_PROMPT"' \
ocean-daemon start
```

If it can read files, run shell commands, and be launched headlessly, it can boil the
ocean. Details: [docs/agents/CUSTOM.md](docs/agents/CUSTOM.md).

## Quickstart

From any project root (60 seconds, three commands):

```bash
# 1. Initialize the run: point at a spec, set the independent verification command
ocean init docs/SPEC.md --verify-cmd "npm test" --goal "ship v1 of the API"

# 2. Preflight — checks agent binary, git, jq, state, verify command
ocean-daemon doctor

# 3. Release the daemon (default agent: claude; or OCEAN_AGENT=codex / gemini)
ocean-daemon start
```

Optionally, survive reboots too:

```bash
ocean-daemon install-launchd     # macOS; Linux: see cron/systemd recipe below
```

Prefer starting inside an interactive Claude Code session? `/ocean docs/SPEC.md` does
the planning in front of you, then `ocean-daemon start` takes over. Try it on the
included [examples/todo-api-spec.md](examples/todo-api-spec.md) first.

## A run, end to end

What actually happens after `ocean-daemon start`:

1. **Planning worker** (status `planning`): reads the spec and codebase once, writes
   `.ocean/PLAN.md` — 3–10 sprints, each with goal, files, acceptance criteria —
   registers them in state, commits the plan, starts sprint 1.
2. **Sprint workers** (status `running`): each fresh worker reads
   `state.json` + `PLAN.md` + `DECISIONS.md` + `git log`, continues exactly where the
   checkpoint notes say, writes tests, implements, gets the verify command green,
   commits `ocean(spN): <title>`, marks the sprint done, checkpoints a one-line
   handoff for the next worker.
3. **Limits hit** — context fills or the usage window closes: worker checkpoints and
   exits; the daemon relaunches (immediately, or after the limit's reset time).
   Nothing is lost, because nothing lived in the conversation.
4. **Completion** (status `complete`): the last worker runs the full sweep — verify
   command, build, spec re-read for unaccounted items — and writes `.ocean/REPORT.md`.
5. **The verify gate**: the daemon *independently* runs your `--verify-cmd`. Green →
   you get a notification. Red → the run reopens for a fix pass (twice max, then it
   blocks for a human instead of looping forever).
6. **You, next morning**: read `REPORT.md` (what shipped, sprint → commit), skim
   `DECISIONS.md` (everything it chose and why), `git log` (one commit per sprint).

## Session limits are the whole point

| Limit | What happens |
|---|---|
| Context window fills | Worker checkpoints (on Claude Code the Stop hook enforces it), exits; daemon relaunches a fresh session that reads `.ocean/` and continues |
| Usage / rate limit | Daemon parses the reset timestamp from CLI output when available, otherwise backs off exponentially (`OCEAN_BACKOFF_BASE` → `OCEAN_BACKOFF_MAX`), then retries. Claude, Codex, and Gemini limit phrasings are all detected |
| Machine reboots / daemon crash | `install-launchd` registers a KeepAlive agent (macOS). Deliberate exits — complete, blocked, stopped — do **not** respawn. Linux: cron/systemd + `ocean-daemon once` |
| Worker hangs | `OCEAN_ITERATION_TIMEOUT` (default 2h) kills it; the daemon relaunches |
| Workers spin without progress | Stall detector compares state fingerprints across iterations and blocks the run instead of burning tokens forever |
| Runaway run | `OCEAN_MAX_ITERATIONS` (default 50) hard-caps total worker launches |

## The decision protocol

The part that makes unattended runs actually finish. Full text in
[SKILL.md](skills/boil-ocean/SKILL.md); the shape:

- **Two-way doors** (reversible — naming, internal structure): decide instantly,
  one-line journal entry.
- **One-way doors** (schemas, public APIs, storage formats): decide by fixed
  principles — spec intent first, then user workflow over implementation convenience,
  then reversibility, then boring-over-clever — with a full journal entry: options,
  choice, rationale, cost to reverse.
- **Only-stop list** — the run blocks and waits for a human ONLY for: destroying data
  that can't be regenerated, spending money, publishing/sending anything externally,
  needing credentials, or legal/safety concerns. Everything else is pre-authorized.

Every decision lands in `.ocean/DECISIONS.md`, and one-way doors are re-flagged in the
final `REPORT.md` — so "it decided alone" never means "it decided silently."

## Permission modes — read this before unattended runs

Headless workers can't answer permission prompts, so `OCEAN_PERMISSIONS` picks one of
three levels, mapped per agent:

| Mode | Claude Code | Codex | Gemini CLI | Trade-off |
|---|---|---|---|---|
| `safe` | `--permission-mode acceptEdits` | `--sandbox workspace-write` | `--approval-mode auto_edit` | Edits only; most shell is blocked. Docs/refactor specs — too weak to run tests |
| `standard` *(default)* | `acceptEdits` + `--allowedTools Bash,Edit,…` | `--full-auto` | `--yolo` | Can build/test/commit. Shell access is broad — trust the repo |
| `yolo` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `--yolo` | Everything. Sandbox or container it |

**This tool executes many sessions unattended. Run it in a repo you trust, ideally in
a dedicated worktree, VM, or container.** More in [Safety model](#safety-model).

## Configuration

Everything is an environment variable — export before `ocean-daemon start`, or bake
into the launchd install. The complete reference with recipes (Telegram notifications,
model routing, budget tuning) is [docs/CONFIGURATION.md](docs/CONFIGURATION.md).
The ones you'll actually touch:

| Env var | Default | Meaning |
|---|---|---|
| `OCEAN_AGENT` | `claude` | `claude` \| `codex` \| `gemini` \| `custom` |
| `OCEAN_PERMISSIONS` | `standard` | `safe` \| `standard` \| `yolo` |
| `OCEAN_MODEL` | *(agent default)* | Model override, mapped to each CLI's flag |
| `OCEAN_MAX_ITERATIONS` | `50` | Hard cap on worker launches per run |
| `OCEAN_NOTIFY_CMD` | *(none)* | Command run with the message as `$1` — Telegram, ntfy, Slack webhook… |
| `OCEAN_WORKER_CMD` | *(none)* | Custom agent command template (`OCEAN_AGENT=custom`) |

## The paper trail

Every run is designed to be auditable the morning after:

| Artifact | What it tells you |
|---|---|
| `.ocean/REPORT.md` | What shipped (sprint → commit), decisions worth review, known limitations |
| `.ocean/DECISIONS.md` | Every autonomous decision; one-way doors with options, rationale, reversal cost |
| `.ocean/PLAN.md` | The sprint plan the run executed against |
| `.ocean/state.json` | Machine state — schema in [docs/STATE.md](docs/STATE.md) |
| `.ocean/logs/iter-NNN.log` | Full output of every worker session |
| `.ocean/logs/daemon.log` | The scheduler's view: launches, limits, backoffs, gates |
| `git log` | One commit per sprint (`ocean(spN): …`), plus the plan commit |

Commit `.ocean/` to the repo — it's the run's audit trail, and it's how a teammate (or
a future run) understands what happened.

## Watching and controlling a run

```bash
ocean-daemon status        # daemon liveness + sprint table
ocean-daemon logs          # follow the scheduler log
ocean status               # sprint table only (any time, no daemon needed)
ocean-daemon stop          # graceful: current worker finishes, then daemon exits
ocean-daemon stop --now    # immediate kill
ocean stop                 # same graceful stop via STOP file
```

Inside Claude Code: `/ocean-status` and `/ocean-stop`. A blocked run tells you exactly
why (`ocean status` prints blockers verbatim); fix or decide, then
`ocean unblock && ocean-daemon start`.

For phone-distance monitoring, set `OCEAN_NOTIFY_CMD` — you'll get a ping per finished
sprint, plus completion/blocked alerts. macOS additionally gets native notifications
automatically.

## Safety model

- **Blast radius**: workers run with the permission mode you chose, in the project
  directory. Prefer a dedicated git worktree, VM, or container for `standard`/`yolo`.
- **The only-stop list** hard-stops the run for destructive/external/spending actions —
  it blocks and waits for a human rather than guessing.
- **Everything is written down**: decisions, logs, commits. `git revert` un-does any
  sprint; `DECISIONS.md` tells you what to revisit.
- **Bounded by construction**: iteration cap, stall detection, failure cap, watchdog
  timeout. There is no code path where the daemon runs forever without progress.
- **Interactive sessions are never blocked**: the Stop guard only fires for the
  daemon's own workers (keyed on `OCEAN_WORKER=1`), never for you.

## Cost

An ocean run is bounded by `OCEAN_MAX_ITERATIONS × (one focused session)`. In practice
fresh small-context workers are dramatically cheaper per unit of shipped work than one
endless conversation, because each session starts from a ~2 KB state file instead of a
multi-megabyte transcript. Pair with [burn-rate](https://github.com/rajkaria/burn-rate)
(this project's sibling: it makes interactive sessions cheap; this makes unattended
runs finish) to see the numbers per session.

## FAQ

**Can I open the repo interactively during a run?**
Yes. The SessionStart hook announces the run (Claude Code), and interactive sessions
are never stop-blocked. Just avoid editing the current sprint's files.

**A worker made a bad call.**
It's journaled with rationale. `ocean-daemon stop`, `git revert` the sprint commit,
add a constraint line to `PLAN.md`, `ocean unblock` if needed, `ocean-daemon start`.

**Can different agents work the same run?**
Yes — state is agent-agnostic. Start with Codex, finish with Claude:
`OCEAN_AGENT` is read at daemon start. One daemon at a time, though (lock-enforced).

**What if the spec is ambiguous?**
That's what the decision protocol is for. Ambiguity → decision + journal entry, not a
3 a.m. question. If it's genuinely on the only-stop list, the run blocks and notifies.

**Windows?**
Via WSL. Native PowerShell support is a welcome contribution.

**More questions** → [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Documentation index

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, state machine, worker lifecycle, design decisions |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every env var, with recipes |
| [docs/STATE.md](docs/STATE.md) | `state.json` schema + the `.ocean/` file formats |
| [docs/agents/CLAUDE-CODE.md](docs/agents/CLAUDE-CODE.md) | Claude Code install, plugin mode, hooks |
| [docs/agents/CODEX.md](docs/agents/CODEX.md) | Codex CLI install, sandbox mapping |
| [docs/agents/GEMINI-CLI.md](docs/agents/GEMINI-CLI.md) | Gemini CLI install, approval mapping |
| [docs/agents/CUSTOM.md](docs/agents/CUSTOM.md) | Adapter contract for any agent |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Blocked runs, stalls, permissions, log forensics |
| [skills/boil-ocean/SKILL.md](skills/boil-ocean/SKILL.md) | The worker protocol itself |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Dev setup, test suite, adding agent adapters |

## Development

```bash
bash tests/test-ocean.sh   # 53 offline tests — mock agent binaries, zero tokens
```

CI runs the suite on macOS and Ubuntu on every push.

## License

MIT © [rajkaria](https://github.com/rajkaria)
