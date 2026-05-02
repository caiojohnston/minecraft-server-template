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

// ── Utility functions ───────────────────────────────────────────────────────

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
  const lines = content.split("\n").filter((l) => l.length > 0);
  return lines.slice(-n);
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

// ── WebSocket ───────────────────────────────────────────────────────────────

const wss = { upgrade: null, on: null }; // Will be initialized after ws is installed
let consoleClients = new Set();

// Periodically poll for new console output and broadcast
let lastLogLineCount = 0;

function checkNewOutput() {
  if (!fs.existsSync(LOG_FILE)) return;
  const content = fs.readFileSync(LOG_FILE, "utf8");
  const lines = content.split("\n").filter((l) => l.length > 0);
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
