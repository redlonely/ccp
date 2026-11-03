# ccp — concise cc-switch launcher

`ccp` 是 [`cc-switch start claude`](https://github.com/farion1231/cc-switch) 的薄封装，用更短的命令在多个终端启动不同 Claude provider，不修改 cc-switch GUI 的全局选择。

```bash
ccp -d glm       # 左侧窗口：GLM + bypass permissions
ccp -d deepseek  # 右侧窗口：DeepSeek + bypass permissions
```

provider 临时配置的创建、私有权限和退出清理由 cc-switch 负责。`ccp` 只补三件事：

- 大小写不敏感和唯一部分匹配；
- `-d` 简写；
- 更短的参数转发语法。

## 依赖

- macOS 或 Unix shell；
- `cc-switch >= 5.10`；
- `sqlite3`；
- Claude Code。

```bash
ccp --check
```

## 安装

```bash
install -m 755 ccp ~/.local/bin/ccp
```

或直接下载：

```bash
curl -fsSL https://raw.githubusercontent.com/redlonely/ccp/main/ccp -o ~/.local/bin/ccp
chmod +x ~/.local/bin/ccp
```

## 用法

```bash
ccp                         # 帮助和 provider 列表
ccp glm                     # 唯一部分匹配 GLM
ccp -d deepseek             # 启动 DeepSeek 并跳过权限确认
ccp -n glm                  # dry-run，只预览 cc-switch 启动信息
ccp glm -- --model sonnet   # 透传 Claude 原生命令参数
```

匹配顺序为：精确 ID/名称、忽略大小写的精确名称、唯一部分匹配。部分匹配命中多个 provider 时会报错并列出候选，不会静默选第一个。

## claude-hud 第三方额度 adapter

`adapters/fetch-provider-usage.mjs` 是可选组件，与 `ccp` 启动命令没有运行时依赖。它读取 `~/.cc-switch/cc-switch.db` 中的 Claude provider，查询厂商额度 API，再为 claude-hud 写入外部 usage snapshot。

目前支持：

- GLM Coding Plan：5 小时和 7 天额度；
- DeepSeek：余额和本地估算的今日消费。

安装 adapter：

```bash
./adapters/install-macos.sh
```

`ccp` 启动 Claude 时会立即刷新一次，随后在该会话存活期间每 60 秒刷新。所有 `ccp` 会话关闭后不再运行 Node 或请求厂商 API。多个窗口共享 snapshot 新鲜度和进程锁，不会按窗口数量重复查询。

检查或手动刷新：

```bash
node ~/.local/share/ccp/fetch-provider-usage.mjs --check
CCP_USAGE_DIR="$HOME/.claude/plugins/claude-hud" \
  node ~/.local/share/ccp/fetch-provider-usage.mjs
```

卸载 adapter：

```bash
./adapters/uninstall-macos.sh
```

卸载会清理旧版 launchd 任务，并把已安装 fetcher 移到废纸篓，保留 snapshot 和 DeepSeek 日基线数据。

### claude-hud 配置

claude-hud `v0.8.0+` 已支持按模型选择外部 snapshot。配置文件 `~/.claude/plugins/claude-hud/config.json` 示例：

```json
{
  "display": {
    "showUsage": true,
    "externalUsageFreshnessMs": 120000,
    "externalUsageByModel": {
      "glm": "/Users/you/.claude/plugins/claude-hud/provider-usage-GLM.json",
      "deepseek": "/Users/you/.claude/plugins/claude-hud/provider-usage-DeepSeek.json"
    }
  }
}
```

路径必须是绝对路径；claude-hud 不展开 `~`。示例中的路径需要替换为实际 home 目录。

## 开发验证

```bash
bash -n ccp adapters/install-macos.sh adapters/uninstall-macos.sh
node --check adapters/fetch-provider-usage.mjs
./tests/test-ccp.sh
```

## License

MIT
