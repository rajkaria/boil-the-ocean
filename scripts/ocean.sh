#!/usr/bin/env bash
# ============================================================================
# ocean.sh — state manager for boil-ocean runs
#
# All run state lives in $OCEAN_DIR/state.json (default: .ocean/state.json).
# Every mutation is atomic (write temp file + mv) so a killed session can
# never leave a half-written state file behind. Claude and the daemon must
# mutate state ONLY through this script — never by editing the JSON directly.
# ============================================================================
set -euo pipefail

OCEAN_DIR="${OCEAN_DIR:-.ocean}"
STATE="$OCEAN_DIR/state.json"

die() { echo "ocean: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required (macOS ships it; else brew install jq)"

now() { date +%s; }

need_state() {
  [ -f "$STATE" ] || die "no active run ($STATE missing) — start one with: ocean.sh init <spec-path>"
}

# Atomic state edit. Usage: edit [jq options] '<filter>'
edit() {
  local tmp
  tmp="$(mktemp "$OCEAN_DIR/.state.XXXXXX")"
  if jq "$@" "$STATE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE"
  else
    rm -f "$tmp"
    die "state update failed (jq filter error)"
  fi
}

ago() {
  local secs=$(( $(now) - $1 ))
  if   [ "$secs" -lt 60 ];    then echo "${secs}s ago"
  elif [ "$secs" -lt 3600 ];  then echo "$((secs / 60))m ago"
  elif [ "$secs" -lt 86400 ]; then echo "$((secs / 3600))h ago"
  else echo "$((secs / 86400))d ago"; fi
}

cmd="${1:-status}"
if [ $# -gt 0 ]; then shift; fi

case "$cmd" in

  init)
    spec="${1:-}"
    [ -n "$spec" ] || die "usage: ocean.sh init <spec-path> [--verify-cmd CMD] [--goal TEXT]"
    shift
    verify=""; goal=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --verify-cmd) verify="${2:-}"; shift 2 ;;
        --goal)       goal="${2:-}";   shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    [ -f "$spec" ] || die "spec file not found: $spec (save pasted specs to a file first)"
    [ -f "$STATE" ] && die "a run already exists ($(jq -r .run_id "$STATE")). Finish it, or remove $OCEAN_DIR to start over."
    mkdir -p "$OCEAN_DIR/logs"
    run_id="ocean-$(date +%Y%m%d-%H%M%S)"
    jq -n \
      --arg run_id "$run_id" --arg spec "$spec" --arg verify "$verify" --arg goal "$goal" \
      --argjson t "$(now)" '{
        run_id: $run_id,
        created_at: $t,
        spec_path: $spec,
        goal: $goal,
        status: "planning",
        current_sprint: 0,
        sprints: [],
        verify_cmd: $verify,
        iteration: 0,
        reopen_count: 0,
        last_checkpoint: $t,
        heartbeat: $t,
        blockers: [],
        notes: ""
      }' > "$STATE"
    # Seed the decision journal so the first entry has a template to follow.
    if [ ! -f "$OCEAN_DIR/DECISIONS.md" ]; then
      cat > "$OCEAN_DIR/DECISIONS.md" <<'EOF'
# Decision Journal

Every autonomous decision gets an entry. Two-way doors get one line; one-way
doors get the full block.

<!-- Template for one-way doors:
## D<N>: <title>
- **Sprint:** <n>  **Date:** <YYYY-MM-DD>
- **Options:** <a> / <b> / <c>
- **Chose:** <x>
- **Why:** <reasoning — user workflow first, implementation convenience last>
- **Cost to reverse:** <low/medium/high — what it would take>
-->
EOF
    fi
    echo "initialized $run_id (status: planning, spec: $spec)"
    ;;

  sprint-add)
    need_state
    title="${1:-}"; [ -n "$title" ] || die "usage: ocean.sh sprint-add \"<title>\""
    edit --arg title "$title" \
      '.sprints += [{id: (.sprints | length + 1), title: $title, status: "todo", commit: ""}]'
    echo "sprint $(jq -r '.sprints | length' "$STATE") added: $title"
    ;;

  plan-done)
    need_state
    n="$(jq -r '.sprints | length' "$STATE")"
    [ "$n" -gt 0 ] || die "no sprints registered — add them with sprint-add before plan-done"
    edit --argjson t "$(now)" '.status = "running" | .heartbeat = $t | .last_checkpoint = $t'
    echo "plan locked: $n sprints, status running"
    ;;

  sprint-start)
    need_state
    id="${1:-}"; [ -n "$id" ] || die "usage: ocean.sh sprint-start <id>"
    jq -e --argjson id "$id" '.sprints[] | select(.id == $id)' "$STATE" >/dev/null \
      || die "no sprint with id $id"
    edit --argjson id "$id" --argjson t "$(now)" \
      '(.sprints[] | select(.id == $id) | .status) = "in_progress"
       | .current_sprint = $id | .heartbeat = $t'
    echo "sprint $id in progress"
    ;;

  sprint-done)
    need_state
    id="${1:-}"; [ -n "$id" ] || die "usage: ocean.sh sprint-done <id> [--commit SHA]"
    shift
    sha=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --commit) sha="${2:-}"; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    edit --argjson id "$id" --arg sha "$sha" --argjson t "$(now)" \
      '(.sprints[] | select(.id == $id) | .status) = "done"
       | (.sprints[] | select(.id == $id) | .commit) = $sha
       | .heartbeat = $t | .last_checkpoint = $t'
    echo "sprint $id done"
    ;;

  checkpoint)
    need_state
    notes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --notes) notes="${2:-}"; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    if [ -n "$notes" ]; then
      edit --arg notes "$notes" --argjson t "$(now)" \
        '.last_checkpoint = $t | .heartbeat = $t | .notes = $notes'
    else
      edit --argjson t "$(now)" '.last_checkpoint = $t | .heartbeat = $t'
    fi
    echo "checkpoint saved"
    ;;

  heartbeat)
    need_state
    edit --argjson t "$(now)" '.heartbeat = $t'
    ;;

  block)
    need_state
    reason="${1:-}"; [ -n "$reason" ] || die "usage: ocean.sh block \"<reason>\""
    edit --arg r "$reason" --argjson t "$(now)" \
      '.status = "blocked" | .blockers += [$r] | .heartbeat = $t | .last_checkpoint = $t'
    echo "run blocked: $reason"
    ;;

  unblock)
    need_state
    edit --argjson t "$(now)" '.status = "running" | .heartbeat = $t'
    echo "run unblocked (blockers list kept for the record)"
    ;;

  reopen)
    need_state
    note="${1:-verify gate failed}"
    edit --arg n "$note" --argjson t "$(now)" \
      '.status = "running" | .reopen_count += 1 | .blockers += [("reopened: " + $n)] | .heartbeat = $t'
    echo "run reopened ($(jq -r .reopen_count "$STATE")x): $note"
    ;;

  set-status)
    need_state
    s="${1:-}"
    case "$s" in
      planning|running|blocked|paused|complete|aborted) ;;
      *) die "invalid status '$s' (planning|running|blocked|paused|complete|aborted)" ;;
    esac
    edit --arg s "$s" --argjson t "$(now)" '.status = $s | .heartbeat = $t | .last_checkpoint = $t'
    echo "status: $s"
    ;;

  iteration)
    need_state
    edit '.iteration += 1'
    jq -r .iteration "$STATE"
    ;;

  stop)
    need_state
    touch "$OCEAN_DIR/STOP"
    echo "STOP file created — the daemon will exit before the next iteration."
    ;;

  json)
    need_state
    cat "$STATE"
    ;;

  status)
    need_state
    run_id=$(jq -r .run_id "$STATE")
    st=$(jq -r .status "$STATE")
    spec=$(jq -r .spec_path "$STATE")
    cur=$(jq -r .current_sprint "$STATE")
    n=$(jq -r '.sprints | length' "$STATE")
    done_n=$(jq -r '[.sprints[] | select(.status == "done")] | length' "$STATE")
    verify=$(jq -r '.verify_cmd // "" | if . == "" then "(none)" else . end' "$STATE")
    iter=$(jq -r .iteration "$STATE")
    last=$(jq -r .last_checkpoint "$STATE")
    nblock=$(jq -r '.blockers | length' "$STATE")
    notes=$(jq -r '.notes // ""' "$STATE")
    echo "Run:     $run_id  [$st]"
    echo "Spec:    $spec"
    echo "Sprints: $done_n/$n done (current: $cur)"
    jq -r '.sprints[] | (if .status == "done" then "  x " elif .status == "in_progress" then "  > " else "  . " end) + (.id | tostring) + ". " + .title + (if .commit != "" then "  (" + .commit[0:7] + ")" else "" end)' "$STATE"
    echo "Verify:  $verify"
    echo "Iteration $iter | last checkpoint $(ago "$last") | blockers: $nblock"
    if [ -n "$notes" ]; then echo "Notes:   $notes"; fi
    if [ "$nblock" -gt 0 ]; then
      echo "Blockers:"
      jq -r '.blockers[] | "  - " + .' "$STATE"
    fi
    ;;

  *)
    die "unknown command: $cmd
usage: ocean.sh <init|sprint-add|plan-done|sprint-start|sprint-done|checkpoint|heartbeat|block|unblock|reopen|set-status|iteration|stop|status|json>"
    ;;
esac
