#!/usr/bin/env node
// 小鲸鱼挂件的命令行 + MCP 服务。
//
//   node scripts/whale.mjs balance      查余额
//   node scripts/whale.mjs today        今日已用
//   node scripts/whale.mjs last-turn    最近一轮对话消耗
//   node scripts/whale.mjs start        启动桌面挂件
//   node scripts/whale.mjs status       挂件运行状态
//   node scripts/whale.mjs mcp          MCP stdio 服务（Codex 调用）

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";

import {
  PLUGIN_ROOT,
  costOf,
  fetchBalance,
  formatMoney,
  isPeakTime,
  loadConfig,
  paths,
  readLastTurn,
  readLedger,
  resolveAuth,
  resolveDataDir,
  saveConfig,
} from "./lib.mjs";

const WIDGET = path.join(PLUGIN_ROOT, "widget", "whale.ps1");
const SERVER_NAME = "deepseek-whale-widget";
const SERVER_VERSION = "1.0.0";

function widgetPid(dataDir) {
  const file = path.join(resolveDataDir(dataDir), "widget.pid");
  try {
    const pid = Number(fs.readFileSync(file, "utf8").trim());
    process.kill(pid, 0);
    return pid;
  } catch {
    return null;
  }
}

function startWidget({ dataDir, assetDir, quiet }) {
  const dir = resolveDataDir(dataDir);
  const existing = widgetPid(dir);
  if (existing) return { started: false, pid: existing, reason: "已在运行" };

  // 用 WMI 创建进程，这是 Windows 上最可靠的后台启动方式：
  //   - spawn(detached:true) 会让 powershell 以 DETACHED_PROCESS 启动、拿不到控制台，
  //     脚本会立刻以 0 退出，挂件根本起不来；
  //   - spawn 不 detached 时子进程共享父进程控制台，父进程一退出它就跟着死。
  // Win32_Process.Create 两者都能避开。
  let cmdline = `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "${WIDGET}" -DataDir "${dir}"`;
  if (assetDir) cmdline += ` -AssetDir "${assetDir}"`;
  if (quiet) cmdline += " -Quiet";

  const script =
    `$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = '${
      cmdline.replace(/'/g, "''")
    }' }; ` +
    `if ($r.ReturnValue -eq 0) { $r.ProcessId } else { throw "Win32_Process.Create 失败: $($r.ReturnValue)" }`;

  const out = execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
    encoding: "utf8",
  }).trim();
  const pid = Number(out);
  if (!Number.isFinite(pid) || pid <= 0) throw new Error(`启动失败，返回：${out}`);
  try {
    fs.writeFileSync(path.join(dir, "widget.pid"), String(pid), "utf8");
  } catch {}
  return { started: true, pid };
}

// 收起挂件：写停止信号，挂件每 300ms 检查一次，收到后走正常关闭流程
// （位置与设置都会被保存），等不到再强制结束。
async function stopWidget({ dataDir, waitMs = 6000 }) {
  const dir = resolveDataDir(dataDir);
  const pid = widgetPid(dir);
  const stopFile = path.join(dir, "whale-stop");
  if (!pid) {
    try {
      fs.rmSync(stopFile, { force: true });
    } catch {}
    return { stopped: false, reason: "未在运行" };
  }
  try {
    fs.writeFileSync(stopFile, "stop", "utf8");
  } catch {}
  const deadline = Date.now() + waitMs;
  let alive = true;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 120));
    try {
      process.kill(pid, 0);
    } catch {
      alive = false;
      break;
    }
  }
  let forced = false;
  if (alive) {
    try {
      process.kill(pid);
      forced = true;
    } catch {}
  }
  try {
    fs.rmSync(stopFile, { force: true });
  } catch {}
  try {
    fs.rmSync(path.join(dir, "widget.pid"), { force: true });
  } catch {}
  return { stopped: true, pid, forced };
}

async function snapshot(dataDir) {
  const dir = resolveDataDir(dataDir);
  const config = loadConfig(dir);
  const auth = resolveAuth(dir);
  const balance = await fetchBalance({ dataDir: dir });
  const ledger = readLedger(dir);
  const lastTurn = readLastTurn(dir);
  return {
    ok: balance.ok !== false,
    balance: balance.ok ? balance.totalBalance : null,
    currency: balance.currency ?? ledger.currency ?? "CNY",
    granted: balance.grantedBalance ?? null,
    toppedUp: balance.toppedUpBalance ?? null,
    stale: Boolean(balance.stale),
    error: balance.error ?? null,
    todayUsage: config.usageMode === "ledger" ? ledger.todayUsage : null,
    usageMode: config.usageMode,
    isPeak: isPeakTime(new Date().toISOString()),
    lastTurn,
    credential: auth ? auth.source : null,
    widgetRunning: Boolean(widgetPid(dir)),
    dataDir: dir,
  };
}

/* ------------------------------------------------------------------ */
/* MCP                                                                 */
/* ------------------------------------------------------------------ */

const TOOLS = [
  {
    name: "whale_balance",
    title: "DeepSeek 余额（小鲸鱼）",
    description:
      "查询 DeepSeek 账户余额，并附带今日已用、当前是否高峰时段、是否正处于每轮对话消耗。小鲸鱼桌面挂件展示的就是这些数据。",
    inputSchema: {
      type: "object",
      properties: {
        refresh: { type: "boolean", description: "忽略 25 秒缓存强制刷新，默认 false。" },
        dataDir: { type: "string", description: "数据目录，默认 ~/.deepseek-whale。" },
      },
      additionalProperties: false,
    },
    handler: async (args) => {
      const snap = await snapshot(args.dataDir);
      if (snap.ok === false) {
        return { error: snap.error ?? "余额获取失败" };
      }
      const lines = [
        `余额：${formatMoney(snap.balance, snap.currency)}`,
        `今日已用：${formatMoney(snap.todayUsage ?? 0, snap.currency)}（${snap.usageMode === "ledger" ? "小鲸鱼记账" : "令牌模式"}）`,
        `当前时段：${snap.isPeak ? "高峰" : "空闲"}`,
      ];
      if (snap.stale) lines.push("（余额来自缓存，最近一次请求失败）");
      return { text: lines.join("\n"), structured: snap };
    },
  },
  {
    name: "whale_last_turn",
    title: "上一轮对话消耗",
    description:
      "读取 Codex 会话日志里最近一轮对话的真实 token 用量，按峰谷单价换算成金额。这是精确值，不是估算。",
    inputSchema: {
      type: "object",
      properties: { dataDir: { type: "string", description: "数据目录。" } },
      additionalProperties: false,
    },
    handler: async (args) => {
      const turn = readLastTurn(resolveDataDir(args.dataDir));
      if (!turn) return { error: "还没读到会话记录" };
      const rate = turn.cacheHitRate === null ? "—" : `${turn.cacheHitRate}%`;
      const threadRate = turn.threadCacheHitRate === null ? "—" : `${turn.threadCacheHitRate}%`;
      return {
        text:
          `上一轮消耗：${formatMoney(turn.amount, "CNY")}\n` +
          `模型：${turn.model ?? "未知"}\n` +
          `缓存命中 ${turn.tokens.hit} / 未命中 ${turn.tokens.miss} / 输出 ${turn.tokens.out}\n` +
          `本轮命中率：${rate}　本会话命中率：${threadRate}`,
        structured: turn,
      };
    },
  },
  {
    name: "whale_widget",
    title: "小鲸鱼挂件控制",
    description:
      "启动或查询桌面小鲸鱼挂件。挂件常驻在屏幕角落，显示余额、今日已用和每轮消耗，支持拖拽吸附与随机台词。",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["start", "stop", "status"], description: "默认 status。" },
        dataDir: { type: "string", description: "数据目录。" },
      },
      additionalProperties: false,
    },
    handler: async (args) => {
      const dir = resolveDataDir(args.dataDir);
      if (args.action === "start") {
        const r = startWidget({ dataDir: dir });
        return {
          text: r.started ? `小鲸鱼挂件已启动（pid ${r.pid}）` : `挂件已在运行（pid ${r.pid}）`,
          structured: r,
        };
      }
      if (args.action === "stop") {
        const r = await stopWidget({ dataDir: dir });
        return {
          text: r.stopped ? `小鲸鱼挂件已收起（pid ${r.pid}）` : "挂件未在运行",
          structured: r,
        };
      }
      const pid = widgetPid(dir);
      return {
        text: pid ? `挂件正在运行（pid ${pid}）` : "挂件未运行",
        structured: { running: Boolean(pid), pid },
      };
    },
  },
];

const TOOL_MAP = new Map(TOOLS.map((t) => [t.name, t]));
const send = (m) => process.stdout.write(`${JSON.stringify(m)}\n`);

async function handleMcp(message) {
  const { id, method, params } = message;
  const reply = (result) => send({ jsonrpc: "2.0", id, result });
  switch (method) {
    case "initialize":
      reply({
        protocolVersion: params?.protocolVersion ?? "2025-11-25",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions:
          "小鲸鱼挂件工具。whale_balance 查余额与今日已用；whale_last_turn 读最近一轮对话消耗（真实 usage）；whale_widget 启停桌面挂件。金额按 DeepSeek 官方峰谷单价换算。",
      });
      return;
    case "ping":
      reply({});
      return;
    case "tools/list":
      reply({ tools: TOOLS.map(({ handler, ...t }) => t) });
      return;
    case "tools/call": {
      const tool = TOOL_MAP.get(params?.name);
      if (!tool) {
        send({ jsonrpc: "2.0", id, error: { code: -32602, message: `Unknown tool: ${params?.name ?? ""}` } });
        return;
      }
      try {
        const r = await tool.handler(params?.arguments ?? {});
        if (r?.error) {
          reply({ content: [{ type: "text", text: r.error }], isError: true });
        } else {
          reply({
            content: [{ type: "text", text: r.text }],
            ...(r.structured ? { structuredContent: r.structured } : {}),
          });
        }
      } catch (error) {
        reply({ content: [{ type: "text", text: `执行失败：${error?.message ?? error}` }], isError: true });
      }
      return;
    }
    default:
      if (id !== undefined && id !== null) {
        send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Unsupported method: ${method}` } });
      }
  }
}

function logMcp(dir, message) {
  try {
    fs.appendFileSync(
      path.join(dir, "mcp.log"),
      `[${new Date().toISOString()}] ${message}\n`,
      "utf8",
    );
  } catch {}
}

// Codex 每个会话都会拉起这个 MCP 服务，"服务被启动"就是"Codex 打开了"的天然信号。
// 所以这里不需要注册任何开机自启：只有 Codex 真的开着才放出挂件。
// 挂件自己始终盯着 Codex 进程，Codex 退出后会优雅收起（见 whale.ps1 的 codexTimer）。
function ensureWidgetForCodex() {
  try {
    const dir = resolveDataDir();
    if (loadConfig(dir).followCodex === false) {
      logMcp(dir, "followCodex 已关闭，不自动放出挂件");
      return;
    }
    if (widgetPid(dir)) return; // 已经在跑了
    const r = startWidget({ dataDir: dir });
    logMcp(dir, r.started ? `已放出挂件 pid=${r.pid}` : `未启动：${r.reason ?? "已在运行"}`);
  } catch (error) {
    try {
      logMcp(resolveDataDir(), `放出挂件失败：${error?.message ?? error}`);
    } catch {}
  }
}

function runMcp() {
  ensureWidgetForCodex();
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch {
      return;
    }
    if (message?.id === undefined || message?.id === null) return;
    handleMcp(message).catch((error) =>
      send({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: String(error?.message ?? error) } }),
    );
  });
  process.stdin.on("close", () => process.exit(0));
}

/* ------------------------------------------------------------------ */
/* CLI                                                                 */
/* ------------------------------------------------------------------ */

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const flag = (name) => {
    const i = rest.indexOf(`--${name}`);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  const dataDir = flag("data-dir");
  const json = rest.includes("--json");

  switch (command) {
    case "mcp":
      runMcp();
      return;
    case "balance":
    case "today":
    case "last-turn":
    case "status": {
      const snap = await snapshot(dataDir);
      if (command === "last-turn") {
        const turn = snap.lastTurn;
        if (json) process.stdout.write(`${JSON.stringify(turn, null, 2)}\n`);
        else if (turn)
          process.stdout.write(
            `上一轮对话消耗 ${formatMoney(turn.amount, snap.currency)}（${turn.model ?? "未知"}，命中 ${turn.tokens.hit} / 未命中 ${turn.tokens.miss} / 输出 ${turn.tokens.out}）\n`,
          );
        else process.stdout.write("还没读到会话记录\n");
        return;
      }
      if (json) {
        process.stdout.write(`${JSON.stringify(snap, null, 2)}\n`);
        return;
      }
      if (command === "balance") {
        if (snap.balance === null) process.stdout.write(`余额获取失败：${snap.error ?? "未知"}（凭据：${snap.credential ?? "未找到"}）\n`);
        else process.stdout.write(`余额 ${formatMoney(snap.balance, snap.currency)}${snap.stale ? "（缓存）" : ""}\n`);
        return;
      }
      if (command === "today") {
        process.stdout.write(`今日已用 ${formatMoney(snap.todayUsage ?? 0, snap.currency)}（${snap.usageMode}）\n`);
        return;
      }
      process.stdout.write(
        [
          `挂件：${snap.widgetRunning ? "运行中" : "未运行"}`,
          `余额：${snap.balance === null ? "获取失败" : formatMoney(snap.balance, snap.currency)}`,
          `今日已用：${formatMoney(snap.todayUsage ?? 0, snap.currency)}`,
          `时段：${snap.isPeak ? "高峰" : "空闲"}`,
          `数据目录：${snap.dataDir}`,
        ].join("\n") + "\n",
      );
      return;
    }
    case "start": {
      const r = startWidget({ dataDir, quiet: rest.includes("--quiet") });
      process.stdout.write(r.started ? `小鲸鱼挂件已启动（pid ${r.pid}）\n` : `挂件已在运行（pid ${r.pid}）\n`);
      return;
    }
    case "stop": {
      const r = await stopWidget({ dataDir });
      process.stdout.write(
        r.stopped
          ? `小鲸鱼挂件已收起（pid ${r.pid}${r.forced ? "，未响应，已强制结束" : ""}）\n`
          : "小鲸鱼挂件未在运行\n",
      );
      return;
    }
    case "config": {
      const patch = {};
      for (const key of ["scale", "sound", "vol", "soundSet", "usageMode", "peakMode", "bubbleOn", "turnCostOn", "followCodex", "quitHotkey"]) {
        const v = flag(key);
        if (v !== undefined) patch[key] = v === "true" ? true : v === "false" ? false : Number.isNaN(Number(v)) ? v : Number(v);
      }
      if (Object.keys(patch).length) saveConfig(patch, dataDir);
      process.stdout.write(`${JSON.stringify(loadConfig(dataDir), null, 2)}\n`);
      return;
    }
    default:
      process.stdout.write(
        "用法：node scripts/whale.mjs <balance|today|last-turn|start|stop|status|config|mcp> [--data-dir <dir>] [--json]\n",
      );
  }
}

main().catch((error) => {
  process.stderr.write(`出错：${error?.message ?? error}\n`);
  process.exit(1);
});
