# --- Stage 1: fetch node + tini ---
FROM debian:bookworm-slim AS fetch
ARG NODE_VERSION=22.11.0

RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils tar; \
  rm -rf /var/lib/apt/lists/*

# tini (init: reaps zombies, forwards signals)
RUN curl -fsSL -o /tini https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 \
 && chmod +x /tini

# official Node binaries — >=22 has a native WebSocket client, so the wrapper
# is zero-dependency and there is no npm install stage at all
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) node_arch="x64" ;; \
    arm64) node_arch="arm64" ;; \
    *) echo "Unsupported arch: $arch" && exit 1 ;; \
  esac; \
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz; \
  mkdir -p /opt/node; \
  tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
  rm -f /tmp/node.tar.xz


# --- Stage 2: runtime on cm2network/steamcmd ---
FROM cm2network/steamcmd:latest

USER root

LABEL org.opencontainers.image.title="cobalt-egg"
LABEL org.opencontainers.image.description="Cobalt 2.0 — Rust Dedicated Server image for Pterodactyl: version pin/rollback, wipe management, logfile+WebRCON console."
LABEL org.opencontainers.image.source="https://github.com/Whispers88/cobalt-egg"

COPY --from=fetch /tini /tini
COPY --from=fetch /opt/node /opt/node

ENV PATH="/opt/node/bin:${PATH}"
ENV NODE_ENV=production

# runtime deps: unzip/tar for frameworks, curl for downloads, iproute2 for the
# port preflight. (2.0 dropped gdb+procps — .stack/.heap are gone.)
RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    unzip ca-certificates curl tzdata iproute2; \
  rm -rf /var/lib/apt/lists/*; \
  useradd -m -d /home/container -s /bin/bash container || true

COPY entrypoint.sh /entrypoint.sh
COPY wrapper.js /opt/cobalt/wrapper.js
RUN chmod +x /entrypoint.sh

ENV HOME=/home/container \
    FRAMEWORK=vanilla \
    AUTO_UPDATE=1 \
    FRAMEWORK_UPDATE=1 \
    VALIDATE=0 \
    TZ=UTC

WORKDIR /home/container

USER container

ENTRYPOINT ["/tini","--","/entrypoint.sh"]
