#!/usr/bin/env node

// Fetch third-party provider quota/balance data for claude-hud external usage.
// Credentials stay in cc-switch.db; snapshots contain display data only.
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const OUTPUT_DIR = process.env.CCP_USAGE_DIR || SCRIPT_DIR;
const DB = process.env.CC_SWITCH_DB || join(homedir(), ".cc-switch", "cc-switch.db");
const TIMEOUT_MS = Number(process.env.CCP_USAGE_TIMEOUT_MS || 10_000);
const MIN_AGE_MS = Number(process.env.CCP_USAGE_MIN_AGE_MS || 45_000);
const LOCK_DIR = join(OUTPUT_DIR, ".provider-usage.lock");

function todayDate() {
  const date = new Date();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

function safeName(value) {
  const safe = String(value)
    .normalize("NFKC")
    .replace(/[^\p{L}\p{N}._-]+/gu, "_")
    .replace(/^\.+/, "")
    .replace(/_+/g, "_")
    .slice(0, 80);
  return safe || "provider";
}

function atomicWriteJson(path, value) {
  const temporary = `${path}.tmp.${process.pid}`;
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    renameSync(temporary, path);
    chmodSync(path, 0o600);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch {
      // Nothing to clean up.
    }
    throw error;
  }
}

function snapshotPath(provider) {
  return join(OUTPUT_DIR, `provider-usage-${safeName(provider.name)}.json`);
}

function snapshotsAreFresh(providers) {
  const now = Date.now();
  return providers.every((provider) => {
    try {
      const snapshot = JSON.parse(readFileSync(snapshotPath(provider), "utf8"));
      const updatedAt = Date.parse(snapshot.updated_at);
      return Number.isFinite(updatedAt) && now - updatedAt < MIN_AGE_MS;
    } catch {
      return false;
    }
  });
}

function acquireLock() {
  try {
    mkdirSync(LOCK_DIR, { mode: 0o700 });
    return true;
  } catch {
    try {
      if (Date.now() - statSync(LOCK_DIR).mtimeMs > TIMEOUT_MS * 2) {
        rmSync(LOCK_DIR, { recursive: true, force: true });
        mkdirSync(LOCK_DIR, { mode: 0o700 });
        return true;
      }
    } catch {
      // Another process may have released the lock between checks.
    }
    return false;
  }
}

function releaseLock() {
  rmSync(LOCK_DIR, { recursive: true, force: true });
}

function readProvidersFromDb() {
  if (!existsSync(DB)) {
    throw new Error(`cc-switch database not found: ${DB}`);
  }
  const sql = `SELECT id,
                      name,
                      json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') AS base_url,
                      COALESCE(
                        json_extract(settings_config, '$.env.ANTHROPIC_AUTH_TOKEN'),
                        json_extract(settings_config, '$.env.ANTHROPIC_API_KEY')
                      ) AS credential
               FROM providers
               WHERE app_type='claude'
                 AND base_url IS NOT NULL
                 AND credential IS NOT NULL`;
  const raw = execFileSync("sqlite3", ["-json", DB, sql], { encoding: "utf8" });
  return JSON.parse(raw || "[]");
}

function providerKind(baseUrl) {
  try {
    const hostname = new URL(baseUrl).hostname.toLowerCase();
    if (hostname === "api.deepseek.com" || hostname.endsWith(".deepseek.com")) return "deepseek";
    if (hostname === "open.bigmodel.cn" || hostname.endsWith(".bigmodel.cn") || hostname === "api.z.ai" || hostname.endsWith(".z.ai")) return "glm";
  } catch {
    return null;
  }
  return null;
}

async function fetchJson(url, credential) {
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${credential}`,
      "Content-Type": "application/json",
    },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${response.statusText}`);
  }
  try {
    return await response.json();
  } catch {
    throw new Error("response is not valid JSON");
  }
}

function formatRemaining(milliseconds) {
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return "";
  const totalMinutes = Math.floor(milliseconds / 60_000);
  if (totalMinutes < 60) return `${totalMinutes}m`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours < 24) return minutes ? `${hours}h${minutes}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const remainingHours = hours % 24;
  return remainingHours ? `${days}d${remainingHours}h` : `${days}d`;
}

function computeDailyUsage(provider, currentBalance) {
  const statePath = join(OUTPUT_DIR, `deepseek-daily-${safeName(provider.id)}.json`);
  const today = todayDate();
  let state = null;
  try {
    state = JSON.parse(readFileSync(statePath, "utf8"));
  } catch {
    state = null;
  }

  let opening = state?.date === today ? Number(state.opening_balance) : currentBalance;
  if (!Number.isFinite(opening) || currentBalance > opening) opening = currentBalance;
  atomicWriteJson(statePath, { date: today, opening_balance: opening });
  return Math.max(0, opening - currentBalance);
}

async function fetchGlmUsage(credential) {
  const body = await fetchJson("https://open.bigmodel.cn/api/monitor/usage/quota/limit", credential);
  if (!body.success || !Array.isArray(body.data?.limits)) {
    const detail = [body.code, body.msg || body.message].filter(Boolean).join(": ");
    throw new Error(`unexpected GLM quota response${detail ? ` (${detail})` : ""}`);
  }
  const tokenLimits = body.data.limits.filter((limit) => limit.type === "TOKENS_LIMIT");
  const fiveHour = tokenLimits.find((limit) => limit.unit === 3);
  const sevenDay = tokenLimits.find((limit) => limit.unit === 6);
  if (!fiveHour && !sevenDay) throw new Error("GLM token quota windows are missing");

  const parts = [];
  for (const [label, limit] of [["5h", fiveHour], ["7d", sevenDay]]) {
    if (!limit) continue;
    const percentage = Number(limit.percentage);
    if (!Number.isFinite(percentage)) continue;
    const reset = formatRemaining(Number(limit.nextResetTime) - Date.now());
    parts.push(`${label} [${percentage}%]${reset ? ` in ${reset}` : ""}`);
  }
  if (!parts.length) throw new Error("GLM quota percentages are invalid");
  return {
    five_hour: null,
    seven_day: null,
    balance_label: parts.join(" | "),
    updated_at: new Date().toISOString(),
  };
}

async function fetchDeepSeekBalance(provider) {
  const root = provider.base_url.replace(/\/v1.*$/, "").replace(/\/anthropic.*$/, "");
  const body = await fetchJson(`${root}/v1/user/balance`, provider.credential);
  if (!Array.isArray(body.balance_infos) || !body.balance_infos.length) {
    throw new Error("unexpected DeepSeek balance response");
  }
  const info = body.balance_infos[0];
  const total = Number.parseFloat(info.total_balance);
  if (!Number.isFinite(total)) throw new Error("DeepSeek balance is invalid");

  const symbol = info.currency === "CNY" ? "¥" : (info.currency || "¥");
  const usedToday = computeDailyUsage(provider, total);
  const todayPart = usedToday > 0 ? ` | 今日 -${usedToday.toFixed(2)}${symbol}` : "";
  return {
    five_hour: null,
    seven_day: null,
    balance_label: `余额 ${total.toFixed(2)}${symbol}${todayPart}`,
    updated_at: new Date().toISOString(),
  };
}

async function processProvider(provider) {
  const kind = providerKind(provider.base_url);
  if (!kind) return { name: provider.name, status: "unsupported" };
  const snapshot = kind === "glm"
    ? await fetchGlmUsage(provider.credential)
    : await fetchDeepSeekBalance(provider);
  const outputPath = snapshotPath(provider);
  atomicWriteJson(outputPath, snapshot);
  return { name: provider.name, status: "updated", outputPath };
}

function checkEnvironment() {
  const providers = readProvidersFromDb();
  const supported = providers.filter((provider) => providerKind(provider.base_url));
  const hud = checkHudCompatibility();
  console.log(`database: ${DB}`);
  console.log(`output: ${OUTPUT_DIR}`);
  console.log(`supported providers: ${supported.map((provider) => provider.name).join(", ") || "none"}`);
  console.log(`claude-hud: ${hud.message}`);
  if (!supported.length || !hud.compatible) process.exitCode = 1;
}

function checkHudCompatibility() {
  const cacheRoot = join(homedir(), ".claude", "plugins", "cache", "claude-hud", "claude-hud");
  try {
    const versions = readdirSync(cacheRoot)
      .filter((entry) => /^\d+\.\d+\.\d+$/.test(entry))
      .sort((left, right) => {
        const a = left.split(".").map(Number);
        const b = right.split(".").map(Number);
        return (a[0] - b[0]) || (a[1] - b[1]) || (a[2] - b[2]);
      });
    const latest = versions.at(-1);
    if (!latest) return { compatible: false, message: "not installed" };
    const configSource = readFileSync(join(cacheRoot, latest, "src", "config.ts"), "utf8");
    const usageSource = readFileSync(join(cacheRoot, latest, "src", "external-usage.ts"), "utf8");
    const compatible = configSource.includes("externalUsageByModel")
      && usageSource.includes("externalUsageByModel");
    return {
      compatible,
      message: compatible
        ? `${latest} compatible`
        : `${latest} missing externalUsageByModel support`,
    };
  } catch (error) {
    return { compatible: false, message: `check failed: ${error.message}` };
  }
}

async function main() {
  if (process.argv.includes("--check")) {
    checkEnvironment();
    return;
  }

  const providers = readProvidersFromDb();
  const supported = providers.filter((provider) => providerKind(provider.base_url));
  if (!supported.length) {
    console.error("provider-usage: no supported providers found");
    process.exitCode = 1;
    return;
  }

  if (!process.argv.includes("--force") && snapshotsAreFresh(supported)) return;
  if (!acquireLock()) return;

  try {
    const results = await Promise.allSettled(supported.map(processProvider));
    let failures = 0;
    results.forEach((result, index) => {
      const name = supported[index].name;
      if (result.status === "rejected") {
        failures += 1;
        console.error(`provider-usage: ${name}: ${result.reason?.message || result.reason}`);
      }
    });
    if (failures) process.exitCode = 1;
  } finally {
    releaseLock();
  }
}

main().catch((error) => {
  console.error(`provider-usage: ${error.message || error}`);
  process.exitCode = 1;
});
