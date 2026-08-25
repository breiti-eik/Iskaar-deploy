#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Smoke-Test Script — Functional Tests
# Validates the smoke-test.sh script behavior.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test.sh"

PASSED=0
FAILED=0
SKIPPED=0

# --- Test Helpers ------------------------------------------------------------

pass() {
    echo "  ✅ PASS: $1"
    ((PASSED++))
}

fail() {
    echo "  ❌ FAIL: $1"
    ((FAILED++))
}

skip() {
    echo "  ⏭️  SKIP: $1"
    ((SKIPPED++))
}

# --- Tests -------------------------------------------------------------------

test_help_flag() {
    echo "Test: --help flag exits 0 and shows usage"
    local output
    output=$(bash "$SMOKE_SCRIPT" --help 2>&1) || true
    if echo "$output" | grep -q "Usage:"; then
        pass "--help shows usage"
    else
        fail "--help does not show usage"
    fi
}

test_invalid_environment() {
    echo "Test: Invalid environment exits with error"
    local output
    output=$(bash "$SMOKE_SCRIPT" invalid 2>&1) || true
    if echo "$output" | grep -q "Invalid environment"; then
        pass "Invalid environment rejected"
    else
        fail "Invalid environment not rejected"
    fi
}

test_missing_environment() {
    echo "Test: Missing environment exits with error"
    local output
    output=$(bash "$SMOKE_SCRIPT" 2>&1) || true
    if echo "$output" | grep -q "Error"; then
        pass "Missing environment shows error"
    else
        fail "Missing environment does not show error"
    fi
}

test_valid_environments() {
    echo "Test: Valid environments are accepted (dev, stage, prod)"
    for env in dev stage prod; do
        # Use a very short timeout and unreachable URL to make it fail fast
        local output
        output=$(MAX_RETRIES=1 RETRY_DELAY=0 TIMEOUT=1 bash "$SMOKE_SCRIPT" "$env" --backend-url http://127.0.0.1:1 --frontend-url http://127.0.0.1:1 2>&1) || true
        if echo "$output" | grep -q "Environment: $env"; then
            pass "Environment '$env' accepted"
        else
            fail "Environment '$env' not accepted"
        fi
    done
}

test_url_override() {
    echo "Test: --backend-url and --frontend-url override defaults"
    local output
    output=$(MAX_RETRIES=1 RETRY_DELAY=0 TIMEOUT=1 bash "$SMOKE_SCRIPT" dev --backend-url http://custom-be:9999 --frontend-url http://custom-fe:8888 2>&1) || true
    if echo "$output" | grep -q "Backend URL: http://custom-be:9999"; then
        pass "--backend-url override works"
    else
        fail "--backend-url override not applied"
    fi
    if echo "$output" | grep -q "Frontend URL: http://custom-fe:8888"; then
        pass "--frontend-url override works"
    else
        fail "--frontend-url override not applied"
    fi
}

test_exit_code_on_failure() {
    echo "Test: Exit code 1 when endpoints unreachable"
    local exit_code=0
    MAX_RETRIES=1 RETRY_DELAY=0 TIMEOUT=1 bash "$SMOKE_SCRIPT" dev --backend-url http://127.0.0.1:1 --frontend-url http://127.0.0.1:1 >/dev/null 2>&1 || exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
        pass "Exit code 1 on failure"
    else
        fail "Expected exit code 1, got $exit_code"
    fi
}

test_failure_summary() {
    echo "Test: Failure summary shows count"
    local output
    output=$(MAX_RETRIES=1 RETRY_DELAY=0 TIMEOUT=1 bash "$SMOKE_SCRIPT" dev --backend-url http://127.0.0.1:1 --frontend-url http://127.0.0.1:1 2>&1) || true
    if echo "$output" | grep -q "3 of 3 smoke test"; then
        pass "Failure summary shows correct count"
    else
        fail "Failure summary incorrect"
    fi
}

test_retry_output() {
    echo "Test: Retry attempts are logged"
    local output
    output=$(MAX_RETRIES=2 RETRY_DELAY=0 TIMEOUT=1 bash "$SMOKE_SCRIPT" dev --backend-url http://127.0.0.1:1 --frontend-url http://127.0.0.1:1 2>&1) || true
    if echo "$output" | grep -q "attempt 1/2"; then
        pass "Retry attempts logged"
    else
        fail "Retry attempts not logged"
    fi
}

# --- Run All Tests -----------------------------------------------------------

echo "=== Smoke-Test Script — Functional Tests ==="
echo ""

test_help_flag
test_invalid_environment
test_missing_environment
test_valid_environments
test_url_override
test_exit_code_on_failure
test_failure_summary
test_retry_output

echo ""
echo "=== Results: $PASSED passed, $FAILED failed, $SKIPPED skipped ==="

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
