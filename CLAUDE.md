# boil-the-ocean — project notes for Claude Code

Autonomous multi-sprint execution harness for coding agents. Read `README.md` for the
product story; `docs/ARCHITECTURE.md` before touching `scripts/`; the worker protocol
is `skills/boil-ocean/SKILL.md` (protocol changes require a pressure-scenario re-test —
see CONTRIBUTING.md rule 4). Tests: `bash tests/test-ocean.sh` (offline, zero tokens).

## Current state (2026-07-13)

- v1.2.0 committed + pushed to branch `claude/optimistic-dijkstra-ca3530` (NOT yet merged
  to main — marketplace goes live only once `.claude-plugin/marketplace.json` is on the
  default branch): one-click plugin install. Added `.claude-plugin/marketplace.json` so
  the repo is its own
  one-plugin marketplace — `/plugin marketplace add rajkaria/boil-the-ocean` +
  `/plugin install boil-the-ocean@boil-the-ocean` from inside Claude Code, no shell/clone;
  same manifest installs on Antigravity / Factory Droid / Copilot CLI. Plugin entry carries
  no version (inherits from plugin.json), so release checklist stays VERSION + plugin.json.
  86/86 tests (4 new: marketplace.json validity + name/source resolution). Docs: README
  Install §, docs/agents/CLAUDE-CODE.md § Plugin mode, CHANGELOG.
- v1.1.0 shipped to prod (commit `418fcb5` on main, tag + GitHub release published):
  installation overhaul modeled on gstack (github.com/garrytan/gstack) — curl-pipe
  bootstrap, `install.sh auto` agent detection, `VERSION` + `ocean version --check`
  (HEAD-SHA-pinned raw fetch, offline-safe, bash-3.2 semver compare since BSD sort lacks
  -V), `ocean upgrade` (ff-only pull + replay of recorded install targets), doctor
  PATH/update checks. Deliberately NOT adopted from gstack: telemetry, snooze, team mode.
- v1.0.0 shipped: https://github.com/rajkaria/boil-the-ocean — tag + GitHub release
  published, CI green on macOS + Ubuntu.
- Installed on this machine: `ocean` / `ocean-daemon` at `~/.local/bin` (symlinks to
  this clone); `ocean-daemon doctor` passes clean.
- Born in burn-rate (branch `claude/boil-ocean-skill-baa5ea`), fully extracted — no
  references remain in that repo's files.

## Key decisions

- **SKILL.md doubles as the agent-agnostic protocol** — workers on any CLI are told
  "read this file and follow it"; multi-agent support needed zero behavioral porting.
- **Fresh worker per iteration, never `--resume`** — state lives in `.ocean/`,
  mutated only via `ocean.sh` atomic writes; checkpoint notes are the inter-worker contract.
- **Deliberate daemon exits are exit-code 0** so launchd/systemd KeepAlive respawns
  crashes only, never complete/blocked/stopped runs.
- **Unified safe/standard/yolo permissions** mapped per agent (Gemini's standard ==
  yolo — its CLI has only two approval levels; documented honestly).
- Name kept **"boil the ocean"** (Manthan / Samudra Manthan was runner-up).

## Next steps

1. Merge v1.2.0 to main + tag (release checklist in CONTRIBUTING.md); the marketplace
   only works once `.claude-plugin/marketplace.json` is on the default branch.
2. Dogfood a real run: `examples/todo-api-spec.md` in a scratch repo, `OCEAN_AGENT=claude`.
3. burn-rate README cross-link section (spend-less / spend-to-finish siblings).
4. Submit to central plugin registries (Anthropic official marketplace, Cursor, Codex) so
   `/add-plugin` / search flows work without adding the repo by URL first.
5. First-class adapters for aider / opencode / cursor-agent (recipe: docs/agents/CUSTOM.md § adding a first-class adapter).
6. Windows/PowerShell support (open contribution).
