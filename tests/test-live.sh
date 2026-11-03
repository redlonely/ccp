#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat > "$SANDBOX/bin/claude" <<'SH'
#!/bin/bash
set -euo pipefail
settings=""
while (($#)); do
  if [[ "$1" == "--settings" && $# -ge 2 ]]; then settings=$2; break; fi
  shift
done
test -f "$settings"
test "$(stat -f '%Lp' "$settings")" = 600
jq -e '.env.ANTHROPIC_BASE_URL and .statusLine.command and .enabledPlugins' "$settings" >/dev/null
jq -e '.statusLine.command | contains("plugins/cache")' "$settings" >/dev/null
SH
chmod +x "$SANDBOX/bin/claude"

snapshot="$HOME/.claude/plugins/claude-hud/provider-usage-GLM.json"
before=$(jq -r '.updated_at' "$snapshot")
CCP_USAGE_MIN_AGE_MS=0 \
CCP_USAGE_DIR="$HOME/.claude/plugins/claude-hud" \
  node "$ROOT/adapters/fetch-provider-usage.mjs"
after=$(jq -r '.updated_at' "$snapshot")
node -e 'process.exit(Date.parse(process.argv[2]) > Date.parse(process.argv[1]) ? 0 : 1)' "$before" "$after"

PATH="$SANDBOX/bin:$PATH" \
CCP_USAGE_REFRESH=0 \
  "$ROOT/ccp" GLM

echo "live ccp integration passed"
