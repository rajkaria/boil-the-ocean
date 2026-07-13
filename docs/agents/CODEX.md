# Boil the Ocean on OpenAI Codex CLI

Codex workers run through `codex exec` (Codex's non-interactive mode). The protocol
file does the behavioral work — no Codex-side plugin system needed.

## Install

No clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/rajkaria/boil-the-ocean/main/install.sh | bash -s -- codex
```

Or from a clone:

```bash
git clone https://github.com/rajkaria/boil-the-ocean.git
cd boil-the-ocean
./install.sh codex
```

What this does:

| Piece | Where | What you get |
|---|---|---|
| Pointer block | `~/.codex/AGENTS.md` | Four lines teaching every Codex session: repos with `.ocean/state.json` have an active run; the protocol file is binding; state mutates only via `ocean.sh` |
| CLI | `~/.local/bin/` | `ocean`, `ocean-daemon` |

The pointer is deliberately tiny (AGENTS.md loads into every session — tokens are
rent). It exists so *interactive* Codex sessions respect a run in progress; the
daemon's workers get the full protocol through their launch prompt regardless.

## Usage

```bash
cd your-project
ocean init docs/SPEC.md --verify-cmd "pytest -q" --goal "ship v1"
OCEAN_AGENT=codex ocean-daemon doctor     # preflight: checks the codex binary too
OCEAN_AGENT=codex ocean-daemon start
```

Watch: `ocean-daemon logs` · Stop: `ocean-daemon stop` · Sprint table: `ocean status`.

## Permission mapping

| `OCEAN_PERMISSIONS` | Codex flags | Meaning |
|---|---|---|
| `safe` | `--sandbox workspace-write` | Sandboxed writes inside the workspace, no network |
| `standard` *(default)* | `--full-auto` | Workspace-write sandbox with full autonomy — the sweet spot |
| `yolo` | `--dangerously-bypass-approvals-and-sandbox` | No sandbox at all — container/VM only |

Codex's own sandbox is a genuine advantage here: `standard` gives you an
OS-level-sandboxed autonomous worker, which is a stronger default posture than most
agents can offer.

## Codex-specific configuration

| Var | Notes |
|---|---|
| `OCEAN_CODEX_BIN` | Binary name/path (default `codex`) |
| `OCEAN_MODEL` | Passed as `-m` (e.g. `o4-mini` for cheap sprints, a stronger model for fix passes) |
| `OCEAN_EXTRA_FLAGS` | Anything else `codex exec` accepts (e.g. `--profile work`) |

Limit handling: Codex's rate-limit / quota phrasings (`rate limit`, `429`,
`insufficient_quota`, …) are detected and trigger exponential backoff
(`OCEAN_BACKOFF_BASE` → `OCEAN_BACKOFF_MAX`).

## Notes and caveats

- **No Stop hook on Codex** — the checkpoint discipline is enforced by the protocol
  text and backstopped by the daemon's stall detector, which blocks a run whose
  workers exit without moving state. In practice `codex exec` runs to task completion
  rather than stopping early, so this matters less than it sounds.
- **Mixed fleets work**: state is agent-agnostic. It's perfectly fine to run planning
  with Claude, sprints with Codex, and a final fix pass with either — set
  `OCEAN_AGENT` per daemon start.
- **AGENTS.md in the project**: if your repo has its own `AGENTS.md`, nothing
  conflicts — the pointer lives in the global `~/.codex/AGENTS.md` and only describes
  how to treat `.ocean/`.
