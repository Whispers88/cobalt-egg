#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Pterodactyl Rust entrypoint — panel-driven startup expansion
# ------------------------------------------------------------

cd /home/container

# Make internal Docker IP available to processes (like stock yolks)
export INTERNAL_IP="$(ip route get 1 | awk '{print $(NF-2); exit}')"

# Defaults (panel can override with Egg variables)
: "${SRCDS_APPID:=258550}"
: "${STEAM_USER:=anonymous}"
: "${STEAM_PASS:=}"
: "${STEAM_AUTH:=}"
: "${AUTO_UPDATE:=1}"
: "${FRAMEWORK:=vanilla}"     # vanilla | oxide | carbon* (carbon, carbon-edge, ...)
: "${UPDATE_CARBON:=0}"       # legacy toggle; treated equivalent to FRAMEWORK=carbon
: "${OXIDE:=0}"               # legacy toggle; treated equivalent to FRAMEWORK=oxide
: "${EXTRA_FLAGS:=}"          # extra flags for +app_update
: "${STEAM_BRANCH:=}"         # optional beta branch
: "${STEAM_BRANCH_PASS:=}"    # optional branch password

# Where SteamCMD caches live under /home/container
export STEAMCMDDIR="/home/container/steamcmd"

# Ensure directories exist & are writable on the mounted volume
mkdir -p \
  /home/container/Steam/package \
  /home/container/steamcmd \
  /home/container/steamapps \
  /home/container/.steam/sdk32 \
  /home/container/.steam/sdk64 || true
chown -R "$(id -u)":"$(id -g)" /home/container || true

# ------------------------------------------------------------
# Helper: find steamcmd
# ------------------------------------------------------------
steamcmd_path() {
  if [[ -x "/home/container/steamcmd/steamcmd.sh" ]]; then echo "/home/container/steamcmd/steamcmd.sh"; return; fi
  if [[ -x "/home/container/steamcmd.sh" ]]; then echo "/home/container/steamcmd.sh"; return; fi
  if [[ -x "/home/steam/steamcmd/steamcmd.sh" ]]; then echo "/home/steam/steamcmd/steamcmd.sh"; return; fi
  if command -v steamcmd >/dev/null 2>&1; then command -v steamcmd; return; fi
  if [[ -x "/usr/games/steamcmd" ]]; then echo "/usr/games/steamcmd"; return; fi
  echo ""
}

# ------------------------------------------------------------
# Auto update via SteamCMD (like stock yolks)
# ------------------------------------------------------------
if [[ -z "${AUTO_UPDATE}" || "${AUTO_UPDATE}" == "1" ]]; then
  SCMD="$(steamcmd_path)"
  if [[ -z "${SCMD}" ]]; then
    echo "ERROR: steamcmd not found; cannot update. (Check base image/egg.)"
    exit 11
  fi

  BRANCH_FLAGS=""
  if [[ -n "${STEAM_BRANCH}" ]]; then
    BRANCH_FLAGS="-beta ${STEAM_BRANCH}"
    if [[ -n "${STEAM_BRANCH_PASS}" ]]; then
      BRANCH_FLAGS="${BRANCH_FLAGS} -betapassword ${STEAM_BRANCH_PASS}"
    fi
  fi

  # Login tuple: allow anonymous or credentials + authcode if provided
  echo "Updating Rust Dedicated Server (appid=${SRCDS_APPID})..."
  "${SCMD}" +force_install_dir /home/container \
           +login "${STEAM_USER}" "${STEAM_PASS}" "${STEAM_AUTH}" \
           +app_update "${SRCDS_APPID}" ${BRANCH_FLAGS} ${EXTRA_FLAGS} \
           +quit
else
  echo "AUTO_UPDATE=0 — skipping game update."
fi

# ------------------------------------------------------------
# Expand Panel Start Command ({{VAR}} -> ${VAR} + eval echo)
# This lets Wings do the templating and we resolve envs here, too.
# ------------------------------------------------------------
if [[ -z "${STARTUP:-}" ]]; then
  echo "ERROR: STARTUP not provided by Panel."
  exit 12
fi

# Convert {{VAR}} → ${VAR} then expand using the current environment
MODIFIED_STARTUP="$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")"

# Show the command like stock yolks do (comment out to hide)
echo ":/home/container$ ${MODIFIED_STARTUP}"

# ------------------------------------------------------------
# Framework handling (Carbon/Oxide) — mirrors the style you posted
# ------------------------------------------------------------
CURL="curl -fSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 0"

install_carbon() {
  # Choose channel from FRAMEWORK: carbon, carbon-edge, carbon-staging, carbon-aux1, carbon-aux2
  local channel="production" minimal="0" url=""
  case "${FRAMEWORK}" in
    carbon-edge* )    channel="edge" ;;
    carbon-staging* ) channel="staging" ;;
    carbon-aux1* )    channel="aux1" ;;
    carbon-aux2* )    channel="aux2" ;;
    carbon* )         channel="production" ;;
  esac
  [[ "${FRAMEWORK}" == *"-minimal" ]] && minimal="1"

  echo "Updating Carbon (channel=${channel}, minimal=${minimal})..."
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
    TMP="$(mktemp -d)"
    pushd "$TMP" >/dev/null
    ${CURL} "${url}" -o carbon.tar.gz
    tar -xzf carbon.tar.gz -C /home/container
    popd >/dev/null
    rm -rf "$TMP"
    echo "Carbon updated."
    # Enable Doorstop for Carbon (like your sample)
    export DOORSTOP_ENABLED=1
    export DOORSTOP_TARGET_ASSEMBLY="$(pwd)/carbon/managed/Carbon.Preloader.dll"
    MODIFIED_STARTUP="LD_PRELOAD=$(pwd)/libdoorstop.so ${MODIFIED_STARTUP}"
  else
    echo "WARN: Could not determine Carbon URL for FRAMEWORK='${FRAMEWORK}'"
  fi
}

install_oxide() {
  echo "Updating uMod (Oxide)…"
  TMP="$(mktemp -d)"
  pushd "$TMP" >/dev/null
  # Generic "latest linux" URL maintained by uMod
  ${CURL} -o oxide.zip "https://umod.org/games/rust/download?build=linux"
  unzip -o -q oxide.zip -d /home/container
  # Optional: compiler (as in your sample)
  ${CURL} -o /home/container/Compiler.x86_x64 "https://assets.umod.org/compiler/Compiler.x86_x64" || true
  popd >/dev/null
  rm -rf "$TMP"
  echo "uMod updated."
}

# Decide framework action
if [[ "${FRAMEWORK}" == "carbon" || "${UPDATE_CARBON:-0}" == "1" || "${FRAMEWORK}" == carbon* ]]; then
  install_carbon
elif [[ "${OXIDE:-0}" == "1" || "${FRAMEWORK}" == "oxide" ]]; then
  install_oxide
# else vanilla → do nothing
fi

# ------------------------------------------------------------
# Runtime library path fix (as in your sample)
# ------------------------------------------------------------
export LD_LIBRARY_PATH="$(pwd)/RustDedicated_Data/Plugins/x86_64:$(pwd)"

# ------------------------------------------------------------
# Find wrapper (support either layout)
# ------------------------------------------------------------
WRAPPER="/opt/cobalt/wrapper.js"
[[ -f "/wrapper.js" ]] && WRAPPER="/wrapper.js"

# ------------------------------------------------------------
# Run the Server via Node wrapper (which will use bash)
# ------------------------------------------------------------
exec /opt/node/bin/node "${WRAPPER}" "${MODIFIED_STARTUP}"
