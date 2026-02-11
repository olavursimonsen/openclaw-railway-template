# Build openclaw from source to avoid npm packaging gaps
FROM node:22-bookworm AS openclaw-build

# Build deps needed for openclaw build (add retries)
RUN apt-get update -o Acquire::Retries=5 \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
     ca-certificates \
     curl \
     build-essential \
     git \
     python3 \
  && rm -rf /var/lib/apt/lists/*

# Bun (openclaw build uses it) + retries
RUN (curl -fsSL https://bun.sh/install | bash) \
  || (sleep 2 && curl -fsSL https://bun.sh/install | bash) \
  || (sleep 5 && curl -fsSL https://bun.sh/install | bash)

ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for extensions
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

# Runtime deps + tailscale (apt retries + tailscale retries)
RUN apt-get update -o Acquire::Retries=5 \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
    ca-certificates \
    curl \
    procps \
    iptables \
    iproute2 \
    openssh-client \
    netcat-openbsd \
  && rm -rf /var/lib/apt/lists/* \
  && (curl -fsSL https://tailscale.com/install.sh | sh) \
     || (sleep 2 && curl -fsSL https://tailscale.com/install.sh | sh) \
     || (sleep 5 && curl -fsSL https://tailscale.com/install.sh | sh)

WORKDIR /app

RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile && pnpm store prune

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/start.sh"]