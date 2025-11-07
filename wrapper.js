#!/usr/bin/env node

// ============================================================================
// Rust wrapper -- Console-first (NO RCON), with logfile mirroring
// - Runs the full startup string under /bin/bash (no splitting)
// - Mirrors stdout/stderr to panel console
// - Writes raw logs to latest.log
// - If -logfile is present, tails it and mirrors to the panel too
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";

// rotate previous log
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFileSync(LATEST_LOG, "", { flag: "w" });

// Require startup command
const args = process.argv.slice(2);
if (!args.length) {
  console.error("[wrapper] ERROR: No startup command provided.");
  process.exit(1);
}
const startupCmd = args.join(" ");
console.log(`[wrapper] Starting Rust: ${startupCmd}`);

// Detect -logfile (quoted or unquoted)
function extractLogfile(cmd) {
  const m = cmd.match(/-logfile\s+("([^"]+)"|(\S+))/);
  if (!m) return null;
  return m[2] || m[3] || null;
}
const unityLogfile = extractLogfile(startupCmd);

// Prefer bash for [[ ]], ==, $(), etc.
const preferredShell = fs.existsSync("/bin/bash") ? "/bin/bash" : "/bin/sh";

// Spawn the game under a shell so we keep the exact command string
const game = spawn(startupCmd, {
  shell: preferredShell,
  stdio: ["pipe", "pipe", "pipe"],
  cwd: "/home/container",
});

// Mirror game stdout/stderr to panel + wrapper log (raw)
function mirror(data, isErr = false) {
  const s = data.toString();
  (isErr ? process.stderr : process.stdout).write(s);
  fs.appendFile(LATEST_LOG, s.replace(/\r/g, ""), () => {});
}
game.stdout.on("data", (d) => mirror(d, false));
game.stderr.on("data", (d) => mirror(d, true));

// If -logfile is set, tail it and mirror to the panel too
let tailProc = null;
if (unityLogfile) {
  try { fs.closeSync(fs.openSync(unityLogfile, "a")); } catch {}
  console.log(`[wrapper] Mirroring -logfile: ${unityLogfile}`);
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], { stdio: ["ignore", "pipe", "pipe"] });
  const tailMirror = (d) => mirror(d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
  tailProc.on("exit", (c) => console.log(`[wrapper] tail exited (${c}).`));
}

// Forward panel input → server stdin
process.stdin.setEncoding("utf8");
process.stdin.on("data", (txt) => {
  try { game.stdin.write(txt); } catch {}
});
process.stdin.resume();

// Graceful shutdown
let exited = false;
["SIGTERM", "SIGINT"].forEach(sig => {
  process.on(sig, () => {
    if (!exited) {
      console.log(`[wrapper] ${sig} → stopping server...`);
      try { game.stdin.write("quit\n"); } catch {}
      setTimeout(() => { try { game.kill("TERM"); } catch {} }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  if (tailProc && !tailProc.killed) { try { tailProc.kill("TERM"); } catch {} }
  console.log(`[wrapper] Rust exited with code: ${code}`);
  process.exit(code ?? 0);
});
