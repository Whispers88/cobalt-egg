#!/usr/bin/env node
const fs = require("fs");
const { spawn } = require("child_process");
const WebSocket = require("ws");

const LATEST_LOG = process.env.LATEST_LOG || "latest.log";

try {
  if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`);
} catch {}
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
    const percentage = str.substr("Loading Prefab Bundle ".length);
    if (seenPercentage[percentage]) return;
    seenPercentage[percentage] = true;
  }
  process.stdout.write(str);
}

let exited = false;

// Safer than exec (no 1MB buffer limit)
const parts = startupCmd.split(" ");
const gameProcess = spawn(parts[0], parts.slice(1), { stdio: ["pipe", "pipe", "pipe"] });
gameProcess.stdout.on("data", filter);
gameProcess.stderr.on("data", filter);
gameProcess.on("exit", (code) => {
  exited = true;
  console.log("Main game process exited with code", code);
  process.exit(code ?? 0);
});

function initialListener(data) {
  const command = data.toString().trim();
  if (command === "quit") {
    gameProcess.kill("SIGTERM");
  } else {
    console.log(`Unable to run "${command}" due to RCON not being connected yet.`);
  }
}
process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", initialListener);

process.on("exit", () => {
  if (exited) return;
  console.log("Received request to stop the process, stopping the game...");
  gameProcess.kill("SIGTERM");
});

// WebRCON bridge with backoff
let waiting = true;
let delay = 3000;
const maxDelay = 15000;
const jitter = () => Math.floor(Math.random() * 1000);
const backoff = () => { delay = Math.min(Math.floor(delay * 1.5), maxDelay); return delay + jitter(); };

function createPacket(command) {
  return JSON.stringify({ Identifier: -1, Message: command, Name: "WebRcon" });
}

function poll() {
  const serverHostname = process.env.RCON_IP ? process.env.RCON_IP : "127.0.0.1";
  const serverPort = process.env.RCON_PORT;
  const serverPassword = process.env.RCON_PASS;

  const ws = new WebSocket(`ws://${serverHostname}:${serverPort}/${serverPassword}`);

  ws.on("open", () => {
    console.log('Connected to RCON. Generating the map now. Please wait until the server status switches to "Running".');
    waiting = false;

    // Hack to fix broken console output
    ws.send(createPacket("status"));

    process.stdin.removeListener("data", initialListener);
    gameProcess.stdout.removeListener("data", filter);
    gameProcess.stderr.removeListener("data", filter);

    process.stdin.on("data", (text) => ws.send(createPacket(text)));
  });

  ws.on("message", (data) => {
    try {
      const json = JSON.parse(data);
      if (json && json.Message) {
        console.log(json.Message);
        fs.appendFile(LATEST_LOG, "\n" + json.Message, () => {});
      }
    } catch (e) {
      console.log("RCON JSON parse error:", e);
    }
  });

  ws.on("error", () => {
    waiting = true;
    console.log("Waiting for RCON to come up...");
    setTimeout(poll, backoff());
  });

  ws.on("close", () => {
    if (!waiting) {
      console.log("Connection to server closed.");
      exited = true;
      process.exit(0);
    }
  });
}
poll();
