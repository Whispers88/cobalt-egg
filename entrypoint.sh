#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Rust Dedicated Server entrypoint (no symlink), using /home/container
# ------------------------------------------------------------

export HOME=/home/container
cd /home/container

# --- helpers ---
log()     { echo -e "[entrypoint] $*"; }
Debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "[debug] $*"; }
Success() { echo -e "[  OK  ] $*"; }
Warn()    { echo -e "[warn]  $*"; }
Err()     { echo -e "[error] $*" >&2; }

# Niceties
ulimit -n 65535 || true
umask 002

# ------------------------------------------------------------
# SteamCMD preflight for /home/container layout
# ------------------------------------------------------------
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/steamapps \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64

chown -R "$(id -u)":"$(id -g)" /home/container || true
export STEAMCMDDIR=/home/container/steamcmd

# ------------------------------------------------------------
# Config / Environment
# ------------------------------------------------------------
CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"

SRCDS_APPID="${SRCDS_APPID:-258550}"
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"

FRAMEWORK="${FRAMEWORK:-vanilla}"          # vanilla | oxide | carbon* (carbon, carbon-edge, carbon-staging, etc.)
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"   # reserved, for compatibility
VALIDATE="${VALIDATE:-1}"                   # 1 to validate (recommended)
EXTRA_FLAGS="${EXTRA_FLAGS:-}"              # extra args for +app_update
STEAM_BRANCH="${STEAM_BRANCH:-}"            # branch name (optional)
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"  # branch password (optional)

STARTUP="${STARTUP:-}"                      # Pterodactyl STARTUP string from the panel

# Logging
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"
DEBUG="${DEBUG:-0}"                         # set DEBUG=1 to print expanded command
MASK_SECRETS="${MASK_SECRETS:-1}"           # mask obvious secrets in debug echo

# Optional public IP detection
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
have_oxide()  { [[ -d "/home/container/oxide" ]]; }
have_carbon() { [[ -d "/home/container/carbon" ]]; }

uninstall_oxide() {
  if have_oxide; then
    log "Removing Oxide/uMod files…"
    rm -rf /home/container/oxide || true
  fi
}

uninstall_carbon() {
  if have_carbon; then
    log "Removing Carbon files…"
    rm -f  /home/container/Carbon.targets || true
    rm -rf /home/container/doorstop_config || true
    rm -f  /home/container/winhttp.dll || true
    rm -rf /home/container/carbon || true
  fi
}

install_oxide() {
  log "Installing uMod (Oxide)…"
  local tmpdir
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null
  $CURL -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o oxide.zip -d /home/container
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Oxide install complete."
}

install_carbon() {
  local channel="production" minimal="0" url=""
  case "${FRAMEWORK}" in
    carbon-edge* )    channel="edge" ;;
    carbon-staging* ) channel="staging" ;;
    carbon-aux1* )    channel="aux1" ;;
    carbon-aux2* )    channel="aux2" ;;
    carbon* )         channel="production" ;;
  esac
  [[ "${FRAMEWORK}" == *"-minimal" ]] && minimal="1"

  log "Installing Carbon (channel=${channel}, minimal=${minimal})…"
  local tmpdir
  tmpdir="$(mktemp -d)"
  pushd "$tmpdir" >/dev/null

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

  [[ -z "${url}" ]] && { log "ERROR: Could not map Carbon artifact from FRAMEWORK='${FRAMEWORK}'"; exit 10; }

  $CURL "$url" -o carbon.tar.gz
  if [[ -n "${CARBON_SHA256:-}" ]]; then
    echo "${CARBON_SHA256}  carbon.tar.gz" | sha256sum -c -
  fi

  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmpdir"
  log "Carbon install complete."
}

steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if [[ -x "/home/container/steamcmd.sh" ]]; then echo "/home/container/steamcmd.sh"; return; fi
  if [[ -x "/home/steam/steamcmd/steamcmd.sh" ]]; then echo "/home/steam/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  if [[ -x "/usr/games/steamcmd" ]]; then echo "/usr/games/steamcmd"; return; fi
  echo ""
}

validate_now() {
  [[ "${VALIDATE}" != "1" ]] && { log "Skipping validation (VALIDATE=${VALIDATE})."; return; }

  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { log "ERROR: steamcmd not found!"; exit 11; }

  local BRANCH_FLAGS=""
  if [[ -n "$STEAM_BRANCH" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    if [[ -n "$STEAM_BRANCH_PASS" ]]; then
      BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
    fi
  fi

  log "Validating game files via SteamCMD (user=${STEAM_USER})…"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
  log "Validation complete."
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
case "${FRAMEWORK}" in
  vanilla)
    uninstall_oxide
    uninstall_carbon
    ;;
  oxide|uMod)
    uninstall_carbon
    validate_now
    install_oxide
    ;;
  carbon*)
    uninstall_oxide
    validate_now
    install_carbon
    ;;
  *)
    log "Unknown FRAMEWORK='${FRAMEWORK}', defaulting to vanilla."
    uninstall_oxide
    uninstall_carbon
    ;;
esac

# Ensure at least one validation if requested
validate_now

# ------------------------------------------------------------
# Expand Panel STARTUP: {{VAR}} -> ${VAR} then eval echo
# ------------------------------------------------------------
if [[ -z "${STARTUP}" ]]; then
  Err "No STARTUP command provided by panel."
  exit 12
fi

# Convert braces and expand with current environment.
# The printf layer protects existing quotes inside STARTUP.
MODIFIED_STARTUP="$(
  eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
)"

# Optional debug print (like yolks). Mask obvious secrets by default.
if [[ "${DEBUG}" == "1" ]]; then
  TO_SHOW="${MODIFIED_STARTUP}"
  if [[ "${MASK_SECRETS}" == "1" ]]; then
    # Mask +rcon.password "..." and -logfile "..."
    TO_SHOW="$(echo "${TO_SHOW}" \
      | sed -E 's/(\+rcon\.password\s+)"[^"]*"/\1"******"/g' \
      | sed -E 's/(-logfile\s+)"[^"]*"/\1"******"/g')"
  fi
  Debug ":/home/container$ ${TO_SHOW}"
fi
Success "Variables replaced!"

# ------------------------------------------------------------
# Launch via wrapper with expanded command
# (wrapper will run it under bash so [[ ]] / == / $() works)
# ------------------------------------------------------------
exec env LATEST_LOG="${LATEST_LOG}" /opt/node/bin/node /opt/cobalt/wrapper.js "${MODIFIED_STARTUP}"
