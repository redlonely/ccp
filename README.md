# ccp — Claude Code Provider Launcher

> **cc-switch × claude-hud 用户的伴侣启动器。**
> 如果你不用 claude-hud，直接用 `cc-switch start claude <name>` 就够了，不需要 ccp。

## 解决什么问题

cc-switch GUI 切完 provider 后**所有终端都被影响**。ccp 让你在单个终端启动一个指定 provider 的 claude 会话，**不动全局**，并补三件 cc-switch 不管的事：

1. **plugin 一致性** — 全局 `enabledPlugins` 覆盖 provider 自带的（不同 provider 自带列表不一样，会让 plugin 漂移）
2. **statusLine 强写** — 防 cc-switch GUI 用内存配置覆盖 db 时把 claude-hud statusLine 配置回滚掉
3. **HUD marker** — 写 `.current-<NAME>.json` 给 claude-hud fetcher 读，让它知道当前会话是哪个 provider

外加便利：模糊匹配（`glm` → `GLM`）和 `-d` 短选项。

## 依赖

- `cc-switch` ≥ 5.10（需要 `provider export` 子命令）
- `claude`（Claude Code CLI）
- `jq` / `sqlite3` / `python3`

跑 `ccp --check` 一键自检。

## 安装

```bash
cp ccp ~/.local/bin/ccp
chmod +x ~/.local/bin/ccp
```

## 用法

```bash
ccp glm                          # 启动 GLM 会话
ccp -d glm                       # 同上 + --dangerously-skip-permissions
ccp deepseek -- --some-claude-flag   # 透传 claude 参数
ccp                              # 列出可用 provider
ccp --check                      # 环境自检
```

## 工作原理

```
ccp <query>
  → sqlite3 模糊匹配 (name, id)
  → cc-switch provider export <id> -o <tmp>   # 官方 API 生成 settings.json
  → jq 合并全局 enabledPlugins
  → jq 注入 statusLine（防 GUI 回滚）
  → 写 .current-<NAME>.json（claude-hud marker）
  → exec claude --settings <tmp>
```

设计细节见 [`docs/specs/`](docs/specs/)。

## 路线

理想终态是这三件补丁**上游到 cc-switch / claude-hud**，ccp 退役。在那之前，ccp 是个有用的薄补丁层。
