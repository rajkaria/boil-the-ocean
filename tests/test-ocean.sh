#!/usr/bin/env bash
# ============================================================================
# test-ocean.sh — integration tests for boil-ocean
#
# Deterministic and offline: the daemon is exercised against a mock `claude`
# binary whose behavior each test scripts explicitly. No network, no real
# Claude sessions. Run: bash tests/test-ocean.sh
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCEAN="$ROOT/scripts/ocean.sh"
DAEMON="$ROOT/scripts/ocean-daemon.sh"
GUARD="$ROOT/scripts/ocean-stop-guard.sh"
ANNOUNCE="$ROOT/scripts/ocean-announce.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1${2:+ — $2}"; FAIL=$((FAIL+1)); }
section() { echo ""; echo "== $1"; }

# Fresh project dir with an initialized run. Sets $PROJ and cds into it.
new_project() {
  PROJ="$TMP/proj-$RANDOM$RANDOM"
  mkdir -p "$PROJ"
  cd "$PROJ" || exit 1
  echo "# Spec: build the thing" > SPEC.md
}

# Mock claude: runs whatever $MOCK_SCRIPT points at, ignoring all arguments.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
bash "$MOCK_SCRIPT"
EOF
chmod +x "$TMP/bin/claude"

# Fast daemon settings for every test
export OCEAN_CLAUDE_BIN="$TMP/bin/claude"
export OCEAN_LOOP_SLEEP=0
export OCEAN_BACKOFF_BASE=1
export OCEAN_ITERATION_TIMEOUT=30
export OCEAN_SH_PATH="$OCEAN"

# ---------------------------------------------------------------------------
section "syntax checks"
for f in "$OCEAN" "$DAEMON" "$GUARD" "$ANNOUNCE" "$ROOT/install.sh" "$ROOT/uninstall.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
if jq empty "$ROOT/hooks/hooks.json" 2>/dev/null && jq empty "$ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
  ok "hooks.json + plugin.json are valid JSON"
else
  bad "hooks.json + plugin.json are valid JSON"
fi

# ---------------------------------------------------------------------------
section "ocean.sh state lifecycle"
new_project
if bash "$OCEAN" init SPEC.md --verify-cmd "true" --goal "test goal" >/dev/null; then
  ok "init creates a run"
else
  bad "init creates a run"
fi
[ "$(jq -r .status .ocean/state.json)" = "planning" ] && ok "init status is planning" || bad "init status is planning"
[ -f .ocean/DECISIONS.md ] && ok "init seeds DECISIONS.md" || bad "init seeds DECISIONS.md"
bash "$OCEAN" init SPEC.md >/dev/null 2>&1 && bad "double init rejected" || ok "double init rejected"

bash "$OCEAN" sprint-add "Schema" >/dev/null
bash "$OCEAN" sprint-add "API" >/dev/null
[ "$(jq -r '.sprints | length' .ocean/state.json)" = "2" ] && ok "sprint-add registers sprints" || bad "sprint-add registers sprints"

bash "$OCEAN" plan-done >/dev/null
[ "$(jq -r .status .ocean/state.json)" = "running" ] && ok "plan-done → running" || bad "plan-done → running"

bash "$OCEAN" sprint-start 1 >/dev/null
[ "$(jq -r '.sprints[0].status' .ocean/state.json)" = "in_progress" ] && ok "sprint-start marks in_progress" || bad "sprint-start marks in_progress"
[ "$(jq -r .current_sprint .ocean/state.json)" = "1" ] && ok "sprint-start sets current_sprint" || bad "sprint-start sets current_sprint"
bash "$OCEAN" sprint-start 99 >/dev/null 2>&1 && bad "sprint-start rejects bad id" || ok "sprint-start rejects bad id"

bash "$OCEAN" sprint-done 1 --commit abc1234 >/dev/null
[ "$(jq -r '.sprints[0].status' .ocean/state.json)" = "done" ] && ok "sprint-done marks done" || bad "sprint-done marks done"
[ "$(jq -r '.sprints[0].commit' .ocean/state.json)" = "abc1234" ] && ok "sprint-done records commit" || bad "sprint-done records commit"

bash "$OCEAN" checkpoint --notes "next: API sprint" >/dev/null
[ "$(jq -r .notes .ocean/state.json)" = "next: API sprint" ] && ok "checkpoint saves notes" || bad "checkpoint saves notes"

bash "$OCEAN" block "needs a human" >/dev/null
[ "$(jq -r .status .ocean/state.json)" = "blocked" ] && ok "block → blocked" || bad "block → blocked"
bash "$OCEAN" unblock >/dev/null
[ "$(jq -r .status .ocean/state.json)" = "running" ] && ok "unblock → running" || bad "unblock → running"
bash "$OCEAN" reopen "verify failed" >/dev/null
[ "$(jq -r .reopen_count .ocean/state.json)" = "1" ] && ok "reopen bumps reopen_count" || bad "reopen bumps reopen_count"
bash "$OCEAN" set-status bogus >/dev/null 2>&1 && bad "set-status rejects invalid" || ok "set-status rejects invalid"
status_out="$(bash "$OCEAN" status)"
echo "$status_out" | grep -q "Schema" && ok "status renders sprint table" || bad "status renders sprint table"

# ---------------------------------------------------------------------------
section "daemon: happy path to completion"
new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "Only sprint" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export COUNT_FILE="$PROJ/count"
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<'EOF'
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  bash "$OCEAN_SH_PATH" sprint-done 1 --commit fff0000
  bash "$OCEAN_SH_PATH" checkpoint --notes "sprint 1 shipped"
else
  bash "$OCEAN_SH_PATH" set-status complete
fi
EOF
bash "$DAEMON" run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "daemon exits 0 on completion" || bad "daemon exits 0 on completion" "rc=$rc"
[ "$(jq -r .status .ocean/state.json)" = "complete" ] && ok "run reaches complete" || bad "run reaches complete"
[ "$(cat "$COUNT_FILE")" = "2" ] && ok "daemon relaunched worker across sessions" || bad "daemon relaunched worker across sessions" "count=$(cat "$COUNT_FILE")"
grep -q "run complete" .ocean/logs/daemon.log && ok "completion logged" || bad "completion logged"

# ---------------------------------------------------------------------------
section "daemon: usage-limit backoff then recovery"
new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export COUNT_FILE="$PROJ/count"
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<'EOF'
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  echo "Claude AI usage limit reached|1600000000"
  exit 1
fi
bash "$OCEAN_SH_PATH" set-status complete
EOF
bash "$DAEMON" run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "daemon survives usage limit" || bad "daemon survives usage limit" "rc=$rc"
grep -qi "backoff" .ocean/logs/daemon.log && ok "backoff was applied" || bad "backoff was applied"
[ "$(jq -r .status .ocean/state.json)" = "complete" ] && ok "run completes after limit reset" || bad "run completes after limit reset"

# ---------------------------------------------------------------------------
section "daemon: STOP file, iteration budget, stall detection"
new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
touch .ocean/STOP
export MOCK_SCRIPT="$PROJ/mock.sh"; echo "exit 0" > "$MOCK_SCRIPT"
bash "$DAEMON" run >/dev/null 2>&1
[ $? -eq 0 ] && grep -q "STOP file" .ocean/logs/daemon.log && ok "STOP file halts daemon" || bad "STOP file halts daemon"

new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"; echo "exit 0" > "$MOCK_SCRIPT"
OCEAN_MAX_ITERATIONS=0 bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "blocked" ] && jq -r '.blockers[0]' .ocean/state.json | grep -q "budget" \
  && ok "iteration budget guard blocks run" || bad "iteration budget guard blocks run"

new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"; echo "exit 0" > "$MOCK_SCRIPT"  # worker that makes no progress
OCEAN_STALL_LIMIT=2 bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "blocked" ] && jq -r '.blockers[0]' .ocean/state.json | grep -q "no state progress" \
  && ok "stall detection blocks spinning run" || bad "stall detection blocks spinning run"

# ---------------------------------------------------------------------------
section "daemon: consecutive worker failures"
new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"; echo "exit 7" > "$MOCK_SCRIPT"
OCEAN_MAX_FAILURES=2 bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "blocked" ] && jq -r '.blockers[0]' .ocean/state.json | grep -q "failed" \
  && ok "repeated failures block run" || bad "repeated failures block run"

# ---------------------------------------------------------------------------
section "daemon: verify gate"
new_project
bash "$OCEAN" init SPEC.md --verify-cmd "false" >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export COUNT_FILE="$PROJ/count"
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<'EOF'
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$COUNT_FILE"
bash "$OCEAN_SH_PATH" set-status complete
EOF
bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "blocked" ] && ok "failing verify_cmd ends blocked, not complete" || bad "failing verify_cmd ends blocked, not complete"
[ "$(jq -r .reopen_count .ocean/state.json)" = "2" ] && ok "verify gate reopened twice before blocking" || bad "verify gate reopened twice before blocking" "reopens=$(jq -r .reopen_count .ocean/state.json)"

new_project
bash "$OCEAN" init SPEC.md --verify-cmd "true" >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<EOF
bash "$OCEAN" set-status complete
EOF
bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "complete" ] && grep -q "verify gate PASSED" .ocean/logs/daemon.log \
  && ok "passing verify_cmd confirms completion" || bad "passing verify_cmd confirms completion"

# ---------------------------------------------------------------------------
section "multi-agent adapters"
new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<'EOF'
bash "$OCEAN_SH_PATH" set-status complete
EOF
OCEAN_AGENT=codex OCEAN_CODEX_BIN="$TMP/bin/claude" bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "complete" ] && grep -q "agent: codex" .ocean/logs/daemon.log \
  && ok "codex adapter drives the run" || bad "codex adapter drives the run"

new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<'EOF'
bash "$OCEAN_SH_PATH" set-status complete
EOF
OCEAN_AGENT=gemini OCEAN_GEMINI_BIN="$TMP/bin/claude" bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "complete" ] \
  && ok "gemini adapter drives the run" || bad "gemini adapter drives the run"

new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null
export MOCK_SCRIPT="$PROJ/mock.sh"
cat > "$MOCK_SCRIPT" <<'EOF'
bash "$OCEAN_SH_PATH" set-status complete
EOF
OCEAN_AGENT=custom OCEAN_WORKER_CMD='printf "%s" "$OCEAN_PROMPT" > prompt.txt; bash "$MOCK_SCRIPT"' \
  bash "$DAEMON" run >/dev/null 2>&1
[ "$(jq -r .status .ocean/state.json)" = "complete" ] \
  && ok "custom adapter drives the run" || bad "custom adapter drives the run"
grep -q "state.json" prompt.txt && grep -q "SKILL.md" prompt.txt \
  && ok "custom adapter receives the full protocol prompt" || bad "custom adapter receives the full protocol prompt"

bash "$OCEAN" set-status running >/dev/null
OCEAN_AGENT=custom OCEAN_WORKER_CMD='' bash "$DAEMON" once >/dev/null 2>&1
grep -q "OCEAN_WORKER_CMD" .ocean/logs/daemon.log \
  && ok "custom adapter without OCEAN_WORKER_CMD reports config error" || bad "custom adapter without OCEAN_WORKER_CMD reports config error"

# ---------------------------------------------------------------------------
section "doctor"
new_project
git init --quiet 2>/dev/null
bash "$OCEAN" init SPEC.md --verify-cmd "true" >/dev/null
doctor_out="$(OCEAN_CLAUDE_BIN="$TMP/bin/claude" bash "$DAEMON" doctor 2>&1)"; doctor_rc=$?
echo "$doctor_out" | grep -q "agent binary found" && [ "$doctor_rc" -eq 0 ] \
  && ok "doctor passes on a healthy setup" || bad "doctor passes on a healthy setup" "rc=$doctor_rc"
doctor_out="$(OCEAN_CLAUDE_BIN=/nonexistent-bin bash "$DAEMON" doctor 2>&1)"; doctor_rc=$?
echo "$doctor_out" | grep -q "not on PATH" && [ "$doctor_rc" -ne 0 ] \
  && ok "doctor warns on missing agent binary" || bad "doctor warns on missing agent binary"

# Regression: invoked via a symlink (as installed into ~/.local/bin), the daemon
# must still resolve sibling scripts and the protocol file in the real repo.
ln -sf "$DAEMON" "$TMP/bin/ocean-daemon-link"
doctor_out="$(OCEAN_CLAUDE_BIN="$TMP/bin/claude" bash "$TMP/bin/ocean-daemon-link" doctor 2>&1)"
echo "$doctor_out" | grep -q "protocol file present" \
  && ok "symlinked daemon resolves the real repo paths" || bad "symlinked daemon resolves the real repo paths" "$doctor_out"

# ---------------------------------------------------------------------------
section "stop-guard hook"
new_project
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" plan-done >/dev/null

out=$(echo '{}' | bash "$GUARD")
[ -z "$out" ] && ok "non-worker session: never blocked" || bad "non-worker session: never blocked"

sleep 1
out=$(echo '{}' | OCEAN_WORKER=1 OCEAN_CHECKPOINT_GRACE=0 bash "$GUARD")
echo "$out" | grep -q '"decision": "block"' && ok "worker + stale checkpoint: blocked" || bad "worker + stale checkpoint: blocked" "$out"
echo "$out" | grep -q "checkpoint --notes" && ok "block reason teaches the handoff" || bad "block reason teaches the handoff"

out=$(echo '{}' | OCEAN_WORKER=1 bash "$GUARD")
[ -z "$out" ] && ok "worker + fresh checkpoint (default grace): allowed" || bad "worker + fresh checkpoint (default grace): allowed"

out=$(echo '{"stop_hook_active": true}' | OCEAN_WORKER=1 OCEAN_CHECKPOINT_GRACE=0 bash "$GUARD")
[ -z "$out" ] && ok "stop_hook_active: allowed (no infinite loop)" || bad "stop_hook_active: allowed (no infinite loop)"

bash "$OCEAN" set-status complete >/dev/null
out=$(echo '{}' | OCEAN_WORKER=1 OCEAN_CHECKPOINT_GRACE=0 bash "$GUARD")
[ -z "$out" ] && ok "terminal status: allowed" || bad "terminal status: allowed"

# ---------------------------------------------------------------------------
section "announce hook"
new_project
out=$(bash "$ANNOUNCE")
[ -z "$out" ] && ok "silent when no run exists" || bad "silent when no run exists"
bash "$OCEAN" init SPEC.md >/dev/null
bash "$OCEAN" sprint-add "S1" >/dev/null
bash "$OCEAN" checkpoint --notes "resume at step 3" >/dev/null
out=$(bash "$ANNOUNCE")
echo "$out" | grep -q "BOIL-OCEAN" && echo "$out" | grep -q "resume at step 3" \
  && ok "announces active run with handoff notes" || bad "announces active run with handoff notes"

# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "  $PASS passed, $FAIL failed"
echo "=============================="
[ "$FAIL" -eq 0 ]
