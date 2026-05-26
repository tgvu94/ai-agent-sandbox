# Medplum multi-stage Dockerfile
#
# Stages
# ──────
#   toolchain  Node 24 + tools only. Used in demo mode — source cloned at runtime.
#   source     Adds git clone. Start of the CI pre-built pipeline.
#   deps       Adds npm ci. Cached until package-lock.json changes.
#   builder    Adds turbo build (server + all workspace deps).
#   ci-test    Pre-built test image. Entrypoint skips clone/install/build.
#   prod-deps  npm ci --omit=dev for the runtime image layer.
#   stripped   Removes src/test dirs from packages/ to keep runtime image lean.
#   runtime    Alpine deploy image for ECS/EKS.
#
# CI pre-built pipeline:
#   ./sandbox.sh medplum build-image
#
# Runtime image note:
# Medplum is an npm workspace monorepo. node_modules/@medplum/* entries are
# symlinks (e.g. @medplum/core → ../../packages/core). The runtime image
# preserves these by copying both node_modules (symlinks intact) and the
# packages/ dist outputs that the symlinks resolve to.
#
# For a production-grade minimal image, run `npx turbo prune @medplum/server`
# to generate a standalone tree with only server + its workspace deps, then
# use gcr.io/distroless/nodejs24-debian12 as the final base. See README.

# ── Stage 1: toolchain ───────────────────────────────────────────────────────
FROM node:24-slim AS toolchain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq python3 ca-certificates && rm -rf /var/lib/apt/lists/*
RUN npm install -g turbo@latest
WORKDIR /sandbox
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

# ── Stage 2: source ──────────────────────────────────────────────────────────
FROM toolchain AS source
ARG REPO_URL=https://github.com/medplum/medplum.git
WORKDIR /sandbox/workspace
RUN git clone --depth=1 "$REPO_URL" .

# ── Stage 3: deps ────────────────────────────────────────────────────────────
# npm ci is cached until package-lock.json changes.
FROM source AS deps
RUN npm ci

# ── Stage 4: builder ─────────────────────────────────────────────────────────
FROM deps AS builder
RUN npx turbo run build \
    --filter=@medplum/server \
    --filter='!@medplum/docs' \
    --filter='!./examples/*' \
    --concurrency=4

# ── Stage 5: ci-test ─────────────────────────────────────────────────────────
# Pre-built test image. Config files are baked in so the entrypoint's
# install_config() can copy them to the workspace without a volume mount.
FROM builder AS ci-test
ENV SKIP_BUILD=1
COPY medplum.config.json /sandbox/medplum.config.json
COPY test.config.json    /sandbox/test.config.json

# ── Stage 6: prod-deps ───────────────────────────────────────────────────────
# Production-only node_modules (no jest, typescript, etc.)
FROM source AS prod-deps
RUN npm ci --omit=dev

# ── Stage 7: stripped ────────────────────────────────────────────────────────
# Remove source and test dirs from packages/ before copying into runtime image.
# Multi-stage means the deletions actually reduce the final image size.
FROM builder AS stripped
RUN find /sandbox/workspace/packages -maxdepth 2 -type d \
        \( -name "src" -o -name "test" -o -name "__tests__" -o -name ".turbo" \) \
        | xargs -r rm -rf

# ── Stage 8: runtime ─────────────────────────────────────────────────────────
# Alpine for small footprint. node_modules symlinks (@medplum/* → packages/*)
# resolve correctly because packages/ is copied alongside node_modules.
#
# Upgrade path to distroless: replace this base with
# gcr.io/distroless/nodejs24-debian12 and use `turbo prune` — see README.
FROM node:24-alpine AS runtime
WORKDIR /app
RUN addgroup -S medplum && adduser -S medplum -G medplum
COPY --from=stripped  /sandbox/workspace/packages    ./packages
COPY --from=prod-deps /sandbox/workspace/node_modules ./node_modules
COPY --from=builder   /sandbox/workspace/package.json .
USER medplum
EXPOSE 8103
# Alpine includes wget — use it for the in-container health probe.
# ECS/K8s should configure an HTTP liveness probe on GET /healthcheck.
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=6 \
    CMD wget -qO- http://localhost:8103/healthcheck | grep -q '"ok":true' || exit 1
CMD ["node", "packages/server/dist/index.js"]
