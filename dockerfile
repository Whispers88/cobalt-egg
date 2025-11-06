# --- Stage 1: fetch tools (node + tini) in an isolated builder ---
FROM debian:bookworm-slim AS fetch
ARG NODE_VERSION=20.17.0

RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl xz-utils tar; \
  rm -rf /var/lib/apt/lists/*

# tini
RUN curl -fsSL -o /tini https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 && chmod +x /tini

# node (official binaries)
RUN arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) node_arch="x64" ;; \
    arm64) node_arch="arm64" ;; \
    *) echo "Unsupported arch: $arch" && exit 1 ;; \
  esac; \
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz; \
  mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
  rm -f /tmp/node.tar.xz

# --- Stage 2: final runtime on top of cm2network/steamcmd (no apt here) ---
FROM cm2network/steamcmd:latest

# Ensure we are root in this stage (cm2network images may set a non-root default user)
USER root

LABEL org.opencontainers.image.title="rust-universal"
LABEL org.opencontainers.image.description="Universal Rust Dedicated Server image for Pterodactyl: Vanilla, Oxide/uMod, Carbon."
LABEL maintainer="you@example.com"

# Copy tools fetched in stage 1
COPY --from=fetch /tini /tini
COPY --from=fetch /opt/node /opt/node

# Put Node on PATH (avoid fragile symlinks)
ENV PATH="/opt/node/bin:${PATH}"

# Pterodactyl-compatible user & dirs
# - Use /bin/sh (always present); use /bin/bash when available
# - Use useradd when available (Debian/Ubuntu/RHEL), else fall back to adduser (BusyBox/Alpine)
RUN set -eux; \
  sh_path="/bin/sh"; \
  if [ -x /bin/bash ]; then sh_path="/bin/bash"; fi; \
  if command -v useradd >/dev/null 2>&1; then \
    if ! id -u container >/dev/null 2>&1; then \
      useradd -m -U -d /home/container -s "$sh_path" container; \
    fi; \
  else \
    # BusyBox/Alpine-style adduser
    if ! id -u container >/dev/null 2>&1; then \
      adduser -D -h /home/container -s "$sh_path" container || true; \
    fi; \
  fi; \
  mkdir -p /home/container/steamcmd /home/container/.steam/sdk32 /home/container/.steam/sdk64 /home/container/bin; \
  chown -R container:container /home/container

WORKDIR /home/container

# Defaults (overridden by egg)
ENV FRAMEWORK=vanilla \
    FRAMEWORK_UPDATE=1 \
    VALIDATE=0 \
    TZ=UTC \
    HOME=/home/container

# App files
COPY entrypoint.sh /entrypoint.sh
COPY wrapper.js /home/container/wrapper.js
RUN chmod +x /entrypoint.sh /home/container/wrapper.js \
 && chown -R container:container /home/container

# Wrapper dependency (local install)
RUN npm install --prefix /home/container --omit=dev ws@8

# Drop privileges for runtime
USER container

# Use tini for clean signals; entrypoint does framework logic then calls wrapper
ENTRYPOINT ["/tini","--","/entrypoint.sh"]
