# Hooks

Wired by `claude-settings.json` (PreToolUse on Bash, in order): `rtk hook claude`,
`git-guard.py`, `completion-gate.sh`, `handoff-gate.sh`. A gate blocks by exiting 0 with
a `permissionDecision: "deny"` JSON on stdout; exit 0 with no output means no opinion.

## completion-gate.sh

Blocks marking a top-level issue `done` without visual evidence or a WAIVER file. See the
header of the script. Tests: `bash hooks/test_completion_gate.sh`.

## handoff-gate.sh

Blocks a hand-off (an issue PATCH or `issue update` setting status `in_review`) until the
fast CI workflow is green on the pushed HEAD commit, so no reviewer is woken on an
unpushed or red commit. Parsing is shared with the completion gate
(`handoff_gate_parse.py` imports `completion_gate_parse.py`).

- Not gated: any call carrying `executionDecision` / `--execution-decision` (a
  reviewer's verdict), and `kind:repro` issues (no code change).
- Blocks (every reason starts with `Hand-off blocked:`):
  - `push <branch> first; CI runs on the pushed commit` (HEAD on no remote branch)
  - `fast CI is red for <sha> (<url>). Fix it and push before handing off.`
  - `fast CI is still running for <sha> (<url>). Wait for it (e.g. gh run watch <id>), then hand off again.`
  - `no CI run yet for <sha>; push triggers it, wait and retry.`
- Allowed with a stderr note: no git repo, no GitHub remote, no
  `.github/workflows/<workflow>` file, or a workflow that has never run.
- Fails open with a stderr warning: issue lookup fails, `gh` missing / unauthenticated
  / erroring, command unparsable. QA still holds on missing or red CI.

Environment: `HANDOFF_GATE` = `enforce` (default) | `warn` (print the reason, allow) |
`off`; `HANDOFF_GATE_CI_WORKFLOW` (default `ci.yml`); `HANDOFF_GATE_REPO_DIR` (default
the hook's cwd); `HANDOFF_GATE_GH` / `HANDOFF_GATE_GIT` (binaries, for tests). At most two
`gh run list` calls, each under a 6 s timeout.

Tests: `bash hooks/test_handoff_gate.sh`.

## git-guard.py

Git and GitHub policy guard. Tests: `python3 hooks/test_git_guard_<name>.py` for each file (or `python3 -m pytest hooks/`).
