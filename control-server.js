#!/usr/bin/env node
// MineHost Control Server — runs inside the Codespace
// Provides HTTP + WebSocket API for the úteis frontend to control the Minecraft server

const http = require("http");
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const PORT = 8081;
const SCRIPT_DIR = path.dirname(path.resolve(__filename));
const SERVER_DIR = process.env.SERVER_DIR || path.join(SCRIPT_DIR, "server");
const LOG_FILE = path.join(SERVER_DIR, "server.log");
const CONFIG_FILE = path.join(SERVER_DIR, "minehost.json");
const SERVER_IP_FILE = path.join(SCRIPT_DIR, ".server_ip");
const PLAYIT_CLAIM_FILE = path.join(SCRIPT_DIR, ".playit_claim");

// ── Utility functions ───────────────────────────────────────────────────────

// Strips ANSI/VT escape sequences including TUI codes (cursor positioning, alt screen, etc.)
const ANSI_RE = /\x1b(?:\[[0-9;?]*[A-Za-z]|[()][AB0-2]|[>=])/g;
const BOX_RE = /[┌┐└┘│─├┤┬┴┼╔╗╚╝║═]/g;
function stripLine(l) {
  return l.replace(ANSI_RE, "").replace(BOX_RE, "").replace(/\r/g, "").trim();
}

function sendToConsole(text) {
  try {
    execSync(`tmux send-keys -t mc ${JSON.stringify(text)} C-m`, {
      timeout: 2000,
      stdio: ["pipe", "pipe", "ignore"],
    });
  } catch (e) {
    // tmux session not found — server not running
  }
}

function getServerRunning() {
  try {
    execSync("tmux has-session -t mc 2>/dev/null");
    return true;
  } catch {
    return false;
  }
}

function getLastLines(n = 200) {
  if (!fs.existsSync(LOG_FILE)) return [];
  const content = fs.readFileSync(LOG_FILE, "utf8");
  const lines = content.split(/\r?\n|\r/).map(stripLine).filter((l) => l.length > 0);
  return lines.slice(-n);
}

function getLastLinesWithTotal(n = 500) {
  if (!fs.existsSync(LOG_FILE)) return { lines: [], total: 0 };
  const content = fs.readFileSync(LOG_FILE, "utf8");
  const rawAll = content.split(/\r?\n|\r/);
  // Count total non-empty raw lines without stripLine (fast for large modpack logs)
  let total = 0;
  for (const l of rawAll) if (l.trim()) total++;
  // Apply stripLine only to the last n*2 raw lines (buffer for empties after strip)
  const lines = rawAll.slice(-(n * 2)).map(stripLine).filter((l) => l.length > 0).slice(-n);
  return { lines, total };
}

function getConfig() {
  if (!fs.existsSync(CONFIG_FILE)) return null;
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  } catch {
    return null;
  }
}

function setConfig(obj) {
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(obj, null, 2));
}

function getServerIP() {
  try {
    if (!fs.existsSync(SERVER_IP_FILE)) return null;
    const ip = fs.readFileSync(SERVER_IP_FILE, "utf8").trim();
    return ip || null;
  } catch {
    return null;
  }
}

function getPlayitClaim() {
  try {
    if (!fs.existsSync(PLAYIT_CLAIM_FILE)) return null;
    const url = fs.readFileSync(PLAYIT_CLAIM_FILE, "utf8").trim();
    return url || null;
  } catch {
    return null;
  }
}

function getRam() {
  try {
    const content = fs.readFileSync("/proc/meminfo", "utf8");
    const total = parseInt(content.match(/MemTotal:\s+(\d+)/)?.[1] ?? "0");
    const avail = parseInt(content.match(/MemAvailable:\s+(\d+)/)?.[1] ?? "0");
    if (!total) return null;
    const used = total - avail;
    return {
      usedMB: Math.round(used / 1024),
      totalMB: Math.round(total / 1024),
      percent: Math.round((used / total) * 100),
    };
  } catch {
    return null;
  }
}

// ── WebSocket ───────────────────────────────────────────────────────────────

const wss = { upgrade: null, on: null }; // Will be initialized after ws is installed
let consoleClients = new Set();

// Periodically poll for new console output and broadcast
let lastLogLineCount = 0;

function checkNewOutput() {
  if (!fs.existsSync(LOG_FILE)) return;
  const content = fs.readFileSync(LOG_FILE, "utf8");
  const lines = content.split(/\r?\n|\r/).map(stripLine).filter((l) => l.length > 0);
  if (lines.length > lastLogLineCount) {
    const newLines = lines.slice(lastLogLineCount);
    const text = newLines.join("\n") + "\n";
    for (const client of consoleClients) {
      if (client.readyState === 1 /* WebSocket.OPEN */) {
        client.send(JSON.stringify({ type: "log", data: text }));
      }
    }
    lastLogLineCount = lines.length;
  }
}

setInterval(checkNewOutput, 500);

// ── HTTP Server ─────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS, DELETE");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    return res.end();
  }

  const url = new URL(req.url, `http://localhost:${PORT}`);

  // GET /status
  if (url.pathname === "/status" && req.method === "GET") {
    const running = getServerRunning();
    const config = getConfig();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ running, config }));
    return;
  }

  // GET /log
  if (url.pathname === "/log" && req.method === "GET") {
    const lines = parseInt(url.searchParams.get("lines") || "200");
    const log = getLastLines(lines);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ log }));
    return;
  }

  // POST /cmd
  if (url.pathname === "/cmd" && req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      try {
        const { command } = JSON.parse(body);
        if (!command) throw new Error("Missing command");
        sendToConsole(command);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch (err) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  // POST /config
  if (url.pathname === "/config" && req.method === "POST") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      try {
        const obj = JSON.parse(body);
        setConfig(obj);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      } catch (err) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  // GET /config
  if (url.pathname === "/config" && req.method === "GET") {
    const config = getConfig();
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ config }));
    return;
  }

  // GET /sse — Server-Sent Events for live log streaming
  if (url.pathname === "/sse" && req.method === "GET") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
      "Access-Control-Allow-Origin": "*",
    });

    // Send existing log history immediately on connect
    let lastIndex = 0;
    if (fs.existsSync(LOG_FILE)) {
      const content = fs.readFileSync(LOG_FILE, "utf8");
      const lines = content.split("\n").filter((l) => l.length > 0);
      if (lines.length > 0) {
        const historyStart = Math.max(0, lines.length - 500);
        const history = lines.slice(historyStart).join("\n");
        res.write(`data: ${JSON.stringify(history)}\n\n`);
        lastIndex = lines.length;
      }
    }

    const sendInterval = setInterval(() => {
      if (!fs.existsSync(LOG_FILE)) return;
      const content = fs.readFileSync(LOG_FILE, "utf8");
      const lines = content.split("\n").filter((l) => l.length > 0);
      if (lines.length > lastIndex) {
        const newLines = lines.slice(lastIndex).join("\n");
        res.write(`data: ${JSON.stringify(newLines)}\n\n`);
        lastIndex = lines.length;
      }
    }, 500);

    req.on("close", () => {
      clearInterval(sendInterval);
      console.log("[control] SSE client disconnected");
    });

    console.log("[control] SSE client connected");
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "Not found" }));
});

// ── WebSocket Upgrade ───────────────────────────────────────────────────────
// (only if ws is installed)

server.on("upgrade", (request, socket, head) => {
  try {
    const WebSocket = require("ws");
    const _wss = new WebSocket.Server({ noServer: true });
    _wss.handleUpgrade(request, socket, head, (ws) => {
      _wss.emit("connection", ws, request);
    });
  } catch (e) {
    socket.destroy();
  }
});

// ── Start ───────────────────────────────────────────────────────────────────

// Install ws if not present
try {
  require.resolve("ws");
} catch {
  console.log("[control] Installing ws package...");
  require("child_process").execSync("npm install ws", { cwd: "/workspaces/minecraft-server-template", stdio: "inherit" });
}

// Now that ws is available, set up WebSocket server
try {
  const WebSocket = require("ws");
  const _wss = new WebSocket.Server({ server });
  _wss.on("connection", (ws) => {
    console.log("[control] WebSocket client connected");
    consoleClients.add(ws);

    const recent = getLastLines(50);
    if (recent.length > 0) {
      ws.send(JSON.stringify({ type: "log", data: recent.join("\n") + "\n" }));
    }

    ws.on("message", (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "cmd" && msg.command) {
          sendToConsole(msg.command);
        }
      } catch {}
    });

    ws.on("close", () => {
      console.log("[control] WebSocket client disconnected");
      consoleClients.delete(ws);
    });
  });
} catch (e) {
  console.log("[control] WebSocket not available — running HTTP-only");
}

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[control] MineHost control server listening on :${PORT}`);
});

// ── Gist-based communication (replaces port forwarding) ─────────────────────

const GIST_ID = process.env.MINEHOST_GIST_ID;
const MINEHOST_TOKEN = process.env.MINEHOST_TOKEN;
let lastHandledCmd = null;

function restartMCServer() {
  const cmdFile = path.join(SCRIPT_DIR, ".mc_cmd");
  if (!fs.existsSync(cmdFile)) {
    console.error("[control] .mc_cmd not found — cannot restart");
    return;
  }
  const cmd = fs.readFileSync(cmdFile, "utf8").trim();
  sendToConsole("stop");

  let waited = 0;
  const check = setInterval(() => {
    waited += 2;
    if (!getServerRunning() || waited >= 30) {
      clearInterval(check);
      try { execSync("tmux kill-session -t mc 2>/dev/null || true", { stdio: "ignore" }); } catch {}
      setTimeout(() => {
        try {
          execSync(`cd ${JSON.stringify(SERVER_DIR)} && tmux new-session -d -s mc ${JSON.stringify(cmd)}`, {
            stdio: "ignore",
            shell: "/bin/bash",
          });
          console.log("[control] MC server restarted");
        } catch (e) {
          console.error("[control] Restart failed:", e.message);
        }
      }, 2000);
    }
  }, 2000);
}

function gistRequest(method, body, cb) {
  const https = require("https");
  const payload = body ? JSON.stringify(body) : null;
  // 10s timeout prevents hanging requests from accumulating in the event loop
  const req = https.request(
    {
      hostname: "api.github.com",
      path: `/gists/${GIST_ID}`,
      method,
      timeout: 10000,
      headers: {
        Authorization: `Bearer ${MINEHOST_TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "minehost-control-server/1.0",
        "Content-Type": "application/json",
        ...(payload ? { "Content-Length": Buffer.byteLength(payload) } : {}),
      },
    },
    (res) => {
      let data = "";
      res.on("data", (c) => (data += c));
      res.on("end", () => { try { cb && cb(JSON.parse(data)); } catch { cb && cb(null); } });
    }
  );
  req.on("error", () => cb && cb(null));
  req.on("timeout", () => { req.destroy(); cb && cb(null); });
  if (payload) req.write(payload);
  req.end();
}

// Single sync function: ONE GET + ONE PATCH per cycle.
// Previously two separate functions (pushGistState + pollPendingCmd) each doing a GET,
// totalling 3 API calls/3s = 60/min — too close to GitHub's 100/min secondary rate limit.
// Now: 2 calls/5s = 24/min from this process + ~12/min from frontend = 36/min total.
function syncGist() {
  if (!GIST_ID || !MINEHOST_TOKEN) return;
  const { lines: log, total: cursor } = getLastLinesWithTotal(500);
  const newState = {
    running: getServerRunning(),
    stage: null,
    log,
    cursor,
    pending_cmd: null,
    updated: Date.now(),
    server_ip: getServerIP(),
    playit_claim: getPlayitClaim(),
    config: getConfig(),
    ram: getRam(),
  };

  gistRequest("GET", null, (current) => {
    if (current?.files?.["state.json"]?.content) {
      try {
        const cur = JSON.parse(current.files["state.json"].content);
        // Handle pending command in the same cycle (no separate pollPendingCmd GET)
        const cmd = cur.pending_cmd;
        if (cmd && cmd !== lastHandledCmd) {
          lastHandledCmd = cmd;
          if (cmd === "__minehost_restart__") {
            restartMCServer();
          } else {
            sendToConsole(cmd);
          }
        }
        // Race fix: only clear pending_cmd if no NEW command arrived during processing.
        // If user sent a command between our GET and PATCH, preserve it for next cycle.
        const shouldClear = !cur.pending_cmd || cur.pending_cmd === lastHandledCmd;
        newState.pending_cmd = shouldClear ? null : cur.pending_cmd;
      } catch {}
    }
    gistRequest("PATCH", { files: { "state.json": { content: JSON.stringify(newState) } } }, null);
  });
}

if (GIST_ID && MINEHOST_TOKEN) {
  console.log(`[control] Gist sync enabled: ${GIST_ID}`);
  setInterval(syncGist, 5000);
} else {
  console.log("[control] No MINEHOST_GIST_ID/MINEHOST_TOKEN — gist sync disabled");
}
