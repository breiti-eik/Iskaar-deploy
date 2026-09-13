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
    local fixture output exit_code tag
    fixture="$(contract_new_deploy_fixture)"

    for tag in v1.0.0 v2.3.1 v0.1.0; do
        output="$(contract_run_deploy "$fixture" dev --deploy true --tag "$tag" --skip-smoke 2>&1)" && exit_code=0 || exit_code=$?

        if [[ "$exit_code" -ne 0 ]] && printf '%s\n' "$output" | grep -qi "not a valid semver tag"; then
            fail "Valid tag '$tag' was rejected as invalid semver" "Output: $output"
        else
            pass "Valid tag '$tag' accepted (not rejected by semver validation)"
        fi
    done

    rm -rf -- "$fixture"
}

# Test 8: Semver validation - invalid tags rejected
test_semver_invalid_tags() {
    echo "[Test 8] Invalid semver tags are rejected"
    local fixture output exit_code tag
    fixture="$(contract_new_deploy_fixture)"

    for tag in v1.0 v1.0.0-beta; do
        output="$(contract_run_deploy "$fixture" dev --deploy true --tag "$tag" --skip-smoke 2>&1)" && exit_code=0 || exit_code=$?

        if [[ "$exit_code" -ne 0 ]] && printf '%s\n' "$output" | grep -qi "not a valid semver tag"; then
            pass "Invalid v-prefixed tag '$tag' rejected with semver error"
        else
            fail "Invalid v-prefixed tag '$tag' should be rejected" "Exit: $exit_code, Output: $output"
        fi
    done

    # Tags without 'v' prefix are used as raw image tags without semver validation.
    for tag in 1.0.0 latest; do
        output="$(contract_run_deploy "$fixture" dev --deploy true --tag "$tag" --skip-smoke 2>&1)" && exit_code=0 || exit_code=$?

        if printf '%s\n' "$output" | grep -qi "not a valid semver tag"; then
            fail "Non-v tag '$tag' unexpectedly triggered semver validation" "Output: $output"
        else
            pass "Tag '$tag' used as a raw tag without semver validation"
        fi
    done

    rm -rf -- "$fixture"
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

# Test 10: Dry-run contains smoke-test invocation
test_dry_run_smoke_test() {
    echo "[Test 10] Dry-run output contains smoke-test invocation"
    if ! has_prerequisites; then
        skip "Dry-run smoke-test" "Required tools (git, docker, helm, kubectl) not available"
        return
    fi

    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --dry-run --tag v1.0.0 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        skip "Dry-run smoke-test" "Script exited with code $exit_code"
        return
    fi

    if echo "$output" | grep -q "smoke-test.sh"; then
        pass "Dry-run output contains smoke-test.sh invocation"
    else
        fail "Dry-run output does not contain smoke-test.sh invocation" "Output: $output"
    fi
}

# Test 11: --skip-smoke flag skips smoke tests
test_skip_smoke_flag() {
    echo "[Test 11] --skip-smoke flag skips smoke tests"
    if ! has_prerequisites; then
        skip "Skip-smoke flag" "Required tools (git, docker, helm, kubectl) not available"
        return
    fi

    local output exit_code
    output=$( cd "$DEPLOY_DIR" && $SCRIPT_PATH dev --dry-run --tag v1.0.0 --skip-smoke 2>&1 ) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        skip "Skip-smoke flag" "Script exited with code $exit_code"
        return
    fi

    if echo "$output" | grep -q "Smoke tests skipped"; then
        pass "--skip-smoke skips smoke tests"
    else
        fail "--skip-smoke does not skip smoke tests" "Output: $output"
    fi

    # Should NOT contain smoke-test.sh call
    if echo "$output" | grep -q "smoke-test.sh"; then
        fail "--skip-smoke still calls smoke-test.sh"
    else
        pass "--skip-smoke does not call smoke-test.sh"
    fi
}

# --- Deployment flag and wrapper contract fixtures ----------------------------

contract_assert_output_line() {
    local output="$1"
    local expected="$2"
    local description="$3"

    if printf '%s\n' "$output" | grep -Fqx -- "$expected"; then
        pass "$description"
    else
        fail "$description" "Expected line '$expected'. Output: $output"
    fi
}

contract_assert_output_contains() {
    local output="$1"
    local expected="$2"
    local description="$3"

    if printf '%s\n' "$output" | grep -Fq -- "$expected"; then
        pass "$description"
    else
        fail "$description" "Expected '$expected'. Output: $output"
    fi
}

contract_assert_file_line() {
    local file="$1"
    local expected="$2"
    local description="$3"

    if [[ -f "$file" ]] && grep -Fqx -- "$expected" "$file"; then
        pass "$description"
    else
        fail "$description" "Expected line '$expected' in '$file'."
    fi
}

contract_new_readiness_fixture() {
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/iskaar-deploy-readiness.XXXXXX")"

    cat > "$fixture/validator.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "${VALIDATOR_ARGS_LOG:?}"
exit "${VALIDATOR_EXIT_CODE:-0}"
EOF
    chmod +x "$fixture/validator.sh"
    printf '%s\n' "$fixture"
}

contract_run_readiness() {
    local fixture="$1"
    shift

    (
        cd "$DEPLOY_DIR"
        READINESS_VALIDATOR="$fixture/validator.sh" \
        VALIDATOR_ARGS_LOG="$fixture/validator.args" \
        "$SCRIPT_PATH" "$@"
    )
}

contract_new_deploy_fixture() {
    local fixture command_name
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/iskaar-deploy-mode.XXXXXX")"
    mkdir -p "$fixture/bin"

    for command_name in git docker helm kubectl; do
        cat > "$fixture/bin/$command_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s %s\n' "${0##*/}" "$*" >> "${FAKE_COMMAND_LOG:?}"
exit 0
EOF
        chmod +x "$fixture/bin/$command_name"
        cp "$fixture/bin/$command_name" "$fixture/bin/${command_name}.exe"
        chmod +x "$fixture/bin/${command_name}.exe"
    done

    cat > "$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s %s\n' "${0##*/}" "$*" >> "${FAKE_COMMAND_LOG:?}"
# Force deploy.sh to use the Minikube Docker daemon fallback instead of a registry.
exit 1
EOF
    chmod +x "$fixture/bin/curl"

    cat > "$fixture/bin/minikube" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s %s\n' "${0##*/}" "$*" >> "${FAKE_COMMAND_LOG:?}"
case "${1:-}" in
    status)
        printf 'Running\n'
        ;;
    service)
        # Return an unreachable local URL so the registry fallback stays isolated.
        printf 'http://127.0.0.1:65534\n'
        ;;
    docker-env)
        # No environment changes are required for this isolated test daemon.
        ;;
esac
exit 0
EOF
    chmod +x "$fixture/bin/minikube"
    cp "$fixture/bin/minikube" "$fixture/bin/minikube.exe"
    chmod +x "$fixture/bin/minikube.exe"

    cat > "$fixture/minikube-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'minikube-setup %s\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
exit 0
EOF
    chmod +x "$fixture/minikube-setup.sh"
    printf '%s\n' "$fixture"
}

contract_run_deploy() {
    local fixture="$1"
    shift

    (
        cd "$DEPLOY_DIR"
        PATH="$fixture/bin:$PATH" \
        MINIKUBE_SETUP_SCRIPT="$fixture/minikube-setup.sh" \
        FAKE_COMMAND_LOG="$fixture.commands" \
        "$SCRIPT_PATH" "$@"
    )
}

test_deploy_mode_contracts() {
    echo "[Test 12] Deployment default, valid values, monitoring default, and stable mode output"
    local fixture output exit_code
    fixture="$(contract_new_readiness_fixture)"

    output="$(contract_run_readiness "$fixture" dev 2>&1)" && exit_code=0 || exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        pass "Missing --deploy defaults to readiness mode with exit code 0"
    else
        fail "Missing --deploy should default to readiness mode" "Exit: $exit_code, Output: $output"
    fi
    contract_assert_output_line "$output" "Mode: READINESS (deploy=false)" "Missing --deploy prints the readiness mode"
    contract_assert_output_line "$output" "Minikube target: not contacted" "Readiness output does not contact Minikube"
    contract_assert_output_line "$output" "Monitoring: false" "Missing --monitoring defaults to false"
    contract_assert_output_line "$output" "Cluster mutations: disabled" "Readiness output disables cluster mutations"
    contract_assert_file_line "$fixture/validator.args" "--deploy" "Readiness validator receives the deployment option"
    contract_assert_file_line "$fixture/validator.args" "false" "Readiness validator receives deploy=false"
    contract_assert_file_line "$fixture/validator.args" "--monitoring" "Readiness validator receives the monitoring option"

    output="$(contract_run_readiness "$fixture" dev --deploy false --monitoring true 2>&1)" && exit_code=0 || exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        pass "Exact values --deploy false and --monitoring true are accepted"
    else
        fail "Exact boolean values should be accepted" "Exit: $exit_code, Output: $output"
    fi
    contract_assert_output_line "$output" "Mode: READINESS (deploy=false)" "Explicit deploy=false prints the readiness mode"
    contract_assert_output_line "$output" "Monitoring: true" "Explicit monitoring=true is reported"
    contract_assert_file_line "$fixture/validator.args" "true" "Readiness validator receives monitoring=true"

    rm -rf -- "$fixture"

    fixture="$(contract_new_deploy_fixture)"
    output="$(contract_run_deploy "$fixture" dev --deploy true --monitoring false --tag contract-tag --skip-smoke 2>&1)" && exit_code=0 || exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
        pass "Exact value --deploy true is accepted by the isolated deploy path"
    else
        fail "Exact value --deploy true should be accepted" "Exit: $exit_code, Output: $output, Commands: $(cat "$fixture.commands" 2>/dev/null || true)"
    fi
    contract_assert_output_line "$output" "Mode: DEPLOY (deploy=true)" "Deploy output prints the deployment mode"
    contract_assert_output_line "$output" "Environment: dev" "Deploy output reports the selected environment"
    contract_assert_output_line "$output" "Minikube profile: minikube" "Deploy output reports the Minikube profile"
    contract_assert_output_line "$output" "Target context: minikube" "Deploy output reports the target context"
    contract_assert_output_line "$output" "Monitoring: false" "Deploy output reports the monitoring default"
    contract_assert_output_line "$output" "Cluster mutations: enabled for local Minikube only" "Deploy output states the local mutation boundary"

    if [[ -f "$fixture.commands" ]] && grep -Eq '(^| )docker push( |$)' "$fixture.commands"; then
        fail "Isolated deploy contract must not push to a registry" "Command log: $(cat "$fixture.commands")"
    else
        pass "Isolated deploy contract performs no registry push"
    fi
    rm -rf -- "$fixture"
}

test_deploy_parser_rejects_invalid_values() {
    echo "[Test 13] Invalid boolean values and the deploy environment boundary are rejected"
    local fixture output exit_code option_name invalid_value environment
    fixture="$(contract_new_readiness_fixture)"

    rm -f -- "$fixture/validator.args"
    for option_name in --deploy --monitoring; do
        for invalid_value in TRUE False 1; do
            output="$(contract_run_readiness "$fixture" dev "$option_name" "$invalid_value" 2>&1)" && exit_code=0 || exit_code=$?
            if [[ "$exit_code" -ne 0 ]]; then
                pass "$option_name rejects non-exact value '$invalid_value'"
            else
                fail "$option_name should reject non-exact value '$invalid_value'" "Output: $output"
            fi
            contract_assert_output_contains "$output" "Valid values: true, false" "$option_name reports its exact valid values"
        done
    done

    output="$(contract_run_readiness "$fixture" dev --deploy 2>&1)" && exit_code=0 || exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        pass "Missing --deploy value is rejected before the readiness validator"
    else
        fail "Missing --deploy value should exit non-zero" "Output: $output"
    fi
    contract_assert_output_contains "$output" "requires a value" "Missing --deploy value has a concrete diagnostic"

    if [[ -e "$fixture/validator.args" ]]; then
        fail "Invalid parser inputs must not start the readiness validator"
    else
        pass "Invalid parser inputs do not start the readiness validator"
    fi

    for environment in stage prod; do
        output="$(contract_run_readiness "$fixture" "$environment" --deploy true 2>&1)" && exit_code=0 || exit_code=$?
        if [[ "$exit_code" -ne 0 ]]; then
            pass "--deploy true is rejected for environment '$environment'"
        else
            fail "--deploy true should be rejected for environment '$environment'" "Output: $output"
        fi
        contract_assert_output_contains "$output" "allowed only with environment 'dev'" "Environment '$environment' reports the local dev restriction"
    done

    rm -rf -- "$fixture"
}

find_powershell_runner() {
    local candidate resolved
    for candidate in pwsh powershell.exe; do
        if resolved="$(command -v "$candidate" 2>/dev/null)" && [[ -n "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    return 1
}

to_powershell_path() {
    local path="$1"
    local drive rest

    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path"
        return 0
    fi
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$path"
        return 0
    fi

    if [[ "$path" =~ ^/mnt/([A-Za-z])/(.*)$ ]]; then
        drive="${BASH_REMATCH[1]^^}"
        rest="${BASH_REMATCH[2]//\//\\}"
        printf '%s:\\%s\n' "$drive" "$rest"
    elif [[ "$path" =~ ^/([A-Za-z])/(.*)$ ]]; then
        drive="${BASH_REMATCH[1]^^}"
        rest="${BASH_REMATCH[2]//\//\\}"
        printf '%s:\\%s\n' "$drive" "$rest"
    else
        printf '%s\n' "$path"
    fi
}

test_powershell_wrapper_contract() {
    echo "[Test 14] PowerShell wrapper forwards parameters and preserves child exit code"
    local powershell_runner fixture wrapper_path test_path output exit_code

    if ! powershell_runner="$(find_powershell_runner)"; then
        skip "PowerShell wrapper forwarding" "No pwsh or powershell.exe is available"
        return
    fi

    fixture="$(mktemp -d "$DEPLOY_DIR/.deploy-wrapper-contract.XXXXXX")"
    cp "$DEPLOY_DIR/scripts/deploy.ps1" "$fixture/deploy.ps1"
    cat > "$fixture/deploy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$@" > "$fixture_dir/args.log"
{
    printf 'BUILD_TIMEOUT=%s\n' "${BUILD_TIMEOUT:-}"
    printf 'MINIKUBE_START_TIMEOUT=%s\n' "${MINIKUBE_START_TIMEOUT:-}"
    printf 'ROLLOUT_TIMEOUT=%s\n' "${ROLLOUT_TIMEOUT:-}"
    printf 'CERTIFICATE_TIMEOUT=%s\n' "${CERTIFICATE_TIMEOUT:-}"
    printf 'ACCESS_TIMEOUT=%s\n' "${ACCESS_TIMEOUT:-}"
    printf 'SMOKE_TIMEOUT=%s\n' "${SMOKE_TIMEOUT:-}"
} > "$fixture_dir/environment.log"
exit 37
EOF
    chmod +x "$fixture/deploy.sh"

    test_path="$PATH"
    if ! command -v bash.exe >/dev/null 2>&1; then
        mkdir -p "$fixture/bin"
        cat > "$fixture/bin/bash.exe" <<'EOF'
#!/usr/bin/env bash
exec bash "$@"
EOF
        chmod +x "$fixture/bin/bash.exe"
        test_path="$fixture/bin:$test_path"
    fi

    wrapper_path="$(to_powershell_path "$fixture/deploy.ps1")"
    output="$(
        cd "$DEPLOY_DIR"
        WSLENV="BUILD_TIMEOUT/u:MINIKUBE_START_TIMEOUT/u:ROLLOUT_TIMEOUT/u:CERTIFICATE_TIMEOUT/u:ACCESS_TIMEOUT/u:SMOKE_TIMEOUT/u" \
        PATH="$test_path" "$powershell_runner" \
            -NoProfile -NonInteractive -ExecutionPolicy Bypass \
            -File "$wrapper_path" \
            -Environment dev \
            -Deploy false \
            -Monitoring true \
            -Tag wrapper-contract \
            -SkipSmoke \
            -BuildTimeout 11 \
            -MinikubeStartTimeout 12 \
            -RolloutTimeout 13 \
            -CertificateTimeout 14 \
            -AccessTimeout 15 \
            -SmokeTimeout 16 2>&1
    )" && exit_code=0 || exit_code=$?

    if [[ "$exit_code" -eq 37 ]]; then
        pass "PowerShell wrapper preserves the child exit code 37"
    else
        fail "PowerShell wrapper should preserve the child exit code 37" "Exit: $exit_code, Output: $output"
    fi
    contract_assert_file_line "$fixture/args.log" "dev" "PowerShell forwards the environment"
    contract_assert_file_line "$fixture/args.log" "--deploy" "PowerShell forwards --deploy"
    contract_assert_file_line "$fixture/args.log" "false" "PowerShell forwards deploy=false"
    contract_assert_file_line "$fixture/args.log" "--monitoring" "PowerShell forwards --monitoring"
    contract_assert_file_line "$fixture/args.log" "true" "PowerShell forwards monitoring=true"
    contract_assert_file_line "$fixture/args.log" "--tag" "PowerShell forwards --tag"
    contract_assert_file_line "$fixture/args.log" "wrapper-contract" "PowerShell forwards the image tag"
    contract_assert_file_line "$fixture/args.log" "--skip-smoke" "PowerShell forwards --skip-smoke"
    contract_assert_file_line "$fixture/environment.log" "BUILD_TIMEOUT=11" "PowerShell forwards the build timeout"
    contract_assert_file_line "$fixture/environment.log" "MINIKUBE_START_TIMEOUT=12" "PowerShell forwards the Minikube start timeout"
    contract_assert_file_line "$fixture/environment.log" "ROLLOUT_TIMEOUT=13" "PowerShell forwards the rollout timeout"
    contract_assert_file_line "$fixture/environment.log" "CERTIFICATE_TIMEOUT=14" "PowerShell forwards the certificate timeout"
    contract_assert_file_line "$fixture/environment.log" "ACCESS_TIMEOUT=15" "PowerShell forwards the access timeout"
    contract_assert_file_line "$fixture/environment.log" "SMOKE_TIMEOUT=16" "PowerShell forwards the smoke timeout"

    rm -f -- "$fixture/args.log" "$fixture/environment.log"
    output="$(
        cd "$DEPLOY_DIR"
        WSLENV="BUILD_TIMEOUT/u:MINIKUBE_START_TIMEOUT/u:ROLLOUT_TIMEOUT/u:CERTIFICATE_TIMEOUT/u:ACCESS_TIMEOUT/u:SMOKE_TIMEOUT/u" \
        PATH="$test_path" "$powershell_runner" \
            -NoProfile -NonInteractive -ExecutionPolicy Bypass \
            -File "$wrapper_path" \
            -Environment dev -Deploy TRUE -Monitoring false 2>&1
    )" && exit_code=0 || exit_code=$?
    if [[ "$exit_code" -ne 0 ]] && printf '%s\n' "$output" | grep -Fq -- "Expected exactly 'true' or 'false'"; then
        pass "PowerShell rejects non-exact boolean values before starting Bash"
    else
        fail "PowerShell should reject non-exact boolean values before starting Bash" "Exit: $exit_code, Output: $output"
    fi
    if [[ ! -e "$fixture/args.log" ]]; then
        pass "PowerShell does not start the child process after boolean validation fails"
    else
        fail "PowerShell started the child process after boolean validation failed"
    fi

    rm -rf -- "$fixture"
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

echo "--- Deployment Flag & Mode Contracts (Req 1.1, 1.2, 1.3, 1.5, 1.7, 10.1, 10.2) ---"
test_deploy_mode_contracts
test_deploy_parser_rejects_invalid_values
test_powershell_wrapper_contract
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

echo "--- Smoke Tests & Rollback ---"
test_dry_run_smoke_test
test_skip_smoke_flag
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
