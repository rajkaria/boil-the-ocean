# Boil the Ocean on any agent (custom adapter)

If your agent CLI can (a) be launched headlessly with a prompt, (b) read files, and
(c) run shell commands, it can boil the ocean. The daemon treats agents as
interchangeable workers; the protocol lives in a markdown file every worker is told
to read.

## The contract

Set two variables:

```bash
OCEAN_AGENT=custom
OCEAN_WORKER_CMD='<shell command that runs one headless agent session>'
```

The daemon invokes your command as `bash -c "$OCEAN_WORKER_CMD"` with:

| Provided | As | Meaning |
|---|---|---|
| The worker prompt | `$OCEAN_PROMPT` (env) | Full instructions: protocol path, state paths, resume rules |
| `OCEAN_WORKER=1` | env | Marks the session as a daemon worker (used by optional hooks) |
| `OCEAN_DIR` | env | State directory path |
| Working directory | cwd | The project root |
| stdout/stderr | redirected | Captured to `.ocean/logs/iter-NNN.log` |

Your command's **exit code** matters: non-zero counts toward
`OCEAN_MAX_FAILURES`. Output matching common limit phrasings (`rate limit`, `429`,
`quota exceeded`, `usage limit`, …) triggers backoff instead of the failure counter.

## Examples

```bash
# Aider
OCEAN_AGENT=custom \
OCEAN_WORKER_CMD='aider --yes-always --message "$OCEAN_PROMPT"' \
ocean-daemon start

# OpenCode
OCEAN_AGENT=custom \
OCEAN_WORKER_CMD='opencode run "$OCEAN_PROMPT"' \
ocean-daemon start

# Cursor CLI
OCEAN_AGENT=custom \
OCEAN_WORKER_CMD='cursor-agent -p "$OCEAN_PROMPT" --force' \
ocean-daemon start

# Anything at all — even an agent behind an API you script yourself
OCEAN_AGENT=custom \
OCEAN_WORKER_CMD='python3 my_agent_runner.py --prompt-env OCEAN_PROMPT' \
ocean-daemon start
```

Quote carefully: use single quotes around the template so `$OCEAN_PROMPT` expands
when the daemon runs it, not when you set it.

## What your agent must be able to do

The prompt instructs the worker to:

1. Read the protocol file (`skills/boil-ocean/SKILL.md`) and treat it as binding.
2. Read `.ocean/state.json`, `PLAN.md`, `DECISIONS.md`, and `git log` for ground truth.
3. Do sprint work: tests, implementation, docs, git commits.
4. Mutate state **only** via `bash <repo>/scripts/ocean.sh <cmd>`.
5. Checkpoint with handoff notes before exiting.

So the practical requirements are file reads, shell execution (git + `ocean.sh`), and
enough instruction-following to respect a protocol document. Agents that can't run
shell commands can't participate (they couldn't commit or checkpoint).

## Adding a first-class adapter

If your agent deserves better than `custom` (its own permission mapping, model flag,
limit phrasings), a first-class adapter is ~15 lines in `scripts/ocean-daemon.sh`:

1. Add `OCEAN_<NAME>_BIN` to the config block.
2. Add a `<name>_flags()` function mapping `safe`/`standard`/`yolo`.
3. Add a case to `agent_bin()` and `run_worker()`.
4. Extend the `hit_usage_limit` regex with the CLI's limit phrasings.
5. Add an adapter test in `tests/test-ocean.sh` (mock binary — see the codex test).
6. Document it in `docs/agents/<NAME>.md`.

PRs welcome — see [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Verification checklist for a new adapter

```bash
OCEAN_AGENT=custom OCEAN_WORKER_CMD='…' ocean-daemon doctor   # binary/config sanity
ocean init examples/todo-api-spec.md --verify-cmd "true"      # disposable run
OCEAN_AGENT=custom OCEAN_WORKER_CMD='…' ocean-daemon once     # single iteration
cat .ocean/logs/iter-001.log                                  # did the agent engage the protocol?
ocean status                                                  # did state move?
```
