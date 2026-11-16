#!/usr/bin/env bash
# Tests for handoff-gate.sh. Feeds PreToolUse JSON on stdin, asserts exit code and stdout.
# The issue lookup is mocked with a stub `curl` (LOOKUP: impl | repro | fail), and `gh`
# with a stub (GH_MODE: green | red | running | none_sha | none_ever | fail). git is real:
# a throwaway repo with a bare remote whose path contains github.com.
# Run: bash hooks/test_handoff_gate.sh   Exit 0 = all pass.
GATE="${GATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff-gate.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "${LOOKUP:-impl}" in
  impl) echo '{"id":"x","parentId":"p","labels":[{"name":"kind:impl"}]}' ;;
  repro) echo '{"id":"x","parentId":"p","labels":[{"name":"kind:repro"}]}' ;;
  *) exit 22 ;;
esac
STUB
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" --commit "*) per_sha=1 ;; *) per_sha=0 ;; esac
U=https://example.invalid/runs/42
case "${GH_MODE:-green}" in
  green) echo "[{\"status\":\"completed\",\"conclusion\":\"success\",\"databaseId\":42,\"url\":\"$U\"}]" ;;
  red) echo "[{\"status\":\"completed\",\"conclusion\":\"failure\",\"databaseId\":42,\"url\":\"$U\"}]" ;;
  running) echo "[{\"status\":\"in_progress\",\"conclusion\":\"\",\"databaseId\":42,\"url\":\"$U\"}]" ;;
  none_sha) if [ $per_sha = 1 ]; then echo '[]'; else echo '[{"databaseId":7}]'; fi ;;
  none_ever) echo '[]' ;;
  *) echo "To get started with GitHub CLI, please run: gh auth login" >&2; exit 4 ;;
esac
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"

# Repo with a pushed HEAD and the fast CI workflow file.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
REMOTE="$TMP/github.com/org/app.git"; REPO="$TMP/repo"
git init -q --bare "$REMOTE"
git init -q -b feat "$REPO"
mkdir -p "$REPO/.github/workflows"; echo 'name: ci' > "$REPO/.github/workflows/ci.yml"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin feat 2>/dev/null

API="/api/"; API="${API}issues/"
HANDOFF="curl -s -X PATCH http://localhost:3100${API}ISSUE-1 -H 'Content-Type: application/json' -d '{\"status\":\"in_review\",\"comment\":\"done\"}'"
fails=0; total=0

run() { # name lookup gh_mode expect(deny|none) command [extra env...]
  local name="$1" lookup="$2" ghm="$3" expect="$4" cmd="$5" out rc ok=1
  shift 5
  total=$((total+1))
  out="$(jq -nc --arg c "$cmd" --arg d "$REPO" '{tool_input:{command:$c},cwd:$d}' | \
    env PATH="$TMP/bin:$PATH" LOOKUP="$lookup" GH_MODE="$ghm" \
    PAPERCLIP_API_URL=http://localhost:3100 PAPERCLIP_API_KEY=k "$@" bash "$GATE" 2>"$TMP/err")"; rc=$?
  [ "$rc" -eq 0 ] || ok=0
  case "$expect" in
    deny) printf '%s' "$out" | grep -q '"permissionDecision":"deny"' || ok=0
          printf '%s' "$out" | grep -q '"permissionDecisionReason":"Hand-off blocked:' || ok=0 ;;
    none) [ -z "$out" ] || ok=0 ;;
  esac
  if [ "$ok" -eq 1 ]; then echo "[PASS] $name"; else echo "[FAIL] $name: rc=$rc out=$out err=$(cat "$TMP/err")"; fails=$((fails+1)); fi
}
err_has() { # name pattern
  total=$((total+1))
  if grep -q -- "$2" "$TMP/err"; then echo "[PASS] $1"; else echo "[FAIL] $1: err=$(cat "$TMP/err")"; fails=$((fails+1)); fi
}
reason_has() { # name pattern: checks $LAST, a gate stdout captured with gate_out
  total=$((total+1))
  if printf '%s' "$LAST" | grep -q -- "$2"; then echo "[PASS] $1"; else echo "[FAIL] $1: out=$LAST"; fails=$((fails+1)); fi
}
gate_out() { # lookup gh_mode command -> stdout of the gate
  jq -nc --arg c "$3" --arg d "$REPO" '{tool_input:{command:$c},cwd:$d}' | \
    env PATH="$TMP/bin:$PATH" LOOKUP="$1" GH_MODE="$2" PAPERCLIP_API_URL=http://localhost:3100 PAPERCLIP_API_KEY=k bash "$GATE" 2>/dev/null
}

run "non-handoff command passes" impl red none "ls -la && git status"
run "other status PATCH passes" impl red none "curl -X PATCH http://localhost:3100${API}ISSUE-1 -d '{\"status\":\"in_progress\"}'"
run "reviewer executionDecision passes" impl red none "curl -s -X PATCH http://localhost:3100${API}ISSUE-1 -d '{\"executionDecision\":\"request_changes\",\"comment\":\"no\"}'"
run "reviewer executionDecision with in_review status passes" impl red none "curl -s -X PATCH http://localhost:3100${API}ISSUE-1 -d '{\"status\":\"in_review\",\"executionDecision\":\"approve\"}'"
run "CLI --execution-decision passes" impl red none "paperclipai issue update ISSUE-1 --status in_review --execution-decision approve"
run "kind:repro hand-off is exempt" repro red none "$HANDOFF"
run "green CI allows the hand-off" impl green none "$HANDOFF"
run "red CI blocks" impl red deny "$HANDOFF"
LAST="$(gate_out impl red "$HANDOFF")"; reason_has "red message names the run url" "fast CI is red for .*example.invalid/runs/42"
run "running CI blocks" impl running deny "$HANDOFF"
LAST="$(gate_out impl running "$HANDOFF")"; reason_has "running message suggests gh run watch" "gh run watch 42"
run "CLI issue update --status in_review is gated" impl red deny "paperclipai issue update ISSUE-1 --status in_review --comment 'ready'"
run "httpie hand-off is gated" impl red deny "http PATCH http://localhost:3100${API}ISSUE-1 status=in_review"
run "workflow present but no run for this SHA blocks" impl none_sha deny "$HANDOFF"
LAST="$(gate_out impl none_sha "$HANDOFF")"; reason_has "pending message" "no CI run yet for"
run "workflow never ran allows with a note" impl none_ever none "$HANDOFF"
err_has "never-ran note" "no fast CI configured"
run "workflow file absent allows" impl red none "$HANDOFF" HANDOFF_GATE_CI_WORKFLOW=missing.yml
err_has "absent-workflow note" "no fast CI configured"
run "gh unauthenticated fails open" impl fail none "$HANDOFF"
err_has "gh failure warning" "gh run list failed"
run "lookup failure fails open" fail red none "$HANDOFF"
err_has "lookup failure warning" "issue lookup failed"
run "warn mode prints and allows" impl red none "$HANDOFF" HANDOFF_GATE=warn
err_has "warn mode message on stderr" "^Hand-off blocked: fast CI is red"
run "off mode allows silently" impl red none "$HANDOFF" HANDOFF_GATE=off

# Unpushed HEAD: commit locally without pushing.
echo x > "$REPO/x.txt"; git -C "$REPO" add x.txt; git -C "$REPO" commit -qm local
run "unpushed HEAD blocks" impl green deny "$HANDOFF"
LAST="$(gate_out impl green "$HANDOFF")"; reason_has "push message names the branch" "Hand-off blocked: push feat first; CI runs on the pushed commit"
git -C "$REPO" push -q origin feat 2>/dev/null
run "after the push a green CI allows" impl green none "$HANDOFF"

# No GitHub remote: allow with a note.
git -C "$REPO" remote set-url origin "$TMP/elsewhere.git"
git init -q --bare "$TMP/elsewhere.git"; git -C "$REPO" push -q origin feat 2>/dev/null
run "no GitHub remote allows" impl red none "$HANDOFF"
err_has "no-remote note" "no fast CI configured"

echo; echo "$((total-fails))/$total passed"
[ "$fails" -eq 0 ]
