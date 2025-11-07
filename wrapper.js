#!/usr/bin/env node

// Console-first wrapper with timestamps and logfile mirroring.
// - Runs the full startup string under /bin/bash (no splitting).
// - Adds timestamps to panel output only; writes raw to latest.log.
// - If -logfile is present, tails it and mirrors to the panel.

const { spawn } = require("child_process");
const fs = require("fs");

const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";

// rotate previous log
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFileSync(LATEST_LOG, "", { flag: "w" });

function ts() {
  const d = new Date();
  return `[${d.toISOString().split("T")[1].split(".")[0]}]`; // HH:MM:SS
}

const args = process.argv.slice(2);
if (!args.length) {
  console.error("[wrapper] ERROR: No startup command provided.");
  process.exit(1);
}
const startupCmd = args.join(" ");

// detect -logfile path (quoted or unquoted)
function extractLogfile(cmd) {
  const m = cmd.match(/-logfile\s+("([^"]+)"|(\S+))/);
  if (!m) return null;
  return m[2] || m[3] || null;
}
const unityLogfile = extractLogfile(startupCmd);

console.log(`${ts()} [wrapper] Starting with shell: ${startupCmd}`);

const preferredShell = fs.existsSync("/bin/bash") ? "/bin/bash" : "/bin/sh";
const game = spawn(startupCmd, {
  shell: preferredShell,               // <— IMPORTANT: run the string as-is
  stdio: ["pipe", "pipe", "pipe"],
  cwd: "/home/container",
});

function mirrorToPanelAndFile(chunk, isErr = false) {
  const raw = chunk.toString();
  const withTs = `${ts()} ${raw}`;
  (isErr ? process.stderr : process.stdout).write(withTs);
  fs.appendFile(LATEST_LOG, raw, () => {});
}

game.stdout.on("data", (d) => mirrorToPanelAndFile(d, false));
game.stderr.on("data", (d) => mirrorToPanelAndFile(d, true));

// If the game writes to a logfile, also tail it so the panel sees it.
let tailProc = null;
if (unityLogfile) {
  try { fs.closeSync(fs.openSync(unityLogfile, "a")); } catch {}
  console.log(`${ts()} [wrapper] Mirroring -logfile: ${unityLogfile}`);
  tailProc = spawn("tail", ["-n", "+1", "-F", unityLogfile], { stdio: ["ignore", "pipe", "pipe"] });
  const tailMirror = (d) => mirrorToPanelAndFile(d, false);
  tailProc.stdout.on("data", tailMirror);
  tailProc.stderr.on("data", tailMirror);
  tailProc.on("exit", (c) => console.log(`${ts()} [wrapper] tail exited (${c}).`));
}

// forward panel input → game stdin
process.stdin.setEncoding("utf8");
process.stdin.on("data", (txt) => { try { game.stdin.write(txt); } catch {} });
process.stdin.resume();

let exited = false;
["SIGTERM", "SIGINT"].forEach(sig => {
  process.on(sig, () => {
    if (!exited) {
      console.log(`${ts()} [wrapper] ${sig} → stopping server...`);
      try { game.stdin.write("quit\n"); } catch {}
      setTimeout(() => { try { game.kill("TERM"); } catch {} }, 5000);
    }
  });
});

game.on("exit", (code) => {
  exited = true;
  if (tailProc && !tailProc.killed) { try { tailProc.kill("TERM"); } catch {} }
  console.log(`${ts()} [wrapper] Rust exited with code: ${code}`);
  process.exit(code ?? 0);
});
