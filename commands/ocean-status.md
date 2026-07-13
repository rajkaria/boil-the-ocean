---
description: Show the current boil-ocean run — sprint progress, daemon state, recent decisions
---

Report the state of the boil-ocean run in this repo. Run these read-only commands
(`<boil-ocean>` = this plugin's root; scripts are also symlinked at `~/.claude/scripts/`
when installed via install.sh):

1. `bash <boil-ocean>/scripts/ocean-daemon.sh status` — daemon liveness + sprint table
2. `tail -20 .ocean/logs/daemon.log` — recent scheduler activity (if present)
3. The last 2–3 entries of `.ocean/DECISIONS.md`

Summarize in a few sentences: run status, sprints done/total and what's in flight,
whether the daemon is alive, the latest handoff notes, and any blockers verbatim.
If the run is blocked, state exactly what the human needs to decide, then how to
resume: fix → `bash scripts/ocean.sh unblock` → `bash scripts/ocean-daemon.sh start`.

$ARGUMENTS
