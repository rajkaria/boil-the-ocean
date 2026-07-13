# Boil the Ocean on Claude Code

Claude Code is the richest integration: native skill triggering, slash commands, and
two lifecycle hooks that enforce the protocol mechanically.

## Install

No clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/rajkaria/boil-the-ocean/main/install.sh | bash -s -- claude
```

Or from a clone:

```bash
git clone https://github.com/rajkaria/boil-the-ocean.git
cd boil-the-ocean
./install.sh          # default target is claude
```

What this does (all symlinks → your clone; `git pull` upgrades in place):

| Piece | Where | What you get |
|---|---|---|
| Skill | `~/.claude/skills/boil-ocean` | Auto-triggers on "boil the ocean", "build the whole spec", "do all the sprints", or resuming a repo with `.ocean/state.json` |
| Commands | `~/.claude/commands/` | `/ocean <spec>`, `/ocean-status`, `/ocean-stop` |
| Scripts | `~/.claude/scripts/` | `ocean.sh`, `ocean-daemon.sh` + the two hook scripts |
| Hooks | `~/.claude/settings.json` | `Stop` → checkpoint guard, `SessionStart` → run announcer (idempotent merge, python3-validated) |
| CLI | `~/.local/bin/` | `ocean`, `ocean-daemon` |

### Plugin mode (alternative)

The repo is also a valid Claude Code **plugin**: `.claude-plugin/plugin.json` +
`hooks/hooks.json` use `${CLAUDE_PLUGIN_ROOT}`, so adding this repo through any plugin
marketplace flow wires commands, skill, and hooks without `install.sh`. You still want
`./install.sh bin` for the `ocean` / `ocean-daemon` CLI.

## Usage

### Interactive start (watch the plan happen)

```
claude
> /ocean docs/SPEC.md
```

The session plans all sprints, commits the plan, starts sprint 1, and reminds you
once to start the scheduler. Then, from another terminal:

```bash
ocean-daemon start
```

### Fully headless start

```bash
ocean init docs/SPEC.md --verify-cmd "npm test" --goal "ship v1"
ocean-daemon doctor      # preflight
ocean-daemon start
```

The first worker does the planning; subsequent workers execute sprints.

## How the hooks behave

- **Stop guard** (`ocean-stop-guard.sh`): fires **only** in daemon-launched worker
  sessions (they carry `OCEAN_WORKER=1`). If a worker tries to end its session while
  the run is `planning`/`running` and no checkpoint is younger than
  `OCEAN_CHECKPOINT_GRACE` (default 300 s), the stop is blocked once, with the exact
  commands to commit + checkpoint + optionally block. `stop_hook_active` is honored,
  so it can never loop. **Your interactive sessions are never blocked.**
- **Announcer** (`ocean-announce.sh`): every session that starts in a repo with an
  active run gets a three-line notice — run id, status, sprints done, latest handoff
  notes — so you don't accidentally duplicate the current sprint's work. Silent
  otherwise.

Disable the guard for one session: `OCEAN_GUARD_DISABLED=1`.

## Claude-specific configuration

| Setting | Notes |
|---|---|
| `OCEAN_PERMISSIONS=safe` | `--permission-mode acceptEdits` — headless Bash mostly denied; docs-only specs |
| `OCEAN_PERMISSIONS=standard` *(default)* | `acceptEdits` + `--allowedTools Bash,Edit,Write,Read,Glob,Grep,TodoWrite,Task,WebFetch,WebSearch,NotebookEdit` |
| `OCEAN_PERMISSIONS=yolo` | `--dangerously-skip-permissions` — container/VM territory |
| `OCEAN_MODEL` | Passed as `--model` (e.g. `claude-sonnet-5` for cheap sprints) |
| `OCEAN_EXTRA_FLAGS` | Anything else `claude -p` accepts |

Usage-limit handling: Claude Code's limit messages (including the embedded reset
timestamp, when present) are parsed; the daemon sleeps until the reset and retries.

## Tips

- **Worktrees**: run oceans in a dedicated `git worktree` — the run gets a clean
  blast radius and your main checkout stays interactive.
- **Sibling project**: [burn-rate](https://github.com/rajkaria/burn-rate) monitors
  interactive session cost; ocean workers show up in its history as small,
  cache-friendly sessions — the two were built to compose.
- `/ocean-status` inside a session gives you the human summary + last decisions
  without leaving Claude.
