# Universal Rust server image for Pterodactyl (Vanilla / Oxide / Carbon)
FROM cm2network/steamcmd:latest

LABEL org.opencontainers.image.title="rust-universal"
LABEL org.opencontainers.image.description="Universal Rust Dedicated Server image for Pterodactyl: Vanilla, Oxide/uMod, Carbon."
LABEL maintainer="whispers88"

# Minimal OS deps only; keep apt surface tiny & resilient
RUN set -eux; \
    apt-get update -o Acquire::Retries=5; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl unzip xz-utils tar; \
    rm -rf /var/lib/apt/lists/*

# ---- tini (static) ----
# (Avoid apt: some bases don't ship tini or hit repo issues)
ADD https://github.com/krallin/tini/releases/download/v0.19.0/tini-amd64 /tini
RUN chmod +x /tini

# ---- Node.js (official binary) ----
ARG NODE_VERSION=20.17.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) node_arch="x64" ;; \
      aarch64) node_arch="arm64" ;; \
      *) echo "Unsupported arch: $arch" && exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tzx; \
    mkdir -p /opt/node; \
    tar -xJf /tmp/node.tzx -C /opt/node --strip-components=1; \
    ln -s /opt/node/bin/node /usr/local/bin/node; \
    ln -s /opt/node/bin/npm  /usr/local/bin/npm; \
    rm -f /tmp/node.tzx

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

# Files from your repo
COPY entrypoint.sh /entrypoint.sh
COPY wrapper.js /home/container/wrapper.js
RUN chmod +x /entrypoint.sh /home/container/wrapper.js \
 && chown -R container:container /home/container

# Wrapper dependency (local install; avoids global npm perms)
RUN npm install --prefix /home/container --omit=dev ws@8

USER container

# tini for clean signal handling
ENTRYPOINT ["/tini","--","/entrypoint.sh"]
