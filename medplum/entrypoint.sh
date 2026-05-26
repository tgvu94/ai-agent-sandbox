#!/usr/bin/env bash
# Medplum sandbox entrypoint
# Modes (SANDBOX_MODE env var):
#   build — install + build only                   (fastest feedback)
#   up    — build, start server, verify health check, exit
#   test  — build, run server unit tests that don't need live DB  (default)
set -euo pipefail

SANDBOX_MODE="${SANDBOX_MODE:-build}"
OUTPUT_DIR="${SANDBOX_OUTPUT_DIR:-/sandbox-output}"
REPO_URL="https://github.com/medplum/medplum.git"
WORKSPACE="/sandbox/workspace"

mkdir -p "$OUTPUT_DIR"

log()  { echo "[$(date -u +%T)] $*"; }
fail() { log "FATAL: $*"; exit 1; }

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
    printf '{"phase":"%s","status":"%s","duration_ms":%d}\n' \
        "$name" "$status" $(( end - start )) >> "$PHASES_FILE"

    [[ "$status" == "success" ]] || fail "Phase '$name' failed. Logs: $log_file"
}

# ── Source acquisition ────────────────────────────────────────────────────────
acquire_workspace() {
    if [[ -n "${USE_MOUNTED_WORKSPACE:-}" && -d "/workspace-host" ]]; then
        log "Using mounted workspace"
        cp -r /workspace-host "$WORKSPACE"
    else
        log "Cloning $REPO_URL (demo mode) — this takes a few minutes"
        git clone --depth=1 "$REPO_URL" "$WORKSPACE"
    fi
}

if [[ ! -d "$WORKSPACE" ]]; then
    run_phase "clone" acquire_workspace
fi

cd "$WORKSPACE"

# ── Install + build ───────────────────────────────────────────────────────────
# SKIP_BUILD=1: set by the ci-test Docker stage — workspace + compiled artifacts
# are already baked into the image, so install/build are redundant.
SKIP_BUILD="${SKIP_BUILD:-}"

do_install() {
    run_phase "install" npm ci --prefer-offline
}

do_build() {
    if [[ -n "$SKIP_BUILD" ]]; then
        log "Skipping install/build — using pre-built image artifacts"
        return
    fi
    do_install
    run_phase "build" npx turbo run build \
        --filter=@medplum/server \
        --filter='!@medplum/docs' \
        --filter='!./examples/*' \
        --concurrency=4
}

# ── Config setup ─────────────────────────────────────────────────────────────
install_config() {
    # The server loads medplum.config.json from CWD before applying env overrides.
    # Tests (jest) also load it from CWD when running from packages/server.
    # test.config.json is loaded by src/index.test.ts via main('file:test.config.json').
    # We install both config files in both locations.
    local cfg=/sandbox/medplum.config.json
    local test_cfg=/sandbox/test.config.json
    if [[ -f "$cfg" ]]; then
        cp "$cfg" "$WORKSPACE/medplum.config.json"
        cp "$cfg" "$WORKSPACE/packages/server/medplum.config.json"
        log "Config installed to workspace root and packages/server"
    fi
    if [[ -f "$test_cfg" ]]; then
        cp "$test_cfg" "$WORKSPACE/packages/server/test.config.json"
        log "test.config.json installed to packages/server"
    fi
}

# ── Mode: up (start the server) ───────────────────────────────────────────────
# Migrations run automatically on startup via initApp().
# Health check: GET /healthcheck returns {"ok":true,...}
do_up() {
    do_build
    install_config

    # Start server in background so we can health-check it
    log "Starting Medplum server..."
    node packages/server/dist/index.js &
    local SERVER_PID=$!

    # Poll health check — server runs migrations on first boot
    log "Waiting for server to become healthy (migrations may take 30s)..."
    local retries=60
    local healthy=false
    while (( retries-- > 0 )); do
        if curl -sf http://localhost:8103/healthcheck > /dev/null 2>&1; then
            healthy=true
            break
        fi
        # Check server hasn't crashed
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            fail "Server process died before becoming healthy"
        fi
        sleep 2
    done

    if [[ "$healthy" == "false" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        fail "Server did not become healthy within 120s"
    fi

    log "Server is healthy"
    curl -s http://localhost:8103/healthcheck | jq . | tee "$OUTPUT_DIR/healthcheck.json"

    # Record the start phase as success
    printf '{"phase":"start","status":"success","duration_ms":0}\n' >> "$PHASES_FILE"

    # Graceful shutdown
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

# ── Mode: test ────────────────────────────────────────────────────────────────
# Medplum's loadTestConfig() reads POSTGRES_HOST and POSTGRES_PORT (not the
# MEDPLUM_DATABASE_* vars) to override the test database connection. Both env
# vars are set in docker-compose.yml so tests connect to "postgres:5432".
#
# loadTestConfig() also forces dbname="medplum_test", so the initdb SQL
# script must have created that database (handled by initdb/01-test-db.sql).
#
# Set COLLECT_COVERAGE=1 to enable Istanbul coverage via Jest --coverage.
# Coverage instrumentation roughly doubles the ~9 min test run; keep it off
# for fast agent iteration loops and on for CI/PR reporting.
do_test() {
    do_build
    install_config

    TESTS_DIR="$OUTPUT_DIR/test-results"
    mkdir -p "$TESTS_DIR"

    # Seed the test database — sets up FHIR resources + admin account.
    # loadTestConfig() enables runMigrations=true for this one test.
    run_phase "seed" npx turbo run test:seed \
        --filter=@medplum/server

    local coverage_args=()
    if [[ -n "${COLLECT_COVERAGE:-}" ]]; then
        coverage_args=(
            --coverage
            --coverageReporters json-summary
            --coverageDirectory "$OUTPUT_DIR/coverage"
        )
    fi

    # NODE_OPTIONS: extra heap prevents SIGKILL on memory-hungry suites
    # --maxWorkers=2: limits Jest parallelism; reduces peak RSS
    # --concurrency=1: Turbo runs only one package at a time
    run_phase "test" env NODE_OPTIONS="--max-old-space-size=4096" \
        npx turbo run test \
        --filter=@medplum/server \
        --concurrency=1 \
        -- --maxWorkers=2 "${coverage_args[@]}"

    # Parse Jest stdout → $OUTPUT_DIR/test-summary.json
    #
    # Why findall + last, not search:
    # Turbo treats test:seed as a dependency of test, so `npx turbo run test`
    # re-runs test:seed inside this phase. test.log therefore contains two Jest
    # summaries: seed first ("1 passed, 1 total"), full suite last ("225 passed").
    # re.search returns the first match (seed). Taking the last match is correct.
    if command -v python3 &>/dev/null && [[ -f "$OUTPUT_DIR/test.log" ]]; then
        python3 - "$OUTPUT_DIR/test.log" "$OUTPUT_DIR/test-summary.json" <<'EOF'
import sys, re, json

log_file, out = sys.argv[1], sys.argv[2]
text = open(log_file).read()

all_suites = re.findall(r'Test Suites:\s+(?:(\d+) failed,\s*)?(\d+) passed,\s*(\d+) total', text)
all_tests  = re.findall(r'Tests:\s+(?:(\d+) failed,\s*)?(?:(\d+) skipped,\s*)?(\d+) passed,\s*(\d+) total', text)

summary = {}
if all_suites:
    s = all_suites[-1]   # last = final Jest summary, not test:seed summary
    summary['suites'] = {'failed': int(s[0] or 0), 'passed': int(s[1]), 'total': int(s[2])}
if all_tests:
    t = all_tests[-1]
    summary['tests']  = {'failed': int(t[0] or 0), 'skipped': int(t[1] or 0),
                         'passed': int(t[2]), 'total': int(t[3])}
with open(out, 'w') as f:
    json.dump(summary, f)
print("Tests:", json.dumps(summary))
EOF
    fi

    # Parse Istanbul coverage-summary.json → $OUTPUT_DIR/coverage-summary.json
    if [[ -n "${COLLECT_COVERAGE:-}" ]] && command -v python3 &>/dev/null; then
        python3 - "$OUTPUT_DIR/coverage/coverage-summary.json" "$OUTPUT_DIR/coverage-summary.json" <<'EOF'
import sys, json, os

src, out = sys.argv[1], sys.argv[2]
if not os.path.exists(src):
    print("No coverage-summary.json found")
    sys.exit(0)
with open(src) as f:
    raw = json.load(f)
t = raw.get("total", {})
coverage = {
    "collected":      True,
    "lines_pct":      t.get("lines",      {}).get("pct", 0),
    "branches_pct":   t.get("branches",   {}).get("pct", 0),
    "functions_pct":  t.get("functions",  {}).get("pct", 0),
    "statements_pct": t.get("statements", {}).get("pct", 0),
}
with open(out, 'w') as f:
    json.dump(coverage, f)
print("Coverage:", json.dumps(coverage))
EOF
    fi
}

# ── Result aggregation ────────────────────────────────────────────────────────
finalize() {
    local overall="${1:-success}"
    python3 - "$PHASES_FILE" "$OUTPUT_DIR/result.json" "$overall" "$OUTPUT_DIR" <<'EOF'
import sys, json, os

phases_file, out_file, overall, output_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

phases = []
with open(phases_file) as f:
    for line in f:
        line = line.strip()
        if line:
            phases.append(json.loads(line))

result = {"project": "medplum", "overall_status": overall, "phases": phases}

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
    build) do_build ;;
    up)    do_up    ;;
    test)  do_test  ;;
    *)     fail "Unknown SANDBOX_MODE: $SANDBOX_MODE. Use: build|up|test" ;;
esac

finalize success
