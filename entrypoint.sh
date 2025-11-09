#!/bin/bash
set -euo pipefail

RED='\e[31m'; YEL='\e[33m'; GRN='\e[32m'; NC='\e[0m'
log()  { echo -e "[entrypoint] $*"; }
warn() { echo -e "${YEL}[warn]${NC} $*"; }
bad()  { echo -e "${RED}[ERROR]${NC} $*"; }
good() { echo -e "${GRN}[ok]${NC} $*"; }

export HOME=/home/container
cd /home/container || exit 1

# niceties
ulimit -n 65535 || true
umask 002
chown -R "$(id -u):$(id -g)" /home/container 2>/dev/null || true

# SteamCMD layout
mkdir -p /home/container/Steam/package /home/container/steamcmd /home/container/.steam/sdk32 /home/container/.steam/sdk64
export STEAMCMDDIR=/home/container/steamcmd

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  echo ""
}

# ---------------- Panel config ----------------
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

DEFAULT_STEAM_BRANCH=""
case "${FRAMEWORK}" in
  vanilla-staging|oxide-staging|carbon-staging* ) DEFAULT_STEAM_BRANCH="staging" ;;
  vanilla-aux1|carbon-aux1* )                     DEFAULT_STEAM_BRANCH="aux1" ;;
  vanilla-aux2|carbon-aux2* )                     DEFAULT_STEAM_BRANCH="aux2" ;;
esac

CUSTOM_FRAMEWORK_URL="${CUSTOM_FRAMEWORK_URL:-${CustomFrameworkURL:-}}"
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# RCON defaults (used for graceful shutdown)
export RCON_HOST="${RCON_HOST:-127.0.0.1}"
export RCON_PORT="${RCON_PORT:-28016}"
export RCON_PASS="${RCON_PASS:-}"

# Removed heartbeat-related vars (WATCH_ENABLED/HEARTBEAT/CHECK loops)

# Shutdown (single timeout)
SHUTDOWN_CMDS="${SHUTDOWN_CMDS:-}"
SHUTDOWN_RCON_CMDS="${SHUTDOWN_RCON_CMDS:-}"
SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-30}"

# Disk & limits awareness
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-1024}"
DISK_ENFORCE="${DISK_ENFORCE:-1}"
HEAP_TARGET_MB="${HEAP_TARGET_MB:-}"

# OOM detector (kept, but no wrapper)
OOM_WATCH="${OOM_WATCH:-1}"
OOM_STATE_FILE="/home/container/.oom_seen"

# Preflight port checks
PREFLIGHT_PORTCHECK="${PREFLIGHT_PORTCHECK:-1}"

# Optional convenience IP
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# ---------------- Limits awareness ----------------
cgroup_mem_limit_mb() {
  local lim
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    lim=$(cat /sys/fs/cgroup/memory.max); [[ "$lim" == "max" ]] && { echo 0; return; }
    echo $(( lim/1024/1024 ))
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes); echo $(( lim/1024/1024 ))
  else
    echo 0
  fi
}
cgroup_cpu_quota() {
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    awk '{ if ($1=="max") {print "unlimited"} else {printf("%.2f", $1/$2)} }' /sys/fs/cgroup/cpu.max
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    local q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if (( q < 0 )); then echo "unlimited"; else awk -v q="$q" -v p="$p" 'BEGIN{printf("%.2f", q/p)}'; fi
  else
    echo "unknown"
  fi
}
MEM_LIMIT_MB=$(cgroup_mem_limit_mb)
CPU_LIMIT_CORES=$(cgroup_cpu_quota)
log "Container limits: memory=${MEM_LIMIT_MB:-0}MB${MEM_LIMIT_MB:+ } cpu=${CPU_LIMIT_CORES} cores"
if [[ -n "$HEAP_TARGET_MB" && "$MEM_LIMIT_MB" -gt 0 && "$HEAP_TARGET_MB" -gt "$MEM_LIMIT_MB" ]]; then
  echo -e "${RED}[LIMIT] HEAP_TARGET_MB=${HEAP_TARGET_MB}MB exceeds container memory limit ${MEM_LIMIT_MB}MB — expect OOM!${NC}"
fi
if [[ "$MEM_LIMIT_MB" -gt 0 && "$MEM_LIMIT_MB" -lt 4096 ]]; then
  echo -e "${RED}[LIMIT] Low container memory (${MEM_LIMIT_MB}MB). Consider 6–8 GB for modded servers.${NC}"
fi

# ---------------- Disk-space guard ----------------
free_mb=$(df -Pm /home/container | awk 'NR==2{print $4}')
if (( free_mb < DISK_MIN_FREE_MB )); then
  echo -e "${RED}[DISK] Free space ${free_mb}MB < threshold ${DISK_MIN_FREE_MB}MB on /home/container${NC}"
  if [[ "$DISK_ENFORCE" == "1" ]]; then bad "Exiting due to low disk (DISK_ENFORCE=1)."; exit 60; else warn "Continuing despite low disk (DISK_ENFORCE=0)."; fi
else
  good "Disk free ${free_mb}MB ≥ ${DISK_MIN_FREE_MB}MB"
fi

# ---------------- Preflight port checks ----------------
check_port() {
  local proto="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnup | grep -q ":${port} " && return 1
    [[ "$proto" == "udp" ]] && ss -lunp | grep -q ":${port} " && return 1
    return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln | grep -q ":${port} " && return 1
    return 0
  fi
  return 0
}
if [[ "$PREFLIGHT_PORTCHECK" == "1" ]]; then
  fail=0
  for spec in "tcp:${RCON_PORT:-}" "udp:${QUERY_PORT:-}" "udp:${SERVER_PORT:-}"; do
    proto="${spec%%:*}"; port="${spec##*:}"
    [[ -z "$port" ]] && continue
    if ! check_port "$proto" "$port"; then
      echo -e "${RED}[PORT] ${proto^^} port ${port} already in use inside container.${NC}"
      fail=1
    fi
  done
  (( fail )) && { bad "Preflight port check failed — fix bindings or change ports."; exit 61; }
fi

# ---------------- OOM detector (non-invasive) ----------------
oom_read_counter() {
  if [[ -r /sys/fs/cgroup/memory.events ]]; then
    awk '/oom_kill/ {print $2}' /sys/fs/cgroup/memory.events
  else
    echo 0
  fi
}
if [[ "$OOM_WATCH" == "1" ]]; then
  prev=$(oom_read_counter)
  if [[ -f "$OOM_STATE_FILE" ]]; then
    last=$(cat "$OOM_STATE_FILE" 2>/dev/null || echo 0)
    if (( prev > last )); then
      echo -e "${RED}[OOM] Previous run saw ${prev-last} OOM kill(s). Investigate memory limits/logs.${NC}"
    fi
  fi
  printf "%s" "$prev" > "$OOM_STATE_FILE" || true
fi

# ---------------- Validate / framework install ----------------
do_validate() {
  [[ "${VALIDATE}" != "1" ]] && { log "VALIDATE=0 → skipping SteamCMD validation."; return 0; }
  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { bad "steamcmd not found"; exit 11; }
  local RESOLVED_BRANCH="${STEAM_BRANCH:-${DEFAULT_STEAM_BRANCH}}"
  local BRANCH_FLAGS=""
  [[ -n "$RESOLVED_BRANCH" ]] && BRANCH_FLAGS="-beta ${RESOLVED_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
  log "SteamCMD validate (branch: ${RESOLVED_BRANCH:-default})…"
  "$SCMD" +force_install_dir /home/container +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate +quit
  good "Steam files validated."
}

install_oxide() {
  local channel="release"
  case "${FRAMEWORK}" in
    oxide-staging|uMod-staging|oxide_staging) channel="staging" ;;
  esac
  local url=""
  if [[ "$channel" == "staging" ]]; then
    url="https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip"
  else
    url="https://downloads.oxidemod.com/artifacts/Oxide.Rust/release/Oxide.Rust-linux.zip"
  fi
  log "Installing Oxide (channel: ${channel})…"
  local tmp; tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o oxide.zip "${url}"
  unzip -o -q oxide.zip -d /home/container
  popd >/dev/null; rm -rf "$tmp"
  good "Oxide install complete (${channel})."
}

install_carbon() {
  log "Installing Carbon…"
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
    case "$channel" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.Minimal.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.Minimal.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.Minimal.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.Minimal.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.Minimal.tar.gz" ;;
    esac
  else
    case "$channel" in
      production) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz" ;;
      edge)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.tar.gz" ;;
      staging)    url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.tar.gz" ;;
      aux1)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.tar.gz" ;;
      aux2)       url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.tar.gz" ;;
    esac
  fi
  [[ -z "$url" ]] && { bad "Could not determine Carbon artifact"; exit 10; }
  local tmp; tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o carbon.tar.gz "${url}"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null; rm -rf "$tmp"; good "Carbon install complete."
}

install_from_custom_url() {
  local url="$1"; [[ -z "$url" ]] && { bad "Custom framework URL empty"; return 1; }
  log "Installing custom framework from URL…"
  local tmp; tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  case "$url" in
    *.zip) curl -fSL --retry 5 -o artifact.zip "$url"; unzip -o -q artifact.zip -d /home/container ;;
    *.tar.gz|*.tgz|*.tar|*.tar.xz) curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
    *) curl -fSL --retry 5 -o artifact.tar.gz "$url"; tar -xzf artifact.tar.gz -C /home/container ;;
  esac
  popd >/dev/null; rm -rf "$tmp"; good "Custom framework install complete."
}

if [[ "${FRAMEWORK_UPDATE}" == "1" ]]; then
  do_validate
  if [[ -n "${CUSTOM_FRAMEWORK_URL}" ]]; then
    warn "Using custom framework URL (overrides FRAMEWORK)."
    install_from_custom_url "${CUSTOM_FRAMEWORK_URL}"
  else
    case "${FRAMEWORK}" in
      oxide*|uMod*) install_oxide ;;
      carbon* )     install_carbon ;;
      * )           log "Vanilla channel; no framework to install." ;;
    esac
  fi
else
  warn "FRAMEWORK_UPDATE=0 → skipping framework install."
  do_validate
fi

# ---------------- Build argv ----------------
if [[ "$#" -gt 0 ]]; then
  ARGV=( "$@" )
else
  [[ -z "${STARTUP:-}" ]] && { bad "No STARTUP provided."; exit 12; }
  EXPANDED="$(eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\"" )"
  eval "set -- ${EXPANDED}"
  ARGV=( "$@" )
fi
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then ARGV=( "${ARGV[@]:1}" ); fi

if [[ ! -f "./RustDedicated" ]]; then bad "RustDedicated not found. Enable VALIDATE=1 and retry."; exit 13; fi
[[ -x "./RustDedicated" ]] || chmod +x ./RustDedicated || true

# ---------------- RCON helper (for shutdown) ----------------
send_rcon_cmds() {
  local cmds_csv="$1"
  [[ -z "${cmds_csv// }" ]] && return 0
  [[ -z "${RCON_PORT:-}" || -z "${RCON_PASS:-}" ]] && { warn "RCON not configured; skipping RCON cmds."; return 1; }
  /opt/node/bin/node - <<'__RCON_JS__' || return $?
const net=require('net');
const HOST=process.env.RCON_HOST||'127.0.0.1';
const PORT=parseInt(process.env.RCON_PORT||'28016',10);
const PASS=process.env.RCON_PASS||'';
const TIMEOUT_MS=(parseInt(process.env.SHUTDOWN_TIMEOUT_SEC||'30',10)*1000)||30000;
const CMDS=(process.env.SHUTDOWN_RCON_CMDS||'').split(',').map(s=>s.trim()).filter(Boolean);
const SERVERDATA_AUTH=3,SERVERDATA_EXECCOMMAND=2;let reqId=1;
function pkt(id,type,body){const b=Buffer.from(body,'utf8');const len=4+4+b.length+2;const buf=Buffer.alloc(4+len);buf.writeInt32LE(len,0);buf.writeInt32LE(id,4);buf.writeInt32LE(type,8);b.copy(buf,12);buf.writeInt8(0,12+b.length);buf.writeInt8(0,13+b.length);return buf;}
function connect(){return new Promise((res,rej)=>{const s=net.createConnection({host:HOST,port:PORT},()=>res(s));s.setTimeout(TIMEOUT_MS,()=>{s.destroy(new Error('timeout'));});s.on('error',rej);});}
async function auth(sock){return new Promise((res,rej)=>{const id=reqId++;sock.write(pkt(id,SERVERDATA_AUTH,PASS));let done=false;const onData=(ch)=>{const rid=ch.readInt32LE(4);if(rid===-1){sock.off('data',onData);rej(new Error('auth failed'));}else{done=true;sock.off('data',onData);res();}};sock.on('data',onData);setTimeout(()=>{if(!done){sock.off('data',onData);rej(new Error('auth timeout'));}},TIMEOUT_MS);});}
async function exec(sock,cmd){return new Promise((res)=>{sock.write(pkt(reqId++,SERVERDATA_EXECCOMMAND,cmd));setTimeout(res,200);});}
(async()=>{if(CMDS.length===0)process.exit(0);const sock=await connect().catch(e=>{console.error("[rcon] connect failed:",e.message);process.exit(2);});try{await auth(sock);}catch(e){console.error("[rcon] auth failed:",e.message);sock.destroy();process.exit(3);}for(const c of CMDS){try{console.log("[rcon] cmd:",c);await exec(sock,c);}catch{}}try{sock.end();}catch{}setTimeout(()=>process.exit(0),50);})();
__RCON_JS__
}

# ---------------- Graceful shutdown trap ----------------
TERM_CHILD_PID=""
on_term() {
  warn "Received termination signal — sending shutdown commands and stopping server…"
  [[ -n "$SHUTDOWN_RCON_CMDS" ]] && send_rcon_cmds "$SHUTDOWN_RCON_CMDS" || true
  if [[ -n "$TERM_CHILD_PID" ]]; then kill -TERM "$TERM_CHILD_PID" 2>/dev/null || true; fi
  sleep "${SHUTDOWN_TIMEOUT_SEC}"
  exit 0
}
trap on_term INT TERM

# ---------------- Launch server directly (no wrapper/heartbeat) ----------------
log "Launching RustDedicated (direct)…"
set +e
./RustDedicated "${ARGV[@]}" &
TERM_CHILD_PID=$!
wait $!
exit $?
