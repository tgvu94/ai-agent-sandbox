#!/usr/bin/env bash
# AI Agent Sandbox — main orchestrator
#
# Usage:
#   ./sandbox.sh <project> <command> [options]
#
# Projects:  eshop | medplum | all
# Commands:
#   build         Build only — fastest feedback loop
#   test          Build + run test suite (or use pre-built CI image if available)
#   up            Build + start app stack + verify health checks, then exit
#   reset         Destroy app-layer volumes for clean state (preserves dep caches)
#   down          Tear down the stack completely
#   logs          Follow container logs
#   result        Print the last structured result from /sandbox-output/result.json
#   build-image   Mock CI step: build ci-test image and push to local registry
#
# Registry commands (shared local registry on localhost:5000):
#   ./sandbox.sh registry start|stop|ps|ls
#
# Using a pre-built CI image (Workflow B):
#   Images are built and pushed by CI — the agent only pulls and runs tests.
#   APP_VERSION, BUILD_BRANCH, and BUILD_SHA identify the image to pull:
#     APP_VERSION=1.2.3 BUILD_BRANCH=main BUILD_SHA=abcdef ./sandbox.sh eshop test
#   If the image exists locally, install/build are skipped automatically.
#
# Agent mode: mount a workspace instead of cloning (Workflow A):
#   WORKSPACE_PATH=/path/to/repo USE_MOUNTED_WORKSPACE=1 \
#     ./sandbox.sh eshop test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT="${1:-}"
COMMAND="${2:-}"

# Default registry — local during development, overridden in CI
REGISTRY="${REGISTRY:-localhost:5000}"

# Versioning
# APP_VERSION    — semver (M.n.p). Set from the git tag or a VERSION file in CI.
#                  Defaults to "0.0.0" so untagged local builds are visibly not releases.
# BUILD_SHA      — short git SHA, auto-detected.
# BUILD_BRANCH   — sanitized branch name. Auto-detected from git; in CI detached-HEAD
#                  mode, falls back to GITHUB_REF_NAME / CI_COMMIT_BRANCH env vars.
#                  Sanitization: lowercase, slashes→dashes, non-alphanum→dash, max 30 chars.
# IMAGE_VERSION  — the combined tag for every image produced by build-image:
#                    1.2.3-main-abcdef  ← dev build, immutable, traceable to branch+commit
#                  Promotion (push, release branch only) additionally adds:
#                    1.2.3              ← "this SHA is the official 1.2.3 release"
#                    latest             ← convenience pointer, never used in infra code
APP_VERSION="${APP_VERSION:-0.0.0}"
BUILD_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"
BUILD_BRANCH="${BUILD_BRANCH:-$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
# In CI, git checkout leaves a detached HEAD — fall back to the CI env var
[[ "$BUILD_BRANCH" == "HEAD" ]] && BUILD_BRANCH="${GITHUB_REF_NAME:-${CI_COMMIT_BRANCH:-HEAD}}"
# Sanitize: lowercase, slashes→dashes, any remaining non-[a-z0-9._-]→dash, collapse runs, max 30 chars
BUILD_BRANCH="$(printf '%s' "$BUILD_BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/' '-' | sed 's/[^a-z0-9._-]/-/g; s/-\{2,\}/-/g' | cut -c1-30)"
IMAGE_VERSION="${APP_VERSION}-${BUILD_BRANCH}-${BUILD_SHA}"

# Resolve WORKSPACE_PATH to absolute before any cd — docker compose resolves
# relative bind-mount paths relative to the compose file, not the caller's cwd.
if [[ -n "${WORKSPACE_PATH:-}" ]]; then
    WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" 2>/dev/null && pwd)" || {
        echo "Error: WORKSPACE_PATH '${WORKSPACE_PATH}' does not exist" >&2
        exit 1
    }
    export WORKSPACE_PATH
fi

usage() {
    sed -n '4,35p' "$0" | sed 's/^# \?//'
    exit 1
}

[[ -z "$PROJECT" || -z "$COMMAND" ]] && usage

COLOR_RESET="\033[0m"
COLOR_CYAN="\033[36m"
COLOR_GREEN="\033[32m"
COLOR_RED="\033[31m"

log()         { echo "[$(date -u +%T)] $*"; }
log_section() { echo -e "${COLOR_CYAN}>>> $*${COLOR_RESET}"; }
log_ok()      { echo -e "${COLOR_GREEN}✓ $*${COLOR_RESET}"; }
log_err()     { echo -e "${COLOR_RED}✗ $*${COLOR_RESET}" >&2; }

# ── Registry ──────────────────────────────────────────────────────────────────
run_registry() {
    local cmd="$1"
    local compose_file="$SCRIPT_DIR/registry/docker-compose.yml"
    case "$cmd" in
        start)
            docker compose -f "$compose_file" up -d
            log_ok "Registry running at localhost:5000"
            ;;
        stop)
            docker compose -f "$compose_file" down
            log_ok "Registry stopped"
            ;;
        ps|status)
            docker compose -f "$compose_file" ps
            ;;
        ls|list)
            local catalog
            catalog=$(curl -sf http://localhost:5000/v2/_catalog 2>/dev/null) \
                || { log_err "Registry unreachable — run: ./sandbox.sh registry start"; exit 1; }
            echo "$catalog" | jq -r '.repositories[]' | while read -r repo; do
                local tags
                tags=$(curl -sf "http://localhost:5000/v2/${repo}/tags/list" 2>/dev/null \
                    | jq -r '.tags // [] | sort | .[]')
                echo "${repo}:"
                if [[ -z "$tags" ]]; then
                    echo "  (no tags)"
                else
                    echo "$tags" | sed 's/^/  /'
                fi
            done
            ;;
        *)
            log_err "Unknown registry command: $cmd. Use: start|stop|ps|ls"
            exit 1
            ;;
    esac
}

# ── CI image build (mock) ─────────────────────────────────────────────────────
# Builds the ci-test and runtime images and pushes both to the local registry.
# Simulates what CI would do — run this once to seed the registry so that
# subsequent `test` runs skip install/build and use the pre-built image.
build_ci_image() {
    local name="$1"
    local context="$2"
    local test_tag="${REGISTRY}/${name}:${IMAGE_VERSION}-test"
    local runtime_tag="${REGISTRY}/${name}:${IMAGE_VERSION}"

    log_section "${name}: building ci-test image (${test_tag})"
    docker build --target ci-test -t "$test_tag" "$context"

    log_section "${name}: building runtime image (${runtime_tag})"
    docker build --target runtime -t "$runtime_tag" "$context"

    log_section "${name}: pushing to local registry"
    if ! docker push "$test_tag"; then
        log_err "Push failed — is the local registry running? Start with: ./sandbox.sh registry start"
        exit 1
    fi
    docker push "$runtime_tag"

    local test_size runtime_size
    test_size=$(docker image inspect "$test_tag"    --format '{{.Size}}' | awk '{printf "%.0fMB", $1/1024/1024}')
    runtime_size=$(docker image inspect "$runtime_tag" --format '{{.Size}}' | awk '{printf "%.0fMB", $1/1024/1024}')
    log_ok "ci-test image : ${test_tag} (${test_size})"
    log_ok "runtime image : ${runtime_tag} (${runtime_size})"
    log_ok "version       : ${IMAGE_VERSION}"
    log_ok "Run './sandbox.sh ${name} test' to use this image (install/build skipped)."
}

# Run compose using a pre-built image if one exists in the local registry;
# fall back to building from the Dockerfile otherwise.
compose_up() {
    local project="$1"    # eshop or medplum
    local runner="$2"     # service name
    local mode="$3"       # SANDBOX_MODE value
    local ci_image="${REGISTRY}/${project}:${IMAGE_VERSION}-test"

    if docker image inspect "$ci_image" >/dev/null 2>&1; then
        log_section "Pre-built image found (${ci_image}) — skipping install/build"
        CI_IMAGE="$ci_image" SKIP_BUILD=1 \
            SANDBOX_MODE="$mode" docker compose up \
                --no-build --abort-on-container-exit \
                --exit-code-from "$runner"
    else
        SANDBOX_MODE="$mode" docker compose up \
            --build --abort-on-container-exit \
            --exit-code-from "$runner"
    fi
}

# ── eShopOnWeb ────────────────────────────────────────────────────────────────
run_eshop() {
    local cmd="$1"
    log_section "eShopOnWeb: $cmd"
    cd "$SCRIPT_DIR/eshop"

    case "$cmd" in
        up|test|build)
            compose_up eshop eshop-runner "$cmd"
            ;;
        build-image)
            build_ci_image eshop "$SCRIPT_DIR/eshop"
            ;;
        reset)
            docker compose down --remove-orphans
            docker volume rm -f eshop_eshop-sqlserver-data \
                               eshop_sandbox-output 2>/dev/null || true
            log_ok "eShopOnWeb state reset. NuGet cache preserved."
            ;;
        down)
            docker compose down --remove-orphans
            ;;
        logs)
            docker compose logs -f
            ;;
        result)
            docker compose run --rm --no-deps --entrypoint cat eshop-runner \
                /sandbox-output/result.json 2>/dev/null \
                || echo '{"error": "no result found — run test first"}'
            ;;
        *)
            log_err "Unknown command: $cmd"
            exit 1
            ;;
    esac
}

# ── Medplum ───────────────────────────────────────────────────────────────────
run_medplum() {
    local cmd="$1"
    log_section "Medplum: $cmd"
    cd "$SCRIPT_DIR/medplum"

    case "$cmd" in
        up|test|build)
            compose_up medplum medplum-runner "$cmd"
            ;;
        build-image)
            build_ci_image medplum "$SCRIPT_DIR/medplum"
            ;;
        reset)
            docker compose down --remove-orphans
            docker volume rm -f medplum_medplum-postgres-data \
                               medplum_medplum-redis-data \
                               medplum_sandbox-output 2>/dev/null || true
            log_ok "Medplum state reset. npm cache preserved."
            ;;
        down)
            docker compose down --remove-orphans
            ;;
        logs)
            docker compose logs -f
            ;;
        result)
            docker compose run --rm --no-deps --entrypoint cat medplum-runner \
                /sandbox-output/result.json 2>/dev/null \
                || echo '{"error": "no result found — run test first"}'
            ;;
        *)
            log_err "Unknown command: $cmd"
            exit 1
            ;;
    esac
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$PROJECT" in
    eshop)    run_eshop   "$COMMAND" ;;
    medplum)  run_medplum "$COMMAND" ;;
    registry) run_registry "$COMMAND" ;;
    all)
        run_eshop   "$COMMAND"
        run_medplum "$COMMAND"
        ;;
    *)
        log_err "Unknown project: $PROJECT. Use: eshop | medplum | all | registry"
        exit 1
        ;;
esac
