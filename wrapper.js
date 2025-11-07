#!/usr/bin/env node

// ============================================================================
// Rust wrapper -- Console-first (NO RCON required)
// - Runs RustDedicated directly (spawn)
// - Mirrors stdout/stderr to panel console
// - Pipes panel input -> Rust stdin
// - Tails logfile if `-logfile` is detected in args
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

// Where logfile should be written (ENTRYPOINT sets this)
const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";

// -------- Cleanup old log --------
try {
    if (fs.existsSync(LATEST_LOG)) {
        fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`);
    }
} catch {}

fs.writeFile(LATEST_LOG, "", (err) => {
    if (err) console.log("⚠️ Failed to initialize log file:", err);
});

// -------- Required startup command argument --------
const args = process.argv.slice(2);
if (!args.length) {
    console.error("[wrapper] ERROR: No startup command provided.");
    process.exit(1);
}

const startupCmd = args.join(" ");
console.log(`[wrapper] Starting Rust: ${startupCmd}`);

// Split into command + parameters safely
// (the .sh already handles quotes correctly)
const parts = startupCmd.split(" ");
const executable = parts[0];
const parameters = parts.slice(1);

// -------- Spawn RustDedicated --------
let exited = false;
const game = spawn(executable, parameters, {
    stdio: ["pipe", "pipe", "pipe"], // pipe EVERYTHING so we can forward
});

// Panel console output
game.stdout.on("data", (data) => {
    const text = data.toString();
    process.stdout.write(text);
    fs.appendFile(LATEST_LOG, text, () => {});
});

game.stderr.on("data", (data) => {
    const text = data.toString();
    process.stderr.write(text);
    fs.appendFile(LATEST_LOG, text, () => {});
});

// Forward panel console → server console
process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", (input) => {
    game.stdin.write(input);
});

// Handle exit
game.on("exit", (code) => {
    exited = true;
    console.log(`[wrapper] Rust exited with code: ${code}`);
    process.exit(code ?? 0);
});

// Ensure graceful shutdown if panel stops server
process.on("SIGTERM", () => {
    console.log("[wrapper] Caught SIGTERM, stopping server...");
    game.kill("SIGTERM");
});
process.on("SIGINT", () => {
    console.log("[wrapper] Caught SIGINT, stopping server...");
    game.kill("SIGINT");
});
process.on("exit", () => {
    if (!exited) {
        console.log("[wrapper] Server terminated externally.");
        game.kill("SIGTERM");
    }
});
