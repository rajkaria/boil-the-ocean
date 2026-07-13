# Configuration reference

Everything is an environment variable. Set them by exporting before any
`ocean-daemon` command:

```bash
OCEAN_AGENT=codex OCEAN_PERMISSIONS=standard ocean-daemon start
```

For a launchd install, export **before** `install-launchd` — the generated plist
captures your PATH; other `OCEAN_*` values should be exported in the shell that runs
`install-launchd` *and* are read fresh by the daemon each loop, so the simplest
persistent approach is an `.ocean/env` pattern (see Recipes).

## Agent selection

| Var | Default | Meaning |
|---|---|---|
| `OCEAN_AGENT` | `claude` | Which adapter to use: `claude`, `codex`, `gemini`, `custom` |
| `OCEAN_CLAUDE_BIN` | `claude` | Claude Code binary (or absolute path) |
| `OCEAN_CODEX_BIN` | `codex` | Codex CLI binary |
| `OCEAN_GEMINI_BIN` | `gemini` | Gemini CLI binary |
| `OCEAN_WORKER_CMD` | *(empty)* | `custom` only: shell command; the worker prompt arrives in `$OCEAN_PROMPT` |
| `OCEAN_MODEL` | *(agent default)* | Model override — mapped to `--model` (claude), `-m` (codex, gemini) |
| `OCEAN_EXTRA_FLAGS` | *(empty)* | Extra flags appended verbatim to the worker command |

## Permissions

| Var | Default | Meaning |
|---|---|---|
| `OCEAN_PERMISSIONS` | `standard` | `safe` / `standard` / `yolo` — per-agent mapping in the README table |

Rule of thumb: `safe` for docs/refactor-only specs, `standard` for normal development
in a trusted repo, `yolo` only inside a container/VM.

## Budget and resilience

| Var | Default | Meaning |
|---|---|---|
| `OCEAN_MAX_ITERATIONS` | `50` | Hard cap on total worker launches for the run's lifetime |
| `OCEAN_ITERATION_TIMEOUT` | `7200` | Seconds before a hung worker is killed (`0` disables) |
| `OCEAN_MAX_FAILURES` | `5` | Consecutive non-limit worker failures before the run blocks |
| `OCEAN_STALL_LIMIT` | `3` | Successful-but-progress-free iterations before the run blocks |
| `OCEAN_BACKOFF_BASE` | `60` | First backoff (seconds); doubles per consecutive limit hit |
| `OCEAN_BACKOFF_MAX` | `3600` | Exponential backoff ceiling |
| `OCEAN_LIMIT_SLEEP_MAX` | `21600` | Ceiling when sleeping until a parsed limit-reset timestamp (6 h) |
| `OCEAN_LOOP_SLEEP` | `5` | Pause between healthy iterations |

## Paths and hooks

| Var | Default | Meaning |
|---|---|---|
| `OCEAN_DIR` | `.ocean` | State directory (relative to project root) |
| `OCEAN_CHECKPOINT_GRACE` | `300` | Stop hook: seconds a checkpoint counts as "fresh" |
| `OCEAN_GUARD_DISABLED` | `0` | `1` disables the Stop guard entirely |

## Notifications

| Var | Default | Meaning |
|---|---|---|
| `OCEAN_NOTIFY_CMD` | *(empty)* | Command invoked with the message as `$1`, on: sprint done, run complete, run blocked, daemon stopped |

macOS users also get native `osascript` notifications automatically.

## Recipes

### Telegram pings per sprint

```bash
# notify.sh
#!/usr/bin/env bash
curl -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d text="$1" >/dev/null
```

```bash
OCEAN_NOTIFY_CMD="bash /path/to/notify.sh" ocean-daemon start
```

Same shape works for [ntfy.sh](https://ntfy.sh) (`curl -d "$1" ntfy.sh/your-topic`),
Slack webhooks, or `say` if you like your Mac talking to you at 3 a.m.

### Model routing: cheap workers, premium verification

```bash
# Sprints on a fast model…
OCEAN_MODEL=claude-sonnet-5 ocean-daemon start
# …and if the verify gate reopens the run, restart the fix passes on a stronger one:
ocean-daemon stop && OCEAN_MODEL=claude-opus-4-8 ocean-daemon start
```

### A persistent per-project config

The daemon reads env at launch, so keep a project profile and source it:

```bash
# .ocean/env  (commit it)
export OCEAN_AGENT=codex
export OCEAN_PERMISSIONS=standard
export OCEAN_MAX_ITERATIONS=30
export OCEAN_NOTIFY_CMD="bash ./scripts/notify.sh"
```

```bash
source .ocean/env && ocean-daemon start
```

### Overnight run, capped at ~8 hours of wall clock

```bash
OCEAN_MAX_ITERATIONS=16 OCEAN_ITERATION_TIMEOUT=1800 ocean-daemon start
```

16 workers × 30 min ceiling ≈ 8 h worst case; a healthy run finishes far earlier.

### Linux without launchd

```bash
# cron — one worker attempt every 10 minutes; lock + terminal states make it safe
*/10 * * * * cd /path/to/project && bash ~/.local/bin/ocean-daemon once >> .ocean/logs/cron.log 2>&1
```

```ini
# systemd — the persistent-loop equivalent of launchd
# /etc/systemd/system/boil-ocean-myproject.service
[Unit]
Description=boil-the-ocean daemon (myproject)
[Service]
WorkingDirectory=/path/to/project
ExecStart=/usr/bin/env bash %h/.local/bin/ocean-daemon run
Restart=on-failure
[Install]
WantedBy=default.target
```

`Restart=on-failure` mirrors the launchd semantics: crashes respawn, deliberate exits
(complete/blocked/stopped, all exit 0) stay down.

### Custom worker prompt

Drop `.ocean/prompt-override.md` in the project to replace the daemon's default worker
prompt entirely (you're then responsible for pointing workers at the protocol file and
state paths — start from the default in `ocean-daemon.sh:worker_prompt`).
