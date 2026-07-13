# Boil the Ocean on Gemini CLI

Gemini workers run through `gemini -p` (headless prompt mode). The protocol file does
the behavioral work — no Gemini-side extension needed.

## Install

No clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/rajkaria/boil-the-ocean/main/install.sh | bash -s -- gemini
```

Or from a clone:

```bash
git clone https://github.com/rajkaria/boil-the-ocean.git
cd boil-the-ocean
./install.sh gemini
```

What this does:

| Piece | Where | What you get |
|---|---|---|
| Pointer block | `~/.gemini/GEMINI.md` | Four lines teaching every Gemini session: repos with `.ocean/state.json` have an active run; the protocol file is binding; state mutates only via `ocean.sh` |
| CLI | `~/.local/bin/` | `ocean`, `ocean-daemon` |

## Usage

```bash
cd your-project
ocean init docs/SPEC.md --verify-cmd "npm test" --goal "ship v1"
OCEAN_AGENT=gemini ocean-daemon doctor     # preflight: checks the gemini binary too
OCEAN_AGENT=gemini ocean-daemon start
```

Watch: `ocean-daemon logs` · Stop: `ocean-daemon stop` · Sprint table: `ocean status`.

## Permission mapping

| `OCEAN_PERMISSIONS` | Gemini flags | Meaning |
|---|---|---|
| `safe` | `--approval-mode auto_edit` | Edits auto-approved; shell commands are not — docs/refactor specs |
| `standard` *(default)* | `--yolo` | Full autonomy (Gemini CLI has no intermediate allowlist mode) |
| `yolo` | `--yolo` | Same as standard — Gemini's approval model is two-level |

Note the honest caveat: on Gemini, `standard` and `yolo` are identical because the
CLI exposes only auto-edit and yolo approval modes. If you want a harder boundary,
run the daemon inside a container and keep `--yolo`.

## Gemini-specific configuration

| Var | Notes |
|---|---|
| `OCEAN_GEMINI_BIN` | Binary name/path (default `gemini`) |
| `OCEAN_MODEL` | Passed as `-m` (e.g. `gemini-2.5-flash` for cheap sprints, `gemini-2.5-pro` for planning/fix passes) |
| `OCEAN_EXTRA_FLAGS` | Anything else the CLI accepts |

Limit handling: Gemini's quota phrasings (`quota exceeded`, `RESOURCE_EXHAUSTED`,
`429`, …) are detected and trigger exponential backoff. Free-tier quotas are daily —
for overnight runs on the free tier, set a generous `OCEAN_BACKOFF_MAX` and expect
the daemon to camp politely until quota returns:

```bash
OCEAN_AGENT=gemini OCEAN_BACKOFF_MAX=10800 ocean-daemon start
```

## Notes and caveats

- **No Stop hook on Gemini** — checkpoint discipline comes from the protocol text,
  backstopped by the daemon's stall detector (a run whose workers exit without moving
  state gets blocked, not looped).
- **Mixed fleets work**: plan with Gemini Pro, sprint with Flash, fix with Claude —
  state is agent-agnostic; set `OCEAN_AGENT`/`OCEAN_MODEL` per daemon start.
- **GEMINI.md in the project**: unaffected — the pointer lives in the global
  `~/.gemini/GEMINI.md` and only describes how to treat `.ocean/`.
