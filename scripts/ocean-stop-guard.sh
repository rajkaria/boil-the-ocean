#!/usr/bin/env bash
# ============================================================================
# ocean-stop-guard.sh — Stop hook
#
# Prevents an ocean WORKER session (launched by ocean-daemon.sh, which sets
# OCEAN_WORKER=1) from ending without a handoff. If the run is active and no
# recent checkpoint exists, the stop is blocked once with instructions to
# commit + checkpoint. Interactive sessions in the same repo are never
# blocked (OCEAN_WORKER is unset there).
#
# Reads the hook payload from stdin (JSON). Honors stop_hook_active so a
# blocked stop can never loop forever.
# ============================================================================
set -uo pipefail

# Only guard the daemon's own workers — never a human's interactive session.
[ "${OCEAN_WORKER:-0}" = "1" ] || exit 0
[ "${OCEAN_GUARD_DISABLED:-0}" = "1" ] && exit 0

OCEAN_DIR="${OCEAN_DIR:-.ocean}"
STATE="$OCEAN_DIR/state.json"
[ -f "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"
if [ -n "$INPUT" ]; then
  # Second pass after a block — always allow, otherwise we'd loop forever.
  if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
  fi
fi

status="$(jq -r '.status // ""' "$STATE" 2>/dev/null)"
case "$status" in
  planning|running) ;;
  *) exit 0 ;;  # blocked/paused/complete/aborted — stopping is correct
esac

grace="${OCEAN_CHECKPOINT_GRACE:-300}"
last="$(jq -r '.last_checkpoint // 0' "$STATE" 2>/dev/null)"
nowts="$(date +%s)"
if [ $((nowts - last)) -le "$grace" ] 2>/dev/null; then
  exit 0  # fresh checkpoint — clean handoff already done
fi

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SDIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$SDIR/$SOURCE" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
cur="$(jq -r '.current_sprint // 0' "$STATE")"
n="$(jq -r '.sprints | length' "$STATE")"

jq -n --arg reason "An ocean run is active (sprint $cur/$n, status: $status) and no checkpoint has been written in the last ${grace}s. Do not end without a handoff. Either (a) keep working on the current sprint, or (b) if you are ending because context is running low: commit your work, then run \`bash $SCRIPT_DIR/ocean.sh checkpoint --notes '<one-line handoff for the next worker>'\` and stop. If you are genuinely blocked on something only the user can decide, run \`bash $SCRIPT_DIR/ocean.sh block '<reason>'\` and stop." \
  '{decision: "block", reason: $reason}'
exit 0
