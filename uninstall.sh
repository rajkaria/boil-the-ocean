#!/usr/bin/env bash
# ============================================================================
# Boil the Ocean Uninstaller — removes symlinks, hook registrations, and
# agent-memory pointer blocks. Per-project .ocean/ state dirs are kept.
# ============================================================================
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

# --- Claude Code symlinks ---
for s in ocean.sh ocean-daemon.sh ocean-stop-guard.sh ocean-announce.sh; do
  rm -f "$CLAUDE_DIR/scripts/$s"
done
for c in ocean.md ocean-status.md ocean-stop.md; do
  rm -f "$CLAUDE_DIR/commands/$c"
done
rm -f "$CLAUDE_DIR/skills/boil-ocean"
echo "[+] Claude Code symlinks removed"

# --- CLI symlinks ---
rm -f "$HOME/.local/bin/ocean" "$HOME/.local/bin/ocean-daemon"
echo "[+] CLI symlinks removed"

# --- Claude Code hook registrations ---
if [ -f "$SETTINGS_FILE" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$SETTINGS_FILE" <<'PYEOF'
import json, sys

settings_file = sys.argv[1]
with open(settings_file) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks.keys()):
    kept = []
    for entry in hooks[event]:
        inner = [h for h in entry.get("hooks", []) if "ocean-" not in h.get("command", "")]
        if inner:
            entry["hooks"] = inner
            kept.append(entry)
        elif entry.get("hooks"):
            removed += 1
        else:
            kept.append(entry)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"[+] Claude Code hook registrations removed: {removed}")
PYEOF
fi

# --- Pointer blocks in agent memory files ---
for f in "$HOME/.codex/AGENTS.md" "$HOME/.gemini/GEMINI.md"; do
  if [ -f "$f" ] && grep -q "boil-the-ocean:start" "$f"; then
    tmp="$(mktemp)"
    awk '/<!-- boil-the-ocean:start -->/{skip=1} !skip{print} /<!-- boil-the-ocean:end -->/{skip=0}' "$f" > "$tmp"
    mv "$tmp" "$f"
    echo "[+] Pointer block removed from $f"
  fi
done

echo "[+] boil-the-ocean uninstalled. Per-project .ocean/ directories were kept."
echo "    If you installed launchd agents for projects, remove each with:"
echo "    bash scripts/ocean-daemon.sh uninstall-launchd   (from that project root)"
