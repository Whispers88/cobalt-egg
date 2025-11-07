#!/usr/bin/env node

// ============================================================================
// Rust wrapper -- Console-first (NO RCON required), with TIMESTAMPS
// - Runs RustDedicated directly (spawn)
// - Adds timestamps to all console output
// - Writes raw logs (untouched) to latest.log
// - Accepts input from panel -> game stdin
// ============================================================================

const { spawn } = require("child_process");
const fs = require("fs");

const LATEST_LOG = process.env.LATEST_LOG || "/home/container/latest.log";

// Rotate previous run
try {
    if (fs.existsSync(LATEST_LOG)) {
        fs.renameSync(LATEST_LOG, `${LATEST_LOG}.prev`);
    }
} catch {}

fs.writeFileSync(LATEST_LOG, "", { flag: "w" });

// ----------------------------------------------------------------------------
// Timestamp formatter
// ----------------------------------------------------------------------------
function timestamp() {
    const d = new Date();
    return `[${d.toISOString().split("T")[1].split(".")[0]}]`; // HH:MM:SS
}

// ----------------------------------------------------------------------------
// Validate we got a startup command
// ----------------------------------------------------------------------------
const args = process.argv.slice(2);
if (!args.length) {
    console.error("[wrapper] ERROR: No startup command provided.");
    process.exit(1);
}

const startupCmd = args.join(" ");
console.log(`${timestamp()} [wrapper] Starting Rust: ${startupCmd}`);

// Split into command + parameters safely (entrypoint does quoting for us)
const parts = startupCmd.split(" ");
const executable = parts[0];
const parameters = parts.slice(1);

// ----------------------------------------------------------------------------
// Spawn Rust process
// ----------------------------------------------------------------------------
let exited = false;

const game = spawn(executable, parameters, {
    stdio: ["pipe", "pipe", "pipe"],
});

// ----------------------------------------------------------------------------
// OUTPUT MIRRORING (with timestamps on panel, raw into log file)
// ----------------------------------------------------------------------------
function handleData(data, isError = false) {
    const raw = data.toString();
    const line = `${timestamp()} ${raw}`; // timestamp version for console only

    // Print to panel
    if (isError) {
        process.stderr.write(line);
    } else {
        process.stdout.write(line);
    }

    // Write raw (no timestamp) to disk
    fs.appendFile(LATEST_LOG, raw, () => {});
}

game.stdout.on("data", (data) => handleData(data, false));
game.stderr.on("data", (data) => handleData(data, true));

// ----------------------------------------------------------------------------
// Forward console input -> server stdin
// ----------------------------------------------------------------------------
process.stdin.resume();
process.stdin.setEncoding("utf8");
process.stdin.on("data", (input) => {
    game.stdin.write(input);
});

// ----------------------------------------------------------------------------
// Shutdown handling
// ----------------------------------------------------------------------------
game.on("exit", (code) => {
    exited = true;
    console.log(`${timestamp()} [wrapper] Rust exited with code: ${code}`);
    process.exit(code ?? 0);
});

process.on("SIGTERM", () => {
    console.log(`${timestamp()} [wrapper] SIGTERM -> stopping server...`);
    game.kill("SIGTERM");
});

process.on("SIGINT", () => {
    console.log(`${timestamp()} [wrapper] SIGINT -> stopping server...`);
    game.kill("SIGINT");
});

process.on("exit", () => {
    if (!exited) {
        console.log(`${timestamp()} [wrapper] Wrapper exit -> stopping server.`);
        game.kill("SIGTERM");
    }
});
