# Universal Rust server image for Pterodactyl (Vanilla / Oxide / Carbon)
# Pin a stable base to avoid surprise breakage
FROM cm2network/steamcmd:debian

LABEL org.opencontainers.image.title="rust-universal"
LABEL org.opencontainers.image.description="Universal Rust Dedicated Server image for Pterodactyl: Vanilla, Oxide/uMod, Carbon (production/edge/staging/minimal)."
LABEL maintainer="you@example.com"

# Install tini for clean signal handling + basic deps + Node (for wrapper)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl wget jq unzip tar xz-utils nodejs npm tini \
 && rm -rf /var/lib/apt/lists/*

# Pterodactyl-compatible user & dirs
RUN useradd -m -d /home/container -s /bin/bash container \
 && mkdir -p /home/container/steamcmd /home/container/.steam/sdk32 /home/container/.steam/sdk64 /home/container/bin \
 && chown -R container:container /home/container

WORKDIR /home/container

# Defaults (egg can override)
ENV FRAMEWORK=vanilla \
    FRAMEWORK_UPDATE=1 \
    VALIDATE=0 \
    TZ=UTC \
    HOME=/home/container

# Copy entrypoint and wrapper
COPY entrypoint.sh /entrypoint.sh
COPY wrapper.js /home/container/wrapper.js
RUN chmod +x /entrypoint.sh /home/container/wrapper.js \
 && chown -R container:container /home/container

# Wrapper dependency
RUN npm install --prefix /home/container --omit=dev ws@8

USER container

# Use tini to reap zombies and forward signals
ENTRYPOINT ["/usr/bin/tini","--","/entrypoint.sh"]
