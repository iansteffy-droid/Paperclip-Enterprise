#!/usr/bin/env bash
# Starts a second (test) instance, so the kit instance on 3200 is never disturbed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/paperclip-instance.sh"
# Ports default to 3201/54331; set PE_TEST_PORT / PE_TEST_DB_PORT when those are taken.
export PE_TEST_PORT="${PE_TEST_PORT:-3201}" PE_TEST_DB_PORT="${PE_TEST_DB_PORT:-54331}"
ARGS=(--instance paperclip-enterprise-test --port ${PE_TEST_PORT} --db-port ${PE_TEST_DB_PORT})
CFG="$HOME/.paperclip/instances/paperclip-enterprise-test/config.json"
fail=0
check() { if "${@:2}"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
cleanup() { "$SH" stop "${ARGS[@]}" >/dev/null 2>&1; }
trap cleanup EXIT

"$SH" start "${ARGS[@]}"
check "health on ${PE_TEST_PORT}" curl -sf --max-time 5 http://127.0.0.1:${PE_TEST_PORT}/api/health -o /dev/null
check "config server.port == ${PE_TEST_PORT}" test "$(jq -r .server.port "$CFG" 2>/dev/null)" = ${PE_TEST_PORT}
check "config embeddedPostgresPort == ${PE_TEST_DB_PORT}" test "$(jq -r .database.embeddedPostgresPort "$CFG" 2>/dev/null)" = ${PE_TEST_DB_PORT}
check "other instance on 3100 untouched" curl -sf --max-time 5 http://127.0.0.1:3100/api/health -o /dev/null
"$SH" stop "${ARGS[@]}"
check "port ${PE_TEST_PORT} closed after stop" bash -c '! curl -s --max-time 3 http://127.0.0.1:${PE_TEST_PORT}/api/health -o /dev/null'

# Fix 2: changed --db-port on a stopped instance with existing config -> exit 2, config unchanged
before="$(cat "$CFG")"
"$SH" start --instance paperclip-enterprise-test --port ${PE_TEST_PORT} --db-port 54332 >/dev/null 2>&1
check "mismatched --db-port exits 2" test $? = 2
check "config unchanged after mismatch" test "$before" = "$(cat "$CFG")"

# Fix 1: failed health wait must not leave the server behind
PAPERCLIP_INSTANCE_HEALTH_TIMEOUT=2 "$SH" start "${ARGS[@]}" >/dev/null 2>&1
check "start with short health deadline exits 1" test $? = 1
check "no pid file after failed start" test ! -e "$HOME/.paperclip/instances/paperclip-enterprise-test/kit.pid"
sleep 1
check "port ${PE_TEST_PORT} closed after failed start" bash -c '! curl -s --max-time 3 http://127.0.0.1:${PE_TEST_PORT}/api/health -o /dev/null'
exit $fail
