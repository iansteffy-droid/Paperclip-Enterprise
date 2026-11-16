#!/usr/bin/env bash
# Tests validate-profile.sh against the template, the default profile and mutated copies.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/validate-profile.sh"
PROFILES="$DIR/../profiles"
fail=0
check() { if "${@:2}"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

out="$("$SH" "$PROFILES/_template.md" 2>&1)"; rc=$?
check "template fails (placeholders)" test "$rc" = 1

out="$("$SH" "$PROFILES/vue-nest-mongo.md" 2>&1)"; rc=$?
check "default profile passes" test "$rc" = 0

grep -v '^| typecheck ' "$PROFILES/vue-nest-mongo.md" > "$TMP/no-typecheck.md"
out="$("$SH" "$TMP/no-typecheck.md" 2>&1)"; rc=$?
check "missing typecheck row exits 1" test "$rc" = 1
check "missing row is named" grep -qF "typecheck" <<<"$out"

grep -v '^## Branching' "$PROFILES/vue-nest-mongo.md" > "$TMP/no-branching.md"
out="$("$SH" "$TMP/no-branching.md" 2>&1)"; rc=$?
check "missing heading exits 1" test "$rc" = 1
check "missing heading is named" grep -qF "## Branching" <<<"$out"

sed 's/^| build \(.*\)| fast |/| build \1| medium |/' "$PROFILES/vue-nest-mongo.md" > "$TMP/bad-cost.md"
out="$("$SH" "$TMP/bad-cost.md" 2>&1)"; rc=$?
check "invalid cost exits 1" test "$rc" = 1
check "invalid cost reports value and line" grep -qE "line [0-9]+.*medium" <<<"$out"

sed 's/^- ci_wait_minutes:.*/- ci_wait_minutes: soon/' "$PROFILES/vue-nest-mongo.md" > "$TMP/bad-limit.md"
out="$("$SH" "$TMP/bad-limit.md" 2>&1)"; rc=$?
check "non-integer limit exits 1" test "$rc" = 1
check "bad limit is named" grep -qF "ci_wait_minutes" <<<"$out"

sed 's/^| build | .*| fast | yes |$/| build |  | fast | yes |/' "$PROFILES/vue-nest-mongo.md" > "$TMP/empty-cmd.md"
out="$("$SH" "$TMP/empty-cmd.md" 2>&1)"; rc=$?
check "empty command cell exits 1" test "$rc" = 1
check "empty command names the row" grep -qF '"build"' <<<"$out"

sed 's/^| build | .*| fast | yes |$/| build | <command> | fast | yes |/' "$PROFILES/vue-nest-mongo.md" > "$TMP/ph-cmd.md"
out="$("$SH" "$TMP/ph-cmd.md" 2>&1)"; rc=$?
check "placeholder command cell exits 1" test "$rc" = 1
check "placeholder command names the row" grep -qF '"build"' <<<"$out"

grep -v '^- expected-failure:' "$PROFILES/vue-nest-mongo.md" > "$TMP/no-xfail.md"
out="$("$SH" "$TMP/no-xfail.md" 2>&1)"; rc=$?
check "missing expected-failure line exits 1" test "$rc" = 1
check "missing expected-failure is named" grep -qF "expected-failure:" <<<"$out"

sed 's/^- expected-failure:.*/- expected-failure: <marker>/' "$PROFILES/vue-nest-mongo.md" > "$TMP/ph-xfail.md"
out="$("$SH" "$TMP/ph-xfail.md" 2>&1)"; rc=$?
check "placeholder expected-failure exits 1" test "$rc" = 1
check "placeholder expected-failure reports line" grep -qE "line [0-9]+.*expected-failure" <<<"$out"

grep -v '^- fast-workflow:' "$PROFILES/vue-nest-mongo.md" > "$TMP/no-fw.md"
out="$("$SH" "$TMP/no-fw.md" 2>&1)"; rc=$?
check "missing fast-workflow exits 1" test "$rc" = 1
check "missing fast-workflow is named" grep -qF "fast-workflow:" <<<"$out"

sed 's/^- fast-workflow:.*/- fast-workflow: build and test/' "$PROFILES/vue-nest-mongo.md" > "$TMP/bad-fw.md"
out="$("$SH" "$TMP/bad-fw.md" 2>&1)"; rc=$?
check "non-file fast-workflow exits 1" test "$rc" = 1
check "bad fast-workflow reports line" grep -qE "line [0-9]+.*fast-workflow" <<<"$out"

sed 's/^- fast-workflow:.*/- fast-workflow: `checks.yaml`/' "$PROFILES/vue-nest-mongo.md" > "$TMP/other-fw.md"
out="$("$SH" "$TMP/other-fw.md" 2>&1)"; rc=$?
check "another workflow file name passes" test "$rc" = 0

sed 's/^- fast-workflow:.*/- fast-workflow: none/' "$PROFILES/vue-nest-mongo.md" > "$TMP/none-fw-fastci.md"
out="$("$SH" "$TMP/none-fw-fastci.md" 2>&1)"; rc=$?
check "fast-workflow none with fast ci:yes rows exits 1" test "$rc" = 1
check "the fast ci:yes rows are named" grep -qF "unit:client" <<<"$out"

sed -e 's/^- fast-workflow:.*/- fast-workflow: none/' -e 's/^\(| [a-z:-]* | .* | fast | \)yes |$/\1no |/' \
  "$PROFILES/vue-nest-mongo.md" > "$TMP/none-fw.md"
out="$("$SH" "$TMP/none-fw.md" 2>&1)"; rc=$?
check "fast-workflow none with no fast ci:yes row passes" test "$rc" = 0

out="$("$SH" "$TMP/does-not-exist.md" 2>&1)"; rc=$?
check "missing file exits 1" test "$rc" = 1
exit "$fail"
