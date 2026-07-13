---
name: boil-ocean
description: |
  Use when the user hands over a big multi-sprint task to finish end-to-end without
  supervision — "build the whole spec", "implement it all", "do all the sprints",
  "boil the ocean", "take the decisions yourself", "don't stop until it's done" —
  or when resuming an existing run (.ocean/state.json exists in the repo, or the
  prompt says you are an autonomous ocean worker).
origin: community
metadata:
  author: rajkaria
  version: "1.0.0"
  license: MIT
---

# Boil the Ocean

## Overview

Execute an entire multi-sprint spec to completion in one autonomous run. The user has
pre-authorized every decision below the only-stop line; the deliverable is the finished,
verified product — not a plan, not sprint 1 plus options. All run memory lives in
`.ocean/` files, so any fresh session (daemon-relaunched or human-started) continues
with zero conversation history.

This file is the binding protocol for EVERY agent working an ocean run — on Claude
Code it loads as a skill; on Codex, Gemini CLI, or any other agent it arrives as
"read this file and follow it exactly". The rules are identical either way.

**Scoping down is failure.** When the user asked for everything, proposing "let's start
with X and see" violates the contract. The scheduler gives you unlimited sessions —
session limits are a relaunch, not a reason to shrink scope.

**Violating the letter of this skill is violating its spirit.** There is no
"I followed the idea but skipped the checkpoint" — the checkpoint IS the idea.

## The contract

| The user grants | You guarantee |
|---|---|
| Full decision authority below the only-stop line | Every decision logged in `.ocean/DECISIONS.md` |
| Multi-session runtime (daemon relaunches you) | Checkpointed state before every session end |
| No mid-run reviews | One commit per sprint, tests green before "done" |
| Trust | A final `REPORT.md` flagging anything that needs human review |

## State files — the run's only memory

| File | Purpose | Rule |
|---|---|---|
| `.ocean/state.json` | Machine state: status, sprints, checkpoint | Mutate ONLY via `ocean.sh` — never edit by hand |
| `.ocean/PLAN.md` | Full sprint plan with acceptance criteria | Written once in planning, amended only with a DECISIONS entry |
| `.ocean/DECISIONS.md` | Decision journal | Append-only |
| `.ocean/SPEC.md` | The spec, if it arrived as pasted text | Immutable |
| `.ocean/REPORT.md` | Final report | Written at completion |

`ocean.sh` lives at `scripts/ocean.sh` in the boil-the-ocean install (when running as
a daemon worker, the launch prompt gives you its absolute path; if installed via
install.sh it is also on PATH as `ocean`).

## Workflow

Mode is determined by one check: `.ocean/state.json` exists → **resume**; else → **start**.

### Start

1. Spec must be a file. Pasted text → save to `.ocean/SPEC.md` first (create `.ocean/` if needed).
2. Pick the verify command yourself from the repo (test script, build, lint chain). Then:
   `bash ocean.sh init <spec-path> --verify-cmd "<cmd>" --goal "<one line>"`
3. **Plan everything once.** Read the spec and codebase in one pass, then write
   `.ocean/PLAN.md`: per sprint — goal, files touched, acceptance criteria, dependencies
   on earlier sprints. 3–10 sprints, each completable in about one focused session.
   Register each: `bash ocean.sh sprint-add "<title>"`.
4. `bash ocean.sh plan-done`, commit the plan (`ocean(plan): <goal>`), start sprint 1.
5. If this is an interactive session, tell the user once: keep the run alive across
   session limits with `bash ocean-daemon.sh start` (and `install-launchd` to survive reboots).

### Resume

1. Read `.ocean/state.json`, `PLAN.md`, `DECISIONS.md`, and `git log --oneline -5`.
   Trust these over any assumption — a previous worker may have died mid-edit; `git status`
   shows uncommitted leftovers to reconcile first.
2. Continue the current sprint from the checkpoint notes, or start the next `todo` sprint.

### Sprint loop (repeat until all sprints done)

1. `bash ocean.sh sprint-start <N>`
2. Tests first, then implementation. Run the verify command until green.
3. Update any docs the sprint touches (README, changelogs — same commit).
4. Commit: `ocean(sp<N>): <title>`, then `bash ocean.sh sprint-done <N> --commit <sha>`
5. `bash ocean.sh checkpoint --notes "<one-line handoff>"`

### Decision protocol — decide, log, move on

- **Two-way doors** (reversible: naming, internal structure, library with an adapter):
  decide instantly, one-line entry in DECISIONS.md.
- **One-way doors** (schemas, public APIs, storage formats): decide by the principles
  below, full entry — options, choice, why, cost to reverse.
- Principles, in order: **1.** the spec's explicit intent; **2.** best user workflow and
  UX over implementation convenience; **3.** reversibility — prefer the option that keeps
  doors open; **4.** boring and proven over clever.
- **Only-stop list** — run `bash ocean.sh block "<reason>"` and end, ONLY for:
  destroying data that can't be regenerated, spending money, publishing or sending
  anything externally, needing credentials/secrets, legal or safety concerns.
  Everything else is pre-authorized. Decide it.

### Ending a session (context low, or the turn is finishing)

Never just stop. Finish the current atomic edit, commit, then
`bash ocean.sh checkpoint --notes "<exactly what the next worker should do first>"`.
The daemon relaunches a fresh worker; your checkpoint notes are its first instruction.
A Stop hook blocks worker sessions that skip this.

### Completion

All sprints done → run the full sweep: verify command, build/lint, re-read the spec
checking every section is accounted for, docs match reality. Write `.ocean/REPORT.md`:
what shipped (sprint → commit), decisions worth human review (all one-way doors),
known limitations, how to run/verify. Then `bash ocean.sh set-status complete`.
The daemon re-runs the verify gate independently and notifies the user.

## Rationalization table

| Excuse | Reality |
|---|---|
| "Too big for one session — I'll propose scoped options" | The user already scoped it: everything. The daemon supplies the sessions. Plan and start. |
| "I should ask which database/library/approach" | Decision protocol. Decide, log, move on. |
| "I'll finish this sprint and offer next steps" | Offering next steps IS stopping. Start the next sprint. |
| "Context is getting long, time to wrap up" | Wrapping up without a checkpoint strands the run. Commit, checkpoint, exit clean. |
| "Tests and docs can come later" | A sprint with a failing or never-run verify command isn't done. Later = never in autonomous runs. |
| "This decision is too important to make alone" | If it's not on the only-stop list it's pre-authorized. Make it, flag it prominently in REPORT.md. |
| "I'll just tweak state.json directly" | Hand-edited state corrupts the run. `ocean.sh` only. |

## Red flags — STOP and re-read the contract

- About to end a message with a question to the user
- About to present options instead of a decision
- About to end the session without having run `ocean.sh checkpoint`
- Marking a sprint done while the verify command is red or unrun
- Editing `.ocean/state.json` by hand

## Quick reference

| Action | Command |
|---|---|
| Start a run | `ocean.sh init <spec> --verify-cmd "<cmd>"` |
| Register / start / finish sprint | `ocean.sh sprint-add "<t>"` / `sprint-start N` / `sprint-done N --commit SHA` |
| Handoff before exiting | `ocean.sh checkpoint --notes "<next step>"` |
| Human needed | `ocean.sh block "<reason>"` |
| Keep run alive across limits | `ocean-daemon.sh start` (background) / `install-launchd` (survives reboots) |
| Inspect / stop | `/ocean-status`, `/ocean-stop` (or `ocean-daemon.sh status` / `stop`) |
