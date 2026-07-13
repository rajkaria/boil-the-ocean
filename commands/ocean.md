---
description: Start (or resume) a boil-the-ocean run — autonomous multi-sprint execution to completion
---

Use the **boil-ocean** skill and follow it exactly.

- If `.ocean/state.json` exists in this repo, resume that run (read state, plan, and
  decision journal first — they are the run's only memory).
- Otherwise start a new run with the spec given in the arguments below: a file path, or
  an inline description (save inline text to `.ocean/SPEC.md` before `ocean.sh init`).

After the plan is committed and sprint 1 is underway, remind the user once, in one line:
to keep this run alive across session/usage limits they can run the scheduler —
`bash <boil-ocean>/scripts/ocean-daemon.sh start` from the repo root (`install-launchd`
to also survive reboots). Then keep working; do not wait for a reply.

Spec / arguments: $ARGUMENTS
