#!/bin/bash
# ccp — Claude Code Provider launcher
# 调用 cc-switch 官方 export API + claude-hud 集成补丁层。
# Usage: ccp [-d|--danger|--check] <provider> [claude args...]

DB="$HOME/.cc-switch/cc-switch.db"
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
HUD_DIR="$HOME/.claude/claude-hud"
HUD_PLUGIN_DIR="$HOME/.claude/plugins/claude-hud"

# ---- --check：环境自检（重装时有用）----
if [ "$1" = "--check" ]; then
  for cmd in cc-switch claude jq sqlite3 python3; do
    command -v "$cmd" >/dev/null || { echo "❌ $cmd missing"; exit 1; }
  done
  [ -f "$DB" ] || { echo "❌ cc-switch.db missing at $DB"; exit 1; }
  echo "✅ ccp environment OK"
  exit 0
fi

# ---- 参数解析：剥离 -d / --danger（位置无关）----
DANGER=""
filtered=()
for a in "$@"; do
  case "$a" in
    -d|--danger) DANGER="--dangerously-skip-permissions" ;;
    *) filtered+=("$a") ;;
  esac
done
set -- "${filtered[@]}"

# ---- 帮助 / 无参提示 ----
if [ -z "$1" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: ccp [-d|--danger|--check] <provider> [claude args...]"
  echo "  -d, --danger   skip permission prompts (--dangerously-skip-permissions)"
  echo "      --check    verify environment (cc-switch/claude/jq/sqlite3/python3)"
  echo ""
  echo "Available providers:"
  sqlite3 "$DB" "SELECT '  ' || name FROM providers WHERE app_type='claude' ORDER BY sort_index;" 2>/dev/null
  echo ""
  echo "Powered by cc-switch $(cc-switch --version 2>/dev/null)"
  exit 0
fi

QUERY="$1"
shift

# ---- provider 解析：模糊匹配（大小写不敏感 + 部分匹配）→ (name, id) ----
# 直读 db 的 name/id 两个字段，schema 极稳定；配置生成走 cc-switch 官方 API。
ROW=$(sqlite3 "$DB" "
  SELECT name || '|' || id
  FROM providers
  WHERE app_type='claude'
    AND (LOWER(name) LIKE LOWER('%${QUERY}%') OR LOWER(id) LIKE LOWER('%${QUERY}%'))
  ORDER BY sort_index
  LIMIT 1;
" 2>/dev/null)

if [ -z "$ROW" ]; then
  echo "❌ Provider '$QUERY' not found"
  echo "Run 'ccp' without args to see available providers"
  exit 1
fi

NAME="${ROW%%|*}"
ID="${ROW##*|}"

# ---- 临时 settings.json：调 cc-switch 官方 export（schema 兼容由它保证）----
SETTINGS_FILE=$(mktemp -t ccp.XXXXXX).json
trap 'rm -f "$SETTINGS_FILE"' EXIT

if ! cc-switch provider export "$ID" -o "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "❌ cc-switch export failed for '$NAME' (id=$ID)"
  exit 1
fi

# ---- plugin 一致性：全局 enabledPlugins 覆盖同名项，保留 provider 专属 plugin ----
# 合并方向：provider.enabledPlugins + global.enabledPlugins（jq `+` 对 object 是 right-bias merge）
# 让"通用 plugin 跟全局，provider 专属 plugin 保留"（如 GLM 的 glm-plan-usage）
# ponytail: --slurpfile 比 -s 简洁，且能在 path 上直接赋值
if [ -f "$GLOBAL_SETTINGS" ]; then
  jq --slurpfile global "$GLOBAL_SETTINGS" \
     '.enabledPlugins = (.enabledPlugins + $global[0].enabledPlugins)' \
     "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
    && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
fi

# ---- statusLine 强写：防 cc-switch GUI 用内存配置覆盖 db 回滚 ----
HUD_STATUSLINE="$HUD_DIR/statusline-cmd.txt"
if [ -f "$HUD_STATUSLINE" ]; then
  CMD=$(cat "$HUD_STATUSLINE")
  jq --arg cmd "$CMD" '.statusLine = {type:"command", command:$cmd}' \
    "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
    && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
fi

# ---- HUD marker：原子写 .current-<NAME>.json 给 claude-hud fetcher 读 ----
# ccp 用临时 settings 启动 claude，~/.claude/settings.json 不反映真实 provider，
# claude-hud 靠这个 marker 文件知道当前是哪个 provider。含 auth_token，0600 权限。
HUD_MARKER="$HUD_PLUGIN_DIR/.current-${NAME// /_}.json"
CCP_NAME="$NAME" SETTINGS_FILE="$SETTINGS_FILE" HUD_MARKER="$HUD_MARKER" python3 -c '
import json, os, time
cfg = json.load(open(os.environ["SETTINGS_FILE"]))
env = cfg.get("env", {})
marker = {
    "name": os.environ["CCP_NAME"],
    "base_url": env.get("ANTHROPIC_BASE_URL", ""),
    "auth_token": env.get("ANTHROPIC_AUTH_TOKEN", ""),
    "started_at": int(time.time()),
}
path = os.environ["HUD_MARKER"]
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(marker, f)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
' || echo "⚠️  HUD marker write failed (non-fatal)" >&2

# ---- 启动：透传剩余参数 ----
exec claude --settings "$SETTINGS_FILE" $DANGER "$@"
