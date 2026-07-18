#!/bin/bash
set -euo pipefail
# ============================================================================
# Cobalt entrypoint 2.0
#   preflight -> apply pending rollback -> resolve version (pin skips SteamCMD
#   entirely) -> install framework (+ archive artifact) -> arm Carbon doorstop
#   -> build argv -> exec wrapper.
#
# FRAMEWORK (vanilla|oxide|carbon[-minimal]) and STEAM_BRANCH (the Rust game
# branch) are independent; the framework channel is derived from the branch.
# Rollback is STAGED by the wrapper as a flag file in .cobalt/ and applied here
# at boot — the only safe mutation point in the container lifecycle.
# ============================================================================

RED='\e[31m'; YEL='\e[33m'; GRN='\e[32m'; NC='\e[0m'
log()  { echo -e "[entrypoint] $*"; }
warn() { echo -e "${YEL}[warn]${NC} $*"; }
bad()  { echo -e "${RED}[ERROR]${NC} $*"; }
good() { echo -e "${GRN}[ok]${NC} $*"; }

# ---------- home (COBALT_HOME overridable for tests) ----------
CH="${COBALT_HOME:-/home/container}"
export COBALT_HOME="$CH"
export HOME="$CH"
cd "$CH" || exit 1
export TERM=${TERM:-xterm}

ulimit -n 65535 2>/dev/null || true
umask 002
chown -R "$(id -u):$(id -g)" "$CH" 2>/dev/null || true

COBALT_DIR="$CH/.cobalt"
mkdir -p "$COBALT_DIR/frameworks" "$COBALT_DIR/staging"

# ---------- node (needed early: JSON parsing for rollback apply) ----------
NODE_BIN="/opt/node/bin/node"
command -v "$NODE_BIN" >/dev/null 2>&1 || NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || { bad "node binary not found"; exit 15; }
jget() { # jget <file> <accessor>  — path via argv so it survives any platform
  "$NODE_BIN" -e "const o=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));console.log(new Function('o','return o'+process.argv[2])(o))" "$1" "$2"
}

# ---------- .pteroignore (shrink panel backups by GB) ----------
if [[ ! -f "$CH/.pteroignore" ]]; then
  cat > "$CH/.pteroignore" <<'EOF'
steamcmd/
Steam/
.DepotDownloader/
.cobalt/staging/
unity.log*
cobalt.log*
latest.log*
EOF
fi

# ---------- SteamCMD layout ----------
mkdir -p "$CH/Steam/package" "$CH/steamcmd" "$CH/.steam/sdk32" "$CH/.steam/sdk64"
export STEAMCMDDIR="$CH/steamcmd"
steamcmd_path() {
  if [[ -x "$CH/steamcmd/steamcmd.sh" ]]; then echo "$CH/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  echo ""
}
depotdownloader_path() {
  if [[ -n "${COBALT_DEPOTDOWNLOADER:-}" && -x "${COBALT_DEPOTDOWNLOADER}" ]]; then echo "$COBALT_DEPOTDOWNLOADER"; return; fi
  for p in /opt/depotdownloader/DepotDownloader "$CH/depotdownloader/DepotDownloader"; do
    [[ -x "$p" ]] && { echo "$p"; return; }
  done
  echo ""
}

# ---------- panel vars ----------
SRCDS_APPID="${SRCDS_APPID:-258550}"
export SRCDS_APPID

STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

# FRAMEWORK (vanilla|oxide|carbon|carbon-minimal) and STEAM_BRANCH (the Rust game
# branch) are now INDEPENDENT — the framework channel derives from the branch.
FRAMEWORK="${FRAMEWORK:-vanilla}"
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"
DOWNLOADER="${DOWNLOADER:-steamcmd}"   # steamcmd | depotdownloader
VALIDATE="${VALIDATE:-0}"          # full 8GB checksum every boot costs minutes; app_update alone no-ops when current
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"   # "" (public) | staging | aux01 | aux02 | ...
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"
CUSTOM_FRAMEWORK_URL="${CUSTOM_FRAMEWORK_URL:-${CustomFrameworkURL:-}}"

SERVER_IDENTITY="${SERVER_IDENTITY:-rust}"
PRESERVE_DIRS="${PRESERVE_DIRS:-oxide,carbon,cfg,Configs,plugins,Carbon,oxide.config.json,server,.cobalt,steamcmd,Steam,.steam,steamapps,.DepotDownloader}"

# RCON + wrapper knobs (wrapper reads env)
export RCON_HOST="${RCON_HOST:-127.0.0.1}"
export RCON_PORT="${RCON_PORT:-28016}"
export RCON_PASS="${RCON_PASS:-}"
export SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-60}"
export TELEMETRY_INTERVAL_SEC="${TELEMETRY_INTERVAL_SEC:-0}"
export UPDATE_CHECK_INTERVAL_SEC="${UPDATE_CHECK_INTERVAL_SEC:-3600}"
export CONSOLE_COLORS="${CONSOLE_COLORS:-}"

# guards
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-1024}"
DISK_ENFORCE="${DISK_ENFORCE:-1}"
HEAP_TARGET_MB="${HEAP_TARGET_MB:-}"
OOM_WATCH="${OOM_WATCH:-1}"
OOM_STATE_FILE="$COBALT_DIR/oom_seen"
PREFLIGHT_PORTCHECK="${PREFLIGHT_PORTCHECK:-1}"

if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  export APP_PUBLIC_IP
fi

# ---------- limits awareness ----------
cgroup_mem_limit_mb() {
  local lim
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    lim=$(cat /sys/fs/cgroup/memory.max)
    [[ "$lim" == "max" ]] && { echo 0; return; }
    echo $(( lim/1024/1024 ))
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
    echo $(( lim/1024/1024 ))
  else
    echo 0
  fi
}
cgroup_cpu_quota() {
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    awk '{ if ($1=="max") {print "unlimited"} else {printf("%.2f", $1/$2)} }' /sys/fs/cgroup/cpu.max
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    local q p; q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if (( q < 0 )); then echo "unlimited"; else awk -v q="$q" -v p="$p" 'BEGIN{printf("%.2f", q/p)}'; fi
  else
    echo "unknown"
  fi
}
MEM_LIMIT_MB=$(cgroup_mem_limit_mb)
CPU_LIMIT_CORES=$(cgroup_cpu_quota)
log "Container limits: memory=${MEM_LIMIT_MB}MB cpu=${CPU_LIMIT_CORES} cores"
if [[ -n "$HEAP_TARGET_MB" && "$MEM_LIMIT_MB" -gt 0 && "$HEAP_TARGET_MB" -gt "$MEM_LIMIT_MB" ]]; then
  echo -e "${RED}[LIMIT] HEAP_TARGET_MB=${HEAP_TARGET_MB}MB exceeds container memory limit ${MEM_LIMIT_MB}MB — expect OOM!${NC}"
fi
if [[ "$MEM_LIMIT_MB" -gt 0 && "$MEM_LIMIT_MB" -lt 4096 ]]; then
  echo -e "${RED}[LIMIT] Low container memory (${MEM_LIMIT_MB}MB). Consider 6-8 GB for modded servers.${NC}"
fi

# ---------- disk guard ----------
free_mb=$(df -Pm "$CH" | awk 'NR==2{print $4}')
if (( free_mb < DISK_MIN_FREE_MB )); then
  echo -e "${RED}[DISK] Free space ${free_mb}MB < threshold ${DISK_MIN_FREE_MB}MB on ${CH}${NC}"
  if [[ "$DISK_ENFORCE" == "1" ]]; then
    bad "Exiting due to low disk (DISK_ENFORCE=1)."
    exit 60
  else
    warn "Continuing despite low disk (DISK_ENFORCE=0)."
  fi
else
  good "Disk free ${free_mb}MB >= ${DISK_MIN_FREE_MB}MB"
fi

# ---------- preflight port checks ----------
check_port() {
  local proto="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnup 2>/dev/null | grep -q ":${port} " && return 1
    [[ "$proto" == "udp" ]] && ss -lunp 2>/dev/null | grep -q ":${port} " && return 1
    return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | grep -q ":${port} " && return 1
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
  if (( fail )); then
    bad "Preflight port check failed — fix bindings or change ports."
    exit 61
  fi
fi

# ---------- OOM detector (notify only) ----------
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
      echo -e "${RED}[OOM] Previous run was OOM-killed ($((prev-last)) kill(s)). Raise the memory limit or lower usage.${NC}"
    fi
  fi
  printf "%s" "$prev" > "$OOM_STATE_FILE" || true
fi

# ============================================================================
# pending ROLLBACK (staged by wrapper: .rollback <build> — applied here)
# ============================================================================
PENDING_RB="$COBALT_DIR/pending_rollback"
if [[ -f "$PENDING_RB" ]]; then
  log "Applying staged rollback…"
  RB_BUILD="$(jget "$PENDING_RB" .buildid)"
  RB_DEPOTS="$(jget "$PENDING_RB" '.depots.map(d=>d.id).join(" ")')"
  RB_ARTIFACT="$(jget "$PENDING_RB" '.frameworkArtifact||""')"
  rb_fail=0
  for dep in $RB_DEPOTS; do
    src=""
    for cand in "$CH/steamcmd/steamapps/content/app_${SRCDS_APPID}/depot_${dep}" \
                "$CH/steamcmd/linux32/steamapps/content/app_${SRCDS_APPID}/depot_${dep}" \
                "$COBALT_DIR/staging/depot_${dep}"; do
      [[ -d "$cand" ]] && { src="$cand"; break; }
    done
    if [[ -z "$src" ]]; then
      bad "rollback: depot ${dep} content not found — skipping apply, starting as-installed."
      rb_fail=1; break
    fi
    log "rollback: applying depot ${dep} from ${src}"
    shopt -s dotglob
    for entry in "$src"/*; do
      [[ -e "$entry" ]] || continue
      name="$(basename "$entry")"
      case ",${PRESERVE_DIRS}," in
        *",${name},"*) warn "rollback: skipping preserved '${name}'"; continue ;;
      esac
      # ponytail: rm+cp full copy per top-level entry = scoped delete semantics
      # with zero rsync dependency; upgrade to rsync --delete if boot time hurts
      rm -rf "${CH:?}/${name:?}"
      cp -a "$entry" "$CH/$name"
    done
    shopt -u dotglob
    rm -rf "$src"
  done
  if [[ "$rb_fail" == "0" ]]; then
    if [[ -n "$RB_ARTIFACT" && -f "$RB_ARTIFACT" ]]; then
      log "rollback: restoring framework from archive $(basename "$RB_ARTIFACT")"
      case "$RB_ARTIFACT" in
        *.zip) unzip -o -q "$RB_ARTIFACT" -d "$CH" ;;
        *)     tar -xzf "$RB_ARTIFACT" -C "$CH" ;;
      esac
    fi
    # acf still claims the newer build — force a validate on the next unpinned update
    printf 'post-rollback to build %s' "$RB_BUILD" > "$COBALT_DIR/force_validate"
    good "Rollback to build ${RB_BUILD} applied (server is pinned to it)."
  fi
  rm -f "$PENDING_RB"
fi

# ============================================================================
# version resolve: pin skips SteamCMD entirely; else app_update
# ============================================================================
PIN_FILE="$COBALT_DIR/pin"
ACF="$CH/steamapps/appmanifest_${SRCDS_APPID}.acf"
acf_buildid() {
  [[ -f "$ACF" ]] || { echo ""; return; }
  sed -n 's/.*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$ACF" | head -1
}

do_update() {
  # decide whether to validate (VALIDATE=1 or a queued force_validate)
  local do_validate=0
  if [[ "$VALIDATE" == "1" || -f "$COBALT_DIR/force_validate" ]]; then
    do_validate=1
    if [[ -f "$COBALT_DIR/force_validate" ]]; then
      local reason; reason="$(cat "$COBALT_DIR/force_validate" 2>/dev/null)"
      warn "Forcing full validation (${reason:-forced})."
    fi
  fi

  if [[ "$DOWNLOADER" == "depotdownloader" ]]; then
    local DD; DD="$(depotdownloader_path)"
    [[ -z "$DD" ]] && { bad "DepotDownloader not found (/opt/depotdownloader/DepotDownloader)"; exit 11; }
    # anonymous by default (no -username); downloads straight into -dir, no relocate
    local DD_ARGS=(-app "$SRCDS_APPID" -dir "$CH")
    [[ -n "$STEAM_BRANCH" ]] && DD_ARGS+=(-branch "$STEAM_BRANCH")
    [[ -n "$STEAM_BRANCH_PASS" ]] && DD_ARGS+=(-branchpassword "$STEAM_BRANCH_PASS")
    [[ "$do_validate" == "1" ]] && DD_ARGS+=(-validate)
    log "DepotDownloader app ${SRCDS_APPID} (branch: ${STEAM_BRANCH:-public}$([[ "$do_validate" == 1 ]] && printf ', validate'))…"
    "$DD" "${DD_ARGS[@]}"
    rm -f "$COBALT_DIR/force_validate"
    good "Game files up to date (DepotDownloader)."
    return
  fi

  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { bad "steamcmd not found"; exit 11; }
  local BRANCH_FLAGS=""
  [[ -n "$STEAM_BRANCH" ]] && BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
  local VFLAG=""
  [[ "$do_validate" == "1" ]] && VFLAG="validate"
  log "SteamCMD app_update ${SRCDS_APPID} (branch: ${STEAM_BRANCH:-public}${VFLAG:+, validate})…"
  "$SCMD" +force_install_dir "$CH" +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
    +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} ${VFLAG} +quit
  rm -f "$COBALT_DIR/force_validate"
  good "Steam files up to date."
}

# ---------- branch-change clean ----------
# When the Rust Steam branch changes, wipe the steamcmd cache and force a
# validate. (The steamcmd folder holds the depot download cache; the game's
# appmanifest lives in steamapps/, so app_update -beta + validate is what
# actually re-resolves the file set for the new branch — the delete alone won't.)
BRANCH_FILE="$COBALT_DIR/branch"
CUR_BRANCH="${STEAM_BRANCH:-public}"
LAST_BRANCH="$(cat "$BRANCH_FILE" 2>/dev/null || echo "__none__")"
if [[ "$LAST_BRANCH" != "__none__" && "$LAST_BRANCH" != "$CUR_BRANCH" ]]; then
  warn "Rust branch changed '${LAST_BRANCH}' -> '${CUR_BRANCH}': clearing steamcmd cache and forcing a validate."
  rm -rf "$CH/steamcmd"
  mkdir -p "$CH/steamcmd"
  printf 'branch change %s -> %s' "$LAST_BRANCH" "$CUR_BRANCH" > "$COBALT_DIR/force_validate"
fi
printf '%s' "$CUR_BRANCH" > "$BRANCH_FILE"

SKIP_FRAMEWORK=0
if [[ -f "$PIN_FILE" ]]; then
  PINNED="$(cat "$PIN_FILE")"
  CURRENT="$(acf_buildid)"
  if [[ -n "$CURRENT" && "$PINNED" == "$CURRENT" ]]; then
    good "PINNED to build ${PINNED} — skipping SteamCMD and framework update."
  else
    warn "PINNED to ${PINNED} but installed build is '${CURRENT:-unknown}' — starting AS-INSTALLED (no update). Use .unpin or .rollback to reconcile."
  fi
  SKIP_FRAMEWORK=1   # frameworks compile against the game build; pin freezes both
elif [[ "$AUTO_UPDATE" == "1" ]]; then
  do_update
else
  log "AUTO_UPDATE=0 — skipping game update."
fi

# ============================================================================
# framework install (+ archive artifact + last_install for the catalog)
# ============================================================================
write_last_install() { # framework version artifact
  printf '{"framework":"%s","version":"%s","artifact":"%s"}\n' "$1" "$2" "$3" > "$COBALT_DIR/last_install"
}

install_oxide() {
  local channel="release" url="" ver="" tag=""
  [[ "$STEAM_BRANCH" == "staging" ]] && channel="staging"   # channel follows the game branch
  if [[ "$channel" == "release" ]]; then
    # GitHub tagged releases give a stable, versioned, historically-fetchable URL
    tag="$(curl -fsSL --retry 3 https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest 2>/dev/null \
      | "$NODE_BIN" -p 'try{JSON.parse(require("fs").readFileSync(0,"utf8")).tag_name}catch{""}' || true)"
    if [[ -n "$tag" ]]; then
      url="https://github.com/OxideMod/Oxide.Rust/releases/download/${tag}/Oxide.Rust-linux.zip"
      ver="$tag"
    else
      warn "GitHub API failed — falling back to oxidemod.com latest"
      url="https://downloads.oxidemod.com/artifacts/Oxide.Rust/release/Oxide.Rust-linux.zip"
      ver="release-$(date +%F)"
    fi
  else
    url="https://downloads.oxidemod.com/artifacts/Oxide.Rust/staging/Oxide.Rust-linux.zip"
    ver="staging-$(date +%F)"
  fi
  log "Installing Oxide ${ver}…"
  local tmp; tmp="$(mktemp -d)"
  curl -fSL --retry 5 -o "$tmp/oxide.zip" "$url"
  local art="$COBALT_DIR/frameworks/oxide-${ver}.zip"
  cp "$tmp/oxide.zip" "$art"
  unzip -o -q "$tmp/oxide.zip" -d "$CH"
  rm -rf "$tmp"
  write_last_install "oxide" "$ver" "$art"
  good "Oxide ${ver} installed (artifact archived)."
}

# Carbon uses ROLLING tags on CarbonCommunity/Carbon (NOT /releases/latest/ —
# that only ever resolves to production_build, the sole non-prerelease). The tag
# follows the Steam BRANCH now, not the framework name:
carbon_tag() {
  case "$STEAM_BRANCH" in
    staging )       echo "rustbeta_staging_build" ;;
    aux01|aux1 )    echo "rustbeta_aux01_build" ;;
    aux02|aux2 )    echo "rustbeta_aux02_build" ;;
    * )             echo "production_build" ;;   # public / unknown -> production
  esac
}
# Ordered asset candidates. Beta tags (staging/aux) ship only Debug, stable tags
# ship Release — try Release then fall back to Debug. `-minimal` is orthogonal.
carbon_assets() {
  if [[ "$FRAMEWORK" == *"-minimal" ]]; then echo "Carbon.Linux.Minimal.tar.gz"
  else echo "Carbon.Linux.Release.tar.gz Carbon.Linux.Debug.tar.gz"; fi
}

install_carbon() {
  local tag; tag="$(carbon_tag)"
  local base="${CARBON_BASE:-https://github.com/CarbonCommunity/Carbon/releases/download}/${tag}"
  local tmp; tmp="$(mktemp -d)" got=""
  for asset in $(carbon_assets); do
    log "Fetching Carbon ${tag}/${asset}…"
    if curl -fSL --retry 3 -o "$tmp/carbon.tar.gz" "${base}/${asset}"; then got="$asset"; break; fi
    warn "  ${asset} not available for ${tag}; trying next…"
  done
  if [[ -z "$got" ]]; then
    rm -rf "$tmp"
    if [[ -d "$CH/carbon" ]]; then
      warn "Carbon download failed for tag '${tag}' — keeping existing install and continuing."
      return 0
    fi
    bad "Carbon download failed for tag '${tag}' (FRAMEWORK=${FRAMEWORK}). Invalid channel or GitHub unreachable."
    exit 10
  fi
  local ver="${tag}-$(date +%F)"
  local art="$COBALT_DIR/frameworks/carbon-${tag}-$(date +%Y%m%d).tar.gz"
  cp "$tmp/carbon.tar.gz" "$art"
  tar -xzf "$tmp/carbon.tar.gz" -C "$CH"
  rm -rf "$tmp"
  write_last_install "${FRAMEWORK}" "$ver" "$art"
  good "Carbon installed from ${tag}/${got} (artifact archived)."
}

install_from_custom_url() {
  local url="$1"
  log "Installing custom framework from URL…"
  local tmp; tmp="$(mktemp -d)"
  local ver; ver="custom-$(date +%F)"
  case "$url" in
    *.zip)
      curl -fSL --retry 5 -o "$tmp/artifact.zip" "$url"
      cp "$tmp/artifact.zip" "$COBALT_DIR/frameworks/${ver}.zip"
      unzip -o -q "$tmp/artifact.zip" -d "$CH"
      write_last_install "custom" "$ver" "$COBALT_DIR/frameworks/${ver}.zip"
      ;;
    *)
      curl -fSL --retry 5 -o "$tmp/artifact.tar.gz" "$url"
      cp "$tmp/artifact.tar.gz" "$COBALT_DIR/frameworks/${ver}.tar.gz"
      tar -xzf "$tmp/artifact.tar.gz" -C "$CH"
      write_last_install "custom" "$ver" "$COBALT_DIR/frameworks/${ver}.tar.gz"
      ;;
  esac
  rm -rf "$tmp"
  good "Custom framework installed (artifact archived)."
}

if [[ "$SKIP_FRAMEWORK" == "1" ]]; then
  : # pinned: run whatever is installed
elif [[ "${FRAMEWORK_UPDATE}" == "1" ]]; then
  if [[ -n "${CUSTOM_FRAMEWORK_URL}" ]]; then
    warn "Using custom framework URL (overrides FRAMEWORK)."
    install_from_custom_url "${CUSTOM_FRAMEWORK_URL}"
  else
    case "${FRAMEWORK}" in
      oxide|oxide-release|uMod|uMod-release|oxide-staging|uMod-staging|oxide_staging) install_oxide ;;
      carbon* ) install_carbon ;;
      * )
        log "Vanilla channel; no framework to install."
        write_last_install "vanilla" "-" ""
        ;;
    esac
  fi
else
  warn "FRAMEWORK_UPDATE=0 — skipping framework install."
fi

# ============================================================================
# build argv
# ============================================================================
if [[ "$#" -gt 0 ]]; then
  ARGV=( "$@" )
else
  [[ -z "${STARTUP:-}" ]] && { bad "No STARTUP provided."; exit 12; }
  EXPANDED="$(eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\"" )"
  eval "set -- ${EXPANDED}"
  ARGV=( "$@" )
fi
if [[ "${#ARGV[@]}" -gt 0 && "${ARGV[0]}" == "/entrypoint.sh" ]]; then ARGV=( "${ARGV[@]:1}" ); fi

# ---------- binary checks ----------
if [[ ! -f "$CH/RustDedicated" ]]; then
  bad "RustDedicated not found. Set AUTO_UPDATE=1 (and VALIDATE=1 once) and restart."
  exit 13
fi
[[ -x "$CH/RustDedicated" ]] || chmod +x "$CH/RustDedicated" || true

WRAPPER="${COBALT_WRAPPER:-/opt/cobalt/wrapper.js}"
[[ -f "$WRAPPER" ]] || { bad "wrapper.js not found at ${WRAPPER}"; exit 14; }

# ---------- Carbon doorstop ----------
# Carbon injects via Unity Doorstop; extracting the tarball is NOT enough — it
# must be launched with DOORSTOP_*/LD_PRELOAD set (carbon.sh does this). We source
# Carbon's own env script for the exact paths, pass them to the wrapper as COBALT_
# vars, and UNSET the real names so only RustDedicated is preloaded, not node.
case "${FRAMEWORK}" in
  carbon*)
    if [[ -f "$CH/carbon/tools/environment.sh" && -f "$CH/libdoorstop.so" ]]; then
      # shellcheck disable=SC1091
      source "$CH/carbon/tools/environment.sh"
      export COBALT_DOORSTOP_TARGET="${DOORSTOP_TARGET_ASSEMBLY:-$CH/carbon/managed/Carbon.Preloader.dll}"
      export COBALT_DOORSTOP_PRELOAD="${LD_PRELOAD:-$CH/libdoorstop.so}"
      export COBALT_DOORSTOP_LDPATH="${LD_LIBRARY_PATH:-$CH:$CH/RustDedicated_Data/Plugins/x86_64}"
      unset DOORSTOP_ENABLED DOORSTOP_TARGET_ASSEMBLY LD_PRELOAD LD_LIBRARY_PATH
      good "Carbon doorstop environment armed (Carbon will inject into RustDedicated)."
    else
      warn "FRAMEWORK=${FRAMEWORK} but Carbon is not installed (carbon/tools/environment.sh or libdoorstop.so missing) — it will NOT load. Set FRAMEWORK_UPDATE=1 and restart."
    fi
    ;;
esac

# ---------- launch (node streams stdout unbuffered; no stdbuf needed) ----------
log "Launching via Cobalt wrapper 2.0"
exec "$NODE_BIN" "$WRAPPER" --argv "${ARGV[@]}"
