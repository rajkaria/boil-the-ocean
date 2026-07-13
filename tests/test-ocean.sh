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
export OCEAN_UPDATE_CHECK=off   # keep the suite fully offline; version tests re-enable per-call

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
section "version + update check"
sem="$(tr -d '[:space:]' < "$ROOT/VERSION")"
echo "$sem" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && ok "VERSION is semver ($sem)" || bad "VERSION is semver" "$sem"
[ "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" = "$sem" ] \
  && ok "plugin.json version matches VERSION" || bad "plugin.json version matches VERSION"

bash "$OCEAN" version | grep -q "boil-the-ocean v$sem" && ok "ocean version prints the version" || bad "ocean version prints the version"
ln -sf "$OCEAN" "$TMP/bin/ocean-link"
bash "$TMP/bin/ocean-link" version | grep -q "v$sem" \
  && ok "version resolves the repo through the install symlink" || bad "version resolves the repo through the install symlink"

REMOTE_V="$TMP/remote-version"
echo "$sem" > "$REMOTE_V"
out="$(OCEAN_UPDATE_CHECK=on OCEAN_REMOTE_URL="file://$REMOTE_V" bash "$OCEAN" version --check)"
echo "$out" | grep -q "up to date" && ok "--check: equal remote → up to date" || bad "--check: equal remote → up to date" "$out"

echo "99.0.0" > "$REMOTE_V"
out="$(OCEAN_UPDATE_CHECK=on OCEAN_REMOTE_URL="file://$REMOTE_V" bash "$OCEAN" version --check)"
echo "$out" | grep -q "update available: v$sem → v99.0.0" && ok "--check: newer remote → update available" || bad "--check: newer remote → update available" "$out"

echo "0.0.1" > "$REMOTE_V"
out="$(OCEAN_UPDATE_CHECK=on OCEAN_REMOTE_URL="file://$REMOTE_V" bash "$OCEAN" version --check)"
echo "$out" | grep -q "up to date" && ok "--check: older remote (dev clone ahead) → up to date" || bad "--check: older remote → up to date" "$out"

echo "<html>404 Not Found</html>" > "$REMOTE_V"
out="$(OCEAN_UPDATE_CHECK=on OCEAN_REMOTE_URL="file://$REMOTE_V" bash "$OCEAN" version --check)"
echo "$out" | grep -q "skipped update check" && ok "--check: garbage remote → skipped, not a false positive" || bad "--check: garbage remote → skipped" "$out"

out="$(OCEAN_UPDATE_CHECK=off bash "$OCEAN" version --check)"
echo "$out" | grep -q "disabled" && ok "--check: OCEAN_UPDATE_CHECK=off disables the network" || bad "--check: OCEAN_UPDATE_CHECK=off" "$out"

# Doctor surfaces availability as INFO without failing the preflight
new_project
git init --quiet 2>/dev/null
bash "$OCEAN" init SPEC.md --verify-cmd "true" >/dev/null
echo "99.0.0" > "$REMOTE_V"
doctor_out="$(OCEAN_UPDATE_CHECK=on OCEAN_REMOTE_URL="file://$REMOTE_V" OCEAN_CLAUDE_BIN="$TMP/bin/claude" bash "$DAEMON" doctor 2>&1)"; doctor_rc=$?
echo "$doctor_out" | grep -q "INFO  update available" && [ "$doctor_rc" -eq 0 ] \
  && ok "doctor surfaces update availability as INFO" || bad "doctor surfaces update availability as INFO" "rc=$doctor_rc"

# ---------------------------------------------------------------------------
section "installer (fake HOME)"
FAKE="$TMP/fakehome"
mkdir -p "$FAKE/.claude"
mkdir -p "$TMP/agentbins"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/agentbins/codex";  chmod +x "$TMP/agentbins/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/agentbins/gemini"; chmod +x "$TMP/agentbins/gemini"

HOME="$FAKE" PATH="$TMP/agentbins:$PATH" bash "$ROOT/install.sh" auto >/dev/null 2>&1
irc=$?
[ "$irc" -eq 0 ] && ok "install.sh auto exits 0" || bad "install.sh auto exits 0" "rc=$irc"
[ -L "$FAKE/.claude/scripts/ocean.sh" ] && [ -L "$FAKE/.claude/scripts/ocean-daemon.sh" ] \
  && ok "auto: claude scripts linked" || bad "auto: claude scripts linked"
[ -L "$FAKE/.claude/commands/ocean.md" ] && [ -L "$FAKE/.claude/skills/boil-ocean" ] \
  && ok "auto: claude commands + skill linked" || bad "auto: claude commands + skill linked"
jq -e '.hooks.Stop and .hooks.SessionStart' "$FAKE/.claude/settings.json" >/dev/null 2>&1 \
  && ok "auto: claude hooks registered" || bad "auto: claude hooks registered"
grep -q "boil-the-ocean:start" "$FAKE/.codex/AGENTS.md" 2>/dev/null \
  && ok "auto: codex pointer appended (detected via PATH)" || bad "auto: codex pointer appended"
grep -q "boil-the-ocean:start" "$FAKE/.gemini/GEMINI.md" 2>/dev/null \
  && ok "auto: gemini pointer appended (detected via PATH)" || bad "auto: gemini pointer appended"
[ -L "$FAKE/.local/bin/ocean" ] && [ -L "$FAKE/.local/bin/ocean-daemon" ] \
  && ok "auto: ocean CLI on ~/.local/bin" || bad "auto: ocean CLI on ~/.local/bin"
targets="$(cat "$FAKE/.local/state/boil-the-ocean/installed-targets" 2>/dev/null)"
echo "$targets" | grep -qx "claude" && echo "$targets" | grep -qx "codex" && echo "$targets" | grep -qx "gemini" \
  && ok "auto: installed targets recorded for ocean upgrade" || bad "auto: installed targets recorded" "$targets"

HOME="$FAKE" PATH="$TMP/agentbins:$PATH" bash "$ROOT/install.sh" auto >/dev/null 2>&1
[ "$(grep -c "boil-the-ocean:start" "$FAKE/.codex/AGENTS.md")" = "1" ] \
  && ok "re-install is idempotent (pointer not duplicated)" || bad "re-install is idempotent"

HOME="$FAKE" bash "$ROOT/uninstall.sh" >/dev/null 2>&1
[ ! -e "$FAKE/.claude/scripts/ocean.sh" ] && [ ! -e "$FAKE/.local/bin/ocean" ] \
  && ok "uninstall removes symlinks" || bad "uninstall removes symlinks"
grep -q "boil-the-ocean:start" "$FAKE/.codex/AGENTS.md" 2>/dev/null \
  && bad "uninstall removes pointer blocks" || ok "uninstall removes pointer blocks"
jq -e '.hooks | to_entries | map(.value[].hooks[].command) | flatten | map(select(contains("ocean-"))) | length == 0' \
  "$FAKE/.claude/settings.json" >/dev/null 2>&1 \
  && ok "uninstall removes hook registrations" || bad "uninstall removes hook registrations"
[ ! -e "$FAKE/.local/state/boil-the-ocean" ] \
  && ok "uninstall removes install state" || bad "uninstall removes install state"

# ---------------------------------------------------------------------------
section "installer bootstrap (curl-style) + ocean upgrade"
# Bootstrap: install.sh alone in an empty dir must clone and hand off.
mkdir -p "$TMP/solo" "$TMP/gitmock"
cp "$ROOT/install.sh" "$TMP/solo/install.sh"
cat > "$TMP/gitmock/git" <<EOF
#!/usr/bin/env bash
# git mock: 'clone <url> <dest>' copies the real repo; everything else no-ops.
if [ "\$1" = "clone" ]; then
  for dest; do :; done
  cp -R "$ROOT" "\$dest"
  exit 0
fi
case "\$*" in
  *"pull --ff-only"*) echo "Already up to date."; exit 0 ;;
  *"status --porcelain"*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/gitmock/git"
FAKE2="$TMP/fakehome2"; mkdir -p "$FAKE2"
(cd "$TMP/solo" && HOME="$FAKE2" PATH="$TMP/gitmock:$PATH" bash install.sh bin >/dev/null 2>&1)
[ -f "$FAKE2/.boil-the-ocean/scripts/ocean.sh" ] \
  && ok "bootstrap clones the repo to ~/.boil-the-ocean" || bad "bootstrap clones the repo"
[ -L "$FAKE2/.local/bin/ocean" ] \
  && ok "bootstrap hands off to the clone's installer" || bad "bootstrap hands off to the clone's installer"
case "$(readlink "$FAKE2/.local/bin/ocean")" in
  "$FAKE2/.boil-the-ocean/"*) ok "bootstrap symlinks point into the clone" ;;
  *) bad "bootstrap symlinks point into the clone" "$(readlink "$FAKE2/.local/bin/ocean")" ;;
esac

# Upgrade: mocked git pull; re-runs the installer for recorded targets.
FAKE3="$TMP/fakehome3"; mkdir -p "$FAKE3"
out="$(HOME="$FAKE3" PATH="$TMP/gitmock:$PATH" bash "$OCEAN" upgrade 2>&1)"; urc=$?
[ "$urc" -eq 0 ] && echo "$out" | grep -q "already up to date" \
  && ok "upgrade pulls and reports up to date" || bad "upgrade pulls and reports up to date" "rc=$urc"
[ -L "$FAKE3/.local/bin/ocean" ] \
  && ok "upgrade re-runs the installer (default bin target)" || bad "upgrade re-runs the installer"

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
