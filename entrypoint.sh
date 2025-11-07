#!/bin/bash
set -euo pipefail

export HOME=/home/container
cd /home/container || exit 1

log() { echo -e "[entrypoint] $*"; }

# Fix permissions (in case Pterodactyl mounts as root)
chown -R "$(id -u)" "$(pwd)" 2>/dev/null || true

# Increase file handles (avoid Rust IO errors)
ulimit -n 65535 || true
umask 002

#------------------------------------------------------------------------
# SteamCMD / Framework handling (Vanilla / Oxide / Carbon)
#------------------------------------------------------------------------

CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15"

SRCDS_APPID="${SRCDS_APPID:-258550}"
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"
VALIDATE="${VALIDATE:-1}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  echo ""
}

validate_now() {
  [[ "$VALIDATE" != "1" ]] && return

  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { log "ERROR: steamcmd not found"; exit 11; }

  local BRANCH_FLAGS=""
  [[ -n "$STEAM_BRANCH" ]] && BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"

  log "Validation started..."
  "$SCMD" +force_install_dir /home/container +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
    +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate +quit
  log "[ OK ] validation complete"
}

install_oxide() {
  log "Installing/Updating Oxide (uMod)..."
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  $CURL -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o oxide.zip -d /home/container >/dev/null
  popd >/dev/null
  rm -rf "$tmpdir"
  log "uMod install complete."
}

install_carbon() {
  log "Installing Carbon..."
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  $CURL -o carbon.tar.gz "https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Carbon installed."
}

case "$FRAMEWORK" in
  oxide|uMod) validate_now; install_oxide ;;
  carbon*)    validate_now; install_carbon ;;
  *)          validate_now ;;  # vanilla
esac

#------------------------------------------------------------------------
# STARTUP variable expansion (critical for Pterodactyl)
#------------------------------------------------------------------------

if [[ -z "${STARTUP:-}" ]]; then
  log "ERROR: No STARTUP command provided."
  exit 12
fi

MODIFIED_STARTUP=$(eval echo $(echo "$STARTUP" | sed -e 's/{{/${/g' -e 's/}}/}/g'))
MODIFIED_STARTUP="${MODIFIED_STARTUP#/entrypoint.sh }"

log "Launching via wrapper: $MODIFIED_STARTUP"

WRAPPER="/wrapper.js"
[[ ! -f "$WRAPPER" ]] && WRAPPER="/opt/cobalt/wrapper.js"
[[ ! -f "$WRAPPER" ]] && { echo "[entrypoint] ERROR: wrapper.js not found!"; exit 14; }

#------------------------------------------------------------------------
# Launch server (console streaming to Pterodactyl)
#------------------------------------------------------------------------
exec /opt/node/bin/node "$WRAPPER" "$MODIFIED_STARTUP"
