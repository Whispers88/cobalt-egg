#!/usr/bin/env node
const fs = require("fs");
const { spawn } = require("child_process");

const LATEST_LOG = process.env.LATEST_LOG || "latest.log";

// rotate wrapper log
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFileSync(LATEST_LOG, "", { flag: "w" });

const args = process.argv.slice(2);
if (!args.length) {
  console.log("Error: Please provide the startup command as arguments.");
  process.exit(1);
}
const startupCmd = args.join(" ");
console.log("Starting Rust via wrapper (Unity console)…");

// Prefer bash so [[ ]] / == / $() in the Start Command work
const preferredShell = fs.existsSync("/bin/bash") ? "/bin/bash" : "/bin/sh";

// Detect -logfile path in the startup command
function extractLogfile(cmd) {
  // matches: -logfile /path OR -logfile "/path with spaces"
  const m = cmd.match(/-logfile\s+("([^"]+)"|(\S+))/);
  if (!m) return null;
  return m[2] || m[3] || null;
}
const unityLogfile = extractLogfile(startupCmd);

// Spawn the game (no PTY). If your game only prints with a TTY, we can wrap with `script`.
const game = spawn(startupCmd, {
  shell: preferredShell,
  stdio: ["pipe", "pipe", "pipe"],
});

// Mirror game stdout/stderr to panel + wrapper log (works when no -logfile)
function mirror(data) {
  const s = data.toString();
  process.stdout.write(s);
  fs.appendFile(LATEST_LOG, s.replace(/\r/g, ""), () => {});
}
game.stdout.on("data", mirror);
game.stderr.on("data", mirror);

// If -logfile is set, tail it and mirror into the panel too
let tailProc = null;
if (unityLogfile) {
  // Ensure the file exists so tail -F starts cleanly
  try { fs.closeSync(fs.openSync(unityLogfile, "a")); } catch {}
  console.log(`[wrapper] Detected -logfile: ${unityLogfile} — mirroring to console.`);
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], { stdio: ["ignore", "pipe", "pipe"] });
  const tailMirror = (data) => {
    const s = data.toString();
    process.stdout.write(s);
    fs.appendFile(LATEST_LOG, s.replace(/\r/g, ""), () => {});
  };
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
  tailProc.on("exit", (c) => console.log(`[wrapper] tail exited (${c}).`));
}

// Forward panel input directly to the Unity console
process.stdin.setEncoding("utf8");
process.stdin.on("data", (text) => {
  const cmd = String(text || "").replace(/\r?\n$/, "") + "\n";
  try { game.stdin.write(cmd); } catch {}
});
process.stdin.resume();

// Graceful shutdown
let exited = false;
["SIGINT", "SIGTERM"].forEach(sig => {
  process.on(sig, () => {
    if (!exited) {
      console.log(`Received ${sig}, asking server to quit...`);
      try { game.stdin.write("quit\n"); } catch {}
      setTimeout(() => { try { game.kill("SIGTERM"); } catch {} }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  if (tailProc && !tailProc.killed) { try { tailProc.kill("TERM"); } catch {} }
  console.log("Main game process exited with code", code);
  process.exit(code ?? 0);
});
