#!/usr/bin/env bash

set -euo pipefail
SRCDS_APPID="258550"

log() { echo "[install] $*"; }
fail() { echo "[install][ERROR] $*" >&2; exit 1; }

# ---------- ENV / Defaults ----------
export HOME="/mnt/server"
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
VALIDATE="${VALIDATE:-0}"   # set to 1 to run Steam 'validate'

# ---------- Prep filesystem ----------
log "Preparing folders..."
mkdir -p /mnt/server \
         /mnt/server/steamcmd \
         /mnt/server/steamapps

# ---------- Download SteamCMD ----------
log "Downloading SteamCMD..."
cd /tmp
curl -sSLo steamcmd_linux.tar.gz --fail --retry 5 --retry-connrefused --retry-delay 2 \
  "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
tar -xzf steamcmd_linux.tar.gz -C /mnt/server/steamcmd

# Keep chown narrow (avoid touching entire /mnt)
chown -R root:root /mnt/server/steamcmd || true

cd /mnt/server/steamcmd

# ---------- Build command flags ----------
declare -a APP_UPDATE
if [[ -n "$STEAM_BRANCH" ]]; then
  APP_UPDATE=(+app_update "$SRCDS_APPID" -beta "$STEAM_BRANCH")
  if [[ -n "$STEAM_BRANCH_PASS" ]]; then
    APP_UPDATE+=(-betapassword "$STEAM_BRANCH_PASS")
  fi
else
  APP_UPDATE=(+app_update "$SRCDS_APPID")
fi

# EXTRA_FLAGS split into an array
read -r -a EXTRA_ARR <<< "${EXTRA_FLAGS}"

VALIDATE_ARR=()
if [[ "$VALIDATE" == "1" ]]; then
  VALIDATE_ARR+=(validate)
fi

# ---------- Run SteamCMD ----------
if [[ "$STEAM_USER" == "anonymous" ]]; then
  log "Using anonymous Steam user"
else
  log "Using provided Steam user: ${STEAM_USER}"
fi

log "Running SteamCMD to install app ${SRCDS_APPID}..."
./steamcmd.sh \
  +force_install_dir "/mnt/server" \
  +login "$STEAM_USER" "$STEAM_PASS" "$STEAM_AUTH" \
  "${APP_UPDATE[@]}" "${EXTRA_ARR[@]}" "${VALIDATE_ARR[@]}" \
  +quit

# ---------- Copy steamclient .so ----------
log "Installing steamclient libraries..."
mkdir -p "/mnt/server/.steam/sdk32" "/mnt/server/.steam/sdk64"
if [[ -f "linux32/steamclient.so" ]]; then
  cp -v "linux32/steamclient.so" "/mnt/server/.steam/sdk32/steamclient.so"
else
  echo "[install][WARN] linux32/steamclient.so not found"
fi
if [[ -f "linux64/steamclient.so" ]]; then
  cp -v "linux64/steamclient.so" "/mnt/server/.steam/sdk64/steamclient.so"
else
  echo "[install][WARN] linux64/steamclient.so not found"
fi

# ---------- Node wrapper (required by your image) ----------
# Your image launches Node and expects /home/container/wrapper.js.
# We generate a small wrapper that expands {{TOKENS}} -> env and runs the final command via bash.
log "Writing wrapper.js for Node entrypoint..."
cat > /mnt/server/wrapper.js <<'JS'
const { spawn } = require('child_process');

function expandTokens(input) {
  // Replace {{VAR}} with the value from environment (falls back to empty string)
  return input.replace(/{{(\w+)}}/g, (_, k) => process.env[k] ?? '');
}

const raw = process.env.STARTUP && process.env.STARTUP.trim().length
  ? process.env.STARTUP
  : (process.argv.length > 2 ? process.argv.slice(2).join(' ') : '');

if (!raw) {
  console.error('[wrapper] No startup command provided via STARTUP env or argv.');
  process.exit(2);
}

const cmd = expandTokens(raw);
console.log('[wrapper] Executing:', cmd);

const child = spawn('/bin/bash', ['-lc', cmd], {
  stdio: 'inherit',
  env: process.env,
});

child.on('exit', (code, signal) => {
  if (signal) {
    console.error(`[wrapper] exited via signal ${signal}`);
    process.exit(128);
  }
  process.exit(code ?? 0);
});
JS
chmod +x /mnt/server/wrapper.js

# ---------- tools/wipe.sh (safe & portable) ----------
log "Installing tools/wipe.sh..."
mkdir -p /mnt/server/tools
cat > /mnt/server/tools/wipe.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: wipe.sh [map|blueprints|full] [--dry-run]
Default: map

Environment:
  SERVER_IDENTITY   Server identity name (default: rust)
  PRESERVE_DIRS     Comma-separated list of top-level items to keep during full wipe
                    (default: oxide,carbon,cfg,Configs,plugins,Carbon,oxide.config.json)
USAGE
}

IDENTITY="${SERVER_IDENTITY:-rust}"
ROOT="/mnt/server/server/${IDENTITY}"
TYPE="${1:-map}"
DRYRUN=0
[[ "${2:-}" == "--dry-run" ]] && DRYRUN=1

log(){ echo "[wipe] $*"; }

if [[ ! -d "$ROOT" ]]; then
  echo "[wipe] ERROR: server identity dir not found: $ROOT" >&2
  exit 1
fi

PRESERVE="${PRESERVE_DIRS:-oxide,carbon,cfg,Configs,plugins,Carbon,oxide.config.json}"
IFS=',' read -r -a PRES <<< "$PRESERVE"

should_preserve() {
  local base="$1"
  for d in "${PRES[@]}"; do
    [[ "$base" == "$d" ]] && return 0
  done
  return 1
}

rm_portable() {
  # BusyBox rm lacks --one-file-system; test and use if available
  if rm --help 2>&1 | grep -q -- '--one-file-system'; then
    rm -rf --one-file-system "$@"
  else
    rm -rf "$@"
  fi
}

delete_path() {
  local p="$1"
  if (( DRYRUN )); then
    log "DRY-RUN delete $p"
  else
    rm_portable "$p"
  fi
}

log "Starting wipe: type=$TYPE on $ROOT (preserve: ${PRESERVE})"

case "$TYPE" in
  map )
    if (( DRYRUN )); then
      find "$ROOT" -maxdepth 1 -type f \( -name '*.map' -o -name '*.sav' \) -print
    else
      find "$ROOT" -maxdepth 1 -type f \( -name '*.map' -o -name '*.sav' \) -print -delete
    fi
    ;;
  blueprints )
    if (( DRYRUN )); then
      find "$ROOT" -maxdepth 1 -type f -name 'blueprints.*.db' -print
    else
      find "$ROOT" -maxdepth 1 -type f -name 'blueprints.*.db' -print -delete
    fi
    ;;
  full )
    shopt -s nullglob
    for f in "$ROOT"/*; do
      base="$(basename "$f")"
      if should_preserve "$base"; then
        log "preserve $base"
        continue
      fi
      log "delete $base"
      delete_path "$f"
    done
    mkdir -p "$ROOT/cfg"
    ;;
  * )
    echo "[wipe] ERROR: unknown wipe type: $TYPE" >&2
    usage
    exit 2
    ;;
esac

log "Wipe complete."
EOF
chmod +x /mnt/server/tools/wipe.sh

log "Installation complete."
