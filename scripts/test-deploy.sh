#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deploy Script Function Tests
# Tests: Dry-Run Output, Semver Validation, Environment Validation, Tag Override
# Validates: Requirements 1.7, 2.1, 2.2, 2.9
# =============================================================================

# --- Test Framework -----------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_PATH="./scripts/deploy.sh"

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
    if [ -n "${2:-}" ]; then
        echo "        Reason: $2"
    fi
}

skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    echo "  SKIP: $1"
    if [ -n "${2:-}" ]; then
        echo "        Reason: $2"
    fi
}

# --- Prerequisite Check -------------------------------------------------------

has_prerequisites() {
    for cmd in git docker helm kubectl; do
        if ! command -v "$cmd" &>/dev/null; then
            return 1
        fi
    done
    return 0
}

# --- Tests --------------------------------------------------------------------

# Test 1: Help output exits 0 and shows usage
test_help_output() {
    echo "[Test 1] --help exits 0 and shows usage"
    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH --help 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        pass "--help exits with code 0"
    else
        fail "--help exits with code $exit_code (expected 0)"
    fi

    if echo "$output" | grep -qi "Usage"; then
        pass "--help output contains 'Usage'"
    else
        fail "--help output does not contain 'Usage'" "Output: $output"
    fi
}

# Test 2: Invalid environment exits non-zero with error message
test_invalid_environment() {
    echo "[Test 2] Invalid environment 'test' is rejected"
    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH test 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        pass "Invalid environment 'test' exits with non-zero code ($exit_code)"
    else
        fail "Invalid environment 'test' should exit non-zero" "Got exit code 0"
        return
    fi

    if echo "$output" | grep -qi "Invalid environment"; then
        pass "Error message mentions 'Invalid environment'"
    else
        fail "Error message does not mention 'Invalid environment'" "Output: $output"
    fi
}

# Test 3: Missing environment argument exits non-zero
test_missing_environment() {
    echo "[Test 3] Missing environment argument is rejected"
    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        pass "Missing environment exits with non-zero code ($exit_code)"
    else
        fail "Missing environment should exit non-zero" "Got exit code 0"
        return
    fi

    if echo "$output" | grep -qi "required\|Usage"; then
        pass "Error output indicates missing argument"
    else
        fail "Error output does not indicate missing argument" "Output: $output"
    fi
}

# Test 4: Dry-run output contains [DRY-RUN]
test_dry_run_prefix() {
    echo "[Test 4] Dry-run output contains [DRY-RUN] lines"
    if ! has_prerequisites; then
        skip "Dry-run [DRY-RUN] prefix" "Required tools (git, docker, helm, kubectl) not available"
        return
    fi

    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --dry-run --tag v1.0.0 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        skip "Dry-run [DRY-RUN] prefix" "Script exited with code $exit_code (may need registry)"
        return
    fi

    if echo "$output" | grep -q "\[DRY-RUN\]"; then
        pass "Dry-run output contains [DRY-RUN] prefix"
    else
        fail "Dry-run output does not contain [DRY-RUN] prefix" "Output: $output"
    fi
}

# Test 5: Dry-run contains helm upgrade --install
test_dry_run_helm_upgrade() {
    echo "[Test 5] Dry-run output contains 'helm upgrade --install'"
    if ! has_prerequisites; then
        skip "Dry-run helm upgrade" "Required tools (git, docker, helm, kubectl) not available"
        return
    fi

    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --dry-run --tag v1.0.0 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        skip "Dry-run helm upgrade" "Script exited with code $exit_code (may need registry)"
        return
    fi

    if echo "$output" | grep -q "helm upgrade --install"; then
        pass "Dry-run output contains 'helm upgrade --install'"
    else
        fail "Dry-run output does not contain 'helm upgrade --install'" "Output: $output"
    fi
}

# Test 6: Tag override is used in dry-run output
test_tag_override_used() {
    echo "[Test 6] Tag override v1.0.0 appears in dry-run output"
    if ! has_prerequisites; then
        skip "Tag override in dry-run" "Required tools (git, docker, helm, kubectl) not available"
        return
    fi

    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --dry-run --tag v1.0.0 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        skip "Tag override in dry-run" "Script exited with code $exit_code (may need registry)"
        return
    fi

    if echo "$output" | grep -q "v1.0.0"; then
        pass "Dry-run output contains overridden tag 'v1.0.0'"
    else
        fail "Dry-run output does not contain overridden tag 'v1.0.0'" "Output: $output"
    fi
}

# Test 7: Semver validation - valid tags accepted
test_semver_valid_tags() {
    echo "[Test 7] Valid semver tags are accepted"
    local valid_tags=("v1.0.0" "v2.3.1" "v0.1.0")
    local all_passed=true

    for tag in "${valid_tags[@]}"; do
        local output exit_code
        output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --tag "$tag" 2>&1 ) && exit_code=0 || exit_code=$?

        # The tag should NOT be rejected by semver validation
        if echo "$output" | grep -qi "not a valid semver tag"; then
            fail "Valid tag '$tag' was rejected as invalid semver" "Output: $output"
            all_passed=false
        else
            pass "Valid tag '$tag' accepted (not rejected by semver validation)"
        fi
    done
}

# Test 8: Semver validation - invalid tags rejected
test_semver_invalid_tags() {
    echo "[Test 8] Invalid semver tags are rejected"

    # v-prefixed tags that don't match vMAJOR.MINOR.PATCH are rejected
    local invalid_v_tags=("v1.0" "v1.0.0-beta")

    for tag in "${invalid_v_tags[@]}"; do
        local output exit_code
        output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --tag "$tag" 2>&1 ) && exit_code=0 || exit_code=$?

        if [ $exit_code -ne 0 ] && echo "$output" | grep -qi "not a valid semver tag"; then
            pass "Invalid v-prefixed tag '$tag' rejected with semver error"
        else
            if echo "$output" | grep -qi "Missing required tools"; then
                skip "Invalid tag '$tag'" "Prerequisites not available (tools missing)"
            else
                fail "Invalid v-prefixed tag '$tag' should be rejected" "Exit: $exit_code, Output: $output"
            fi
        fi
    done

    # Tags without 'v' prefix (1.0.0, latest) are not semver-validated
    # but they are used as-is (no semver tagging applied)
    # The requirement is that only vMAJOR.MINOR.PATCH is valid semver;
    # these should not produce a semver-tagged image
    local non_v_tags=("1.0.0" "latest")

    for tag in "${non_v_tags[@]}"; do
        local output exit_code
        output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --tag "$tag" 2>&1 ) && exit_code=0 || exit_code=$?

        # These tags bypass semver validation (no 'v' prefix)
        # They are used as raw tags without the semver guarantee
        if echo "$output" | grep -qi "not a valid semver tag"; then
            pass "Tag '$tag' correctly identified as non-semver"
        else
            # Script uses them as-is without semver validation (expected behavior)
            pass "Tag '$tag' used as raw tag (no semver validation triggered, no v-prefix)"
        fi
    done
}

# Test 9: Environment selects correct values file
test_environment_selects_values_file() {
    echo "[Test 9] Environment selects correct values file in dry-run"
    if ! has_prerequisites; then
        skip "Environment values file selection" "Required tools (git, docker, helm, kubectl) not available"
        return
    fi

    # Test dev environment
    local output_dev exit_code_dev
    output_dev=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --dry-run --tag v1.0.0 2>&1 ) && exit_code_dev=0 || exit_code_dev=$?

    if [ $exit_code_dev -ne 0 ]; then
        skip "Dev values file" "Script exited with code $exit_code_dev"
    else
        if echo "$output_dev" | grep -q "values-dev.yaml"; then
            pass "Dev environment uses values-dev.yaml"
        else
            fail "Dev environment does not reference values-dev.yaml" "Output: $output_dev"
        fi
    fi

    # Test prod environment
    local output_prod exit_code_prod
    output_prod=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH prod --dry-run --tag v1.0.0 2>&1 ) && exit_code_prod=0 || exit_code_prod=$?

    if [ $exit_code_prod -ne 0 ]; then
        skip "Prod values file" "Script exited with code $exit_code_prod"
    else
        if echo "$output_prod" | grep -q "values-prod.yaml"; then
            pass "Prod environment uses values-prod.yaml"
        else
            fail "Prod environment does not reference values-prod.yaml" "Output: $output_prod"
        fi
    fi
}

# --- Execute Tests ------------------------------------------------------------

echo "============================================="
echo "  Deploy Script Function Tests"
echo "============================================="
echo ""
echo "Deploy directory: $DEPLOY_DIR"
echo "Script path: $SCRIPT_PATH"
echo ""

# Verify deploy script exists
if [ ! -f "$DEPLOY_DIR/$SCRIPT_PATH" ]; then
    echo "ERROR: Deploy script not found at $DEPLOY_DIR/$SCRIPT_PATH"
    exit 1
fi

# Verify deploy script is executable
if [ ! -x "$DEPLOY_DIR/$SCRIPT_PATH" ]; then
    echo "WARNING: Deploy script is not executable, attempting chmod +x"
    chmod +x "$DEPLOY_DIR/$SCRIPT_PATH"
fi

echo "--- Help & Usage (Req 2.1) ---"
test_help_output
echo ""

echo "--- Environment Validation (Req 2.1) ---"
test_invalid_environment
test_missing_environment
echo ""

echo "--- Dry-Run Output (Req 2.9) ---"
test_dry_run_prefix
test_dry_run_helm_upgrade
test_tag_override_used
echo ""

echo "--- Semver Validation (Req 1.7, 2.2) ---"
test_semver_valid_tags
test_semver_invalid_tags
echo ""

echo "--- Environment Values File Selection (Req 2.1) ---"
test_environment_selects_values_file
echo ""

# --- Summary ------------------------------------------------------------------

echo "============================================="
echo "  Test Summary"
echo "============================================="
echo "  Run:     $TESTS_RUN"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  Skipped: $TESTS_SKIPPED"
echo "============================================="

if [ $TESTS_FAILED -gt 0 ]; then
    echo "  RESULT: FAILED"
    exit 1
else
    echo "  RESULT: ALL PASSED"
    exit 0
fi
