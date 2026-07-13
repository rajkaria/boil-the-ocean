# Changelog

All notable changes to boil-the-ocean are documented here. Format:
[Keep a Changelog](https://keepachangelog.com); versioning: [SemVer](https://semver.org).

## [1.2.0] — 2026-07-13

One-click plugin install — no shell, no clone.

### Added

- **`.claude-plugin/marketplace.json`**: the repo is now its own one-plugin
  marketplace. From inside Claude Code, `/plugin marketplace add rajkaria/boil-the-ocean`
  then `/plugin install boil-the-ocean@boil-the-ocean` wires the skill, the `/ocean*`
  commands, and both hooks — updated in place on re-install, no `install.sh` needed.
- **Cross-agent plugin install**: the same manifest installs on every agent that speaks
  the Claude Code plugin-marketplace protocol — Antigravity (`agy plugin install <url>`),
  Factory Droid, GitHub Copilot CLI. Documented in the README and
  `docs/agents/CLAUDE-CODE.md`.
- **Marketplace test coverage** (4 new tests, 86 total): `marketplace.json` is valid
  JSON, its name and plugin entry match the plugin, and its `source: "./"` resolves to a
  real `plugin.json`.

### Notes

- The plugin carries no separate version — its entry inherits from `plugin.json`, so the
  release checklist stays VERSION + plugin.json in lockstep.

## [1.1.0] — 2026-07-13

Installation overhaul — one-liner install, agent auto-detection, self-upgrade.
(Prior art studied: [gstack](https://github.com/garrytan/gstack)'s setup/update-check
machinery, adapted to this project's zero-dependency-bash philosophy.)

### Added

- **Curl-pipe bootstrap**: `curl -fsSL …/install.sh | bash` now works with no clone —
  `install.sh` detects it's running outside a repo, clones to `~/.boil-the-ocean`
  (override: `OCEAN_HOME`, `OCEAN_REPO_URL`), and hands off to the clone's installer.
- **`./install.sh auto`**: detects which agent CLIs are on the machine (Claude Code
  via `~/.claude`, `codex`, `gemini` via PATH) and installs for every one found;
  falls back to the bare `ocean` CLI when none are.
- **`VERSION` file + `ocean version [--check]`**: `--check` compares against the
  repo's live `main` (HEAD-SHA-pinned raw fetch so a stale CDN can't lie, 5-second
  ceilings, offline-safe, `OCEAN_UPDATE_CHECK=off` to disable). Dev clones running
  ahead of `main` correctly report "up to date", not a downgrade prompt.
- **`ocean upgrade`**: fast-forward pulls the clone and replays `install.sh` for every
  target recorded at install time (`~/.local/state/boil-the-ocean/installed-targets`),
  so files added by a new version get linked without manual steps.
- **Doctor additions**: warns when `~/.local/bin` is missing from PATH; prints a
  one-line `INFO` when an update is available (never fails the preflight).
- **Installer test coverage** (28 new tests, 82 total): full `install.sh auto` +
  `uninstall.sh` round-trip against a fake `$HOME`, curl-style bootstrap with a mocked
  `git`, `ocean upgrade` replay, idempotency, and the whole `version --check` matrix
  (equal / newer / older / garbage / disabled) via `file://` remotes — still fully
  offline.

### Changed

- `uninstall.sh` also removes the recorded-targets state dir and explains what is
  deliberately kept (per-project `.ocean/`, the clone itself).
- `ocean version` / `ocean upgrade` work without `jq` (it's a runtime dependency, not
  an install dependency).
- README install section rewritten around the one-liner, a paste-to-your-agent
  install block, and an upgrade/uninstall section including no-clone manual removal.

## [1.0.0] — 2026-07-13

Initial public release. 🌊

### Added

- **The protocol** (`skills/boil-ocean/SKILL.md`): autonomous multi-sprint execution
  contract — plan-everything-once, one commit per sprint, verify-before-done, a
  decision protocol with journal (two-way vs one-way doors, only-stop list), checkpoint
  discipline, rationalization table + red flags. Doubles as a native Claude Code skill
  and the binding instruction file for every other agent.
- **State manager** (`scripts/ocean.sh`): atomic-write JSON state, validated
  transitions, human-readable `status`, full lifecycle (`init`, `sprint-*`,
  `checkpoint`, `block`/`unblock`/`reopen`, `stop`).
- **Scheduler** (`scripts/ocean-daemon.sh`): relaunches fresh headless workers until
  the run completes; usage-limit detection with reset-timestamp parsing and
  exponential backoff; watchdog iteration timeout; consecutive-failure cap; state-
  fingerprint stall detection; iteration budget guard; independent verify gate with
  bounded reopens; per-sprint + terminal notifications (`OCEAN_NOTIFY_CMD` + native
  macOS); `doctor` preflight; launchd install for reboot survival; `once` mode for
  cron/systemd.
- **Multi-agent adapters**: Claude Code (`claude -p`), OpenAI Codex CLI
  (`codex exec`), Gemini CLI (`gemini -p`), and a `custom` adapter contract
  (`OCEAN_WORKER_CMD` + `$OCEAN_PROMPT`) for any headless agent. Unified
  `safe`/`standard`/`yolo` permission model mapped per agent.
- **Claude Code integration**: `/ocean`, `/ocean-status`, `/ocean-stop` commands;
  Stop-hook checkpoint guard (workers only, loop-safe); SessionStart run announcer;
  plugin manifest (`.claude-plugin/`) for marketplace installs.
- **Installer** (`install.sh claude|codex|gemini|bin|all`): symlink-based, idempotent,
  with AGENTS.md/GEMINI.md pointer blocks and `ocean`/`ocean-daemon` CLI on PATH.
- **Tests**: 53 offline integration tests (mock agent binary — zero tokens), covering
  state lifecycle, the full daemon loop, all adapters, both hooks, and doctor. CI on
  macOS + Ubuntu.
- **Docs**: architecture, configuration reference with recipes, state schema,
  per-agent guides (Claude Code / Codex / Gemini / custom), troubleshooting, example
  spec.
