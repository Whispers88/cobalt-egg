#!/usr/bin/env node
const fs = require("fs");
const { spawn } = require("child_process");
const WebSocket = require("ws");

const LATEST_LOG = process.env.LATEST_LOG || "latest.log";

try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFile(LATEST_LOG, "", (err) => { if (err) console.log("Log init error:", err); });

const args = process.argv.slice(2);
if (!args.length) {
  console.log("Error: Please specify a startup command.");
  process.exit(1);
}
const startupCmd = args.join(" ");
console.log("Starting Rust via wrapper…");

const seenPercentage = {};
function filter(data) {
  const str = data.toString();
  if (str.startsWith("Loading Prefab Bundle ")) {
    const percentage = str.slice("Loading Prefab Bundle ".length);
    if (seenPercentage[percentage]) return;
    seenPercentage[percentage] = true;
  }
  process.stdout.write(str);
}

// ---- IMPORTANT CHANGE: run under bash if available ----
const preferredShell = fs.existsSync("/bin/bash") ? "/bin/bash" : "/bin/sh";
// Use -lc so env/aliases are loaded and the whole string runs as one command
const gameProcess = spawn(startupCmd, {
  shell: preferredShell,
  stdio: ["pipe", "pipe", "pipe"]
});

gameProcess.stdout.on("data", filter);
gameProcess.stderr.on("data", filter);

gameProcess.on("exit", (code) => {
  console.log("Main game process exited with code", code);
  process.exit(code ?? 0);
});

// Buffer console until RCON is ready
function initialListener(data) {
  const command = data.toString().trim();
  console.log(`Console not ready yet, ignored: "${command}"`);
}
process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", initialListener);

// Forward stop signals
["SIGINT", "SIGTERM"].forEach(sig => {
  process.on(sig, () => {
    console.log(`Received ${sig}, stopping server...`);
    gameProcess.kill("SIGTERM");
  });
});

// WebRCON backoff loop
let waiting = true;
let delay = 3000;
const maxDelay = 15000;
const jitter = () => Math.floor(Math.random() * 1000);
const backoff = () => Math.min(delay = Math.floor(delay * 1.5), maxDelay) + jitter();

const createPacket = (command) => JSON.stringify({ Identifier: -1, Message: command, Name: "WebRcon" });

(function poll() {
  const host = process.env.RCON_IP || "127.0.0.1";
  const port = process.env.RCON_PORT;
  const pass = process.env.RCON_PASS;

  const ws = new WebSocket(`ws://${host}:${port}/${pass}`);

  ws.on("open", () => {
    waiting = false;
    console.log("Connected to WebRCON.");
    ws.send(createPacket("status"));

    process.stdin.removeListener("data", initialListener);
    process.stdin.on("data", (text) => ws.send(createPacket(text.toString().trim())));
  });

  ws.on("message", (data) => {
    try {
      const msg = JSON.parse(data);
      if (msg?.Message) {
        console.log(msg.Message);
        fs.appendFile(LATEST_LOG, msg.Message + "\n", () => {});
      }
    } catch (e) {
      console.log("RCON JSON error:", e);
    }
  });

  ws.on("error", () => {
    waiting = true;
    console.log("Waiting for RCON…");
    setTimeout(poll, backoff());
  });

  ws.on("close", () => {
    if (!waiting) {
      console.log("Server closed.");
      process.exit(0);
    }
  });
})();
