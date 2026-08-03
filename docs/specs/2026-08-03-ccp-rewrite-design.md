# ccp 重写设计 — 调用 cc-switch 官方 API + claude-hud 集成层

**日期**: 2026-08-03
**状态**: Draft（待主人复核）
**作者**: claude + 主人

---

## 1. 背景与动机

`ccp` 是 `~/.local/bin/ccp` 里的 104 行 bash 脚本，作为 **cc-switch × claude-hud × claude code 三者协作的启动器**，解决以下痛点：

- cc-switch GUI 切完 provider 后**所有终端都被影响**（全局 current provider 切换）
- 不同 provider 的 `enabledPlugins` 不一致（GLM 27 项、DeepSeek 28 项、LemonFly 0 项），切到不同 provider 会丢失/强制启用 plugin
- claude-hud 需要知道当前会话用哪个 provider，但 cc-switch 不感知 claude-hud 协议
- cc-switch GUI 退出时可能用内存配置覆盖 db，导致 statusLine 配置回滚

### 现状

ccp 现在的实现在 `cc-switch 5.10.0` 下部分能力已被官方覆盖：

| ccp 当前能力 | cc-switch 5.10 是否原生提供 |
|------------|---------------------------|
| 启动指定 provider 不动全局 | ✅ `cc-switch start claude <SELECTOR>` |
| `--` 透传 claude 参数 | ✅ `cc-switch start claude X -- <args>` |
| 生成 settings.json | ✅ `cc-switch provider export <ID> -o <path>` |
| 大小写不敏感 + 部分模糊匹配 | ❌ 严格精确匹配（大小写敏感） |
| `enabledPlugins` 全局合并 | ❌ export 输出 provider 自带列表（每家不同） |
| statusLine 强写（防 GUI 回滚） | ❌ cc-switch 不知 claude-hud 协议 |
| HUD marker 文件 | ❌ claude-hud 私有协议 |
| `-d` 短选项 → `--dangerously-skip-permissions` | 🟡 仅语法糖，可被 `-- --dangerously-skip-permissions` 替代 |

### 重写动机

1. **解掉 schema 漂移焦虑**：ccp 现在直读 db 拼 settings.json，绕过 cc-switch 的迁移逻辑；改用 `cc-switch provider export` 后由 cc-switch 自己保证 schema 兼容。
2. **代码精简**：删掉 Python heredoc 合并 plugins 的复杂逻辑（改用 jq），复用官方 export。整体行数 104 → ~85（见第 8 节），重点在降低风险而非减行。
3. **保留所有补丁价值**：模糊匹配、plugin 一致性、statusLine 注入、HUD marker 全部保留 —— 这些是 cc-switch 永远不会管的 claude-hud 集成层。

---

## 2. 目标与非目标

### 目标

- **G1**：行为对用户完全等价（`ccp -d glm` 仍能用、效果一致）
- **G2**：底层从"绕开 cc-switch"翻成"调用 cc-switch 官方 export API"
- **G3**：保留 4 个独立补丁价值（模糊匹配、plugin 一致性、statusLine 注入、HUD marker）
- **G4**：保留 `trap EXIT` 清理临时文件、原子写 HUD marker（0600 权限）等安全特性

### 非目标（YAGNI 边界）

- **N1**：不支持非 cc-switch 用户（前置依赖 cc-switch + cc-switch.db）
- **N2**：不做 provider 的增删改（cc-switch 自己管，ccp 只读和启动）
- **N3**：不做交互式 provider 选择菜单（命令行参数够用）
- **N4**：不做 npm / brew 包发布（受众太窄，先 GitHub repo + README）
- **N5**：不支持 codex / gemini / open-code（仅 claude）
- **N6**：不替换 cc-switch GUI（ccp 只负责"启动一个 claude 会话"）

---

## 3. 架构

### 调用链

```
ccp [-d|--danger] <query> [claude args...]
   │
   ├─ 1. 参数解析：剥离 -d/--danger 到 DANGER flag
   ├─ 2. provider 解析：query → (name, id)   [sqlite3 只读 SELECT]
   ├─ 3. 临时文件：mktemp
   ├─ 4. 官方导出：cc-switch provider export <id> -o <tmp>
   ├─ 5. plugin 一致性：jq 用全局 enabledPlugins 覆盖同名项（合并方向）
   ├─ 6. statusLine 注入：jq 写入 claude-hud/statusline-cmd.txt 内容
   ├─ 7. HUD marker：原子写 .current-<NAME>.json（0600）
   ├─ 8. trap rm <tmp>
   └─ 9. exec claude --settings <tmp> $DANGER "$@"
```

### 数据流

```
                ┌─────────────────────────┐
   用户输入 ──→ │ 参数解析层（strip -d）  │
                └────────────┬─────────────┘
                             ↓
                ┌─────────────────────────┐
                │ provider 解析层          │
                │ sqlite3 SELECT name, id  │ ← ~/.cc-switch/cc-switch.db
                │ WHERE LOWER(name) LIKE  │
                └────────────┬─────────────┘
                             ↓ (name, id)
                ┌─────────────────────────┐
                │ 配置生成层               │
                │ cc-switch provider ...  │ → 临时 settings.json
                │ jq merge plugins        │ ← ~/.claude/settings.json (global enabledPlugins)
                │ jq inject statusLine    │ ← ~/.claude/claude-hud/statusline-cmd.txt
                └────────────┬─────────────┘
                             ↓
                ┌─────────────────────────┐
                │ HUD marker 层            │
                │ 写 .current-<NAME>.json │ → ~/.claude/plugins/claude-hud/
                │ (atomic, 0600)          │
                └────────────┬─────────────┘
                             ↓
                ┌─────────────────────────┐
                │ 启动层                   │
                │ exec claude --settings  │
                └─────────────────────────┘
```

---

## 4. 组件设计

### 4.1 参数解析层

**职责**：剥离 `-d`/`--danger` 到 DANGER 变量，其余透传。

```bash
DANGER=""
filtered=()
for a in "$@"; do
  case "$a" in
    -d|--danger) DANGER="--dangerously-skip-permissions" ;;
    *) filtered+=("$a") ;;
  esac
done
set -- "${filtered[@]}"
```

**保留现状**：ccp 当前这段已经写对了，原样保留。

### 4.2 provider 解析层

**职责**：把用户输入（可能小写、部分匹配）解析为精确 (name, id)。

**实现选择**：用 sqlite3 直读 db，**而非**解析 `cc-switch provider list` 表格输出。

**理由**：
- cc-switch provider list 不支持 `--json`，表格输出可能因终端宽度、color code 变化而解析失败
- sqlite3 SELECT name, id 只读两个字段，schema 极稳定（不会跨大版本变化）
- ccp 已经在用这种方式，保留稳定性

```bash
DB="$HOME/.cc-switch/cc-switch.db"
QUERY="$1"; shift

# 大小写不敏感 + 部分匹配（name 或 id），LIMIT 1 取第一个
ROW=$(sqlite3 "$DB" "
  SELECT name || '|' || id
  FROM providers
  WHERE app_type='claude'
    AND (LOWER(name) LIKE LOWER('%${QUERY}%') OR LOWER(id) LIKE LOWER('%${QUERY}%'))
  ORDER BY LENGTH(name) ASC, sort_index ASC
  LIMIT 1;
")

if [ -z "$ROW" ]; then
  echo "❌ Provider '$QUERY' not found"
  echo "Run 'ccp' without args to see available providers"
  exit 1
fi

NAME="${ROW%%|*}"
ID="${ROW##*|}"
```

**改进**：相比现状，新增 `ORDER BY LENGTH(name) ASC` —— 让短名优先（输入 `a` 时优先匹配 `Apple` 而非 `Banana Apple`），降低误匹配。**待定**：保留还是简化为 `ORDER BY sort_index`。

**已知小瑕疵（不修）**：`${QUERY}` 字符串拼接到 SQL，理论上 `%` `_` 是 LIKE 元字符会让查询意外。本地自用、查询名字，影响极小。如果以后要修，用 sqlite3 `.parameter set` 绑定。

### 4.3 配置生成层

**职责**：用 cc-switch 官方 API 生成 settings.json，并补两块 claude-hud 集成补丁。

```bash
SETTINGS_FILE=$(mktemp -t ccp.XXXXXX).json

# (a) 官方导出（schema 兼容由 cc-switch 自己保证）
cc-switch provider export "$ID" -o "$SETTINGS_FILE" >/dev/null 2>&1 || {
  echo "❌ cc-switch export 失败"; rm -f "$SETTINGS_FILE"; exit 1
}

# (b) plugin 一致性：全局 enabledPlugins 覆盖同名项（合并方向）
GLOBAL_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$GLOBAL_SETTINGS" ]; then
  jq -s '
    .[0] as $cfg | .[1] as $global
    | $cfg.enabledPlugins = ($cfg.enabledPlugins + $global.enabledPlugins)
    | $cfg
  ' "$SETTINGS_FILE" "$GLOBAL_SETTINGS" > "${SETTINGS_FILE}.tmp" \
    && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
fi

# (c) statusLine 强写：防 GUI 回滚覆盖
HUD_STATUSLINE="$HOME/.claude/claude-hud/statusline-cmd.txt"
if [ -f "$HUD_STATUSLINE" ]; then
  CMD=$(cat "$HUD_STATUSLINE")
  jq --arg cmd "$CMD" '.statusLine = {type:"command", command:$cmd}' \
    "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
    && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
fi
```

**plugin 合并方向决策**（重要）：

主人诉求"plugin 跨 provider 保持一致"。两种实现：

- **完全覆盖**：`$cfg.enabledPlugins = $global.enabledPlugins`（最纯粹的一致）
- **合并（推荐）**：`$cfg.enabledPlugins + $global.enabledPlugins`（jq 的 `+` 对 object 是 right-bias merge，等价于 ccp 现在的 `{**provider, **global}`）

**推荐合并**，理由：GLM 自带的 `glm-plan-usage@zai-coding-plugins` 是 GLM 专属余额查询 plugin，全局不会有也不该有 —— 干掉它 GLM 会话就用不了。合并方向正好"通用 plugin 跟全局，provider 专属 plugin 保留"。

### 4.4 HUD marker 层

**职责**：写 `.current-<NAME>.json` 给 claude-hud fetcher 读。

**保留现状**：ccp 当前这段（L84-101）已经写对了，原子写 + 0600 权限。原样保留。

唯一调整：从 `$CONFIG`（sqlite3 直读的 settings_config）改为从 `$SETTINGS_FILE`（export 出来的临时文件）读 env，保持数据源一致。

```bash
HUD_MARKER="$HOME/.claude/plugins/claude-hud/.current-${NAME// /_}.json"
CCP_NAME="$NAME" HUD_MARKER="$HUD_MARKER" python3 -c '
import json, os, time
cfg = json.load(open(os.environ["SETTINGS_FILE"])) if os.environ.get("SETTINGS_FILE") else {}
env = cfg.get("env", {})
marker = {
    "name": os.environ.get("CCP_NAME", ""),
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
' SETTINGS_FILE="$SETTINGS_FILE"
```

### 4.5 启动层

```bash
trap 'rm -f "$SETTINGS_FILE"' EXIT

exec claude --settings "$SETTINGS_FILE" $DANGER "$@"
```

**保留现状**。

---

## 5. 错误处理

| 失败点 | 处理 |
|-------|------|
| `cc-switch` 不在 PATH | 启动前 `command -v cc-switch` 检查，提示装 cc-switch |
| `~/.cc-switch/cc-switch.db` 不存在 | 提示"未找到 cc-switch 配置，请先用 cc-switch GUI 添加 provider" |
| query 没匹配到 provider | 打印错误 + 提示 `ccp` 无参数看列表（保留现状） |
| 匹配到多个（LIMIT 1 之外） | 静默取第一个（保留现状） |
| `cc-switch provider export` 失败 | 打印 cc-switch 原始错误，rm tmp，exit 1 |
| jq 解析失败（export 输出非合法 JSON） | 打印错误，rm tmp，exit 1 |
| `~/.claude/claude-hud/statusline-cmd.txt` 不存在 | 跳过 statusLine 注入（不致命，会话仍能启动） |
| `~/.claude/settings.json` 不存在或无 enabledPlugins | 跳过 plugin 合并（不致命） |
| HUD marker 写失败（权限/磁盘） | 警告到 stderr，不阻塞启动 |
| `claude` 不在 PATH | exec 失败由 shell 报错（不做前置检查，因为 cc-switch 已经会查） |

**原则**：致命错误（配置错误、依赖缺失）立即退出；非致命（claude-hud 文件缺失）降级运行。

---

## 6. 测试方案（ponytail 风格：一个最小 self-check）

按 ponytail 原则：留一个最小可执行的检查，能在逻辑破坏时失败。**不引入测试框架、不做 per-function 测试套件**。

### 6.1 静态自检：`ccp --check`

新增 `--check` 子命令（5 行内），验证运行环境：

```bash
[ "$1" = "--check" ] && {
  command -v cc-switch >/dev/null || { echo "❌ cc-switch missing"; exit 1; }
  command -v claude    >/dev/null || { echo "❌ claude missing";    exit 1; }
  command -v jq        >/dev/null || { echo "❌ jq missing";        exit 1; }
  command -v sqlite3   >/dev/null || { echo "❌ sqlite3 missing";   exit 1; }
  [ -f "$HOME/.cc-switch/cc-switch.db" ] || { echo "❌ cc-switch.db missing"; exit 1; }
  echo "✅ ccp environment OK"
  exit 0
}
```

### 6.2 Dry-run（透传给 cc-switch）

不自己实现 dry-run，复用 cc-switch 的：

```bash
ccp <query> --dry-run
# 等价于
cc-switch start claude <resolved-name> --dry-run
```

但这条路有局限：cc-switch dry-run 不显示 ccp 的补丁（plugin 合并、statusLine 注入）。所以补一个 `--debug` 在 ccp 里打印最终生成的 settings.json 路径，主人可以手动 `bat` 一下检查。

### 6.3 一次性回归手测

重写后手测 4 个场景：

1. `ccp GLM` → 启动 GLM 会话，claude-hud 显示 GLM
2. `ccp -d glm`（小写）→ 启动 GLM + 跳过权限
3. `ccp nonexistent` → 报错并列出可用 provider
4. 启动后检查 `~/.claude/plugins/claude-hud/.current-GLM.json` 存在且 enabledPlugins 与全局一致

---

## 7. 依赖

| 依赖 | 用途 | 备注 |
|------|------|------|
| `bash` ≥ 3.2 | 数组、参数替换 | macOS 自带，不依赖 bash 4 associative array |
| `cc-switch` ≥ 5.10 | `provider export` 子命令 | 5.10 才有 export，更低版本会失败 |
| `claude` | 启动 claude code | 主人路径 `~/Library/pnpm/bin/claude` |
| `jq` | JSON 处理 | brew install jq |
| `sqlite3` | 只读 SELECT name, id | macOS 自带 |
| `python3` | HUD marker 原子写 | macOS 自带 |

---

## 8. 行数估算

| 模块 | 现状 | 重写后 |
|------|------|-------|
| 参数解析 | 8 行 | 8 行（不变） |
| provider 解析 | 12 行 | 12 行（不变） |
| 配置生成 | sqlite3 + Python heredoc 28 行 | jq + cc-switch export 15 行 |
| statusLine 注入 | 9 行 | 9 行（不变） |
| HUD marker | 18 行 | 18 行（不变） |
| 启动 | 2 行 | 2 行（不变） |
| 帮助/无参提示 | 12 行 | 12 行（不变） |
| --check 自检 | 0 行 | 8 行（新增） |
| **合计** | ~104 行 | ~85 行 |

**重点不在减行而在降低风险**（直读 db → 官方 export）。plugin 合并改用 jq 移除了 Python heredoc 的复杂度，HUD marker 的 Python 保留（结构化字段 + 原子写比 bash 干净）。

---

## 9. 发布策略

### 9.1 仓库结构（建议）

```
~/code/ccp/
├── ccp                       # 主脚本（从 ~/.local/bin/ccp 迁移）
├── README.md                 # 安装 + 用法 + 设计说明
├── LICENSE                   # MIT
└── docs/
    └── specs/
        └── 2026-08-03-ccp-rewrite-design.md   # 本文件
```

### 9.2 安装方式（YAGNI）

不做 brew tap、不做 npm 包。README 提供一行 curl 安装：

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/ccp/main/install.sh | bash
# install.sh 只做：下载 ccp 到 ~/.local/bin/，chmod +x
```

或者更懒：README 让人 `cp ccp ~/.local/bin/` 手动放。

### 9.3 受众声明

README 明确写："**ccp 是 claude-hud × cc-switch 用户的伴侣启动器。如果你不用 claude-hud，直接用 `cc-switch start claude` 即可。**"

避免误解为通用工具。

---

## 10. 未来演化路径

### 短期（本次重写）

完成本 spec 描述的重写。

### 中期（如果 claude-hud 是开源的）

把 ccp 合并进 claude-hud 仓库，作为推荐启动方式。统一版本管理。

### 长期（路 C：上游）

给 cc-switch / claude-hud 提 issue 或 PR：
- cc-switch：`provider export` 增加 `--merge-global-plugins` 选项
- cc-switch：`start claude` 支持 `--case-insensitive` 模糊匹配
- claude-hud：原生支持读 cc-switch db 推断当前 provider（不需要 ccp 写 marker）

任一被接受，ccp 的对应补丁可以删掉，最终退役。

---

## 11. 待主人确认的开放问题

1. **plugin 合并方向**（4.3 节）：推荐"合并"（保留 provider 专属如 glm-plan-usage），还是"完全覆盖"（最纯粹一致）？
2. **模糊匹配 tie-breaker**（4.2 节）：`ORDER BY LENGTH(name)` 短名优先，还是 `ORDER BY sort_index` 按 cc-switch 排序？
3. **`--check` 子命令**（6.1 节）：要不要加？5 行成本，主人重装时有用。
4. **仓库位置**：`~/code/ccp/` 作为未来 repo 根，可以吗？
5. **是否提 git init**：重写后要不要顺便 git init + 首次 commit？

---

## 12. 实施步骤（high-level，详细 plan 由 writing-plans skill 出）

1. 在 `~/code/ccp/ccp` 写新版脚本
2. 手测 4 个场景（6.3）
3. 替换 `~/.local/bin/ccp`（备份原文件到 `~/.local/bin/ccp.bak`）
4. git init + 首次 commit（如果主人同意）
5. 写 README

---

**下一步**：主人 review 本 spec → 确认开放问题 → 调用 `writing-plans` skill 出详细实施计划。
