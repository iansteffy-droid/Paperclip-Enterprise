#!/usr/bin/env bash
# handoff-gate.sh: PreToolUse(Bash) gate. Blocks a hand-off (a Paperclip issue PATCH or
# `issue update` that sets status "in_review") until the fast CI workflow is green on the
# handed-off commit, pushed, so a reviewer is never woken on an unpushed or red commit.
#
# The commit checked is the one the hand-off comment names (`HEAD: <sha>`, else the head of
# `Range: <base>..<head>`); only a comment naming neither falls back to the repo dir's HEAD.
# The fast workflow is HANDOFF_GATE_CI_WORKFLOW when set, else the profile's `## CI`
# `fast-workflow:` (.paperclip-enterprise/profile.md at that commit, else in the repo dir),
# else ci.yml. `fast-workflow: none` means no fast CI: the hand-off is allowed once pushed.
#
# Environment read:
#   HANDOFF_GATE               enforce (default) | warn (print the message, allow) | off
#   HANDOFF_GATE_CI_WORKFLOW   fast CI workflow file (.github/workflows/<name>); overrides the profile
#   HANDOFF_GATE_REPO_DIR      repo to check; default the hook input's cwd, else $PWD
#   HANDOFF_GATE_GH / HANDOFF_GATE_GIT   gh / git binaries (tests point these at stubs)
#   PAPERCLIP_API_URL / PAPERCLIP_API_KEY  issue lookup; a `kind:repro` issue is exempt
#
# Scope: hand-offs are found by handoff_gate_parse.py (shares completion_gate_parse.py's
# curl / httpie / wget parsing). A call carrying executionDecision (a reviewer's verdict)
# is never gated. Fails OPEN with a stderr warning when the issue lookup fails, when gh is
# missing, unauthenticated or errors, or when the command cannot be parsed: this gate
# is a fast-feedback check, and QA holds on missing or red CI anyway.
# Allowed with a note: no git repo, no GitHub remote, `fast-workflow: none`, no workflow
# file at the commit, or a workflow that has never run. Blocked: the named commit unknown
# to the repo, the commit on no remote branch, no run yet for it, run still queued / in
# progress, run completed and not green.
#
# Contract (same as completion-gate.sh): exit 0 with no output = no opinion;
# exit 0 with deny JSON = block. Every block reason starts with "Hand-off blocked:".

mode="${HANDOFF_GATE:-enforce}"
[ "$mode" = off ] && exit 0
input="$(cat 2>/dev/null)"
[ -n "$input" ] || exit 0
case "$input" in *in_review*) ;; *) exit 0 ;; esac

warn() { printf 'handoff-gate: %s\n' "$1" >&2; }
command -v jq >/dev/null 2>&1 || { warn "jq not installed; skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { warn "python3 not installed; skipping"; exit 0; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${HANDOFF_GATE_GH:-gh}"
GIT="${HANDOFF_GATE_GIT:-git}"
NO_CI="no fast CI configured; skipping (QA will hold on missing CI)"

block() {
  if [ "$mode" = warn ]; then
    printf '%s\n' "$1" >&2
    exit 0
  fi
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
with_timeout() { # secs cmd...
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -n "$cmd" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // .tool_input.cwd // ""' 2>/dev/null)"
parsed="$(GATE_CMD="$cmd" GATE_CWD="$cwd" python3 -I -B "$HERE/handoff_gate_parse.py" 2>/dev/null)"
ids="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="HANDOFF"{print $2}')"
[ -n "$ids" ] || exit 0
named="$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="HANDOFF" && $3!=""{print $3; exit}')"

# Is at least one handed-off issue gated? kind:repro is exempt; lookup failure fails open.
gated=0
while IFS= read -r issue_id; do
  issue_id="${issue_id%%\?*}"
  case "$issue_id" in *PAPERCLIP_TASK_ID*) issue_id="${PAPERCLIP_TASK_ID:-$issue_id}" ;; esac
  issue_id="$(printf '%s' "$issue_id" | tr -d '"'\''${}\\')"
  [ -n "$issue_id" ] || continue
  if [ -z "${PAPERCLIP_API_URL:-}" ] || [ -z "${PAPERCLIP_API_KEY:-}" ]; then
    warn "cannot look up issue ${issue_id} (PAPERCLIP_API_URL/KEY unset); skipping the CI check"
    continue
  fi
  resp="$(curl -fsS -m 5 -H "Authorization: Bearer ${PAPERCLIP_API_KEY}" \
            "${PAPERCLIP_API_URL%/}/api/issues/${issue_id}" 2>/dev/null)"
  if [ -z "$resp" ] || ! printf '%s' "$resp" | jq -e 'type=="object"' >/dev/null 2>&1; then
    warn "issue lookup failed for ${issue_id}; skipping the CI check"
    continue
  fi
  printf '%s' "$resp" | jq -e '[(.labels // .issue.labels // [])[] | (.name? // .)] | index("kind:repro")' \
    >/dev/null 2>&1 && continue
  gated=1
done <<EOF
$ids
EOF
[ "$gated" = 1 ] || exit 0

# The commit under review: the one the hand-off comment names, else the repo dir's HEAD.
dir="${HANDOFF_GATE_REPO_DIR:-${cwd:-$PWD}}"
head="$("$GIT" -C "$dir" rev-parse HEAD 2>/dev/null)"
[ -n "$head" ] || { warn "not in a git repository ($dir); skipping"; exit 0; }
if [ -n "$named" ]; then
  sha="$("$GIT" -C "$dir" rev-parse -q --verify "${named}^{commit}" 2>/dev/null)"
  [ -n "$sha" ] || block "Hand-off blocked: the hand-off names commit ${named}, which ${dir} does not have; fetch, and name the commit you pushed."
else
  sha="$head"
fi
short="${sha:0:12}"
branch="$("$GIT" -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
{ [ "$sha" = "$head" ] && [ -n "$branch" ] && [ "$branch" != HEAD ]; } || branch="your branch"
remotes="$("$GIT" -C "$dir" remote -v 2>/dev/null)"

if [ -n "$remotes" ] && [ -z "$("$GIT" -C "$dir" branch -r --contains "$sha" 2>/dev/null)" ]; then
  block "Hand-off blocked: push ${branch} first; CI runs on the pushed commit (${short} is on no remote branch)."
fi

# The fast workflow: env override, else the profile's `fast-workflow:` at that commit, else ci.yml.
profile_fast_workflow() {
  local text
  text="$("$GIT" -C "$dir" show "${sha}:.paperclip-enterprise/profile.md" 2>/dev/null)" \
    || text="$(cat "$dir/.paperclip-enterprise/profile.md" 2>/dev/null)" || return 0
  printf '%s\n' "$text" | awk '
    /^## / { sec = $0; sub(/[ \t]+$/, "", sec); next }
    sec == "## CI" && /^(- )?`?fast-workflow:/ {
      v = $0; sub(/^[^:]*:/, "", v); gsub(/[` \t\r]/, "", v); print v; exit }'
}
WF="${HANDOFF_GATE_CI_WORKFLOW:-}"
[ -n "$WF" ] || WF="$(profile_fast_workflow)"
WF="${WF:-ci.yml}"
if [ "$WF" = none ]; then
  warn "the profile sets fast-workflow: none (no fast CI); allowed once pushed"; exit 0
fi
printf '%s' "$remotes" | grep -q 'github\.com' || { warn "$NO_CI"; exit 0; }
"$GIT" -C "$dir" cat-file -e "${sha}:.github/workflows/${WF}" 2>/dev/null \
  || [ -f "$dir/.github/workflows/$WF" ] || { warn "$NO_CI ($WF not found)"; exit 0; }

command -v "$GH" >/dev/null 2>&1 || { warn "gh not installed; cannot check fast CI, skipping"; exit 0; }
errf="$(mktemp 2>/dev/null || echo /dev/null)"
runs="$(cd "$dir" && with_timeout 6 "$GH" run list --commit "$sha" --workflow "$WF" \
          --json status,conclusion,databaseId,url --limit 5 2>"$errf")"; grc=$?
gerr="$(head -c 300 "$errf" 2>/dev/null | tr '\n' ' ')"; [ "$errf" = /dev/null ] || rm -f "$errf"
if [ "$grc" -ne 0 ] || ! printf '%s' "$runs" | jq -e 'type=="array"' >/dev/null 2>&1; then
  warn "gh run list failed (unauthenticated or offline?): ${gerr:-rc=$grc}; skipping the CI check"
  exit 0
fi

if [ "$(printf '%s' "$runs" | jq 'length')" = 0 ]; then
  ever="$(cd "$dir" && with_timeout 5 "$GH" run list --workflow "$WF" --json databaseId --limit 1 2>/dev/null)"
  if [ $? -ne 0 ] || ! printf '%s' "$ever" | jq -e 'type=="array"' >/dev/null 2>&1; then
    warn "gh run list failed; skipping the CI check"; exit 0
  fi
  [ "$(printf '%s' "$ever" | jq 'length')" = 0 ] && { warn "$NO_CI"; exit 0; }
  block "Hand-off blocked: no CI run yet for ${short}; push triggers it, wait and retry."
fi

status="$(printf '%s' "$runs" | jq -r '.[0].status // ""')"
conclusion="$(printf '%s' "$runs" | jq -r '.[0].conclusion // ""')"
run_id="$(printf '%s' "$runs" | jq -r '.[0].databaseId // ""')"
url="$(printf '%s' "$runs" | jq -r '.[0].url // ""')"

if [ "$status" != completed ]; then
  block "Hand-off blocked: fast CI is still running for ${short} (${url}). Wait for it (e.g. \`gh run watch ${run_id}\`), then hand off again."
fi
case "$conclusion" in
  success|neutral|skipped) exit 0 ;;
esac
block "Hand-off blocked: fast CI is red for ${short} (${url}). Fix it and push before handing off."
