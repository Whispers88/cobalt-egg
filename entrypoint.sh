#!/bin/bash
set -euo pipefail

# =======================================================================
# Rust Dedicated Server entrypoint for Pterodactyl (console-first)
# - Works from /home/container
# - Quote-safe handling of Start Command args (preserves spaces)
# - Supports Vanilla / Oxide / Carbon
# - Validates via SteamCMD (optional)
# - Launches via wrapper.js which mirrors logfile to panel
# =======================================================================

export HOME=/home/container
cd /home/container || exit 1

log() { echo -e "[entrypoint] $*"; }
err() { echo -e "[entrypoint][error] $*" >&2; }

# niceties
ulimit -n 65535 || true
umask 002

# best-effort ownership fix (harmless if not needed)
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

FRAMEWORK="${FRAMEWORK:-vanilla}"      # vanilla | oxide | carbon* (edge/staging/auxX, *-minimal)
VALIDATE="${VALIDATE:-1}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

# wrapper log destination (wrapper writes raw logs here)
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"

# optional convenience IP (panel can override)
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# -----------------------------------------------------------------------
# Update / validate
# -----------------------------------------------------------------------
do_validate() {
  [[ "${VALIDATE}" != "1" ]] && return 0
  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { err "steamcmd not found"; exit 11; }

  local BRANCH_FLAGS=""
  [[ -n "$STEAM_BRANCH" ]] && BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
  [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"

  log "Validating game files via SteamCMD…"
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

  if [[ -z "${url}" ]]; then
    err "Could not determine Carbon artifact for FRAMEWORK='${FRAMEWORK}'"
    exit 10
  fi

  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  curl -fSL --retry 5 -o carbon.tar.gz "${url}"
  tar -xzf carbon.tar.gz -C /home/container
  popd >/dev/null
  rm -rf "$tmp"
  log "Carbon install complete."
}

# run chosen framework steps
case "${FRAMEWORK}" in
  oxide|uMod) do_validate; install_oxide ;;
  carbon*  ) do_validate; install_carbon ;;
  *        ) do_validate ;;  # vanilla
esac

# -----------------------------------------------------------------------
# Build final startup command (QUOTE-SAFE)
# Supports:
#   - Layout A: panel Start Command passes args (/entrypoint.sh ./RustDedicated …)
#   - Layout B: panel STARTUP env holds the templated string
# -----------------------------------------------------------------------
MODIFIED_STARTUP=""

if [[ "$#" -gt 0 ]]; then
  # Rebuild one string from original args, preserving spaces/quotes
  MODIFIED_STARTUP="$(printf '%q ' "$@")"
  MODIFIED_STARTUP="${MODIFIED_STARTUP% }"   # trim trailing space
else
  # STARTUP env expansion: convert {{VAR}} → ${VAR} and expand safely
  if [[ -z "${STARTUP:-}" ]]; then
    err "No startup provided: neither Start Command args nor STARTUP env found."
    exit 12
  fi
  MODIFIED_STARTUP="$(
    eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
  )"
fi

# Strip accidental recursion if someone included /entrypoint.sh in STARTUP
if [[ "${MODIFIED_STARTUP}" == /entrypoint.sh* ]]; then
  log "Note: stripping leading '/entrypoint.sh' from startup string"
  MODIFIED_STARTUP="${MODIFIED_STARTUP#/entrypoint.sh }"
fi

# Ensure the Rust binary exists & is executable
if [[ -f "./RustDedicated" && ! -x "./RustDedicated" ]]; then
  chmod +x ./RustDedicated || true
fi
if [[ ! -f "./RustDedicated" ]]; then
  err "RustDedicated not found in $(pwd). Did app_update install to /home/container?"
  err "Set VALIDATE=1 (or enable AUTO_UPDATE in your egg) and try again."
  exit 13
fi

log "Launching via wrapper…"

# pick wrapper path (either location is fine)
WRAPPER="/wrapper.js"
[[ -f "$WRAPPER" ]] || WRAPPER="/opt/cobalt/wrapper.js"
if [[ ! -f "$WRAPPER" ]]; then
  err "wrapper.js not found at /wrapper.js or /opt/cobalt/wrapper.js"
  exit 14
fi

# -----------------------------------------------------------------------
# Launch through the console-wrapper (which mirrors logfile to panel)
# -----------------------------------------------------------------------
exec /opt/node/bin/node "${WRAPPER}" "${MODIFIED_STARTUP}"
