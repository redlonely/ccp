#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export CC_SWITCH_DB="$SANDBOX/cc-switch.db"
mkdir -p "$HOME" "$SANDBOX/bin"

sqlite3 "$CC_SWITCH_DB" <<'SQL'
CREATE TABLE providers (id TEXT PRIMARY KEY, name TEXT NOT NULL, app_type TEXT NOT NULL, sort_index INTEGER NOT NULL);
INSERT INTO providers VALUES ('glm-id', 'GLM', 'claude', 0);
INSERT INTO providers VALUES ('deep-id', 'DeepSeek', 'claude', 1);
INSERT INTO providers VALUES ('deep-copy-id', 'DeepSeek Copy', 'claude', 2);
INSERT INTO providers VALUES ('quote-id', 'O''Brien', 'claude', 3);
INSERT INTO providers VALUES ('other-id', 'Other', 'codex', 0);
SQL

cat > "$SANDBOX/bin/cc-switch" <<'SH'
#!/bin/bash
if [[ "${1:-}" == provider && "${2:-}" == list ]]; then exit 0; fi
printf '%s\n' "$@"
if [[ -n "${CCP_TEST_SLEEP:-}" ]]; then sleep "$CCP_TEST_SLEEP"; fi
SH
chmod +x "$SANDBOX/bin/cc-switch"
export PATH="$SANDBOX/bin:/usr/bin:/bin"

assert_output() {
  local expected=$1
  shift
  local actual
  actual=$("$@")
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

assert_output $'start\nclaude\nglm-id' "$ROOT/ccp" glm
assert_output $'start\nclaude\nglm-id' "$ROOT/ccp" GLM
assert_output $'start\nclaude\nglm-id\n--\n--dangerously-skip-permissions' "$ROOT/ccp" -d gl
assert_output $'start\nclaude\ndeep-id\n--\n--model\nsonnet' "$ROOT/ccp" DeepSeek -- --model sonnet
assert_output $'start\nclaude\nquote-id' "$ROOT/ccp" "O'Brien"
assert_output $'ccp: GLM -> GLM\nstart\nclaude\nglm-id\n--dry-run' "$ROOT/ccp" -n GLM

if "$ROOT/ccp" deep >"$SANDBOX/out" 2>"$SANDBOX/err"; then
  echo "ambiguous selector unexpectedly succeeded" >&2
  exit 1
fi
grep -q "provider 'deep' is ambiguous" "$SANDBOX/err"
grep -q "DeepSeek Copy" "$SANDBOX/err"

# The usage refresher runs only while the ccp-launched process is alive.
cat > "$SANDBOX/bin/node" <<'SH'
#!/bin/bash
echo run >> "$CCP_TEST_NODE_LOG"
SH
chmod +x "$SANDBOX/bin/node"
echo '// test fetcher' > "$SANDBOX/fetcher.mjs"
export CCP_TEST_NODE_LOG="$SANDBOX/node.log"
CCP_TEST_SLEEP=2 \
CCP_USAGE_FETCHER="$SANDBOX/fetcher.mjs" \
CCP_USAGE_INTERVAL_SECONDS=1 \
CCP_STATE_DIR="$SANDBOX/state" \
CCP_USAGE_DIR="$SANDBOX/usage" \
  "$ROOT/ccp" glm >/dev/null &
ccp_pid=$!
sleep 1
test -s "$CCP_TEST_NODE_LOG"
wait "$ccp_pid"
runs_after_exit=$(wc -l < "$CCP_TEST_NODE_LOG")
sleep 2
test "$(wc -l < "$CCP_TEST_NODE_LOG")" -eq "$runs_after_exit"

echo "ccp tests passed"
