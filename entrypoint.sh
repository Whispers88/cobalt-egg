#!/bin/bash
set -euo pipefail

# ============================================================
# Rust Dedicated Server entrypoint (Pterodactyl)
# - Console-first (Unity stdin/stdout)
# - Panel variables supported via args or $STARTUP
# ============================================================

export HOME=/home/container
cd /home/container

# ---------- helpers ----------
log()      { echo -e "[entrypoint] $*"; }
Debug()    { [[ "${DEBUG:-0}" == "1" ]] && echo -e "[debug] $*"; }
Success()  { echo -e "[  OK  ] $*"; }
Warn()     { echo -e "[warn]  $*"; }
Err()      { echo -e "[error] $*" >&2; }

# niceties
ulimit -n 65535 || true
umask 002

# provide INTERNAL_IP like stock yolks
export INTERNAL_IP="$(ip route get 1 | awk '{print $(NF-2); exit}')"

# ---------- directories Steam expects under /home/container ----------
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/steamapps \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64 || true

# ensure writable (mounted volume)
chown -R "$(id -u)":"$(id -g)" /home/container || true

# put steamcmd cache here (nice to have)
export STEAMCMDDIR=/home/container/steamcmd

# ---------- config & defaults (panel can override) ----------
: "${SRCDS_APPID:=258550}"

: "${STEAM_USER:=anonymous}"
: "${STEAM_PASS:=}"
: "${STEAM_AUTH:=}"

: "${AUTO_UPDATE:=0}"        # 1 = run app_update (classic yolk style)
: "${VALIDATE:=0}"           # 1 = validate files
: "${EXTRA_FLAGS:=}"         # extra flags for +app_update
: "${STEAM_BRANCH:=}"        # optional beta branch
: "${STEAM_BRANCH_PASS:=}"   # optional branch password

: "${FRAMEWORK:=vanilla}"    # vanilla | oxide | carbon* (carbon, carbon-edge, carbon-*-minimal, ...)
: "${FRAMEWORK_UPDATE:=1}"   # reserved compatibility flag

# wrapper logging
export LATEST_LOG="${LATEST_LOG:-/home/container/latest.log}"
: "${DEBUG:=0}"              # set to 1 to print expanded command
: "${MASK_SECRETS:=1}"       # mask +rcon.password etc when DEBUG=1

# optional public IP (let panel override)
if [[ -z "${APP_PUBLIC_IP:-}" ]]; then
  APP_PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  export APP_PUBLIC_IP
fi

# ---------- steamcmd locator ----------
steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if [[ -x "/home/container/steamcmd.sh" ]]; then echo "/home/container/steamcmd.sh"; return; fi
  if [[ -x "/home/steam/steamcmd/steamcmd.sh" ]]; then echo "/home/steam/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  if [[ -x "/usr/games/steamcmd" ]]; then echo "/usr/games/steamcmd"; return; fi
  echo ""
}

# ---------- update/validate ----------
do_app_update() {
  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { Err "steamcmd not found"; exit 11; }

  local BRANCH_FLAGS=""
  if [[ -n "$STEAM_BRANCH" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
  fi

  log "Running SteamCMD app_update (appid=${SRCDS_APPID})…"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} \
         +quit
  Success "app_update complete"
}

do_validate() {
  local SCMD; SCMD="$(steamcmd_path)"
  [[ -z "$SCMD" ]] && { Err "steamcmd not found"; exit 11; }

  local BRANCH_FLAGS=""
  if [[ -n "$STEAM_BRANCH" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    [[ -n "$STEAM_BRANCH_PASS" ]] && BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
  fi

  log "Validating files via SteamCMD…"
  "$SCMD" +force_install_dir /home/container \
         +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
         +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} validate \
         +quit
  Success "validation complete"
}

# AUTO_UPDATE first (optional), then VALIDATE if requested
[[ "${AUTO_UPDATE}" == "1" ]] && do_app_update
[[ "${VALIDATE}"   == "1" ]] && do_validate

# ---------- framework installers ----------
CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"

install_oxide() {
  log "Installing/Updating uMod (Oxide)…"
  local tmp; tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  $CURL -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o -q oxide.zip -d /home/container
  # optional compiler (non-fatal if it fails)
  $CURL -o /home/container/Compiler.x86_x64 "https://assets.umod.org/compiler/Compiler.x86_x64" || true
  popd >/dev/null
  rm -rf "$tmp"
  Success "Oxide installed"
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

  if [[ -n "${url}" ]]; then
    local tmp; tmp="$(mktemp -d)"
    pushd "$tmp" >/dev/null
    $CURL "${url}" -o carbon.tar.gz
    tar -xzf carbon.tar.gz -C /home/container
    popd >/dev/null
    rm -rf "$tmp"
    Success "Carbon installed"
    # Doorstop env (Carbon)
    export DOORSTOP_ENABLED=1
    export DOORSTOP_TARGET_ASSEMBLY="$(pwd)/carbon/managed/Carbon.Preloader.dll"
  else
    Warn "Could not resolve Carbon URL for FRAMEWORK='${FRAMEWORK}'"
  fi
}

# Decide framework action
case "${FRAMEWORK}" in
  vanilla) : ;;  # nothing
  oxide|uMod) install_oxide ;;
  carbon* )    install_carbon ;;
  *) Warn "Unknown FRAMEWORK='${FRAMEWORK}', continuing vanilla";;
esac

# Rust runtime library path quirk
export LD_LIBRARY_PATH="$(pwd)/RustDedicated_Data/Plugins/x86_64:$(pwd)"

# ============================================================
# Resolve startup command:
# - If panel passed args to /entrypoint.sh, use those (already {{}}-expanded by Wings)
# - Else, expand $STARTUP by converting {{VAR}} -> ${VAR} and eval echo
# ============================================================

MODIFIED_STARTUP=""

if [[ "$#" -gt 0 ]]; then
  MODIFIED_STARTUP="$*"
  Debug "Using Start Command args from panel (already expanded by Wings)."
else
  if [[ -z "${STARTUP:-}" ]]; then
    Err "No startup provided: neither Start Command args nor STARTUP env found."
    exit 12
  fi
  # Convert {{VAR}} → ${VAR} and expand using current env. Keep quoting intact.
  MODIFIED_STARTUP="$(
    eval "echo \"$(printf '%s' "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')\""
  )"
  Debug "Expanded command from \$STARTUP using sed+eval."
fi

# Optional debug echo (mask secrets by default)
if [[ "${DEBUG}" == "1" ]]; then
  TO_SHOW="${MODIFIED_STARTUP}"
  if [[ "${MASK_SECRETS}" == "1" ]]; then
    TO_SHOW="$(echo "${TO_SHOW}" \
      | sed -E 's/(\+rcon\.password\s+)"[^"]*"/\1"******"/g' \
      | sed -E 's/(-logfile\s+)"[^"]*"/\1"******"/g')"
  fi
  Debug ":$(pwd)$ ${TO_SHOW}"
fi
Success "Startup variables resolved!"

# ============================================================
# Launch the server via Node wrapper (console mode wrapper)
# - Wrapper should run under bash and mirror stdout/stderr
# - If using -logfile, use the tailing wrapper variant
# ============================================================

WRAPPER="/opt/cobalt/wrapper.js"
[[ -f "/wrapper.js" ]] && WRAPPER="/wrapper.js"

exec env LATEST_LOG="${LATEST_LOG}" /opt/node/bin/node "${WRAPPER}" "${MODIFIED_STARTUP}"
