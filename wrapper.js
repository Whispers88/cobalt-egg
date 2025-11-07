#!/usr/bin/env node
const fs = require("fs");
const { spawn } = require("child_process");

// --- config ---
const LATEST_LOG = process.env.LATEST_LOG || "latest.log";

// rotate log
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFileSync(LATEST_LOG, "", { flag: "w" });

// reconstruct the Start Command exactly as panel passed it to entrypoint
const args = process.argv.slice(2);
if (!args.length) {
  console.log("Error: Please provide the startup command as arguments.");
  process.exit(1);
}
const startupCmd = args.join(" ");
console.log("Starting Rust via wrapper (Unity console)…");

// Prefer bash so [[ ]] / == / $() work in the panel command
const preferredShell = fs.existsSync("/bin/bash") ? "/bin/bash" : "/bin/sh";

// Spawn the game via shell to preserve complex quoting
const game = spawn(startupCmd, {
  shell: preferredShell,
  stdio: ["pipe", "pipe", "pipe"],
});

// Deduplicate noisy boot lines (optional)
const seenPercentage = {};
function filterAndMirror(data) {
  const str = data.toString();
  if (str.startsWith("Loading Prefab Bundle ")) {
    const pct = str.slice("Loading Prefab Bundle ".length);
    if (seenPercentage[pct]) return;
    seenPercentage[pct] = true;
  }
  // send to panel
  process.stdout.write(str);
  // append to log
  fs.appendFile(LATEST_LOG, str.replace(/\r/g, ""), () => {});
}
game.stdout.on("data", filterAndMirror);
game.stderr.on("data", filterAndMirror);

// Forward stdin directly to Unity console
process.stdin.setEncoding("utf8");
process.stdin.on("data", (text) => {
  // Normalize input and always add newline
  const cmd = String(text || "").replace(/\r?\n$/, "") + "\n";
  try { game.stdin.write(cmd); } catch {}
});
process.stdin.resume();

// Graceful stop propagation
let exited = false;
["SIGINT", "SIGTERM"].forEach(sig => {
  process.on(sig, () => {
    if (!exited) {
      console.log(`Received ${sig}, stopping server...`);
      try { game.stdin.write("quit\n"); } catch {}
      // if it doesn't exit quickly, fall back to SIGTERM
      setTimeout(() => { try { game.kill("SIGTERM"); } catch {} }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  console.log("Main game process exited with code", code);
  process.exit(code ?? 0);
});
