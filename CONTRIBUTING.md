# Contributing

Thanks for wanting to make the ocean boil harder. This project values small, testable,
auditable changes — it runs unattended on other people's machines, so the bar for
"obviously correct" is high.

## Dev setup

```bash
git clone https://github.com/rajkaria/boil-the-ocean.git
cd boil-the-ocean
bash tests/test-ocean.sh
```

That's it. Dependencies: `bash`, `jq`, `git`, `python3` (installer tests exercise the
settings.json merge). The suite is fully offline — the daemon is tested against a mock
agent binary and the installer against a fake `$HOME`, so tests cost zero tokens, touch
nothing outside `mktemp -d`, and run in seconds.

## Ground rules

1. **Every behavior change ships with a test.** The suite covers the state manager,
   the daemon loop (completion, limits, stalls, failures, verify gate, budget), both
   hooks, and every agent adapter. Follow the existing patterns — each daemon test
   scripts a mock worker via `MOCK_SCRIPT`.
2. **Keep bash 3.2 compatible** (macOS default): no associative arrays, no `${var,,}`,
   no `mapfile`.
3. **`state.json` is sacred**: any new field goes through `ocean.sh`, gets atomic
   writes for free, and gets documented in `docs/STATE.md`.
4. **Protocol (SKILL.md) changes are tested like code.** The protocol was developed
   against observed agent failures; if you change behavioral text, run a
   pressure-scenario check (give the file to a fresh agent session with a tempting
   scenario — e.g. "huge spec, tired, wants to ask a question" — and verify
   compliance). Describe the scenario + outcome in your PR.
5. **Docs move with the code.** New env var → `docs/CONFIGURATION.md`; new adapter →
   `docs/agents/<NAME>.md`; new failure mode → `docs/TROUBLESHOOTING.md`.

## Adding an agent adapter

The most-wanted contribution. Recipe in
[docs/agents/CUSTOM.md § Adding a first-class adapter](docs/agents/CUSTOM.md) — in
short: config var, flags function mapping `safe`/`standard`/`yolo`, `run_worker` case,
limit-regex additions, a mock-binary test, and an agent doc. Aim for the whole thing
in one screenful of diff.

## Release checklist (maintainers)

1. `bash tests/test-ocean.sh` green on macOS + Linux (CI covers both).
2. Bump `VERSION` **and** `.claude-plugin/plugin.json` in lockstep — the test suite
   asserts they match, and `ocean version --check` / `ocean upgrade` key off `VERSION`.
3. Update `CHANGELOG.md`.
4. Tag: `git tag vX.Y.Z && git push --tags`. Pushing to `main` is what makes the new
   version visible to every install's update check.

## Conduct

Be kind, be concrete, assume good faith. Disagreements get settled with a failing
test case, not adjectives.
