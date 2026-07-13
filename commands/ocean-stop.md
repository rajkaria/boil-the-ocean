---
description: Gracefully stop the boil-ocean run and its scheduler
---

Stop the boil-ocean run in this repo gracefully:

1. `bash <boil-ocean>/scripts/ocean-daemon.sh stop` — creates `.ocean/STOP`; the daemon
   exits before its next iteration. A currently running worker finishes its session
   first (its Stop hook makes it checkpoint, so nothing is lost).
2. If the user said "now" / "immediately", use `stop --now` instead (kills the daemon
   process; the worker's checkpoint from its last sprint boundary still stands).
3. If a launchd agent was installed, also run
   `bash <boil-ocean>/scripts/ocean-daemon.sh uninstall-launchd` — otherwise it would
   respawn after a crash or reboot.
4. Confirm with `bash <boil-ocean>/scripts/ocean-daemon.sh status` and tell the user:
   current sprint progress, and that resuming later is just `ocean-daemon.sh start`
   (state in `.ocean/` is untouched by stopping).

$ARGUMENTS
