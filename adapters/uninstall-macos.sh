#!/bin/bash
set -euo pipefail

LABEL="com.claude-hud.provider-usage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
  mv "$PLIST" "$HOME/.Trash/$LABEL.plist.$(date +%Y%m%d-%H%M%S)"
fi

FETCHER="$HOME/.local/share/ccp/fetch-provider-usage.mjs"
if [[ -f "$FETCHER" ]]; then
  mv "$FETCHER" "$HOME/.Trash/fetch-provider-usage.mjs.$(date +%Y%m%d-%H%M%S)"
fi
echo "provider-usage adapter removed; snapshots and balance history were kept"
