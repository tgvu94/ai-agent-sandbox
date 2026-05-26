# eShopOnWeb multi-stage Dockerfile
#
# Stages
# ──────
#   toolchain  SDK + tools only. Used in demo mode — source cloned at runtime.
#   source     Adds git clone. Start of the CI pre-built pipeline.
#   deps       Adds dotnet restore. Cached until *.csproj / packages.lock changes.
#   builder    Adds dotnet build.
#   ci-test    Pre-built test image. Entrypoint skips clone/restore/build.
#   publish    Produces self-contained publish output for the runtime image.
#   runtime    Chiseled (distroless-equivalent) deploy image for ECS/EKS.
#
# Local demo mode (current default — source cloned at container start):
#   docker build --target toolchain -t eshop-runner .
#
# CI pre-built pipeline (build once, test/deploy many):
#   docker build --target ci-test -t localhost:5000/eshop:ci-test .
#   docker build --target runtime -t localhost:5000/eshop:latest  .
#   ./sandbox.sh eshop build-image
#
# Version note: eShopOnWeb's own src/Web/Dockerfile uses sdk:9.0 (stale — the
# project migrated to .NET 10 but never updated its Dockerfiles). global.json
# and all .csproj TargetFramework declarations require net10.0. Using sdk:9.0
# fails immediately with NETSDK1045.

# ── Stage 1: toolchain ───────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS toolchain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq python3 ca-certificates && rm -rf /var/lib/apt/lists/*
RUN dotnet tool install --global dotnet-ef \
    && dotnet tool install --global dotnet-format || true
ENV PATH="$PATH:/root/.dotnet/tools"
WORKDIR /sandbox
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

# ── Stage 2: source ──────────────────────────────────────────────────────────
FROM toolchain AS source
ARG REPO_URL=https://github.com/NimblePros/eShopOnWeb.git
WORKDIR /sandbox/workspace
RUN git clone --depth=1 "$REPO_URL" .

# ── Stage 3: deps ────────────────────────────────────────────────────────────
# Restore is cached until any .csproj or packages.lock.json changes.
FROM source AS deps
RUN dotnet restore eShopOnWeb.sln --verbosity minimal

# ── Stage 4: builder ─────────────────────────────────────────────────────────
FROM deps AS builder
RUN dotnet build eShopOnWeb.sln \
    --no-restore --configuration Release --verbosity minimal

# ── Stage 5: ci-test ─────────────────────────────────────────────────────────
# Pre-built test image pushed to the registry on each commit.
# SKIP_BUILD=1 tells the entrypoint to jump straight to dotnet test.
FROM builder AS ci-test
ENV SKIP_BUILD=1
COPY coverlet.runsettings /sandbox/eshop/coverlet.runsettings

# ── Stage 6: publish ─────────────────────────────────────────────────────────
FROM builder AS publish
RUN dotnet publish src/Web/Web.csproj \
    -c Release -o /app/publish --no-restore

# ── Stage 7: runtime ─────────────────────────────────────────────────────────
# Microsoft chiseled = Ubuntu stripped to only the .NET runtime + libc.
# No shell, no package manager — equivalent to distroless for .NET.
# Deploy target for ECS/EKS; ~100 MB vs ~900 MB for the SDK image.
#
# HEALTHCHECK: chiseled has no shell or curl, so the Docker HEALTHCHECK
# instruction cannot run tools inside the container. Health probing is handled
# externally — from the smoke test (build-image), the ECS target group HTTP
# probe, or a Kubernetes httpGet liveness probe. See README.
#
# Debugging: see README "Debugging minimal images" for ephemeral container
# and kubectl debug patterns.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS runtime
WORKDIR /app
COPY --from=publish /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Web.dll"]
