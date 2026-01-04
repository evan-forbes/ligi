# CLI Bash Smoke Tests

This document describes the bash-based smoke test suite for the ligi CLI.

## Overview

The smoke tests live in `scripts/smoke_test.sh`. They compile ligi and run integration tests against the binary in an isolated temp directory.

## Running Tests

```bash
# Run all tests
./scripts/smoke_test.sh

# Verbose output (shows DEBUG messages)
./scripts/smoke_test.sh -v

# Keep temp directory on failure (for debugging)
./scripts/smoke_test.sh -k

# Show help
./scripts/smoke_test.sh -h
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Build failed |

## Test Structure

### Anatomy of a Test

Each test is a bash function that returns 0 on success, non-zero on failure:

```bash
test_example() {
    local output
    output=$("$LIGI_BIN" some-command 2>&1)

    assert_contains "$output" "expected text" && \
    assert_exit_code 0 "$?"
}
```

Tests are registered and run via `run_test`:

```bash
run_test "descriptive test name" test_example || true
```

The `|| true` prevents early exit when a test fails (allows all tests to run).

### Available Assertions

| Function | Description |
|----------|-------------|
| `assert_eq expected actual` | Values are exactly equal |
| `assert_contains haystack needle` | String contains substring |
| `assert_not_contains haystack needle` | String does not contain substring |
| `assert_file_exists path` | File exists |
| `assert_dir_exists path` | Directory exists |
| `assert_exit_code expected actual` | Exit code matches |

### Test Isolation

- All tests run in a temp directory (`$TEST_TMPDIR`)
- The temp directory is created fresh for each run
- Cleanup happens automatically on exit
- Global index entries created during tests are cleaned up

## Adding New Tests

### 1. Write the Test Function

Add your test function in the "Test Cases" section of `smoke_test.sh`:

```bash
test_my_new_feature() {
    local test_dir="$TEST_TMPDIR/test_my_feature"
    mkdir -p "$test_dir"

    local output
    local exit_code=0
    output=$("$LIGI_BIN" my-command --flag "$test_dir" 2>&1) || exit_code=$?

    assert_exit_code 0 "$exit_code" && \
    assert_contains "$output" "success"
}
```

### 2. Register the Test

Add a `run_test` call in the `main` function:

```bash
run_test "my-command works with --flag" test_my_new_feature || true
```

### 3. Guidelines

- **Naming**: Test functions should be `test_<feature>_<scenario>`
- **Isolation**: Each test should use its own subdirectory in `$TEST_TMPDIR`
- **Cleanup**: The test framework handles cleanup; don't worry about it
- **Assertions**: Chain assertions with `&&` to short-circuit on failure
- **Exit codes**: Capture exit codes with `|| exit_code=$?` before assertions
- **Stderr**: Redirect stderr to stdout with `2>&1` to capture all output

### 4. Test Categories

Organize tests by command/feature in the main function:

```bash
# Version and help tests
run_test "..." test_version || true

# Init command tests
run_test "..." test_init_local || true

# Check command tests
run_test "..." test_check_text || true

# New command tests
run_test "..." test_new_command || true
```

## Current Test Coverage

### Version/Help
- `ligi --version` shows version
- `ligi --help` shows help with commands
- `ligi -h` short form works
- `ligi <unknown>` returns error

### Init Command
- Creates directory structure (`art/`, subdirs)
- Idempotent (safe to run twice)
- `--quiet` suppresses output
- Registers repo in global index
- `--help` shows init help

### Check Command
- Text output format
- JSON output format (`-o json`)
- Reports `MISSING_ART` status
- Reports `BROKEN` status
- Handles empty global index
- `--help` shows check help

## Debugging Failed Tests

1. Run with `-v` for verbose output
2. Run with `-k` to keep temp directory
3. Inspect the temp directory manually
4. Check `~/.ligi/art/index/ligi_global_index.md` for state issues

## CI Integration

The smoke tests can be run in CI:

```yaml
- name: Run smoke tests
  run: ./scripts/smoke_test.sh
```

The script uses ANSI colors only when running in a terminal, so CI logs remain readable.
