# fetch node + tini
FROM debian:bookworm-slim AS fetch
ARG NODE_VERSION=20.17.0
ARG TINI_VERSION=0.19.0

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates curl xz-utils tar gnupg; \
  rm -rf /var/lib/apt/lists/*

# tini 
RUN set -eux; \
  curl -fsSL -o /tini "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-amd64"; \
  curl -fsSL -o /tini.sha256 "https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini-amd64.sha256sum"; \
  sha256sum -c /tini.sha256; \
  chmod +x /tini

# NodeJS (verify)
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in amd64) node_arch="x64" ;; arm64) node_arch="arm64" ;; *) echo "Unsupported arch: $arch" && exit 1 ;; esac; \
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o /tmp/SHASUMS256.txt; \
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz; \
  (cd /tmp && grep " node-v${NODE_VERSION}-linux-${node_arch}.tar.xz\$" SHASUMS256.txt | sha256sum -c -); \
  mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
  rm -f /tmp/node.tar.xz /tmp/SHASUMS256.txt


# runtime using cm2network/steamcmd base
FROM cm2network/steamcmd:latest

USER root

LABEL org.opencontainers.image.title="Cobalt-Rust-Pterodactly-Egg" \
      org.opencontainers.image.description="Rust Dedicated Server image for Pterodactyl" \
      org.opencontainers.image.source="cobaltstudios" \
      maintainer="cobaltstudios"

# Copy tools
COPY --from=fetch /tini /tini
COPY --from=fetch /opt/node /opt/node

# Node environment
ENV PATH="/opt/node/bin:${PATH}" \
    NODE_ENV=production \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# Runtime deps (unzip for uMod/Carbon)
ARG DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends unzip ca-certificates curl tzdata iproute2 bash; \
  rm -rf /var/lib/apt/lists/*

# Ensure app dirs exist and are writable by steam
ENV HOME=/mnt/server
RUN set -eux; \
  mkdir -p /opt/cobalt /mnt/server /mnt/server/steamcmd /mnt/server/logs; \
  chown -R steam:steam /opt/cobalt /mnt/server

# Keep wrapper deps inside image
COPY --chown=steam:steam wrapper.js /opt/cobalt/wrapper.js
COPY --chown=steam:steam entrypoint.sh /entrypoint.sh

# Install wrapper dependencys
RUN set -eux; \
  npm install --prefix /opt/cobalt --omit=dev ws@8; \
  npm cache clean --force >/dev/null 2>&1 || true

# Permissions
RUN set -eux; \
  chmod +x /entrypoint.sh /tini; \
  ln -sfn /mnt/server/steamcmd /home/steam/steamcmd || true; \
  chown -h steam:steam /home/steam/steamcmd

# Ptero-friendly defaults
ENV FRAMEWORK=vanilla \
    FRAMEWORK_UPDATE=1 \
    VALIDATE=1 \
    TZ=UTC \
    STEAMCMDDIR=/mnt/server/steamcmd

WORKDIR /mnt/server

# Drop privileges to 'steam' (matches base image expectations)
USER steam

# tini - bash entrypoint
ENTRYPOINT ["/tini","--","/entrypoint.sh"]
