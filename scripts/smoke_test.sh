#!/usr/bin/env bash
#
# Ligi CLI Smoke Tests
#
# This script compiles ligi and runs smoke tests against the binary.
# All tests run in an isolated temp directory that is cleaned up on exit.
#
# Usage:
#   ./scripts/smoke_test.sh           # Run all tests
#   ./scripts/smoke_test.sh -v        # Verbose output
#   ./scripts/smoke_test.sh -k        # Keep temp directory on failure
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Build failed

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIGI_BIN="$PROJECT_ROOT/zig-out/bin/ligi"

# Options
VERBOSE=false
KEEP_ON_FAIL=false

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -k|--keep)
            KEEP_ON_FAIL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-v|--verbose] [-k|--keep] [-h|--help]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose   Show detailed test output"
            echo "  -k, --keep      Keep temp directory on test failure"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_verbose() {
    if $VERBOSE; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Cleanup function
cleanup() {
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        if [[ $TESTS_FAILED -gt 0 ]] && $KEEP_ON_FAIL; then
            log_warn "Keeping temp directory for inspection: $TEST_TMPDIR"
        else
            log_verbose "Cleaning up temp directory: $TEST_TMPDIR"
            rm -rf "$TEST_TMPDIR"
        fi
    fi

    # Also clean up the global index entries we created
    local global_index="$HOME/.ligi/art/index/ligi_global_index.md"
    if [[ -f "$global_index" ]]; then
        # Remove any test entries (paths containing our temp dir pattern)
        if grep -q "smoke_test_" "$global_index" 2>/dev/null; then
            log_verbose "Cleaning smoke test entries from global index"
            grep -v "smoke_test_" "$global_index" > "$global_index.tmp" && mv "$global_index.tmp" "$global_index"
        fi
    fi
}

trap cleanup EXIT

# Test assertion helpers
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-values should be equal}"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-should contain substring}"

    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "  String does not contain: $needle"
        echo "  In: $haystack"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-should not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    else
        echo "  String should not contain: $needle"
        echo "  In: $haystack"
        return 1
    fi
}

assert_file_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        return 0
    else
        echo "  File does not exist: $path"
        return 1
    fi
}

assert_dir_exists() {
    local path="$1"
    if [[ -d "$path" ]]; then
        return 0
    else
        echo "  Directory does not exist: $path"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"

    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  Expected exit code: $expected"
        echo "  Actual exit code:   $actual"
        return 1
    fi
}

# Run a single test
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    log_verbose "Running: $test_name"

    if $test_func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$test_name"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$test_name"
        return 1
    fi
}

# ============================================================================
# Build
# ============================================================================

build_ligi() {
    log "Building ligi..."

    cd "$PROJECT_ROOT"

    if ! zig build 2>&1; then
        log_fail "Build failed"
        exit 2
    fi

    if [[ ! -x "$LIGI_BIN" ]]; then
        log_fail "Binary not found at $LIGI_BIN"
        exit 2
    fi

    log "Build successful: $LIGI_BIN"
}

# ============================================================================
# Test Cases
# ============================================================================

test_version() {
    local output
    output=$("$LIGI_BIN" --version)
    assert_contains "$output" "ligi"
}

test_help() {
    local output
    output=$("$LIGI_BIN" --help)
    assert_contains "$output" "Usage:" && \
    assert_contains "$output" "Commands:" && \
    assert_contains "$output" "init" && \
    assert_contains "$output" "check" && \
    assert_contains "$output" "backup"
}

test_help_short() {
    local output
    output=$("$LIGI_BIN" -h)
    assert_contains "$output" "Usage:"
}

test_unknown_command() {
    local output
    local exit_code=0

    output=$("$LIGI_BIN" nonexistent 2>&1) || exit_code=$?

    assert_exit_code 1 "$exit_code" && \
    assert_contains "$output" "unknown command"
}

test_init_local() {
    local test_dir="$TEST_TMPDIR/test_init_local"
    mkdir -p "$test_dir"

    local output
    output=$("$LIGI_BIN" init --root "$test_dir" 2>&1)

    assert_contains "$output" "Initialized" && \
    assert_dir_exists "$test_dir/art" && \
    assert_dir_exists "$test_dir/art/index" && \
    assert_dir_exists "$test_dir/art/config" && \
    assert_dir_exists "$test_dir/art/template" && \
    assert_dir_exists "$test_dir/art/archive" && \
    assert_file_exists "$test_dir/art/README.md" && \
    assert_file_exists "$test_dir/AGENTS.md" && \
    assert_file_exists "$test_dir/art/index/ligi_tags.md" && \
    assert_file_exists "$test_dir/art/config/ligi.toml"
}

test_init_idempotent() {
    local test_dir="$TEST_TMPDIR/test_init_idempotent"
    mkdir -p "$test_dir"

    # First init
    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    # Second init should not fail and should report already initialized
    local output
    output=$("$LIGI_BIN" init --root "$test_dir" 2>&1)

    assert_contains "$output" "already initialized"
}

test_init_quiet() {
    local test_dir="$TEST_TMPDIR/test_init_quiet"
    mkdir -p "$test_dir"

    local output
    output=$("$LIGI_BIN" init --root "$test_dir" --quiet 2>&1)

    # Should have no output in quiet mode
    assert_eq "" "$output" && \
    assert_dir_exists "$test_dir/art"
}

test_init_registers_in_global_index() {
    local test_dir="$TEST_TMPDIR/test_init_registers"
    mkdir -p "$test_dir"

    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    local global_index="$HOME/.ligi/art/index/ligi_global_index.md"

    if [[ ! -f "$global_index" ]]; then
        echo "  Global index not found: $global_index"
        return 1
    fi

    # The path should be in the global index (canonicalized)
    local canonical_path
    canonical_path=$(cd "$test_dir" && pwd -P)

    grep -q "$canonical_path" "$global_index"
}

test_check_text_output() {
    local test_dir="$TEST_TMPDIR/test_check_text"
    mkdir -p "$test_dir/art"

    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    local output
    output=$("$LIGI_BIN" check 2>&1)

    # Should show OK for our test repo
    assert_contains "$output" "OK"
}

test_check_json_output() {
    local test_dir="$TEST_TMPDIR/test_check_json"
    mkdir -p "$test_dir/art"

    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    local output
    output=$("$LIGI_BIN" check -o json 2>&1)

    # Should be valid JSON structure
    assert_contains "$output" '{"results":[' && \
    assert_contains "$output" '"status":"OK"'
}

test_check_missing_art() {
    local test_dir="$TEST_TMPDIR/test_check_missing_art"
    mkdir -p "$test_dir/art"

    # Init first (creates art/)
    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    # Remove art/ directory
    rm -rf "$test_dir/art"

    local output
    output=$("$LIGI_BIN" check 2>&1)

    assert_contains "$output" "MISSING_ART"
}

test_check_broken_path() {
    local test_dir="$TEST_TMPDIR/test_check_broken"
    mkdir -p "$test_dir/art"

    # Init to register
    "$LIGI_BIN" init --root "$test_dir" >/dev/null 2>&1

    # Remove entire directory
    rm -rf "$test_dir"

    local output
    local exit_code=0
    output=$("$LIGI_BIN" check 2>&1) || exit_code=$?

    assert_contains "$output" "BROKEN" && \
    assert_exit_code 1 "$exit_code"
}

test_check_empty_index() {
    # Ensure we have a clean global index for this test
    local global_index="$HOME/.ligi/art/index/ligi_global_index.md"
    local backup=""

    if [[ -f "$global_index" ]]; then
        backup=$(cat "$global_index")
        # Write empty index
        cat > "$global_index" << 'EOF'
# Ligi Global Index

This file is auto-maintained by ligi. It tracks all repositories initialized with ligi.

## Repositories

## Notes

(Freeform, not parsed by ligi)
EOF
    fi

    local output
    output=$("$LIGI_BIN" check 2>&1)

    # Restore backup
    if [[ -n "$backup" ]]; then
        echo "$backup" > "$global_index"
    fi

    assert_contains "$output" "No repositories registered"
}

test_init_help() {
    local output
    output=$("$LIGI_BIN" init --help 2>&1)

    assert_contains "$output" "Usage:" && \
    assert_contains "$output" "init"
}

test_check_help() {
    local output
    output=$("$LIGI_BIN" check --help 2>&1)

    assert_contains "$output" "Usage:" && \
    assert_contains "$output" "check"
}

test_global_flag_help() {
    local output
    output=$("$LIGI_BIN" --help init 2>&1)

    assert_contains "$output" "init"
}

# ============================================================================
# Main
# ============================================================================

main() {
    log "Ligi CLI Smoke Tests"
    log "===================="

    # Create temp directory
    TEST_TMPDIR=$(mktemp -d -t ligi_smoke_test_XXXXXX)
    log "Temp directory: $TEST_TMPDIR"

    # Build
    build_ligi

    echo ""
    log "Running tests..."
    echo ""

    # Version and help tests
    run_test "ligi --version shows version" test_version || true
    run_test "ligi --help shows help" test_help || true
    run_test "ligi -h shows help" test_help_short || true
    run_test "ligi <unknown> returns error" test_unknown_command || true

    # Init command tests
    run_test "ligi init creates directory structure" test_init_local || true
    run_test "ligi init is idempotent" test_init_idempotent || true
    run_test "ligi init --quiet suppresses output" test_init_quiet || true
    run_test "ligi init registers in global index" test_init_registers_in_global_index || true
    run_test "ligi init --help shows init help" test_init_help || true

    # Check command tests
    run_test "ligi check shows text output" test_check_text_output || true
    run_test "ligi check -o json shows JSON output" test_check_json_output || true
    run_test "ligi check reports MISSING_ART" test_check_missing_art || true
    run_test "ligi check reports BROKEN paths" test_check_broken_path || true
    run_test "ligi check handles empty index" test_check_empty_index || true
    run_test "ligi check --help shows check help" test_check_help || true

    # Help variations
    run_test "ligi --help <cmd> shows command help" test_global_flag_help || true

    # Summary
    echo ""
    log "===================="
    log "Results: $TESTS_PASSED/$TESTS_RUN passed"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_fail "$TESTS_FAILED test(s) failed"
        exit 1
    else
        log_pass "All tests passed!"
        exit 0
    fi
}

main "$@"
