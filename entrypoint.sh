#!/bin/bash
set -euo pipefail
export HOME=/home/container
cd /home/container

log() { echo -e "[entrypoint] $*"; }

# Preflight niceties
ulimit -n 65535 || true
umask 002

CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"
SRCDS_APPID="${SRCDS_APPID:-258550}"
STEAM_USER="${STEAM_USER:-anonymous}"
STEAM_PASS="${STEAM_PASS:-}"
STEAM_AUTH="${STEAM_AUTH:-}"
FRAMEWORK="${FRAMEWORK:-vanilla}"
FRAMEWORK_UPDATE="${FRAMEWORK_UPDATE:-1}"
VALIDATE="${VALIDATE:-1}"   # <- default to 1; we *always* validate below
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
STEAM_BRANCH="${STEAM_BRANCH:-}"
STEAM_BRANCH_PASS="${STEAM_BRANCH_PASS:-}"

# Auto-detect app public IP if blank (optional convenience)
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# Helpers to detect presence
have_oxide()  { [[ -d "/home/container/oxide" ]]; }
have_carbon() { [[ -d "/home/container/carbon" ]]; }

uninstall_oxide() {
  if have_oxide; then
    log "Removing Oxide (validation will restore vanilla files)…"
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
  log "Installing / updating Oxide (uMod)…"
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

  log "Installing / updating Carbon (channel=${channel}, minimal=${minimal})…"
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

  [[ -z "${url}" ]] && { log "ERROR: Could not map Carbon artifact URL from FRAMEWORK='${FRAMEWORK}'"; exit 10; }
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
  # common locations in Ptero images
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then
    echo "/home/container/steamcmd/steamcmd.sh"
  elif [[ -x "/home/container/steamcmd.sh" ]]; then
    echo "/home/container/steamcmd.sh"
  else
    echo ""
  fi
}

validate_now() {
  # We ALWAYS validate before any mod install.
  local SCMD; SCMD="$(steamcmd_path)"
  if [[ -z "$SCMD" ]]; then
    log "ERROR: steamcmd not found in container; cannot validate."
    exit 11
  fi

  local BRANCH_FLAGS=""
  if [[ -n "$STEAM_BRANCH" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    if [[ -n "$STEAM_BRANCH_PASS" ]]; then
      BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
    fi
  fi

  log "Validating game files via steamcmd (user=${STEAM_USER})…"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
  log "Validation complete."
}

# -----------------------------
#
