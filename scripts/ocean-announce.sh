#!/usr/bin/env bash
# ============================================================================
# ocean-announce.sh — SessionStart hook
#
# If the repo has an active boil-ocean run, print a one-paragraph notice so
# any session (interactive or worker) knows the run exists and where its
# state lives. Silent when there is no active run — costs zero context.
# ============================================================================
set -uo pipefail

OCEAN_DIR="${OCEAN_DIR:-.ocean}"
STATE="$OCEAN_DIR/state.json"
[ -f "$STATE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

status="$(jq -r '.status // ""' "$STATE" 2>/dev/null)"
case "$status" in
  planning|running|blocked) ;;
  *) exit 0 ;;
esac

run_id="$(jq -r .run_id "$STATE")"
cur="$(jq -r .current_sprint "$STATE")"
n="$(jq -r '.sprints | length' "$STATE")"
done_n="$(jq -r '[.sprints[] | select(.status == "done")] | length' "$STATE")"
notes="$(jq -r '.notes // ""' "$STATE")"

echo "BOIL-OCEAN: this repo has an active run — $run_id [status: $status, sprints done: $done_n/$n, current: $cur]."
[ -n "$notes" ] && echo "Last handoff: $notes"
echo "State lives in $OCEAN_DIR/ (state.json, PLAN.md, DECISIONS.md). Use /ocean-status for details. If you are an autonomous worker, follow the boil-ocean skill; if this is an interactive session, do not duplicate the worker's sprint work without checking state first."
exit 0
