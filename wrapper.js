#!/usr/bin/env node
const fs = require("fs");
const { spawn } = require("child_process");
const WebSocket = require("ws");

const LATEST_LOG = process.env.LATEST_LOG || "latest.log";
const FORCE_CONSOLE = process.env.CONSOLE_MODE === "1";

// Prepare log file
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFile(LATEST_LOG, "", (err) => { if (err) console.log("Log init error:", err); });

const args = process.argv.slice(2);
if (!args.length) {
  console.log("Error: Please specify a startup command.");
  process.exit(1);
}
const startupCmd = args.join(" ");
console.log("Starting Rust via wrapper…");

// Use bash if available so STARTUP strings with [[ ]] / == work
const preferredShell = fs.existsSync("/bin/bash") ? "/bin/bash" : "/bin/sh";

// Spawn the game process via the shell to preserve quoting
const gameProcess = spawn(startupCmd, {
  shell: preferredShell,
  stdio: ["pipe", "pipe", "pipe"],
});

// Deduplicate a noisy line pattern from Rust boot
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

gameProcess.stdout.on("data", filter);
gameProcess.stderr.on("data", filter);

let exited = false;
gameProcess.on("exit", (code) => {
  exited = true;
  console.log("Main game process exited with code", code);
  process.exit(code ?? 0);
});

// Graceful stop on container signals
["SIGINT", "SIGTERM"].forEach(sig => {
  process.on(sig, () => {
    if (!exited) {
      console.log(`Received ${sig}, stopping server...`);
      gameProcess.kill("SIGTERM");
    }
  });
});

// ---- Console mode: forward stdin directly to the game ----
function enableConsoleMode() {
  console.log("Console mode enabled (direct stdin/stdout, no RCON).");
  process.stdin.resume();
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (text) => {
    const cmd = String(text || "").replace(/\r?\n$/, "");
    if (cmd === "quit") {
      gameProcess.kill("SIGTERM");
      return;
    }
    // Forward command + newline to the game process
    try { gameProcess.stdin.write(cmd + "\n"); } catch {}
  });
}

// ---- RCON mode: stdin goes to WebRCON when connected ----
function enableRconMode() {
  const host = process.env.RCON_IP || "127.0.0.1";
  const port = process.env.RCON_PORT;
  const pass = process.env.RCON_PASS;

  if (!port || !pass) {
    console.log("RCON not fully configured; falling back to console mode.");
    enableConsoleMode();
    return;
  }

  console.log(`RCON mode enabled (ws://${host}:${port}/••••). Waiting for WebRCON…`);

  let waiting = true;
  let delay = 3000;
  const maxDelay = 15000;
  const jitter = () => Math.floor(Math.random() * 1000);
  const backoff = () => Math.min(delay = Math.floor(delay * 1.5), maxDelay) + jitter();

  const createPacket = (command) =>
    JSON.stringify({ Identifier: -1, Message: command, Name: "WebRcon" });

  // Buffer stdin until RCON is ready
  function initialListener(data) {
    const command = data.toString().trim();
    if (command === "quit") {
      gameProcess.kill("SIGTERM");
    } else {
      console.log(`Console not ready yet, queued: "${command}"`);
    }
  }
  process.stdin.resume();
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", initialListener);

  (function poll() {
    const ws = new WebSocket(`ws://${host}:${port}/${pass}`);

    ws.on("open", () => {
      waiting = false;
      console.log("Connected to WebRCON.");

      // Kick status to unstick console output
      ws.send(createPacket("status"));

      // Rewire stdin to send commands over RCON
      process.stdin.removeListener("data", initialListener);
      process.stdin.on("data", (text) => {
        const cmd = String(text || "").trim();
        if (cmd === "quit") {
          gameProcess.kill("SIGTERM");
        } else if (cmd.length) {
          ws.send(createPacket(cmd));
        }
      });
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
      console.log("Waiting for WebRCON…");
      setTimeout(poll, backoff());
    });

    ws.on("close", () => {
      if (!waiting) {
        console.log("WebRCON connection closed. Exiting.");
        process.exit(0);
      }
    });
  })();
}

// Choose mode
if (FORCE_CONSOLE) {
  enableConsoleMode();
} else {
  enableRconMode();
}
