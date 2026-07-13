# Troubleshooting

Start every investigation the same way:

```bash
ocean-daemon doctor        # config/binary/state sanity
ocean status               # what does the run think is happening?
tail -50 .ocean/logs/daemon.log        # what does the scheduler think?
ls -t .ocean/logs/iter-*.log | head -1 # the latest worker's full transcript
```

## The run is blocked

`ocean status` prints blockers verbatim. The usual four:

| Blocker text | What happened | Fix |
|---|---|---|
| *(something from the only-stop list)* | A worker hit a genuinely human decision — credentials, spending, destructive/external action | Make the call, write it into `PLAN.md` or `DECISIONS.md`, then `ocean unblock && ocean-daemon start` |
| `verify_cmd still failing after 2 reopens` | Workers claimed completion twice; your test command disagrees both times | Run the verify command yourself, read the failure, fix or re-scope, `ocean unblock && ocean-daemon start` |
| `no state progress across N iterations` | Workers ran but state never moved (see below) | Read the last `iter-*.log` — then fix the underlying cause and unblock |
| `worker failed N times in a row` | The agent CLI is exiting non-zero | Read the last `iter-*.log`; usually auth (`claude login` / `codex login`), a missing binary, or a permission mode too weak for the work |
| `hit OCEAN_MAX_ITERATIONS` | Budget guard fired | If progress was real, raise the cap and unblock; if not, treat as a stall |

## Stalls: workers run but nothing moves

The stall detector fires when `{status, current sprint, sprint statuses, checkpoint}`
is identical across `OCEAN_STALL_LIMIT` successful iterations. Root causes, most
common first:

1. **Permission mode too weak.** The worker can't run `ocean.sh` (Bash denied) or
   can't commit. Symptom in the log: permission denials or the agent narrating work
   it never executed. Fix: `OCEAN_PERMISSIONS=standard` (or check your allowlist).
2. **The agent ignored the protocol.** Some models drift on long prompts. Check the
   iter log for whether it actually read SKILL.md. Consider a stronger `OCEAN_MODEL`
   for that run, or tighten `.ocean/prompt-override.md`.
3. **A sprint too big to finish in one session**, so every worker starts over and
   dies before `sprint-done`. Fix: split the sprint in `PLAN.md` + add matching
   `sprint-add` entries, journal the amendment, unblock.

## Usage limits

Expected behavior, not an error: the daemon logs `usage limit hit — backoff Ns` and
sleeps. With a parsed reset timestamp it sleeps until reset (+60 s, capped at
`OCEAN_LIMIT_SLEEP_MAX`); otherwise exponentially (`OCEAN_BACKOFF_BASE` doubling to
`OCEAN_BACKOFF_MAX`). If your provider's limit message isn't detected (check the iter
log), the run misclassifies it as a failure — open an issue with the exact phrasing so
we can extend the regex, or add it locally in `hit_usage_limit()`.

## The daemon won't start

| Symptom | Cause | Fix |
|---|---|---|
| `already running (pid N)` | A live daemon holds the lock | That's the answer — or `ocean-daemon stop` first |
| `no run found at .ocean/state.json` | You're not in the project root, or no `init` yet | `cd` to the repo root / `ocean init …` |
| Exits instantly, log says STOP file | Leftover `.ocean/STOP` | `ocean-daemon start` clears it automatically — but `once` mode does not: `rm .ocean/STOP` |
| `state update failed (jq filter error)` | Hand-edited state.json | Restore from git (`git checkout .ocean/state.json`) — and don't edit it by hand |

## Stale or broken installs

| Symptom | Cause | Fix |
|---|---|---|
| Behavior doesn't match the README | Clone is behind the docs you're reading | `ocean version --check`, then `ocean upgrade` |
| `ocean: command not found` after install | `~/.local/bin` not on PATH | `export PATH="$HOME/.local/bin:$PATH"` (doctor warns about this) |
| A new command/script 404s after `git pull` | Pulling by hand skips the re-link step | `ocean upgrade` instead — it replays `install.sh` for every recorded target |
| `upgrade` says history diverged | Local commits in the clone | It's your fork now: `git -C ~/.boil-the-ocean pull --rebase` yourself, or re-clone |
| Update check feels like surveillance | It's a 5s `VERSION` fetch, no data sent | `OCEAN_UPDATE_CHECK=off` disables it entirely |

## Stop-guard weirdness (Claude Code)

- **"My interactive session got blocked from stopping"** — it shouldn't:
  the guard requires `OCEAN_WORKER=1`, which only the daemon sets. If you exported it
  yourself (e.g. copied a worker env), unset it. Escape hatch: `OCEAN_GUARD_DISABLED=1`.
- **Worker sessions stopping without checkpoints anyway** — the guard allows a stop
  when the last checkpoint is fresher than `OCEAN_CHECKPOINT_GRACE` (300 s). If your
  sprints are extremely short, that's correct behavior, not a bug.

## Verify gate keeps bouncing completions

`reopen_count` climbs when workers think they're done and your `verify_cmd` disagrees.
Check that the verify command:

- runs green on a *clean checkout* of the sprint commits (`git stash && npm test`),
- doesn't depend on env the daemon lacks (nvm/pyenv shims — put absolute paths or a
  `.ocean/env` source line into `verify_cmd` itself, e.g. `bash -lc 'npm test'`),
- isn't flaky. A flaky gate is indistinguishable from failure — fix flakiness first.

## Reading the logs like a maintainer

```bash
grep -E "iteration [0-9]+ (starting|finished)" .ocean/logs/daemon.log   # the heartbeat
grep -i "backoff\|limit" .ocean/logs/daemon.log                         # limit history
grep -i "NOTIFY" .ocean/logs/daemon.log                                 # what you were told
jq '.sprints' .ocean/state.json                                         # ground truth
git log --oneline --grep="^ocean("                                      # shipped work
```

## Still stuck?

Open an issue with: `ocean-daemon doctor` output, the last 50 lines of
`daemon.log`, the tail of the latest `iter-*.log`, and `ocean json` (redact anything
sensitive). That tuple diagnoses ~everything.
