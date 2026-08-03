# ccp — Claude Code Provider Launcher

> **cc-switch × claude-hud 用户的伴侣启动器。**
> 不用 claude-hud？直接用 `cc-switch start claude <name>` 就够了，不需要 ccp。

---

## 它解决什么

cc-switch GUI 切完 provider 后，**所有终端都被影响**（全局 current provider 切换）。`ccp` 让你在单个终端启动一个指定 provider 的 claude 会话，**不动全局**，并补三件 cc-switch 不管的事：

| 补丁 | 为什么需要 |
|------|-----------|
| **plugin 一致性** | 不同 provider 自带 `enabledPlugins` 不一样（GLM 27 项、DeepSeek 28 项、LemonFly 0 项），切到不同 provider 会**丢失 / 强制启用 plugin** |
| **statusLine 强写** | cc-switch GUI 退出时可能用内存配置覆盖 db，把 claude-hud 的 statusLine 配置回滚掉 |
| **HUD marker** | claude-hud 需要知道当前会话用哪个 provider，但 cc-switch 不感知 claude-hud 协议 |

外加便利：
- **模糊匹配**：`ccp glm` → `GLM`（cc-switch `start` 只支持精确大小写敏感匹配）
- **`-d` 短选项**：`ccp -d glm` ≡ `ccp glm -- --dangerously-skip-permissions`

---

## 前置条件

| 依赖 | 版本 / 说明 | 安装 |
|------|------------|------|
| **macOS** | 其他 Unix 理论可行，未测 | — |
| [**cc-switch**](https://github.com/farion1231/cc-switch) | ≥ 5.10（需要 `provider export` 子命令） | `brew install --cask cc-switch` |
| [**claude-hud**](https://github.com/jarrodwatts/claude-hud) | 任意版本（用其 statusline + marker 协议） | 见其 README |
| **Claude Code CLI** | 任意版本 | `pnpm add -g claude` 或参考官方文档 |
| `jq` | 任意版本 | `brew install jq` |
| `sqlite3` | macOS 自带 | — |
| `python3` | macOS 自带 | — |

**必须先用 cc-switch GUI 添加过 provider**（不然 `~/.cc-switch/cc-switch.db` 是空的，`ccp` 列不出任何 provider）。

一键自检：

```bash
ccp --check
```

---

## 安装 ccp

```bash
curl -fsSL https://raw.githubusercontent.com/redlonely/ccp/main/ccp -o ~/.local/bin/ccp
chmod +x ~/.local/bin/ccp
```

或手动：把 [`ccp`](./ccp) 复制到 `~/.local/bin/`（或其他 PATH 目录），加可执行权限。

---

## 用法

```bash
ccp                              # 列出可用 provider
ccp glm                          # 启动 GLM 会话（模糊匹配，不动全局）
ccp -d glm                       # 同上 + --dangerously-skip-permissions
ccp deepseek -- --some-flag      # 透传 claude 参数（用 -- 分隔）
ccp --check                      # 环境自检
ccp -h, --help                   # 帮助
```

模糊匹配规则：大小写不敏感 + 部分匹配（name 或 id），按 cc-switch GUI 的 `sort_index` 排序取第一个。

---

## 工作原理

```
ccp <query>
  → sqlite3 模糊匹配 (name, id)                       # 只读两个字段，schema 极稳定
  → cc-switch provider export <id> -o <tmp>           # 官方 API 生成 settings.json（schema 兼容由它保证）
  → jq 合并全局 enabledPlugins                        # 全局覆盖同名，保留 provider 专属
  → jq 注入 statusLine                                # 防 GUI 回滚
  → 写 .current-<NAME>.json (atomic, 0600)            # claude-hud marker
  → exec claude --settings <tmp> [--dangerously-skip-permissions] [args...]
  → trap EXIT rm <tmp>                                # 退出时清理临时文件
```

设计文档：[`docs/specs/2026-08-03-ccp-rewrite-design.md`](./docs/specs/2026-08-03-ccp-rewrite-design.md)

---

## FAQ

**Q: 我不用 claude-hud，能用 ccp 吗？**
A: 能跑，但 ccp 的核心价值打折。建议直接 `alias ccp='cc-switch start claude'` 一行解决。

**Q: 切换后 claude-hud 状态栏没更新？**
A: 检查 `~/.claude/plugins/claude-hud/.current-<NAME>.json` 是否存在、权限 0600、字段完整。ccp 启动时会写这个文件。

**Q: plugin 跨 provider 还是漂移了？**
A: 检查 `~/.claude/settings.json` 是否有 `enabledPlugins` 字段。ccp 是从这个文件合并到 provider 配置的，全局没配置就没合并效果。

**Q: cc-switch 升级后 schema 变了，ccp 会坏吗？**
A: 配置生成走 `cc-switch provider export`，schema 兼容由 cc-switch 自己保证。只有 sqlite3 模糊匹配直读 name/id（schema 极稳定，不会跨大版本变化）。

---

## 路线

理想终态是这三件补丁**上游到 cc-switch / claude-hud**，ccp 退役：
- cc-switch `provider export` 增加 `--merge-global-plugins` 选项
- cc-switch `start claude` 支持模糊匹配
- claude-hud 原生支持读 cc-switch db 推断当前 provider

在那之前，ccp 是个有用的薄补丁层。

---

## License

[MIT](./LICENSE)
