#!/bin/bash
set -euo pipefail

# =======================================================================
# Rust Dedicated Server entrypoint for Pterodactyl
# Console-first (Unity Console), no RCON required
# - Handles Carbon / Oxide / Vanilla
# - SteamCMD validate / branch support
# - Expands Pterodactyl variables from {{VAR}}
# - Launches via wrapper.js (which mirrors logfile to console)
# =======================================================================

export HOME=/home/container
cd /home/container

log()   { echo -e "[entrypoint] $*"; }

# Allow high open files (Rust needs this)
ulimit -n 65535 || true
umask 002

# -----------------------------------------------------------------------
# SteamCMD directory layout (Rust MUST be installed here for Wings)
# -----------------------------------------------------------------------
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/steamapps \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64

# Fix perms for mounted filesystem
chown -R "$(id -u):$(id -g)" /home/container || true

# Where SteamCMD should store cache
export STEAMCMDDIR=/home/container/steamcmd

# -----------------------------------------------------------------------
# Read config / env (panel variables)
# -----------------------------------------------------------------------
SRCDS_APPID="${SRCDS_APPID:-258550}"
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"      # vanilla | oxide | carbon* variants
VALIDATE="${VALIDATE:-1}"              # validation is good for rust
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"

STARTUP="${STARTUP:-}"                  # Optional; panel may pass args instead

# Log file used by wrapper
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# Detect public IP if available
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# -----------------------------------------------------------------------
# Framework helpers
# -----------------------------------------------------------------------
have_oxide()  { [[ -d "/home/container/oxide" ]]; }
have_carbon() { [[ -d "/home/container/carbon" ]]; }

install_oxide() {
  log "Installing / updating Oxide (uMod)…"
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o oxide.zip -d /home/container
  popd >/dev/null
  rm -rf "$tmp"
}

install_carbon() {
  log "Installing / updating Carbon…"
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null

  # Choose correct build
  case "${FRAMEWORK}" in
    carbon-edge*) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Edge.tar.gz" ;;
    carbon-staging*) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Staging.tar.gz" ;;
    carbon-aux1*) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux1.tar.gz" ;;
    carbon-aux2*) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Aux2.tar.gz" ;;
    carbon*) url="https://github.com/Carbon-Modding/Carbon.Core/releases/latest/download/Carbon.Linux.Release.tar.gz" ;;
    *) url="" ;;
  esac

  [[ -z "$url" ]] && { log "Carbon channel not detected"; exit 10; }

  curl -fSL --retry 5 -o carbon.tar.gz "$url"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmp"
}

validate_game() {
  [[ "${VALIDATE}" != "1" ]] && return 0

  local BRANCH_FLAGS=""
  [[ -n "$STEAM_BRANCH" ]] && BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"

  log "Validating Rust via SteamCMD..."
  /home/container/steamcmd/steamcmd.sh \
    +force_install_dir /home/container \
    +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
    +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
    +quit
  log "[ OK ] validation complete"
}

# -----------------------------------------------------------------------
# Framework selection
# -----------------------------------------------------------------------
case "${FRAMEWORK}" in
  vanilla) ;;
  oxide|uMod)
    validate_game
    install_oxide
    ;;
  carbon*)
    validate_game
    install_carbon
    ;;
  *)
    log "Unknown FRAMEWORK=${FRAMEWORK}, defaulting to vanilla"
    ;;
esac

# -----------------------------------------------------------------------
# Build STARTUP command
# Supports:
#   ✅ Start Command passes args (/entrypoint.sh ./RustDedicated ...)
#   ✅ STARTUP env contains {{VAR}} (egg style)
# -----------------------------------------------------------------------
MODIFIED_STARTUP=""

if [[ "$#" -gt 0 ]]; then
  # Panel Start Command puts everything after /entrypoint.sh here
  MODIFIED_STARTUP="$*"
else
  # STARTUP env from egg -> convert {{VAR}} into ${VAR}
  if [[ -z "${STARTUP}" ]]; then
    log "ERROR: No startup command provided."
    exit 12
  fi

  MODIFIED_STARTUP="$(
    eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
  )"
fi

log "Launching via wrapper: ${MODIFIED_STARTUP}"

# -----------------------------------------------------------------------
# Start Rust through wrapper.js (console mode)
# -----------------------------------------------------------------------
exec /opt/node/bin/node /wrapper.js "${MODIFIED_STARTUP}"
