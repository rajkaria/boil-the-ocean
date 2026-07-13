# boil-the-ocean — project notes for Claude Code

Autonomous multi-sprint execution harness for coding agents. Read `README.md` for the
product story; `docs/ARCHITECTURE.md` before touching `scripts/`; the worker protocol
is `skills/boil-ocean/SKILL.md` (protocol changes require a pressure-scenario re-test —
see CONTRIBUTING.md rule 4). Tests: `bash tests/test-ocean.sh` (offline, zero tokens).

## Current state (2026-07-13)

- v1.2.0 **released** — merged to `main` ff-only (tip `74941ec`), tag `v1.2.0` + GitHub
  release published, `.claude-plugin/marketplace.json` live on the default branch so
  `/plugin marketplace add rajkaria/boil-the-ocean` resolves (verified: default branch is
  main, manifest is valid JSON there, `source: "./"` → plugin.json v1.2.0). One-click
  plugin install: `/plugin marketplace add rajkaria/boil-the-ocean` +
  `/plugin install boil-the-ocean@boil-the-ocean` from inside Claude Code, no shell/clone;
  same manifest installs on Antigravity / Factory Droid / Copilot CLI. Plugin entry carries
  no version (inherits from plugin.json), so release checklist stays VERSION + plugin.json.
  86/86 tests (4 new in v1.2.0: marketplace.json validity + name/source resolution).
  CONTRIBUTING release checklist expanded (ff-to-main, tag+push, gh release,
  marketplace smoke-verify). Docs: README Install §, docs/agents/CLAUDE-CODE.md § Plugin
  mode, CHANGELOG.
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

1. **Registry submissions** (researched 2026-07-13; all are publishing actions needing
   Raj's interactive auth/consent — do not auto-submit):
   - **Anthropic community marketplace** (realistic official path): submit at
     `clau.de/plugin-directory-submission` (in-app claude.ai form) → automated security
     scan → lands in `anthropics/claude-plugins-community`, installable as
     `@claude-community`. The `anthropics/claude-plugins-official` directory is curated at
     Anthropic's discretion (partner-oriented, harder).
   - **Codex (OpenAI)**: Codex reads `.claude-plugin/marketplace.json` as a
     *legacy-compatible* path, so `codex plugin marketplace add rajkaria/boil-the-ocean`
     should work against the shipped manifest with **zero changes** — needs a real-CLI
     smoke test to confirm, then add Codex to README's plugin-install list. Self-serve
     publishing to the official Codex directory is "coming soon" (not open as of mid-2026);
     community list = PR to `hashgraph-online/awesome-codex-plugins`.
   - **Cursor**: uses a **separate** `.cursor-plugin/marketplace.json` + `.cursor-plugin/
     plugin.json` format (skills still `skills/SKILL.md`, rules `.mdc`, MCP `mcp.json`).
     NOT compatible out of the box — needs a parallel `.cursor-plugin/` manifest (an
     adapter). Publish at `cursor.com/marketplace/publish`.
   - Low-effort discoverability PRs: `ComposioHQ/awesome-claude-plugins`,
     `quemsah/awesome-claude-plugins`; independent dirs claudepluginhub.com /
     claudemarketplaces.com.
2. Dogfood a real run: `examples/todo-api-spec.md` in a scratch repo, `OCEAN_AGENT=claude`.
3. burn-rate README cross-link section (spend-less / spend-to-finish siblings).
4. First-class adapters for aider / opencode / cursor-agent (recipe: docs/agents/CUSTOM.md § adding a first-class adapter).
5. Windows/PowerShell support (open contribution).
