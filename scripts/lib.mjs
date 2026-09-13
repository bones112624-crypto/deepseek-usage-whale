// deepseek-whale-widget 的共享核心：余额、峰谷计价、今日已用记账、每轮对话消耗。
// 零依赖，只需要 Node 18+。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PLUGIN_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

export const BALANCE_URL = "https://api.deepseek.com/user/balance";
export const BALANCE_TTL_MS = 25_000;

// 峰谷定价（元 / 百万 token），[空闲, 高峰]。
// 上游 dsh-whale-widget 的 BASE_PRICE 是 2026-09-10 调价前的旧价，
// 这里已按 DeepSeek 官方定价页更新；DeepSeek 调价时改这一处即可。
export const BASE_PRICE = { hit: [0.02, 0.04], miss: [1, 2], out: [4, 8] };
export const PRO_PRICE = { hit: [0.15, 0.3], miss: [4.5, 9], out: [13.5, 27] };
export const PRICING = [
  { match: /reasoner|pro/i, price: PRO_PRICE },
  { match: /.*/, price: BASE_PRICE },
];

// 工作日高峰：北京时间 9:00-12:00 与 14:00-18:00；周末全天谷价
export const WEEKEND_VALLEY = true;

export function priceFor(model) {
  const name = String(model ?? "");
  for (const entry of PRICING) if (entry.match.test(name)) return entry.price;
  return BASE_PRICE;
}

/** 给定 ISO 时间，判断是否处于高峰时段（北京时间）。 */
export function isPeakTime(iso) {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return false;
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Shanghai",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(date);
  const pick = (type) => parts.find((p) => p.type === type)?.value ?? "";
  const weekday = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 }[pick("weekday")];
  if (!weekday) return false;
  if (WEEKEND_VALLEY && weekday >= 6) return false;
  const minutes = (Number(pick("hour")) % 24) * 60 + Number(pick("minute"));
  return (minutes >= 540 && minutes < 720) || (minutes >= 840 && minutes < 1080);
}

/** 按峰谷单价换算一次用量的金额。 */
export function costOf({ model, hit = 0, miss = 0, out = 0, at = new Date().toISOString() }) {
  const p = priceFor(model);
  const idx = isPeakTime(at) ? 1 : 0;
  return (
    (hit * p.hit[idx] + miss * p.miss[idx] + out * p.out[idx]) / 1_000_000
  );
}

export const CURRENCY_SYMBOL = { CNY: "¥", USD: "$", EUR: "€" };

export function formatMoney(value, currency) {
  const symbol = CURRENCY_SYMBOL[currency] ?? "";
  const n = Number(value ?? 0);
  if (!symbol) return `${n.toFixed(2)} ${currency ?? ""}`.trim();
  return `${symbol} ${n.toFixed(2)}`;
}

/* ------------------------------------------------------------------ */
/* 路径与配置                                                          */
/* ------------------------------------------------------------------ */

function firstNonEmpty(...values) {
  for (const v of values) if (typeof v === "string" && v.trim()) return v.trim();
  return null;
}

export function safeHome() {
  try {
    const home = os.homedir();
    if (home) return home;
  } catch {}
  const drive = process.env.HOMEDRIVE;
  const rest = process.env.HOMEPATH;
  return firstNonEmpty(
    process.env.USERPROFILE,
    process.env.HOME,
    drive && rest ? `${drive}${rest}` : null,
  );
}

export function resolveDataDir(explicit) {
  const dir = firstNonEmpty(
    explicit,
    process.env.DEEPSEEK_WHALE_DIR,
    safeHome() ? path.join(safeHome(), ".deepseek-whale") : null,
  );
  if (!dir) throw new Error("无法确定数据目录，请设置 DEEPSEEK_WHALE_DIR。");
  fs.mkdirSync(dir, { recursive: true });
  return path.resolve(dir);
}

export function paths(dataDir) {
  const dir = resolveDataDir(dataDir);
  return {
    dir,
    config: path.join(dir, "config.json"),
    usage: path.join(dir, "usage.json"),
    cost: path.join(dir, "last-turn.json"),
  };
}

function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if (error && (error.code === "ENOENT" || error.name === "SyntaxError")) return fallback;
    throw error;
  }
}

export function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

export const DEFAULT_CONFIG = {
  scale: 1.5,
  sound: true,
  vol: 1,
  soundSet: "duck",
  usageMode: "ledger",
  peakMode: "default",
  bubbleOn: true,
  turnCostOn: true,
  turnCostCloseSec: 5,
  x: null,
  y: null,
};

export function loadConfig(dataDir) {
  return { ...DEFAULT_CONFIG, ...(readJson(paths(dataDir).config, {}) ?? {}) };
}

export function saveConfig(patch, dataDir) {
  const next = { ...loadConfig(dataDir), ...patch };
  writeJson(paths(dataDir).config, next);
  return next;
}

/* ------------------------------------------------------------------ */
/* 凭据                                                                */
/* ------------------------------------------------------------------ */

let providerCache;

/** 从 ~/.codex/config.toml 里找 DeepSeek provider 的 key。 */
export function readCodexProvider() {
  if (providerCache !== undefined) return providerCache;
  providerCache = null;
  const home = safeHome();
  if (!home) return providerCache;
  const codexHome = firstNonEmpty(process.env.CODEX_HOME, path.join(home, ".codex"));
  let text;
  try {
    text = fs.readFileSync(path.join(codexHome, "config.toml"), "utf8");
  } catch {
    return providerCache;
  }

  const providers = new Map();
  let current = null;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/#.*$/, "").trim();
    if (!line) continue;
    const section = line.match(/^\[([^\]]+)\]$/);
    if (section) {
      const name = section[1].trim();
      const prefix = "model_providers.";
      current = name.startsWith(prefix) ? name.slice(prefix.length).replace(/^"|"$/g, "") : null;
      if (current && !providers.has(current)) providers.set(current, {});
      continue;
    }
    if (!current) continue;
    const kv = line.match(/^([A-Za-z0-9_."-]+)\s*=\s*(.+)$/);
    if (!kv) continue;
    const key = kv[1].replace(/^"|"$/g, "");
    let value = kv[2].trim();
    const quoted = value.match(/^(['"])(.*)\1$/);
    if (quoted) value = quoted[2];
    providers.get(current)[key] = value;
  }

  for (const info of providers.values()) {
    const baseUrl = info.base_url ?? "";
    const name = info.name ?? "";
    if (!/deepseek/i.test(baseUrl) && !/deepseek/i.test(name)) continue;
    const key = firstNonEmpty(info.experimental_bearer_token, info.api_key, info.bearer_token);
    if (key) {
      providerCache = { key, source: "codex config.toml", baseUrl };
      return providerCache;
    }
  }
  return providerCache;
}

export function resolveAuth(dataDir, explicitKey) {
  const explicit = firstNonEmpty(explicitKey);
  if (explicit) return { key: explicit, source: "显式传入" };
  const stored = firstNonEmpty(loadConfig(dataDir).apiKey);
  if (stored) return { key: stored, source: "config.json" };
  const fromEnv = firstNonEmpty(process.env.DEEPSEEK_API_KEY);
  if (fromEnv) return { key: fromEnv, source: "DEEPSEEK_API_KEY" };
  const codex = readCodexProvider();
  if (codex) return { key: codex.key, source: codex.source };
  return null;
}

/* ------------------------------------------------------------------ */
/* 余额                                                                */
/* ------------------------------------------------------------------ */

let balanceCache = null;
let balanceInFlight = null;

/** 按上游规则挑展示项：优先 CNY 且 >0，其次任意非零，再退 CNY，最后第一项。 */
export function pickBalance(infos) {
  const list = Array.isArray(infos) ? infos.filter(Boolean) : [];
  if (list.length === 0) return null;
  const num = (x) => Number(x?.total_balance ?? 0);
  const cny = list.find((i) => String(i.currency).toUpperCase() === "CNY");
  if (cny && num(cny) > 0) return cny;
  const nonZero = list.find((i) => num(i) > 0);
  if (nonZero) return nonZero;
  if (cny) return cny;
  return list[0];
}

export async function fetchBalance({ dataDir, apiKey, force = false } = {}) {
  const now = Date.now();
  if (!force && balanceCache && now - balanceCache.at < BALANCE_TTL_MS) {
    return balanceCache.value;
  }
  if (balanceInFlight) return balanceInFlight;

  const auth = resolveAuth(dataDir, apiKey);
  if (!auth) {
    return { ok: false, code: "no_key", error: "未配置 DEEPSEEK_API_KEY" };
  }

  balanceInFlight = (async () => {
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const response = await fetch(BALANCE_URL, {
          headers: { Authorization: `Bearer ${auth.key}`, Accept: "application/json" },
          signal: AbortSignal.timeout(20_000),
        });
        if (response.status >= 400 && response.status < 500) {
          const text = await response.text();
          return {
            ok: false,
            code: `http_${response.status}`,
            error: text.slice(0, 200) || `HTTP ${response.status}`,
          };
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const payload = await response.json();
        const picked = pickBalance(payload.balance_infos);
        if (!picked) return { ok: false, code: "no_balance", error: "接口未返回余额" };
        const value = {
          ok: true,
          totalBalance: Number(picked.total_balance ?? 0),
          grantedBalance: Number(picked.granted_balance ?? 0),
          toppedUpBalance: Number(picked.topped_up_balance ?? 0),
          currency: String(picked.currency ?? "CNY"),
          isAvailable: Boolean(payload.is_available),
          updatedAt: new Date().toISOString(),
          source: auth.source,
        };
        balanceCache = { at: Date.now(), value };
        return value;
      } catch (error) {
        lastError = error;
        if (attempt === 0) await new Promise((r) => setTimeout(r, 500));
      }
    }
    // 瞬时失败：有缓存就沿用旧值
    if (balanceCache) {
      return { ...balanceCache.value, stale: true, error: String(lastError?.message ?? lastError) };
    }
    return { ok: false, code: "network", error: String(lastError?.message ?? lastError) };
  })();

  try {
    return await balanceInFlight;
  } finally {
    balanceInFlight = null;
  }
}

export function clearBalanceCache() {
  balanceCache = null;
}

/* ------------------------------------------------------------------ */
/* 今日已用：小鲸鱼记账（余额差值）                                     */
/* ------------------------------------------------------------------ */

function localDay(iso = new Date().toISOString()) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(iso));
}

/** 用一次余额观测更新账本；返回 { todayUsage, currency }。 */
export function observeBalance(balance, dataDir) {
  const file = paths(dataDir).usage;
  const today = localDay();
  const state = readJson(file, null) ?? {
    date: today,
    lastBalance: null,
    lastCurrency: null,
    todayUsage: 0,
    history: [],
  };

  if (state.date !== today) {
    const history = Array.isArray(state.history) ? state.history : [];
    history.push({ date: state.date, usage: Number(state.todayUsage ?? 0) });
    state.history = history.slice(-30);
    state.date = today;
    state.todayUsage = 0;
    state.lastBalance = balance.totalBalance;
    state.lastCurrency = balance.currency;
  } else if (state.lastBalance === null || state.lastCurrency === null) {
    state.lastBalance = balance.totalBalance;
    state.lastCurrency = balance.currency;
  } else if (state.lastCurrency !== balance.currency) {
    // 币种变了：只重置基准，不记差值（否则会把汇率跳变记成消费）
    state.lastBalance = balance.totalBalance;
    state.lastCurrency = balance.currency;
  } else if (balance.totalBalance < state.lastBalance) {
    state.todayUsage = Number(state.todayUsage ?? 0) + (state.lastBalance - balance.totalBalance);
    state.lastBalance = balance.totalBalance;
  } else {
    state.lastBalance = balance.totalBalance;
  }

  writeJson(file, state);
  return { todayUsage: Number(state.todayUsage ?? 0), currency: balance.currency };
}

export function readLedger(dataDir) {
  const state = readJson(paths(dataDir).usage, null);
  if (!state) return { todayUsage: 0, currency: "CNY" };
  const today = localDay();
  return {
    todayUsage: state.date === today ? Number(state.todayUsage ?? 0) : 0,
    currency: state.lastCurrency ?? "CNY",
  };
}

/* ------------------------------------------------------------------ */
/* 每轮对话消耗：读 Codex 会话日志                                       */
/* ------------------------------------------------------------------ */

function sessionsRoot() {
  const home = safeHome();
  if (!home) return null;
  const codexHome = firstNonEmpty(process.env.CODEX_HOME, path.join(home, ".codex"));
  return path.join(codexHome, "sessions");
}

function walkRollouts(root, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) walkRollouts(full, out);
    else if (entry.isFile() && /^rollout-.*\.jsonl$/i.test(entry.name)) out.push(full);
  }
  return out;
}

/**
 * 从 Codex 会话日志里读出最近一轮的 token 用量与金额。
 * Codex 每次调用都会写 token_usage_record（真实 usage，非估算）。
 */
export function readLastTurn(dataDir, { limit = 40 } = {}) {
  const root = sessionsRoot();
  if (!root) return null;
  const files = walkRollouts(root);
  if (files.length === 0) return null;
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);

  const records = [];
  let liveModel = null;
  for (const file of files.slice(0, 3)) {
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let event;
      try {
        event = JSON.parse(trimmed);
      } catch {
        continue;
      }
      if (event?.type === "turn_context" && event.payload?.model) {
        liveModel = event.payload.model;
      } else if (event?.type === "session_meta") {
        liveModel = event.payload?.base_instructions?.provenance?.model ?? liveModel;
      } else if (event?.type === "token_usage_record") {
        const usage = event.payload?.usage ?? {};
        const input = Number(usage.input_tokens ?? 0);
        const cached = Number(usage.cached_input_tokens ?? 0);
        const output = Number(usage.output_tokens ?? 0);
        if (input + output <= 0) continue;
        records.push({
          ts: event.timestamp,
          turn: event.payload?.turn_id ?? null,
          model: liveModel,
          hit: cached,
          miss: Math.max(0, input - cached),
          out: output,
          reasoning: Number(usage.reasoning_output_tokens ?? 0),
        });
      }
    }
  }
  if (records.length === 0) return null;
  records.sort((a, b) => Date.parse(a.ts) - Date.parse(b.ts));

  const last = records[records.length - 1];
  const turnId = last.turn;
  const sameTurn = records.filter((r) => r.turn === turnId);
  const sum = sameTurn.reduce(
    (acc, r) => ({
      hit: acc.hit + r.hit,
      miss: acc.miss + r.miss,
      out: acc.out + r.out + r.reasoning,
    }),
    { hit: 0, miss: 0, out: 0 },
  );
  const amount = costOf({ model: last.model, ...sum, at: last.ts });

  const file = paths(dataDir).cost;
  const prev = readJson(file, null);
  const seq = prev && prev.turn === turnId ? Number(prev.seq ?? 0) : Number(prev?.seq ?? 0) + 1;
  const payload = {
    ok: true,
    seq,
    turn: turnId,
    amount: Number(amount.toFixed(6)),
    model: last.model,
    tokens: { hit: sum.hit, miss: sum.miss, out: sum.out },
    ts: last.ts,
  };
  if (!prev || prev.turn !== turnId || prev.amount !== payload.amount) {
    writeJson(file, payload);
  }
  return payload;
}
