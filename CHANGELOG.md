# Changelog

All notable changes to boil-the-ocean are documented here. Format:
[Keep a Changelog](https://keepachangelog.com); versioning: [SemVer](https://semver.org).

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
