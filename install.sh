#!/usr/bin/env bash
# ============================================================================
# Boil the Ocean Installer
#
#   ./install.sh              install for Claude Code (skill + commands + hooks)
#   ./install.sh codex        install for OpenAI Codex CLI (AGENTS.md pointer)
#   ./install.sh gemini       install for Gemini CLI (GEMINI.md pointer)
#   ./install.sh bin          just the CLI: `ocean` + `ocean-daemon` on PATH
#   ./install.sh all          all of the above
#
# Everything is symlinked to this clone, so `git pull` updates the install.
# Per-agent details: docs/agents/. Claude Code can also consume this repo
# directly as a plugin (.claude-plugin/ + hooks/hooks.json are wired for it).
# ============================================================================
set -euo pipefail

TARGET="${1:-claude}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$REPO_DIR/scripts/ocean.sh" ] || { echo "[x] run this from the boil-the-ocean repo"; exit 1; }

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

command -v jq >/dev/null 2>&1 || warn "jq not found — the scripts require it (macOS ships it; else: brew install jq / apt install jq)"

chmod +x "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/install.sh "$REPO_DIR"/uninstall.sh "$REPO_DIR"/tests/*.sh 2>/dev/null || true

# --- shared: CLI symlinks ---------------------------------------------------
install_bin() {
  local bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir"
  ln -sf "$REPO_DIR/scripts/ocean.sh" "$bin_dir/ocean"
  ln -sf "$REPO_DIR/scripts/ocean-daemon.sh" "$bin_dir/ocean-daemon"
  info "CLI installed: ocean, ocean-daemon → $bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) warn "$bin_dir is not on your PATH — add:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
}

# --- shared: pointer block for agent memory files (AGENTS.md / GEMINI.md) ---
# Kept to four lines on purpose: these files load into EVERY session.
install_pointer() {
  local file="$1" label="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "boil-the-ocean:start" "$file" 2>/dev/null; then
    info "$label already has the boil-the-ocean pointer — skipped"
    return 0
  fi
  cat >> "$file" <<EOF

<!-- boil-the-ocean:start -->
## boil-the-ocean
If a repository contains \`.ocean/state.json\`, an autonomous boil-the-ocean run is active there.
The binding worker protocol is $REPO_DIR/skills/boil-ocean/SKILL.md — when asked to act as an
autonomous worker (or to resume "the ocean run"), read that file first and follow it exactly.
Run state is mutated ONLY via \`bash $REPO_DIR/scripts/ocean.sh <cmd>\` — never edit state.json by hand.
<!-- boil-the-ocean:end -->
EOF
  info "$label: pointer block appended ($file)"
}

install_claude() {
  local claude_dir="$HOME/.claude"
  [ -d "$claude_dir" ] || { error "~/.claude not found. Is Claude Code installed?"; return 1; }
  command -v python3 >/dev/null 2>&1 || { error "python3 is required for safe settings.json merging."; return 1; }
  mkdir -p "$claude_dir/scripts" "$claude_dir/commands" "$claude_dir/skills"

  for s in ocean.sh ocean-daemon.sh ocean-stop-guard.sh ocean-announce.sh; do
    ln -sf "$REPO_DIR/scripts/$s" "$claude_dir/scripts/$s"
  done
  info "Claude Code: scripts linked into $claude_dir/scripts"

  for c in ocean.md ocean-status.md ocean-stop.md; do
    ln -sf "$REPO_DIR/commands/$c" "$claude_dir/commands/$c"
  done
  info "Claude Code: commands linked — /ocean, /ocean-status, /ocean-stop"

  ln -sfn "$REPO_DIR/skills/boil-ocean" "$claude_dir/skills/boil-ocean"
  info "Claude Code: skill linked — boil-ocean"

  python3 - "$claude_dir/settings.json" "$claude_dir/scripts" <<'PYEOF'
import json, sys, os

settings_file, scripts_dir = sys.argv[1], sys.argv[2]
settings = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            print(f"[x] {settings_file} is not valid JSON — fix it and re-run", file=sys.stderr)
            sys.exit(1)

hooks = settings.setdefault("hooks", {})

def ensure(event, cmd):
    entries = hooks.setdefault(event, [])
    for e in entries:
        for h in e.get("hooks", []):
            if cmd in h.get("command", ""):
                return False
    entries.append({"matcher": "", "hooks": [{"type": "command", "command": f'bash "{cmd}"'}]})
    return True

added = []
if ensure("Stop", f"{scripts_dir}/ocean-stop-guard.sh"):
    added.append("Stop → ocean-stop-guard")
if ensure("SessionStart", f"{scripts_dir}/ocean-announce.sh"):
    added.append("SessionStart → ocean-announce")

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

for a in added:
    print(f"[+] Claude Code: hook registered — {a}")
if not added:
    print("[+] Claude Code: hooks already registered")
PYEOF
  install_bin
}

install_codex() {
  command -v codex >/dev/null 2>&1 || warn "codex CLI not found on PATH — pointer installed anyway; install codex before starting a run"
  install_pointer "$HOME/.codex/AGENTS.md" "Codex"
  install_bin
  echo ""
  info "Codex quickstart (from any project root):"
  echo "      ocean init docs/SPEC.md --verify-cmd 'npm test'"
  echo "      OCEAN_AGENT=codex ocean-daemon start"
}

install_gemini() {
  command -v gemini >/dev/null 2>&1 || warn "gemini CLI not found on PATH — pointer installed anyway; install gemini before starting a run"
  install_pointer "$HOME/.gemini/GEMINI.md" "Gemini CLI"
  install_bin
  echo ""
  info "Gemini quickstart (from any project root):"
  echo "      ocean init docs/SPEC.md --verify-cmd 'npm test'"
  echo "      OCEAN_AGENT=gemini ocean-daemon start"
}

echo ""
echo -e "  ${BOLD}Boil the Ocean Installer${NC}"
echo "  ========================"
echo ""

case "$TARGET" in
  claude) install_claude ;;
  codex)  install_codex ;;
  gemini) install_gemini ;;
  bin)    install_bin ;;
  all)    install_claude; echo ""; install_codex; echo ""; install_gemini ;;
  *)      error "unknown target '$TARGET' (claude|codex|gemini|bin|all)"; exit 1 ;;
esac

echo ""
info "Done. Preflight-check any project with:  ocean-daemon doctor"
info "Docs: README.md · docs/agents/ · docs/CONFIGURATION.md"
echo ""
