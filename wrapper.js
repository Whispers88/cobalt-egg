#!/usr/bin/env node

// ============================================================================
// Rust wrapper -- Console-first (NO RCON), argv-safe + logfile mirroring
// - Receives argv for RustDedicated via --argv <args...>
// - Spawns RustDedicated WITHOUT a shell (preserves multi-word args)
// - Mirrors stdout/stderr to panel, writes raw to latest.log
// - If -logfile is present, tails it and mirrors to panel too
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";

// rotate previous log
try { if (fs.existsSync(LATEST_LOG)) fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`); } catch {}
fs.writeFileSync(LATEST_LOG, "", { flag: "w" });

const argv = process.argv.slice(2);

// Expect "--argv" followed by the full RustDedicated argv
const flagIndex = argv.indexOf("--argv");
if (flagIndex === -1) {
  console.error("[wrapper] ERROR: Missing --argv marker.");
  process.exit(1);
}

const gameArgs = argv.slice(flagIndex + 1);
if (gameArgs.length === 0) {
  console.error("[wrapper] ERROR: No arguments provided for RustDedicated.");
  process.exit(1);
}

const executable = gameArgs[0];
const params = gameArgs.slice(1);

console.log(`[wrapper] Executing: ${executable} ${params.map(a => (/[^A-Za-z0-9_/.:-]/.test(a) ? `"${a}"` : a)).join(" ")}`);

// Detect -logfile path (next token is the path)
let unityLogfile = null;
for (let i = 0; i < params.length; i++) {
  if (params[i] === "-logfile" && i + 1 < params.length) {
    unityLogfile = params[i + 1];
    break;
  }
}

// Spawn WITHOUT shell: exact argv preserved
const game = spawn(executable, params, {
  stdio: ["pipe", "pipe", "pipe"],
  cwd: "/home/container",
});

function mirror(chunk, isErr = false) {
  const s = chunk.toString();
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