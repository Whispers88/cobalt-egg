# --- Stage 1: fetch node + tini in an isolated builder ---
FROM debian:bookworm-slim AS fetch
ARG NODE_VERSION=20.17.0

RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils tar; \
  rm -rf /var/lib/apt/lists/*

# tini (init)
RUN curl -fsSL -o /tini https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 \
 && chmod +x /tini

# official NodeJS binaries
RUN arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) node_arch="x64" ;; \
    arm64) node_arch="arm64" ;; \
    *) echo "Unsupported arch: $arch" && exit 1 ;; \
  esac; \
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz; \
  mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
  rm -f /tmp/node.tar.xz


# --- Stage 2: runtime using cm2network/steamcmd base ---
FROM cm2network/steamcmd:latest

USER root

LABEL org.opencontainers.image.title="rust-universal-nosymlink"
LABEL org.opencontainers.image.description="Rust Dedicated Server image for Pterodactyl using /mnt/server directly (no symlink)."
LABEL maintainer="you@example.com"

# copy tools
COPY --from=fetch /tini /tini
COPY --from=fetch /opt/node /opt/node

# ensure Node is available
ENV PATH="/opt/node/bin:${PATH}"

# runtime deps needed by entrypoint (unzip important for uMod/Carbon)
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unzip ca-certificates curl tzdata iproute2; \
  rm -rf /var/lib/apt/lists/*

# create run user whose home is /mnt/server (matches Wings mount)
RUN set -eux; \
  if command -v useradd >/dev/null 2>&1; then \
    useradd -d /mnt/server -m -U -s /bin/bash container || true; \
  else \
    adduser -D -h /mnt/server -s /bin/sh container || true; \
  fi

# app bits live inside image (not in /mnt/server)
# we keep wrapper + its node deps under /opt/cobalt so they exist even if /mnt/server is empty
RUN mkdir -p /opt/cobalt
COPY wrapper.js /opt/cobalt/wrapper.js
COPY entrypoint.sh /entrypoint.sh

# install wrapper dependency
RUN npm install --prefix /opt/cobalt --omit=dev ws@8

# perms
RUN chmod +x /entrypoint.sh /opt/cobalt/wrapper.js

# Ptero-friendly defaults (match runtime use of /mnt/server)
ENV HOME=/mnt/server \
    FRAMEWORK=vanilla \
    FRAMEWORK_UPDATE=1 \
    VALIDATE=1 \
    TZ=UTC

# IMPORTANT: run in /mnt/server directly
WORKDIR /mnt/server

# drop privileges
USER container

# tini → bash entrypoint
ENTRYPOINT ["/tini","--","/entrypoint.sh"]
