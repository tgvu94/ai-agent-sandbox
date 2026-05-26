#!/usr/bin/env bash
# eShopOnWeb sandbox entrypoint
# Modes (set via SANDBOX_MODE env var):
#   test  — restore, build, run all test suites, emit results.json  (default)
#   up    — restore, build, run migrations + seed, start the web server
#   build — restore + build only (fast feedback loop)
set -euo pipefail

SANDBOX_MODE="${SANDBOX_MODE:-test}"
OUTPUT_DIR="${SANDBOX_OUTPUT_DIR:-/sandbox-output}"
REPO_URL="https://github.com/NimblePros/eShopOnWeb.git"
WORKSPACE="/sandbox/workspace"

mkdir -p "$OUTPUT_DIR"

# ── Logging helpers ──────────────────────────────────────────────────────────
log()  { echo "[$(date -u +%T)] $*"; }
fail() { log "FATAL: $*"; exit 1; }

# ── Phase runner: times each step, streams log, writes JSONL ─────────────────
PHASES_FILE="$OUTPUT_DIR/phases.jsonl"
> "$PHASES_FILE"

run_phase() {
    local name="$1"; shift
    local log_file="$OUTPUT_DIR/${name}.log"
    local start; start=$(date +%s%3N)
    local status="success"

    log "==> Phase: $name"
    local exit_code=0
    "$@" 2>&1 | tee "$log_file" || exit_code=$?
    [[ $exit_code -eq 0 ]] || status="failed"

    local end; end=$(date +%s%3N)
    local duration=$(( end - start ))

    printf '{"phase":"%s","status":"%s","duration_ms":%d}\n' \
        "$name" "$status" "$duration" >> "$PHASES_FILE"

    if [[ "$status" == "failed" ]]; then
        fail "Phase '$name' failed. Logs: $log_file"
    fi
}

# ── Source acquisition ────────────────────────────────────────────────────────
acquire_workspace() {
    if [[ -n "${USE_MOUNTED_WORKSPACE:-}" && -d "/workspace-host" ]]; then
        log "Using mounted workspace at /workspace-host"
        cp -r /workspace-host "$WORKSPACE"
    else
        log "Cloning $REPO_URL (demo mode)"
        git clone --depth=1 "$REPO_URL" "$WORKSPACE"
    fi
}

if [[ ! -d "$WORKSPACE" ]]; then
    run_phase "clone" acquire_workspace
fi

cd "$WORKSPACE"

# ── Mode: build only ──────────────────────────────────────────────────────────
# SKIP_BUILD=1: set by the ci-test Docker stage — workspace + compiled artifacts
# are already baked into the image, so clone/restore/build are redundant.
SKIP_BUILD="${SKIP_BUILD:-}"

do_build() {
    if [[ -n "$SKIP_BUILD" ]]; then
        log "Skipping restore/build — using pre-built image artifacts"
        return
    fi
    run_phase "restore" dotnet restore eShopOnWeb.sln --verbosity minimal
    run_phase "build"   dotnet build   eShopOnWeb.sln \
        --no-restore --configuration Release --verbosity minimal
}

# ── Mode: test ────────────────────────────────────────────────────────────────
# Unit/integration/functional tests use EF Core in-memory — no SQL Server needed.
# PublicApiIntegrationTests also uses in-memory via WebApplicationFactory.
# We capture TRX (VSTest XML) for structured parsing.
#
# Set COLLECT_COVERAGE=1 to also collect line/branch coverage via Coverlet.
# Requires coverlet.collector in test projects (eShopOnWeb ships it).
# Coverage roughly doubles test time; keep it off for fast agent iteration loops.
do_test() {
    do_build

    TESTS_DIR="$OUTPUT_DIR/test-results"
    mkdir -p "$TESTS_DIR"

    local coverage_args=()
    if [[ -n "${COLLECT_COVERAGE:-}" ]]; then
        # --settings scopes coverage to hand-written application code only:
        # excludes EF migrations, model snapshots, and test assemblies from
        # the denominator so the % reflects actual testable code.
        coverage_args=(
            --collect "XPlat Code Coverage"
            --settings /sandbox/eshop/coverlet.runsettings
        )
    fi

    run_phase "test" dotnet test eShopOnWeb.sln \
        --no-build --configuration Release \
        --results-directory "$TESTS_DIR" \
        --logger "trx;LogFileName=results.trx" \
        --logger "console;verbosity=normal" \
        "${coverage_args[@]}"

    # Parse TRX → $OUTPUT_DIR/test-summary.json
    if command -v python3 &>/dev/null && [[ -f "$TESTS_DIR/results.trx" ]]; then
        python3 - "$TESTS_DIR/results.trx" "$OUTPUT_DIR/test-summary.json" <<'EOF'
import sys, xml.etree.ElementTree as ET, json

trx, out = sys.argv[1], sys.argv[2]
root = ET.parse(trx).getroot()
ns = {'t': 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010'}
c = root.find('.//t:ResultSummary/t:Counters', ns)
summary = {
    'total':   int(c.get('total', 0)),
    'passed':  int(c.get('passed', 0)),
    'failed':  int(c.get('failed', 0)),
    'skipped': int(c.get('notExecuted', 0)),
}
with open(out, 'w') as f:
    json.dump(summary, f)
print("Tests:", json.dumps(summary))
EOF
    fi

    # Parse Cobertura XML → $OUTPUT_DIR/coverage-summary.json
    if [[ -n "${COLLECT_COVERAGE:-}" ]] && command -v python3 &>/dev/null; then
        python3 - "$TESTS_DIR" "$OUTPUT_DIR/coverage-summary.json" <<'EOF'
import sys, xml.etree.ElementTree as ET, json, glob

tests_dir, out = sys.argv[1], sys.argv[2]
files = glob.glob(f"{tests_dir}/**/*.cobertura.xml", recursive=True)
if not files:
    print("No coverage XML found — is coverlet.collector installed in test projects?")
    sys.exit(0)
root = ET.parse(files[0]).getroot()
coverage = {
    "collected":    True,
    "lines_pct":    round(float(root.get("line-rate",   0)) * 100, 1),
    "branches_pct": round(float(root.get("branch-rate", 0)) * 100, 1),
}
with open(out, 'w') as f:
    json.dump(coverage, f)
print("Coverage:", json.dumps(coverage))
EOF
    fi
}

# ── Mode: up (run the application) ───────────────────────────────────────────
# EF Core auto-migrates + seeds on startup via SeedDatabaseAsync().
# SQL Server must be healthy before this runs (enforced by depends_on).
do_up() {
    do_build

    run_phase "run" dotnet run \
        --project src/Web/Web.csproj \
        --no-build --configuration Release \
        --urls "http://+:8080"
}

# ── Emit final result JSON ─────────────────────────────────────────────────────
finalize() {
    local overall="${1:-success}"
    if ! command -v python3 &>/dev/null; then
        echo '{"project":"eshop","overall_status":"'"$overall"'","note":"python3 unavailable, phases in phases.jsonl"}' \
            | tee "$OUTPUT_DIR/result.json"
        return
    fi
    python3 - "$PHASES_FILE" "$OUTPUT_DIR/result.json" "$overall" "$OUTPUT_DIR" <<'EOF'
import sys, json, os

phases_file, out_file, overall, output_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

phases = []
with open(phases_file) as f:
    for line in f:
        line = line.strip()
        if line:
            phases.append(json.loads(line))

result = {"project": "eshop", "overall_status": overall, "phases": phases}

summary_file = os.path.join(output_dir, "test-summary.json")
if os.path.exists(summary_file):
    with open(summary_file) as f:
        result["tests"] = json.load(f)

coverage_file = os.path.join(output_dir, "coverage-summary.json")
if os.path.exists(coverage_file):
    with open(coverage_file) as f:
        result["coverage"] = json.load(f)
else:
    result["coverage"] = {"collected": False}

with open(out_file, 'w') as f:
    json.dump(result, f, indent=2)
print(json.dumps(result, indent=2))
EOF
}

trap 'finalize failed' ERR

case "$SANDBOX_MODE" in
    test)  do_test ;;
    up)    do_up   ;;
    build) do_build ;;
    *)     fail "Unknown SANDBOX_MODE: $SANDBOX_MODE. Use: test|up|build" ;;
esac

finalize success
