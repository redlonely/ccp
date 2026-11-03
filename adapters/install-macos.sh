#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NODE_BIN=$(command -v node || true)
if [[ -z "$NODE_BIN" ]]; then
  echo "provider-usage: node is required" >&2
  exit 1
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "provider-usage: sqlite3 is required" >&2
  exit 1
fi

INSTALL_DIR="$HOME/.local/share/ccp"
OUTPUT_DIR="$HOME/.claude/plugins/claude-hud"
STATE_DIR="$HOME/.local/state/ccp"
LABEL="com.claude-hud.provider-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$INSTALL_DIR" "$OUTPUT_DIR" "$STATE_DIR"
install -m 700 "$SCRIPT_DIR/fetch-provider-usage.mjs" "$INSTALL_DIR/fetch-provider-usage.mjs"

# Older releases installed an always-on launchd timer. The adapter is now
# started and stopped with each ccp session, so remove that global scheduler.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
  mv "$PLIST" "$STATE_DIR/$LABEL.plist.disabled"
fi

CCP_USAGE_DIR="$OUTPUT_DIR" "$NODE_BIN" "$INSTALL_DIR/fetch-provider-usage.mjs" --check
echo "provider-usage adapter installed; ccp will refresh it while sessions are running"
