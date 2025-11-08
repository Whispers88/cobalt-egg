#!/bin/bash
set -euo pipefail

# =======================================================================
# Rust Dedicated Server entrypoint for Pterodactyl (argv-safe)
# - Optional framework install/update + Steam validate
# - Crash auto-restart (if WATCH_ENABLED=1)
# - CPU-only stall watch: no /proc ticks for HEARTBEAT_TIMEOUT_SEC => restart
# - RCON shutdown commands + local shell shutdown commands (single timeout)
# =======================================================================

export HOME=/home/container
cd /home/container || exit 1

log() { echo -e "[entrypoint] $*"; }
err() { echo -e "[entrypoint][error] $*" >&2; }

# niceties
ulimit -n 65535 || true
umask 002
chown -R "$(id -u):$(id -g)" /home/container 2>/dev/null || true

# -----------------------------------------------------------------------
# SteamCMD layout
# -----------------------------------------------------------------------
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64

export STEAMCMDDIR=/home/container/steamcmd

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  echo ""
}

# -----------------------------------------------------------------------
# Config from panel
# -----------------------------------------------------------------------
SRCDS_APPID="${SRCDS_APPID:-258550}"

STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"
VALIDATE="${VALIDATE:-1}"

EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

# Map framework to default Steam branch (explicit STEAM_BRANCH overrides)
DEFAULT_STEAM_BRANCH=""
case "${FRAMEWORK}" in
  vanilla-staging|oxide-staging|carbon-staging* ) DEFAULT_STEAM_BRANCH="staging" ;;
  vanilla-aux1|carbon-aux1* )                     DEFAULT_STEAM_BRANCH="aux1" ;;
  vanilla-aux2|carbon-aux2* )                     DEFAULT_STEAM_BRANCH="aux2" ;;
  * )                                             DEFAULT_STEAM_BRANCH="" ;;
esac

# Custom framework artifact URL
CUSTOM_FRAMEWORK_URL="${CUSTOM_FRAMEWORK_URL:-${CustomFrameworkURL:-}}"

# Wrapper log destination
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# ---- Simplified resiliency knobs ----
WATCH_ENABLED="${WATCH_ENABLED:-1}"
HEARTBEAT_TIMEOUT_SEC="${HEARTBEAT_TIMEOUT_SEC:-120}"

# Fixed internals (not user-facing)
CHECK_EVERY_SEC=10
STALL_TERM_GRACE_SEC=20
RESTART_BACKOFF_SEC=5

# Shutdown hooks (single timeout for both RCON and shell cmds)
SHUTDOWN_CMDS="${SHUTDOWN_CMDS:-}"
SHUTDOWN_RCON_CMDS="${SHUTDOWN_RCON_CMDS:-}"
SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-30}"
RCON_HOST="${RCON_HOST:-127.0.0.1}"

# optional convenience IP
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# -----------------------------------------------------------------------
# Update / validate helpers
# -----------------------------------------------------------------------
do_validate() {
  [[ "${VALIDATE}" != "1" ]] && { log "VALIDATE=0 → skipping SteamCMD validation."; return 0; }

  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { err "steamcmd not found"; exit 11; }

  local RESOLVED_BRANCH="${STEAM_BRANCH:-${DEFAULT_STEAM_BRANCH}}"
  local BRANCH_FLAGS=""
  [[ -n "$RESOLVED_BRANCH" ]] && BRANCH_FLAGS="-beta ${RESOLVED_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"

  log "Validating game files via SteamCMD… (branch: ${RESOLVED_BRANCH:-default})"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
  log "[  OK  ] validation complete"
}

install_oxide() {
  log "Installing / updating Oxide (uMod)…"
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o -q oxide.zip -d /home/container
  popd >/dev/null
  rm -rf "$tmp"
  log "uMod install complete."
}

install_carbon() {
  log "Installing / updating Carbon…"
  local channel="production" minimal="0" url=""
  case "${FRAMEWORK}" in
    carbon-edge* )    channel="edge" ;;
    carbon-staging* ) channel="staging" ;;
    carbon-aux1* )    channel="aux1" ;;
    carbon-aux2* )    channel="aux2" ;;
    carbon* )         channel="production" ;;
  esac
  [[ "${FRAMEWORK}" == *"-minimal" ]] && minimal="1"

  if [[ "$minimal" == "1" ]]; then
    case "${channel}" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.Minimal.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.Minimal.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.Minimal.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.Minimal.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.Minimal.tar.gz" ;;
    esac
  else
    case "${channel}" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.tar.gz" ;;
    esac
  fi

  [[ -z "${url}" ]] && { err "Could not determine Carbon artifact for FRAMEWORK='${FRAMEWORK}'"; exit 10; }

  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o carbon.tar.gz "${url}"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmp"
  log "Carbon install complete."
}

install_from_custom_url() {
  local url="$1"
  [[ -z "$url" ]] && { err "Custom framework URL is empty."; return 1; }
  log "Installing / updating from Custom Framework URL: ${url}"
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  case "$url" in
    *.zip)                         curl -fSL --retry 5 -o artifact.zip "$url"; unzip -o -q artifact.zip -d /home/container ;;
    *.tar.gz|*.tgz|*.tar|*.tar.xz) curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
    *)                             curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
  esac
  popd >/dev/null
  rm -rf "$tmp"
  log "Custom framework install complete."
}

# -----------------------------------------------------------------------
# Framework actions (guarded by FRAMEWORK_UPDATE)
# -----------------------------------------------------------------------
if [[ "${FRAMEWORK_UPDATE}" == "1" ]]; then
  do_validate
  if [[ -n "${CUSTOM_FRAMEWORK_URL}" ]]; then
    log "FRAMEWORK_UPDATE=1 and CustomFrameworkURL detected → using custom artifact (overrides FRAMEWORK='${FRAMEWORK}')."
    install_from_custom_url "${CUSTOM_FRAMEWORK_URL}"
  else
    case "${FRAMEWORK}" in
      oxide|uMod) install_oxide ;;
      carbon*   ) install_carbon ;;
      *)          log "FRAMEWORK='${FRAMEWORK}' → vanilla channel or other; no framework to install." ;;
    esac
  fi
else
  log "FRAMEWORK_UPDATE=0 → skipping framework install/update steps."
  do_validate
fi

# -----------------------------------------------------------------------
# Build argv to pass to wrapper (NO STRING JOINING)
# -----------------------------------------------------------------------
if [[ "$#" -gt 0 ]]; then
  ARGV=( "$@" )
else
  if [[ -z "${STARTUP:-}" ]]; then
    err "No startup provided: neither Start Command args nor STARTUP env found."
    exit 12
  fi
  EXPANDED="$(
    eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
  )"
  eval "set -- ${EXPANDED}"
  ARGV=( "$@" )
fi

# strip accidental /entrypoint.sh
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then
  ARGV=( "${ARGV[@]:1}" )
fi

# ensure Rust binary exists
if [[ ! -f "./RustDedicated" ]]; then
  err "RustDedicated not found in $(pwd). Did app_update install to /home/container?"
  err "Set VALIDATE=1 (or enable AUTO_UPDATE in your egg) and try again."
  exit 13
fi
[[ -x "./RustDedicated" ]] || chmod +x ./RustDedicated || true

# pick wrapper path
WRAPPER="/wrapper.js"
[[ -f "$WRAPPER" ]] || WRAPPER="/opt/cobalt/wrapper.js"
if [[ ! -f "$WRAPPER" ]]; then
  err "wrapper.js not found at /wrapper.js or /opt/cobalt/wrapper.js"
  exit 14
fi

# -----------------------------------------------------------------------
# CPU-only stall helper
# -----------------------------------------------------------------------
proc_ticks() {
  local pid="$1"
  [[ -r "/proc/${pid}/stat" ]] || { echo 0; return; }
  awk '{print $14+$15}' "/proc/${pid}/stat" 2>/dev/null || echo 0
}

cpu_stall_watch() {
  local pid="$1"
  local last_ticks cur_ticks last_ts now_ts idle
  last_ticks="$(proc_ticks "${pid}")"
  last_ts="$(date +%s)"

  echo "[watch] cpu-only: pid ${pid}, heartbeat=${HEARTBEAT_TIMEOUT_SEC}s, interval=${CHECK_EVERY_SEC}s"
  trap 'exit 0' TERM INT

  while kill -0 "${pid}" 2>/dev/null; do
    sleep "${CHECK_EVERY_SEC}"
    cur_ticks="$(proc_ticks "${pid}")"

    if [[ "${cur_ticks}" != "${last_ticks}" && "${cur_ticks}" != "0" ]]; then
      last_ticks="${cur_ticks}"
      last_ts="$(date +%s)"
      continue
    fi

    now_ts="$(date +%s)"
    idle=$(( now_ts - last_ts ))
    if (( idle >= HEARTBEAT_TIMEOUT_SEC )); then
      echo "[watch][error] stall: no CPU progress for ${idle}s (>= ${HEARTBEAT_TIMEOUT_SEC}s). TERM pid ${pid}"
      kill -TERM "${pid}" 2>/dev/null || true

      for (( i=0; i<STALL_TERM_GRACE_SEC; i++ )); do
        sleep 1
        kill -0 "${pid}" 2>/dev/null || { echo "[watch] process exited after TERM"; exit 0; }
      done

      echo "[watch][error] still running → KILL pid ${pid}"
      kill -KILL "${pid}" 2>/dev/null || true
      exit 0
    fi
  done

  echo "[watch] target ended; exiting stall watcher"
  exit 0
}

# -----------------------------------------------------------------------
# RCON helper (inline Node, Source RCON TCP) for shutdown
# -----------------------------------------------------------------------
send_rcon_cmds() {
  local cmds_csv="$1"
  [[ -z "${cmds_csv// }" ]] && return 0
  [[ -z "${RCON_PORT:-}" || -z "${RCON_PASS:-}" ]] && { err "RCON not configured (RCON_PORT/RCON_PASS). Skipping RCON shutdown cmds."; return 1; }

  /opt/node/bin/node - <<'__RCON_JS__' || return $?
const net = require('net');

const HOST = process.env.RCON_HOST || '127.0.0.1';
const PORT = parseInt(process.env.RCON_PORT || '28016', 10);
const PASS = process.env.RCON_PASS || '';
const TIMEOUT_MS = (parseInt(process.env.SHUTDOWN_TIMEOUT_SEC || '30', 10) * 1000) || 30000;
const CMDS = (process.env.SHUTDOWN_RCON_CMDS || '').split(',').map(s => s.trim()).filter(Boolean);

const SERVERDATA_AUTH = 3;
const SERVERDATA_EXECCOMMAND = 2;

let reqId = 1;

function pkt(id, type, body) {
  const bodyBuf = Buffer.from(body, 'utf8');
  const len = 4 + 4 + bodyBuf.length + 2;
  const buf = Buffer.alloc(4 + len);
  buf.writeInt32LE(len, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  bodyBuf.copy(buf, 12);
  buf.writeInt8(0, 12 + bodyBuf.length);
  buf.writeInt8(0, 13 + bodyBuf.length);
  return buf;
}

function connectRcon() {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: HOST, port: PORT }, () => resolve(sock));
    sock.setTimeout(TIMEOUT_MS, () => { sock.destroy(new Error('timeout')); });
    sock.on('error', reject);
  });
}

async function auth(sock) {
  return new Promise((resolve, reject) => {
    const id = reqId++;
    sock.write(pkt(id, SERVERDATA_AUTH, PASS));
    let ok = false;
    const onData = (chunk) => {
      const rid = chunk.readInt32LE(4);
      if (rid === -1) { sock.off('data', onData); reject(new Error('auth failed')); }
      else { ok = true; sock.off('data', onData); resolve(); }
    };
    sock.on('data', onData);
    setTimeout(() => { if (!ok) { sock.off('data', onData); reject(new Error('auth timeout')); } }, TIMEOUT_MS);
  });
}

async function exec(sock, cmd) {
  return new Promise((resolve) => {
    const id = reqId++;
    sock.write(pkt(id, SERVERDATA_EXECCOMMAND, cmd));
    setTimeout(resolve, 200);
  });
}

(async () => {
  if (CMDS.length === 0) process.exit(0);
  const sock = await connectRcon().catch(e => { console.error('[rcon] connect failed:', e.message); process.exit(2); });
  try { await auth(sock); } catch (e) { console.error('[rcon] auth failed:', e.message); sock.destroy(); process.exit(3); }
  for (const c of CMDS) { try { console.log('[rcon] cmd:', c); await exec(sock, c); } catch {} }
  try { sock.end(); } catch {}
  setTimeout(() => process.exit(0), 50);
})();
__RCON_JS__
}

# -----------------------------------------------------------------------
# Shutdown commands helper (single timeout applied to every step)
# -----------------------------------------------------------------------
shutdown_ran="0"
run_shutdown_cmds() {
  [[ "${shutdown_ran}" == "1" ]] && return 0
  shutdown_ran="1"

  # RCON shutdown commands first
  if [[ -n "${SHUTDOWN_RCON_CMDS// }" ]]; then
    log "Sending shutdown RCON commands: ${SHUTDOWN_RCON_CMDS}"
    send_rcon_cmds "${SHUTDOWN_RCON_CMDS}" || err "Some RCON shutdown commands may have failed."
    sleep 1
  fi

  # Local shell commands (CSV)
  if [[ -n "${SHUTDOWN_CMDS// }" ]]; then
    log "Running local shutdown shell commands…"
    local IFS=','; read -r -a CMDS <<< "${SHUTDOWN_CMDS}"
    for raw in "${CMDS[@]}"; do
      cmd="${raw#"${raw%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
      [[ -z "${cmd}" ]] && continue
      log "shutdown: ${cmd}"
      timeout "${SHUTDOWN_TIMEOUT_SEC}" bash -lc "${cmd}" || err "shutdown command failed or timed out (${SHUTDOWN_TIMEOUT_SEC}s): ${cmd}"
    done
  fi
}

# -----------------------------------------------------------------------
# Supervision loop (crash + CPU stall)
# -----------------------------------------------------------------------
child_pid=""
term_requested="0"
trap 'term_requested="1"; [[ -n "${child_pid}" ]] && kill -TERM "${child_pid}" 2>/dev/null || true' TERM INT

log "Launching via wrapper (argv mode)…"
while :; do
  # Start server without exec so we can supervise
  /opt/node/bin/node "$WRAPPER" --argv "${ARGV[@]}" &
  child_pid="$!"

  # CPU stall watch (if enabled)
  if [[ "${WATCH_ENABLED}" == "1" ]]; then
    cpu_stall_watch "${child_pid}" & stall_pid="$!"
  fi

  # Wait for child; capture rc
  rc=0
  wait "${child_pid}" || rc=$?

  # Stop stall watcher
  [[ -n "${stall_pid:-}" ]] && kill -TERM "${stall_pid}" 2>/dev/null || true
  unset stall_pid

  # If watch disabled or graceful stop or panel stop → exit
  if [[ "${WATCH_ENABLED}" != "1" || "${rc}" -eq 0 || "${term_requested}" == "1" ]]; then
    run_shutdown_cmds
    exit "${rc}"
  fi

  # Crash → restart after short backoff
  log "Server crashed/terminated (rc=${rc}). Restarting in ${RESTART_BACKOFF_SEC}s…"
  sleep "${RESTART_BACKOFF_SEC}"
done
