#!/usr/bin/env node
// Fetch provider usage/balance and write claude-hud external snapshots.
// 数据源：cc-switch.db 的 providers 表（claude app_type）。
// 阶段1解耦：不再扫 ccp 写的 .current-*.json marker，直接读 db 拿所有 provider 的 token。
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DS_DAILY = join(__dirname, "ds-daily.json");

// Local calendar date (YYYY-MM-DD) in the machine's timezone, not UTC.
function todayDate() {
  const d = new Date();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${mm}-${dd}`;
}

// Difference method for "today's usage": record today's opening balance on
// first query of the day, then usage = opening - current. Cold start: the
// first day under monitoring counts from the first query onward.
function computeDailyUsage(currentBalance) {
  const today = todayDate();
  let daily = null;
  try {
    daily = JSON.parse(readFileSync(DS_DAILY, "utf-8"));
  } catch {
    daily = null;
  }

  let opening;
  if (!daily || daily.date !== today) {
    opening = currentBalance;
    try {
      writeFileSync(DS_DAILY, JSON.stringify({ date: today, opening_balance: opening }, null, 2) + "\n");
    } catch {
      // Best-effort persistence; usage just won't be comparable next run.
    }
  } else {
    opening = Number(daily.opening_balance);
    if (!Number.isFinite(opening)) opening = currentBalance;
  }

  // Clamp at 0: a top-up mid-day would otherwise show negative "usage".
  return Math.max(0, opening - currentBalance);
}

// 按 baseUrl 分发到对应查询；返回 null 表示该 provider 暂不支持（跳过）。
function dispatchSnapshot(baseUrl, apiKey) {
  if (baseUrl.includes("deepseek")) return fetchDeepSeekBalance(baseUrl, apiKey);
  if (baseUrl.includes("bigmodel.cn") || baseUrl.includes("z.ai")) return fetchZhipuUsage(apiKey);
  return null;
}

// 处理单个 provider：查额度 → 写 provider-usage-<name>.json。
async function processProvider({ name, base_url, auth_token }) {
  if (!name || !base_url || !auth_token) return;

  const snapshot = await dispatchSnapshot(base_url, auth_token);
  if (!snapshot) return;

  const safe = String(name).replace(/\s+/g, "_");
  writeFileSync(join(__dirname, `provider-usage-${safe}.json`), JSON.stringify(snapshot, null, 2) + "\n");
}

// 从 cc-switch.db 读所有 claude provider 的 (name, base_url, auth_token)。
// ponytail: execFileSync 调 sqlite3 -json，零依赖，避免 node:sqlite 实验性 API。
function readProvidersFromDb() {
  const db = join(homedir(), ".cc-switch", "cc-switch.db");
  if (!existsSync(db)) return [];
  const sql = `SELECT name,
                      json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') AS base_url,
                      json_extract(settings_config, '$.env.ANTHROPIC_AUTH_TOKEN') AS auth_token
               FROM providers
               WHERE app_type='claude'
                 AND base_url IS NOT NULL
                 AND auth_token IS NOT NULL`;
  let raw;
  try {
    raw = execFileSync("sqlite3", ["-json", db, sql], { encoding: "utf8" });
  } catch {
    return [];
  }
  try {
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

function formatRemaining(ms) {
  if (!ms || ms <= 0) return "";
  const totalMin = Math.floor(ms / 60000);
  if (totalMin < 60) return `${totalMin}m`;
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h < 24) return m > 0 ? `${h}h${m}m` : `${h}h`;
  const d = Math.floor(h / 24);
  const rh = h % 24;
  return rh > 0 ? `${d}d${rh}h` : `${d}d`;
}

async function fetchZhipuUsage(apiKey) {
  const res = await fetch("https://open.bigmodel.cn/api/monitor/usage/quota/limit", {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    signal: AbortSignal.timeout(10_000),
  });
  const body = await res.json();
  if (!body.success || !body.data?.limits) return null;

  // GLM 返回多个 TOKENS_LIMIT 窗口：unit=3 number=5 是 5 小时窗口，unit=6 number=1 是周窗口。
  // TIME_LIMIT 是 MCP 工具调用时间限制，不是 token 额度，不显示。
  const limits = body.data.limits;
  const tokenLimits = limits.filter((l) => l.type === "TOKENS_LIMIT");
  const fiveHour = tokenLimits.find((l) => l.unit === 3);
  const sevenDay = tokenLimits.find((l) => l.unit === 6);

  const parts = [];
  if (fiveHour) {
    const reset = formatRemaining(fiveHour.nextResetTime - Date.now());
    parts.push(`5h ${fiveHour.percentage}%${reset ? ` r${reset}` : ""}`);
  }
  if (sevenDay) {
    const reset = formatRemaining(sevenDay.nextResetTime - Date.now());
    parts.push(`7d ${sevenDay.percentage}%${reset ? ` r${reset}` : ""}`);
  }

  return {
    five_hour: {
      used_percentage: fiveHour?.percentage ?? null,
      resets_at: fiveHour?.nextResetTime
        ? new Date(fiveHour.nextResetTime).toISOString()
        : null,
    },
    seven_day: {
      used_percentage: sevenDay?.percentage ?? null,
      resets_at: sevenDay?.nextResetTime
        ? new Date(sevenDay.nextResetTime).toISOString()
        : null,
    },
    balance_label: parts.join(" | ") || null,
    updated_at: new Date().toISOString(),
  };
}

async function fetchDeepSeekBalance(baseUrl, apiKey) {
  const balanceUrl = baseUrl.replace(/\/v1.*$/, "").replace(/\/anthropic.*$/, "") + "/v1/user/balance";
  const res = await fetch(balanceUrl, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    signal: AbortSignal.timeout(10_000),
  });
  const body = await res.json();
  if (!body.balance_infos?.length) return null;

  const info = body.balance_infos[0];
  const total = parseFloat(info.total_balance || "0");
  const sym = info.currency === "CNY" ? "¥" : (info.currency || "¥");

  const usedToday = computeDailyUsage(total);
  const todayPart = usedToday > 0 ? ` | 今日 -${sym}${usedToday.toFixed(2)}` : "";

  return {
    five_hour: null,
    seven_day: null,
    balance_label: `${sym}${total.toFixed(2)}${todayPart}`,
    updated_at: new Date().toISOString(),
  };
}

async function main() {
  // 数据源：cc-switch.db 的所有 claude provider（不再扫 ccp marker）。
  // 每个 provider 各查写独立快照，claude-hud 按 stdin.model 路由显示。
  const providers = readProvidersFromDb();
  if (providers.length === 0) process.exit(0);

  for (const p of providers) {
    try {
      await processProvider(p);
    } catch {
      // 单个 provider 失败不影响其他
    }
  }
}

main().catch(() => process.exit(1));
