#!/usr/bin/env bash
# ============================================================================
# ocean-daemon.sh — the scheduler that keeps a boil-the-ocean run alive
# across session limits.
#
# Repeatedly launches headless agent workers (Claude Code, Codex, Gemini CLI,
# or any custom CLI) against the run's state files until the run reaches a
# terminal state. Each worker is a FRESH session (state lives in .ocean/, not
# in conversation memory), so hitting a context or usage limit costs nothing
# but a relaunch.
#
# Handles: usage-limit backoff (parses the reset timestamp when the CLI
# provides one), consecutive-failure backoff, stall detection (no state
# progress across iterations), a final verify gate before declaring the run
# complete, and optional launchd installation so runs survive reboots.
#
# Usage: ocean-daemon.sh <start|run|once|stop|status|logs|doctor|install-launchd|uninstall-launchd>
# Run from the project root (the directory that contains .ocean/).
# ============================================================================
set -uo pipefail

# Resolve symlinks (install.sh links this script into ~/.local/bin and
# ~/.claude/scripts) so sibling scripts and the protocol file are found in the
# real repo, not next to the symlink.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SDIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$SDIR/$SOURCE" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
OCEAN_SH="$SCRIPT_DIR/ocean.sh"
PROJECT_ROOT="$(pwd)"

# --- Configuration (env-overridable) ---------------------------------------
OCEAN_DIR="${OCEAN_DIR:-.ocean}"
OCEAN_AGENT="${OCEAN_AGENT:-claude}"                  # claude | codex | gemini | custom
OCEAN_CLAUDE_BIN="${OCEAN_CLAUDE_BIN:-claude}"
OCEAN_CODEX_BIN="${OCEAN_CODEX_BIN:-codex}"
OCEAN_GEMINI_BIN="${OCEAN_GEMINI_BIN:-gemini}"
OCEAN_WORKER_CMD="${OCEAN_WORKER_CMD:-}"              # custom agent: shell command, reads prompt from $OCEAN_PROMPT
OCEAN_MODEL="${OCEAN_MODEL:-}"                        # optional model override (mapped per agent)
OCEAN_PERMISSIONS="${OCEAN_PERMISSIONS:-standard}"    # safe | standard | yolo
OCEAN_EXTRA_FLAGS="${OCEAN_EXTRA_FLAGS:-}"            # appended verbatim to the worker command
OCEAN_MAX_ITERATIONS="${OCEAN_MAX_ITERATIONS:-50}"    # hard budget cap
OCEAN_BACKOFF_BASE="${OCEAN_BACKOFF_BASE:-60}"        # secs, first backoff
OCEAN_BACKOFF_MAX="${OCEAN_BACKOFF_MAX:-3600}"        # secs, exponential cap
OCEAN_LIMIT_SLEEP_MAX="${OCEAN_LIMIT_SLEEP_MAX:-21600}" # secs, cap when waiting for a usage-limit reset
OCEAN_ITERATION_TIMEOUT="${OCEAN_ITERATION_TIMEOUT:-7200}" # secs per worker, 0 = no limit
OCEAN_STALL_LIMIT="${OCEAN_STALL_LIMIT:-3}"           # iterations with zero state progress => blocked
OCEAN_MAX_FAILURES="${OCEAN_MAX_FAILURES:-5}"         # consecutive non-limit failures => blocked
OCEAN_LOOP_SLEEP="${OCEAN_LOOP_SLEEP:-5}"             # secs between healthy iterations
OCEAN_NOTIFY_CMD="${OCEAN_NOTIFY_CMD:-}"              # optional: command run with message as $1

STATE="$OCEAN_DIR/state.json"
LOCK="$OCEAN_DIR/daemon.lock"
DLOG="$OCEAN_DIR/logs/daemon.log"
SKILL_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/skills/boil-ocean/SKILL.md"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DLOG" >&2; }

notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  if [ -n "$OCEAN_NOTIFY_CMD" ]; then
    bash -c "$OCEAN_NOTIFY_CMD \"\$1\"" _ "$msg" >/dev/null 2>&1 || true
  fi
  if [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/}\" with title \"boil-ocean\"" >/dev/null 2>&1 || true
  fi
}

need_run() {
  if [ ! -f "$STATE" ]; then
    echo "ocean-daemon: no run found at $STATE — initialize one first:" >&2
    echo "  bash $OCEAN_SH init <spec-path> --verify-cmd '<test command>'" >&2
    exit 0  # deliberate exit: launchd must not respawn a repo with no run
  fi
  mkdir -p "$OCEAN_DIR/logs"
}

state_get() { jq -r "$1" "$STATE"; }

# --- Agent adapters ---------------------------------------------------------
# Each agent maps the same three permission levels onto its own flags. The
# protocol itself (SKILL.md) is agent-agnostic — every worker is told to read
# and follow it, so no per-agent skill system is required.

claude_flags() {
  case "$OCEAN_PERMISSIONS" in
    safe)     echo "--permission-mode acceptEdits" ;;
    standard) echo "--permission-mode acceptEdits --allowedTools Bash,Edit,Write,Read,Glob,Grep,TodoWrite,Task,WebFetch,WebSearch,NotebookEdit" ;;
    yolo)     echo "--dangerously-skip-permissions" ;;
    *)        log "unknown OCEAN_PERMISSIONS='$OCEAN_PERMISSIONS', using safe"; echo "--permission-mode acceptEdits" ;;
  esac
}

codex_flags() {
  case "$OCEAN_PERMISSIONS" in
    safe) echo "--sandbox workspace-write" ;;
    yolo) echo "--dangerously-bypass-approvals-and-sandbox" ;;
    *)    echo "--full-auto" ;;
  esac
}

gemini_flags() {
  case "$OCEAN_PERMISSIONS" in
    safe) echo "--approval-mode auto_edit" ;;
    *)    echo "--yolo" ;;
  esac
}

agent_bin() {
  case "$OCEAN_AGENT" in
    codex)  echo "$OCEAN_CODEX_BIN" ;;
    gemini) echo "$OCEAN_GEMINI_BIN" ;;
    *)      echo "$OCEAN_CLAUDE_BIN" ;;
  esac
}

worker_prompt() {
  if [ -f "$OCEAN_DIR/prompt-override.md" ]; then
    cat "$OCEAN_DIR/prompt-override.md"
    return
  fi
  cat <<EOF
You are an autonomous worker in a boil-the-ocean run. Your protocol is defined in: $SKILL_FILE — read it now and follow it exactly. (On Claude Code this is the boil-ocean skill; on other agents, treat that file as binding instructions.)

Then read $OCEAN_DIR/state.json, $OCEAN_DIR/PLAN.md (if present), and $OCEAN_DIR/DECISIONS.md, plus \`git log --oneline -5\` for ground truth. Trust these files over any assumption — they are the run's only memory.

- If status is "planning": produce the full sprint plan per the skill, then begin sprint 1.
- If status is "running": continue the current sprint exactly where the last worker's checkpoint notes left off.

Work until the run is complete or your context runs low. State mutations go ONLY through: bash $OCEAN_SH <cmd>
Before your session ends, always: commit your work, then run: bash $OCEAN_SH checkpoint --notes "<one-line handoff>"
Never ask the user questions — apply the skill's decision protocol and log decisions in $OCEAN_DIR/DECISIONS.md. Only \`bash $OCEAN_SH block "<reason>"\` for items on the skill's only-stop list.
EOF
}

# Run one worker with an optional watchdog timeout. Appends to $1 (logfile).
run_worker() {
  local logfile="$1" rc wpid tpid prompt
  prompt="$(worker_prompt)"

  # shellcheck disable=SC2086 — flags are intentionally word-split
  case "$OCEAN_AGENT" in
    codex)
      OCEAN_WORKER=1 OCEAN_DIR="$OCEAN_DIR" "$OCEAN_CODEX_BIN" exec $(codex_flags) \
        ${OCEAN_MODEL:+-m "$OCEAN_MODEL"} $OCEAN_EXTRA_FLAGS "$prompt" >> "$logfile" 2>&1 &
      ;;
    gemini)
      OCEAN_WORKER=1 OCEAN_DIR="$OCEAN_DIR" "$OCEAN_GEMINI_BIN" $(gemini_flags) \
        ${OCEAN_MODEL:+-m "$OCEAN_MODEL"} $OCEAN_EXTRA_FLAGS -p "$prompt" >> "$logfile" 2>&1 &
      ;;
    custom)
      if [ -z "$OCEAN_WORKER_CMD" ]; then
        log "OCEAN_AGENT=custom requires OCEAN_WORKER_CMD (shell command; prompt arrives in \$OCEAN_PROMPT)"
        return 1
      fi
      OCEAN_WORKER=1 OCEAN_DIR="$OCEAN_DIR" OCEAN_PROMPT="$prompt" \
        bash -c "$OCEAN_WORKER_CMD" >> "$logfile" 2>&1 &
      ;;
    *)
      OCEAN_WORKER=1 OCEAN_DIR="$OCEAN_DIR" "$OCEAN_CLAUDE_BIN" -p "$prompt" \
        $(claude_flags) ${OCEAN_MODEL:+--model "$OCEAN_MODEL"} $OCEAN_EXTRA_FLAGS >> "$logfile" 2>&1 &
      ;;
  esac
  wpid=$!

  if [ "$OCEAN_ITERATION_TIMEOUT" -gt 0 ] 2>/dev/null; then
    ( sleep "$OCEAN_ITERATION_TIMEOUT"; kill "$wpid" 2>/dev/null ) &
    tpid=$!
    wait "$wpid"; rc=$?
    kill "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null
  else
    wait "$wpid"; rc=$?
  fi
  return "$rc"
}

hit_usage_limit() { # $1 = worker logfile
  # Covers Claude Code, Codex, and Gemini CLI phrasings for the same problem.
  tail -c 8000 "$1" 2>/dev/null | grep -qiE 'usage limit|rate[ _-]?limit|overloaded|too many requests|error 529|status 429|quota exceeded|resource[ _-]?exhausted|insufficient_quota'
}

# Sleep until a usage-limit reset. Prefers the epoch the CLI embeds in
# "…limit reached|<epoch>" output; falls back to exponential backoff.
limit_backoff() { # $1 = worker logfile, $2 = consecutive limit count
  local logfile="$1" nlimits="$2" reset nowts wait_s
  reset="$(tail -c 8000 "$logfile" 2>/dev/null | grep -oE 'limit reached\|[0-9]{10}' | grep -oE '[0-9]{10}' | tail -1)"
  nowts="$(date +%s)"
  if [ -n "$reset" ] && [ "$reset" -gt "$nowts" ] 2>/dev/null; then
    wait_s=$(( reset - nowts + 60 ))
    [ "$wait_s" -gt "$OCEAN_LIMIT_SLEEP_MAX" ] && wait_s="$OCEAN_LIMIT_SLEEP_MAX"
    log "usage limit hit — reset timestamp found, backoff ${wait_s}s (until $(date -r "$reset" 2>/dev/null || echo "$reset"))"
  else
    wait_s=$(( OCEAN_BACKOFF_BASE * (1 << (nlimits - 1)) ))
    [ "$wait_s" -gt "$OCEAN_BACKOFF_MAX" ] && wait_s="$OCEAN_BACKOFF_MAX"
    log "usage/rate limit hit (${nlimits}x) — backoff ${wait_s}s"
  fi
  sleep "$wait_s"
}

# Final gate: a run is only complete if verify_cmd passes. Failures reopen
# the run (max 2 reopens) so a worker can fix it; then it's blocked for a
# human. Returns 0 = genuinely complete, 1 = reopened.
verify_gate() {
  local verify reopens
  verify="$(state_get '.verify_cmd // ""')"
  [ -z "$verify" ] && { log "no verify_cmd set — accepting completion as-is"; return 0; }
  log "verify gate: $verify"
  if bash -c "$verify" >> "$DLOG" 2>&1; then
    log "verify gate PASSED"
    return 0
  fi
  reopens="$(state_get '.reopen_count // 0')"
  if [ "$reopens" -ge 2 ]; then
    bash "$OCEAN_SH" block "verify_cmd still failing after $reopens reopens: $verify" >/dev/null
    notify "ocean run blocked: verify gate failed after $reopens reopens"
    return 0  # terminal — main loop will see 'blocked' and exit
  fi
  bash "$OCEAN_SH" reopen "verify_cmd failed: $verify" >/dev/null
  log "verify gate FAILED — run reopened for a fix pass"
  return 1
}

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    trap 'rm -rf "$LOCK"' EXIT INT TERM
    return 0
  fi
  local oldpid
  oldpid="$(cat "$LOCK/pid" 2>/dev/null || echo "")"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "ocean-daemon: already running (pid $oldpid)" >&2
    exit 0
  fi
  log "removing stale lock (pid ${oldpid:-unknown} is gone)"
  rm -rf "$LOCK"
  acquire_lock
}

main_loop() {
  need_run
  acquire_lock
  export OCEAN_DIR
  local run_id status iter fingerprint prev_fingerprint="" stall=0 failures=0 limits=0 rc logfile done_n prev_done
  run_id="$(state_get .run_id)"
  prev_done="$(state_get '[.sprints[] | select(.status == "done")] | length')"
  log "daemon up for $run_id (pid $$, agent: $OCEAN_AGENT, permissions: $OCEAN_PERMISSIONS, max iterations: $OCEAN_MAX_ITERATIONS)"

  while :; do
    if [ -f "$OCEAN_DIR/STOP" ]; then
      log "STOP file present — exiting cleanly"
      notify "ocean run $run_id: daemon stopped by STOP file"
      exit 0
    fi

    status="$(state_get .status)"
    case "$status" in
      complete)
        if verify_gate; then
          if [ "$(state_get .status)" = "blocked" ]; then
            exit 0
          fi
          notify "ocean run $run_id COMPLETE ✔ — report: $OCEAN_DIR/REPORT.md"
          log "run complete — daemon exiting"
          exit 0
        fi
        continue ;;  # reopened — next loop iteration launches a fix worker
      blocked)
        notify "ocean run $run_id BLOCKED: $(state_get '.blockers[-1] // "unknown"')"
        log "run blocked — daemon exiting (fix, then: ocean.sh unblock && ocean-daemon.sh start)"
        exit 0 ;;
      paused|aborted)
        log "run is $status — daemon exiting"
        exit 0 ;;
      planning|running) ;;
      *)
        log "unknown status '$status' — exiting"
        exit 0 ;;
    esac

    iter="$(bash "$OCEAN_SH" iteration)"
    if [ "$iter" -gt "$OCEAN_MAX_ITERATIONS" ]; then
      bash "$OCEAN_SH" block "hit OCEAN_MAX_ITERATIONS ($OCEAN_MAX_ITERATIONS) — budget guard" >/dev/null
      notify "ocean run $run_id stopped: iteration budget ($OCEAN_MAX_ITERATIONS) exhausted"
      exit 0
    fi

    logfile="$OCEAN_DIR/logs/iter-$(printf '%03d' "$iter").log"
    log "iteration $iter starting (status: $status) → $logfile"
    run_worker "$logfile"; rc=$?
    log "iteration $iter finished (exit $rc)"

    if hit_usage_limit "$logfile"; then
      limits=$((limits + 1)); failures=0
      limit_backoff "$logfile" "$limits"
      continue
    fi
    limits=0

    if [ "$rc" -ne 0 ]; then
      failures=$((failures + 1))
      if [ "$failures" -ge "$OCEAN_MAX_FAILURES" ]; then
        bash "$OCEAN_SH" block "worker failed $failures times in a row (see $logfile)" >/dev/null
        notify "ocean run $run_id blocked: $failures consecutive worker failures"
        exit 0
      fi
      log "worker failed ($failures/$OCEAN_MAX_FAILURES consecutive) — retrying after ${OCEAN_BACKOFF_BASE}s"
      sleep "$OCEAN_BACKOFF_BASE"
      continue
    fi
    failures=0

    # Per-sprint progress notification (so you can watch from your phone
    # via OCEAN_NOTIFY_CMD without tailing logs).
    done_n="$(state_get '[.sprints[] | select(.status == "done")] | length')"
    if [ "$done_n" -gt "$prev_done" ] 2>/dev/null; then
      notify "ocean run $run_id: sprint $done_n/$(state_get '.sprints | length') done — $(state_get '[.sprints[] | select(.status == "done")][-1].title')"
      prev_done="$done_n"
    fi

    # Stall detection: if the state fingerprint hasn't moved across
    # OCEAN_STALL_LIMIT successful iterations, workers are spinning.
    fingerprint="$(jq -c '{status, current_sprint, sprints: [.sprints[].status], last_checkpoint}' "$STATE")"
    if [ "$fingerprint" = "$prev_fingerprint" ]; then
      stall=$((stall + 1))
      log "no state progress ($stall/$OCEAN_STALL_LIMIT)"
      if [ "$stall" -ge "$OCEAN_STALL_LIMIT" ]; then
        bash "$OCEAN_SH" block "no state progress across $stall iterations — workers are stuck (see $OCEAN_DIR/logs/)" >/dev/null
        notify "ocean run $run_id blocked: stalled"
        exit 0
      fi
    else
      stall=0
    fi
    prev_fingerprint="$fingerprint"

    sleep "$OCEAN_LOOP_SLEEP"
  done
}

launchd_label() {
  echo "com.boil-ocean.$(basename "$PROJECT_ROOT" | tr -cd 'a-zA-Z0-9-' | tr 'A-Z' 'a-z')"
}

launchd_plist() { echo "$HOME/Library/LaunchAgents/$(launchd_label).plist"; }

cmd="${1:-status}"
case "$cmd" in

  run)   # foreground loop (launchd and debugging)
    mkdir -p "$OCEAN_DIR/logs" 2>/dev/null
    main_loop
    ;;

  once)  # single iteration — for cron on Linux: */10 * * * * cd /proj && ocean-daemon.sh once
    need_run
    acquire_lock
    export OCEAN_DIR
    status="$(state_get .status)"
    case "$status" in
      planning|running) ;;
      *) echo "run status is '$status' — nothing to do"; exit 0 ;;
    esac
    [ -f "$OCEAN_DIR/STOP" ] && { echo "STOP file present"; exit 0; }
    iter="$(bash "$OCEAN_SH" iteration)"
    [ "$iter" -gt "$OCEAN_MAX_ITERATIONS" ] && { bash "$OCEAN_SH" block "iteration budget exhausted" >/dev/null; exit 0; }
    logfile="$OCEAN_DIR/logs/iter-$(printf '%03d' "$iter").log"
    log "single iteration $iter → $logfile"
    run_worker "$logfile" || true
    ;;

  start) # background daemon
    need_run
    if [ -d "$LOCK" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      echo "daemon already running (pid $(cat "$LOCK/pid"))"
      exit 0
    fi
    rm -f "$OCEAN_DIR/STOP"
    nohup bash "$0" run >> "$DLOG" 2>&1 &
    echo "daemon started (pid $!) — logs: $DLOG"
    echo "stop gracefully with: bash $0 stop"
    ;;

  stop)
    need_run
    touch "$OCEAN_DIR/STOP"
    echo "STOP file created — daemon exits before the next iteration."
    if [ "${2:-}" = "--now" ] && [ -d "$LOCK" ]; then
      pid="$(cat "$LOCK/pid" 2>/dev/null || echo "")"
      [ -n "$pid" ] && kill "$pid" 2>/dev/null && echo "daemon (pid $pid) killed"
    else
      echo "(a running worker will finish its current session first; use 'stop --now' to kill immediately)"
    fi
    ;;

  status)
    if [ -d "$LOCK" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      echo "daemon: RUNNING (pid $(cat "$LOCK/pid"))"
    else
      echo "daemon: not running"
    fi
    [ -f "$STATE" ] && bash "$OCEAN_SH" status
    ;;

  logs)
    need_run
    tail -n 50 -f "$DLOG"
    ;;

  doctor)  # preflight checks — run before starting a long unattended run
    okc=0; warnc=0
    okline()   { echo "  PASS  $1"; okc=$((okc+1)); }
    warnline() { echo "  WARN  $1"; warnc=$((warnc+1)); }
    echo "boil-the-ocean doctor (agent: $OCEAN_AGENT, permissions: $OCEAN_PERMISSIONS)"
    command -v jq >/dev/null 2>&1 && okline "jq available" || warnline "jq missing — required (brew install jq)"
    if [ "$OCEAN_AGENT" = "custom" ]; then
      [ -n "$OCEAN_WORKER_CMD" ] && okline "OCEAN_WORKER_CMD set" || warnline "OCEAN_AGENT=custom but OCEAN_WORKER_CMD is empty"
    else
      bin="$(agent_bin)"
      command -v "$bin" >/dev/null 2>&1 && okline "agent binary found: $bin" || warnline "agent binary not on PATH: $bin"
    fi
    [ -f "$SKILL_FILE" ] && okline "protocol file present: $SKILL_FILE" || warnline "protocol file missing: $SKILL_FILE"
    git rev-parse --git-dir >/dev/null 2>&1 && okline "inside a git repository" || warnline "not a git repo — sprint commits will fail"
    if [ -f "$STATE" ]; then
      jq empty "$STATE" 2>/dev/null && okline "state.json valid (status: $(state_get .status))" || warnline "state.json is corrupt"
      verify="$(state_get '.verify_cmd // ""' 2>/dev/null)"
      if [ -n "$verify" ]; then
        bash -c "$verify" >/dev/null 2>&1 && okline "verify_cmd passes right now: $verify" || warnline "verify_cmd currently fails: $verify (fine if the work isn't done yet)"
      else
        warnline "no verify_cmd set — completion will be accepted without an independent gate"
      fi
    else
      warnline "no run initialized yet (ocean.sh init <spec> --verify-cmd '<cmd>')"
    fi
    if [ -d "$LOCK" ] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      okline "daemon running (pid $(cat "$LOCK/pid"))"
    else
      echo "  INFO  daemon not running"
    fi
    echo ""
    echo "$okc pass, $warnc warn"
    [ "$warnc" -eq 0 ]
    ;;

  install-launchd)  # survives reboots and crashes (macOS)
    need_run
    [ "$(uname)" = "Darwin" ] || { echo "launchd is macOS-only; on Linux use cron with 'once' (see README)"; exit 1; }
    plist="$(launchd_plist)"
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(launchd_label)</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/ocean-daemon.sh</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key><string>$PROJECT_ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$PATH</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>StandardOutPath</key><string>$PROJECT_ROOT/$OCEAN_DIR/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$PROJECT_ROOT/$OCEAN_DIR/logs/launchd.log</string>
</dict>
</plist>
EOF
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
    echo "launchd agent installed: $plist"
    echo "The run now survives reboots and daemon crashes. Remove with: bash $0 uninstall-launchd"
    ;;

  uninstall-launchd)
    plist="$(launchd_plist)"
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "launchd agent removed"
    ;;

  *)
    echo "usage: ocean-daemon.sh <start|run|once|stop [--now]|status|logs|doctor|install-launchd|uninstall-launchd>" >&2
    exit 1
    ;;
esac
